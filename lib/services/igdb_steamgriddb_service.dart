// ============================================================================
// LoopGamer — Motor de Catálogo Multi-Fonte:
// 1. RetroAPI (https://retroapi.konsumer.workers.dev/api/:platform/:field/:values)
// 2. ROM-Gripper Taxonomy & Intent API (https://romgripper.github.io/ROM-Gripper/en/api)
// 3. Cliente REST API RomM (https://docs.romm.app/latest/ — /api/platforms, /api/roms)
// 4. Descoberta ao vivo no Internet Archive + Libretro Official Thumbnails CDN
// ============================================================================

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import '../models/emulation_game.dart';
import 'rom_download_service.dart';

class _AsyncSemaphore {
  _AsyncSemaphore(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(
    Future<T> Function() task, {
    CancelToken? cancelToken,
  }) async {
    await _acquire(cancelToken: cancelToken);
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<void> _acquire({CancelToken? cancelToken}) async {
    if (cancelToken?.isCancelled == true) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken?.cancelError?.error,
      );
    }
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.addLast(waiter);
    if (cancelToken != null) {
      unawaited(
        cancelToken.whenCancel.then((err) {
          if (!waiter.isCompleted) {
            _waiters.remove(waiter);
            waiter.completeError(
              DioException.requestCancelled(
                requestOptions: RequestOptions(path: ''),
                reason: err.error,
              ),
            );
          }
        }),
      );
    }
    await waiter.future;
  }

  void _release() {
    while (_waiters.isNotEmpty) {
      final next = _waiters.removeFirst();
      if (!next.isCompleted) {
        next.complete();
        return;
      }
    }
    _active--;
  }
}

class IgdbSteamGridService {
  IgdbSteamGridService({
    Dio? dio,
    this.steamGridDbApiKey = const String.fromEnvironment('SGDB_API_KEY'),
  })  : _hasCustomDio = dio != null,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 14),
              ),
            );

  final bool _hasCustomDio;
  final Dio _dio;
  final String steamGridDbApiKey;

  CancelToken? _activeSearchCancelToken;
  bool _isDisposed = false;
  final _AsyncSemaphore _sgdbSemaphore = _AsyncSemaphore(3);
  final _AsyncSemaphore _retroApiSemaphore = _AsyncSemaphore(4);
  final _AsyncSemaphore _archiveMetaSemaphore = _AsyncSemaphore(4);

  /// Cache em memória das respostas da RetroAPI (retroapi.konsumer.workers.dev)
  static final Map<String, List<EmulationGame>> _retroApiCache = {};
  final Map<String, Future<List<EmulationGame>>> _inFlightRetroApiBySlug = {};
  final Map<String, Future<List<EmulationGame>>> _inFlightRealCatalogByKey = {};

  /// Cache de textos pré-normalizados para busca instantânea na barra de pesquisa.
  static final Map<
      int,
      ({
        String normTitle,
        String baseTitle,
        String normCanonical,
        String metaHaystack,
      })> _searchIndexCache = {};

  /// Cache em memória de artes SteamGridDB por título normalizado (evita chamadas duplicadas)
  static final Map<String, ({String? grid, String? hero, String? logo})>
      _sgdbArtCache = {};
  static final Map<String, Future<({String? grid, String? hero, String? logo})?>>
      _sgdbInFlight = {};

  /// Limpa os caches em memória (útil para isolamento em testes).
  static void clearCacheForTesting() {
    _retroApiCache.clear();
    _searchIndexCache.clear();
    _sgdbArtCache.clear();
    _sgdbInFlight.clear();
  }

  static bool _isSuccessStatus(int? statusCode) =>
      statusCode != null && statusCode >= 200 && statusCode < 300;

  static int _parseByteSize(dynamic rawValue) {
    if (rawValue is num) return rawValue.toInt();
    final str = '${rawValue ?? ''}'.trim();
    if (str.isEmpty) return 0;
    return int.tryParse(str) ?? double.tryParse(str)?.toInt() ?? 0;
  }

  static const Set<String> _validRomExtensions = {
    '.gba',
    '.gbc',
    '.gb',
    '.sfc',
    '.smc',
    '.nes',
    '.nds',
    '.3ds',
    '.cci',
    '.cxi',
    '.z64',
    '.n64',
    '.v64',
    '.md',
    '.gen',
    '.smd',
    '.gg',
    '.sms',
    '.pce',
    '.rvz',
    '.wbfs',
    '.gcz',
    '.gcm',
    '.pkg',
    '.nsp',
    '.xci',
    '.nsz',
    '.xcz',
    '.nro',
    '.nca',
    '.iso',
    '.chd',
    '.cso',
    '.pbp',
    '.bin',
    '.zip',
  };

  int cachedRetroApiCount(String platformSlug) =>
      _retroApiCache[platformSlug.toLowerCase()]?.length ?? 0;

  bool hasMoreRetroApiGames(String platformSlug, int currentLoadedForPlatform) {
    final slug = platformSlug.toLowerCase();
    if (slug == 'todos') return false;
    final total = _retroApiCache[slug]?.length;
    if (total == null) return _retroApiEndpointForPlatform(slug) != null;
    return currentLoadedForPlatform < total;
  }

  /// Consulta a API pública `https://retroapi.konsumer.workers.dev/api/:platform/:field/:values`
  /// que indexa mais de 722.000 ROMs oficiais do Libretro Database em 145 plataformas.
  Future<List<EmulationGame>> fetchFromRetroApiPlatform(
    String platformSlug, {
    int maxPerPlatform = 36,
    int offset = 0,
    CancelToken? cancelToken,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST') && !_hasCustomDio) {
      return const [];
    }
    final slug = platformSlug.toLowerCase();
    if (slug == 'todos') return const [];
    if (_retroApiCache.containsKey(slug)) {
      final cached = _retroApiCache[slug]!;
      if (offset >= cached.length) return const [];
      return cached.skip(offset).take(maxPerPlatform).toList();
    }

    final querySpec = _retroApiEndpointForPlatform(slug);
    if (querySpec == null) return const [];

    final inFlight = _inFlightRetroApiBySlug[slug];
    if (inFlight != null) {
      final parsed = await inFlight;
      if (offset >= parsed.length) return const [];
      return parsed.skip(offset).take(maxPerPlatform).toList();
    }

    final fetchFuture = _loadAndParseRetroApiPlatform(
      slug: slug,
      querySpec: querySpec,
      cancelToken: cancelToken,
    );
    _inFlightRetroApiBySlug[slug] = fetchFuture;
    try {
      final parsed = await fetchFuture;
      if (offset >= parsed.length) return const [];
      return parsed.skip(offset).take(maxPerPlatform).toList();
    } finally {
      if (identical(_inFlightRetroApiBySlug[slug], fetchFuture)) {
        unawaited(_inFlightRetroApiBySlug.remove(slug));
      }
    }
  }

  static bool _isTrackSecondaryOrBadDump(String rawName, String lowerRom) {
    if (lowerRom.endsWith('.cue')) return true;
    final trackMatch = RegExp(
      r'\(track\s*0*(\d+)\)',
      caseSensitive: false,
    ).firstMatch(rawName);
    if (trackMatch != null) {
      final trackNum = int.tryParse(trackMatch.group(1) ?? '') ?? 1;
      if (trackNum > 1) return true;
    }
    return false;
  }

  Future<List<EmulationGame>> _fetchArchiveCollectionGames({
    required String slug,
    required String platformLabel,
    required String defaultDeveloper,
    CancelToken? cancelToken,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST') && !_hasCustomDio) {
      return const [];
    }
    final collections = RomDownloadService.collectionsForPlatform(slug);
    if (collections.isEmpty) return const [];

    final minValidBytes = RomDownloadService.minBytesForPlatform(slug);
    final allowedExts = RomDownloadService.allowedExtensionsForPlatform(slug);
    final results = <EmulationGame>[];

    for (final collection in collections.take(2)) {
      if (_isDisposed || cancelToken?.isCancelled == true) break;
      try {
        final res = await _dio
            .get<dynamic>(
              'https://archive.org/metadata/$collection',
              cancelToken: cancelToken,
              options: Options(receiveTimeout: const Duration(seconds: 15)),
            )
            .timeout(const Duration(seconds: 12));
        if (!_isSuccessStatus(res.statusCode) ||
            res.data is! Map<String, dynamic>) {
          continue;
        }
        final data = res.data as Map<String, dynamic>;
        if (data['metadata']?['access-restricted-item'] == 'true') {
          continue;
        }
        final rawFiles = data['files'] as List<dynamic>? ?? const [];
        if (rawFiles.isEmpty) continue;

        final parsed = await _runParseArchiveCollectionInIsolate(
          rawFiles: rawFiles,
          collection: collection,
          slug: slug,
          platformLabel: platformLabel,
          defaultDeveloper: defaultDeveloper,
          minValidBytes: minValidBytes,
          allowedExts: allowedExts,
        );
        results.addAll(parsed);
        if (results.length >= 220) break;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
      } catch (e) {
        debugPrint(
          '[IgdbSteamGridService] Archive collection skip ($collection): $e',
        );
      }
    }
    return results;
  }

  static List<EmulationGame> _parseArchiveCollectionSync({
    required List<dynamic> rawFiles,
    required String collection,
    required String slug,
    required String platformLabel,
    required String defaultDeveloper,
    required int minValidBytes,
    required List<String> allowedExts,
  }) {
    final isArcade = slug == 'cps1' ||
        slug == 'cps2' ||
        slug == 'neogeo' ||
        slug == 'mame' ||
        slug == 'arcade';
    final parenRegex = RegExp(r'\s*\([^)]*\)|\s*\[[^\]]*\]');
    final Map<String, ({int score, EmulationGame item})> bestByKey = {};

    for (final f in rawFiles) {
      if (f is! Map) continue;
      if (f['private'] == true || f['private'] == 'true') continue;
      final name = (f['name'] as String?)?.trim() ?? '';
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower.endsWith('.xml') ||
          lower.endsWith('.sqlite') ||
          lower.endsWith('.torrent') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.png') ||
          lower.endsWith('.txt') ||
          lower.endsWith('.cue')) {
        continue;
      }
      final baseFile = name.split('/').last;
      final lowerBase = baseFile.toLowerCase();
      if (RomDownloadService.isJunkArchiveEntry(lowerBase) ||
          RomDownloadService.isNonFullGameRelease(lowerBase)) {
        continue;
      }
      if (_isTrackSecondaryOrBadDump(baseFile, lowerBase)) continue;
      if (!allowedExts.any(lowerBase.endsWith) &&
          !lowerBase.endsWith('.zip') &&
          !lowerBase.endsWith('.7z')) {
        continue;
      }

      final sizeBytes = _parseByteSize(f['size']);
      if (sizeBytes <= 0 || (!isArcade && sizeBytes < minValidBytes)) {
        continue;
      }

      final rawStem = baseFile.replaceAll(RegExp(r'\.[^.]+$'), '');
      String cleanTitle = rawStem
          .replaceAll(parenRegex, '')
          .replaceAll('_', ' ')
          .replaceAll(' - ', ': ')
          .trim();
      if (cleanTitle.isEmpty) continue;

      var resolvedSlug = slug;
      var resolvedLabel = platformLabel;
      if (isArcade) {
        final fbneo = RomDownloadService.resolveCanonicalFbneoParent(lowerBase);
        if (slug == 'cps1' || slug == 'cps2') {
          if (fbneo == null) continue;
          if (!lower.contains('/cps1/') &&
              !lower.contains('/cps2/') &&
              fbneo.platformSlug != slug &&
              !(slug == 'cps1' && fbneo.platformSlug == 'cps2')) {
            continue;
          }
          resolvedSlug = slug;
        }
        // Pula arquivos BIOS dentro de coleções arcade
        if (rawStem.toLowerCase() == 'qsound' ||
            rawStem.toLowerCase() == 'qsound_hle' ||
            rawStem.toLowerCase() == 'neogeo') {
          continue;
        }
        if (cleanTitle.length <= 12 && !cleanTitle.contains(' ')) {
          // Mantém identificador legível se não houver título expandido
          cleanTitle = rawStem.toUpperCase();
        }
      }

      final encodedPath =
          name.split('/').map(Uri.encodeComponent).join('/');
      final directUrl = 'https://archive.org/download/$collection/$encodedPath';
      final crc = ((f['crc32'] as String?) ?? '').trim().toUpperCase();
      final region = lowerBase.contains('(usa') || lowerBase.contains('(us)')
          ? 'USA'
          : (lowerBase.contains('(euro') || lowerBase.contains('(eu)')
              ? 'EUR'
              : 'WORLD');

      int score = isArcade ? 1000 : 0;
      if (region == 'USA') score += 500;
      if (region == 'WORLD') score += 400;
      if (lowerBase.endsWith('.rvz') ||
          lowerBase.endsWith('.chd') ||
          lowerBase.endsWith('.wbfs')) {
        score += 300;
      } else if (lowerBase.endsWith('.iso')) {
        score += 200;
      }

      final dedupeKey = '$resolvedSlug|${cleanTitle.toLowerCase()}';
      final existing = bestByKey[dedupeKey];
      if (existing != null && score <= existing.score) continue;

      bestByKey[dedupeKey] = (
        score: score,
        item: EmulationGame(
          igdbId: EmulationGame.stableIdFromKey('${resolvedSlug}_$collection|$name'),
          name: cleanTitle,
          canonicalNoIntroName: rawStem,
          summary:
              '$cleanTitle ($resolvedLabel) — arquivo verificado no Internet Archive.',
          genres: ['Retro', resolvedLabel],
          developer: defaultDeveloper,
          releaseYear: null,
          rating: 88,
          platformName: resolvedLabel,
          platformSlug: resolvedSlug,
          region: region,
          crc32: crc.length == 8 ? crc : '',
          estimatedSizeBytes: sizeBytes,
          directRomUrl: directUrl,
        ),
      );
    }

    return bestByKey.values.map((e) => e.item).toList(growable: false);
  }

  static Future<List<EmulationGame>> _runParseArchiveCollectionInIsolate({
    required List<dynamic> rawFiles,
    required String collection,
    required String slug,
    required String platformLabel,
    required String defaultDeveloper,
    required int minValidBytes,
    required List<String> allowedExts,
  }) =>
      Isolate.run(
        () => _parseArchiveCollectionSync(
          rawFiles: rawFiles,
          collection: collection,
          slug: slug,
          platformLabel: platformLabel,
          defaultDeveloper: defaultDeveloper,
          minValidBytes: minValidBytes,
          allowedExts: allowedExts,
        ),
      );

  static Future<List<EmulationGame>> _runParseRetroApiInIsolate({
    required List<dynamic> data,
    required String slug,
    required String platformLabel,
    required String platformDisplay,
    required String defaultDeveloper,
    required int minValidBytes,
  }) =>
      Isolate.run(
        () => _parseRetroApiPayloadSync(
          data: data,
          slug: slug,
          platformLabel: platformLabel,
          platformDisplay: platformDisplay,
          defaultDeveloper: defaultDeveloper,
          minValidBytes: minValidBytes,
        ),
      );

  Future<List<EmulationGame>> _fetchRetroOnly({
    required String slug,
    required ({
      String url,
      String platformLabel,
      String platformDisplay,
      String defaultDeveloper,
    }) querySpec,
    required int minValidBytes,
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _dio.get<dynamic>(
        querySpec.url,
        cancelToken: cancelToken,
      );
      if (!_isSuccessStatus(res.statusCode)) {
        debugPrint(
          '[IgdbSteamGridService] RetroAPI retornou HTTP ${res.statusCode} para $slug.',
        );
        return const [];
      }
      final data = res.data;
      if (data is! List) return const [];
      return await _runParseRetroApiInIsolate(
        data: data,
        slug: slug,
        platformLabel: querySpec.platformLabel,
        platformDisplay: querySpec.platformDisplay,
        defaultDeveloper: querySpec.defaultDeveloper,
        minValidBytes: minValidBytes,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      debugPrint(
        '[IgdbSteamGridService] Erro RetroAPI ($slug): HTTP ${e.response?.statusCode ?? e.type}',
      );
      return const [];
    } catch (e) {
      debugPrint('[IgdbSteamGridService] Falha RetroAPI ($slug): $e');
      return const [];
    }
  }

  Future<List<EmulationGame>> _loadAndParseRetroApiPlatform({
    required String slug,
    required ({
      String url,
      String platformLabel,
      String platformDisplay,
      String defaultDeveloper,
    }) querySpec,
    CancelToken? cancelToken,
  }) async {
    try {
      final minValidBytes = RomDownloadService.minBytesForPlatform(slug);

      final batches = await Future.wait([
        _fetchRetroOnly(
          slug: slug,
          querySpec: querySpec,
          minValidBytes: minValidBytes,
          cancelToken: cancelToken,
        ),
        _fetchArchiveCollectionGames(
          slug: slug,
          platformLabel: querySpec.platformLabel,
          defaultDeveloper: querySpec.defaultDeveloper,
          cancelToken: cancelToken,
        ),
      ]);

      final retroGames = batches[0];
      final archiveGames = batches[1];

      final archiveByNorm = <String, EmulationGame>{};
      final archiveByStem = <String, EmulationGame>{};
      for (final g in archiveGames) {
        final norm = EmulationGame.normalizeSearchText(g.name);
        if (norm.isNotEmpty) archiveByNorm[norm] = g;
        final stem = g.canonicalNoIntroName.toLowerCase();
        if (stem.isNotEmpty) archiveByStem[stem] = g;
      }

      final merged = <EmulationGame>[];
      final seenNorm = <String>{};

      for (final g in retroGames) {
        final norm = EmulationGame.normalizeSearchText(g.name);
        final stem = g.canonicalNoIntroName
            .replaceAll(RegExp(r'\.(zip|7z)$', caseSensitive: false), '')
            .toLowerCase();
        final archiveMatch = archiveByNorm[norm] ?? archiveByStem[stem];
        if (archiveMatch != null) {
          merged.add(
            g.copyWith(
              estimatedSizeBytes: archiveMatch.estimatedSizeBytes,
              directRomUrl: archiveMatch.directRomUrl,
              crc32: g.crc32.isNotEmpty ? g.crc32 : archiveMatch.crc32,
            ),
          );
          seenNorm.add(norm);
        } else {
          // Se já temos acervo Archive real com tamanhos válidos para a plataforma,
          // evita poluir com entradas RetroAPI sem tamanho nem mirror confiável.
          if (archiveGames.length >= 15 && !g.hasKnownSize) {
            continue;
          }
          merged.add(g);
          seenNorm.add(norm);
        }
      }

      for (final g in archiveGames) {
        final norm = EmulationGame.normalizeSearchText(g.name);
        if (seenNorm.add(norm)) {
          merged.add(g);
        }
      }

      _retroApiCache[slug] = merged;
      return merged;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      return const [];
    } catch (e) {
      debugPrint('[IgdbSteamGridService] Falha catálogo ($slug): $e');
      return const [];
    }
  }

  static List<EmulationGame> _parseRetroApiPayloadSync({
    required List<dynamic> data,
    required String slug,
    required String platformLabel,
    required String platformDisplay,
    required String defaultDeveloper,
    required int minValidBytes,
  }) {
    final Map<String, ({int score, bool preferred, EmulationGame item})>
        bestByKey = {};
    final parenRegex = RegExp(r'\s*\([^)]*\)');
    final isArcadeSlug = slug == 'neogeo' ||
        slug == 'cps1' ||
        slug == 'cps2' ||
        slug == 'mame' ||
        slug == 'arcade';

    for (final group in data) {
      if (group is! List) continue;
      for (final raw in group) {
        if (raw is! Map) continue;
        final rawName = (raw['name'] as String?)?.trim() ?? '';
        if (rawName.isEmpty) continue;

        final lowerName = rawName.toLowerCase();
        if (lowerName.contains('(beta') ||
            lowerName.contains('(proto') ||
            lowerName.contains('(demo') ||
            lowerName.contains('(sample') ||
            lowerName.contains('(pirate') ||
            lowerName.contains('(trial') ||
            lowerName.contains('(kiosk') ||
            lowerName.contains('(taikenban') ||
            lowerName.contains('(preview') ||
            lowerName.contains('[b]') ||
            lowerName.contains('[h') ||
            lowerName.contains('[o') ||
            lowerName.contains('[f') ||
            lowerName.contains('[t')) {
          continue;
        }

        final isPreferredRegion = rawName.contains('(USA') ||
            rawName.contains('(World') ||
            rawName.contains('(Europe') ||
            rawName.contains('(Euro') ||
            !rawName.contains('(');

        final cleanDisplayTitle = rawName
            .replaceAll(parenRegex, '')
            .replaceAll(' - ', ': ')
            .trim();
        if (cleanDisplayTitle.isEmpty) continue;

        final dedupeKey = '${slug}_${cleanDisplayTitle.toLowerCase()}';
        var romName = (raw['rom_name'] as String?) ?? '$rawName.rom';
        final rawSize = _parseByteSize(raw['size']);
        var sizeBytes = rawSize > 0 ? rawSize : 0;

        final lowerRom = romName.toLowerCase();
        if (_isTrackSecondaryOrBadDump(rawName, lowerRom)) {
          continue;
        }
        if (!isArcadeSlug && sizeBytes > 0 && sizeBytes < minValidBytes) {
          continue;
        }
        if (isArcadeSlug && sizeBytes > 0 && sizeBytes < 32 * 1024) {
          continue;
        }

        int score = 0;
        if (sizeBytes >= minValidBytes) {
          score += 10000;
        } else if (sizeBytes > 0) {
          score += 2000;
        }

        if (isArcadeSlug) {
          final resolvedFbneo = RomDownloadService.resolveCanonicalFbneoParent(
            lowerRom,
            gameTitle: cleanDisplayTitle,
          );
          final rawStem = lowerRom.replaceAll(
            RegExp(r'\.(zip|7z)$', caseSensitive: false),
            '',
          );
          if (resolvedFbneo != null && rawStem == resolvedFbneo.parentStem) {
            score += 50000;
          }
          // Prefer non-merged full romsets over tiny split clone zips
          score += (sizeBytes ~/ 65536).clamp(0, 8000);
          if (resolvedFbneo != null &&
              (slug == 'cps1' || slug == 'cps2') &&
              (lowerRom.endsWith('.zip') || lowerRom.endsWith('.7z'))) {
            if (rawStem != resolvedFbneo.parentStem) {
              // Clone ZIPs listam apenas arquivos delta (poucos KB), nao o tamanho do parent
              sizeBytes = 0;
            }
            romName = '${resolvedFbneo.parentStem}.zip';
          }
        }

        if (rawName.contains('(USA')) {
          score += isArcadeSlug ? 350 : 500;
        } else if (rawName.contains('(World')) {
          score += isArcadeSlug ? 450 : 400;
        } else if (rawName.contains('(Europe') || rawName.contains('(Euro')) {
          score += isArcadeSlug ? 400 : 300;
        } else if (!rawName.contains('(')) {
          score += 200;
        }
        score += 50;

        final existing = bestByKey[dedupeKey];
        if (existing != null && score <= existing.score) {
          continue;
        }

        final crc = ((raw['crc'] as String?) ?? '').toUpperCase();
        final developer = (raw['developer'] as String?) ??
            (raw['publisher'] as String?) ??
            defaultDeveloper;
        final rawGenre = (raw['genre'] as String?)?.trim();
        final genre =
            (rawGenre != null && rawGenre.isNotEmpty) ? rawGenre : 'Retro';
        final releaseYear = (raw['releaseyear'] as num?)?.toInt();
        final rawDesc = (raw['description'] as String?)?.trim();
        final region = rawName.contains('(USA')
            ? 'USA'
            : (rawName.contains('(Europe') || rawName.contains('(Euro'))
                ? 'EUR'
                : 'WORLD';

        final idSeed = EmulationGame.stableIdFromKey('${slug}_$rawName');

        final item = EmulationGame(
          igdbId: idSeed,
          name: cleanDisplayTitle,
          canonicalNoIntroName: rawName,
          summary: (rawDesc != null && rawDesc.length > 12)
              ? rawDesc
              : '$cleanDisplayTitle para $platformDisplay ($developer${releaseYear != null ? ", $releaseYear" : ""}).',
          genres: [genre, platformLabel],
          developer: developer,
          releaseYear: releaseYear,
          rating: 89,
          platformName: platformLabel,
          platformSlug: slug,
          region: region,
          crc32: crc,
          estimatedSizeBytes: sizeBytes,
          directRomUrl: 'retroapi://$slug/${Uri.encodeComponent(romName)}',
        );

        bestByKey[dedupeKey] = (
          score: score,
          preferred: isPreferredRegion,
          item: item,
        );
      }
    }

    return <EmulationGame>[
      for (final entry in bestByKey.values)
        if (entry.preferred) entry.item,
      for (final entry in bestByKey.values)
        if (!entry.preferred) entry.item,
    ];
  }

  ({
    String url,
    String platformLabel,
    String platformDisplay,
    String defaultDeveloper,
  })? _retroApiEndpointForPlatform(String slug) {
    switch (slug) {
      case 'psp':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/psp/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'PSP',
          platformDisplay: 'PlayStation Portable',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'ps1':
      case 'psx':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/psx/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'PS1',
          platformDisplay: 'Sony PlayStation',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'snes':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/snes/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'SNES',
          platformDisplay: 'Super Nintendo',
          defaultDeveloper: 'Nintendo',
        );
      case 'gba':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gba/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GBA',
          platformDisplay: 'Game Boy Advance',
          defaultDeveloper: 'Nintendo',
        );
      case 'nds':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/nds/releaseyear/2005,2006,2007,2008,2009,2010',
          platformLabel: 'NDS',
          platformDisplay: 'Nintendo DS',
          defaultDeveloper: 'Nintendo',
        );
      case 'n64':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/n64/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'N64',
          platformDisplay: 'Nintendo 64',
          defaultDeveloper: 'Nintendo',
        );
      case 'md':
      case 'genesis':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/megadrive/genre/Action,Adventure,RPG,Fighting,Racing,Platform,Shooter',
          platformLabel: 'MEGA DRIVE',
          platformDisplay: 'Sega Mega Drive',
          defaultDeveloper: 'Sega',
        );
      case 'nes':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/nes/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'NES',
          platformDisplay: 'Nintendo Entertainment System',
          defaultDeveloper: 'Nintendo',
        );
      case 'gbc':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gbc/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GBC',
          platformDisplay: 'Game Boy Color',
          defaultDeveloper: 'Nintendo',
        );
      case 'gamegear':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gamegear/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GAME GEAR',
          platformDisplay: 'Sega Game Gear',
          defaultDeveloper: 'Sega',
        );
      case 'neogeo':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/SNK',
          platformLabel: 'NEO GEO',
          platformDisplay: 'SNK Neo Geo',
          defaultDeveloper: 'SNK',
        );
      case 'cps1':
      case 'cps2':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/Capcom',
          platformLabel: 'CPS1 / CPS2',
          platformDisplay: 'Capcom Play System',
          defaultDeveloper: 'Capcom',
        );
      case 'mame':
      case 'arcade':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/Konami,Namco,Sega,Taito,Irem',
          platformLabel: 'ARCADE',
          platformDisplay: 'MAME Arcade',
          defaultDeveloper: 'Arcade',
        );
      case 'dreamcast':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/dreamcast/releaseyear/1999,2000,2001',
          platformLabel: 'DREAMCAST',
          platformDisplay: 'Sega Dreamcast',
          defaultDeveloper: 'Sega',
        );
      case 'ps2':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/ps2/releaseyear/2000,2001,2002,2003,2004,2005,2006',
          platformLabel: 'PS2',
          platformDisplay: 'Sony PlayStation 2',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'gamecube':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gamecube/releaseyear/2001,2002,2003,2004,2005,2006',
          platformLabel: 'GAMECUBE',
          platformDisplay: 'Nintendo GameCube',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case 'wii':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/wii/releaseyear/2006,2007,2008,2009,2010,2011',
          platformLabel: 'WII',
          platformDisplay: 'Nintendo Wii',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case '3ds':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/3ds/releaseyear/2011,2012,2013,2014,2015,2016,2017',
          platformLabel: '3DS',
          platformDisplay: 'Nintendo 3DS',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case 'ps3':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/ps3/releaseyear/2006,2007,2008,2009,2010,2011,2012',
          platformLabel: 'PS3',
          platformDisplay: 'Sony PlayStation 3',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'saturn':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/saturn/releaseyear/1995,1996,1997,1998',
          platformLabel: 'SATURN',
          platformDisplay: 'Sega Saturn',
          defaultDeveloper: 'Sega / Third-Party',
        );
      case 'pce':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/pce/genre/Action,Adventure,RPG,Fighting,Racing,Platform,Shooter',
          platformLabel: 'PC ENGINE',
          platformDisplay: 'NEC PC Engine',
          defaultDeveloper: 'NEC / Hudson Soft',
        );
      case 'gb':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gb/genre/Action,Adventure,RPG,Fighting,Platform,Puzzle',
          platformLabel: 'GAME BOY',
          platformDisplay: 'Nintendo Game Boy',
          defaultDeveloper: 'Nintendo',
        );
      case 'mastersystem':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mastersystem/genre/Action,Adventure,RPG,Platform,Shooter',
          platformLabel: 'MASTER SYSTEM',
          platformDisplay: 'Sega Master System',
          defaultDeveloper: 'Sega',
        );
      default:
        return null;
    }
  }

  /// Sincroniza jogos de uma instância RomM real (https://docs.romm.app/latest/)
  /// usando o endpoint oficial `GET {baseUrl}/api/roms`
  Future<List<EmulationGame>> fetchFromRommServer({
    required String serverUrl,
    String apiToken = '',
    String? platformSlug,
    String? searchTerm,
    CancelToken? cancelToken,
  }) async {
    final cleanBase = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanBase.isEmpty) return const [];

    try {
      final headers = <String, String>{
        'Accept': 'application/json',
        if (apiToken.trim().isNotEmpty)
          'Authorization': apiToken.trim().startsWith('Basic ') ||
                  apiToken.trim().startsWith('Bearer ')
              ? apiToken.trim()
              : 'Bearer ${apiToken.trim()}',
      };

      final queryParams = <String, dynamic>{
        'limit': 150,
        if (searchTerm != null && searchTerm.trim().isNotEmpty)
          'search_term': searchTerm.trim(),
      };

      final res = await _dio.get<dynamic>(
        '$cleanBase/api/roms',
        queryParameters: queryParams,
        cancelToken: cancelToken,
        options: Options(headers: headers),
      );
      if (!_isSuccessStatus(res.statusCode)) {
        debugPrint(
          '[IgdbSteamGridService] RomM retornou HTTP ${res.statusCode} em $cleanBase/api/roms.',
        );
        return const [];
      }

      final rawItems = res.data is Map<String, dynamic>
          ? ((res.data as Map<String, dynamic>)['items'] as List<dynamic>? ??
              const [])
          : (res.data is List<dynamic> ? res.data as List<dynamic> : const []);

      final List<EmulationGame> rommGames = [];
      for (final raw in rawItems.whereType<Map<String, dynamic>>()) {
        final id = (raw['id'] as num?)?.toInt() ??
            EmulationGame.stableIdFromKey(
              'romm|$cleanBase|${raw['fs_name'] ?? raw['name'] ?? rommGames.length}',
            );
        final name = (raw['name'] as String?) ??
            (raw['fs_name_no_ext'] as String?) ??
            'ROM #$id';
        final fsName = (raw['fs_name'] as String?) ?? '$name.rom';
        final fsNameNoExt = (raw['fs_name_no_ext'] as String?) ?? name;
        final pSlugRaw =
            ((raw['platform_slug'] ?? raw['p_slug'] ?? 'gba') as String)
                .toLowerCase();
        final mapped = _normalizeRommPlatform(pSlugRaw);
        if (platformSlug != null &&
            platformSlug != 'todos' &&
            mapped.slug != platformSlug.toLowerCase()) {
          continue;
        }

        final sizeBytes = _parseByteSize(raw['fs_size_bytes']);
        final crc =
            ((raw['crc_hash'] ?? raw['md5_hash'] ?? '') as String).toUpperCase();
        final summary = (raw['summary'] as String?)?.trim().isNotEmpty == true
            ? (raw['summary'] as String)
            : 'Jogo sincronizado da sua biblioteca RomM (${mapped.name}).';
        final coverUrl = (raw['url_cover'] as String?) ??
            (raw['path_cover_large'] != null
                ? '$cleanBase/${raw['path_cover_large']}'
                : null);

        final directDownloadUrl =
            '$cleanBase/api/roms/$id/content/${Uri.encodeComponent(fsName)}';

        rommGames.add(
          EmulationGame(
            igdbId: (raw['igdb_id'] as num?)?.toInt() ?? (900000 + id),
            name: name,
            canonicalNoIntroName: fsNameNoExt,
            summary: summary,
            genres: ((raw['genres'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList()) ??
                const ['Retro'],
            developer: ((raw['companies'] as List<dynamic>?)?.isNotEmpty == true)
                ? raw['companies'].first.toString()
                : 'RomM Library',
            releaseYear: (raw['first_release_date'] as num?) != null
                ? DateTime.fromMillisecondsSinceEpoch(
                        (raw['first_release_date'] as num).toInt() * 1000)
                    .year
                : null,
            rating: (raw['average_rating'] as num?)?.toDouble() ?? 88,
            platformName: mapped.name,
            platformSlug: mapped.slug,
            directRomUrl: directDownloadUrl,
            crc32: crc.length > 8 ? crc.substring(0, 8) : crc,
            gridCoverUrl: coverUrl,
            estimatedSizeBytes: sizeBytes,
          ),
        );
      }
      return rommGames;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      debugPrint(
        '[IgdbSteamGridService] RomM HTTP error (${e.response?.statusCode}): ${e.message}',
      );
      return const [];
    } catch (e) {
      debugPrint('[IgdbSteamGridService] RomM unexpected error: $e');
      return const [];
    }
  }

  ({String name, String slug}) _normalizeRommPlatform(String rawSlug) {
    final s = rawSlug.toLowerCase();
    if (s.contains('switch') || s == 'nsw') {
      return (name: 'SWITCH', slug: 'switch');
    }
    if (s.contains('psp') || s.contains('playstation-portable')) {
      return (name: 'PSP', slug: 'psp');
    }
    if (s == 'ps3' || s.contains('playstation-3') || s.contains('ps3')) {
      return (name: 'PS3', slug: 'ps3');
    }
    if (s == 'ps2' || s.contains('playstation-2') || s.contains('ps2')) {
      return (name: 'PS2', slug: 'ps2');
    }
    if (s == 'psx' || s == 'ps1' || s == 'playstation') {
      return (name: 'PS1', slug: 'ps1');
    }
    if (s.contains('gamecube') || s == 'gc' || s == 'ngc') {
      return (name: 'GAMECUBE', slug: 'gamecube');
    }
    if (s == 'wii' || s.contains('nintendo-wii')) {
      return (name: 'WII', slug: 'wii');
    }
    if (s.contains('3ds') || s.contains('n3ds')) {
      return (name: '3DS', slug: '3ds');
    }
    if (s.contains('snes') || s.contains('sfam')) {
      return (name: 'SNES', slug: 'snes');
    }
    if (s == 'nes' || s == 'famicom') {
      return (name: 'NES', slug: 'nes');
    }
    if (s.contains('n64') || s.contains('nintendo-64')) {
      return (name: 'N64', slug: 'n64');
    }
    if (s.contains('nds') || s.contains('nintendo-ds')) {
      return (name: 'NDS', slug: 'nds');
    }
    if (s.contains('saturn')) {
      return (name: 'SATURN', slug: 'saturn');
    }
    if (s.contains('pce') ||
        s.contains('pc-engine') ||
        s.contains('turbografx') ||
        s.contains('tg16')) {
      return (name: 'PC ENGINE', slug: 'pce');
    }
    if (s.contains('mastersystem') ||
        s.contains('master-system') ||
        s == 'sms') {
      return (name: 'MASTER SYSTEM', slug: 'mastersystem');
    }
    if (s.contains('genesis') || s.contains('megadrive') || s == 'md') {
      return (name: 'MEGA DRIVE', slug: 'md');
    }
    if (s.contains('gamegear') || s.contains('game-gear') || s == 'gg') {
      return (name: 'GAME GEAR', slug: 'gamegear');
    }
    if (s.contains('neogeo') || s.contains('neo-geo')) {
      return (name: 'NEO GEO', slug: 'neogeo');
    }
    if (s.contains('cps1') || s.contains('cps2') || s.contains('cps')) {
      return (name: 'CPS1 / CPS2', slug: 'cps1');
    }
    if (s.contains('mame') || s.contains('arcade') || s.contains('fbneo')) {
      return (name: 'ARCADE', slug: 'mame');
    }
    if (s.contains('dreamcast') || s == 'dc') {
      return (name: 'DREAMCAST', slug: 'dreamcast');
    }
    if (s.contains('gbc') || s.contains('game-boy-color')) {
      return (name: 'GBC', slug: 'gbc');
    }
    if (s == 'gb' || s == 'game-boy' || s == 'gameboy') {
      return (name: 'GAME BOY', slug: 'gb');
    }
    return (name: 'GBA', slug: 'gba');
  }


  static String _canonicalPlatformSlug(String raw) {
    final s = raw.trim().toLowerCase();
    switch (s) {
      case 'psx':
        return 'ps1';
      case 'genesis':
        return 'md';
      case 'arcade':
        return 'mame';
      default:
        return s;
    }
  }

  static bool _matchesPlatformFilter(EmulationGame g, String? platformFilter) {
    if (platformFilter == null || platformFilter.toUpperCase() == 'TODOS') {
      return true;
    }
    final target = _canonicalPlatformSlug(platformFilter);
    return g.platformName.toUpperCase() == platformFilter.toUpperCase() ||
        _canonicalPlatformSlug(g.platformSlug) == target;
  }

  static String _baseComparableTitle(String raw) {
    final stripped = raw
        .replaceAll(
          RegExp(
            r'^(?:ps[123]|psx|psp|wii|gc|gamecube|nds|3ds|gba|snes|nes|n64|dreamcast|saturn)\s*[-:|]\s*',
            caseSensitive: false,
          ),
          '',
        )
        .replaceAll(RegExp(r'\([^)]*\)'), ' ')
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ');
    return EmulationGame.normalizeSearchText(stripped);
  }

  static bool _containsAllTokens(String haystack, List<String> tokens) {
    if (haystack.isEmpty || tokens.isEmpty) return false;
    final words = haystack.split(' ');
    for (final t in tokens) {
      final found = words.any((w) => w == t || w.startsWith(t)) ||
          haystack.contains(t);
      if (!found) return false;
    }
    return true;
  }

  static ({
    String normTitle,
    String baseTitle,
    String normCanonical,
    String metaHaystack,
  }) _indexedSearchTerms(EmulationGame g) {
    final key = Object.hash(g.igdbId, g.name, g.platformSlug);
    final cached = _searchIndexCache[key];
    if (cached != null) return cached;
    final entry = (
      normTitle: EmulationGame.normalizeSearchText(g.name),
      baseTitle: _baseComparableTitle(g.name),
      normCanonical: EmulationGame.normalizeSearchText(g.canonicalNoIntroName),
      metaHaystack: EmulationGame.normalizeSearchText(
        '${g.developer} ${g.platformName} ${g.fullConsoleName} ${g.genres.join(" ")}',
      ),
    );
    _searchIndexCache[key] = entry;
    return entry;
  }

  static int _searchRelevanceScore(
    EmulationGame g,
    String normQuery,
    List<String> queryTokens, {
    int sourceBonus = 0,
  }) {
    if (normQuery.isEmpty) {
      return 1 + sourceBonus + (g.hasKnownSize ? 10 : 0);
    }
    final terms = _indexedSearchTerms(g);
    final normTitle = terms.normTitle;
    final baseTitle = terms.baseTitle;
    final normCanonical = terms.normCanonical;

    int score = 0;
    if (normTitle == normQuery || baseTitle == normQuery) {
      score = 1000;
    } else if (normTitle.startsWith(normQuery) ||
        baseTitle.startsWith(normQuery)) {
      score = 850;
    } else if (normTitle.contains(normQuery) ||
        baseTitle.contains(normQuery) ||
        normCanonical.contains(normQuery)) {
      score = 700;
    } else if (queryTokens.isNotEmpty &&
        (_containsAllTokens(normTitle, queryTokens) ||
            _containsAllTokens(normCanonical, queryTokens))) {
      score = 500;
    } else {
      final metaHaystack = terms.metaHaystack;
      if (metaHaystack.contains(normQuery) ||
          _containsAllTokens(metaHaystack, queryTokens)) {
        score = 250;
      }
    }

    if (score == 0) return 0;
    score += sourceBonus;
    if (g.hasKnownSize) score += 30;
    if (g.region == 'USA') score += 10;
    return score;
  }

  /// Busca jogos combinando RomM Server, Catálogo Integrado Multi-Console,
  /// RetroAPI (`retroapi.konsumer.workers.dev`) e Internet Archive.
  Future<List<EmulationGame>> searchGames(
    String query, {
    String? platformFilter,
    String rommServerUrl = '',
    String rommApiToken = '',
    CancelToken? cancelToken,
  }) async {
    if (_isDisposed) return const [];

    final previousToken = _activeSearchCancelToken;
    if (previousToken != null && !previousToken.isCancelled) {
      previousToken.cancel('Superseded by new search');
    }

    final searchToken = CancelToken();
    _activeSearchCancelToken = searchToken;
    if (cancelToken != null) {
      if (cancelToken.isCancelled) {
        if (!searchToken.isCancelled) {
          searchToken.cancel(cancelToken.cancelError?.error ?? 'Cancelled');
        }
        return const [];
      }
      unawaited(
        cancelToken.whenCancel.then((err) {
          if (!searchToken.isCancelled) {
            searchToken.cancel(err.error);
          }
        }),
      );
    }

    try {
      final sanitized = query.replaceAll('"', '').trim();
      final normQuery = EmulationGame.normalizeSearchText(sanitized);
      final queryTokens =
          normQuery.split(' ').where((t) => t.isNotEmpty).toList();

      final Map<String, ({EmulationGame game, int score})> byKey = {};

      void addOrMerge(EmulationGame candidate, {int sourceBonus = 0}) {
        if (!_matchesPlatformFilter(candidate, platformFilter)) return;
        final score = _searchRelevanceScore(
          candidate,
          normQuery,
          queryTokens,
          sourceBonus: sourceBonus,
        );
        if (score <= 0) return;

        final baseTitle = _baseComparableTitle(candidate.name);
        final key =
            '${_canonicalPlatformSlug(candidate.platformSlug)}|${baseTitle.isNotEmpty ? baseTitle : EmulationGame.normalizeSearchText(candidate.name)}';

        final existing = byKey[key];
        if (existing == null) {
          byKey[key] = (game: candidate, score: score);
          return;
        }

        var merged = existing.game;
        var bestScore = existing.score;
        if (!merged.hasKnownSize && candidate.hasKnownSize) {
          merged = merged.copyWith(
            estimatedSizeBytes: candidate.estimatedSizeBytes,
          );
        } else if (score > existing.score &&
            (candidate.hasKnownSize || !merged.hasKnownSize)) {
          merged = candidate;
          bestScore = score;
        }
        byKey[key] = (game: merged, score: bestScore);
      }

      // 1. Servidor RomM próprio (se configurado)
      if (rommServerUrl.trim().isNotEmpty) {
        final fromRomm = await fetchFromRommServer(
          serverUrl: rommServerUrl,
          apiToken: rommApiToken,
          platformSlug: platformFilter,
          searchTerm: sanitized,
          cancelToken: searchToken,
        );
        for (final g in fromRomm) {
          addOrMerge(g, sourceBonus: 120);
        }
      }
      if (searchToken.isCancelled || _isDisposed) return const [];

      // 2. Catálogo local + cache completo da RetroAPI
      for (final g in kVerifiedRealGamesCatalog) {
        addOrMerge(g, sourceBonus: 100);
      }
      for (final list in _retroApiCache.values) {
        for (final g in list) {
          addOrMerge(g, sourceBonus: 80);
        }
      }

      // 3. Se uma plataforma específica estiver selecionada e ainda não estiver no cache,
      // carrega toda a plataforma na RetroAPI e busca em todo o catálogo em cache
      if (platformFilter != null && platformFilter.toLowerCase() != 'todos') {
        final slug = platformFilter.toLowerCase();
        if (!_retroApiCache.containsKey(slug)) {
          await fetchFromRetroApiPlatform(
            slug,
            maxPerPlatform: 260,
            cancelToken: searchToken,
          );
        }
        if (searchToken.isCancelled || _isDisposed) return const [];
        final cachedPlatformGames = _retroApiCache[slug] ?? const [];
        for (final g in cachedPlatformGames) {
          addOrMerge(g, sourceBonus: 80);
        }
      }

      // 4. Se houver termo de busca, consulta também o Internet Archive desbloqueado
      if (sanitized.isNotEmpty &&
          (!Platform.environment.containsKey('FLUTTER_TEST') ||
              _hasCustomDio)) {
        final archiveMatches = await _searchArchiveOrgRoms(
          sanitized,
          platformFilter: platformFilter,
          cancelToken: searchToken,
        );
        for (final m in archiveMatches) {
          addOrMerge(m, sourceBonus: 0);
        }
      }
      if (searchToken.isCancelled || _isDisposed) return const [];

      final ranked = byKey.values.toList()
        ..sort((a, b) {
          final scoreCmp = b.score.compareTo(a.score);
          if (scoreCmp != 0) return scoreCmp;
          if (a.game.hasKnownSize != b.game.hasKnownSize) {
            return a.game.hasKnownSize ? -1 : 1;
          }
          return a.game.name.compareTo(b.game.name);
        });

      return await Future.wait(
        ranked.map(
          (e) => enrichWithSteamGridDbArt(e.game, cancelToken: searchToken),
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) {
        return const [];
      }
      debugPrint(
        '[IgdbSteamGridService] searchGames Dio error (${e.response?.statusCode}): ${e.message}',
      );
      return const [];
    } catch (e) {
      debugPrint('[IgdbSteamGridService] searchGames unexpected error: $e');
      return const [];
    } finally {
      if (identical(_activeSearchCancelToken, searchToken)) {
        _activeSearchCancelToken = null;
      }
    }
  }

  String? _archiveSearchHint(String? platformFilter) {
    final p = platformFilter?.toLowerCase() ?? '';
    if (p.isEmpty || p == 'todos') return null;
    switch (p) {
      case 'ps2':
        return '(ps2 OR "playstation 2")';
      case 'ps3':
        return '(ps3 OR "playstation 3")';
      case 'gamecube':
        return '(gamecube OR ngc)';
      case 'wii':
        return '(wii OR nintendo)';
      case '3ds':
        return '(3ds OR "nintendo 3ds")';
      case 'saturn':
        return 'saturn';
      case 'pce':
        return '("pc engine" OR turbografx)';
      case 'gb':
        return '("game boy" OR gameboy)';
      case 'mastersystem':
        return '"master system"';
      case 'md':
        return '(genesis OR "mega drive")';
      case 'gamegear':
        return '"game gear"';
      case 'switch':
        return '(switch OR nsp OR nro)';
      default:
        return p;
    }
  }

  /// Consulta a API pública do Internet Archive priorizando itens desbloqueados
  Future<List<EmulationGame>> _searchArchiveOrgRoms(
    String query, {
    String? platformFilter,
    CancelToken? cancelToken,
  }) async {
    if (_isDisposed || cancelToken?.isCancelled == true) return const [];
    if (Platform.environment.containsKey('FLUTTER_TEST') && !_hasCustomDio) {
      return const [];
    }
    try {
      final hint = _archiveSearchHint(platformFilter);
      final qStr = hint == null
          ? 'title:("$query") AND mediatype:(software) AND NOT access-restricted-item:true'
          : 'title:("$query") AND ($hint) AND mediatype:(software) AND NOT access-restricted-item:true';

      Future<List<dynamic>> queryDocs(String searchQuery) async {
        final res = await _dio.get<Map<String, dynamic>>(
          'https://archive.org/advancedsearch.php',
          queryParameters: {
            'q': searchQuery,
            'fl[]': ['identifier', 'title', 'description', 'year'],
            'rows': '12',
            'page': '1',
            'output': 'json',
          },
          cancelToken: cancelToken,
        );
        if (!_isSuccessStatus(res.statusCode)) {
          debugPrint(
            '[IgdbSteamGridService] Archive.org search HTTP ${res.statusCode} for "$searchQuery"',
          );
          return const [];
        }
        return (res.data?['response'] as Map<String, dynamic>?)?['docs']
                as List<dynamic>? ??
            const [];
      }

      var docs = await queryDocs(qStr);
      if (docs.isEmpty && hint != null) {
        docs = await queryDocs(
          'title:("$query") AND mediatype:(software) AND NOT access-restricted-item:true',
        );
      }

      final docMaps = docs.whereType<Map<String, dynamic>>().take(10).toList();
      final metaResponses = await Future.wait(
        docMaps.map((doc) async {
          final id = doc['identifier'] as String?;
          if (id == null) return null;
          return _archiveMetaSemaphore.run(() async {
            if (_isDisposed || cancelToken?.isCancelled == true) return null;
            try {
              final metaRes = await _dio.get<Map<String, dynamic>>(
                'https://archive.org/metadata/$id',
                cancelToken: cancelToken,
              );
              if (!_isSuccessStatus(metaRes.statusCode)) {
                debugPrint(
                  '[IgdbSteamGridService] Archive.org metadata HTTP ${metaRes.statusCode} for $id',
                );
                return null;
              }
              return (doc: doc, id: id, data: metaRes.data);
            } on DioException catch (e) {
              if (e.type == DioExceptionType.cancel) rethrow;
              debugPrint(
                '[IgdbSteamGridService] Archive.org metadata error for $id (${e.response?.statusCode}): ${e.message}',
              );
              return null;
            } catch (e) {
              debugPrint(
                '[IgdbSteamGridService] Archive.org metadata unexpected error for $id: $e',
              );
              return null;
            }
          }, cancelToken: cancelToken);
        }),
      );

      final hasSpecificFilter =
          platformFilter != null && platformFilter.toUpperCase() != 'TODOS';
      final filterSlug =
          hasSpecificFilter ? _canonicalPlatformSlug(platformFilter) : '';
      final normQuery = EmulationGame.normalizeSearchText(query);
      final queryTokens =
          normQuery.split(' ').where((t) => t.isNotEmpty).toList();

      final List<EmulationGame> found = [];
      for (final entry in metaResponses) {
        if (entry == null) continue;
        final itemTitle = (entry.doc['title'] as String?)?.trim() ?? '';
        if (RomDownloadService.isNonFullGameRelease(
              itemTitle,
              gameTitle: query,
            ) ||
            RomDownloadService.isNonFullGameRelease(
              entry.id,
              gameTitle: query,
            )) {
          continue;
        }

        final fileMaps =
            ((entry.data?['files'] as List<dynamic>?) ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList();
        if (fileMaps.isEmpty) continue;

        final picked = _pickBestSearchFileForArchiveItem(
          files: fileMaps,
          entryId: entry.id,
          itemTitle: itemTitle,
          query: query,
          normQuery: normQuery,
          queryTokens: queryTokens,
          filterSlug: hasSpecificFilter ? filterSlug : null,
        );
        if (picked == null) continue;

        final encodedPath = picked.fileName
            .split('/')
            .map(Uri.encodeComponent)
            .join('/');
        final directUrl =
            'https://archive.org/download/${entry.id}/$encodedPath';

        final fileTitleClean = picked.fileName
            .split('/')
            .last
            .replaceAll(RegExp(r'\.[^.]+$'), '')
            .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
            .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
            .replaceAll('_', ' ')
            .trim();

        final looksLikeSeriesPack = RegExp(
          r'\b(series|complete|romset|anthology|packs?)\b',
          caseSensitive: false,
        ).hasMatch(itemTitle);
        final cleanTitle =
            (looksLikeSeriesPack || itemTitle.isEmpty) &&
                    fileTitleClean.isNotEmpty
                ? fileTitleClean
                : itemTitle;

        found.add(
          EmulationGame(
            igdbId: EmulationGame.stableIdFromKey(
              'archive|${picked.platform.slug}|${entry.id}',
            ),
            name: cleanTitle,
            canonicalNoIntroName: picked.fileName
                .split('/')
                .last
                .replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
            summary: (entry.doc['description']?.toString()) ??
                'Edição preservada compatível com o catálogo (${picked.platform.name}).',
            genres: const ['Retro', 'Console'],
            developer: 'Lançamento Original',
            releaseYear: int.tryParse('${entry.doc['year'] ?? ''}'),
            rating: 88,
            platformName: picked.platform.name,
            platformSlug: picked.platform.slug,
            directRomUrl: directUrl,
            crc32: picked.crc32,
            estimatedSizeBytes: picked.sizeBytes,
          ),
        );
      }
      return found;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      debugPrint(
        '[IgdbSteamGridService] Archive.org HTTP error (${e.response?.statusCode}): ${e.message}',
      );
      return const [];
    } catch (e) {
      debugPrint('[IgdbSteamGridService] Archive.org unexpected error: $e');
      return const [];
    }
  }

  ({
    String fileName,
    int sizeBytes,
    String crc32,
    ({String name, String slug}) platform,
  })? _pickBestSearchFileForArchiveItem({
    required List<Map<String, dynamic>> files,
    required String entryId,
    required String itemTitle,
    required String query,
    required String normQuery,
    required List<String> queryTokens,
    String? filterSlug,
  }) {
    if (filterSlug != null) {
      final picked = RomDownloadService.pickBestArchiveFileEntry(
        files: files,
        platformSlug: filterSlug,
        gameTitle: query,
        requireTitleMatch: false,
        requireNonZeroSize: true,
        allowRawBinFallback: filterSlug == 'ps1' || filterSlug == 'saturn',
        rejectBetaAndProto: true,
        extraFileFilter: (fileName, sizeBytes) {
          final detected = _detectPlatformFromFileName(
            fileName.toLowerCase(),
            entryId,
            itemTitle: itemTitle,
            sizeBytes: sizeBytes,
          );
          if (detected != null && detected.slug != filterSlug) {
            return false;
          }
          return true;
        },
      );
      if (picked == null) return null;
      final spec = kRommPlatforms.cast<RommPlatformSpec?>().firstWhere(
            (p) => _canonicalPlatformSlug(p!.slug) == filterSlug,
            orElse: () => null,
          );
      final plat = spec != null
          ? (name: spec.shortName, slug: spec.slug)
          : _detectPlatformFromFileName(
                picked.name.toLowerCase(),
                entryId,
                itemTitle: itemTitle,
                sizeBytes: picked.sizeBytes,
              );
      if (plat == null) return null;
      return (
        fileName: picked.name,
        sizeBytes: picked.sizeBytes,
        crc32: picked.crc32,
        platform: plat,
      );
    }

    ({
      String fileName,
      int sizeBytes,
      String crc32,
      ({String name, String slug}) platform,
    })? best;
    int bestScore = -999999;

    const discPlatforms = {
      'ps1',
      'psp',
      'ps2',
      'ps3',
      'gamecube',
      'wii',
      'dreamcast',
      'saturn',
    };

    for (final f in files) {
      final fileName = (f['name'] as String?) ?? '';
      if (fileName.isEmpty) continue;
      final isPrivate = f['private'] == 'true' || f['private'] == true;
      if (isPrivate) continue;
      if (RomDownloadService.isJunkArchiveEntry(fileName, gameTitle: query) ||
          RomDownloadService.isNonFullGameRelease(
            fileName,
            gameTitle: query,
          )) {
        continue;
      }

      final lower = fileName.toLowerCase();
      if (!_validRomExtensions.any(lower.endsWith)) continue;

      final sizeBytes = _parseByteSize(f['size']);
      if (sizeBytes <= 0) continue;

      final plat = _detectPlatformFromFileName(
        lower,
        entryId,
        itemTitle: itemTitle,
        sizeBytes: sizeBytes,
      );
      if (plat == null) continue;

      final minBytes = RomDownloadService.minBytesForPlatform(plat.slug);
      if (sizeBytes < minBytes) continue;

      final allowed = RomDownloadService.allowedExtensionsForPlatform(plat.slug);
      final extAllowed = allowed.any(lower.endsWith) ||
          ((plat.slug == 'ps1' || plat.slug == 'saturn') &&
              lower.endsWith('.bin'));
      if (!extAllowed) continue;

      int score = 0;
      final normFile = _baseComparableTitle(fileName.split('/').last);
      if (normQuery.isNotEmpty && normFile.contains(normQuery)) {
        score += 300;
      } else if (queryTokens.isNotEmpty &&
          _containsAllTokens(normFile, queryTokens)) {
        score += 180;
      }

      if (lower.endsWith('.zip')) {
        score += 50;
      } else if (lower.endsWith('.bin')) {
        score += 20;
      } else {
        score += 150;
      }

      if (lower.contains('(usa)') || lower.contains('(world)')) {
        score += 120;
      } else if (lower.contains('(europe)')) {
        score += 90;
      } else if (lower.contains('(japan)') &&
          !query.toLowerCase().contains('japan')) {
        score -= 150;
      }

      if (lower.contains('[t-') || lower.contains('hack')) {
        score -= 120;
      }

      if (discPlatforms.contains(plat.slug) &&
          sizeBytes >= 100 * 1024 * 1024) {
        score += 100;
      }
      score += (sizeBytes / (100 * 1024 * 1024)).clamp(0, 30).round();

      if (score > bestScore) {
        bestScore = score;
        best = (
          fileName: fileName,
          sizeBytes: sizeBytes,
          crc32: ((f['crc32'] as String?) ?? '').toUpperCase(),
          platform: plat,
        );
      }
    }
    return best;
  }

  ({String name, String slug})? _detectPlatformFromFileName(
    String lowerFile,
    String identifier, {
    String itemTitle = '',
    int sizeBytes = 0,
  }) {
    final fileAndId = '$lowerFile $identifier'.toLowerCase();
    final combined = '$fileAndId $itemTitle'.toLowerCase();
    final allowHandheldSize = sizeBytes <= 0 || sizeBytes <= 32 * 1024 * 1024;

    if (lowerFile.endsWith('.nsp') ||
        lowerFile.endsWith('.xci') ||
        lowerFile.endsWith('.nsz') ||
        lowerFile.endsWith('.xcz') ||
        lowerFile.endsWith('.nro') ||
        lowerFile.endsWith('.nca') ||
        combined.contains('nintendo switch') ||
        RegExp(r'\bswitch\b').hasMatch(combined)) {
      return (name: 'SWITCH', slug: 'switch');
    }
    if (lowerFile.endsWith('.3ds') ||
        lowerFile.endsWith('.cci') ||
        lowerFile.endsWith('.cxi') ||
        combined.contains('nintendo 3ds') ||
        RegExp(r'\b3ds\b').hasMatch(combined)) {
      return (name: '3DS', slug: '3ds');
    }
    if (lowerFile.endsWith('.rvz') ||
        lowerFile.endsWith('.gcz') ||
        lowerFile.endsWith('.gcm') ||
        combined.contains('gamecube')) {
      return (name: 'GAMECUBE', slug: 'gamecube');
    }
    if (lowerFile.endsWith('.wbfs') || RegExp(r'\bwii\b').hasMatch(combined)) {
      return (name: 'WII', slug: 'wii');
    }
    if (lowerFile.endsWith('.pkg') ||
        combined.contains('ps3') ||
        combined.contains('playstation 3')) {
      return (name: 'PS3', slug: 'ps3');
    }
    if (combined.contains('ps2') || combined.contains('playstation 2')) {
      return (name: 'PS2', slug: 'ps2');
    }
    if (combined.contains('psp') ||
        lowerFile.endsWith('.cso') ||
        lowerFile.endsWith('.pbp')) {
      return (name: 'PSP', slug: 'psp');
    }
    if (combined.contains('saturn')) {
      return (name: 'SATURN', slug: 'saturn');
    }
    if (combined.contains('dreamcast')) {
      return (name: 'DREAMCAST', slug: 'dreamcast');
    }
    if (combined.contains('psx') ||
        combined.contains('ps1') ||
        combined.contains('playstation 1')) {
      return (name: 'PS1', slug: 'ps1');
    }
    if (lowerFile.endsWith('.nds') || RegExp(r'\bnds\b').hasMatch(combined)) {
      return (name: 'NDS', slug: 'nds');
    }
    if (lowerFile.endsWith('.z64') ||
        lowerFile.endsWith('.n64') ||
        lowerFile.endsWith('.v64') ||
        combined.contains('n64')) {
      return (name: 'N64', slug: 'n64');
    }
    if (lowerFile.endsWith('.gba') ||
        (allowHandheldSize &&
            (RegExp(r'\bgba\b').hasMatch(fileAndId) ||
                combined.contains('game boy advance')))) {
      return (name: 'GBA', slug: 'gba');
    }
    if (lowerFile.endsWith('.gbc') ||
        (allowHandheldSize && combined.contains('game boy color'))) {
      return (name: 'GBC', slug: 'gbc');
    }
    if (lowerFile.endsWith('.gb') ||
        (allowHandheldSize &&
            RegExp(r'\bgame[\s_-]?boy\b').hasMatch(combined) &&
            !combined.contains('advance') &&
            !combined.contains('color'))) {
      return (name: 'GAME BOY', slug: 'gb');
    }
    if (lowerFile.endsWith('.sfc') ||
        lowerFile.endsWith('.smc') ||
        combined.contains('snes')) {
      return (name: 'SNES', slug: 'snes');
    }
    if (lowerFile.endsWith('.nes') ||
        (allowHandheldSize && RegExp(r'\bnes\b').hasMatch(combined))) {
      return (name: 'NES', slug: 'nes');
    }
    if (lowerFile.endsWith('.md') ||
        lowerFile.endsWith('.gen') ||
        lowerFile.endsWith('.smd') ||
        combined.contains('genesis') ||
        combined.contains('mega drive')) {
      return (name: 'MEGA DRIVE', slug: 'md');
    }
    if (lowerFile.endsWith('.sms') ||
        combined.contains('master system') ||
        combined.contains('mastersystem')) {
      return (name: 'MASTER SYSTEM', slug: 'mastersystem');
    }
    if (lowerFile.endsWith('.gg') || combined.contains('game gear')) {
      return (name: 'GAME GEAR', slug: 'gamegear');
    }
    if (lowerFile.endsWith('.pce') ||
        combined.contains('pc engine') ||
        combined.contains('turbografx')) {
      return (name: 'PC ENGINE', slug: 'pce');
    }
    if (lowerFile.endsWith('.chd')) {
      return sizeBytes > 900 * 1024 * 1024
          ? (name: 'PS2', slug: 'ps2')
          : (name: 'PS1', slug: 'ps1');
    }
    if (lowerFile.endsWith('.iso')) {
      if (sizeBytes > 900 * 1024 * 1024) {
        return (name: 'PS2', slug: 'ps2');
      }
      if (sizeBytes >= 80 * 1024 * 1024) {
        return (name: 'PS1', slug: 'ps1');
      }
    }
    if (lowerFile.endsWith('.bin') && sizeBytes >= 64 * 1024 * 1024) {
      return (name: 'PS1', slug: 'ps1');
    }
    return null;
  }

  Future<EmulationGame> enrichWithSteamGridDbArt(
    EmulationGame game, {
    CancelToken? cancelToken,
  }) async {
    if (steamGridDbApiKey.isEmpty || _isDisposed) return game;
    if (cancelToken?.isCancelled == true) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken?.cancelError?.error,
      );
    }

    final norm = EmulationGame.normalizeSearchText(game.name);
    final cacheKey = norm.isNotEmpty ? norm : game.name.toLowerCase();

    final cached = _sgdbArtCache[cacheKey];
    if (cached != null) {
      return game.copyWith(
        gridCoverUrl: cached.grid,
        heroBannerUrl: cached.hero,
        logoUrl: cached.logo,
      );
    }

    final inFlight = _sgdbInFlight[cacheKey];
    if (inFlight != null) {
      try {
        final art = await (cancelToken != null
            ? Future.any([
                inFlight,
                cancelToken.whenCancel
                    .then<({String? grid, String? hero, String? logo})?>(
                  (err) => throw err,
                ),
              ])
            : inFlight);
        if (art == null) return game;
        return game.copyWith(
          gridCoverUrl: art.grid,
          heroBannerUrl: art.hero,
          logoUrl: art.logo,
        );
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel &&
            cancelToken?.isCancelled == true) {
          rethrow;
        }
        return game;
      } catch (e) {
        debugPrint('[IgdbSteamGridService] SteamGridDB in-flight error: $e');
        return game;
      }
    }

    final Future<({String? grid, String? hero, String? logo})?> future =
        _sgdbSemaphore.run(() async {
      if (_isDisposed || cancelToken?.isCancelled == true) {
        if (cancelToken?.isCancelled == true) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: ''),
            reason: cancelToken?.cancelError?.error,
          );
        }
        return null;
      }
      final headers = {'Authorization': 'Bearer $steamGridDbApiKey'};
      final encodedName = Uri.encodeComponent(game.name);

      final searchRes = await _dio.get<Map<String, dynamic>>(
        'https://www.steamgriddb.com/api/v2/search/autocomplete/$encodedName',
        options: Options(headers: headers),
        cancelToken: cancelToken,
      );
      if (!_isSuccessStatus(searchRes.statusCode)) {
        debugPrint(
          '[IgdbSteamGridService] SteamGridDB search HTTP ${searchRes.statusCode} for ${game.name}',
        );
        return null;
      }

      final searchData = searchRes.data?['data'] as List<dynamic>?;
      if (searchData == null || searchData.isEmpty) {
        const emptyArt = (grid: null, hero: null, logo: null);
        _sgdbArtCache[cacheKey] = emptyArt;
        return emptyArt;
      }

      final firstMatch = searchData.first as Map<String, dynamic>?;
      final sgdbGameId = (firstMatch?['id'] as num?)?.toInt();
      if (sgdbGameId == null) {
        const emptyArt = (grid: null, hero: null, logo: null);
        _sgdbArtCache[cacheKey] = emptyArt;
        return emptyArt;
      }

      final results = await Future.wait([
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/grids/game/$sgdbGameId?dimensions=600x900',
          options: Options(headers: headers),
          cancelToken: cancelToken,
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/heroes/game/$sgdbGameId',
          options: Options(headers: headers),
          cancelToken: cancelToken,
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/logos/game/$sgdbGameId',
          options: Options(headers: headers),
          cancelToken: cancelToken,
        ),
      ]);

      String? firstUrl(Response<Map<String, dynamic>> res) {
        if (!_isSuccessStatus(res.statusCode)) return null;
        final list = res.data?['data'] as List<dynamic>?;
        if (list == null || list.isEmpty) return null;
        return (list.first as Map<String, dynamic>?)?['url'] as String?;
      }

      final art = (
        grid: firstUrl(results[0]),
        hero: firstUrl(results[1]),
        logo: firstUrl(results[2]),
      );
      _sgdbArtCache[cacheKey] = art;
      return art;
    }, cancelToken: cancelToken);

    _sgdbInFlight[cacheKey] = future;
    try {
      final art = await future;
      if (art == null) return game;
      return game.copyWith(
        gridCoverUrl: art.grid,
        heroBannerUrl: art.hero,
        logoUrl: art.logo,
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel && cancelToken != null) rethrow;
      debugPrint(
        '[IgdbSteamGridService] SteamGridDB HTTP error (${e.response?.statusCode}): ${e.message}',
      );
      return game;
    } catch (e) {
      debugPrint('[IgdbSteamGridService] SteamGridDB unexpected error: $e');
      return game;
    } finally {
      if (identical(_sgdbInFlight[cacheKey], future)) {
        unawaited(_sgdbInFlight.remove(cacheKey));
      }
    }
  }

  /// Deduplica lista de jogos em O(N) preservando o primeiro exemplar por `(plataforma, título)`.
  static List<EmulationGame> deduplicateCatalog(Iterable<EmulationGame> games) {
    final List<EmulationGame> out = [];
    final Set<String> seen = {};
    for (final g in games) {
      final key = '${g.platformSlug.toLowerCase()}|${g.name.toLowerCase()}';
      if (seen.add(key)) {
        out.add(g);
      }
    }
    return out;
  }

  /// Carrega o catálogo completo combinando:
  /// 1. Servidor RomM (se configurado)
  /// 2. Catálogo curado integrado
  /// 3. Milhares de jogos reais da RetroAPI (`retroapi.konsumer.workers.dev`)
  Future<List<EmulationGame>> fetchRealCatalog({
    String rommServerUrl = '',
    String rommApiToken = '',
    CancelToken? cancelToken,
  }) async {
    if (_isDisposed || cancelToken?.isCancelled == true) return const [];
    final catalogKey = '${rommServerUrl.trim()}|${rommApiToken.trim()}';
    final existing = _inFlightRealCatalogByKey[catalogKey];
    if (existing != null) {
      return existing;
    }
    final future = _fetchRealCatalogInternal(
      rommServerUrl: rommServerUrl,
      rommApiToken: rommApiToken,
      cancelToken: cancelToken,
    );
    _inFlightRealCatalogByKey[catalogKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlightRealCatalogByKey[catalogKey], future)) {
        unawaited(_inFlightRealCatalogByKey.remove(catalogKey));
      }
    }
  }

  Future<List<EmulationGame>> _fetchRealCatalogInternal({
    String rommServerUrl = '',
    String rommApiToken = '',
    CancelToken? cancelToken,
  }) async {
    if (_isDisposed || cancelToken?.isCancelled == true) return const [];

    final List<EmulationGame> combined = [];
    final Set<String> seenKeys = {};

    void addIfNew(EmulationGame g) {
      final key = '${g.platformSlug.toLowerCase()}|${g.name.toLowerCase()}';
      if (seenKeys.add(key)) {
        combined.add(g);
      }
    }

    try {
      if (rommServerUrl.trim().isNotEmpty) {
        final remote = await fetchFromRommServer(
          serverUrl: rommServerUrl,
          apiToken: rommApiToken,
          cancelToken: cancelToken,
        );
        for (final g in remote) {
          addIfNew(g);
        }
      }

      for (final g in kVerifiedRealGamesCatalog) {
        addIfNew(g);
      }

      if (_isDisposed || cancelToken?.isCancelled == true) return combined;

      // Busca com concorrência limitada na RetroAPI para restaurar catálogo completo (3.000+ jogos)
      const targetPlatforms = [
        'psp',
        'ps1',
        'ps2',
        'gamecube',
        'wii',
        '3ds',
        'ps3',
        'snes',
        'gba',
        'nds',
        'n64',
        'md',
        'saturn',
        'pce',
        'nes',
        'gbc',
        'gb',
        'gamegear',
        'mastersystem',
        'neogeo',
        'cps1',
        'mame',
        'dreamcast',
      ];

      final retroBatches = await Future.wait(
        targetPlatforms.map(
          (slug) => _retroApiSemaphore.run(
            () => fetchFromRetroApiPlatform(
              slug,
              maxPerPlatform: 260,
              cancelToken: cancelToken,
            ),
            cancelToken: cancelToken,
          ),
        ),
      );

      for (final batch in retroBatches) {
        for (final g in batch) {
          addIfNew(g);
        }
      }

      if (steamGridDbApiKey.isEmpty ||
          _isDisposed ||
          cancelToken?.isCancelled == true) {
        return combined;
      }
      return await Future.wait(
        combined.map(
          (g) => enrichWithSteamGridDbArt(g, cancelToken: cancelToken),
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return combined;
      debugPrint(
        '[IgdbSteamGridService] fetchRealCatalog HTTP error (${e.response?.statusCode}): ${e.message}',
      );
      return combined;
    } catch (e) {
      debugPrint('[IgdbSteamGridService] fetchRealCatalog unexpected error: $e');
      return combined;
    }
  }

  /// Libera recursos de rede e cancela buscas em andamento.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    final activeToken = _activeSearchCancelToken;
    _activeSearchCancelToken = null;
    if (activeToken != null && !activeToken.isCancelled) {
      activeToken.cancel('Service disposed');
    }
    if (!_hasCustomDio) {
      _dio.close(force: true);
    }
  }
}

/// Catálogo base instantâneo cobrindo todas as plataformas do RomM, RetroAPI e ROM-Gripper:
/// PSP, PS1, SNES, GBA, NDS, N64, Mega Drive, NES, GBC, Game Gear, Neo Geo, CPS1/CPS2, Arcade (MAME) e Dreamcast.
const List<EmulationGame> kVerifiedRealGamesCatalog = [
  // ==========================================================================
  // SONY PLAYSTATION PORTABLE (PSP)
  // ==========================================================================
  EmulationGame(
    igdbId: 19560,
    name: 'God of War: Ghost of Sparta',
    canonicalNoIntroName: 'God of War - Ghost of Sparta (USA) (En,Fr,Es)',
    summary:
        'A jornada implacável de Kratos até a cidade submersa de Atlântida e o domínio da Morte para resgatar seu irmão Deimos.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Ready at Dawn / Santa Monica',
    releaseYear: 2010,
    rating: 91,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1195376640,
    directRomUrl:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Ghost%20of%20Sparta%20%28USA%29%20%28PSN%29.iso',
  ),
  EmulationGame(
    igdbId: 549,
    name: 'God of War: Chains of Olympus',
    canonicalNoIntroName: 'God of War - Chains of Olympus (USA)',
    summary:
        'Antes de sua revolta contra o Olimpo, Kratos enfrenta o exército persa e desce ao Mundo Inferior quando Hélios desaparece do céu.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Ready at Dawn',
    releaseYear: 2008,
    rating: 89,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1153433600,
    directRomUrl:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Chains%20of%20Olympus%20%28USA%29%20%28PSN%29.iso',
  ),
  EmulationGame(
    igdbId: 1219,
    name: 'Monster Hunter Freedom Unite',
    canonicalNoIntroName: 'Monster Hunter Freedom Unite (USA)',
    summary:
        'Centenas de horas de caçadas estratégicas contra wyverns colossais, forja de armaduras Rank G e companheiros Felyne.',
    genres: ['Action RPG', 'Caça'],
    developer: 'Capcom',
    releaseYear: 2008,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 882900992,
    directRomUrl: 'retroapi://psp/Monster_Hunter_Freedom_Unite.chd',
  ),
  EmulationGame(
    igdbId: 9927,
    name: 'Shin Megami Tensei: Persona 3 Portable',
    canonicalNoIntroName: 'Shin Megami Tensei - Persona 3 Portable (USA)',
    summary:
        'Viva o cotidiano escolar durante o dia e explore a torre sombria de Tartarus na Hora Negra com dois protagonistas jogáveis.',
    genres: ['JRPG', 'Social Sim'],
    developer: 'Atlus',
    releaseYear: 2010,
    rating: 92,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 954204160,
    directRomUrl: 'retroapi://psp/Persona_3_Portable.chd',
  ),
  EmulationGame(
    igdbId: 433,
    name: 'Crisis Core: Final Fantasy VII',
    canonicalNoIntroName: 'Crisis Core - Final Fantasy VII (USA)',
    summary:
        'Acompanhe a ascensão de Zack Fair na SOLDIER, sua amizade com Cloud e os segredos por trás do Projeto Jenova e Sephiroth.',
    genres: ['Action RPG'],
    developer: 'Square Enix',
    releaseYear: 2008,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1090519040,
    directRomUrl: 'retroapi://psp/Crisis_Core_Final_Fantasy_VII.chd',
  ),
  EmulationGame(
    igdbId: 730,
    name: 'Grand Theft Auto: Vice City Stories',
    canonicalNoIntroName: 'Grand Theft Auto - Vice City Stories (USA) (v1.03)',
    summary:
        'Domine o império do crime na Vice City de 1984 com construção de negócios, combate naval e trilha sonora icônica dos anos 80.',
    genres: ['Mundo Aberto', 'Ação'],
    developer: 'Rockstar Leeds',
    releaseYear: 2006,
    rating: 88,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 985661440,
    directRomUrl:
        'https://archive.org/download/grand-theft-auto-vice-city-stories-europe-psp_202603_ver2/Grand%20Theft%20Auto%20-%20Vice%20City%20Stories%20%28Europe%29.iso',
  ),
  EmulationGame(
    igdbId: 729,
    name: 'Grand Theft Auto: Liberty City Stories',
    canonicalNoIntroName:
        'Grand Theft Auto - Liberty City Stories (USA) (En,Fr,De,Es,It) (v3.00)',
    summary:
        'Toni Cipriani retorna a Liberty City em 1998 para retomar o controle da família Leone em meio à guerra entre máfias.',
    genres: ['Mundo Aberto', 'Ação'],
    developer: 'Rockstar Leeds',
    releaseYear: 2005,
    rating: 87,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 744488960,
    directRomUrl: 'retroapi://psp/GTA_Liberty_City_Stories.chd',
  ),
  EmulationGame(
    igdbId: 1265,
    name: 'Tekken 6',
    canonicalNoIntroName: 'Tekken 6 (USA) (En,Fr,De,Es,It,Ru)',
    summary:
        'O sexto Torneio do Punho de Ferro traz 40 lutadores, sistema Rage, arenas destrutíveis e combate técnico a 60 quadros por segundo.',
    genres: ['Luta', 'Arcade'],
    developer: 'Bandai Namco',
    releaseYear: 2009,
    rating: 88,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 692060160,
    directRomUrl: 'https://archive.org/download/tekken-6_202309/Tekken%206.iso',
  ),
  EmulationGame(
    igdbId: 382,
    name: 'Metal Gear Solid: Peace Walker',
    canonicalNoIntroName: 'Metal Gear Solid - Peace Walker (USA)',
    summary:
        'Big Boss lidera os Militaires Sans Frontières na Costa Rica de 1974, expandindo a Mother Base e enfrentando armas autônomas de IA.',
    genres: ['Stealth', 'Ação Tática'],
    developer: 'Kojima Productions',
    releaseYear: 2010,
    rating: 93,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1289748480,
    directRomUrl: 'retroapi://psp/Metal_Gear_Solid_Peace_Walker.chd',
  ),
  EmulationGame(
    igdbId: 1211,
    name: 'Kingdom Hearts: Birth by Sleep',
    canonicalNoIntroName: 'Kingdom Hearts - Birth by Sleep (USA)',
    summary:
        'Três mestres da Keyblade — Terra, Ventus e Aqua — cruzam mundos encantados para desvendar as origens de Mestre Xehanort.',
    genres: ['Action RPG'],
    developer: 'Square Enix',
    releaseYear: 2010,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1321205760,
    directRomUrl: 'retroapi://psp/Kingdom_Hearts_Birth_by_Sleep.chd',
  ),
  EmulationGame(
    igdbId: 2491,
    name: 'Daxter',
    canonicalNoIntroName: 'Daxter (USA)',
    summary:
        'Enquanto Jak está preso em Haven City, Daxter assume o protagonismo como exterminador de insetos metálicos em plataformas acrobáticas.',
    genres: ['Plataforma 3D', 'Aventura'],
    developer: 'Ready at Dawn',
    releaseYear: 2006,
    rating: 86,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 723517440,
    directRomUrl: 'retroapi://psp/Daxter.chd',
  ),
  EmulationGame(
    igdbId: 3101,
    name: 'Midnight Club 3: DUB Edition',
    canonicalNoIntroName: 'Midnight Club 3 - DUB Edition (USA)',
    summary:
        'Corridas urbanas noturnas em alta velocidade pelas ruas de San Diego, Atlanta e Detroit com personalização completa.',
    genres: ['Corrida', 'Arcade'],
    developer: 'Rockstar San Diego',
    releaseYear: 2005,
    rating: 87,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 964689920,
    directRomUrl: 'retroapi://psp/Midnight_Club_3_DUB_Edition.chd',
  ),

  // ==========================================================================
  // SONY PLAYSTATION (PS1 / PSX)
  // ==========================================================================
  EmulationGame(
    igdbId: 1120,
    name: 'Castlevania: Symphony of the Night',
    canonicalNoIntroName: 'Castlevania - Symphony of the Night (USA)',
    summary:
        'Alucard desperta de seu sono eterno para explorar o castelo invertido de Drácula, combinando elementos de RPG, relíquias e magias ocultas.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 1997,
    rating: 95,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 376438784,
    directRomUrl: 'retroapi://ps1/Castlevania_Symphony_of_the_Night.chd',
  ),
  EmulationGame(
    igdbId: 375,
    name: 'Metal Gear Solid',
    canonicalNoIntroName: 'Metal Gear Solid (USA) (Disc 1) (Rev 1)',
    summary:
        'Solid Snake infiltra-se na ilha de Shadow Moses no Alasca para neutralizar a unidade renegada FOXHOUND e o tanque bípede nuclear REX.',
    genres: ['Stealth', 'Ação Cinematográfica'],
    developer: 'Konami',
    releaseYear: 1998,
    rating: 96,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 498073600,
    directRomUrl: 'retroapi://ps1/Metal_Gear_Solid.chd',
  ),
  EmulationGame(
    igdbId: 427,
    name: 'Final Fantasy VII',
    canonicalNoIntroName: 'Final Fantasy VII (USA) (Disc 1)',
    summary:
        'Cloud Strife e o grupo eco-rebelde AVALANCHE enfrentam a megacorporação Shinra e a ameaça planetária de Sephiroth.',
    genres: ['JRPG', 'Aventura'],
    developer: 'Square',
    releaseYear: 1997,
    rating: 95,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 461373440,
    directRomUrl: 'retroapi://ps1/Final_Fantasy_VII.chd',
  ),
  EmulationGame(
    igdbId: 966,
    name: 'Resident Evil 2',
    canonicalNoIntroName: 'Resident Evil 2 (USA) (Disc 1)',
    summary:
        'Leon S. Kennedy e Claire Redfield lutam para escapar de uma Raccoon City devastada pelo T-Virus da Umbrella Corporation.',
    genres: ['Survival Horror'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 412090368,
    directRomUrl: 'retroapi://ps1/Resident_Evil_2.chd',
  ),
  EmulationGame(
    igdbId: 481,
    name: 'Silent Hill',
    canonicalNoIntroName: 'Silent Hill (USA)',
    summary:
        'Harry Mason procura sua filha adotiva Cheryl pelas ruas cobertas de neblina e cinzas da misteriosa cidade de Silent Hill.',
    genres: ['Survival Horror', 'Terror Psicológico'],
    developer: 'Konami (Team Silent)',
    releaseYear: 1999,
    rating: 91,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 318767104,
    directRomUrl: 'retroapi://ps1/Silent_Hill.chd',
  ),
  EmulationGame(
    igdbId: 1263,
    name: 'Tekken 3',
    canonicalNoIntroName: 'Tekken 3 (USA)',
    summary:
        'A estreia de Jin Kazama, Eddy Gordo e Hwoarang com movimentação lateral fluida, modo Tekken Force e trilha sonora lendária.',
    genres: ['Luta 3D', 'Arcade'],
    developer: 'Namco',
    releaseYear: 1998,
    rating: 94,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 429916160,
    directRomUrl: 'retroapi://ps1/Tekken_3.chd',
  ),
  EmulationGame(
    igdbId: 1184,
    name: 'Crash Bandicoot 2: Cortex Strikes Back',
    canonicalNoIntroName: 'Crash Bandicoot 2 - Cortex Strikes Back (USA)',
    summary:
        'Crash retorna para coletar os 25 cristais espalhados pelas salas dimensionais enquanto Dr. Neo Cortex oculta suas reais intenções com a estação espacial Cortex Vortex.',
    genres: ['Plataforma 3D', 'Aventura'],
    developer: 'Naughty Dog',
    releaseYear: 1997,
    rating: 92,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'EUR',
    estimatedSizeBytes: 136501796,
    directRomUrl: 'retroapi://ps1/Crash_Bandicoot_2_Cortex_Strikes_Back.chd',
  ),
  EmulationGame(
    igdbId: 1185,
    name: 'Crash Bandicoot: Warped',
    canonicalNoIntroName: 'Crash Bandicoot - Warped (USA)',
    summary:
        'Crash e Coco viajam através do Tornado do Tempo desde a Muralha da China até o futuro para impedir os planos de Cortex e Uka Uka.',
    genres: ['Plataforma 3D'],
    developer: 'Naughty Dog',
    releaseYear: 1998,
    rating: 91,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 188743680,
    directRomUrl: 'retroapi://ps1/Crash_Bandicoot_Warped.chd',
  ),
  EmulationGame(
    igdbId: 1192,
    name: 'Crash Team Racing',
    canonicalNoIntroName: 'Crash Team Racing (USA)',
    summary:
        'Corridas de kart frenéticas com sistema de turbo por derrapagem tripla, modo Aventura completo e batalhas em arena contra Nitros Oxide.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Naughty Dog',
    releaseYear: 1999,
    rating: 92,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 272629760,
    directRomUrl: 'retroapi://ps1/Crash_Team_Racing.chd',
  ),
  EmulationGame(
    igdbId: 1380,
    name: 'Gran Turismo 2',
    canonicalNoIntroName: 'Gran Turismo 2 (USA) (Simulation Mode) (Rev 1)',
    summary:
        'Mais de 650 automóveis licenciados, provas de rali, carteiras de habilitação e ajuste fino de suspensão e câmbio.',
    genres: ['Simulador de Corrida'],
    developer: 'Polyphony Digital',
    releaseYear: 1999,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 440401920,
    directRomUrl: 'retroapi://ps1/Gran_Turismo_2.chd',
  ),
  EmulationGame(
    igdbId: 430,
    name: 'Chrono Cross',
    canonicalNoIntroName: 'Chrono Cross (USA) (Disc 1)',
    summary:
        'Serge atravessa duas dimensões paralelas no arquipélago de El Nido com mais de 40 aliados recrutáveis e trilha de Yasunori Mitsuda.',
    genres: ['JRPG'],
    developer: 'Square',
    releaseYear: 2000,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 419430400,
    directRomUrl: 'retroapi://ps1/Chrono_Cross.chd',
  ),

  // ==========================================================================
  // SUPER NINTENDO (SNES)
  // ==========================================================================
  EmulationGame(
    igdbId: 428,
    name: 'Chrono Trigger',
    canonicalNoIntroName: 'Chrono Trigger (USA)',
    summary:
        'Crono, Marle, Lucca, Frog e Robo viajam desde a Pré-História até o ano 2300 d.C. para impedir que Lavos destrua o planeta.',
    genres: ['JRPG', 'Viagem no Tempo'],
    developer: 'Square',
    releaseYear: 1995,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2998272,
    directRomUrl: 'retroapi://snes/Chrono_Trigger.sfc',
  ),
  EmulationGame(
    igdbId: 1029,
    name: 'The Legend of Zelda: A Link to the Past',
    canonicalNoIntroName: 'Legend of Zelda, The - A Link to the Past (USA)',
    summary:
        'Cruze os portais entre o Mundo da Luz e o Mundo das Trevas em Hyrule, empunhe a Master Sword e liberte as Sete Donzelas.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 1991,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 702464,
    directRomUrl: 'retroapi://snes/Zelda_A_Link_to_the_Past.sfc',
  ),
  EmulationGame(
    igdbId: 1070,
    name: 'Super Metroid',
    canonicalNoIntroName: 'Super Metroid (Japan, USA) (En,Ja)',
    summary:
        'Samus Aran desce às profundezas interconectadas do planeta Zebes em uma obra-prima de atmosfera, exploração não linear e combate sci-fi.',
    genres: ['Metroidvania', 'Sci-Fi'],
    developer: 'Nintendo R&D1',
    releaseYear: 1994,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 1716224,
    directRomUrl: 'retroapi://snes/Super_Metroid.sfc',
  ),
  EmulationGame(
    igdbId: 1068,
    name: 'Super Mario World',
    canonicalNoIntroName: 'Super Mario World (USA)',
    summary:
        'A estreia de Yoshi na Dinosaur Land com 96 saídas secretas, Palácios dos Blocos, Capa Voadora e a fortaleza de Bowser.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo EAD',
    releaseYear: 1990,
    rating: 97,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 348160,
    directRomUrl: 'retroapi://snes/Super_Mario_World.sfc',
  ),
  EmulationGame(
    igdbId: 1090,
    name: 'Donkey Kong Country 2: Diddy\'s Kong Quest',
    canonicalNoIntroName:
        'Donkey Kong Country 2 - Diddy\'s Kong Quest (USA) (En,Fr) (Rev 1)',
    summary:
        'Diddy e Dixie Kong invadem a Ilha dos Crocodilos para resgatar Donkey Kong ao som da inesquecível trilha sonora de David Wise.',
    genres: ['Plataforma 2D', 'Aventura'],
    developer: 'Rare',
    releaseYear: 1995,
    rating: 94,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2621440,
    directRomUrl: 'retroapi://snes/Donkey_Kong_Country_2.sfc',
  ),
  EmulationGame(
    igdbId: 1711,
    name: 'Mega Man X',
    canonicalNoIntroName: 'Mega Man X (USA) (Rev 1)',
    summary:
        'O caçador de Mavericks X e seu aliado Zero enfrentam a rebelião liderada por Sigma, adquirindo cápsulas de armadura e armas especiais.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Capcom',
    releaseYear: 1993,
    rating: 93,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 1126400,
    directRomUrl: 'retroapi://snes/Mega_Man_X.sfc',
  ),
  EmulationGame(
    igdbId: 426,
    name: 'Final Fantasy III (VI)',
    canonicalNoIntroName: 'Final Fantasy III (USA) (Rev 1)',
    summary:
        'Terra Branford e os Returners desafiam o Império Gestahliano e a loucura apocalíptica de Kefka em um mundo movido a Magitek.',
    genres: ['JRPG'],
    developer: 'Square',
    releaseYear: 1994,
    rating: 95,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2293760,
    directRomUrl: 'retroapi://snes/Final_Fantasy_III.sfc',
  ),
  EmulationGame(
    igdbId: 1072,
    name: 'Super Mario RPG: Legend of the Seven Stars',
    canonicalNoIntroName: 'Super Mario RPG - Legend of the Seven Stars (USA)',
    summary:
        'Mario, Bowser, Peach, Mallow e Geno unem forças em combates por turnos cronometrados para restaurar a Star Road contra Smithy.',
    genres: ['JRPG', 'Aventura'],
    developer: 'Square / Nintendo',
    releaseYear: 1996,
    rating: 92,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2883584,
    directRomUrl: 'retroapi://snes/Super_Mario_RPG.sfc',
  ),
  EmulationGame(
    igdbId: 1074,
    name: 'EarthBound',
    canonicalNoIntroName: 'EarthBound (USA)',
    summary:
        'Ness e seus amigos percorrem cidades modernas, desertos e dimensões surreais usando poderes PSI contra o invasor cósmico Giygas.',
    genres: ['JRPG', 'Cult Classic'],
    developer: 'Ape / HAL Laboratory',
    releaseYear: 1995,
    rating: 93,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2162688,
    directRomUrl: 'retroapi://snes/EarthBound.sfc',
  ),

  // ==========================================================================
  // GAME BOY ADVANCE (GBA)
  // ==========================================================================
  EmulationGame(
    igdbId: 1515,
    name: 'Pokémon Emerald Version',
    canonicalNoIntroName: 'Pokemon - Emerald Version (USA, Europe)',
    summary:
        'A edição definitiva da região de Hoenn: detenha o despertar de Groudon e Kyogre com a ajuda de Rayquaza e domine a Battle Frontier.',
    genres: ['RPG', 'Coleção de Monstros'],
    developer: 'Game Freak',
    releaseYear: 2005,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 6606028,
    directRomUrl: 'retroapi://gba/Pokemon_Emerald.gba',
  ),
  EmulationGame(
    igdbId: 1559,
    name: 'Pokémon FireRed Version',
    canonicalNoIntroName: 'Pokemon - FireRed Version (USA, Europe) (Rev 1)',
    summary:
        'Retorne à região de Kanto totalmente recriada no GBA, derrote a Equipe Rocket, explore as Sevii Islands e conquiste a Liga Índigo.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2004,
    rating: 90,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5452595,
    directRomUrl: 'retroapi://gba/Pokemon_FireRed.gba',
  ),
  EmulationGame(
    igdbId: 1557,
    name: 'Metroid Fusion',
    canonicalNoIntroName: 'Metroid Fusion (USA)',
    summary:
        'Infectada pelo parasita X e salva por uma vacina de DNA Metroid, Samus investiga os setores biológicos da estação espacial BSL.',
    genres: ['Metroidvania', 'Ação'],
    developer: 'Nintendo R&D1',
    releaseYear: 2002,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 4613734,
    directRomUrl: 'retroapi://gba/Metroid_Fusion.gba',
  ),
  EmulationGame(
    igdbId: 1558,
    name: 'Metroid: Zero Mission',
    canonicalNoIntroName: 'Metroid - Zero Mission (USA)',
    summary:
        'Reimaginação veloz da primeira missão de Samus em Zebes, incluindo o capítulo inédito de infiltração furtiva na nave-mãe Space Pirate.',
    genres: ['Metroidvania', 'Ação'],
    developer: 'Nintendo R&D1',
    releaseYear: 2004,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 4404019,
    directRomUrl: 'retroapi://gba/Metroid_Zero_Mission.gba',
  ),
  EmulationGame(
    igdbId: 1037,
    name: 'The Legend of Zelda: The Minish Cap',
    canonicalNoIntroName: 'Legend of Zelda, The - The Minish Cap (USA)',
    summary:
        'Com o gorro falante Ezlo, Link encolhe ao tamanho do povo Minish para forjar a Espada Quádrupla e derrotar o feiticeiro Vaati.',
    genres: ['Action Adventure'],
    developer: 'Capcom / Flagship',
    releaseYear: 2004,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 8178892,
    directRomUrl: 'retroapi://gba/Zelda_The_Minish_Cap.gba',
  ),
  EmulationGame(
    igdbId: 1126,
    name: 'Castlevania: Aria of Sorrow',
    canonicalNoIntroName: 'Castlevania - Aria of Sorrow (USA)',
    summary:
        'Em 2035, Soma Cruz é transportado para um castelo selado dentro de um eclipse solar e descobre o poder de dominar as almas dos monstros.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 2003,
    rating: 93,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5138022,
    directRomUrl: 'retroapi://gba/Castlevania_Aria_of_Sorrow.gba',
  ),
  EmulationGame(
    igdbId: 1442,
    name: 'Golden Sun',
    canonicalNoIntroName: 'Golden Sun (USA, Europe)',
    summary:
        'Isaac e os Adeptos de Vale partem pelo continente de Weyard combinando criaturas elementais Djinn e magias de Psynergy.',
    genres: ['JRPG'],
    developer: 'Camelot Software Planning',
    releaseYear: 2001,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5872025,
    directRomUrl: 'retroapi://gba/Golden_Sun.gba',
  ),
  EmulationGame(
    igdbId: 1460,
    name: 'Fire Emblem',
    canonicalNoIntroName: 'Fire Emblem (USA, Australia)',
    summary:
        'Comande os exércitos de Lyndis, Eliwood e Hector em batalhas táticas por turnos onde cada decisão no campo de batalha é permanente.',
    genres: ['RPG Tático', 'Estratégia'],
    developer: 'Intelligent Systems',
    releaseYear: 2003,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 7654604,
    directRomUrl: 'retroapi://gba/Fire_Emblem.gba',
  ),
  EmulationGame(
    igdbId: 1628,
    name: 'Advance Wars',
    canonicalNoIntroName: 'Advance Wars (USA) (Rev 1)',
    summary:
        'Lidere os Comandantes da nação Orange Star em combates estratégicos de infantaria, blindados, força aérea e marinha.',
    genres: ['Estratégia por Turnos'],
    developer: 'Intelligent Systems',
    releaseYear: 2001,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 2831155,
    directRomUrl: 'retroapi://gba/Advance_Wars.gba',
  ),

  // ==========================================================================
  // NINTENDO DS (NDS)
  // ==========================================================================
  EmulationGame(
    igdbId: 1512,
    name: 'Pokémon Platinum Version',
    canonicalNoIntroName: 'Pokemon - Platinum Version (USA)',
    summary:
        'Desafie os planos de Cyrus e da Equipe Galáctica, atravesse as leis da física no Distortion World de Giratina e conquiste Sinnoh.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2008,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 51380224,
    directRomUrl: 'retroapi://nds/Pokemon_Platinum.nds',
  ),
  EmulationGame(
    igdbId: 1518,
    name: 'Pokémon HeartGold Version',
    canonicalNoIntroName: 'Pokemon - HeartGold Version (USA)',
    summary:
        'Percorra as duas regiões completas de Johto e Kanto com seu Pokémon caminhando ao seu lado, conquiste 16 insígnias e enfrente Red no Mt. Silver.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2009,
    rating: 94,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 60817408,
    directRomUrl: 'retroapi://nds/Pokemon_HeartGold.nds',
  ),
  EmulationGame(
    igdbId: 1522,
    name: 'Pokémon Black Version',
    canonicalNoIntroName:
        'Pokemon - Black Version (USA, Europe) (NDSi Enhanced)',
    summary:
        'Explore a metrópole de Unova com batalhas animadas em tempo real, estações do ano dinâmicas e o embate ideológico contra N e a Equipe Plasma.',
    genres: ['RPG'],
    developer: 'Game Freak',
    releaseYear: 2011,
    rating: 90,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 109051904,
    directRomUrl: 'retroapi://nds/Pokemon_Black.nds',
  ),
  EmulationGame(
    igdbId: 2348,
    name: 'Mario Kart DS',
    canonicalNoIntroName: 'Mario Kart DS (USA) (En,Fr,De,Es,It)',
    summary:
        '32 pistas clássicas e inéditas, modo Missões contra chefes, personalização de emblemas e derrapagens técnicas em alta velocidade.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Nintendo EAD',
    releaseYear: 2005,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 18874368,
    directRomUrl: 'retroapi://nds/Mario_Kart_DS.nds',
  ),
  EmulationGame(
    igdbId: 1081,
    name: 'New Super Mario Bros.',
    canonicalNoIntroName: 'New Super Mario Bros. (USA)',
    summary:
        'Plataforma 2.5D vibrante com novos power-ups como Mega Cogumelo, Casco Azul e Mini Cogumelo através de oito mundos repletos de passagens ocultas.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo EAD',
    releaseYear: 2006,
    rating: 89,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 16777216,
    directRomUrl: 'retroapi://nds/New_Super_Mario_Bros.nds',
  ),
  EmulationGame(
    igdbId: 1129,
    name: 'Castlevania: Dawn of Sorrow',
    canonicalNoIntroName: 'Castlevania - Dawn of Sorrow (USA)',
    summary:
        'Continuação direta de Aria of Sorrow: Soma Cruz enfrenta uma seita que tenta criar um novo Lorde das Trevas, usando selos mágicos e síntese de armas.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 2005,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 31457280,
    directRomUrl: 'retroapi://nds/Castlevania_Dawn_of_Sorrow.nds',
  ),

  // ==========================================================================
  // NINTENDO 64 (N64)
  // ==========================================================================
  EmulationGame(
    igdbId: 1030,
    name: 'The Legend of Zelda: Ocarina of Time',
    canonicalNoIntroName: 'Legend of Zelda, The - Ocarina of Time (USA)',
    summary:
        'Viaje sete anos no tempo entre a infância e a idade adulta de Link, domine melodias sagradas na Ocarina e impeça o reinado de Ganondorf.',
    genres: ['Action Adventure', 'Fantasia'],
    developer: 'Nintendo EAD',
    releaseYear: 1998,
    rating: 99,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 26214400,
    directRomUrl: 'retroapi://n64/Zelda_Ocarina_of_Time.z64',
  ),
  EmulationGame(
    igdbId: 10740,
    name: 'Super Mario 64',
    canonicalNoIntroName: 'Super Mario 64 (USA)',
    summary:
        'Salte para dentro dos quadros encantados do Castelo da Princesa Peach e colete 120 Power Stars no marco fundador dos jogos de plataforma 3D.',
    genres: ['Plataforma 3D'],
    developer: 'Nintendo EAD',
    releaseYear: 1996,
    rating: 97,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 6291456,
    directRomUrl: 'retroapi://n64/Super_Mario_64.z64',
  ),
  EmulationGame(
    igdbId: 1031,
    name: 'The Legend of Zelda: Majora\'s Mask',
    canonicalNoIntroName: 'Legend of Zelda, The - Majora\'s Mask (USA)',
    summary:
        'Três dias antes que a Lua colida contra a terra de Termina: use máscaras de transformação e volte no tempo para salvar seus habitantes.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 2000,
    rating: 95,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 27262976,
    directRomUrl: 'retroapi://n64/Zelda_Majoras_Mask.z64',
  ),
  EmulationGame(
    igdbId: 2342,
    name: 'Mario Kart 64',
    canonicalNoIntroName: 'Mario Kart 64 (USA)',
    summary:
        'Disputas lendárias na Rainbow Road, Bowser\'s Castle e Koopa Troopa Beach com quatro copas completas e modo Batalha em arenas 3D.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Nintendo EAD',
    releaseYear: 1997,
    rating: 91,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 8388608,
    directRomUrl: 'retroapi://n64/Mario_Kart_64.z64',
  ),
  EmulationGame(
    igdbId: 1626,
    name: 'Super Smash Bros.',
    canonicalNoIntroName: 'Super Smash Bros. (USA)',
    summary:
        'Os maiores heróis da Nintendo — Mario, Link, Samus, Pikachu, Fox e Kirby — colidem em arenas dinâmicas onde o objetivo é arremessar o rival para fora.',
    genres: ['Luta em Plataforma'],
    developer: 'HAL Laboratory',
    releaseYear: 1999,
    rating: 90,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 12582912,
    directRomUrl: 'retroapi://n64/Super_Smash_Bros.z64',
  ),

  // ==========================================================================
  // SEGA MEGA DRIVE / GENESIS (MD)
  // ==========================================================================
  EmulationGame(
    igdbId: 3192,
    name: 'Sonic the Hedgehog 2',
    canonicalNoIntroName: 'Sonic The Hedgehog 2 (World) (Rev A)',
    summary:
        'Sonic e Miles "Tails" Prower aceleram por Emerald Hill, Chemical Plant e Casino Night para coletar as 7 Esmeraldas do Caos e derrotar o Death Egg.',
    genres: ['Plataforma 2D', 'Velocidade'],
    developer: 'Sega Technical Institute',
    releaseYear: 1992,
    rating: 93,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'WORLD',
    estimatedSizeBytes: 786432,
    directRomUrl: 'retroapi://md/Sonic_The_Hedgehog_2.md',
  ),
  EmulationGame(
    igdbId: 1891,
    name: 'Streets of Rage 2',
    canonicalNoIntroName: 'Streets of Rage 2 (USA)',
    summary:
        'Axel, Blaze, Max e Skate limpam as ruas dominadas pelo sindicato de Mr. X no ápice do gênero beat \'em up com trilha eletrônica de Yuzo Koshiro.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Sega / Ancient',
    releaseYear: 1992,
    rating: 94,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 1572864,
    directRomUrl: 'retroapi://md/Streets_of_Rage_2.md',
  ),
  EmulationGame(
    igdbId: 4412,
    name: 'Gunstar Heroes',
    canonicalNoIntroName: 'Gunstar Heroes (USA)',
    summary:
        'Run-and-gun explosivo da Treasure com combinação livre de quatro tipos de tiro, chefes articulados multi-estágio e ação ininterrupta.',
    genres: ['Run and Gun', 'Ação'],
    developer: 'Treasure',
    releaseYear: 1993,
    rating: 92,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 819200,
    directRomUrl: 'retroapi://md/Gunstar_Heroes.md',
  ),
  EmulationGame(
    igdbId: 1122,
    name: 'Castlevania: Bloodlines',
    canonicalNoIntroName: 'Castlevania - Bloodlines (USA)',
    summary:
        'John Morris e Eric Lecarde percorrem a Europa de 1917 — das ruínas da Grécia à Torre de Pisa — para impedir a ressurreição da Condessa Bartley.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Konami',
    releaseYear: 1994,
    rating: 89,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 720896,
    directRomUrl: 'retroapi://md/Castlevania_Bloodlines.md',
  ),

  // ==========================================================================
  // NINTENDO ENTERTAINMENT SYSTEM (NES) & GAME BOY COLOR (GBC)
  // ==========================================================================
  EmulationGame(
    igdbId: 1067,
    name: 'Super Mario Bros. 3',
    canonicalNoIntroName: 'Super Mario Bros. 3 (USA) (Rev 1)',
    summary:
        'Oito mundos temáticos, mapas interativos, Super Folha Guaxinim, Traje de Sapo e navios voadores dos sete Koopalings.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo R&D4',
    releaseYear: 1990,
    rating: 97,
    platformName: 'NES',
    platformSlug: 'nes',
    region: 'USA',
    estimatedSizeBytes: 245760,
    directRomUrl: 'retroapi://nes/Super_Mario_Bros_3.nes',
  ),
  EmulationGame(
    igdbId: 1702,
    name: 'Mega Man 2',
    canonicalNoIntroName: 'Mega Man 2 (USA)',
    summary:
        'Derrote Metal Man, Air Man, Quick Man e os oito Robot Masters de Dr. Wily, absorvendo suas armas em qualquer ordem.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Capcom',
    releaseYear: 1988,
    rating: 93,
    platformName: 'NES',
    platformSlug: 'nes',
    region: 'USA',
    estimatedSizeBytes: 147456,
    directRomUrl: 'retroapi://nes/Mega_Man_2.nes',
  ),
  EmulationGame(
    igdbId: 1514,
    name: 'Pokémon Crystal Version',
    canonicalNoIntroName: 'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
    summary:
        'O clássico de Johto no Game Boy Color com sprites animados em batalha, ciclo de dia e noite em tempo real e a caçada ao lendário Suicune.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2001,
    rating: 91,
    platformName: 'GBC',
    platformSlug: 'gbc',
    region: 'USA',
    estimatedSizeBytes: 1048576,
    directRomUrl: 'retroapi://gbc/Pokemon_Crystal.gbc',
  ),
  EmulationGame(
    igdbId: 1034,
    name: 'The Legend of Zelda: Link\'s Awakening DX',
    canonicalNoIntroName:
        'Legend of Zelda, The - Link\'s Awakening DX (USA, Europe) (Rev 2) (SGB Enhanced) (GB Compatible)',
    summary:
        'Náufrago na misteriosa Ilha Koholint, Link precisa reunir os oito Instrumentos das Sereias para despertar o Peixe do Vento.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 1998,
    rating: 93,
    platformName: 'GBC',
    platformSlug: 'gbc',
    region: 'USA',
    estimatedSizeBytes: 655360,
    directRomUrl: 'retroapi://gbc/Zelda_Links_Awakening_DX.gbc',
  ),

  // ==========================================================================
  // SEGA GAME GEAR (ROM-Gripper & RetroAPI)
  // ==========================================================================
  EmulationGame(
    igdbId: 45101,
    name: 'Sonic Chaos',
    canonicalNoIntroName: 'Sonic Chaos (USA, Europe, Brazil) (En)',
    summary:
        'Sonic e Tails enfrentam Dr. Robotnik na South Island em 8 bits coloridos com Rocket Shoes e Super Peel-Out.',
    genres: ['Plataforma 2D'],
    developer: 'Aspect / Sega',
    releaseYear: 1993,
    rating: 86,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gamegear/Sonic_Chaos.gg',
  ),
  EmulationGame(
    igdbId: 45102,
    name: 'Sonic Blast',
    canonicalNoIntroName: 'Sonic Blast (World)',
    summary:
        'Sonic e Knuckles unem forças em gráficos pré-renderizados no Game Gear para recuperar os fragmentos das Esmeraldas.',
    genres: ['Plataforma 2D'],
    developer: 'Aspect / Sega',
    releaseYear: 1996,
    rating: 84,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'WORLD',
    estimatedSizeBytes: 1048576,
    directRomUrl: 'retroapi://gamegear/Sonic_Blast.gg',
  ),
  EmulationGame(
    igdbId: 45103,
    name: 'Shinobi II: The Silent Fury',
    canonicalNoIntroName: 'GG Shinobi II, The - The Silent Fury (World)',
    summary:
        'Joe Musashi lidera cinco ninjas elementais com habilidades distintas para recuperar os cristais roubados pelo Black Ninja.',
    genres: ['Ação', 'Ninja'],
    developer: 'Sega',
    releaseYear: 1992,
    rating: 89,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'WORLD',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gamegear/GG_Shinobi_II.gg',
  ),

  // ==========================================================================
  // SNK NEO GEO (ROM-Gripper & RetroAPI)
  // ==========================================================================
  EmulationGame(
    igdbId: 55101,
    name: 'Metal Slug: Super Vehicle-001',
    canonicalNoIntroName: 'Metal Slug - Super Vehicle-001',
    summary:
        'Marco Rossi e Tarma Roving avançam pelas linhas inimigas do General Morden em pixel art lendária da SNK.',
    genres: ['Run and Gun', 'Arcade'],
    developer: 'Nazca / SNK',
    releaseYear: 1996,
    rating: 94,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 14680064,
    directRomUrl: 'retroapi://neogeo/mslug.zip',
  ),
  EmulationGame(
    igdbId: 55102,
    name: 'Metal Slug 3',
    canonicalNoIntroName: 'Metal Slug 3',
    summary:
        'Rotas ramificadas submarinas, aéreas e espaciais, dezenas de veículos Slug e o ápice da animação 2D da era Neo Geo MVS.',
    genres: ['Run and Gun', 'Arcade'],
    developer: 'SNK',
    releaseYear: 2000,
    rating: 96,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 38797312,
    directRomUrl: 'retroapi://neogeo/mslug3.zip',
  ),
  EmulationGame(
    igdbId: 55103,
    name: 'The King of Fighters \'98',
    canonicalNoIntroName:
        'The King of Fighters \'98 - The Slugfest / King of Fighters \'98 - dream match never ends',
    summary:
        'O Dream Match definitivo da franquia KOF reunindo 38 lutadores em trios nos sistemas Advanced e Extra.',
    genres: ['Luta 2D', 'Arcade'],
    developer: 'SNK',
    releaseYear: 1998,
    rating: 95,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 29360128,
    directRomUrl: 'retroapi://neogeo/kof98.zip',
  ),
  EmulationGame(
    igdbId: 55104,
    name: 'Garou: Mark of the Wolves',
    canonicalNoIntroName: 'Garou - Mark of the Wolves',
    summary:
        'Rock Howard e Terry Bogard disputam o torneio King of Fighters: Maximum Mayhem com mecânicas T.O.P. e Just Defend.',
    genres: ['Luta 2D', 'Arcade'],
    developer: 'SNK',
    releaseYear: 1999,
    rating: 95,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 41943040,
    directRomUrl: 'retroapi://neogeo/garou.zip',
  ),

  // ==========================================================================
  // CAPCOM PLAY SYSTEM — CPS1 / CPS2 & ARCADE MAME
  // ==========================================================================
  EmulationGame(
    igdbId: 65101,
    name: 'Street Fighter Alpha 3',
    canonicalNoIntroName: 'Street Fighter Alpha 3',
    summary:
        'Escolha entre os estilos A-ISM, V-ISM e X-ISM com 28 lutadores na placa arcade CPS2 da Capcom.',
    genres: ['Luta 2D', 'CPS2'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 94,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'USA',
    estimatedSizeBytes: 22020096,
    directRomUrl: 'retroapi://cps1/sfa3.zip',
  ),
  EmulationGame(
    igdbId: 65102,
    name: 'Marvel vs. Capcom: Clash of Super Heroes',
    canonicalNoIntroName: 'Marvel vs. Capcom - Clash of Super Heroes',
    summary:
        'Combates em duplas explosivos entre Ryu, Mega Man, Jin, Spider-Man, Wolverine e Venom na CPS2.',
    genres: ['Luta 2D', 'Crossover'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 93,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'USA',
    estimatedSizeBytes: 24117248,
    directRomUrl: 'retroapi://cps1/mvsc.zip',
  ),
  EmulationGame(
    igdbId: 65103,
    name: 'Cadillacs and Dinosaurs',
    canonicalNoIntroName: 'Cadillacs and Dinosaurs',
    summary:
        'Jack Tenrec, Hannah Dundee, Mustapha Cairo e Mess O\'Bradovich enfrentam caçadores ilegais em um futuro pós-apocalíptico.',
    genres: ['Beat \'em up', 'CPS1'],
    developer: 'Capcom',
    releaseYear: 1993,
    rating: 93,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'WORLD',
    estimatedSizeBytes: 6291456,
    directRomUrl: 'retroapi://cps1/dino.zip',
  ),
  EmulationGame(
    igdbId: 75101,
    name: 'Teenage Mutant Ninja Turtles: Turtles in Time',
    canonicalNoIntroName: 'Teenage Mutant Ninja Turtles - Turtles in Time',
    summary:
        'Leonardo, Michelangelo, Donatello e Raphael viajam através da história para recuperar a Estátua da Liberdade de Krang e Shredder.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Konami',
    releaseYear: 1991,
    rating: 92,
    platformName: 'ARCADE',
    platformSlug: 'mame',
    region: 'USA',
    estimatedSizeBytes: 5242880,
    directRomUrl: 'retroapi://mame/tmnt2.zip',
  ),
  EmulationGame(
    igdbId: 75102,
    name: 'The Simpsons Arcade Game',
    canonicalNoIntroName: 'The Simpsons',
    summary:
        'Homer, Marge, Bart e Lisa enfrentam os capangas de Mr. Burns pelas ruas de Springfield para resgatar Maggie.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Konami',
    releaseYear: 1991,
    rating: 90,
    platformName: 'ARCADE',
    platformSlug: 'mame',
    region: 'USA',
    estimatedSizeBytes: 4194304,
    directRomUrl: 'retroapi://mame/simpsons.zip',
  ),

  // ==========================================================================
  // SEGA DREAMCAST
  // ==========================================================================
  EmulationGame(
    igdbId: 85101,
    name: 'Sonic Adventure',
    canonicalNoIntroName: 'Sonic Adventure (USA) (En,Ja,Fr,De,Es)',
    summary:
        'Sonic, Tails, Knuckles, Amy, Big e E-102 Gamma exploram Station Square e Mystic Ruins contra a criatura ancestral Chaos.',
    genres: ['Plataforma 3D', 'Ação'],
    developer: 'Sonic Team / Sega',
    releaseYear: 1999,
    rating: 90,
    platformName: 'DREAMCAST',
    platformSlug: 'dreamcast',
    region: 'USA',
    estimatedSizeBytes: 712710096,
    directRomUrl: 'retroapi://dreamcast/Sonic_Adventure.chd',
  ),
  EmulationGame(
    igdbId: 85102,
    name: 'SoulCalibur',
    canonicalNoIntroName: 'SoulCalibur (USA)',
    summary:
        'Combates com armas em 8 direções a 60 FPS no Dreamcast em torno da espada amaldiçoada Soul Edge.',
    genres: ['Luta 3D', 'Arcade'],
    developer: 'Namco',
    releaseYear: 1999,
    rating: 98,
    platformName: 'DREAMCAST',
    platformSlug: 'dreamcast',
    region: 'USA',
    estimatedSizeBytes: 650117120,
    directRomUrl: 'retroapi://dreamcast/SoulCalibur.chd',
  ),

  // ==========================================================================
  // SONY PLAYSTATION 2 (PS2)
  // ==========================================================================
  EmulationGame(
    igdbId: 91101,
    name: 'Shadow of the Colossus',
    canonicalNoIntroName: 'Shadow of the Colossus (USA) (En,Fr,Es)',
    summary:
        'Escale 16 colossos gigantes em uma terra proibida para trazer uma vida de volta.',
    genres: ['Aventura', 'Ação'],
    developer: 'Team Ico / Sony',
    releaseYear: 2005,
    rating: 95,
    platformName: 'PS2',
    platformSlug: 'ps2',
    region: 'USA',
    estimatedSizeBytes: 2450000000,
    directRomUrl: 'retroapi://ps2/Shadow_of_the_Colossus.iso',
  ),
  EmulationGame(
    igdbId: 91102,
    name: 'God of War II',
    canonicalNoIntroName: 'God of War II (USA)',
    summary:
        'Kratos parte em busca das Irmãs do Destino em uma jornada épica pelo Olimpo.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Santa Monica Studio',
    releaseYear: 2007,
    rating: 93,
    platformName: 'PS2',
    platformSlug: 'ps2',
    region: 'USA',
    estimatedSizeBytes: 4200000000,
    directRomUrl: 'retroapi://ps2/God_of_War_II.iso',
  ),

  // ==========================================================================
  // NINTENDO GAMECUBE
  // ==========================================================================
  EmulationGame(
    igdbId: 92101,
    name: 'The Legend of Zelda: The Wind Waker',
    canonicalNoIntroName: 'Legend of Zelda, The - The Wind Waker (USA)',
    summary:
        'Navegue pelo Grande Mar com estilo cel-shaded atemporal e masmorras memoráveis.',
    genres: ['Aventura', 'Ação'],
    developer: 'Nintendo EAD',
    releaseYear: 2003,
    rating: 96,
    platformName: 'GAMECUBE',
    platformSlug: 'gamecube',
    region: 'USA',
    estimatedSizeBytes: 1180000000,
    directRomUrl: 'retroapi://gamecube/Wind_Waker.rvz',
  ),
  EmulationGame(
    igdbId: 92102,
    name: 'Metroid Prime',
    canonicalNoIntroName: 'Metroid Prime (USA)',
    summary:
        'Explore o planeta Tallon IV em primeira pessoa com Samus Aran em gráficos de ponta.',
    genres: ['Ação', 'Aventura'],
    developer: 'Retro Studios',
    releaseYear: 2002,
    rating: 97,
    platformName: 'GAMECUBE',
    platformSlug: 'gamecube',
    region: 'USA',
    estimatedSizeBytes: 1250000000,
    directRomUrl: 'retroapi://gamecube/Metroid_Prime.rvz',
  ),

  // ==========================================================================
  // NINTENDO WII
  // ==========================================================================
  EmulationGame(
    igdbId: 93101,
    name: 'Super Mario Galaxy',
    canonicalNoIntroName: 'Super Mario Galaxy (USA)',
    summary:
        'Salte por planetoides com gravidade própria em uma das obras-primas 3D da Nintendo.',
    genres: ['Plataforma 3D', 'Aventura'],
    developer: 'Nintendo EAD Tokyo',
    releaseYear: 2007,
    rating: 97,
    platformName: 'WII',
    platformSlug: 'wii',
    region: 'USA',
    estimatedSizeBytes: 3450000000,
    directRomUrl: 'retroapi://wii/Super_Mario_Galaxy.wbfs',
  ),
  EmulationGame(
    igdbId: 93102,
    name: 'Donkey Kong Country Returns',
    canonicalNoIntroName: 'Donkey Kong Country Returns (USA) (En,Fr,Es)',
    summary:
        'Donkey e Diddy Kong retomam suas bananas em fases 2.5D desafiadoras da Retro Studios.',
    genres: ['Plataforma', 'Ação'],
    developer: 'Retro Studios',
    releaseYear: 2010,
    rating: 89,
    platformName: 'WII',
    platformSlug: 'wii',
    region: 'USA',
    estimatedSizeBytes: 3200000000,
    directRomUrl: 'retroapi://wii/DKCR.wbfs',
  ),

  // ==========================================================================
  // NINTENDO 3DS
  // ==========================================================================
  EmulationGame(
    igdbId: 94101,
    name: 'The Legend of Zelda: A Link Between Worlds',
    canonicalNoIntroName:
        'Legend of Zelda, The - A Link Between Worlds (USA) (En,Fr,Es)',
    summary:
        'Alterne entre Hyrule e Lorule transformando-se em pintura nas paredes em 60 FPS.',
    genres: ['Aventura', 'RPG'],
    developer: 'Nintendo EAD',
    releaseYear: 2013,
    rating: 94,
    platformName: '3DS',
    platformSlug: '3ds',
    region: 'USA',
    estimatedSizeBytes: 680000000,
    directRomUrl: 'retroapi://3ds/A_Link_Between_Worlds.3ds',
  ),
  EmulationGame(
    igdbId: 94102,
    name: 'Mario Kart 7',
    canonicalNoIntroName: 'Mario Kart 7 (USA) (En,Fr,Es)',
    summary:
        'Corridas de kart com planadores, percursos submarinos e karts personalizáveis no 3DS.',
    genres: ['Corrida', 'Arcade'],
    developer: 'Nintendo EAD / Retro Studios',
    releaseYear: 2011,
    rating: 88,
    platformName: '3DS',
    platformSlug: '3ds',
    region: 'USA',
    estimatedSizeBytes: 640000000,
    directRomUrl: 'retroapi://3ds/Mario_Kart_7.3ds',
  ),

  // ==========================================================================
  // SONY PLAYSTATION 3 (PS3 EXPERIMENTAL — RPCS3 VULKAN + PS3UPDAT.PUP)
  // ==========================================================================
  EmulationGame(
    igdbId: 95101,
    name: 'Demon\'s Souls',
    canonicalNoIntroName: 'Demon\'s Souls (USA)',
    summary:
        'RPG de ação sombrio em Boletaria. Requer Vulkan + firmware PS3UPDAT.PUP importado nas Configurações.',
    genres: ['RPG', 'Ação'],
    developer: 'FromSoftware',
    releaseYear: 2009,
    rating: 91,
    platformName: 'PS3',
    platformSlug: 'ps3',
    region: 'USA',
    estimatedSizeBytes: 6200000000,
    directRomUrl: 'retroapi://ps3/Demons_Souls.iso',
  ),
  EmulationGame(
    igdbId: 95102,
    name: 'God of War III',
    canonicalNoIntroName: 'God of War III (USA)',
    summary:
        'O clímax da vingança de Kratos no Monte Olimpo. Core experimental via RPCS3 ARM64.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Santa Monica Studio',
    releaseYear: 2010,
    rating: 93,
    platformName: 'PS3',
    platformSlug: 'ps3',
    region: 'USA',
    estimatedSizeBytes: 8500000000,
    directRomUrl: 'retroapi://ps3/God_of_War_III.iso',
  ),

  // ==========================================================================
  // SEGA SATURN
  // ==========================================================================
  EmulationGame(
    igdbId: 96101,
    name: 'NiGHTS into Dreams...',
    canonicalNoIntroName: 'NiGHTS into Dreams... (USA)',
    summary:
        'Voe pelos sonhos de Nightopia em uma criação clássica da Sonic Team para Sega Saturn.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Sonic Team / Sega',
    releaseYear: 1996,
    rating: 90,
    platformName: 'SATURN',
    platformSlug: 'saturn',
    region: 'USA',
    estimatedSizeBytes: 420000000,
    directRomUrl: 'retroapi://saturn/NiGHTS_into_Dreams.chd',
  ),
  EmulationGame(
    igdbId: 96102,
    name: 'Panzer Dragoon II Zwei',
    canonicalNoIntroName: 'Panzer Dragoon II Zwei (USA)',
    summary:
        'Rail shooter atmosférico montado em dragão com múltiplos caminhos e evolução.',
    genres: ['Shooter', 'Ação'],
    developer: 'Team Andromeda / Sega',
    releaseYear: 1996,
    rating: 91,
    platformName: 'SATURN',
    platformSlug: 'saturn',
    region: 'USA',
    estimatedSizeBytes: 480000000,
    directRomUrl: 'retroapi://saturn/Panzer_Dragoon_II_Zwei.chd',
  ),

  // ==========================================================================
  // NEC PC ENGINE / TURBOGRAFX-16
  // ==========================================================================
  EmulationGame(
    igdbId: 97101,
    name: 'Bonk\'s Adventure',
    canonicalNoIntroName: 'Bonk\'s Adventure (USA)',
    summary:
        'Plataforma clássica com o mascote cabeçudo da NEC enfrentando dinossauros pré-históricos.',
    genres: ['Plataforma', 'Ação'],
    developer: 'Red Company / Hudson Soft',
    releaseYear: 1990,
    rating: 87,
    platformName: 'PC ENGINE',
    platformSlug: 'pce',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://pce/Bonks_Adventure.pce',
  ),
  EmulationGame(
    igdbId: 97102,
    name: 'Blazing Lazers',
    canonicalNoIntroName: 'Blazing Lazers (USA)',
    summary:
        'Um dos melhores shoot \'em ups verticais de 16-bit desenvolvido pela Compile.',
    genres: ['Shooter', 'Arcade'],
    developer: 'Compile / Hudson Soft',
    releaseYear: 1989,
    rating: 89,
    platformName: 'PC ENGINE',
    platformSlug: 'pce',
    region: 'USA',
    estimatedSizeBytes: 393216,
    directRomUrl: 'retroapi://pce/Blazing_Lazers.pce',
  ),

  // ==========================================================================
  // NINTENDO GAME BOY
  // ==========================================================================
  EmulationGame(
    igdbId: 98101,
    name: 'Super Mario Land 2: 6 Golden Coins',
    canonicalNoIntroName: 'Super Mario Land 2 - 6 Golden Coins (USA, Europe)',
    summary:
        'Estréia de Wario como rival de Mario em seis zonas temáticas no Game Boy clássico.',
    genres: ['Plataforma', 'Aventura'],
    developer: 'Nintendo R&D1',
    releaseYear: 1992,
    rating: 90,
    platformName: 'GAME BOY',
    platformSlug: 'gb',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gb/Super_Mario_Land_2.gb',
  ),
  EmulationGame(
    igdbId: 98102,
    name: 'The Legend of Zelda: Link\'s Awakening',
    canonicalNoIntroName: 'Legend of Zelda, The - Link\'s Awakening (USA, Europe)',
    summary:
        'Desperte o Peixe dos Ventos na misteriosa Ilha Koholint neste clássico atemporal.',
    genres: ['Aventura', 'RPG'],
    developer: 'Nintendo EAD',
    releaseYear: 1993,
    rating: 94,
    platformName: 'GAME BOY',
    platformSlug: 'gb',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gb/Links_Awakening.gb',
  ),

  // ==========================================================================
  // SEGA MASTER SYSTEM
  // ==========================================================================
  EmulationGame(
    igdbId: 99101,
    name: 'Alex Kidd in Miracle World',
    canonicalNoIntroName: 'Alex Kidd in Miracle World (USA, Europe)',
    summary:
        'Aventura clássica de 8-bit que marcou geração no Brasil e no mundo com Master System.',
    genres: ['Plataforma', 'Aventura'],
    developer: 'Sega',
    releaseYear: 1986,
    rating: 88,
    platformName: 'MASTER SYSTEM',
    platformSlug: 'mastersystem',
    region: 'USA',
    estimatedSizeBytes: 262144,
    directRomUrl: 'retroapi://mastersystem/Alex_Kidd_in_Miracle_World.sms',
  ),
  EmulationGame(
    igdbId: 99102,
    name: 'Phantasy Star',
    canonicalNoIntroName: 'Phantasy Star (USA, Europe)',
    summary:
        'RPG espacial pioneiro com masmorras 3D em primeira pessoa e trilha memorável.',
    genres: ['RPG', 'Aventura'],
    developer: 'Sega',
    releaseYear: 1987,
    rating: 92,
    platformName: 'MASTER SYSTEM',
    platformSlug: 'mastersystem',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://mastersystem/Phantasy_Star.sms',
  ),
  EmulationGame(
    igdbId: 670802711,
    name: 'Resident Evil 4: Wii Edition',
    canonicalNoIntroName: 'Resident Evil 4 - Wii Edition (USA)',
    summary:
        'Aclamada edição definitiva de Resident Evil 4 para Nintendo Wii com todos os extras e mira por movimento.',
    genres: ['Survival Horror', 'Ação'],
    developer: 'Capcom',
    releaseYear: 2007,
    rating: 94,
    platformName: 'WII',
    platformSlug: 'wii',
    region: 'USA',
    estimatedSizeBytes: 3519304180,
    directRomUrl:
        'https://archive.org/download/resident-evil-4-wii-edition-usa_202602/Resident%20Evil%204%20-%20Wii%20Edition%20%28USA%29.rvz',
  ),
  EmulationGame(
    igdbId: 1153328141,
    name: 'Street Fighter IV',
    canonicalNoIntroName: 'Street Fighter IV (USA)',
    summary:
        'O renascimento clássico da série Street Fighter em 2.5D para PlayStation 3.',
    genres: ['Luta', 'Arcade'],
    developer: 'Capcom / Dimps',
    releaseYear: 2009,
    rating: 92,
    platformName: 'PS3',
    platformSlug: 'ps3',
    region: 'USA',
    estimatedSizeBytes: 10441003619,
    directRomUrl:
        'https://archive.org/download/street-fighter-iv-ps3-games/Street%20Fighter%20IV%20%28USA%2C%20Asia%29%20%28En%2CJa%2CFr%2CDe%2CEs%2CIt%2CKo%29.7z',
  ),
  EmulationGame(
    igdbId: 1153328142,
    name: 'Super Street Fighter IV: 3D Edition',
    canonicalNoIntroName: 'Super Street Fighter IV - 3D Edition (USA)',
    summary:
        'Versão portátil completa para Nintendo 3DS com 35 lutadores e golpes em 60 FPS.',
    genres: ['Luta', 'Arcade'],
    developer: 'Capcom / Dimps',
    releaseYear: 2011,
    rating: 89,
    platformName: '3DS',
    platformSlug: '3ds',
    region: 'USA',
    estimatedSizeBytes: 1770424497,
    directRomUrl:
        'https://archive.org/download/20260424-140852/3DS0037%20-%20Super%20Street%20Fighter%20IV%203D%20Edition%20%28U%29.zip',
  ),
  EmulationGame(
    igdbId: 99201,
    name: 'Celeste Classic',
    canonicalNoIntroName: 'Celeste Classic (World) (Homebrew)',
    summary:
        'Port homebrew completo de Celeste Classic para Game Boy Advance feito por JeffRuLz.',
    genres: ['Plataforma', 'Indie'],
    developer: 'JeffRuLz / Maddy Makes Games',
    releaseYear: 2021,
    rating: 93,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'WORLD',
    estimatedSizeBytes: 5418424,
    directRomUrl:
        'https://github.com/JeffRuLz/Celeste-Classic-GBA/releases/download/v1.2/Celeste.Classic.v1.2.Homebrew.gba',
  ),
  EmulationGame(
    igdbId: 99202,
    name: 'Cave Story (Doukutsu Monogatari)',
    canonicalNoIntroName: 'Cave Story (PT-BR) (Mega Drive)',
    summary:
        'Obra-prima indie metroidvania portada nativamente para Sega Mega Drive em Português.',
    genres: ['Metroidvania', 'Indie', 'Plataforma'],
    developer: 'Studio Pixel / andwn',
    releaseYear: 2022,
    rating: 95,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'WORLD',
    estimatedSizeBytes: 4194304,
    directRomUrl:
        'https://github.com/andwn/cave-story-md/releases/download/v0.8.8/doukutsu-br.gen',
  ),
];
