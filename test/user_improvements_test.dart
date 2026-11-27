import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/services/cover_cache_service.dart';
import 'package:loopgamer/services/diagnostic_log_service.dart';
import 'package:loopgamer/services/game_asset_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/services/rom_platform_detector.dart';
import 'package:loopgamer/widgets/procedural_cover.dart';
import 'test_temp_utils.dart';

Directory _setupMockEnvironment({bool Function()? isConnected}) {
  final tempDir =
      Directory.systemTemp.createTempSync('loopgamer_user_improvements_');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  messenger.setMockMethodCallHandler(
    pathProviderChannel,
    (call) async => tempDir.path,
  );
  messenger.setMockMethodCallHandler(methodsChannel, (call) async {
    if (call.method == 'requestNotificationPermission') return true;
    if (call.method == 'syncDownloadNotification') return true;
    if (call.method == 'getNetworkStatus') {
      final online = isConnected?.call() ?? true;
      return <String, dynamic>{'connected': online, 'wifi': online};
    }
    return null;
  });

  addTearDown(() {
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(methodsChannel, null);
    if (tempDir.existsSync()) {
      deleteTempDirQuietly(tempDir);
    }
  });

  return tempDir;
}

String _coverUrlHash(String url) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < url.length; i++) {
    hash ^= url.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return '${hash.toRadixString(16)}.img';
}

Uint8List _buildParamSfo({
  required String title,
  required String titleId,
}) {
  final keys = <int>[
    ...utf8.encode('TITLE\x00'),
    ...utf8.encode('TITLE_ID\x00'),
  ];
  const titleOffsetInKeys = 0;
  const titleIdOffsetInKeys = 'TITLE\x00'.length;

  final titleBytes = <int>[...utf8.encode(title), 0];
  final titleIdBytes = <int>[...utf8.encode(titleId), 0];
  final data = <int>[...titleBytes, ...titleIdBytes];

  const headerLen = 20;
  const entryCount = 2;
  const indexLen = entryCount * 16;
  const keyTableOffset = headerLen + indexLen;
  final dataTableOffset = keyTableOffset + keys.length;

  final bytes = BytesBuilder();
  // Magic: \x00PSF + version 1.1
  bytes.add(const [0x00, 0x50, 0x53, 0x46, 0x01, 0x01, 0x00, 0x00]);
  final bd = ByteData(12)
    ..setUint32(0, keyTableOffset, Endian.little)
    ..setUint32(4, dataTableOffset, Endian.little)
    ..setUint32(8, entryCount, Endian.little);
  bytes.add(bd.buffer.asUint8List());

  void addIndex(int keyOff, int dataLen, int dataOff) {
    final entry = ByteData(16)
      ..setUint16(0, keyOff, Endian.little)
      ..setUint16(2, 0x0204, Endian.little)
      ..setUint32(4, dataLen, Endian.little)
      ..setUint32(8, dataLen, Endian.little)
      ..setUint32(12, dataOff, Endian.little);
    bytes.add(entry.buffer.asUint8List());
  }

  addIndex(titleOffsetInKeys, titleBytes.length, 0);
  addIndex(titleIdOffsetInKeys, titleIdBytes.length, titleBytes.length);
  bytes.add(keys);
  bytes.add(data);
  return bytes.toBytes();
}

Uint8List _buildPs3Iso({required List<int> ebootFirstFourBytes}) {
  const totalLen = 128 * 1024;
  final iso = Uint8List(totalLen);

  // Marcador PS3 dentro dos primeiros setores
  final discMarker = ascii.encode('PLAYSTATION3 PS3_DISC.SFB PS3_GAME');
  iso.setRange(32768, 32768 + discMarker.length, discMarker);

  // Registro ISO9660 para EBOOT.BIN;1 no offset recStart = 4096 apontando para LBA 20
  const recStart = 4096;
  const ebootLba = 20;
  const ebootSize = 1024;
  final nameBytes = ascii.encode('EBOOT.BIN;1');
  final bd = ByteData.sublistView(iso);
  iso[recStart] = 34 + nameBytes.length;
  bd.setUint32(recStart + 2, ebootLba, Endian.little);
  bd.setUint32(recStart + 10, ebootSize, Endian.little);
  iso[recStart + 32] = nameBytes.length;
  iso.setRange(recStart + 33, recStart + 33 + nameBytes.length, nameBytes);

  // Conteúdo do EBOOT no setor LBA 20 (offset 20 * 2048 = 40960)
  iso.setRange(
    ebootLba * 2048,
    ebootLba * 2048 + ebootFirstFourBytes.length,
    ebootFirstFourBytes,
  );
  return iso;
}

/// Gera um arquivo `.7z` mínimo válido usando o codec Copy (0x00) para
/// exercitar o extrator `.7z` em Dart puro dentro do `Isolate`.
Uint8List _buildMinimalCopy7z({
  required String fileName,
  required Uint8List payload,
}) {
  assert(payload.length == 8192, 'Codificação [0xA0, 0x00] espera 8192 bytes');

  final header = BytesBuilder();
  header.addByte(0x01); // kHeader
  header.addByte(0x04); // kMainStreamsInfo

  // PackInfo (0x06)
  header.addByte(0x06);
  header.addByte(0x00); // packPos = 0
  header.addByte(0x01); // numPackStreams = 1
  header.addByte(0x09); // kSize
  header.add(const [0xA0, 0x00]); // packSize = 8192
  header.addByte(0x00); // kEnd PackInfo

  // UnpackInfo (0x07)
  header.addByte(0x07);
  header.addByte(0x0B); // kFolder
  header.addByte(0x01); // numFolders = 1
  header.addByte(0x00); // external = 0
  header.addByte(0x01); // numCoders = 1
  header.addByte(0x01); // flags: idSize=1, simple, sem attrs
  header.addByte(0x00); // codec Copy (0x00)
  header.addByte(0x0C); // kCodersUnpackSize
  header.add(const [0xA0, 0x00]); // unpackSize = 8192
  header.addByte(0x00); // kEnd UnpackInfo

  header.addByte(0x00); // kEnd MainStreamsInfo

  // FilesInfo (0x05)
  header.addByte(0x05);
  header.addByte(0x01); // numFiles = 1
  header.addByte(0x11); // kName
  final utf16Name = BytesBuilder()..addByte(0x00); // external = 0
  for (final unit in fileName.codeUnits) {
    utf16Name.addByte(unit & 0xFF);
    utf16Name.addByte((unit >> 8) & 0xFF);
  }
  utf16Name.add(const [0x00, 0x00]);
  final namePropBytes = utf16Name.toBytes();
  assert(namePropBytes.length < 128);
  header.addByte(namePropBytes.length);
  header.add(namePropBytes);
  header.addByte(0x00); // kEnd FilesInfo

  header.addByte(0x00); // kEnd Header
  final headerBytes = header.toBytes();

  final sigHdr = Uint8List(32);
  sigHdr.setRange(0, 8, const [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x04]);
  final bd = ByteData.sublistView(sigHdr);
  bd.setUint64(12, payload.length, Endian.little);
  bd.setUint64(20, headerBytes.length, Endian.little);

  return (BytesBuilder()
        ..add(sigHdr)
        ..add(payload)
        ..add(headerBytes))
      .toBytes();
}

Uint8List _buildValidPngOver100Bytes() {
  const width = 16;
  const height = 16;
  final rawScanlines = BytesBuilder();
  for (var y = 0; y < height; y++) {
    rawScanlines.addByte(0); // filter type 0
    for (var x = 0; x < width; x++) {
      rawScanlines.add([
        (x * 29 + y * 17) & 0xFF,
        ((x * 13) ^ (y * 41)) & 0xFF,
        (x * 7 + y * 53) & 0xFF,
        0xFF,
      ]);
    }
  }
  final idatData = Uint8List.fromList(
    const ZLibEncoder().encode(rawScanlines.toBytes()),
  );

  Uint8List makeChunk(String type, List<int> data) {
    final typeBytes = ascii.encode(type);
    final crcInput = Uint8List(typeBytes.length + data.length)
      ..setRange(0, typeBytes.length, typeBytes)
      ..setRange(typeBytes.length, typeBytes.length + data.length, data);
    final crc = getCrc32(crcInput);

    final out = BytesBuilder();
    final lenBd = ByteData(4)..setUint32(0, data.length, Endian.big);
    out.add(lenBd.buffer.asUint8List());
    out.add(crcInput);
    final crcBd = ByteData(4)..setUint32(0, crc, Endian.big);
    out.add(crcBd.buffer.asUint8List());
    return out.toBytes();
  }

  final ihdr = ByteData(13)
    ..setUint32(0, width, Endian.big)
    ..setUint32(4, height, Endian.big)
    ..setUint8(8, 8) // bit depth
    ..setUint8(9, 6) // RGBA
    ..setUint8(10, 0)
    ..setUint8(11, 0)
    ..setUint8(12, 0);

  return (BytesBuilder()
        ..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        ..add(makeChunk('IHDR', ihdr.buffer.asUint8List()))
        ..add(makeChunk('IDAT', idatData))
        ..add(makeChunk('IEND', const <int>[])))
      .toBytes();
}

class _OfflineThenSuccessAdapter implements HttpClientAdapter {
  _OfflineThenSuccessAdapter({
    required this.payload,
    required this.isOnline,
    required this.onOfflineAttempt,
  });

  final Uint8List payload;
  final bool Function() isOnline;
  final void Function() onOfflineAttempt;
  int fetchCount = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    fetchCount++;
    if (!isOnline()) {
      onOfflineAttempt();
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'Sem conexão com a internet',
      );
    }

    final rangeHeader = options.headers['Range']?.toString();
    if (rangeHeader != null && rangeHeader.startsWith('bytes=')) {
      final spec = rangeHeader.substring('bytes='.length);
      final parts = spec.split('-');
      final start = int.tryParse(parts[0]) ?? 0;
      final end = parts.length > 1 && parts[1].isNotEmpty
          ? (int.tryParse(parts[1]) ?? payload.length - 1)
          : payload.length - 1;
      final slice = Uint8List.sublistView(
        payload,
        start,
        (end + 1).clamp(0, payload.length),
      );
      return ResponseBody.fromBytes(
        slice,
        206,
        headers: {
          Headers.contentLengthHeader: ['${slice.length}'],
          'content-range': ['bytes $start-$end/${payload.length}'],
        },
      );
    }

    return ResponseBody.fromBytes(
      payload,
      200,
      headers: {
        Headers.contentLengthHeader: ['${payload.length}'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Validação de dumps de PS3', () {
    test(
      'aceita pasta PS3_GAME/USRDIR/EBOOT.BIN válida com PARAM.SFO e detecta PS3',
      () async {
        final tempDir = _setupMockEnvironment();
        final gameDir = Directory('${tempDir.path}/BLUS30443');
        final eboot = File('${gameDir.path}/PS3_GAME/USRDIR/EBOOT.BIN');
        eboot.parent.createSync(recursive: true);
        eboot.writeAsBytesSync(<int>[
          0x53,
          0x43,
          0x45,
          0x00,
          ...List<int>.filled(60, 0x12),
        ]);

        final sfo = File('${gameDir.path}/PS3_GAME/PARAM.SFO');
        sfo.writeAsBytesSync(
          _buildParamSfo(title: 'God of War III', titleId: 'BCUS98111'),
        );

        final detected = await RomPlatformDetector.detect(
          gameDir.path,
          filePath: gameDir.path,
        );
        expect(detected?.slug, 'ps3');

        final validation =
            await RomDownloadService.validatePs3DumpContent(gameDir.path);
        expect(validation.isValid, isTrue);
        expect(validation.dumpFormat, 'folder');
        expect(
          validation.resolvedRomPath!.replaceAll('\\', '/'),
          endsWith('PS3_GAME/USRDIR/EBOOT.BIN'),
        );
        expect(validation.gameTitle, 'God of War III');
        expect(validation.titleId, 'BCUS98111');
      },
    );

    test('aceita ISO descriptografada com marcador PS3 e SCE\\0 no EBOOT.BIN',
        () async {
      final tempDir = _setupMockEnvironment();
      final isoFile = File('${tempDir.path}/ps3_decrypted.iso');
      isoFile.writeAsBytesSync(
        _buildPs3Iso(ebootFirstFourBytes: const [0x53, 0x43, 0x45, 0x00]),
      );

      final validation =
          await RomDownloadService.validatePs3DumpContent(isoFile.path);
      expect(validation.isValid, isTrue);
      expect(validation.dumpFormat, 'iso');
    });

    test(
      'rejeita ISO criptografada com orientação para ManaGunZ, multiMAN ou IRISMAN',
      () async {
        final tempDir = _setupMockEnvironment();
        final isoFile = File('${tempDir.path}/ps3_encrypted_redump.iso');
        isoFile.writeAsBytesSync(
          _buildPs3Iso(ebootFirstFourBytes: const [0xDE, 0xAD, 0xBE, 0xEF]),
        );

        final validation =
            await RomDownloadService.validatePs3DumpContent(isoFile.path);
        expect(validation.isValid, isFalse);
        expect(validation.errorMessage, contains('ManaGunZ'));
        expect(validation.errorMessage, contains('multiMAN'));
        expect(validation.errorMessage, contains('IRISMAN'));
      },
    );
  });

  group('Extração em Isolate com barra de progresso (.zip e .7z)', () {
    test('extrai pasta PS3_GAME do .zip em Isolate reportando progresso',
        () async {
      final tempDir = _setupMockEnvironment();
      final archive = Archive();
      final ebootBytes = <int>[
        0x53,
        0x43,
        0x45,
        0x00,
        ...List<int>.filled(2044, 0x33),
      ];
      final sfbBytes = ascii.encode('PS3_DISC_TEST'.padRight(64, ' '));
      archive.addFile(
        ArchiveFile(
          'BLUS30443/PS3_GAME/USRDIR/EBOOT.BIN',
          ebootBytes.length,
          ebootBytes,
        ),
      );
      archive.addFile(
        ArchiveFile(
          'BLUS30443/PS3_GAME/PS3_DISC.SFB',
          sfbBytes.length,
          sfbBytes,
        ),
      );

      final zipFile = File('${tempDir.path}/ps3_dump.zip');
      zipFile.writeAsBytesSync(ZipEncoder().encode(archive)!);

      final extractDir = Directory('${tempDir.path}/out_ps3');
      final progressValues = <double>[];
      final picked = await RomDownloadService.extractAndPickRomFromArchive(
        archivePath: zipFile.path,
        extractDir: extractDir,
        platformSlug: 'ps3',
        onProgress: (p, _) => progressValues.add(p),
      );

      expect(progressValues, isNotEmpty);
      expect(picked, isNotNull);
      expect(
        picked!.replaceAll('\\', '/'),
        endsWith('PS3_GAME/USRDIR/EBOOT.BIN'),
      );

      final folderRoot = Directory('${extractDir.path}/BLUS30443');
      final validation =
          await RomDownloadService.validatePs3DumpContent(folderRoot.path);
      expect(validation.isValid, isTrue);
    });

    test('extrai .7z em Dart puro dentro do Isolate reportando progresso',
        () async {
      final tempDir = _setupMockEnvironment();
      final romPayload = Uint8List.fromList(
        List<int>.generate(8192, (i) => (i * 19 + 5) & 0xFF),
      );
      final sevenZipBytes = _buildMinimalCopy7z(
        fileName: 'hero.nes',
        payload: romPayload,
      );
      final szFile = File('${tempDir.path}/hero.7z')
        ..writeAsBytesSync(sevenZipBytes);

      final extractDir = Directory('${tempDir.path}/out_7z');
      final progressValues = <double>[];
      final picked = await RomDownloadService.extractAndPickRomFromArchive(
        archivePath: szFile.path,
        extractDir: extractDir,
        platformSlug: 'nes',
        onProgress: (p, _) => progressValues.add(p),
      );

      expect(progressValues, isNotEmpty);
      expect(picked, isNotNull);
      expect(picked!.endsWith('hero.nes'), isTrue);
      expect(File(picked).readAsBytesSync(), equals(romPayload));
    });
  });

  group('Retomada automática ao voltar para o app ou reconectar rede', () {
    test(
      'aguarda conexão sem gastar tentativas e conclui ao chamar onAppOrNetworkResumed',
      () async {
        var online = true;
        _setupMockEnvironment(isConnected: () => online);

        final payload = Uint8List.fromList(
          List<int>.generate(16 * 1024, (i) => (i * 31 + 7) & 0xFF),
        );
        final waitingForNetwork = Completer<void>();
        late final RomDownloadService service;

        final adapter = _OfflineThenSuccessAdapter(
          payload: payload,
          isOnline: () => online,
          onOfflineAttempt: () {},
        );
        final dio = Dio()..httpClientAdapter = adapter;
        service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        const game = EmulationGame(
          igdbId: 88101,
          name: 'Atari Resume Test',
          canonicalNoIntroName: 'Atari Resume Test (USA)',
          summary: 'Teste de retomada automática.',
          genres: ['Action'],
          developer: 'LoopDev',
          releaseYear: 1982,
          rating: 85,
          platformName: 'Atari 2600',
          platformSlug: 'atari2600',
          directRomUrl: 'https://example.com/atari_resume_test.a26',
          estimatedSizeBytes: 16384,
        );

        // Simula queda de conexão antes do download começar
        online = false;
        final downloadFuture = service.startBackgroundDownload(
          game: game,
          onStatus: (status) {
            if ((status.speedLabel ?? '').contains('Aguardando conexão') &&
                !waitingForNetwork.isCompleted) {
              waitingForNetwork.complete();
            }
          },
        );

        await waitingForNetwork.future.timeout(const Duration(seconds: 3));
        expect(adapter.fetchCount, 1);

        // Conexão volta e o ciclo do app dispara onAppOrNetworkResumed
        online = true;
        await service.onAppOrNetworkResumed();

        final resultPath =
            await downloadFuture.timeout(const Duration(seconds: 5));
        expect(resultPath, isNotNull);
        expect(File(resultPath!).readAsBytesSync(), equals(payload));
        expect(adapter.fetchCount, 2);
      },
    );
  });

  group('CPS1 e CPS2 FBNeo romset pai canônico', () {
    test('mapeia clones e títulos para o romset pai correto no FBNeo', () {
      expect(
        RomDownloadService.resolveCanonicalFbneoParent('sfa3ur1.zip'),
        (parentStem: 'sfa3', platformSlug: 'cps2'),
      );
      expect(
        RomDownloadService.resolveCanonicalFbneoParent(
          'Street Fighter Alpha 3 (USA 980904)',
          gameTitle: 'Street Fighter Alpha 3',
        ),
        (parentStem: 'sfa3', platformSlug: 'cps2'),
      );
      expect(
        RomDownloadService.resolveCanonicalFbneoParent('mvscu.zip'),
        (parentStem: 'mvsc', platformSlug: 'cps2'),
      );
      expect(
        RomDownloadService.resolveCanonicalFbneoParent('dinou.zip'),
        (parentStem: 'dino', platformSlug: 'cps1'),
      );
      expect(
        RomDownloadService.resolveCanonicalFbneoParent('sf2ceua.zip'),
        (parentStem: 'sf2ce', platformSlug: 'cps1'),
      );
    });
  });

  group('PSP velocidade em 60 FPS (PPSSPP core options)', () {
    test(
      'não força auto_frameskip, frameskip nem sound_speedhack quando frameSkip == 0',
      () {
        const settings = AppSettings(performanceBoost: true, frameSkip: 0);
        final opts = settings.libretroCoreOptions;
        expect(opts['ppsspp_auto_frameskip'], 'disabled');
        expect(opts['ppsspp_frameskip'], 'disabled');
        expect(opts['ppsspp_sound_speedhack'], 'disabled');
        expect(opts['ppsspp_force_max_fps'], 'disabled');
      },
    );

    test('aplica frameskip explícito quando frameSkip > 0', () {
      const settings = AppSettings(performanceBoost: true, frameSkip: 2);
      final opts = settings.libretroCoreOptions;
      expect(opts['ppsspp_frameskip'], '2');
      expect(opts['ppsspp_auto_frameskip'], 'enabled');
    });
  });

  group('Capas e banners offline salvos localmente', () {
    testWidgets(
      'recupera capa e banner locais por gameId e ProceduralCover usa Image.file offline',
      (tester) async {
        _setupMockEnvironment();
        late final Directory cacheDir;
        await tester.runAsync(() async {
          cacheDir = await CoverCacheService.instance.ensureCacheDirectory();
        });
        final pngBytes = _buildValidPngOver100Bytes();
        expect(pngBytes.length, greaterThan(100));

        final coverFile = File('${cacheDir.path}/game_cover_777001.img')
          ..writeAsBytesSync(pngBytes);
        final bannerFile = File('${cacheDir.path}/game_banner_777001.img')
          ..writeAsBytesSync(pngBytes);
        File('${coverFile.path}.src')
            .writeAsStringSync(_coverUrlHash('https://offline.invalid/cover.png'));
        File('${bannerFile.path}.src')
            .writeAsStringSync(_coverUrlHash('https://offline.invalid/banner.png'));

        final resolvedCover =
            CoverCacheService.instance.getCachedCoverForGame(777001);
        final resolvedBanner =
            CoverCacheService.instance.getCachedBannerForGame(777001);
        expect(resolvedCover?.path, coverFile.path);
        expect(resolvedBanner?.path, bannerFile.path);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 140,
                    height: 200,
                    child: ProceduralCover(
                      title: 'Bleach: Heat the Soul 3',
                      platformName: 'PSP',
                      gameId: 777001,
                      imageUrl: 'https://offline.invalid/cover.png',
                    ),
                  ),
                  SizedBox(
                    width: 240,
                    height: 120,
                    child: ProceduralCover(
                      title: 'Bleach: Heat the Soul 3',
                      platformName: 'PSP',
                      gameId: 777001,
                      isBanner: true,
                      imageUrl: 'https://offline.invalid/banner.png',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        final imageFinder = find.byType(Image);
        expect(imageFinder, findsNWidgets(2));
        final coverImage = tester.widget<Image>(imageFinder.at(0));
        final bannerImage = tester.widget<Image>(imageFinder.at(1));
        expect(coverImage.image, isA<FileImage>());
        expect((coverImage.image as FileImage).file.path, coverFile.path);
        expect(bannerImage.image, isA<FileImage>());
        expect((bannerImage.image as FileImage).file.path, bannerFile.path);

        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  });

  group('Extração streaming .zip, bloqueio de PC .exe, capas e relatório', () {
    test('extrai .zip DEFLATE com nomes Latin-1 não-UTF8 em streaming sem OOM',
        () async {
      final tempDir = _setupMockEnvironment();
      final payload = Uint8List.fromList(
        List<int>.generate(16 * 1024, (i) => (i * 13 + 7) & 0xFF),
      );
      final arc = Archive()
        ..addFile(ArchiveFile('game_XX.gba', payload.length, payload));
      final zipBytes = Uint8List.fromList(ZipEncoder().encode(arc)!);

      // Substitui 'XX' por bytes inválidos em UTF-8 ([0xE7, 0xE3]) nos registros
      final marker = ascii.encode('game_XX.gba');
      for (var i = 0; i <= zipBytes.length - marker.length; i++) {
        var match = true;
        for (var j = 0; j < marker.length; j++) {
          if (zipBytes[i + j] != marker[j]) {
            match = false;
            break;
          }
        }
        if (match) {
          zipBytes[i + 5] = 0xE7;
          zipBytes[i + 6] = 0xE3;
        }
      }

      final zipFile = File('${tempDir.path}/latin1.zip')
        ..writeAsBytesSync(zipBytes);
      final extractDir = Directory('${tempDir.path}/out_stream');
      final outFiles = <String>[];
      final progress = <double>[];

      await StreamingZipArchiveExtractor.extractToDisk(
        zipPath: zipFile.path,
        extractPath: extractDir.path,
        platformSlug: 'gba',
        onProgress: (p, _) => progress.add(p),
        outFiles: outFiles,
      );

      expect(progress, isNotEmpty);
      expect(outFiles, hasLength(1));
      expect(File(outFiles.first).readAsBytesSync(), equals(payload));
    });

    test('rejeita arquivo PC .exe com ALIVE.BIN disfarçado de ROM de console',
        () {
      final pickedPs3 = RomDownloadService.pickPreferredExtractedRom(
        const [
          'Catherine.Classic/Catherine.exe',
          'Catherine.Classic/data/lounge/ALIVE.BIN',
        ],
        platformSlug: 'ps3',
      );
      final pickedWii = RomDownloadService.pickPreferredExtractedRom(
        const [
          'Catherine.Classic/Catherine.exe',
          'Catherine.Classic/data/lounge/ALIVE.BIN',
        ],
        platformSlug: 'wii',
      );
      expect(pickedPs3, isNull);
      expect(pickedWii, isNull);
    });

    test('evita capa cruzada entre versões de Resident Evil e corrige playlist CPS1/CPS2',
        () {
      expect(
        GameAssetService.titleSimilarityScore(
          'Resident Evil',
          'Resident Evil 4',
        ),
        0.0,
      );
      expect(
        GameAssetService.titleSimilarityScore(
          'Resident Evil Gaiden',
          'Resident Evil 2',
        ),
        0.0,
      );
      expect(
        GameAssetService.titleSimilarityScore(
          'Chrono Trigger',
          'CHRONO TRIGGER',
        ),
        1.0,
      );

      const sfa3 = EmulationGame(
        igdbId: 65101,
        name: 'Street Fighter Alpha 3',
        canonicalNoIntroName: 'Street Fighter Alpha 3 (Euro 980904)',
        summary: '',
        genres: ['Luta'],
        developer: 'Capcom',
        releaseYear: 1998,
        rating: 94,
        platformName: 'CPS1 / CPS2',
        platformSlug: 'cps1',
        directRomUrl: 'retroapi://cps1/sfa3.zip',
      );
      expect(sfa3.libretroPlaylistName, 'FBNeo - Arcade Games');
    });

    test('DiagnosticLogService grava relatório completo de erros e armazenamento',
        () async {
      _setupMockEnvironment();
      DiagnosticLogService.instance.record(
        'Erro simulado de teste na extração',
        level: 'ERROR',
      );

      final saved = await DiagnosticLogService.instance.saveReportToDisk(
        storage: const AppStorageBreakdown(
          readyRomsBytes: 1024 * 1024 * 512,
          partialDownloadsBytes: 1024 * 1024 * 10,
          tempCacheBytes: 4096,
        ),
        libraryGames: const [],
      );

      expect(await saved.file.exists(), isTrue);
      expect(saved.reportText, contains('RELATÓRIO DE ERROS'));
      expect(saved.reportText, contains('ARMAZENAMENTO'));
      expect(
        saved.reportText,
        contains('Erro simulado de teste na extração'),
      );
    });
  });
}
