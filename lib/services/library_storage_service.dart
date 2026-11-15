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

  Future<List<EmulationGame>> loadPersistedLibrary() =>
      _synchronized(_loadPersistedLibraryUnlocked);

  Future<List<EmulationGame>> _loadPersistedLibraryUnlocked() async {
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
            estimatedSizeBytes:
                (item['estimatedSizeBytes'] as num?)?.toInt() ?? 0,
            localRomPath: localPath,
          ),
        );
      } catch (e) {
        debugPrint(
          '[LibraryStorageService] Ignorando entrada #$i corrompida no manifesto: $e',
        );
      }
    }
    return validGames;
  }

  Future<void> saveGameToLibrary(EmulationGame game, String localRomPath) {
    return _synchronized(() async {
      final existing = await _loadPersistedLibraryUnlocked();
      final romFile = File(localRomPath);
      final fileSize = await romFile.exists()
          ? await romFile.length()
          : game.estimatedSizeBytes;

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
      final existing = await _loadPersistedLibraryUnlocked();
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
