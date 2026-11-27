import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/data/apkvision_offline_catalog.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/screens/settings_screen.dart';
import 'package:loopgamer/services/cover_cache_service.dart';
import 'package:loopgamer/services/game_asset_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/widgets/port_cover_card.dart';
import 'test_temp_utils.dart';

class _MockHttpAdapter implements HttpClientAdapter {
  _MockHttpAdapter(this.handler);

  final Future<ResponseBody> Function(RequestOptions options) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) =>
      handler(options);
}

ResponseBody _jsonResponse(Object payload, {int status = 200}) {
  return ResponseBody.fromString(
    jsonEncode(payload),
    status,
    headers: const {
      Headers.contentTypeHeader: ['application/json; charset=utf-8'],
    },
  );
}

String _fnvHash(String url) {
  int hash = 0x811c9dc5;
  for (int i = 0; i < url.length; i++) {
    hash ^= url.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return '${hash.toRadixString(16)}.img';
}

Directory _setupCacheEnvironment() {
  final tempDir =
      Directory.systemTemp.createTempSync('loopgamer_ports_covers_');
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async => tempDir.path);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    if (tempDir.existsSync()) deleteTempDirQuietly(tempDir);
  });
  return tempDir;
}

void main() {
  setUp(() {
    GameAssetService.clearMemoryCache();
  });

  group('Categoria Ports Android', () {
    test('enum e spec usam o rótulo Ports Android', () {
      expect(RommPlatformCategory.androidPorts.label, 'Ports Android');
      final spec = kRommPlatforms
          .where((p) => p.slug == 'android-port')
          .toList(growable: false);
      expect(spec, hasLength(1));
      expect(spec.single.resolvedCategory,
          RommPlatformCategory.androidPorts);
      expect(spec.single.coreNote, contains('APK'));
    });

    test('o catálogo APKVision alimenta a categoria com capa por título', () {
      expect(ApkVisionOfflineCatalog.entries.length, greaterThan(50));
      expect(
        ApkVisionOfflineCatalog.entries
            .where((e) => e.title.trim().isNotEmpty)
            .length,
        ApkVisionOfflineCatalog.entries.length,
      );
      expect(PortCoverCard, isNotNull);
    });
  });

  group('Capas trocadas — Silent Hill nunca recebe a capa de F', () {
    test('similaridade rejeita F e aceita Silent Hill', () {
      expect(GameAssetService.titleSimilarityScore('Silent Hill', 'F'),
          lessThan(0.55));
      expect(
          GameAssetService.titleSimilarityScore('Silent Hill', 'Silent Hill'),
          greaterThanOrEqualTo(0.55));
    });

    test('SteamGridDB escolhe o candidato real em vez do primeiro resultado',
        () async {
      final dio = Dio(BaseOptions())
        ..httpClientAdapter = _MockHttpAdapter((options) async {
          final path = options.uri.path;
          if (path.contains('/search/autocomplete/')) {
            return _jsonResponse({
              'success': true,
              'data': [
                {'id': 1, 'name': 'F'},
                {'id': 481, 'name': 'Silent Hill'},
              ],
            });
          }
          if (path.contains('/grids/game/481')) {
            return _jsonResponse({
              'success': true,
              'data': [
                {'url': 'https://cdn.invalid/silent-hill-cover.jpg'},
              ],
            });
          }
          return _jsonResponse({'success': true, 'data': []});
        });
      final service = GameAssetService(
        dio: dio,
        steamGridDbApiKey: 'test-key',
        disableNetwork: false,
      );
      final assets = await service.fetchAssetsByTitle('Silent Hill');
      expect(assets.coverImageUrl, 'https://cdn.invalid/silent-hill-cover.jpg');
      expect(
          assets.coverImageUrl, isNot(contains('f-cover')));
    });

    test('alias antigo sem procedência é descartado e o correto é mantido',
        () async {
      _setupCacheEnvironment();
      final dir = await CoverCacheService.instance.ensureCacheDirectory();
      final bytes = List<int>.generate(160, (i) => 0x41 + (i % 20));
      final alias = File('${dir.path}/game_cover_481.img')
        ..writeAsBytesSync(bytes);
      final sidecar = File('${alias.path}.src');

      const staleUrl = 'https://cdn.invalid/f-cover.jpg';
      await sidecar.writeAsString(_fnvHash(staleUrl));
      expect(
          CoverCacheService.instance
              .getCachedCoverForGame(481, 'https://cdn.invalid/silent-hill.jpg'),
          isNull);

      const correctUrl = 'https://cdn.invalid/silent-hill.jpg';
      await sidecar.writeAsString(_fnvHash(correctUrl));
      expect(
          CoverCacheService.instance.getCachedCoverForGame(481, correctUrl)?.path,
          alias.path);

      await sidecar.delete();
      expect(
          CoverCacheService.instance.getCachedCoverForGame(481, correctUrl),
          isNull);
    });
  });

  group('Configurações — desempenho', () {
    testWidgets('mostra Otimizar para este aparelho na tela de Configurações',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final service = RomDownloadService();
      await tester.pumpWidget(
        MaterialApp(
          home: SettingsScreen(
            settings: const AppSettings(),
            downloadService: service,
            onSettingsChanged: (_) {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Desempenho'), findsOneWidget);
      await tester.tap(find.text('Desempenho'));
      await tester.pump();
      expect(find.text('Otimizar para este aparelho'), findsWidgets);
    });
  });
}
