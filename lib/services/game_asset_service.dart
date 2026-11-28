import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file/file.dart' as file_pkg;
import 'package:file/memory.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../models/emulation_game.dart';

/// Gerenciador de cache em **memória apenas** para uso com `CachedNetworkImage`.
///
/// Cumpre estritamente a regra de ZERO cache local persistente em disco:
/// utiliza [MemoryFileSystem] em RAM e nunca grava arquivos no armazenamento
/// persistente nem abre bancos SQLite.
class SessionMemoryCacheManager extends BaseCacheManager
    with ImageCacheManager {
  SessionMemoryCacheManager._({Dio? dio, bool? disableNetwork})
      : _disableNetwork = disableNetwork ??
            (dio == null && Platform.environment.containsKey('FLUTTER_TEST')),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 8),
                receiveTimeout: const Duration(seconds: 12),
                responseType: ResponseType.bytes,
                followRedirects: true,
                maxRedirects: 5,
                // Retorna a resposta mesmo para erros HTTP: o tratamento de
                // status fica em _performDownload, evitando exceções espelhadas.
                validateStatus: (status) =>
                    status != null && status >= 200 && status < 300,
                headers: const {
                  'User-Agent':
                      'LoopGamer/2.3 (https://github.com/bugaram/loopgamer)',
                },
              ),
            );

  /// Instância para testes com [Dio] mockado e rede habilitada.
  @visibleForTesting
  factory SessionMemoryCacheManager.forTesting({required Dio dio}) =>
      SessionMemoryCacheManager._(dio: dio, disableNetwork: false);

  static final SessionMemoryCacheManager instance = SessionMemoryCacheManager._();

  static const int _maxMemoryEntries = 140;

  final bool _disableNetwork;
  final Dio _dio;
  final MemoryFileSystem _memoryFs = MemoryFileSystem();
  final LinkedHashMap<String, _MemoryCacheEntry> _entries =
      LinkedHashMap<String, _MemoryCacheEntry>();
  final Map<String, Future<FileInfo>> _inFlight = {};
  int _fileSeq = 0;

  String _sanitizeKey(String key) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < key.length; i++) {
      hash ^= key.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return 'mem_${hash.toRadixString(16)}_${_fileSeq++}';
  }

  String _inferExtension(String url, String? contentType, String fallback) {
    final lowerCt = (contentType ?? '').toLowerCase();
    if (lowerCt.contains('png')) return 'png';
    if (lowerCt.contains('webp')) return 'webp';
    if (lowerCt.contains('jpeg') || lowerCt.contains('jpg')) return 'jpg';
    final path = url.split('?').first.toLowerCase();
    if (path.endsWith('.png')) return 'png';
    if (path.endsWith('.webp')) return 'webp';
    if (path.endsWith('.jpg') || path.endsWith('.jpeg')) return 'jpg';
    return fallback;
  }

  void _storeInMemory(String key, FileInfo info) {
    _entries.remove(key);
    _entries[key] = _MemoryCacheEntry(info: info);
    while (_entries.length > _maxMemoryEntries) {
      final oldestKey = _entries.keys.first;
      final removed = _entries.remove(oldestKey);
      if (removed != null) {
        try {
          if (removed.info.file.existsSync()) {
            removed.info.file.deleteSync();
          }
        } catch (_) {}
      }
    }
  }

  @override
  Future<file_pkg.File> getSingleFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async {
    final effectiveKey = key ?? url;
    final cached = await getFileFromCache(effectiveKey);
    if (cached != null) return cached.file;
    final info = await downloadFile(url, key: effectiveKey, authHeaders: headers);
    return info.file;
  }

  @override
  @Deprecated('Prefer to use the new getFileStream method')
  Stream<FileInfo> getFile(
    String url, {
    String? key,
    Map<String, String>? headers,
  }) async* {
    await for (final response in getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: false,
    )) {
      if (response is FileInfo) {
        yield response;
      }
    }
  }

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    final effectiveKey = key ?? url;
    final cached = await getFileFromMemory(effectiveKey);
    if (cached != null) {
      yield cached;
      return;
    }

    if (withProgress) {
      yield DownloadProgress(url, null, 0);
    }

    try {
      final info = await downloadFile(
        url,
        key: effectiveKey,
        authHeaders: headers,
      );
      yield info;
    } catch (e) {
      // URLs que respondem 404 são esperados para mídias que não existem
      // (ex.: thumbnails): conclui o stream sem gerar erro visível.
      if (e is HttpException && RegExp(r'\(\d{3}\)').hasMatch(e.message)) {
        return;
      }
      rethrow;
    }
  }

  @override
  Future<FileInfo> downloadFile(
    String url, {
    String? key,
    Map<String, String>? authHeaders,
    bool force = false,
  }) async {
    final effectiveKey = key ?? url;
    if (!force) {
      final existing = await getFileFromMemory(effectiveKey);
      if (existing != null) return existing;
    }

    final running = _inFlight[effectiveKey];
    if (running != null && !force) return running;

    final future = _performDownload(url, effectiveKey, authHeaders);
    _inFlight[effectiveKey] = future;
    try {
      return await future;
    } finally {
      if (identical(_inFlight[effectiveKey], future)) {
        unawaited(_inFlight.remove(effectiveKey));
      }
    }
  }

  Future<FileInfo> _performDownload(
    String url,
    String key,
    Map<String, String>? authHeaders,
  ) async {
    if (_disableNetwork) {
      throw HttpException(
        'Network disabled during FLUTTER_TEST',
        uri: Uri.tryParse(url),
      );
    }
    final response = await _dio.get<List<int>>(
      url,
      options: Options(
        headers: authHeaders,
        responseType: ResponseType.bytes,
      ),
    );
    final status = response.statusCode ?? 0;
    final data = response.data;
    final contentType = response.headers.value(Headers.contentTypeHeader);
    if (status < 200 ||
        status >= 300 ||
        data == null ||
        data.isEmpty ||
        (contentType != null && contentType.toLowerCase().contains('text/html'))) {
      throw HttpException(
        'Falha ao carregar imagem ($status)',
        uri: Uri.tryParse(url),
      );
    }

    final ext = _inferExtension(url, contentType, 'png');
    final bytes = Uint8List.fromList(data);
    return _writeBytesToMemoryFile(
      url: url,
      key: key,
      bytes: bytes,
      fileExtension: ext,
      source: FileSource.Online,
    );
  }

  FileInfo _writeBytesToMemoryFile({
    required String url,
    required String key,
    required Uint8List bytes,
    required String fileExtension,
    required FileSource source,
    Duration maxAge = const Duration(hours: 12),
  }) {
    final path = '/${_sanitizeKey(key)}.$fileExtension';
    final file = _memoryFs.file(path);
    file.writeAsBytesSync(bytes, flush: true);
    final info = FileInfo(
      file,
      source,
      DateTime.now().add(maxAge),
      url,
    );
    _storeInMemory(key, info);
    return info;
  }

  @override
  Future<FileInfo?> getFileFromCache(
    String key, {
    bool ignoreMemCache = false,
  }) async {
    if (ignoreMemCache) return null;
    return getFileFromMemory(key);
  }

  @override
  Future<FileInfo?> getFileFromMemory(String key) async {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!entry.info.file.existsSync()) {
      _entries.remove(key);
      return null;
    }
    return entry.info;
  }

  @override
  Future<file_pkg.File> putFile(
    String url,
    Uint8List fileBytes, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final effectiveKey = key ?? url;
    final info = _writeBytesToMemoryFile(
      url: url,
      key: effectiveKey,
      bytes: fileBytes,
      fileExtension: fileExtension,
      source: FileSource.Cache,
      maxAge: maxAge,
    );
    return info.file;
  }

  @override
  Future<file_pkg.File> putFileStream(
    String url,
    Stream<List<int>> source, {
    String? key,
    String? eTag,
    Duration maxAge = const Duration(days: 30),
    String fileExtension = 'file',
  }) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in source) {
      builder.add(chunk);
    }
    return putFile(
      url,
      builder.takeBytes(),
      key: key,
      eTag: eTag,
      maxAge: maxAge,
      fileExtension: fileExtension,
    );
  }

  @override
  Future<void> removeFile(String key) async {
    final removed = _entries.remove(key);
    if (removed != null) {
      try {
        if (removed.info.file.existsSync()) {
          removed.info.file.deleteSync();
        }
      } catch (_) {}
    }
  }

  @override
  Future<void> emptyCache() async {
    for (final entry in _entries.values) {
      try {
        if (entry.info.file.existsSync()) {
          entry.info.file.deleteSync();
        }
      } catch (_) {}
    }
    _entries.clear();
  }

  @override
  Future<void> dispose() async {
    await emptyCache();
  }
}

class _MemoryCacheEntry {
  const _MemoryCacheEntry({required this.info});
  final FileInfo info;
}

/// Conjunto de URLs de mídia resolvidas em memória para um jogo.
class GameAssets {
  const GameAssets({
    this.backgroundImageUrl,
    this.coverImageUrl,
    this.logoImageUrl,
    this.alternativeImageUrl,
    this.source = 'procedural',
  });

  const GameAssets.empty()
      : backgroundImageUrl = null,
        coverImageUrl = null,
        logoImageUrl = null,
        alternativeImageUrl = null,
        source = 'procedural';

  final String? backgroundImageUrl;
  final String? coverImageUrl;
  final String? logoImageUrl;
  final String? alternativeImageUrl;
  final String source;

  bool get hasLogo => logoImageUrl != null && logoImageUrl!.isNotEmpty;
  bool get hasBackground =>
      backgroundImageUrl != null && backgroundImageUrl!.isNotEmpty;
  bool get hasCover => coverImageUrl != null && coverImageUrl!.isNotEmpty;

  GameAssets mergeWith(GameAssets other) {
    return GameAssets(
      backgroundImageUrl: _nonEmpty(backgroundImageUrl) ??
          _nonEmpty(other.backgroundImageUrl),
      coverImageUrl:
          _nonEmpty(coverImageUrl) ?? _nonEmpty(other.coverImageUrl),
      logoImageUrl: _nonEmpty(logoImageUrl) ?? _nonEmpty(other.logoImageUrl),
      alternativeImageUrl: _nonEmpty(alternativeImageUrl) ??
          _nonEmpty(other.alternativeImageUrl),
      source: source != 'procedural' ? source : other.source,
    );
  }

  static String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _AsyncRequestSemaphore {
  _AsyncRequestSemaphore(this.maxConcurrent);

  final int maxConcurrent;
  int _active = 0;
  final Queue<Completer<void>> _waiters = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active < maxConcurrent) {
      _active++;
    } else {
      final waiter = Completer<void>();
      _waiters.addLast(waiter);
      await waiter.future;
    }
    try {
      return await task();
    } finally {
      if (_waiters.isNotEmpty) {
        final next = _waiters.removeFirst();
        if (!next.isCompleted) next.complete();
      } else {
        _active--;
      }
    }
  }
}

/// Serviço unificado de assets de jogos (banners, capas 3:4 e clear logos PNG).
///
/// Fontes suportadas sem exigir chave de API (out-of-the-box):
/// 1. **Steam Store Search + Steam CDN** (`logo.png` transparente,
///    `library_hero.jpg`, `library_600x900_2x.jpg`)
/// 2. **GOG Catalog API** (`logo` PNG transparente, `coverVertical`,
///    `galaxyBackgroundImage`)
/// 3. **Wikidata (`P154` / `P179`) + Wikimedia Commons API** (clear logos
///    PNG/SVG convertidos via `Special:FilePath?width=512`)
/// 4. **Libretro Thumbnails CDN** (`Named_Boxarts`, `Named_Snaps`)
///
/// Também suporta **RAWG** (`background_image` / `background_image_additional`)
/// e **SteamGridDB** (`logos` / `heroes` / `grids`) quando chaves opcionais são
/// fornecidas via `--dart-define=RAWG_API_KEY=...` ou `SGDB_API_KEY=...`.
///
/// Usa **exclusivamente cache em memória da sessão** (zero gravação em disco).
class GameAssetService {
  GameAssetService({
    Dio? dio,
    this.rawgApiKey = const String.fromEnvironment('RAWG_API_KEY'),
    this.steamGridDbApiKey = const String.fromEnvironment('SGDB_API_KEY'),
    bool? disableNetwork,
  })  : _hasCustomDio = dio != null,
        _disableNetwork = disableNetwork ??
            (dio == null && Platform.environment.containsKey('FLUTTER_TEST')),
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 7),
                receiveTimeout: const Duration(seconds: 10),
                validateStatus: (status) => status != null && status < 500,
                headers: const {
                  'User-Agent':
                      'LoopGamer/2.3 (https://github.com/bugaram/loopgamer)',
                },
              ),
            );

  static final GameAssetService instance = GameAssetService();

  final bool _hasCustomDio;
  final bool _disableNetwork;
  final Dio _dio;
  final String rawgApiKey;
  final String steamGridDbApiKey;

  final _AsyncRequestSemaphore _semaphore = _AsyncRequestSemaphore(4);
  bool _isDisposed = false;

  static const int _maxCacheSize = 300;
  static final LinkedHashMap<String, GameAssets> _sessionCache =
      LinkedHashMap<String, GameAssets>();
  static final Map<String, Future<GameAssets>> _inFlight = {};

  /// Limpa o cache em memória da sessão (útil em testes).
  @visibleForTesting
  static void clearMemoryCache() {
    _sessionCache.clear();
    _inFlight.clear();
  }

  /// Pré-popula cache em memória para testes ou dados já conhecidos.
  @visibleForTesting
  static void seedMemoryCache(String gameName, GameAssets assets) {
    _sessionCache[_cacheKey(gameName)] = assets;
  }

  /// Consulta síncrona ao cache em memória da sessão.
  GameAssets? getCachedAssets(String gameName, {String? platformSlug}) {
    final scopedKey = platformSlug != null && platformSlug.isNotEmpty
        ? _cacheKey('$gameName|$platformSlug')
        : null;
    if (scopedKey != null && _sessionCache.containsKey(scopedKey)) {
      return _sessionCache[scopedKey];
    }
    return _sessionCache[_cacheKey(gameName)];
  }

  static String _cacheKey(String rawTitle) {
    final cleaned = cleanGameTitle(rawTitle);
    final norm = EmulationGame.normalizeSearchText(cleaned);
    return norm.isNotEmpty ? norm : cleaned.toLowerCase();
  }

  /// Remove sufixos regionais/revisão (`(USA)`, `(Rev 1)`, `[!]`, etc.) para buscas.
  static String cleanGameTitle(String rawTitle) {
    var out = rawTitle
        .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
        .replaceAll(RegExp(r'\s*\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'[®™©]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (out.isEmpty) out = rawTitle.trim();
    return out;
  }

  /// Extrai o título base da franquia antes de `:` ou ` - ` (ex.: `God of War`).
  static String? extractFranchiseTitle(String cleanTitle) {
    final colonIdx = cleanTitle.indexOf(':');
    if (colonIdx > 2) {
      return cleanTitle.substring(0, colonIdx).trim();
    }
    final dashIdx = cleanTitle.indexOf(' - ');
    if (dashIdx > 2) {
      return cleanTitle.substring(0, dashIdx).trim();
    }
    return null;
  }

  static const Set<String> _stopWords = {
    'the',
    'of',
    'and',
    'a',
    'an',
    'in',
    'on',
    'to',
    'for',
    'edition',
    'remastered',
    'collection',
    'hd',
    'definitive',
    'complete',
  };

  static const Set<String> _noiseModifiers = {
    'soundtrack',
    'ost',
    'artbook',
    'wallpaper',
    'demo',
    'trial',
    'dlc',
    'season pass',
    'upgrade',
    'pack',
    'pass',
    'bundle',
    'guide',
    'trailer',
  };

  static List<String> _significantTokens(String text) {
    return EmulationGame.normalizeSearchText(text)
        .split(' ')
        .where((t) => t.isNotEmpty && !_stopWords.contains(t))
        .toList();
  }

  static const Set<String> _editionAndSequelTokens = {
    '0',
    '1',
    '2',
    '3',
    '4',
    '5',
    '6',
    '7',
    '8',
    '9',
    'ii',
    'iii',
    'iv',
    'v',
    'vi',
    'zero',
    'gaiden',
    'survivor',
    'outbreak',
    'veronica',
    'revelations',
    'village',
    'biohazard',
    'nemesis',
    'director',
    'remake',
    'remaster',
    'alpha',
    'turbo',
    'super',
    'hyper',
    'ultra',
    'champion',
    'max',
    'portable',
    'classic',
    'advance',
    'pocket',
    '3d',
    '64',
    'ds',
    'wii',
    'x',
    'plus',
    'ex',
  };

  /// Calcula similaridade normalizada `[0.0, 1.0]` entre título buscado e candidato.
  static double titleSimilarityScore(String query, String candidate) {
    final qNorm = EmulationGame.normalizeSearchText(cleanGameTitle(query));
    final cNorm = EmulationGame.normalizeSearchText(cleanGameTitle(candidate));
    if (qNorm.isEmpty || cNorm.isEmpty) return 0.0;
    if (qNorm == cNorm) return 1.0;

    // Penaliza fortemente DLC/Soundtrack/Pack quando não foi solicitado.
    for (final noise in _noiseModifiers) {
      if (cNorm.contains(noise) && !qNorm.contains(noise)) {
        return 0.0;
      }
    }

    final qTokens = _significantTokens(qNorm).toSet();
    final cTokens = _significantTokens(cNorm).toSet();
    if (qTokens.isEmpty || cTokens.isEmpty) return 0.0;

    // Evita cruzar versões/sequências diferentes (ex.: Resident Evil 1/Gaiden vs 2/4/Remake)
    for (final tok in cTokens) {
      if (_editionAndSequelTokens.contains(tok) && !qTokens.contains(tok)) {
        return 0.0;
      }
    }
    for (final tok in qTokens) {
      if (_editionAndSequelTokens.contains(tok) && !cTokens.contains(tok)) {
        return 0.0;
      }
    }

    final matches = qTokens.intersection(cTokens).length;
    if (matches == 0) return 0.0;

    final recall = matches / qTokens.length;
    final precision = matches / cTokens.length;
    final f1 = (2 * recall * precision) / (recall + precision);

    if (cNorm.startsWith('$qNorm ') || qNorm.startsWith('$cNorm ')) {
      return (f1 + 0.15).clamp(0.0, 0.96);
    }
    return f1;
  }

  /// Resolve `backgroundImageUrl`, `coverImageUrl` e `logoImageUrl` para um [EmulationGame].
  Future<GameAssets> fetchAssetsForGame(EmulationGame game) async {
    return fetchAssetsByTitle(
      game.name,
      platformSlug: game.platformSlug,
      existingBackgroundUrl: game.heroBannerUrl,
      existingCoverUrl: game.gridCoverUrl,
      existingLogoUrl: game.logoUrl,
      fallbackBoxartUrl: game.resolvedGridCoverUrl,
      fallbackSnapUrl: game.resolvedHeroBannerUrl,
    );
  }

  /// Busca e combina assets em memória da sessão sem gravar nada em disco.
  Future<GameAssets> fetchAssetsByTitle(
    String rawTitle, {
    String? platformSlug,
    String? existingBackgroundUrl,
    String? existingCoverUrl,
    String? existingLogoUrl,
    String? fallbackBoxartUrl,
    String? fallbackSnapUrl,
  }) async {
    final cleanTitle = cleanGameTitle(rawTitle);
    if (cleanTitle.isEmpty) return const GameAssets.empty();

    final normalizedSlug = platformSlug?.trim().toLowerCase() ?? '';
    final baseKey = _cacheKey(cleanTitle);
    final scopedKey = normalizedSlug.isNotEmpty
        ? _cacheKey('$cleanTitle|$normalizedSlug')
        : baseKey;

    final cached = scopedKey != baseKey
        ? _sessionCache[scopedKey]
        : _sessionCache[baseKey];
    if (cached != null) return cached;

    final seeded = GameAssets(
      backgroundImageUrl: existingBackgroundUrl,
      coverImageUrl: existingCoverUrl,
      logoImageUrl: existingLogoUrl,
      source: (existingBackgroundUrl != null ||
              existingCoverUrl != null ||
              existingLogoUrl != null)
          ? 'game_model'
          : 'procedural',
    );

    if (_disableNetwork || _isDisposed) {
      return seeded;
    }

    final existingFlight = _inFlight[scopedKey];
    if (existingFlight != null) return existingFlight;

    final future = _semaphore.run(
      () => _resolvePipeline(
        cleanTitle: cleanTitle,
        platformSlug: normalizedSlug,
        seeded: seeded,
        fallbackBoxartUrl: fallbackBoxartUrl,
        fallbackSnapUrl: fallbackSnapUrl,
      ),
    );
    _inFlight[scopedKey] = future;

    try {
      final resolved = await future;
      _putInMemoryCache(scopedKey, resolved);
      if (scopedKey != baseKey &&
          resolved.hasLogo &&
          !_sessionCache.containsKey(baseKey)) {
        _putInMemoryCache(
          baseKey,
          GameAssets(logoImageUrl: resolved.logoImageUrl, source: resolved.source),
        );
      }
      return resolved;
    } finally {
      if (identical(_inFlight[scopedKey], future)) {
        unawaited(_inFlight.remove(scopedKey));
      }
    }
  }

  void _putInMemoryCache(String key, GameAssets value) {
    _sessionCache.remove(key);
    _sessionCache[key] = value;
    while (_sessionCache.length > _maxCacheSize) {
      _sessionCache.remove(_sessionCache.keys.first);
    }
  }

  Future<String?> _resolveLibretroThumbnail(
    String cleanTitle,
    String platformSlug, {
    required String kind, // 'Named_Boxarts' | 'Named_Snaps'
    String? primaryCandidateUrl,
  }) async {
    final candidates = <String>[
      if (primaryCandidateUrl != null && primaryCandidateUrl.isNotEmpty)
        primaryCandidateUrl,
    ];

    final sanitized = cleanTitle
        .replaceAll(RegExp(r'[&\*/:`<>?\\|"]'), '_')
        .trim();
    if (sanitized.isNotEmpty && platformSlug.isNotEmpty) {
      final playlists = <String>[
        EmulationGame(
          igdbId: 0,
          name: cleanTitle,
          canonicalNoIntroName: cleanTitle,
          summary: '',
          genres: const [],
          developer: '',
          releaseYear: null,
          rating: 0,
          platformName: platformSlug,
          platformSlug: platformSlug,
          directRomUrl: '',
        ).libretroPlaylistName,
        if (platformSlug == 'cps1' || platformSlug == 'cps2') 'MAME',
      ];
      const suffixes = ['(USA)', '(USA) (Disc 1)', '(World)', '(Europe)', ''];
      for (final playlist in playlists.toSet()) {
        for (final sfx in suffixes) {
          final fileName = sfx.isEmpty ? '$sanitized.png' : '$sanitized $sfx.png';
          final url =
              'https://thumbnails.libretro.com/${Uri.encodeComponent(playlist)}/$kind/${Uri.encodeComponent(fileName)}';
          if (!candidates.contains(url)) candidates.add(url);
        }
      }
    }

    for (final url in candidates.take(6)) {
      if (await _isUrlReachable(url)) {
        return url;
      }
    }
    return null;
  }

  Future<GameAssets> _resolvePipeline({
    required String cleanTitle,
    required String platformSlug,
    required GameAssets seeded,
    String? fallbackBoxartUrl,
    String? fallbackSnapUrl,
  }) async {
    var acc = seeded;

    // 1. Capas/snaps autênticos da plataforma via Libretro Thumbnails primeiro
    if (!acc.hasCover &&
        (platformSlug.isNotEmpty ||
            (fallbackBoxartUrl != null && fallbackBoxartUrl.isNotEmpty))) {
      final boxartUrl = await _resolveLibretroThumbnail(
        cleanTitle,
        platformSlug,
        kind: 'Named_Boxarts',
        primaryCandidateUrl: fallbackBoxartUrl,
      );
      if (boxartUrl != null) {
        acc = acc.mergeWith(
          GameAssets(coverImageUrl: boxartUrl, source: 'libretro'),
        );
      }
    }
    if (!acc.hasBackground &&
        (platformSlug.isNotEmpty ||
            (fallbackSnapUrl != null && fallbackSnapUrl.isNotEmpty))) {
      final snapUrl = await _resolveLibretroThumbnail(
        cleanTitle,
        platformSlug,
        kind: 'Named_Snaps',
        primaryCandidateUrl: fallbackSnapUrl,
      );
      if (snapUrl != null) {
        acc = acc.mergeWith(
          GameAssets(backgroundImageUrl: snapUrl, source: 'libretro'),
        );
      }
    }

    // 2. Opcionais com chave (quando configurados pelo ambiente)
    final keyedTasks = <Future<GameAssets>>[];
    if (steamGridDbApiKey.trim().isNotEmpty &&
        (!acc.hasLogo || !acc.hasBackground || !acc.hasCover)) {
      keyedTasks.add(_fetchFromSteamGridDb(cleanTitle));
    }
    if (rawgApiKey.trim().isNotEmpty &&
        (!acc.hasBackground || !acc.hasCover || !acc.hasLogo)) {
      keyedTasks.add(_fetchFromRawg(cleanTitle));
    }
    if (keyedTasks.isNotEmpty) {
      final results = await Future.wait(keyedTasks);
      for (final res in results) {
        acc = acc.mergeWith(res);
      }
    }

    // 3. Fontes 100% sem chave (Steam Store/CDN + GOG Catalog + Wikidata/Commons)
    if (!acc.hasLogo || !acc.hasBackground || !acc.hasCover) {
      final keylessPrimary = await Future.wait([
        _fetchFromSteam(cleanTitle),
        _fetchFromGog(cleanTitle),
      ]);
      for (final res in keylessPrimary) {
        acc = acc.mergeWith(res);
      }
    }

    if (!acc.hasLogo || !acc.hasBackground) {
      final wikiAssets = await _fetchFromWikidataAndCommons(cleanTitle);
      acc = acc.mergeWith(wikiAssets);
    }

    return acc;
  }

  Future<bool> _isUrlReachable(String url) async {
    try {
      final res = await _dio.head<void>(
        url,
        options: Options(
          followRedirects: true,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      final code = res.statusCode ?? 0;
      if (code < 200 || code >= 300) return false;
      final ct = res.headers.value(Headers.contentTypeHeader)?.toLowerCase();
      if (ct != null && ct.contains('text/html')) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ===========================================================================
  // RAWG (opcional com RAWG_API_KEY)
  // ===========================================================================
  Future<GameAssets> _fetchFromRawg(String title) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://api.rawg.io/api/games',
        queryParameters: {
          'key': rawgApiKey,
          'search': title,
          'page_size': 5,
        },
      );
      if ((res.statusCode ?? 0) < 200 || (res.statusCode ?? 0) >= 300) {
        return const GameAssets.empty();
      }
      final results = res.data?['results'] as List<dynamic>?;
      if (results == null || results.isEmpty) return const GameAssets.empty();

      Map<String, dynamic>? best;
      double bestScore = 0.0;
      for (final item in results) {
        if (item is! Map<String, dynamic>) continue;
        final name = '${item['name'] ?? ''}';
        final score = titleSimilarityScore(title, name);
        if (score > bestScore) {
          bestScore = score;
          best = item;
        }
      }
      if (best == null || bestScore < 0.55) return const GameAssets.empty();

      final bg = best['background_image'] as String?;
      final additional = best['background_image_additional'] as String?;
      String? screenshotFallback;
      final shots = best['short_screenshots'] as List<dynamic>?;
      if (shots != null && shots.length > 1) {
        screenshotFallback =
            (shots[1] as Map<String, dynamic>?)?['image'] as String?;
      }
      return GameAssets(
        backgroundImageUrl: bg,
        coverImageUrl: additional ?? bg,
        alternativeImageUrl: additional ?? screenshotFallback ?? bg,
        source: 'rawg',
      );
    } catch (e) {
      debugPrint('[GameAssetService] RAWG fallback error: $e');
      return const GameAssets.empty();
    }
  }

  // ===========================================================================
  // SteamGridDB (opcional com SGDB_API_KEY)
  // ===========================================================================
  Future<GameAssets> _fetchFromSteamGridDb(String title) async {
    try {
      final headers = {'Authorization': 'Bearer $steamGridDbApiKey'};
      final encoded = Uri.encodeComponent(title);
      final searchRes = await _dio.get<Map<String, dynamic>>(
        'https://www.steamgriddb.com/api/v2/search/autocomplete/$encoded',
        options: Options(headers: headers),
      );
      if ((searchRes.statusCode ?? 0) < 200 ||
          (searchRes.statusCode ?? 0) >= 300) {
        return const GameAssets.empty();
      }
      final data = searchRes.data?['data'] as List<dynamic>?;
      if (data == null || data.isEmpty) return const GameAssets.empty();

      int? gameId;
      double bestScore = 0.0;
      for (final item in data) {
        if (item is! Map<String, dynamic>) continue;
        final score = titleSimilarityScore(title, '${item['name'] ?? ''}');
        if (score > bestScore) {
          bestScore = score;
          gameId = (item['id'] as num?)?.toInt();
        }
      }
      // Nunca usa o primeiro resultado "por padrão": autocomplete devolve
      // títulos como "F" para buscas sem correspondência exata, e isso já
      // colocou a capa do jogo errado em Silent Hill.
      if (gameId == null || bestScore < 0.55) {
        return const GameAssets.empty();
      }

      final responses = await Future.wait([
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/logos/game/$gameId',
          options: Options(headers: headers),
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/heroes/game/$gameId',
          options: Options(headers: headers),
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/grids/game/$gameId?dimensions=600x900',
          options: Options(headers: headers),
        ),
      ]);

      String? firstAssetUrl(Response<Map<String, dynamic>> r) {
        if ((r.statusCode ?? 0) < 200 || (r.statusCode ?? 0) >= 300) {
          return null;
        }
        final list = r.data?['data'] as List<dynamic>?;
        if (list == null || list.isEmpty) return null;
        return (list.first as Map<String, dynamic>?)?['url'] as String?;
      }

      return GameAssets(
        logoImageUrl: firstAssetUrl(responses[0]),
        backgroundImageUrl: firstAssetUrl(responses[1]),
        coverImageUrl: firstAssetUrl(responses[2]),
        source: 'steamgriddb',
      );
    } catch (e) {
      debugPrint('[GameAssetService] SteamGridDB error: $e');
      return const GameAssets.empty();
    }
  }

  // ===========================================================================
  // Fonte Sem Chave 1: Steam Store Search + Steam CDN
  // ===========================================================================
  Future<GameAssets> _fetchFromSteam(String title) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://store.steampowered.com/api/storesearch/',
        queryParameters: {
          'term': title,
          'l': 'english',
          'cc': 'US',
        },
      );
      if ((res.statusCode ?? 0) < 200 || (res.statusCode ?? 0) >= 300) {
        return const GameAssets.empty();
      }
      final items = res.data?['items'] as List<dynamic>?;
      if (items == null || items.isEmpty) return const GameAssets.empty();

      int? bestId;
      double bestScore = 0.0;
      for (final raw in items) {
        if (raw is! Map<String, dynamic>) continue;
        final name = '${raw['name'] ?? ''}';
        final score = titleSimilarityScore(title, name);
        if (score > bestScore) {
          bestScore = score;
          bestId = (raw['id'] as num?)?.toInt();
        }
      }
      if (bestId == null || bestScore < 0.55) return const GameAssets.empty();

      const cdnBase = 'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps';
      final logoCandidate = '$cdnBase/$bestId/logo.png';
      final heroCandidate = '$cdnBase/$bestId/library_hero.jpg';
      final coverCandidate = '$cdnBase/$bestId/library_600x900_2x.jpg';

      final checks = await Future.wait([
        _isUrlReachable(logoCandidate),
        _isUrlReachable(heroCandidate),
        _isUrlReachable(coverCandidate),
      ]);

      String? logoUrl = checks[0] ? logoCandidate : null;
      String? heroUrl = checks[1] ? heroCandidate : null;
      final String? coverUrl = checks[2] ? coverCandidate : null;

      heroUrl ??= await _fetchSteamAppDetailsBackground(bestId);

      if (logoUrl == null && heroUrl == null && coverUrl == null) {
        return const GameAssets.empty();
      }
      return GameAssets(
        logoImageUrl: logoUrl,
        backgroundImageUrl: heroUrl,
        coverImageUrl: coverUrl,
        source: 'steam_keyless',
      );
    } catch (e) {
      debugPrint('[GameAssetService] Steam keyless lookup error: $e');
      return const GameAssets.empty();
    }
  }

  Future<String?> _fetchSteamAppDetailsBackground(int appId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://store.steampowered.com/api/appdetails',
        queryParameters: {'appids': appId},
      );
      final appData = res.data?['$appId'] as Map<String, dynamic>?;
      if (appData?['success'] != true) return null;
      final data = appData?['data'] as Map<String, dynamic>?;
      if (data == null) return null;
      return (data['background_raw'] as String?) ??
          (data['background'] as String?) ??
          (data['header_image'] as String?);
    } catch (_) {
      return null;
    }
  }

  // ===========================================================================
  // Fonte Sem Chave 2: GOG Public Catalog API
  // ===========================================================================
  Future<GameAssets> _fetchFromGog(String title) async {
    try {
      final res = await _dio.get<dynamic>(
        'https://catalog.gog.com/v1/catalog',
        queryParameters: {
          'limit': 6,
          'query': 'like:$title',
        },
      );
      if ((res.statusCode ?? 0) < 200 ||
          (res.statusCode ?? 0) >= 300 ||
          res.data is! Map<String, dynamic>) {
        return const GameAssets.empty();
      }
      final data = res.data as Map<String, dynamic>;
      final products = data['products'] as List<dynamic>?;
      if (products == null || products.isEmpty) return const GameAssets.empty();

      Map<String, dynamic>? best;
      double bestScore = 0.0;
      for (final raw in products) {
        if (raw is! Map<String, dynamic>) continue;
        final name = '${raw['title'] ?? ''}';
        final score = titleSimilarityScore(title, name);
        if (score > bestScore) {
          bestScore = score;
          best = raw;
        }
      }
      if (best == null || bestScore < 0.55) return const GameAssets.empty();

      final logo = best['logo'] as String?;
      final bg = (best['galaxyBackgroundImage'] as String?) ??
          (best['coverHorizontal'] as String?);
      final cover = best['coverVertical'] as String?;

      if (logo == null && bg == null && cover == null) {
        return const GameAssets.empty();
      }
      return GameAssets(
        logoImageUrl: logo,
        backgroundImageUrl: bg,
        coverImageUrl: cover,
        source: 'gog_keyless',
      );
    } catch (e) {
      debugPrint('[GameAssetService] GOG keyless lookup error: $e');
      return const GameAssets.empty();
    }
  }

  // ===========================================================================
  // Fonte Sem Chave 3: Wikidata (P154 / P179) + Wikimedia Commons Search
  // ===========================================================================
  Future<GameAssets> _fetchFromWikidataAndCommons(String title) async {
    try {
      String? logoUrl = await _fetchLogoFromWikidata(title);
      logoUrl ??= await _fetchLogoFromCommonsSearch(title);

      final franchise = extractFranchiseTitle(title);
      if (logoUrl == null && franchise != null && franchise.length >= 4) {
        logoUrl = await _fetchLogoFromWikidata(franchise);
        logoUrl ??= await _fetchLogoFromCommonsSearch(franchise);
      }

      if (logoUrl == null) return const GameAssets.empty();
      return GameAssets(
        logoImageUrl: logoUrl,
        source: 'wikimedia_keyless',
      );
    } catch (e) {
      debugPrint('[GameAssetService] Wikimedia keyless lookup error: $e');
      return const GameAssets.empty();
    }
  }

  Future<String?> _fetchLogoFromWikidata(String title) async {
    try {
      final searchRes = await _dio.get<Map<String, dynamic>>(
        'https://www.wikidata.org/w/api.php',
        queryParameters: {
          'action': 'wbsearchentities',
          'search': title,
          'language': 'en',
          'format': 'json',
          'limit': 5,
        },
      );
      final results = searchRes.data?['search'] as List<dynamic>?;
      if (results == null || results.isEmpty) return null;

      String? bestEntityId;
      double bestRank = 0.0;
      for (final raw in results) {
        if (raw is! Map<String, dynamic>) continue;
        final label = '${raw['label'] ?? ''}';
        final desc = '${raw['description'] ?? ''}'.toLowerCase();
        var score = titleSimilarityScore(title, label);
        if (score < 0.55) continue;
        if (desc.contains('video game') ||
            desc.contains('game series') ||
            desc.contains('franchise')) {
          score += 0.25;
        }
        if (score > bestRank) {
          bestRank = score;
          bestEntityId = raw['id'] as String?;
        }
      }
      if (bestEntityId == null) return null;

      final p154File = await _readEntityLogoClaim(bestEntityId);
      if (p154File != null) {
        return _commonsFileUrl(p154File);
      }

      // Fallback para série/franquia (P179 -> P154), ex.: sub-títulos de PSP
      final seriesId = await _readEntitySeriesId(bestEntityId);
      if (seriesId != null) {
        final seriesLogoFile = await _readEntityLogoClaim(seriesId);
        if (seriesLogoFile != null) {
          return _commonsFileUrl(seriesLogoFile);
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> _readEntityLogoClaim(String entityId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'https://www.wikidata.org/w/api.php',
      queryParameters: {
        'action': 'wbgetclaims',
        'entity': entityId,
        'property': 'P154',
        'format': 'json',
      },
    );
    final claims = res.data?['claims'] as Map<String, dynamic>?;
    final list = claims?['P154'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;
    final snak = (list.first as Map<String, dynamic>?)?['mainsnak']
        as Map<String, dynamic>?;
    final value =
        (snak?['datavalue'] as Map<String, dynamic>?)?['value'] as String?;
    if (value == null || !_isTransparentLogoFile(value)) return null;
    return value;
  }

  Future<String?> _readEntitySeriesId(String entityId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'https://www.wikidata.org/w/api.php',
      queryParameters: {
        'action': 'wbgetclaims',
        'entity': entityId,
        'property': 'P179',
        'format': 'json',
      },
    );
    final claims = res.data?['claims'] as Map<String, dynamic>?;
    final list = claims?['P179'] as List<dynamic>?;
    if (list == null || list.isEmpty) return null;
    final snak = (list.first as Map<String, dynamic>?)?['mainsnak']
        as Map<String, dynamic>?;
    final val = snak?['datavalue']?['value'] as Map<String, dynamic>?;
    return val?['id'] as String?;
  }

  Future<String?> _fetchLogoFromCommonsSearch(String title) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        'https://commons.wikimedia.org/w/api.php',
        queryParameters: {
          'action': 'query',
          'list': 'search',
          'srnamespace': 6,
          'srsearch': '$title logo',
          'srlimit': 8,
          'format': 'json',
        },
      );
      final search = res.data?['query']?['search'] as List<dynamic>?;
      if (search == null || search.isEmpty) return null;

      String? bestFile;
      double bestScore = 0.0;
      for (final raw in search) {
        if (raw is! Map<String, dynamic>) continue;
        final rawFile = '${raw['title'] ?? ''}'.replaceFirst('File:', '');
        if (!_isTransparentLogoFile(rawFile)) continue;

        final lowerFile = rawFile.toLowerCase();
        if (!lowerFile.contains('logo') && !lowerFile.contains('wordmark')) {
          continue;
        }

        // Remove extensão e palavras genéricas ("logo", "wordmark") antes de medir match
        final stripped = rawFile
            .replaceAll(RegExp(r'\.(png|svg|webp)$', caseSensitive: false), '')
            .replaceAll(
              RegExp(r'\b(logo|wordmark|game|video|series|ntsc|pal|jp)\b',
                  caseSensitive: false),
              ' ',
            )
            .trim();
        final score = titleSimilarityScore(title, stripped);
        if (score > bestScore) {
          bestScore = score;
          bestFile = rawFile;
        }
      }

      if (bestFile == null || bestScore < 0.65) return null;
      return _commonsFileUrl(bestFile);
    } catch (_) {
      return null;
    }
  }

  static bool _isTransparentLogoFile(String filename) {
    final lower = filename.trim().toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.svg') ||
        lower.endsWith('.webp');
  }

  static String _commonsFileUrl(String filename) {
    final normalized = filename.replaceFirst('File:', '').replaceAll(' ', '_');
    return 'https://commons.wikimedia.org/wiki/Special:FilePath/${Uri.encodeComponent(normalized)}?width=512';
  }

  void dispose() {
    _isDisposed = true;
    if (!_hasCustomDio) {
      _dio.close(force: true);
    }
  }
}
