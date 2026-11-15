import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/emulation_game.dart';

class LibraryStorageService {
  static const int currentManifestVersion = 1;

  static Future<void> _lockTail = Future<void>.value();
  static int _tmpCounter = 0;

  static final Uint32List _crc32Table = _buildCrc32Table();

  static Uint32List _buildCrc32Table() {
    final table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int bit = 0; bit < 8; bit++) {
        c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
      }
      table[i] = c;
    }
    return table;
  }

  Future<T> _synchronized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _lockTail = _lockTail.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  Future<File> _manifestFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/library_manifest.json');
  }

  Future<void> _backupCorruptFile(File file) async {
    try {
      if (await file.exists()) {
        await file.copy('${file.path}.corrupt.bak');
      }
    } catch (e) {
      debugPrint(
        '[LibraryStorageService] Falha ao salvar backup de manifesto corrompido: $e',
      );
    }
  }

  /// Calcula o CRC32 IEEE 802.3 da ROM em isolate dedicado (streaming em blocos).
  static Future<String> computeFileCrc32Hex(
    String filePath, {
    int? maxBytes,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return '00000000';
    return _runComputeCrc32InIsolate(filePath, maxBytes);
  }

  static Future<String> _runComputeCrc32InIsolate(
    String filePath,
    int? maxBytes,
  ) {
    return Isolate.run(() => _computeCrc32Sync(filePath, maxBytes: maxBytes));
  }

  static String _computeCrc32Sync(String filePath, {int? maxBytes}) {
    final file = File(filePath);
    if (!file.existsSync()) return '00000000';

    final table = _crc32Table;
    final raf = file.openSync(mode: FileMode.read);
    try {
      final length = raf.lengthSync();
      final targetLen =
          maxBytes != null && maxBytes < length ? maxBytes : length;
      const int chunkSize = 512 * 1024;
      final buffer = Uint8List(chunkSize);
      int remaining = targetLen;
      int crc = 0xFFFFFFFF;

      while (remaining > 0) {
        final toRead = remaining > chunkSize ? chunkSize : remaining;
        final read = raf.readIntoSync(buffer, 0, toRead);
        if (read <= 0) break;
        for (int i = 0; i < read; i++) {
          crc = (crc >>> 8) ^ table[(crc ^ buffer[i]) & 0xFF];
        }
        remaining -= read;
      }

      final finalCrc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
      return finalCrc.toRadixString(16).toUpperCase().padLeft(8, '0');
    } finally {
      raf.closeSync();
    }
  }

  /// Calcula o CRC32 IEEE 802.3 da ROM (ou dos primeiros [maxBytes] bytes).
  Future<String> computeRomCrc32Hex(String filePath, {int? maxBytes}) =>
      computeFileCrc32Hex(filePath, maxBytes: maxBytes);

  static String _basename(String filePath) {
    final cleaned = filePath.replaceAll(RegExp(r'[/\\]+$'), '');
    if (cleaned.isEmpty) return filePath;
    final parts = cleaned.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? cleaned : parts.last;
  }

  static Directory? _findDedicatedGameFolder(File romFile) {
    var current = romFile.parent;
    for (int depth = 0; depth < 6; depth++) {
      final name = _basename(current.path);
      final parent = current.parent;
      if (parent.path == current.path) break;
      final parentName = _basename(parent.path).toLowerCase();
      if (parentName == 'roms' &&
          (name.startsWith('game_') || name.startsWith('arcade_'))) {
        return current;
      }
      current = parent;
    }
    return null;
  }

  static bool _isInsideGameOrArcadeFolder(String localPath) {
    if (_findDedicatedGameFolder(File(localPath)) != null) {
      return true;
    }
    final normalized = localPath.replaceAll('\\', '/').toLowerCase();
    return normalized.contains('/game_') || normalized.contains('/arcade_');
  }

  static Future<String> _uniqueFileKey(File file) async {
    try {
      return await file.resolveSymbolicLinks();
    } catch (_) {
      return file.absolute.path.replaceAll('\\', '/');
    }
  }

  static Future<List<String>> _extractDescriptorRefs(File descriptorFile) async {
    try {
      final bytes = await descriptorFile.readAsBytes();
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = text.split(RegExp(r'\r?\n'));
      final lower = descriptorFile.path.toLowerCase();
      final refs = <String>[];

      if (lower.endsWith('.cue')) {
        final quotedDouble =
            RegExp(r'^\s*FILE\s+"([^"]+)"', caseSensitive: false);
        final quotedSingle =
            RegExp(r"^\s*FILE\s+'([^']+)'", caseSensitive: false);
        final unquoted = RegExp(r'^\s*FILE\s+(\S+)', caseSensitive: false);
        for (final line in lines) {
          final match = quotedDouble.firstMatch(line) ??
              quotedSingle.firstMatch(line) ??
              unquoted.firstMatch(line);
          final ref = match?.group(1)?.trim();
          if (ref != null && ref.isNotEmpty) {
            refs.add(ref);
          }
        }
      } else if (lower.endsWith('.m3u')) {
        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          refs.add(line);
        }
      } else if (lower.endsWith('.gdi')) {
        final quoted = RegExp(r'"([^"]+)"');
        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (line.isEmpty || RegExp(r'^\d+$').hasMatch(line)) continue;
          final qMatch = quoted.firstMatch(line);
          if (qMatch != null) {
            final ref = qMatch.group(1)?.trim();
            if (ref != null && ref.isNotEmpty) refs.add(ref);
          } else {
            final parts = line.split(RegExp(r'\s+'));
            if (parts.length >= 5 && parts[4].isNotEmpty) {
              refs.add(parts[4]);
            }
          }
        }
      }
      return refs;
    } catch (e) {
      debugPrint(
        '[LibraryStorageService] Falha ao inspecionar descritor ${descriptorFile.path}: $e',
      );
      return const [];
    }
  }

  static Future<void> _collectDescriptorFilesRecursive(
    File descriptorFile,
    Set<String> seenKeys,
    List<File> collected,
  ) async {
    if (!await descriptorFile.exists()) return;
    final key = await _uniqueFileKey(descriptorFile);
    if (!seenKeys.add(key)) return;
    collected.add(descriptorFile);

    final refs = await _extractDescriptorRefs(descriptorFile);
    final parentDir = descriptorFile.parent;
    for (final rawRef in refs) {
      final normalizedRef = rawRef
          .replaceAll('"', '')
          .replaceAll("'", '')
          .replaceAll('\\', '/')
          .trim();
      if (normalizedRef.isEmpty) continue;

      final baseName = _basename(normalizedRef);
      File? companion;
      if (!normalizedRef.startsWith('/') &&
          !normalizedRef.contains('..') &&
          !RegExp(r'^[a-zA-Z]:').hasMatch(normalizedRef)) {
        final relCandidate = File('${parentDir.path}/$normalizedRef');
        if (await relCandidate.exists()) {
          companion = relCandidate;
        }
      }
      if (companion == null &&
          baseName.isNotEmpty &&
          baseName != '.' &&
          baseName != '..') {
        final baseCandidate = File('${parentDir.path}/$baseName');
        if (await baseCandidate.exists()) {
          companion = baseCandidate;
        }
      }
      if (companion == null) continue;

      final lowerComp = companion.path.toLowerCase();
      if (lowerComp.endsWith('.cue') ||
          lowerComp.endsWith('.m3u') ||
          lowerComp.endsWith('.gdi')) {
        await _collectDescriptorFilesRecursive(companion, seenKeys, collected);
      } else {
        final compKey = await _uniqueFileKey(companion);
        if (seenKeys.add(compKey)) {
          collected.add(companion);
        }
      }
    }
  }

  /// Resolve o tamanho real instalado em disco para uma ROM (incluindo pastas `game_<id>`/`arcade_<id>`
  /// e faixas companion de `.cue`/`.m3u`/`.gdi`), preservando [fallbackBytes] contra clobber de stubs.
  static Future<int> resolveInstalledRomSizeBytes(
    String localRomPath, {
    int fallbackBytes = 0,
  }) async {
    final safeFallback = fallbackBytes > 0 ? fallbackBytes : 0;
    final romFile = File(localRomPath);
    if (!await romFile.exists()) {
      return safeFallback;
    }

    int measuredBytes = 0;
    try {
      final dedicatedFolder = _findDedicatedGameFolder(romFile);
      if (dedicatedFolder != null && await dedicatedFolder.exists()) {
        final mainBase = _basename(localRomPath).toLowerCase();
        final entities = await dedicatedFolder
            .list(recursive: true, followLinks: false)
            .toList();
        final regularFiles = entities.whereType<File>().toList();
        final hasOtherFiles = regularFiles.any(
          (f) {
            final base = _basename(f.path).toLowerCase();
            return base != 'neogeo.zip' && !base.endsWith('.part');
          },
        );
        final seenKeys = <String>{};
        for (final f in regularFiles) {
          final base = _basename(f.path).toLowerCase();
          if (base.endsWith('.part') && !mainBase.endsWith('.part')) {
            continue;
          }
          if (base == 'neogeo.zip' &&
              mainBase != 'neogeo.zip' &&
              hasOtherFiles) {
            continue;
          }
          final key = await _uniqueFileKey(f);
          if (!seenKeys.add(key)) continue;
          measuredBytes += await f.length();
        }
      } else {
        final lower = localRomPath.toLowerCase();
        if (lower.endsWith('.cue') ||
            lower.endsWith('.m3u') ||
            lower.endsWith('.gdi')) {
          final collected = <File>[];
          await _collectDescriptorFilesRecursive(
            romFile,
            <String>{},
            collected,
          );
          for (final f in collected) {
            measuredBytes += await f.length();
          }
        } else {
          measuredBytes = await romFile.length();
        }
      }
    } catch (e) {
      debugPrint(
        '[LibraryStorageService] Falha ao medir tamanho de $localRomPath: $e',
      );
      try {
        measuredBytes = await romFile.length();
      } catch (_) {
        measuredBytes = 0;
      }
    }

    if (measuredBytes < 1024 && safeFallback >= 1024) {
      return safeFallback;
    }
    return measuredBytes > 0 ? measuredBytes : safeFallback;
  }

  Future<List<EmulationGame>> loadPersistedLibrary() =>
      _synchronized(() => _loadPersistedLibraryUnlocked(persistRepairs: true));

  Future<List<EmulationGame>> _loadPersistedLibraryUnlocked({
    bool persistRepairs = true,
  }) async {
    final file = await _manifestFile();
    if (!await file.exists()) return const [];

    final List<dynamic> rawList;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        await _backupCorruptFile(file);
        debugPrint(
          '[LibraryStorageService] Manifesto vazio em ${file.path}; backup preservado.',
        );
        return const [];
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final games = decoded['games'];
        if (games is! List<dynamic>) {
          await _backupCorruptFile(file);
          debugPrint(
            '[LibraryStorageService] Campo "games" inválido no manifesto; backup preservado.',
          );
          return const [];
        }
        rawList = games;
      } else if (decoded is List<dynamic>) {
        rawList = decoded;
      } else {
        await _backupCorruptFile(file);
        debugPrint(
          '[LibraryStorageService] Formato raiz inválido no manifesto; backup preservado.',
        );
        return const [];
      }
    } catch (e) {
      await _backupCorruptFile(file);
      debugPrint(
        '[LibraryStorageService] Manifesto JSON corrompido (${file.path}): $e',
      );
      return const [];
    }

    final List<EmulationGame> validGames = [];
    bool repairedAnySize = false;
    for (int i = 0; i < rawList.length; i++) {
      final rawItem = rawList[i];
      if (rawItem is! Map) {
        debugPrint(
          '[LibraryStorageService] Ignorando entrada #$i inválida (não é objeto JSON).',
        );
        continue;
      }
      try {
        final item = Map<String, dynamic>.from(rawItem);
        final igdbId = (item['igdbId'] as num?)?.toInt();
        final name = item['name'];
        final platformName = item['platformName'];
        final platformSlug = item['platformSlug'];
        final localPath = item['localRomPath'];

        if (igdbId == null ||
            name is! String ||
            name.isEmpty ||
            platformName is! String ||
            platformName.isEmpty ||
            platformSlug is! String ||
            platformSlug.isEmpty ||
            localPath is! String ||
            localPath.isEmpty) {
          debugPrint(
            '[LibraryStorageService] Ignorando entrada #$i com campos obrigatórios inválidos.',
          );
          continue;
        }

        final rawGenres = item['genres'];
        if (rawGenres != null && rawGenres is! List) {
          throw const FormatException('Campo "genres" inválido');
        }
        final genres = rawGenres is List
            ? rawGenres.map((e) => e.toString()).toList()
            : const <String>[];

        if (!await File(localPath).exists()) {
          continue;
        }

        final canonical = item['canonicalNoIntroName'];
        final regionRaw = item['region'];
        final savedSize = (item['estimatedSizeBytes'] as num?)?.toInt() ?? 0;
        final lowerPath = localPath.toLowerCase();
        final shouldRecomputeSize = savedSize < 1024 ||
            lowerPath.endsWith('.cue') ||
            lowerPath.endsWith('.m3u') ||
            lowerPath.endsWith('.gdi') ||
            _isInsideGameOrArcadeFolder(localPath);
        final resolvedSize = shouldRecomputeSize
            ? await resolveInstalledRomSizeBytes(
                localPath,
                fallbackBytes: savedSize,
              )
            : savedSize;
        if (resolvedSize != savedSize) {
          repairedAnySize = true;
        }

        validGames.add(
          EmulationGame(
            igdbId: igdbId,
            name: name,
            canonicalNoIntroName:
                (canonical is String && canonical.isNotEmpty) ? canonical : name,
            summary: item['summary'] is String ? item['summary'] as String : '',
            genres: genres,
            developer:
                item['developer'] is String ? item['developer'] as String : '',
            releaseYear: (item['releaseYear'] as num?)?.toInt(),
            rating: (item['rating'] as num?)?.toDouble(),
            platformName: platformName,
            platformSlug: platformSlug,
            directRomUrl: item['directRomUrl'] is String
                ? item['directRomUrl'] as String
                : '',
            region: (regionRaw is String && regionRaw.isNotEmpty)
                ? regionRaw
                : 'USA',
            gridCoverUrl: item['gridCoverUrl'] is String
                ? item['gridCoverUrl'] as String
                : null,
            heroBannerUrl: item['heroBannerUrl'] is String
                ? item['heroBannerUrl'] as String
                : null,
            logoUrl:
                item['logoUrl'] is String ? item['logoUrl'] as String : null,
            crc32:
                item['crc32'] is String ? item['crc32'] as String : '00000000',
            estimatedSizeBytes: resolvedSize,
            localRomPath: localPath,
          ),
        );
      } catch (e) {
        debugPrint(
          '[LibraryStorageService] Ignorando entrada #$i corrompida no manifesto: $e',
        );
      }
    }
    if (repairedAnySize && persistRepairs) {
      try {
        await _writeManifestUnlocked(validGames);
      } catch (e) {
        debugPrint(
          '[LibraryStorageService] Falha ao persistir reparo de tamanhos no manifesto: $e',
        );
      }
    }
    return validGames;
  }

  Future<void> saveGameToLibrary(EmulationGame game, String localRomPath) {
    return _synchronized(() async {
      final existing = await _loadPersistedLibraryUnlocked(persistRepairs: false);
      final fileSize = await resolveInstalledRomSizeBytes(
        localRomPath,
        fallbackBytes: game.estimatedSizeBytes,
      );

      final updated = [
        for (final g in existing)
          if (g.igdbId != game.igdbId) g,
        EmulationGame(
          igdbId: game.igdbId,
          name: game.name,
          canonicalNoIntroName: game.canonicalNoIntroName,
          summary: game.summary,
          genres: game.genres,
          developer: game.developer,
          releaseYear: game.releaseYear,
          rating: game.rating,
          platformName: game.platformName,
          platformSlug: game.platformSlug,
          directRomUrl: game.directRomUrl,
          region: game.region,
          gridCoverUrl: game.gridCoverUrl,
          heroBannerUrl: game.heroBannerUrl,
          logoUrl: game.logoUrl,
          crc32: game.crc32,
          estimatedSizeBytes: fileSize,
          localRomPath: localRomPath,
        ),
      ];

      await _writeManifestUnlocked(updated);
    });
  }

  Future<void> removeGameFromLibrary(int igdbId) {
    return _synchronized(() async {
      final existing =
          await _loadPersistedLibraryUnlocked(persistRepairs: false);
      final updated = existing.where((g) => g.igdbId != igdbId).toList();
      await _writeManifestUnlocked(updated);
    });
  }

  Future<void> _writeManifestUnlocked(List<EmulationGame> games) async {
    final serialized = games
        .map(
          (g) => {
            'igdbId': g.igdbId,
            'name': g.name,
            'canonicalNoIntroName': g.canonicalNoIntroName,
            'summary': g.summary,
            'genres': g.genres,
            'developer': g.developer,
            'releaseYear': g.releaseYear,
            'rating': g.rating,
            'platformName': g.platformName,
            'platformSlug': g.platformSlug,
            'directRomUrl': g.directRomUrl,
            'region': g.region,
            'gridCoverUrl': g.gridCoverUrl,
            'heroBannerUrl': g.heroBannerUrl,
            'logoUrl': g.logoUrl,
            'crc32': g.crc32,
            'estimatedSizeBytes': g.estimatedSizeBytes,
            'localRomPath': g.localRomPath,
          },
        )
        .toList();

    final payload = <String, dynamic>{
      'version': currentManifestVersion,
      'games': serialized,
    };

    final file = await _manifestFile();
    await _atomicWriteString(file, jsonEncode(payload));
  }

  Future<void> _atomicWriteString(File target, String content) async {
    if (!await target.parent.exists()) {
      await target.parent.create(recursive: true);
    }
    final seq = ++_tmpCounter;
    final tmp = File(
      '${target.path}.tmp_${DateTime.now().microsecondsSinceEpoch}_$seq',
    );
    try {
      await tmp.writeAsString(content, flush: true);
      await tmp.rename(target.path);
    } catch (e) {
      try {
        if (await tmp.exists()) {
          await tmp.delete();
        }
      } catch (cleanupErr) {
        debugPrint('[LibraryStorageService] Falha ao remover tmp: $cleanupErr');
      }
      rethrow;
    }
  }
}
