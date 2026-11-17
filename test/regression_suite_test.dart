import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/main.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/models/user_library_meta.dart';
import 'package:loopgamer/screens/home_screen.dart';
import 'package:loopgamer/screens/library_screen.dart';
import 'package:loopgamer/screens/libretro_player_screen.dart';
import 'package:loopgamer/services/emulator_service.dart';
import 'package:loopgamer/services/gpu_driver_service.dart';
import 'package:loopgamer/services/library_storage_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/services/settings_storage_service.dart';
import 'package:loopgamer/theme/hydra_tokens.dart';
import 'package:loopgamer/widgets/animated_game_logo.dart';
import 'package:loopgamer/widgets/procedural_cover.dart';

typedef _AdapterHandler = Future<ResponseBody> Function(
  RequestOptions options,
  Future<void>? cancelFuture,
);

class _AsyncFakeHttpAdapter implements HttpClientAdapter {
  _AsyncFakeHttpAdapter(this._handler);

  final _AdapterHandler _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    return _handler(options, cancelFuture);
  }

  @override
  void close({bool force = false}) {}
}

EmulationGame _makeTestGame({
  required int id,
  String name = 'Test Game',
  String platformName = 'Game Boy Advance',
  String platformSlug = 'gba',
  String directRomUrl = 'https://example.com/game.gba',
  String region = 'USA',
  int estimatedSizeBytes = 256 * 1024,
  String? localRomPath,
}) {
  return EmulationGame(
    igdbId: id,
    name: name,
    canonicalNoIntroName: '$name ($region)',
    summary: 'Test summary',
    genres: const <String>['Action'],
    developer: 'LoopDev',
    releaseYear: 2003,
    rating: 90.0,
    platformName: platformName,
    platformSlug: platformSlug,
    directRomUrl: directRomUrl,
    region: region,
    estimatedSizeBytes: estimatedSizeBytes,
    localRomPath: localRomPath,
  );
}

Directory _setupTempSupportDir() {
  final tempDir = Directory.systemTemp.createTempSync('loopgamer_reg_test_');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    pathProviderChannel,
    (call) async => tempDir.path,
  );
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });
  return tempDir;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LibraryStorageService regressions', () {
    test('atomic write persists versioned JSON without leaving .tmp files', () async {
      final tempDir = _setupTempSupportDir();
      final storage = LibraryStorageService();

      final romFile = File('${tempDir.path}/game1.gba');
      await romFile.writeAsBytes(Uint8List(2048), flush: true);

      final game = _makeTestGame(id: 5001, name: 'Atomic Quest', region: 'USA');
      await storage.saveGameToLibrary(game, romFile.path);

      final manifestFile = File('${tempDir.path}/library_manifest.json');
      expect(await manifestFile.exists(), isTrue);

      final decoded =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      expect(decoded['version'], LibraryStorageService.currentManifestVersion);
      expect(decoded['games'], isA<List<dynamic>>());
      expect((decoded['games'] as List<dynamic>).length, 1);

      final leftoverTmps = tempDir
          .listSync()
          .where((e) => e.path.contains('.tmp_'))
          .toList();
      expect(leftoverTmps, isEmpty);
    });

    test('preserves valid items when manifest has corrupt entry and backs up corrupt root', () async {
      final tempDir = _setupTempSupportDir();
      final storage = LibraryStorageService();

      final rom1 = File('${tempDir.path}/valid1.gba');
      await rom1.writeAsBytes(Uint8List(4096), flush: true);
      final rom2 = File('${tempDir.path}/valid2.gba');
      await rom2.writeAsBytes(Uint8List(4096), flush: true);

      final manifestFile = File('${tempDir.path}/library_manifest.json');
      await manifestFile.writeAsString(
        jsonEncode({
          'version': 1,
          'games': [
            {
              'igdbId': 101,
              'name': 'Valid Game 1',
              'canonicalNoIntroName': 'Valid Game 1 (EUR)',
              'summary': 'Ok',
              'genres': ['RPG'],
              'developer': 'Dev',
              'platformName': 'GBA',
              'platformSlug': 'gba',
              'region': 'EUR',
              'localRomPath': rom1.path,
            },
            'not-a-map-corrupt-item',
            {
              'igdbId': 102,
              'name': 'Missing Path Item',
              'platformName': 'GBA',
              'platformSlug': 'gba',
            },
            {
              'igdbId': 103,
              'name': 'Bad Genres Type',
              'platformName': 'GBA',
              'platformSlug': 'gba',
              'genres': 'invalid_genres_string',
              'localRomPath': rom1.path,
            },
          ],
        }),
        flush: true,
      );

      final loaded = await storage.loadPersistedLibrary();
      expect(loaded.length, 1);
      expect(loaded.single.igdbId, 101);
      expect(loaded.single.region, 'EUR');

      // Saving a second game must NOT erase the first valid game
      await storage.saveGameToLibrary(
        _makeTestGame(id: 202, name: 'Valid Game 2', region: 'JPN'),
        rom2.path,
      );
      final afterSecondSave = await storage.loadPersistedLibrary();
      expect(afterSecondSave.map((g) => g.igdbId), containsAll(<int>[101, 202]));

      // Corrupt root JSON produces empty list AND creates .corrupt.bak
      await manifestFile.writeAsString('{broken_json', flush: true);
      final afterCorruptRoot = await storage.loadPersistedLibrary();
      expect(afterCorruptRoot, isEmpty);
      final backupFile = File('${manifestFile.path}.corrupt.bak');
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.readAsString(), '{broken_json');
    });

    test('serializes and deserializes region faithfully', () async {
      final tempDir = _setupTempSupportDir();
      final storage = LibraryStorageService();

      final romEur = File('${tempDir.path}/eur.gba');
      final romJpn = File('${tempDir.path}/jpn.gba');
      await romEur.writeAsBytes(Uint8List(2048), flush: true);
      await romJpn.writeAsBytes(Uint8List(2048), flush: true);

      await storage.saveGameToLibrary(
        _makeTestGame(id: 301, name: 'Euro Title', region: 'EUR'),
        romEur.path,
      );
      await storage.saveGameToLibrary(
        _makeTestGame(id: 302, name: 'Japan Title', region: 'JPN'),
        romJpn.path,
      );

      final loaded = await storage.loadPersistedLibrary();
      final byId = {for (final g in loaded) g.igdbId: g};
      expect(byId[301]?.region, 'EUR');
      expect(byId[302]?.region, 'JPN');
    });

    test('concurrent saveGameToLibrary calls do not lose entries', () async {
      final tempDir = _setupTempSupportDir();
      final storage = LibraryStorageService();

      final romPaths = <int, String>{};
      for (int i = 1; i <= 8; i++) {
        final f = File('${tempDir.path}/concurrent_$i.gba');
        await f.writeAsBytes(Uint8List(2048), flush: true);
        romPaths[i] = f.path;
      }

      await Future.wait([
        for (int i = 1; i <= 8; i++)
          storage.saveGameToLibrary(
            _makeTestGame(id: 700 + i, name: 'Game $i', region: 'EUR'),
            romPaths[i]!,
          ),
      ]);

      final loaded = await storage.loadPersistedLibrary();
      expect(loaded.length, 8);
      expect(
        loaded.map((g) => g.igdbId),
        containsAll(<int>[701, 702, 703, 704, 705, 706, 707, 708]),
      );

      final leftoverTmps = tempDir
          .listSync()
          .where((e) => e.path.contains('.tmp_'))
          .toList();
      expect(leftoverTmps, isEmpty);
    });
  });

  group('SettingsStorageService regressions', () {
    test('concurrent saveSettings writes do not corrupt file or leave .tmp files', () async {
      final tempDir = _setupTempSupportDir();
      final storage = SettingsStorageService();

      await Future.wait([
        for (int i = 0; i < 10; i++)
          storage.saveSettings(
            AppSettings(
              frameSkip: i % 3,
              masterVolume: 0.1 + (i * 0.05),
              rommServerUrl: 'https://romm$i.example.com',
            ),
          ),
      ]);

      final loaded = await storage.loadSettings();
      expect(loaded.rommServerUrl, 'https://romm9.example.com');
      expect(loaded.frameSkip, 9 % 3);

      final leftoverTmps = tempDir
          .listSync()
          .where((e) => e.path.contains('.tmp_'))
          .toList();
      expect(leftoverTmps, isEmpty);
    });

    test('corrupt settings JSON falls back safely and creates .corrupt.bak', () async {
      final tempDir = _setupTempSupportDir();
      final storage = SettingsStorageService();

      final settingsFile = File('${tempDir.path}/app_settings.json');
      await settingsFile.writeAsString('{invalid: json!!', flush: true);

      final loaded = await storage.loadSettings();
      expect(loaded.gpuBackend, const AppSettings().gpuBackend);
      expect(loaded.rommServerUrl, '');

      final backupFile = File('${settingsFile.path}.corrupt.bak');
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.readAsString(), '{invalid: json!!');

      // Non-Map root JSON also backs up and falls back
      await backupFile.delete();
      await settingsFile.writeAsString('[1, 2, 3]', flush: true);
      final loadedList = await storage.loadSettings();
      expect(loadedList.showFpsTelemetry, isTrue);
      expect(await backupFile.exists(), isTrue);
      expect(await backupFile.readAsString(), '[1, 2, 3]');
    });
  });

  group('EmulationGame & AppSettings schema regressions', () {
    test('EmulationGame.stableIdFromKey is deterministic and > 100000', () {
      final id1 = EmulationGame.stableIdFromKey('psp|god of war: ghost of sparta');
      final id2 = EmulationGame.stableIdFromKey('psp|god of war: ghost of sparta');
      final idOther = EmulationGame.stableIdFromKey('ps1|castlevania');
      final idUnicode = EmulationGame.stableIdFromKey('snes|ação e aventura é');

      expect(id1, equals(id2));
      expect(id1, greaterThan(100000));
      expect(idOther, greaterThan(100000));
      expect(idUnicode, greaterThan(100000));
      expect(id1, isNot(equals(idOther)));
      expect(
        EmulationGame.stableIdFromKey(''),
        equals(EmulationGame.stableIdFromKey('')),
      );
      expect(EmulationGame.stableIdFromKey(''), greaterThan(100000));
    });

    test('AppSettings serializes schema version and validates RomM server URLs', () {
      final json = const AppSettings().toJson();
      expect(json['version'], AppSettings.currentSchemaVersion);
      expect(AppSettings.currentSchemaVersion, 2);

      // Legacy config without 'version' migrates cleanly
      final migrated = AppSettings.fromJson({
        'gpuRenderer': false,
        'internalResolutionScale': 3,
      });
      expect(migrated.gpuBackend, GpuBackend.software);
      expect(migrated.renderResolution, RenderResolutionPreset.x3);

      expect(
        const UserLibraryMeta().toJson()['version'],
        UserLibraryMeta.currentSchemaVersion,
      );

      // URL validation
      expect(AppSettings.isValidRommServerUrl('http://192.168.1.50:8080'), isTrue);
      expect(AppSettings.isValidRommServerUrl('https://romm.local/api'), isTrue);
      expect(AppSettings.isValidRommServerUrl(''), isFalse);
      expect(AppSettings.isValidRommServerUrl('   '), isFalse);
      expect(AppSettings.isValidRommServerUrl('192.168.1.50:8080'), isFalse);
      expect(AppSettings.isValidRommServerUrl('ftp://romm.local'), isFalse);
      expect(AppSettings.isValidRommServerUrl('http://'), isFalse);
      expect(AppSettings.isValidRommServerUrl('javascript:alert(1)'), isFalse);
      expect(AppSettings.isValidRommServerUrl('https://bad host.local'), isFalse);
    });
  });

  group('EmulatorService regressions', () {
    const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');

    test('saveState & loadState return false honestly on native failure with zero fake files', () async {
      final tempDir = _setupTempSupportDir();
      bool nativeSaveResult = false;
      bool nativeLoadResult = false;
      bool throwOnSave = false;
      bool throwOnLoad = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodsChannel, (call) async {
        if (call.method == 'saveState') {
          if (throwOnSave) {
            throw PlatformException(code: 'SAVE_ERR', message: 'Native save failed');
          }
          return nativeSaveResult;
        }
        if (call.method == 'loadState') {
          if (throwOnLoad) {
            throw PlatformException(code: 'LOAD_ERR', message: 'Native load failed');
          }
          return nativeLoadResult;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, null);
      });

      final service = EmulatorService();
      addTearDown(service.dispose);
      final romPath = '${tempDir.path}/roms/chrono.sfc';

      // 1. Native save returns false -> returns false, sets lastError, writes ZERO files
      final failedSave = await service.saveState(
        1,
        romPath: romPath,
        gameTitle: 'Chrono Trigger',
        previewPngBytes: Uint8List.fromList([1, 2, 3, 4]),
      );
      expect(failedSave, isFalse);
      expect(service.lastError, isNotNull);

      final savesDir = Directory('${tempDir.path}/saves');
      if (await savesDir.exists()) {
        expect(await savesDir.list().toList(), isEmpty);
      }

      // 2. Native save throws PlatformException -> returns false, zero fake files
      throwOnSave = true;
      final thrownSave = await service.saveState(
        1,
        romPath: romPath,
        gameTitle: 'Chrono Trigger',
      );
      expect(thrownSave, isFalse);
      expect(service.lastError, 'Native save failed');
      if (await savesDir.exists()) {
        expect(await savesDir.list().toList(), isEmpty);
      }
      throwOnSave = false;

      // 3. loadState on missing .state file returns false immediately
      nativeLoadResult = true;
      final missingLoad = await service.loadState(1, romPath: romPath);
      expect(missingLoad, isFalse);
      expect(service.lastError, isNotNull);

      // 4. Create real non-empty .state file, but native load returns false -> returns false
      await savesDir.create(recursive: true);
      final stateFile = File('${savesDir.path}/chrono_slot1.state');
      await stateFile.writeAsBytes(Uint8List.fromList([10, 20, 30]), flush: true);

      nativeLoadResult = false;
      expect(await service.loadState(1, romPath: romPath), isFalse);
      expect(service.lastError, isNotNull);

      // 5. Native load throws -> returns false
      throwOnLoad = true;
      expect(await service.loadState(1, romPath: romPath), isFalse);
      expect(service.lastError, 'Native load failed');
      throwOnLoad = false;

      // 6. Native save & load return true -> returns true
      nativeSaveResult = true;
      nativeLoadResult = true;
      expect(
        await service.saveState(1, romPath: romPath, gameTitle: 'Chrono Trigger'),
        isTrue,
      );
      expect(service.lastError, isNull);
      expect(await service.loadState(1, romPath: romPath), isTrue);
      expect(service.lastError, isNull);
    });

    test('rejects invalid coreOptions containing "=", ";" or newlines', () async {
      _setupTempSupportDir();
      final service = EmulatorService();
      addTearDown(service.dispose);

      expect(EmulatorService.serializeCoreOptions(null), '');
      expect(EmulatorService.serializeCoreOptions(const {}), '');
      expect(
        EmulatorService.serializeCoreOptions(const {
          'ppsspp_backend': 'vulkan',
          'ppsspp_frameskip': '0',
        }),
        'ppsspp_backend=vulkan;ppsspp_frameskip=0',
      );

      expect(
        () => EmulatorService.serializeCoreOptions({'': 'val'}),
        throwsArgumentError,
      );
      expect(
        () => EmulatorService.serializeCoreOptions({'bad=key': 'val'}),
        throwsArgumentError,
      );
      expect(
        () => EmulatorService.serializeCoreOptions({'bad;key': 'val'}),
        throwsArgumentError,
      );
      expect(
        () => EmulatorService.serializeCoreOptions({'key': 'bad=val'}),
        throwsArgumentError,
      );
      expect(
        () => EmulatorService.serializeCoreOptions({'key': 'bad;val'}),
        throwsArgumentError,
      );
      expect(
        () => EmulatorService.serializeCoreOptions({'key': 'bad\nval'}),
        throwsArgumentError,
      );

      await expectLater(
        () => service.startSession(
          platformSlug: 'psp',
          coreSoName: 'ppsspp_libretro_android.so',
          romPath: '/tmp/test.iso',
          coreOptions: const {'ppsspp_backend': 'vulkan;evil=1'},
        ),
        throwsArgumentError,
      );
    });

    test('isValidElfSharedLibrary rejects truncated/non-ELF and accepts valid ELF', () async {
      final tempDir = _setupTempSupportDir();

      final tinyFile = File('${tempDir.path}/tiny.so');
      await tinyFile.writeAsBytes([0x7F, 0x45, 0x4C, 0x46], flush: true);
      expect(await EmulatorService.isValidElfSharedLibrary(tinyFile), isFalse);

      final nonElf = File('${tempDir.path}/html.so');
      await nonElf.writeAsBytes(Uint8List(32 * 1024), flush: true);
      expect(await EmulatorService.isValidElfSharedLibrary(nonElf), isFalse);

      final validElf = File('${tempDir.path}/valid.so');
      final bytes = Uint8List(32 * 1024);
      bytes[0] = 0x7F;
      bytes[1] = 0x45;
      bytes[2] = 0x4C;
      bytes[3] = 0x46;
      await validElf.writeAsBytes(bytes, flush: true);
      expect(await EmulatorService.isValidElfSharedLibrary(validElf), isTrue);
    });
  });

  group('RomDownloadService regressions', () {
    test('resolveExistingRomPath preserves valid imported .zip and cleans tiny stubs', () async {
      final tempDir = _setupTempSupportDir();
      final service = RomDownloadService();
      addTearDown(service.dispose);

      final romsDir = Directory('${tempDir.path}/roms');
      await romsDir.create(recursive: true);

      final importedZip = File('${romsDir.path}/rom_77001_Imported_Game.zip');
      await importedZip.writeAsBytes(Uint8List(4096), flush: true);

      final resolved = await service.resolveExistingRomPath(77001);
      expect(resolved, importedZip.path);
      expect(await importedZip.exists(), isTrue);

      final tinyStub = File('${romsDir.path}/rom_77002_Stub.zip');
      await tinyStub.writeAsBytes(Uint8List(128), flush: true);
      final resolvedStub = await service.resolveExistingRomPath(77002);
      expect(resolvedStub, isNull);
      expect(await tinyStub.exists(), isFalse);
    });

    test('pause -> resume race does not clobber active resume token or status', () async {
      _setupTempSupportDir();

      int requestCount = 0;
      final firstRequestStarted = Completer<void>();
      final firstRequestPaused = Completer<void>();
      final allowSecondFinish = Completer<void>();
      final firstStreamController = StreamController<Uint8List>();

      final dio = Dio();
      dio.httpClientAdapter = _AsyncFakeHttpAdapter((options, cancelFuture) async {
        requestCount++;
        if (requestCount == 1) {
          if (!firstRequestStarted.isCompleted) {
            firstRequestStarted.complete();
          }
          unawaited(
            cancelFuture?.then((_) {
              if (!firstRequestPaused.isCompleted) {
                firstRequestPaused.complete();
              }
              if (!firstStreamController.isClosed) {
                firstStreamController.addError(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'PAUSED_BY_USER',
                  ),
                );
                unawaited(firstStreamController.close());
              }
            }),
          );
          firstStreamController.add(Uint8List(4096));
          return ResponseBody(
            firstStreamController.stream,
            200,
            headers: {
              Headers.contentTypeHeader: ['application/octet-stream'],
              Headers.contentLengthHeader: ['262144'],
            },
          );
        }

        // Second request (resume): wait until we've verified op1 cleanup didn't corrupt op2
        await allowSecondFinish.future;
        final payload = Uint8List(262144);
        return ResponseBody.fromBytes(
          payload,
          200,
          headers: {
            Headers.contentTypeHeader: ['application/octet-stream'],
            Headers.contentLengthHeader: ['${payload.length}'],
          },
        );
      });

      final service = RomDownloadService(dio: dio);
      addTearDown(service.dispose);

      final game = _makeTestGame(
        id: 88001,
        name: 'Race Runner',
        platformSlug: 'gba',
        directRomUrl: 'https://example.com/race_runner.gba',
        estimatedSizeBytes: 262144,
      );

      final firstFuture = service.startBackgroundDownload(game: game);

      // Espera a primeira requisição HTTP realmente iniciar antes de pausar —
      // sem isso a pausa pode cair na janela de startup e o teste fica
      // dependente de timing.
      await firstRequestStarted.future;

      // Pause and IMMEDIATELY resume before op1 finishes unwinding
      service.pauseDownload(game.igdbId);
      final secondFuture = service.startBackgroundDownload(game: game);

      await firstRequestPaused.future;
      await firstFuture;

      // Status must remain downloading (NOT overwritten with paused by op1!)
      expect(
        service.activeStatuses[game.igdbId]?.state,
        RomActionState.downloading,
      );

      // Pause again AFTER op1 finished its finally block -> must still cancel op2!
      // First verify op2 completes cleanly when unblocked:
      allowSecondFinish.complete();
      final resultPath = await secondFuture;
      expect(resultPath, isNotNull);
      expect(await File(resultPath!).exists(), isTrue);
      expect(
        service.activeStatuses[game.igdbId]?.state,
        RomActionState.readyToPlay,
      );
    });

    test('pause -> resume keeps token registered so a subsequent pause still works', () async {
      _setupTempSupportDir();

      int requestCount = 0;
      final firstRequestStarted = Completer<void>();
      final secondRequestStarted = Completer<void>();
      final firstStreamController = StreamController<Uint8List>();
      final secondRequestCancelled = Completer<void>();

      final dio = Dio();
      dio.httpClientAdapter = _AsyncFakeHttpAdapter((options, cancelFuture) async {
        requestCount++;
        if (requestCount == 1) {
          if (!firstRequestStarted.isCompleted) {
            firstRequestStarted.complete();
          }
          unawaited(
            cancelFuture?.then((_) {
              if (!firstStreamController.isClosed) {
                firstStreamController.addError(
                  DioException.requestCancelled(
                    requestOptions: options,
                    reason: 'PAUSED_BY_USER',
                  ),
                );
                unawaited(firstStreamController.close());
              }
            }),
          );
          return ResponseBody(
            firstStreamController.stream,
            200,
            headers: {
              Headers.contentTypeHeader: ['application/octet-stream'],
              Headers.contentLengthHeader: ['262144'],
            },
          );
        }

        final secondController = StreamController<Uint8List>();
        if (!secondRequestStarted.isCompleted) {
          secondRequestStarted.complete();
        }
        unawaited(
          cancelFuture?.then((_) {
            if (!secondRequestCancelled.isCompleted) {
              secondRequestCancelled.complete();
            }
            if (!secondController.isClosed) {
              secondController.addError(
                DioException.requestCancelled(
                  requestOptions: options,
                  reason: 'PAUSED_BY_USER',
                ),
              );
              unawaited(secondController.close());
            }
          }),
        );
        return ResponseBody(
          secondController.stream,
          200,
          headers: {
            Headers.contentTypeHeader: ['application/octet-stream'],
            Headers.contentLengthHeader: ['262144'],
          },
        );
      });

      final service = RomDownloadService(dio: dio);
      addTearDown(service.dispose);

      final game = _makeTestGame(
        id: 88002,
        name: 'Double Pause',
        platformSlug: 'gba',
        directRomUrl: 'https://example.com/double_pause.gba',
        estimatedSizeBytes: 262144,
      );

      final firstFuture = service.startBackgroundDownload(game: game);
      await firstRequestStarted.future.timeout(const Duration(seconds: 2));

      service.pauseDownload(game.igdbId);
      final secondFuture = service.startBackgroundDownload(game: game);
      await firstFuture;
      await secondRequestStarted.future.timeout(const Duration(seconds: 2));

      // Second operation must still be cancellable via pauseDownload!
      service.pauseDownload(game.igdbId);
      await secondRequestCancelled.future.timeout(const Duration(seconds: 2));
      await secondFuture;
      expect(service.activeStatuses[game.igdbId]?.state, RomActionState.paused);
    });
  });

  group('GpuDriverService path traversal regressions', () {
    test('isValidDriverId and deleteDriver reject path traversal ("..") and preserve outside files', () async {
      final tempDir = _setupTempSupportDir();
      final service = GpuDriverService();
      addTearDown(service.dispose);

      expect(GpuDriverService.isValidDriverId('turnip_v24.1'), isTrue);
      expect(GpuDriverService.isValidDriverId('..'), isFalse);
      expect(GpuDriverService.isValidDriverId('.'), isFalse);
      expect(GpuDriverService.isValidDriverId('../victim'), isFalse);
      expect(GpuDriverService.isValidDriverId('a/b'), isFalse);
      expect(GpuDriverService.isValidDriverId(r'a\b'), isFalse);
      expect(GpuDriverService.isValidDriverId(''), isFalse);
      expect(GpuDriverService.isValidDriverId(' leading'), isFalse);
      expect(GpuDriverService.isValidDriverId('bad\x00id'), isFalse);

      final victimDir = Directory('${tempDir.path}/victim_dir');
      await victimDir.create(recursive: true);
      final victimFile = File('${victimDir.path}/keep_me.txt');
      await victimFile.writeAsString('do-not-delete', flush: true);

      await expectLater(
        () => service.deleteDriver('../victim_dir'),
        throwsArgumentError,
      );
      await expectLater(() => service.deleteDriver('..'), throwsArgumentError);
      await expectLater(() => service.deleteDriver('a/b'), throwsArgumentError);
      await expectLater(
        () => service.deleteDriver(r'a\b'),
        throwsArgumentError,
      );
      expect(await victimFile.exists(), isTrue);

      // Valid driver inside gpu_drivers/ can be deleted cleanly
      final validDriverDir = Directory('${tempDir.path}/gpu_drivers/turnip_ok');
      await validDriverDir.create(recursive: true);
      await File('${validDriverDir.path}/meta.json').writeAsString('{}');
      await service.deleteDriver('turnip_ok');
      expect(await validDriverDir.exists(), isFalse);
    });
  });

  group('UI regressions: Player exit dialog & Empty/Loading/Error states', () {
    testWidgets('HomeScreen renders loading, error+retry and empty states cleanly', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final downloadService = RomDownloadService();
      addTearDown(downloadService.dispose);

      // 1. Loading state
      await tester.pumpWidget(
        MaterialApp(
          theme: HydraTokens.buildAppTheme(),
          home: HomeScreen(
            featuredGames: const [],
            popularGames: const [],
            downloadService: downloadService,
            onStatusUpdated: (_, __) {},
            onLaunchGame: (_, __) {},
            isLoadingCatalog: true,
          ),
        ),
      );
      expect(find.text('Carregando catálogo...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      // 2. Error + retry state
      int retryCalls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: HydraTokens.buildAppTheme(),
          home: HomeScreen(
            featuredGames: const [],
            popularGames: const [],
            downloadService: downloadService,
            onStatusUpdated: (_, __) {},
            onLaunchGame: (_, __) {},
            isLoadingCatalog: false,
            catalogError: 'Falha simulada de rede',
            onRetryCatalog: () => retryCalls++,
          ),
        ),
      );
      expect(find.text('Erro ao carregar catálogo'), findsOneWidget);
      expect(find.text('Falha simulada de rede'), findsOneWidget);
      await tester.tap(find.text('Tentar novamente'));
      await tester.pump();
      expect(retryCalls, 1);

      // 3. Empty state
      await tester.pumpWidget(
        MaterialApp(
          theme: HydraTokens.buildAppTheme(),
          home: HomeScreen(
            featuredGames: const [],
            popularGames: const [],
            downloadService: downloadService,
            onStatusUpdated: (_, __) {},
            onLaunchGame: (_, __) {},
            isLoadingCatalog: false,
          ),
        ),
      );
      expect(find.text('Nenhum jogo disponível'), findsOneWidget);
    });

    testWidgets('LibraryScreen renders empty state cleanly', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(915, 412);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: HydraTokens.buildAppTheme(),
          home: LibraryScreen(
            downloadedGames: const [],
            downloadingGames: const [],
            downloadStatuses: const {},
            onImportNewRomPressed: () {},
            onLaunchGame: (_, __) {},
            onRemoveGame: (_) async {},
            onCancelDownload: (_) {},
          ),
        ),
      );

      expect(find.text('Nenhum jogo instalado ainda'), findsOneWidget);
    });

    testWidgets(
      'LibretroPlayerScreen requires exit confirmation and respects failed saveState',
      timeout: const Timeout(Duration(seconds: 15)),
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final tempDir = _setupTempSupportDir();

        // Pre-create valid ELF core synchronously so startSession does not hit network or stall FakeAsync
        final coresDir = Directory('${tempDir.path}/libretro_cores');
        coresDir.createSync(recursive: true);
        final coreBytes = Uint8List(32 * 1024);
        coreBytes[0] = 0x7F;
        coreBytes[1] = 0x45;
        coreBytes[2] = 0x4C;
        coreBytes[3] = 0x46;
        File('${coresDir.path}/mgba_libretro_android.so')
            .writeAsBytesSync(coreBytes, flush: true);

        const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
        const eventsChannel = EventChannel('org.loopgamer.libretro/events');

        bool saveStateResult = false;
        int stopSessionCalls = 0;

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, (call) async {
          switch (call.method) {
            case 'startLibretroSession':
              return 1;
            case 'saveState':
              return saveStateResult;
            case 'stopLibretroSession':
              stopSessionCalls++;
              return null;
            default:
              return null;
          }
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
          eventsChannel,
          MockStreamHandler.inline(
            onListen: (args, events) {},
            onCancel: (args) {},
          ),
        );
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodsChannel, null);
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockStreamHandler(eventsChannel, null);
        });

        final emulatorService = EmulatorService();
        addTearDown(emulatorService.dispose);

        final game = _makeTestGame(
          id: 9901,
          name: 'Aria of Sorrow',
          platformName: 'GBA',
          platformSlug: 'gba',
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
            home: Builder(
              builder: (ctx) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () {
                      unawaited(
                        Navigator.of(ctx).push(
                          MaterialPageRoute<void>(
                            builder: (_) => LibretroPlayerScreen(
                              game: game,
                              romPath: '${tempDir.path}/aria.gba',
                              emulatorService: emulatorService,
                              initialSettings: const AppSettings(),
                              onSettingsChanged: (_) {},
                            ),
                          ),
                        ),
                      );
                    },
                    child: const Text('Launch Player'),
                  ),
                ),
              ),
            ),
          ),
        );

        Future<void> pumpUntilFound(Finder finder) async {
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 25));
            if (finder.evaluate().isNotEmpty) return;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          await tester.pump();
        }

        Future<void> pumpUntilGone(Finder finder) async {
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 50));
            if (finder.evaluate().isEmpty) return;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 20)),
            );
          }
          await tester.pump();
        }

        await tester.tap(find.text('Launch Player'));
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 300));

        expect(find.byType(LibretroPlayerScreen), findsOneWidget);

        // Open sidebar via HUD pill (wait for async slot inspection), then tap 'Sair'
        await tester.tap(find.byTooltip('Abrir menu do jogo'));
        await pumpUntilFound(find.text('Sair'));
        expect(find.text('Sair'), findsOneWidget);

        await tester.tap(find.text('Sair'));
        await tester.pump(const Duration(milliseconds: 200));

        // Confirmation dialog must be visible with all 3 options
        expect(find.text('Encerrar partida?'), findsOneWidget);
        expect(find.text('Cancelar'), findsOneWidget);
        expect(find.text('Sair sem salvar'), findsOneWidget);
        expect(find.text('Salvar rápido e sair'), findsOneWidget);

        // 1. Tap Cancelar -> stays on player
        await tester.tap(find.text('Cancelar'));
        await tester.pump(const Duration(milliseconds: 150));
        expect(find.text('Encerrar partida?'), findsNothing);
        expect(find.byType(LibretroPlayerScreen), findsOneWidget);

        // 2. Tap Sair -> 'Salvar rápido e sair' when saveState fails -> stays on player and shows error
        saveStateResult = false;
        await tester.tap(find.text('Sair'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('Salvar rápido e sair'));
        await pumpUntilFound(
          find.textContaining('não suporta ou falhou ao salvar'),
        );
        expect(find.byType(LibretroPlayerScreen), findsOneWidget);
        expect(
          find.textContaining('não suporta ou falhou ao salvar'),
          findsOneWidget,
        );

        // 3. Tap Sair -> 'Sair sem salvar' -> pops cleanly back to launcher
        await tester.tap(find.text('Sair'));
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(find.text('Sair sem salvar'));
        await pumpUntilGone(find.byType(LibretroPlayerScreen));

        expect(find.byType(LibretroPlayerScreen), findsNothing);
        expect(find.text('Launch Player'), findsOneWidget);
        expect(stopSessionCalls, greaterThanOrEqualTo(1));
      },
    );

    testWidgets(
      'LibraryScreen landscape renders 3:4 vertical carousel cards and launches ready game',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final readyGame = _makeTestGame(
          id: 101,
          name: 'Chrono Adventure',
          localRomPath: '/tmp/chrono.gba',
        );
        final downloadingGame = _makeTestGame(
          id: 102,
          name: 'Tactics Advance',
        );

        EmulationGame? launchedGame;
        String? launchedPath;
        const meta = UserLibraryMeta(
          favorites: {101},
          playtime: {
            101: PlaytimeRecord(totalSeconds: 42 * 60, sessions: 1),
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: LibraryScreen(
              downloadedGames: [readyGame],
              downloadingGames: [downloadingGame],
              downloadStatuses: const {
                102: RomDownloadStatus(
                  state: RomActionState.downloading,
                  progress: 0.45,
                  speedLabel: '2.4 MB/s',
                ),
              },
              userMeta: meta,
              onImportNewRomPressed: () {},
              onLaunchGame: (g, p) {
                launchedGame = g;
                launchedPath = p;
              },
              onRemoveGame: (_) async {},
              onCancelDownload: (_) {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));

        expect(find.text('Chrono Adventure'), findsAtLeastNWidgets(1));
        expect(find.text('Tactics Advance'), findsAtLeastNWidgets(1));
        expect(find.byType(ProceduralCover), findsAtLeastNWidgets(2));
        expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
        expect(find.text('Cancelar'), findsOneWidget);

        // Seleciona o card do jogo pronto e clica em Jogar
        await tester.tap(find.text('Chrono Adventure').first);
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Jogar'), findsOneWidget);

        await tester.tap(find.text('Jogar'));
        await tester.pump();
        expect(launchedGame?.igdbId, 101);
        expect(launchedPath, '/tmp/chrono.gba');
      },
    );

    testWidgets(
      'LoopGamerApp landscape floating top bar reflects native Wi-Fi status',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, (call) async {
          if (call.method == 'getNetworkStatus') {
            return <String, dynamic>{'connected': true, 'wifi': false};
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodsChannel, null);
        });

        await tester.pumpWidget(const LoopGamerApp());
        await tester.pump();

        expect(find.bySemanticsLabel('Sem Wi-Fi (dados móveis)'), findsOneWidget);
        expect(find.bySemanticsLabel('Buscar ROMs'), findsOneWidget);
        expect(find.bySemanticsLabel('Abrir Biblioteca'), findsOneWidget);
        final titleText = tester.widget<Text>(find.text('LOOPGAMER'));
        expect(titleText.style?.fontFamily, 'PressStart2P');
        expect(
          find.ancestor(
            of: find.text('LOOPGAMER'),
            matching: find.byType(Center),
          ),
          findsOneWidget,
        );
      },
    );
  });
}
