import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/emulation_game.dart';

class LibraryStorageService {
  Future<File> _manifestFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/library_manifest.json');
  }

  /// Calcula o CRC32 IEEE 802.3 dos primeiros 4 MB da ROM.
  Future<String> computeRomCrc32Hex(String filePath) async {
    final file = File(filePath);
    if (!await file.exists()) return '00000000';

    final raf = await file.open();
    try {
      final length = await raf.length();
      final readLen = length > 4 * 1024 * 1024 ? 4 * 1024 * 1024 : length;
      final bytes = await raf.read(readLen);

      int crc = 0xFFFFFFFF;
      for (final b in bytes) {
        crc ^= b;
        for (int bit = 0; bit < 8; bit++) {
          if ((crc & 1) != 0) {
            crc = (crc >>> 1) ^ 0xEDB88320;
          } else {
            crc = crc >>> 1;
          }
        }
      }
      final finalCrc = (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
      return finalCrc.toRadixString(16).toUpperCase().padLeft(8, '0');
    } finally {
      await raf.close();
    }
  }

  Future<List<EmulationGame>> loadPersistedLibrary() async {
    final file = await _manifestFile();
    if (!await file.exists()) return const [];

    try {
      final raw = await file.readAsString();
      final list = jsonDecode(raw) as List<dynamic>;
      final List<EmulationGame> validGames = [];

      for (final item in list.cast<Map<String, dynamic>>()) {
        final localPath = item['localRomPath'] as String?;
        if (localPath != null && await File(localPath).exists()) {
          validGames.add(
            EmulationGame(
              igdbId: item['igdbId'] as int,
              name: item['name'] as String,
              canonicalNoIntroName:
                  (item['canonicalNoIntroName'] as String?) ??
                      (item['name'] as String),
              summary: item['summary'] as String,
              genres: (item['genres'] as List<dynamic>).cast<String>(),
              developer: item['developer'] as String,
              releaseYear: item['releaseYear'] as int?,
              rating: (item['rating'] as num?)?.toDouble(),
              platformName: item['platformName'] as String,
              platformSlug: item['platformSlug'] as String,
              directRomUrl: (item['directRomUrl'] as String?) ?? '',
              gridCoverUrl: item['gridCoverUrl'] as String?,
              heroBannerUrl: item['heroBannerUrl'] as String?,
              logoUrl: item['logoUrl'] as String?,
              crc32: (item['crc32'] as String?) ?? '00000000',
              estimatedSizeBytes:
                  (item['estimatedSizeBytes'] as num?)?.toInt() ?? 0,
              localRomPath: localPath,
            ),
          );
        }
      }
      return validGames;
    } catch (_) {
      return const [];
    }
  }

  Future<void> saveGameToLibrary(EmulationGame game, String localRomPath) async {
    final existing = await loadPersistedLibrary();
    final fileSize = await File(localRomPath).length();

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
        gridCoverUrl: game.gridCoverUrl,
        heroBannerUrl: game.heroBannerUrl,
        logoUrl: game.logoUrl,
        crc32: game.crc32,
        estimatedSizeBytes: fileSize,
        localRomPath: localRomPath,
      ),
    ];

    await _writeManifest(updated);
  }

  Future<void> removeGameFromLibrary(int igdbId) async {
    final existing = await loadPersistedLibrary();
    final updated = existing.where((g) => g.igdbId != igdbId).toList();
    await _writeManifest(updated);
  }

  Future<void> _writeManifest(List<EmulationGame> games) async {
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
            'gridCoverUrl': g.gridCoverUrl,
            'heroBannerUrl': g.heroBannerUrl,
            'logoUrl': g.logoUrl,
            'crc32': g.crc32,
            'estimatedSizeBytes': g.estimatedSizeBytes,
            'localRomPath': g.localRomPath,
          },
        )
        .toList();

    final file = await _manifestFile();
    await file.writeAsString(jsonEncode(serialized), flush: true);
  }
}
