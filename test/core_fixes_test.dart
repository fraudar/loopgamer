import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/screens/settings_screen.dart';
import 'package:loopgamer/services/igdb_steamgriddb_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';

typedef _RouteResponder = ResponseBody Function(RequestOptions options);

class _FakeHttpAdapter implements HttpClientAdapter {
  _FakeHttpAdapter(this._responder);

  final _RouteResponder _responder;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return _responder(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _jsonBody(Object data, {int statusCode = 200}) {
  return ResponseBody.fromString(
    jsonEncode(data),
    statusCode,
    headers: {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );
}

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

  group('Game Size & Search Accuracy regressions', () {
    setUp(IgdbSteamGridService.clearCacheForTesting);
    tearDown(IgdbSteamGridService.clearCacheForTesting);

    test('formattedSize never emits fake 4.2 MB when estimatedSizeBytes <= 0', () {
      const unknownGame = EmulationGame(
        igdbId: 1,
        name: 'Castlevania: Lords of Shadow',
        canonicalNoIntroName: 'Castlevania: Lords of Shadow (USA)',
        summary: 'Action adventure',
        genres: ['Action'],
        developer: 'Konami',
        releaseYear: 2010,
        rating: 88,
        platformName: 'PS3',
        platformSlug: 'ps3',
        directRomUrl: 'retroapi://ps3/Castlevania.iso',
        estimatedSizeBytes: 0,
      );
      expect(unknownGame.hasKnownSize, isFalse);
      expect(unknownGame.formattedSize, 'Tam. n/d');

      const gigGame = EmulationGame(
        igdbId: 2,
        name: 'Naruto Shippuden: Kizuna Drive',
        canonicalNoIntroName: 'Naruto Shippuden - Kizuna Drive (USA)',
        summary: 'Action',
        genres: ['Action'],
        developer: 'Bandai Namco',
        releaseYear: 2011,
        rating: 86,
        platformName: 'PSP',
        platformSlug: 'psp',
        directRomUrl: 'retroapi://psp/Naruto.iso',
        estimatedSizeBytes: 1177255936,
      );
      expect(gigGame.hasKnownSize, isTrue);
      expect(gigGame.formattedSize, '1.10 GB');
    });

    test('RetroAPI prefers valid size over .cue null, keeps >800 titles, and omits fake 4.0 MB default', () async {
      final ps2Filler = List<Map<String, dynamic>>.generate(
        850,
        (i) => {
          'name': 'Filler Game $i (USA)',
          'rom_name': 'Filler Game $i (USA).iso',
          'size': 1500000000,
        },
      );
      final dio = Dio();
      dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final uri = options.uri.toString();
        if (uri.contains('/api/psp/')) {
          return _jsonBody([
            [
              {
                'name': 'Naruto Shippuden - Kizuna Drive (USA) (En,Fr,Es)',
                'rom_name':
                    'Naruto Shippuden - Kizuna Drive (USA) (En,Fr,Es).iso',
                'size': 1177255936,
              },
            ],
          ]);
        }
        if (uri.contains('/api/ps2/')) {
          return _jsonBody([
            ps2Filler,
            [
              {
                'name': 'Castlevania - Lament of Innocence (USA)',
                'rom_name': 'Castlevania - Lament of Innocence (USA).cue',
                'size': null,
              },
              {
                'name': 'Castlevania - Lament of Innocence (USA)',
                'rom_name': 'Castlevania - Lament of Innocence (USA).iso',
                'size': 3027009536,
              },
              {
                'name': 'Castlevania (Korea) (En,Ko)',
                'rom_name': 'Castlevania (Korea) (En,Ko).iso',
                'size': 3082682368,
              },
            ],
          ]);
        }
        if (uri.contains('/api/gamecube/')) {
          return _jsonBody([
            [
              {
                'name': 'Naruto Clash of Ninja 2 (USA)',
                'rom_name': 'Naruto Clash of Ninja 2 (USA).iso',
                'size': null,
              },
            ],
          ]);
        }
        return _jsonBody({'response': {'docs': []}});
      });

      final service = IgdbSteamGridService(dio: dio);

      final pspGames = await service.fetchFromRetroApiPlatform('psp');
      expect(pspGames.single.name, 'Naruto Shippuden: Kizuna Drive');
      expect(pspGames.single.formattedSize, '1.10 GB');

      final ps2All = await service.fetchFromRetroApiPlatform(
        'ps2',
        maxPerPlatform: 1000,
      );
      expect(ps2All.length, 852);
      final lament = ps2All.firstWhere(
        (g) => g.name == 'Castlevania: Lament of Innocence',
      );
      expect(lament.estimatedSizeBytes, 3027009536);
      expect(lament.formattedSize, '2.82 GB');

      final castlevaniaPs2 = ps2All.firstWhere((g) => g.name == 'Castlevania');
      expect(castlevaniaPs2.estimatedSizeBytes, 3082682368);
      expect(castlevaniaPs2.formattedSize, '2.87 GB');

      final gcGames = await service.fetchFromRetroApiPlatform('gamecube');
      expect(gcGames.single.estimatedSizeBytes, 0);
      expect(gcGames.single.formattedSize, 'Tam. n/d');

      // Searching without ':' matches RetroAPI PSP title & skips Archive demo
      final searchNaruto = await service.searchGames(
        'naruto shippuden kizuna drive',
        platformFilter: 'PSP',
      );
      expect(searchNaruto, isNotEmpty);
      expect(searchNaruto.first.name, 'Naruto Shippuden: Kizuna Drive');
      expect(searchNaruto.first.formattedSize, '1.10 GB');
    });

    test('searchGames & Archive.org reject demos, updates, APKs, 0-byte ISOs and small cross-console packs', () async {
      final dio = Dio();
      dio.httpClientAdapter = _FakeHttpAdapter((options) {
        final uri = options.uri.toString();
        if (uri.contains('/api/')) {
          return _jsonBody([]);
        }
        if (uri.contains('advancedsearch.php')) {
          final q = options.queryParameters['q']?.toString() ?? '';
          if (q.contains('kizuna')) {
            return _jsonBody({
              'response': {
                'docs': [
                  {
                    'identifier': 'NPEH90049_Demo',
                    'title': 'Naruto Shippuden Kizuna Drive Demo (PSP) (NPEH90049)',
                  },
                ],
              },
            });
          }
          return _jsonBody({
            'response': {
              'docs': [
                {
                  'identifier': 'PS3_NPUB31372_Updates',
                  'title': 'PS3 Game Updates: Castlevania: Lords of Shadow 2',
                },
                {
                  'identifier': 'jp.konami.epjCastlevania2',
                  'title': 'Castlevania Symphony of the Night - Android',
                },
                {
                  'identifier': 'ps2-essential-castlevania-lament-of-innocence',
                  'title': 'PS2 - Castlevania Lament of Innocence',
                },
                {
                  'identifier': 'castlevania-series-ch_202303',
                  'title': 'Castlevania series',
                },
                {
                  'identifier': 'ps2-essential-castlevania-curse-of-darkness',
                  'title': 'PS2 - Castlevania Curse of Darkness',
                },
              ],
            },
          });
        }
        if (uri.endsWith('/metadata/NPEH90049_Demo')) {
          return _jsonBody({
            'files': [
              {'name': 'EBOOT.PBP', 'size': '38056032', 'crc32': 'aaaaaaaa'},
            ],
          });
        }
        if (uri.endsWith('/metadata/PS3_NPUB31372_Updates')) {
          return _jsonBody({
            'files': [
              {
                'name': 'UP0101-NPUB31372_00-CLOS200000000000-A0101-V0100-PE.pkg',
                'size': '24016544',
                'crc32': 'bbbbbbbb',
              },
            ],
          });
        }
        if (uri.endsWith('/metadata/jp.konami.epjCastlevania2')) {
          return _jsonBody({
            'files': [
              {
                'name': 'Castlevania Symphony of the Night/jp.konami.epjCastlevania2.zip',
                'size': '230311071',
                'crc32': 'cccccccc',
              },
            ],
          });
        }
        if (uri.endsWith('/metadata/ps2-essential-castlevania-lament-of-innocence')) {
          return _jsonBody({
            'files': [
              {
                'name': 'Castlevania_Lament_of_Innocence.iso',
                'size': '0',
                'crc32': '00000000',
              },
            ],
          });
        }
        if (uri.endsWith('/metadata/castlevania-series-ch_202303')) {
          return _jsonBody({
            'files': [
              {
                'name': '[Castlevania Aria of Sorrow][GBA].zip',
                'size': '8648283',
                'crc32': 'dddddddd',
              },
            ],
          });
        }
        if (uri.endsWith('/metadata/ps2-essential-castlevania-curse-of-darkness')) {
          return _jsonBody({
            'files': [
              {
                'name': 'Castlevania Curse of Darkness (OST).zip',
                'size': '8500000',
                'crc32': '11111111',
              },
              {
                'name': 'Castlevania_Curse_of_Darkness.iso',
                'size': '3522396160',
                'crc32': '22222222',
              },
            ],
          });
        }
        return _jsonBody({});
      });

      final service = IgdbSteamGridService(dio: dio);

      // 36 MB PSP Demo must be filtered out completely
      final narutoArchiveOnly = await service.searchGames(
        'naruto shippuden kizuna drive',
        platformFilter: 'PSP',
      );
      expect(narutoArchiveOnly, isEmpty);

      // Filtering PS2 Castlevania must ignore updates, Android, 0-byte ISO, 8 MB GBA pack & 8 MB OST
      final ps2Castlevania = await service.searchGames(
        'castlevania',
        platformFilter: 'PS2',
      );
      expect(ps2Castlevania.length, 1);
      expect(ps2Castlevania.single.name, 'PS2 - Castlevania Curse of Darkness');
      expect(ps2Castlevania.single.estimatedSizeBytes, 3522396160);
      expect(ps2Castlevania.single.formattedSize, '3.28 GB');
    });
  });
}
