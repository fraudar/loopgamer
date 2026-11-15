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
      expect(flashDir.existsSync(), isFalse);
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
}
