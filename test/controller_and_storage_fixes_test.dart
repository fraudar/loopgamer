import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/main.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/screens/explore_screen.dart';
import 'package:loopgamer/screens/library_screen.dart';
import 'package:loopgamer/screens/libretro_player_screen.dart';
import 'package:loopgamer/screens/settings_screen.dart';
import 'package:loopgamer/services/emulator_service.dart';
import 'package:loopgamer/services/library_storage_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/theme/hydra_tokens.dart';

class _TestHttpAdapter implements HttpClientAdapter {
  _TestHttpAdapter(this._handler);

  final Future<ResponseBody> Function(
    RequestOptions options,
    Future<void>? cancelFuture,
  ) _handler;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      _handler(options, cancelFuture);

  @override
  void close({bool force = false}) {}
}

Directory _setupIsolatedSupportDir() {
  final dir = Directory.systemTemp.createTempSync('loopgamer_fix_test_');
  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async => dir.path);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, null);
    if (dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
  });
  return dir;
}

List<int> _buildZipBytes(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    archive.addFile(
      ArchiveFile(entry.key, entry.value.length, entry.value),
    );
  }
  return ZipEncoder().encode(archive)!;
}

EmulationGame _testGame({
  required int id,
  String name = 'Street Fighter Alpha 3',
  String platformName = 'PlayStation',
  String platformSlug = 'ps1',
  String directRomUrl = 'https://example.com/sf3.gba',
  int estimatedSizeBytes = 0,
  String? localRomPath,
}) {
  return EmulationGame(
    igdbId: id,
    name: name,
    canonicalNoIntroName: '$name (USA)',
    summary: 'Teste de regressão.',
    genres: const ['Luta'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 92.0,
    platformName: platformName,
    platformSlug: platformSlug,
    directRomUrl: directRomUrl,
    estimatedSizeBytes: estimatedSizeBytes,
    localRomPath: localRomPath,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Core Isolate extraction & Storage fixes', () {
    test(
      'ensureCoreDownloaded extracts ELF .so without unsendable Completer isolate crash',
      () async {
        _setupIsolatedSupportDir();

        final elfPayload = Uint8List(EmulatorService.minCoreSoBytes + 64);
        elfPayload[0] = 0x7F;
        elfPayload[1] = 0x45;
        elfPayload[2] = 0x4C;
        elfPayload[3] = 0x46;

        final coreZip = _buildZipBytes({
          'pcsx_rearmed_libretro_android.so': elfPayload,
        });

        final dio = Dio();
        dio.httpClientAdapter = _TestHttpAdapter((options, cancel) async {
          return ResponseBody.fromBytes(
            coreZip,
            200,
            headers: {
              Headers.contentLengthHeader: ['${coreZip.length}'],
            },
          );
        });

        final emulatorService = EmulatorService(dio: dio);
        addTearDown(emulatorService.dispose);

        // Simulates capturing an unsendable _AsyncCompleter in the caller context.
        final unsendableCompleter = Completer<void>();
        final reportedProgress = <double>[];

        final corePath = await emulatorService.ensureCoreDownloaded(
          coreSoName: 'pcsx_rearmed_libretro_android.so',
          onDownloadProgress: (p) {
            reportedProgress.add(p);
            if (!unsendableCompleter.isCompleted && p >= 1.0) {
              unsendableCompleter.complete();
            }
          },
        );

        expect(File(corePath).existsSync(), isTrue);
        expect(reportedProgress, isNotEmpty);
        expect(unsendableCompleter.isCompleted, isTrue);
      },
    );

    test(
      'Multi-file CUE/BIN computes full folder size, repairs stale 0 KB entries, and never formats 0 KB for non-empty files',
      () async {
        final root = _setupIsolatedSupportDir();
        final gameDir = Directory('${root.path}/roms/game_777')
          ..createSync(recursive: true);
        final cueFile = File('${gameDir.path}/Street Fighter Alpha 3 (USA).cue')
          ..writeAsStringSync(
            'FILE "Street Fighter Alpha 3 (USA) (Track 1).bin" BINARY\n  TRACK 01 MODE2/2352\n',
          );
        final bin1 =
            File('${gameDir.path}/Street Fighter Alpha 3 (USA) (Track 1).bin')
              ..writeAsBytesSync(List<int>.filled(4096, 1));
        final bin2 =
            File('${gameDir.path}/Street Fighter Alpha 3 (USA) (Track 2).bin')
              ..writeAsBytesSync(List<int>.filled(2048, 2));

        final expectedBytes =
            cueFile.lengthSync() + bin1.lengthSync() + bin2.lengthSync();

        expect(
          _testGame(id: 1, estimatedSizeBytes: 0).formattedSize,
          'Tam. n/d',
        );
        expect(
          _testGame(id: 1, estimatedSizeBytes: 180).formattedSize,
          '< 1 KB',
        );

        final resolved = await LibraryStorageService.resolveInstalledRomSizeBytes(
          cueFile.path,
          fallbackBytes: 180,
        );
        expect(resolved, expectedBytes);

        final storage = LibraryStorageService();
        await storage.saveGameToLibrary(
          _testGame(id: 777, estimatedSizeBytes: 0, localRomPath: cueFile.path),
          cueFile.path,
        );

        // Tamper the saved manifest size back to 0 to verify loadPersistedLibrary auto-repairs it.
        final manifestFile = File('${root.path}/library_manifest.json');
        final decodedRoot =
            jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
        final rawList =
            (decodedRoot['games'] as List).cast<Map<String, dynamic>>();
        rawList.first['estimatedSizeBytes'] = 0;
        manifestFile.writeAsStringSync(jsonEncode(decodedRoot));

        final loaded = await storage.loadPersistedLibrary();
        expect(loaded, hasLength(1));
        expect(loaded.first.estimatedSizeBytes, expectedBytes);
        expect(loaded.first.formattedSize, isNot('0 KB'));
        expect(loaded.first.formattedSize, '6 KB');
      },
    );

    test(
      'Compressed zip ROMs are extracted and source .zip is deleted without duplication; arcade zips and neogeo.zip remain intact',
      () async {
        final root = _setupIsolatedSupportDir();
        final gbaRom = Uint8List(140 * 1024);
        final zipBytes = _buildZipBytes({'AdvanceWars.gba': gbaRom});

        final externalSource = File('${root.path}/downloads_tmp/AdvanceWars.zip')
          ..parent.createSync(recursive: true)
          ..writeAsBytesSync(zipBytes);

        final downloadService = RomDownloadService();
        addTearDown(downloadService.dispose);

        final imported = await downloadService.importExternalRomFile(
          igdbId: 888,
          sourcePath: externalSource.path,
          platformSlug: 'gba',
        );
        expect(imported, isNotNull);
        expect(imported!.localPath, endsWith('AdvanceWars.gba'));
        expect(imported.totalBytes, gbaRom.length);

        // No leftover duplicate .zip inside roms/ or roms/game_888/
        expect(
          File('${root.path}/roms/rom_888_AdvanceWars.zip').existsSync(),
          isFalse,
        );
        final gameDirZips = Directory('${root.path}/roms/game_888')
            .listSync(recursive: true)
            .where((e) => e.path.toLowerCase().endsWith('.zip'));
        expect(gameDirZips, isEmpty);

        // Plant an orphan .part + stale duplicate .zip + valid arcade .zip + neogeo.zip
        final dupZip = File('${root.path}/roms/rom_888_AdvanceWars.zip')
          ..writeAsBytesSync(List<int>.filled(4096, 3));
        final orphanPart = File('${root.path}/roms/rom_999_broken.gba.part')
          ..writeAsBytesSync(List<int>.filled(2048, 4));
        final arcadeDir = Directory('${root.path}/roms/arcade_555')
          ..createSync(recursive: true);
        final arcadeRom = File('${arcadeDir.path}/sf2.zip')
          ..writeAsBytesSync(List<int>.filled(1024, 5));
        final neogeoBios = File('${arcadeDir.path}/neogeo.zip')
          ..writeAsBytesSync(List<int>.filled(1024, 6));

        final freed = await downloadService.cleanOrphanPartAndCacheFiles();
        expect(freed, greaterThanOrEqualTo(4096 + 2048));
        expect(dupZip.existsSync(), isFalse);
        expect(orphanPart.existsSync(), isFalse);
        expect(arcadeRom.existsSync(), isTrue);
        expect(neogeoBios.existsSync(), isTrue);
      },
    );

    test(
      'FIFO queue downloads all 5 queued ROMs (concurrency <= 2), reports breakdown, and syncs native notification',
      () async {
        final root = _setupIsolatedSupportDir();
        final notificationCalls = <Map<String, dynamic>>[];

        const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, (call) async {
          if (call.method == 'requestNotificationPermission') return true;
          if (call.method == 'syncDownloadNotification') {
            notificationCalls.add(
              Map<String, dynamic>.from(call.arguments as Map),
            );
            return true;
          }
          if (call.method == 'getNetworkStatus') {
            return <String, dynamic>{'connected': true, 'wifi': true};
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodsChannel, null);
        });

        int activeRequests = 0;
        int maxConcurrentObserved = 0;
        final romBytes = Uint8List(140 * 1024);

        final dio = Dio();
        dio.httpClientAdapter = _TestHttpAdapter((options, cancel) async {
          activeRequests++;
          maxConcurrentObserved = math.max(maxConcurrentObserved, activeRequests);
          await Future<void>.delayed(const Duration(milliseconds: 30));
          activeRequests--;
          return ResponseBody.fromBytes(
            romBytes,
            200,
            headers: {
              Headers.contentLengthHeader: ['${romBytes.length}'],
            },
          );
        });

        final downloadService = RomDownloadService(dio: dio);
        addTearDown(downloadService.dispose);

        final readyIds = <int>{};
        var sawQueuedState = false;
        final sub = downloadService.downloadEvents.listen((event) {
          if (event.status.isQueued) {
            sawQueuedState = true;
          }
          if (event.status.state == RomActionState.readyToPlay) {
            readyIds.add(event.game.igdbId);
          }
        });
        addTearDown(sub.cancel);

        final games = List<EmulationGame>.generate(
          5,
          (i) => _testGame(
            id: 500 + i,
            name: 'Game $i',
            platformName: 'Game Boy Advance',
            platformSlug: 'gba',
            directRomUrl: 'https://example.com/game_$i.gba',
            estimatedSizeBytes: romBytes.length,
          ),
        );

        final paths = await Future.wait(
          games.map((g) => downloadService.startBackgroundDownload(game: g)),
        );
        await pumpEventQueue();

        expect(paths.whereType<String>(), hasLength(5));
        expect(maxConcurrentObserved, lessThanOrEqualTo(2));
        expect(sawQueuedState, isTrue);
        expect(readyIds, equals({500, 501, 502, 503, 504}));
        expect(notificationCalls, isNotEmpty);

        // Verify breakdown accounts for installed ROMs + PS3 firmware.
        final pupFile = File('${root.path}/PS3UPDAT.PUP')
          ..writeAsBytesSync(List<int>.filled(4096, 9));
        expect(pupFile.existsSync(), isTrue);

        final breakdown = await downloadService.getAppStorageBreakdown();
        expect(breakdown.readyRomsBytes, 5 * romBytes.length);
        expect(breakdown.ps3FirmwareBytes, 4096);
        expect(breakdown.totalAppBytes, greaterThanOrEqualTo(breakdown.readyRomsBytes));
      },
    );

    test('EmulatorService.removePs3Firmware removes firmware files cleanly', () async {
      final root = _setupIsolatedSupportDir();
      final pupRoot = File('${root.path}/PS3UPDAT.PUP')
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 64));
      final pupNested = File('${root.path}/rpcs3/PS3UPDAT.PUP')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 64));
      final pupFirmware = File('${root.path}/rpcs3/firmware/PS3UPDAT.PUP')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 64));
      final flashDir = Directory('${root.path}/rpcs3/dev_flash/sys')
        ..createSync(recursive: true);
      File('${flashDir.path}/dummy.sprx').writeAsBytesSync([1, 2, 3, 4]);

      final service = EmulatorService();
      addTearDown(service.dispose);

      expect(await service.hasPs3Firmware(), isTrue);
      final removed = await service.removePs3Firmware();
      expect(removed, isTrue);
      expect(await service.hasPs3Firmware(), isFalse);
      expect(pupRoot.existsSync(), isFalse);
      expect(pupNested.existsSync(), isFalse);
      expect(pupFirmware.existsSync(), isFalse);
      expect(flashDir.existsSync(), isFalse);
    });

    test('EmulatorService migrates legacy PS3UPDAT.PUP into rpcs3/firmware/PS3UPDAT.PUP', () async {
      final root = _setupIsolatedSupportDir();
      final pupRoot = File('${root.path}/PS3UPDAT.PUP')
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 128));
      final pupNested = File('${root.path}/rpcs3/PS3UPDAT.PUP')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(1024 * 1024 + 128));

      final service = EmulatorService();
      addTearDown(service.dispose);

      expect(await service.hasPs3Firmware(), isTrue);
      expect(await service.ensureCanonicalPs3FirmwareLayout(), isTrue);
      final canonical = File('${root.path}/rpcs3/firmware/PS3UPDAT.PUP');
      expect(canonical.existsSync(), isTrue);
      expect(canonical.lengthSync(), 1024 * 1024 + 128);
      expect(pupRoot.existsSync(), isFalse);
      expect(pupNested.existsSync(), isFalse);
    });

    test('AppSettings keeps ppsspp_fast_memory enabled and startSession writes FastMemory = True and unwraps core errors', () async {
      final root = _setupIsolatedSupportDir();
      final coreDir = Directory('${root.path}/libretro_cores')
        ..createSync(recursive: true);
      final fakeElf = Uint8List(EmulatorService.minCoreSoBytes + 64)
        ..[0] = 0x7F
        ..[1] = 0x45
        ..[2] = 0x4C
        ..[3] = 0x46;
      final pspCore = File('${coreDir.path}/ppsspp_libretro_android.so')
        ..writeAsBytesSync(fakeElf);
      expect(pspCore.existsSync(), isTrue);

      // O boot de PSP exige os assets oficiais do PPSSPP em system/PPSSPP —
      // semeia o marcador para o teste não depender de rede.
      File('${root.path}/PPSSPP/flash0/font/jpn0.pgf')
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(Uint8List(2048));

      const settings = AppSettings();
      expect(settings.libretroCoreOptions['ppsspp_fast_memory'], 'enabled');
      expect(
        settings.libretroCoreOptions['ppsspp_ignore_bad_memory_access'],
        'enabled',
      );

      const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
      String? invokedCorePath;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(methodsChannel, (call) async {
        if (call.method == 'startLibretroSession') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          invokedCorePath = args['corePath'] as String?;
          throw PlatformException(
            code: 'CORE_LOAD_FAILED',
            message: 'Falha simulada do núcleo libretro.',
          );
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, null);
      });

      final service = EmulatorService();
      addTearDown(service.dispose);

      await expectLater(
        () => service.startSession(
          platformSlug: 'psp',
          coreSoName: 'ppsspp_libretro_android.so',
          romPath: '${root.path}/ac_bloodlines.iso',
          coreOptions: settings.libretroCoreOptions,
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Falha simulada do núcleo libretro.',
          ),
        ),
      );
      expect(invokedCorePath, pspCore.path);

      final ppssppIni = File('${root.path}/PPSSPP/system/ppsspp.ini');
      expect(ppssppIni.existsSync(), isTrue);
      final iniText = ppssppIni.readAsStringSync();
      expect(iniText, contains('FastMemory = True'));
      expect(iniText, isNot(contains('FastMemory = False')));
    });

    test('LibretroTelemetryEvent parses fatal core error and shutdown fields', () {
      final event = LibretroTelemetryEvent.fromMap({
        'fps': 0.0,
        'frameTimeMs': 16.6,
        'width': 1280,
        'height': 720,
        'coreName': 'rpcs3_libretro_android.so',
        'hasRenderedFrame': false,
        'coreShutdown': true,
        'coreFatal': true,
        'coreError': 'ISO de PS3 criptografada (Redump)',
      });

      expect(event.hasRenderedFrame, isFalse);
      expect(event.coreShutdown, isTrue);
      expect(event.coreFatal, isTrue);
      expect(event.coreError, 'ISO de PS3 criptografada (Redump)');
    });
  });

  group('UI, External ISO, PS3 Removal & Controller navigation', () {
    testWidgets(
      'GameDetailSheet omits Arquivo Local and points external games to Biblioteca',
      (WidgetTester tester) async {
        _setupIsolatedSupportDir();
        final downloadService = RomDownloadService();
        addTearDown(downloadService.dispose);

        final externalGame = _testGame(
          id: 901,
          name: 'Shadow Hearts',
          platformName: 'PlayStation 2',
          platformSlug: 'ps2',
          directRomUrl: 'external://ps2/shadow.iso',
          estimatedSizeBytes: 0,
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: Scaffold(
              body: GameDetailSheet(
                game: externalGame,
                downloadService: downloadService,
                initialStatus: const RomDownloadStatus(),
                onStatusChanged: (_) {},
                onPlayPressed: (_) {},
              ),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Arquivo Local'), findsNothing);
        expect(find.text('Importar Arquivo Local'), findsNothing);
        expect(find.text('Selecionar arquivo'), findsNothing);
        expect(find.text('Importe pela Biblioteca'), findsOneWidget);
      },
    );

    testWidgets(
      'LibraryScreen exposes Importar ISO / ROM button and invokes callback',
      (WidgetTester tester) async {
        _setupIsolatedSupportDir();
        var importCalls = 0;

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: LibraryScreen(
              downloadedGames: const [],
              downloadingGames: const [],
              downloadStatuses: const {},
              onImportNewRomPressed: () {},
              onImportExternalIsoPressed: () => importCalls++,
              onLaunchGame: (_, __) {},
              onRemoveGame: (_) async {},
              onCancelDownload: (_) {},
            ),
          ),
        );
        await tester.pump();

        final importButton = find.text('Importar ISO / ROM');
        expect(importButton, findsOneWidget);
        await tester.tap(importButton);
        await tester.pump();
        expect(importCalls, 1);
      },
    );

    testWidgets(
      'SettingsScreen displays PS3 firmware removal button when installed and deletes it on confirmation',
      (WidgetTester tester) async {
        final root = _setupIsolatedSupportDir();
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final pupFile = File('${root.path}/PS3UPDAT.PUP')
          ..writeAsBytesSync(Uint8List(1024 * 1024 + 64));
        final downloadService = RomDownloadService();
        addTearDown(downloadService.dispose);
        final emulatorService = EmulatorService();
        addTearDown(emulatorService.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
            home: SettingsScreen(
              settings: const AppSettings(),
              downloadService: downloadService,
              onSettingsChanged: (_) {},
              emulatorService: emulatorService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        await tester.pumpAndSettle();

        // Scroll portrait list past Firmware PS3 card so both title and action buttons are visible.
        final firmwareTitle = find.text('Firmware PS3 (PS3UPDAT.PUP)');
        await tester.scrollUntilVisible(
          find.text('Servidor RomM Privado'),
          300.0,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        expect(firmwareTitle, findsOneWidget);
        final removeButton = find.text('Remover');
        expect(removeButton, findsOneWidget);

        await tester.ensureVisible(removeButton);
        await tester.tap(removeButton);
        await tester.pumpAndSettle();
        expect(find.text('Remover firmware de PS3?'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Remover'),
          ),
        );
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 30)),
          );
        }
        await tester.pumpAndSettle();

        expect(pupFile.existsSync(), isFalse);
        expect(find.text('Remover'), findsNothing);
      },
    );

    testWidgets(
      'LoopGamerApp switches sections with LB/RB and opens Ajustes with Xbox Guide button',
      (WidgetTester tester) async {
        _setupIsolatedSupportDir();
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, (call) async {
          if (call.method == 'getNetworkStatus') {
            return <String, dynamic>{'connected': true, 'wifi': true};
          }
          return null;
        });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodsChannel, null);
        });

        await tester.pumpWidget(const LoopGamerApp());
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        IndexedStack currentStack() =>
            tester.widget<IndexedStack>(find.byType(IndexedStack));

        expect(currentStack().index, 0);

        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
        await tester.pump();
        expect(currentStack().index, 1);

        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonRight1);
        await tester.pump();
        expect(currentStack().index, 2);

        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
        await tester.pump();
        expect(currentStack().index, 1);

        // Xbox logo / Guide button opens Settings (tab 3).
        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonMode);
        await tester.pump();
        expect(currentStack().index, 3);
      },
    );
  });

  group('Play! PS2 core options', () {
    test('defaults and low presets enable 2x resolution, bilinear filtering, and Fit Screen', () {
      const defaults = AppSettings();
      expect(defaults.libretroCoreOptions['play_res_multi'], '2x');
      expect(defaults.libretroCoreOptions['play_bilinear_filtering'], 'true');
      expect(defaults.libretroCoreOptions['play_presentation_mode'], 'Fit Screen');

      final x1 = defaults.copyWith(renderResolution: RenderResolutionPreset.x1);
      final x2 = defaults.copyWith(renderResolution: RenderResolutionPreset.x2);
      expect(x1.libretroCoreOptions['play_res_multi'], '2x');
      expect(x2.libretroCoreOptions['play_res_multi'], '2x');
    });

    test('higher renderResolution presets scale play_res_multi to 4x and 8x', () {
      const base = AppSettings();
      for (final preset in const [
        RenderResolutionPreset.x3,
        RenderResolutionPreset.x4,
        RenderResolutionPreset.p1080,
      ]) {
        expect(
          base.copyWith(renderResolution: preset).libretroCoreOptions['play_res_multi'],
          '4x',
          reason: 'Expected 4x for $preset',
        );
      }

      for (final preset in const [
        RenderResolutionPreset.x5,
        RenderResolutionPreset.x8,
        RenderResolutionPreset.k4,
      ]) {
        expect(
          base.copyWith(renderResolution: preset).libretroCoreOptions['play_res_multi'],
          '8x',
          reason: 'Expected 8x for $preset',
        );
      }
    });
  });

  group('PS3 firmware removal & orphaned cache cleanup', () {
    test('removePs3Firmware deletes flash3, caches, dev_hdd1, dev_hdd0/game and empty rpcs3/', () async {
      final root = _setupIsolatedSupportDir();
      final paths = <String>[
        '${root.path}/PS3UPDAT.PUP',
        '${root.path}/rpcs3/PS3UPDAT.PUP',
        '${root.path}/rpcs3/firmware/PS3UPDAT.PUP',
        '${root.path}/rpcs3/dev_flash/sys/vsh.self',
        '${root.path}/rpcs3/dev_flash2/etc/x.dat',
        '${root.path}/rpcs3/dev_flash3/data/font.ttf',
        '${root.path}/rpcs3/dev_hdd1/caches/swap.bin',
        '${root.path}/rpcs3/cache/ppu/module.obj',
        '${root.path}/rpcs3/dev_hdd0/game/BLES00909/USRDIR/data.psarc',
        '${root.path}/rpcs3/config/config.yml',
        '${root.path}/rpcs3/tmp/shader.tmp',
        '${root.path}/rpcs3/dev_hdd0/home/00000001/localusername',
      ];
      for (final p in paths) {
        File(p)
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(1024, 7));
      }

      final emulator = EmulatorService();
      addTearDown(emulator.dispose);
      final ok = await emulator.removePs3Firmware();
      expect(ok, isTrue);
      expect(File('${root.path}/PS3UPDAT.PUP').existsSync(), isFalse);
      expect(Directory('${root.path}/rpcs3').existsSync(), isFalse);
    });

    test('removePs3Firmware keeps user PS3 savedata while purging caches and flash', () async {
      final root = _setupIsolatedSupportDir();
      final saveFile = File(
        '${root.path}/rpcs3/dev_hdd0/home/00000001/savedata/BLES00909/PARAM.SFO',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(512, 3));
      final staleFiles = <String>[
        '${root.path}/rpcs3/dev_flash3/extra.dat',
        '${root.path}/rpcs3/dev_hdd1/hdd1.bin',
        '${root.path}/rpcs3/cache/spu.dat',
        '${root.path}/rpcs3/dev_hdd0/game/BLES00909/big.psarc',
      ];
      for (final p in staleFiles) {
        File(p)
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(2048, 9));
      }

      final emulator = EmulatorService();
      addTearDown(emulator.dispose);
      final ok = await emulator.removePs3Firmware();
      expect(ok, isTrue);
      expect(saveFile.existsSync(), isTrue);
      expect(Directory('${root.path}/rpcs3/dev_flash3').existsSync(), isFalse);
      expect(Directory('${root.path}/rpcs3/dev_hdd1').existsSync(), isFalse);
      expect(Directory('${root.path}/rpcs3/cache').existsSync(), isFalse);
      expect(Directory('${root.path}/rpcs3/dev_hdd0/game').existsSync(), isFalse);
    });

    test('getAppStorageBreakdown and cleanOrphanPartAndCacheFiles classify and reclaim orphaned rpcs3/logs', () async {
      final root = _setupIsolatedSupportDir();
      final romFile = File('${root.path}/roms/ps2/sfex3.iso')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(8192, 1));
      final saveFile = File(
        '${root.path}/rpcs3/dev_hdd0/home/00000001/savedata/BLES00909/SAVE.DAT',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(512, 2));
      final orphanFlash3 = File('${root.path}/rpcs3/dev_flash3/extra.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 4));
      final orphanHdd1 = File('${root.path}/rpcs3/dev_hdd1/cache.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 5));
      final orphanCache = File('${root.path}/rpcs3/cache/jit.obj')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 6));
      final orphanGame = File('${root.path}/rpcs3/dev_hdd0/game/BLES/game.psarc')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 7));
      final orphanLog = File('${root.path}/logs/core.log')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(2048, 8));

      final downloads = RomDownloadService();
      addTearDown(downloads.dispose);
      final before = await downloads.getAppStorageBreakdown();
      expect(before.readyRomsBytes, 8192);
      expect(before.savesAndCoversBytes, greaterThanOrEqualTo(512));
      expect(before.tempCacheBytes, 4096 * 4 + 2048);

      final freed = await downloads.cleanOrphanPartAndCacheFiles();
      expect(freed, greaterThanOrEqualTo(4096 * 4 + 2048));
      expect(romFile.existsSync(), isTrue);
      expect(saveFile.existsSync(), isTrue);
      expect(orphanFlash3.existsSync(), isFalse);
      expect(orphanHdd1.existsSync(), isFalse);
      expect(orphanCache.existsSync(), isFalse);
      expect(orphanGame.existsSync(), isFalse);
      expect(orphanLog.existsSync(), isFalse);
    });
  });

  group('RPCS3 aps3e options & zero-copy external ISO execution', () {
    test('AppSettings.libretroCoreOptions configures safe Android RPCS3 options', () {
      const settings = AppSettings();
      final opts = settings.libretroCoreOptions;
      expect(opts['rpcs3_database_override'], 'disabled');
      expect(opts['rpcs3_ppu_decoder'], 'llvm');
      expect(opts['rpcs3_spu_decoder'], 'llvm');
      expect(opts['rpcs3_ppu_threads'], '2');
      expect(opts['rpcs3_llvm_threads'], '2');
      expect(opts['rpcs3_shader_compiler_threads'], '1');
      expect(opts['rpcs3_shader_mode'], 'async');
      expect(opts['rpcs3_strict_rendering'], 'disabled');
      expect(opts['rpcs3_max_spurs_threads'], '4');
      expect(opts['rpcs3_resolution_scale'], '100');
      expect(opts['rpcs3_spu_verification'], 'enabled');
      expect(opts['rpcs3_emulate_bdvd_speed'], 'disabled');
      expect(opts['rpcs3_async_texture_streaming'], 'disabled');
      expect(opts['rpcs3_hle_lwmutex'], 'disabled');
      expect(opts['rpcs3_shader_quality'], 'low');
    });

    test('importExternalRomFile links ISO directly without copying and deleteRomFilesForGame keeps external file intact', () async {
      final root = _setupIsolatedSupportDir();
      final externalIso = File('${root.path}/downloads_tmp/GodOfWar2.iso')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(8192, 7));

      final downloads = RomDownloadService();
      addTearDown(downloads.dispose);

      final linked = await downloads.importExternalRomFile(
        igdbId: 901234567,
        sourcePath: externalIso.path,
        platformSlug: 'ps2',
      );
      expect(linked, isNotNull);
      expect(linked!.localPath, externalIso.path);
      expect(linked.totalBytes, 8192);

      // Nothing copied into supportDir/roms/
      final romsDir = Directory('${root.path}/roms');
      if (romsDir.existsSync()) {
        expect(
          romsDir.listSync(recursive: true).whereType<File>(),
          isEmpty,
        );
      }

      // resolveExistingRomPath resolves external knownLocalPath
      final resolved = await downloads.resolveExistingRomPath(
        901234567,
        knownLocalPath: externalIso.path,
      );
      expect(resolved, externalIso.path);

      // Removing game from Library MUST NOT delete the user's external ISO
      await downloads.deleteRomFilesForGame(
        901234567,
        localPath: externalIso.path,
      );
      expect(externalIso.existsSync(), isTrue);
    });

    test('cleanSavesAndCovers separates covers vs saves and preserves ROMs/manifests', () async {
      final root = _setupIsolatedSupportDir();
      final romFile = File('${root.path}/roms/psp/tekken.iso')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 1));
      final manifestFile = File('${root.path}/library_manifest.json')
        ..writeAsStringSync('{"games":[]}');
      final saveFile = File('${root.path}/saves/tekken_slot0.state')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(8192, 2));
      final ps3Save = File(
        '${root.path}/rpcs3/dev_hdd0/home/00000001/savedata/BLES01508/DATA.BIN',
      )
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(4096, 3));
      final coverFile = File('${root.path}/covers/1265.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(2048, 4));
      final cachedCover = File('${root.path}/loop_covers_cache/cover_1.png')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List<int>.filled(2048, 5));

      final downloads = RomDownloadService();
      addTearDown(downloads.dispose);

      final before = await downloads.getAppStorageBreakdown();
      expect(before.savesBytes, 8192 + 4096);
      expect(before.coversBytes, 2048 + 2048);
      expect(before.savesAndCoversBytes, before.savesBytes + before.coversBytes);

      // Step 1: Delete ONLY covers -> saves and ROM remain intact
      final freedCovers = await downloads.cleanSavesAndCovers(
        deleteSaves: false,
        deleteCovers: true,
      );
      expect(freedCovers, 4096);
      expect(coverFile.existsSync(), isFalse);
      expect(cachedCover.existsSync(), isFalse);
      expect(saveFile.existsSync(), isTrue);
      expect(ps3Save.existsSync(), isTrue);
      expect(romFile.existsSync(), isTrue);
      expect(manifestFile.existsSync(), isTrue);

      // Step 2: Delete saves as well -> saves gone, ROM & manifest still intact
      final freedSaves = await downloads.cleanSavesAndCovers(
        deleteSaves: true,
        deleteCovers: true,
      );
      expect(freedSaves, 8192 + 4096);
      expect(saveFile.existsSync(), isFalse);
      expect(ps3Save.existsSync(), isFalse);
      expect(romFile.existsSync(), isTrue);
      expect(manifestFile.existsSync(), isTrue);

      final after = await downloads.getAppStorageBreakdown();
      expect(after.savesAndCoversBytes, 0);
      expect(after.readyRomsBytes, 4096);
    });

    testWidgets(
      'SettingsScreen displays Limpar capas e saves button below Limpar cache e .part and deletes covers/saves on confirmation',
      (WidgetTester tester) async {
        final root = _setupIsolatedSupportDir();
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final romFile = File('${root.path}/roms/psp/game.iso')
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(4096, 1));
        final saveFile = File('${root.path}/saves/game_slot0.state')
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(204800, 2));
        final coverFile = File('${root.path}/covers/999.png')
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(102400, 3));

        final downloadService = RomDownloadService();
        addTearDown(downloadService.dispose);
        final emulatorService = EmulatorService();
        addTearDown(emulatorService.dispose);

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            supportedLocales: const [Locale('pt', 'BR'), Locale('en')],
            home: SettingsScreen(
              settings: const AppSettings(),
              downloadService: downloadService,
              onSettingsChanged: (_) {},
              emulatorService: emulatorService,
            ),
          ),
        );
        await tester.pumpAndSettle();

        final cleanCacheFinder = find.textContaining('Limpar cache e .part');
        final anyCleanSavesFinder = find.textContaining('Limpar capas e saves');
        await tester.scrollUntilVisible(
          anyCleanSavesFinder,
          300.0,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();

        final cleanSavesFinder = find.textContaining('Limpar capas e saves (');
        for (int i = 0; i < 250 && cleanSavesFinder.evaluate().isEmpty; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(cleanCacheFinder, findsOneWidget);
        expect(cleanSavesFinder, findsOneWidget);
        expect(
          tester.getTopLeft(cleanSavesFinder).dy,
          greaterThan(tester.getBottomLeft(cleanCacheFinder).dy),
        );

        await tester.ensureVisible(cleanSavesFinder);
        await tester.tap(cleanSavesFinder);
        await tester.pumpAndSettle();
        expect(find.text('Limpar capas e saves?'), findsOneWidget);

        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Limpar tudo'),
          ),
        );
        for (int i = 0;
            i < 250 &&
                (saveFile.existsSync() ||
                    coverFile.existsSync() ||
                    find
                        .text('Limpando capas e saves...')
                        .evaluate()
                        .isNotEmpty);
            i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 2)),
          );
          await tester.pump();
        }
        await tester.pumpAndSettle();

        expect(saveFile.existsSync(), isFalse);
        expect(coverFile.existsSync(), isFalse);
        expect(romFile.existsSync(), isTrue);
      },
    );
  });

  group('PS3 stability, distinct button styles & controller visibility', () {
    test(
      'AppSettings uses safe RPCS3 core options and serializes independent per-element button styles',
      () {
        const defaults = AppSettings();
        final opts = defaults.libretroCoreOptions;
        expect(opts['rpcs3_database_override'], 'disabled');
        expect(opts['rpcs3_llvm_threads'], '2');
        expect(opts['rpcs3_shader_compiler_threads'], '1');
        expect(opts['rpcs3_shader_mode'], 'async');
        expect(opts['rpcs3_spu_verification'], 'enabled');
        expect(opts['rpcs3_async_texture_streaming'], 'disabled');
        expect(opts['rpcs3_hle_lwmutex'], 'disabled');
        expect(opts['rpcs3_driver_wakeup_delay'], '0');
        expect(opts['rpcs3_driver_recovery_timeout'], '1000');
        expect(opts['rpcs3_sleep_timers_accuracy'], 'auto');

        expect(defaults.effectiveDpadStyle, GamepadButtonStyle.gamehubGlass);
        expect(defaults.effectiveActionStyle, GamepadButtonStyle.gamehubGlass);

        final custom = defaults.copyWith(
          buttonStyle: GamepadButtonStyle.playstation,
          dpadButtonStyle: GamepadButtonStyle.minimalOutline,
          actionButtonStyle: GamepadButtonStyle.gamehubGlass,
          shoulderButtonStyle: GamepadButtonStyle.xboxAbxy,
          stickButtonStyle: GamepadButtonStyle.minimalOutline,
          selectStartButtonStyle: GamepadButtonStyle.xboxAbxy,
        );
        expect(custom.effectiveDpadStyle, GamepadButtonStyle.minimalOutline);
        expect(custom.effectiveActionStyle, GamepadButtonStyle.gamehubGlass);
        expect(custom.effectiveShoulderStyle, GamepadButtonStyle.xboxAbxy);
        expect(custom.effectiveStickStyle, GamepadButtonStyle.minimalOutline);
        expect(
          custom.effectiveSelectStartStyle,
          GamepadButtonStyle.xboxAbxy,
        );

        final roundtrip = AppSettings.fromJson(custom.toJson());
        expect(roundtrip.buttonStyle, GamepadButtonStyle.playstation);
        expect(roundtrip.dpadButtonStyle, GamepadButtonStyle.minimalOutline);
        expect(roundtrip.actionButtonStyle, GamepadButtonStyle.gamehubGlass);
        expect(roundtrip.shoulderButtonStyle, GamepadButtonStyle.xboxAbxy);
        expect(roundtrip.stickButtonStyle, GamepadButtonStyle.minimalOutline);
        expect(
          roundtrip.selectStartButtonStyle,
          GamepadButtonStyle.xboxAbxy,
        );

        final reset = roundtrip.resetGamepadLayout();
        expect(reset.dpadButtonStyle, isNull);
        expect(reset.actionButtonStyle, isNull);
        expect(reset.effectiveDpadStyle, GamepadButtonStyle.gamehubGlass);
      },
    );

    testWidgets(
      'Landscape Home top bar shows gamepad icon strictly when connected and hides when disconnected',
      (WidgetTester tester) async {
        _setupIsolatedSupportDir();
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        MockStreamHandlerEventSink? eventSink;
        const eventsChannel = EventChannel('org.loopgamer.libretro/events');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
          eventsChannel,
          MockStreamHandler.inline(
            onListen: (args, sink) {
              eventSink = sink;
            },
            onCancel: (args) {
              eventSink = null;
            },
          ),
        );
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockStreamHandler(eventsChannel, null);
        });

        final emulatorService = EmulatorService();
        addTearDown(emulatorService.dispose);

        await tester.pumpWidget(LoopGamerApp(emulatorService: emulatorService));
        await tester.pump();

        expect(find.bySemanticsLabel('Controle físico ativo'), findsNothing);

        // UI navigation events without physical connection must not force the icon on.
        eventSink?.success(<String, dynamic>{
          'event': 'gamepadUiAction',
          'action': 'r1',
        });
        await tester.pump();
        expect(find.bySemanticsLabel('Controle físico ativo'), findsNothing);

        // Connecting physical controller reveals the indicator on landscape home.
        eventSink?.success(<String, dynamic>{
          'event': 'hardwareGamepadState',
          'connected': true,
        });
        await tester.pump();
        expect(find.bySemanticsLabel('Controle físico ativo'), findsOneWidget);

        // Disconnecting hides it immediately.
        eventSink?.success(<String, dynamic>{
          'event': 'hardwareGamepadState',
          'connected': false,
        });
        await tester.pump();
        expect(find.bySemanticsLabel('Controle físico ativo'), findsNothing);
      },
    );

    testWidgets(
      'LibretroPlayerScreen hides on-screen buttons on controller use and keeps distinct GameHub Glass / Minimalista / per-element styles',
      (WidgetTester tester) async {
        final root = _setupIsolatedSupportDir();
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final coresDir = Directory('${root.path}/libretro_cores')
          ..createSync(recursive: true);
        final coreBytes = Uint8List(32 * 1024)
          ..[0] = 0x7F
          ..[1] = 0x45
          ..[2] = 0x4C
          ..[3] = 0x46;
        File('${coresDir.path}/mgba_libretro_android.so')
            .writeAsBytesSync(coreBytes, flush: true);

        MockStreamHandlerEventSink? eventSink;
        const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
        const eventsChannel = EventChannel('org.loopgamer.libretro/events');

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodsChannel, (call) async {
          if (call.method == 'startLibretroSession') return 1;
          return null;
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockStreamHandler(
          eventsChannel,
          MockStreamHandler.inline(
            onListen: (args, sink) {
              eventSink = sink;
            },
            onCancel: (args) {
              eventSink = null;
            },
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

        final savedUpdates = <AppSettings>[];
        final game = _testGame(
          id: 9912,
          name: 'Castlevania',
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
            home: LibretroPlayerScreen(
              game: game,
              romPath: '${root.path}/aria.gba',
              emulatorService: emulatorService,
              initialSettings: const AppSettings(
                buttonStyle: GamepadButtonStyle.playstation,
                actionButtonStyle: GamepadButtonStyle.gamehubGlass,
                dpadButtonStyle: GamepadButtonStyle.minimalOutline,
              ),
              onSettingsChanged: savedUpdates.add,
            ),
          ),
        );
        for (int i = 0; i < 6; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }

        // Actions uses GameHub Glass (A B X Y squircle labels), NOT PlayStation icons.
        expect(find.bySemanticsLabel('Botão Y'), findsOneWidget);
        expect(find.bySemanticsLabel('Botão Triângulo'), findsNothing);

        final yFinder = find.bySemanticsLabel('Botão Y');
        final yContainer = tester.widget<AnimatedContainer>(
          find.descendant(of: yFinder, matching: find.byType(AnimatedContainer)),
        );
        final yDeco = yContainer.decoration! as BoxDecoration;
        expect(yDeco.shape, BoxShape.rectangle);
        expect(yDeco.borderRadius, BorderRadius.circular(15.0));

        // D-Pad uses Minimalista (transparent circle wireframe), untouched by Actions.
        final dpadUpFinder = find.bySemanticsLabel('Direcional Cima');
        final dpadContainer = tester.widget<AnimatedContainer>(
          find.descendant(
            of: dpadUpFinder,
            matching: find.byType(AnimatedContainer),
          ),
        );
        final dpadDeco = dpadContainer.decoration! as BoxDecoration;
        expect(dpadDeco.shape, BoxShape.circle);
        expect(dpadDeco.color, Colors.transparent);

        Future<void> pumpUntilFound(Finder finder) async {
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 25));
            if (finder.evaluate().isNotEmpty) return;
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
          }
          await tester.pump();
        }

        // Changing ONLY Actions style in editor does NOT alter D-Pad or global fallback.
        await tester.tap(find.byTooltip('Abrir menu do jogo'));
        await pumpUntilFound(find.text('Gamepad'));
        await tester.tap(find.text('Gamepad'));
        await tester.pump(const Duration(milliseconds: 200));
        await tester.tap(find.text('Mover e Editar Botões na Tela'));
        await tester.pump(const Duration(milliseconds: 250));
        await tester.tap(find.text('Botões Ação (A B X Y)'));
        await tester.pump(const Duration(milliseconds: 300));
        final xboxOption = find.text('Xbox ABXY');
        await tester.ensureVisible(xboxOption);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(xboxOption);
        await tester.pump(const Duration(milliseconds: 200));
        final doneSheetButton = find.text('Pronto');
        await tester.ensureVisible(doneSheetButton);
        await tester.pump(const Duration(milliseconds: 150));
        await tester.tap(doneSheetButton);
        await tester.pump(const Duration(milliseconds: 300));

        expect(savedUpdates, isNotEmpty);
        final afterActionChange = savedUpdates.last;
        expect(afterActionChange.actionButtonStyle, GamepadButtonStyle.xboxAbxy);
        expect(
          afterActionChange.dpadButtonStyle,
          GamepadButtonStyle.minimalOutline,
        );
        expect(afterActionChange.buttonStyle, GamepadButtonStyle.playstation);

        // Actions switched to Xbox circular bold buttons, while D-Pad stayed Minimalista.
        final updatedYContainer = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.bySemanticsLabel('Botão Y'),
            matching: find.byType(AnimatedContainer),
          ),
        );
        expect(
          (updatedYContainer.decoration! as BoxDecoration).shape,
          BoxShape.circle,
        );
        final updatedDpadContainer = tester.widget<AnimatedContainer>(
          find.descendant(
            of: find.bySemanticsLabel('Direcional Cima'),
            matching: find.byType(AnimatedContainer),
          ),
        );
        expect(
          (updatedDpadContainer.decoration! as BoxDecoration).color,
          Colors.transparent,
        );

        // Exit layout editor and resume gameplay so auto-hide triggers normally.
        await tester.tap(find.text('Concluir'));
        await pumpUntilFound(find.text('Continuar'));
        await tester.tap(find.text('Continuar'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.bySemanticsLabel('Botão Y'), findsOneWidget);

        // Advance past the edit-mode toast timer cleanly before exiting test.
        await tester.pump(const Duration(seconds: 3));

        // Physical controller activity immediately hides on-screen buttons.
        eventSink?.success(<String, dynamic>{'event': 'hardwareGamepadActive'});
        await tester.pump();
        expect(find.bySemanticsLabel('Botão Y'), findsNothing);

        // Touching gameplay area brings them back, and using controller hides again.
        await tester.tapAt(const Offset(450, 220));
        await tester.pump();
        expect(find.bySemanticsLabel('Botão Y'), findsOneWidget);

        eventSink?.success(<String, dynamic>{'event': 'hardwareGamepadActive'});
        await tester.pump();
        expect(find.bySemanticsLabel('Botão Y'), findsNothing);
      },
    );
  });
}
