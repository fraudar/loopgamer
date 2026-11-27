import 'dart:io';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'test_temp_utils.dart';

/// Servidor HTTP falso com suporte opcional a `Range`.
class _FakeRangeAdapter implements HttpClientAdapter {
  _FakeRangeAdapter(this._payload, {this.supportRange = true});

  final Uint8List _payload;
  final bool supportRange;

  int requestCount = 0;
  int maxConcurrent = 0;
  int _inFlight = 0;

  /// Intervalos (`inicio-fim`) pedidos pelos workers paralelos (sem a sonda).
  final Set<String> chunkRanges = <String>{};
  final Set<String> _alreadyFailed = <String>{};

  /// Início de um intervalo que falhará uma única vez (simula instabilidade).
  int failRangeOnceStartingAt = -1;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requestCount++;
    _inFlight++;
    maxConcurrent = math.max(maxConcurrent, _inFlight);
    try {
      // Mantém as requisições vivas ao mesmo tempo para que a concorrência
      // realmente aconteça (sem o delay todas terminariam em sequência).
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final rawRange = options.headers['Range'] as String?;
      final match =
          rawRange == null ? null : RegExp(r'bytes=(\d+)-(\d+)').firstMatch(rawRange);
      if (!supportRange || match == null) {
        return ResponseBody.fromBytes(
          _payload,
          200,
          headers: {Headers.contentLengthHeader: ['${_payload.length}']},
        );
      }

      final start = int.parse(match.group(1)!);
      final end = int.parse(match.group(2)!);

      // Sonda `bytes=0-0` usada para descobrir o tamanho total.
      if (start == 0 && end == 0) {
        return ResponseBody.fromBytes(
          Uint8List(1),
          206,
          headers: {
            Headers.contentLengthHeader: ['1'],
            'accept-ranges': ['bytes'],
            'content-range': ['bytes 0-0/${_payload.length}'],
          },
        );
      }

      chunkRanges.add('$start-$end');
      if (failRangeOnceStartingAt == start && _alreadyFailed.add(rawRange!)) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.connectionError,
          message: 'Falha de rede simulada no chunk que começa em $start.',
        );
      }

      final slice = _payload.sublist(start, math.min(end + 1, _payload.length));
      return ResponseBody.fromBytes(
        slice,
        206,
        headers: {
          Headers.contentLengthHeader: ['${slice.length}'],
          'content-range': [
            'bytes $start-$end/${_payload.length}',
          ],
        },
      );
    } finally {
      _inFlight--;
    }
  }

  @override
  void close({bool force = false}) {}
}

Directory _setupTempSupportDir() {
  final tempDir = Directory.systemTemp.createTempSync('loopgamer_parallel_test_');
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    pathProviderChannel,
    (call) async => tempDir.path,
  );

  const methodsChannel = MethodChannel('org.loopgamer.libretro/methods');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(methodsChannel, (call) async {
    if (call.method == 'requestNotificationPermission') return true;
    if (call.method == 'syncDownloadNotification') return true;
    if (call.method == 'getNetworkStatus') {
      return <String, dynamic>{'connected': true, 'wifi': true};
    }
    return null;
  });

  addTearDown(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProviderChannel, null);
    messenger.setMockMethodCallHandler(methodsChannel, null);
    if (tempDir.existsSync()) {
      deleteTempDirQuietly(tempDir);
    }
  });
  return tempDir;
}

/// Ajusta os limiares do download paralelo e restaura ao final do teste,
/// evitando precisar de arquivos de dezenas de megabytes.
void _tuneParallelThresholds({
  int maxChunks = 4,
  int minChunkBytes = 64 * 1024,
  int minTotalBytes = 8 * 1024,
}) {
  final savedMaxChunks = RomDownloadService.maxParallelChunks;
  final savedMinChunk = RomDownloadService.minParallelChunkBytes;
  final savedMinTotal = RomDownloadService.minParallelTotalBytes;
  RomDownloadService.maxParallelChunks = maxChunks;
  RomDownloadService.minParallelChunkBytes = minChunkBytes;
  RomDownloadService.minParallelTotalBytes = minTotalBytes;
  addTearDown(() {
    RomDownloadService.maxParallelChunks = savedMaxChunks;
    RomDownloadService.minParallelChunkBytes = savedMinChunk;
    RomDownloadService.minParallelTotalBytes = savedMinTotal;
  });
}

EmulationGame _makeGame({required int id, required int sizeBytes}) {
  return EmulationGame(
    igdbId: id,
    name: 'Parallel Test Game',
    canonicalNoIntroName: 'Parallel Test Game (USA)',
    summary: 'Jogo de teste para o download multi-conexão.',
    genres: const <String>['Action'],
    developer: 'LoopDev',
    releaseYear: 2004,
    rating: 90.0,
    platformName: 'Game Boy Advance',
    platformSlug: 'gba',
    directRomUrl: 'https://example.com/parallel_test_game.gba',
    estimatedSizeBytes: sizeBytes,
  );
}

/// Payload determinístico: qualquer byte fora de ordem é detectado.
Uint8List _makePayload(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 31 + 7) & 0xFF;
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RomDownloadService download multi-conexão (HTTP Range em paralelo)', () {
    test(
      'abre várias conexões e grava o arquivo byte a byte idêntico ao original',
      () async {
        _setupTempSupportDir();
        _tuneParallelThresholds();

        final payload = _makePayload(256 * 1024);
        final server = _FakeRangeAdapter(payload);

        final dio = Dio();
        dio.httpClientAdapter = server;
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(id: 96001, sizeBytes: payload.length);
        final path = await service.startBackgroundDownload(game: game);

        expect(path, isNotNull);
        final file = File(path!);
        expect(await file.exists(), isTrue);

        final written = await file.readAsBytes();
        expect(written.length, payload.length, reason: 'tamanho deve bater');
        expect(written, equals(payload), reason: 'conteúdo deve ser idêntico');

        // A sonda (bytes=0-0) não conta como chunk.
        expect(
          server.chunkRanges.length,
          greaterThanOrEqualTo(2),
          reason: 'esperava mais de uma conexão Range em paralelo',
        );
        expect(
          server.maxConcurrent,
          greaterThanOrEqualTo(2),
          reason: 'as conexões precisam rodar ao mesmo tempo',
        );

        // Metadados de retome precisam ser limpos após a conclusão.
        final entries = File(path).parent.listSync();
        expect(
          entries.where((entry) => entry.path.endsWith('.pmeta')).toList(),
          isEmpty,
          reason: 'nenhum .pmeta pode sobrar depois de concluir',
        );
        expect(
          entries.where((entry) => entry.path.endsWith('.part')).toList(),
          isEmpty,
          reason: 'nenhum .part pode sobrar',
        );
      },
    );

    test(
      'cai para stream único quando o servidor ignora Range e entrega o arquivo',
      () async {
        _setupTempSupportDir();
        _tuneParallelThresholds();

        final payload = _makePayload(256 * 1024);
        final server = _FakeRangeAdapter(payload, supportRange: false);

        final dio = Dio();
        dio.httpClientAdapter = server;
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(id: 96002, sizeBytes: payload.length);
        final path = await service.startBackgroundDownload(game: game);

        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), equals(payload));
        expect(
          server.chunkRanges,
          isEmpty,
          reason: 'sem suporte a Range não pode haver chunks paralelos',
        );
      },
    );

    test(
      'arquivo pequeno demais não tenta paralelizar e continua correto',
      () async {
        _setupTempSupportDir();
        _tuneParallelThresholds(minTotalBytes: 1024 * 1024);

        final payload = _makePayload(256 * 1024);
        final server = _FakeRangeAdapter(payload);

        final dio = Dio();
        dio.httpClientAdapter = server;
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(id: 96003, sizeBytes: payload.length);
        final path = await service.startBackgroundDownload(game: game);

        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), equals(payload));
        expect(
          server.chunkRanges,
          isEmpty,
          reason: 'abaixo do limiar o download deve seguir em stream único',
        );
      },
    );

    test(
      'falha transitória em um chunk é repetida sem perder a integridade',
      () async {
        _setupTempSupportDir();
        _tuneParallelThresholds();

        final payload = _makePayload(256 * 1024);
        final server = _FakeRangeAdapter(payload)..failRangeOnceStartingAt = 64 * 1024;

        final dio = Dio();
        dio.httpClientAdapter = server;
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(id: 96004, sizeBytes: payload.length);
        final path = await service.startBackgroundDownload(game: game);

        expect(path, isNotNull);
        expect(
          await File(path!).readAsBytes(),
          equals(payload),
          reason: 'o retry do chunk não pode deixar buraco nem lixo no arquivo',
        );
        expect(server.chunkRanges.length, greaterThanOrEqualTo(3));
      },
    );

    test(
      'retoma de um .part parcial reaproveita os bytes já baixados',
      () async {
        final supportDir = _setupTempSupportDir();
        _tuneParallelThresholds();

        final payload = _makePayload(256 * 1024);
        final server = _FakeRangeAdapter(payload);

        final dio = Dio();
        dio.httpClientAdapter = server;
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(id: 96005, sizeBytes: payload.length);

        // Simula um download em stream único que parou em 100 KB.
        final romsDir = Directory('${supportDir.path}/roms')
          ..createSync(recursive: true);
        final partFile = File(
          '${romsDir.path}/rom_${game.igdbId}_Parallel_Test_Game.gba.part',
        );
        partFile.writeAsBytesSync(payload.sublist(0, 100 * 1024));

        final path = await service.startBackgroundDownload(game: game);

        expect(path, isNotNull);
        expect(await File(path!).readAsBytes(), equals(payload));
        expect(
          partFile.existsSync(),
          isFalse,
          reason: 'o .part deve virar o arquivo final',
        );
        expect(
          server.chunkRanges.every((r) => !r.startsWith('0-')),
          isTrue,
          reason: 'os 100 KB iniciais não precisam ser baixados de novo',
        );
      },
    );
  });
}
