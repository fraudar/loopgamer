import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/screens/settings_screen.dart';
import 'package:loopgamer/services/igdb_steamgriddb_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';

void main() {
  group('RomDownloadService validation & Archive selection', () {
    test('rejects junk Archive entries such as _jp2.zip, images, manuals and patches', () {
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'Castlevania - Symphony of the Night (USA)_jp2.zip',
          gameTitle: 'Castlevania: Symphony of the Night',
        ),
        isTrue,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'Crash Bandicoot 2_images.zip',
          gameTitle: 'Crash Bandicoot 2',
        ),
        isTrue,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'manual.pdf',
          gameTitle: 'Castlevania: Aria of Sorrow',
        ),
        isTrue,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'game.sbi',
          gameTitle: 'Crash Bandicoot 2',
        ),
        isTrue,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'patch.ips',
          gameTitle: 'Castlevania: Aria of Sorrow',
        ),
        isTrue,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'Castlevania - Symphony of the Night (USA).chd',
          gameTitle: 'Castlevania: Symphony of the Night',
        ),
        isFalse,
      );
      expect(
        RomDownloadService.isJunkArchiveEntry(
          'Castlevania - Aria of Sorrow (USA).gba',
          gameTitle: 'Castlevania: Aria of Sorrow',
        ),
        isFalse,
      );
    });

    test('enforces platform minimum sizes and allowed extensions', () {
      expect(RomDownloadService.minBytesForPlatform('ps1'), greaterThan(1024 * 1024));
      expect(RomDownloadService.minBytesForPlatform('gba'), greaterThan(64 * 1024));

      final ps1Exts = RomDownloadService.allowedExtensionsForPlatform('ps1');
      expect(ps1Exts, containsAll(<String>['.chd', '.pbp', '.iso', '.zip']));

      final gbaExts = RomDownloadService.allowedExtensionsForPlatform('gba');
      expect(gbaExts, contains('.gba'));
    });

    test('pickBestArchiveFile skips junk/tiny entries and picks playable ROMs', () {
      final ps1Files = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Castlevania - Symphony of the Night (USA)_jp2.zip',
          'size': '150000000',
        },
        <String, dynamic>{
          'name': 'Castlevania - Symphony of the Night (Japan).zip',
          'size': '380000000',
        },
        <String, dynamic>{
          'name': 'Castlevania - Symphony of the Night (USA).chd',
          'size': '360000000',
        },
        <String, dynamic>{
          'name': 'Castlevania - Symphony of the Night (Manual).pdf',
          'size': '12000000',
        },
      ];
      expect(
        RomDownloadService.pickBestArchiveFile(
          files: ps1Files,
          platformSlug: 'ps1',
          gameTitle: 'Castlevania: Symphony of the Night',
        ),
        'Castlevania - Symphony of the Night (USA).chd',
      );

      final crashFiles = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Crash Bandicoot (USA).chd',
          'size': '250000000',
        },
        <String, dynamic>{
          'name': 'Crash Bandicoot 2 - Cortex Strikes Back (USA) (Tiny Patch).zip',
          'size': '180000',
        },
        <String, dynamic>{
          'name': 'Crash Bandicoot 2 - Cortex Strikes Back (USA).zip',
          'size': '290000000',
        },
      ];
      expect(
        RomDownloadService.pickBestArchiveFile(
          files: crashFiles,
          platformSlug: 'ps1',
          gameTitle: 'Crash Bandicoot 2: Cortex Strikes Back',
        ),
        'Crash Bandicoot 2 - Cortex Strikes Back (USA).zip',
      );

      final gbaFiles = <Map<String, dynamic>>[
        <String, dynamic>{
          'name': 'Castlevania - Aria of Sorrow (USA)_jp2.zip',
          'size': '9000000',
        },
        <String, dynamic>{
          'name': 'Castlevania - Aria of Sorrow (USA).gba',
          'size': '8388608',
        },
      ];
      expect(
        RomDownloadService.pickBestArchiveFile(
          files: gbaFiles,
          platformSlug: 'gba',
          gameTitle: 'Castlevania: Aria of Sorrow',
        ),
        'Castlevania - Aria of Sorrow (USA).gba',
      );
    });

    test('extractAndPickRomFromZip extracts multi-file .cue + .bin and rejects junk zips', () async {
      final tempRoot = await Directory.systemTemp.createTemp('loopgamer_zip_test_');
      addTearDown(() async {
        if (await tempRoot.exists()) {
          await tempRoot.delete(recursive: true);
        }
      });

      // 1. Multi-file CUE + BIN ZIP (using size safely above minBytesForPlatform('ps1'))
      final ps1Min = RomDownloadService.minBytesForPlatform('ps1');
      final binSize = ps1Min + 4096;
      expect(binSize, lessThanOrEqualTo(64 * 1024 * 1024));

      final ps1Archive = Archive()
        ..addFile(
          ArchiveFile(
            'Crash 2 (USA).cue',
            64,
            Uint8List.fromList('FILE "Crash 2 (USA).bin" BINARY\n  TRACK 01 MODE2/2352\n'.codeUnits),
          ),
        )
        ..addFile(
          ArchiveFile(
            'Crash 2 (USA).bin',
            binSize,
            Uint8List(binSize),
          ),
        );
      final ps1ZipPath = '${tempRoot.path}/crash2.zip';
      final ps1ZipBytes = ZipEncoder().encode(ps1Archive)!;
      await File(ps1ZipPath).writeAsBytes(ps1ZipBytes, flush: true);

      final extractDir = Directory('${tempRoot.path}/game_1184');
      final pickedPs1 = await RomDownloadService.extractAndPickRomFromZip(
        zipPath: ps1ZipPath,
        extractDir: extractDir,
        platformSlug: 'ps1',
      );
      expect(pickedPs1, isNotNull);
      expect(pickedPs1!.toLowerCase(), endsWith('.cue'));
      expect(await File('${extractDir.path}/Crash 2 (USA).bin').exists(), isTrue);

      // 2. GBA valid ROM inside ZIP
      final gbaMin = RomDownloadService.minBytesForPlatform('gba');
      final gbaSize = gbaMin + 1024;
      final gbaArchive = Archive()
        ..addFile(
          ArchiveFile(
            'Aria of Sorrow (USA).gba',
            gbaSize,
            Uint8List(gbaSize),
          ),
        );
      final gbaZipPath = '${tempRoot.path}/aria.zip';
      await File(gbaZipPath).writeAsBytes(ZipEncoder().encode(gbaArchive)!, flush: true);

      final pickedGba = await RomDownloadService.extractAndPickRomFromZip(
        zipPath: gbaZipPath,
        extractDir: Directory('${tempRoot.path}/game_1126'),
        platformSlug: 'gba',
      );
      expect(pickedGba, isNotNull);
      expect(pickedGba!.toLowerCase(), endsWith('.gba'));

      // 3. Junk zip containing only .jp2 / tiny txt files must return null
      final junkArchive = Archive()
        ..addFile(
          ArchiveFile('scan_0001.jp2', 2048, Uint8List(2048)),
        )
        ..addFile(
          ArchiveFile('tiny.gba', 128, Uint8List(128)),
        );
      final junkZipPath = '${tempRoot.path}/junk_jp2.zip';
      await File(junkZipPath).writeAsBytes(ZipEncoder().encode(junkArchive)!, flush: true);

      final pickedJunk = await RomDownloadService.extractAndPickRomFromZip(
        zipPath: junkZipPath,
        extractDir: Directory('${tempRoot.path}/game_junk'),
        platformSlug: 'gba',
      );
      expect(pickedJunk, isNull);
    });

    test('pickPreferredExtractedRom prefers .cue over .bin and respects platform', () {
      final picked = RomDownloadService.pickPreferredExtractedRom(
        const <String>[
          '/roms/game_1184/Crash 2 (Track 2).bin',
          '/roms/game_1184/Crash 2 (Track 1).bin',
          '/roms/game_1184/Crash 2.cue',
        ],
        platformSlug: 'ps1',
      );
      expect(picked, '/roms/game_1184/Crash 2.cue');
    });
  });

  group('Catalog & AppSettings regressions', () {
    test('kVerifiedRealGamesCatalog contains PS1/GBA targets and zero external Switch stubs', () {
      final ids = kVerifiedRealGamesCatalog.map((g) => g.igdbId).toSet();
      expect(ids, containsAll(<int>[1120, 1184, 1126]));

      for (final game in kVerifiedRealGamesCatalog) {
        expect(game.platformSlug.toLowerCase(), isNot('switch'));
        expect(game.directRomUrl.toLowerCase(), isNot(startsWith('external://switch')));
      }
    });

    test('deduplicateCatalog removes duplicate entries in O(N)', () {
      const a = EmulationGame(
        igdbId: 1120,
        name: 'Castlevania: Symphony of the Night',
        canonicalNoIntroName: 'Castlevania - Symphony of the Night (USA)',
        summary: 'Action RPG',
        genres: <String>['RPG'],
        developer: 'Konami',
        releaseYear: 1997,
        rating: 95.0,
        platformName: 'PlayStation',
        platformSlug: 'ps1',
        directRomUrl: 'https://example.com/sotn.chd',
      );
      const dupSameId = EmulationGame(
        igdbId: 1120,
        name: 'Castlevania: Symphony of the Night',
        canonicalNoIntroName: 'Castlevania - Symphony of the Night (USA)',
        summary: 'Action RPG',
        genres: <String>['RPG'],
        developer: 'Konami',
        releaseYear: 1997,
        rating: 95.0,
        platformName: 'PlayStation',
        platformSlug: 'ps1',
        directRomUrl: 'https://example.com/sotn2.chd',
      );
      const b = EmulationGame(
        igdbId: 1184,
        name: 'Crash Bandicoot 2: Cortex Strikes Back',
        canonicalNoIntroName: 'Crash Bandicoot 2 - Cortex Strikes Back (USA)',
        summary: 'Platformer',
        genres: <String>['Platform'],
        developer: 'Naughty Dog',
        releaseYear: 1997,
        rating: 90.0,
        platformName: 'PlayStation',
        platformSlug: 'ps1',
        directRomUrl: 'https://example.com/crash2.chd',
      );

      final deduped = IgdbSteamGridService.deduplicateCatalog(
        const <EmulationGame>[a, dupSameId, b],
      );
      expect(deduped.length, 2);
      expect(deduped.map((g) => g.igdbId), containsAllInOrder(<int>[1120, 1184]));
    });

    test('AppSettings serializes and deserializes TurnipFreedrenoPreset', () {
      for (final preset in TurnipFreedrenoPreset.values) {
        final settings = AppSettings(freedrenoPreset: preset);
        final roundTrip = AppSettings.fromJson(settings.toJson());
        expect(roundTrip.freedrenoPreset, preset);
        expect(roundTrip.copyWith().freedrenoPreset, preset);
      }
    });

    test('AppSettings single-trigger shoulder adaptation works per console and override', () {
      expect(AppSettings.isSingleTriggerPlatform('psp'), isTrue);
      expect(AppSettings.isSingleTriggerPlatform('gba'), isTrue);
      expect(AppSettings.isSingleTriggerPlatform('snes'), isTrue);
      expect(AppSettings.isSingleTriggerPlatform('nds'), isTrue);
      expect(AppSettings.isSingleTriggerPlatform('ps1'), isFalse);
      expect(AppSettings.isSingleTriggerPlatform('n64'), isFalse);

      const defaultSettings = AppSettings();
      expect(defaultSettings.shouldUseSingleTriggers('psp'), isTrue);
      expect(defaultSettings.shouldUseSingleTriggers('ps1'), isFalse);

      final forcedSingle = AppSettings.fromJson(
        const AppSettings(shoulderStyle: ShoulderTriggerStyle.singleLR).toJson(),
      );
      expect(forcedSingle.shoulderStyle, ShoulderTriggerStyle.singleLR);
      expect(forcedSingle.shouldUseSingleTriggers('ps1'), isTrue);
    });

    testWidgets(
      'SettingsScreen groups Firmware inside Drivers section and uses select menus',
      timeout: const Timeout(Duration(seconds: 15)),
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(412, 915);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final tempDir = Directory.systemTemp.createTempSync('loopgamer_settings_test_');
        const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProviderChannel, (call) async => tempDir.path);
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(pathProviderChannel, null);
          if (tempDir.existsSync()) {
            tempDir.deleteSync(recursive: true);
          }
        });

        AppSettings current = const AppSettings();
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (ctx, setState) => SettingsScreen(
                settings: current,
                downloadService: RomDownloadService(),
                onSettingsChanged: (next) => setState(() => current = next),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 200));

        expect(find.byType(DropdownButton<TouchOverlayMode>), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);

        // Changing TouchOverlayMode via the select menu updates AppSettings
        final overlayDropdown = find.byType(DropdownButton<TouchOverlayMode>);
        await tester.ensureVisible(overlayDropdown);
        await tester.pump(const Duration(milliseconds: 100));
        await tester.tap(overlayDropdown);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text(TouchOverlayMode.alwaysShow.label).last);
        await tester.pump(const Duration(milliseconds: 300));
        expect(current.touchOverlayMode, TouchOverlayMode.alwaysShow);

        // Firmware PS3 must live in the same section as Drivers & Freedreno select menu
        final listFinder = find.byType(Scrollable).first;
        final firmwareText = find.text('Firmware PS3 (PS3UPDAT.PUP)');
        await tester.scrollUntilVisible(
          firmwareText,
          250,
          scrollable: listFinder,
        );
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.text('Drivers, Firmware & Adreno Turnip'), findsOneWidget);
        expect(find.text('Driver Vulkan Customizado (Turnip)'), findsOneWidget);
        expect(firmwareText, findsOneWidget);
        expect(find.byType(DropdownButton<TurnipFreedrenoPreset>), findsOneWidget);
        expect(find.byType(ChoiceChip), findsNothing);
      },
    );
  });
}
