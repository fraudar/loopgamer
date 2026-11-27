import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/services/library_storage_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'test_temp_utils.dart';

/// path_provider falso apontando para um diretório temporário do teste.
class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;
}

EmulationGame _game(int id, String name) => EmulationGame(
      igdbId: id,
      name: name,
      canonicalNoIntroName: name,
      summary: '',
      genres: const [],
      developer: '',
      releaseYear: 2004,
      rating: null,
      platformName: 'Nintendo Game Boy Advance',
      platformSlug: 'gba',
      directRomUrl: '',
      region: 'USA',
      crc32: '00000000',
      estimatedSizeBytes: 0,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('entrada com ROM ausente é preservada e marcada como missingRomPath',
      () async {
    final tempDir = Directory.systemTemp.createTempSync('loopgamer_missing_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    addTearDown(() => deleteTempDirQuietly(tempDir));

    final storage = LibraryStorageService();
    final romFile = File('${tempDir.path}/roms/game.gba');
    await romFile.parent.create(recursive: true);
    await romFile.writeAsBytes(List<int>.filled(4096, 0x42), flush: true);

    await storage.saveGameToLibrary(_game(9001, 'Presente'), romFile.path);

    // Simula SD removido / arquivo apagado.
    await romFile.delete();

    final loaded = await storage.loadPersistedLibrary();
    final entry = loaded.firstWhere(
      (g) => g.igdbId == 9001,
      orElse: () => throw StateError('entrada removida do manifesto'),
    );
    expect(entry.missingRomPath, isTrue);
    expect(entry.localRomPath, romFile.path);
  });

  test('ao voltar o arquivo, a entrada é reconciliada para presente', () async {
    final tempDir = Directory.systemTemp.createTempSync('loopgamer_missing2_');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    addTearDown(() => deleteTempDirQuietly(tempDir));

    final storage = LibraryStorageService();
    final romFile = File('${tempDir.path}/roms/game2.gba');
    await romFile.parent.create(recursive: true);
    await romFile.writeAsBytes(List<int>.filled(4096, 0x24), flush: true);
    await storage.saveGameToLibrary(_game(9002, 'Volta'), romFile.path);

    await romFile.delete();
    await storage.loadPersistedLibrary();

    await romFile.writeAsBytes(List<int>.filled(4096, 0x24), flush: true);
    final reloaded = await storage.loadPersistedLibrary();
    final entry = reloaded.firstWhere((g) => g.igdbId == 9002);
    expect(entry.missingRomPath, isFalse);
  });
}
