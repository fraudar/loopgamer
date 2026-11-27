import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'test_temp_utils.dart';

/// Entrega sempre o arquivo inteiro (sem Range), como um servidor comum.
class _FullBodyAdapter implements HttpClientAdapter {
  _FullBodyAdapter(this._payload);

  final Uint8List _payload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromBytes(
      _payload,
      200,
      headers: {Headers.contentLengthHeader: ['${_payload.length}']},
    );
  }

  @override
  void close({bool force = false}) {}
}

Directory _setupTempSupportDir() {
  final tempDir =
      Directory.systemTemp.createTempSync('loopgamer_platform_test_');
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

EmulationGame _makeGame({
  required int id,
  required String platformSlug,
  required String platformName,
  required String url,
  required int sizeBytes,
}) {
  return EmulationGame(
    igdbId: id,
    name: 'Resident Evil 4',
    canonicalNoIntroName: 'Resident Evil 4 (USA)',
    summary: 'Teste de validação de plataforma.',
    genres: const <String>['Action'],
    developer: 'LoopDev',
    releaseYear: 2004,
    rating: 90.0,
    platformName: platformName,
    platformSlug: platformSlug,
    directRomUrl: url,
    estimatedSizeBytes: sizeBytes,
  );
}

/// Monta uma imagem que o `RomPlatformDetector` lê como PlayStation 1.
Uint8List _ps1StyleImage(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 17 + 3) & 0xFF;
  }
  const marker = 'PS-X EXE';
  for (var i = 0; i < marker.length; i++) {
    bytes[i] = marker.codeUnitAt(i);
  }
  return bytes;
}

/// Imagem sem nenhum marcador de disco conhecido.
Uint8List _plainImage(int length) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = (i * 41 + 11) & 0xFF;
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RomDownloadService validação de plataforma pela conteúdo da ROM', () {
    test(
      'rejeita ROM de outro console e não deixa arquivo para trás',
      () async {
        final supportDir = _setupTempSupportDir();

        // Catálogo diz PC Engine, mas os bytes são de PlayStation 1.
        final payload = _ps1StyleImage(64 * 1024);
        final dio = Dio()..httpClientAdapter = _FullBodyAdapter(payload);
        final service = RomDownloadService(dio: dio);
        addTearDown(service.dispose);

        final game = _makeGame(
          id: 97001,
          platformSlug: 'pce',
          platformName: 'NEC PC Engine/TurboGrafx-16',
          url: 'https://example.com/resident_evil_4.pce',
          sizeBytes: payload.length,
        );

        RomDownloadStatus? lastStatus;
        final path = await service.startBackgroundDownload(
          game: game,
          onStatus: (status) => lastStatus = status,
        );

        expect(path, isNull, reason: 'não pode entregar ROM no core errado');
        expect(lastStatus?.state, RomActionState.notDownloaded);
        expect(
          lastStatus?.errorMessage,
          contains('PlayStation'),
          reason: 'a mensagem deve dizer o console real do arquivo',
        );

        final romsDir = Directory('${supportDir.path}/roms');
        final leftovers = romsDir.existsSync()
            ? romsDir
                .listSync()
                .where((e) => e.path.contains('97001'))
                .toList()
            : <FileSystemEntity>[];
        expect(
          leftovers,
          isEmpty,
          reason: 'nada da ROM rejeitada pode ficar em disco',
        );
      },
    );

    test('aceita ROM cujo conteúdo bate com a plataforma do catálogo', () async {
      _setupTempSupportDir();

      final payload = _ps1StyleImage(8 * 1024 * 1024);
      final dio = Dio()..httpClientAdapter = _FullBodyAdapter(payload);
      final service = RomDownloadService(dio: dio);
      addTearDown(service.dispose);

      final game = _makeGame(
        id: 97002,
        platformSlug: 'ps1',
        platformName: 'Sony PlayStation',
        url: 'https://example.com/chrono_trigger.iso',
        sizeBytes: payload.length,
      );

      final path = await service.startBackgroundDownload(game: game);

      expect(path, isNotNull);
      final file = File(path!);
      expect(await file.exists(), isTrue);
      expect(await file.length(), payload.length);
    });

    test('não bloqueia formato sem marcadores de disco', () async {
      _setupTempSupportDir();

      final payload = _plainImage(64 * 1024);
      final dio = Dio()..httpClientAdapter = _FullBodyAdapter(payload);
      final service = RomDownloadService(dio: dio);
      addTearDown(service.dispose);

      final game = _makeGame(
        id: 97003,
        platformSlug: 'pce',
        platformName: 'NEC PC Engine/TurboGrafx-16',
        url: 'https://example.com/bonks_adventure.pce',
        sizeBytes: payload.length,
      );

      final path = await service.startBackgroundDownload(game: game);

      expect(path, isNotNull);
      expect(await File(path!).exists(), isTrue);
    });
  });
}
