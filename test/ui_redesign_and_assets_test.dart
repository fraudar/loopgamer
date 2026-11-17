import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/models/emulation_game.dart';
import 'package:loopgamer/models/user_library_meta.dart';
import 'package:loopgamer/screens/explore_screen.dart';
import 'package:loopgamer/screens/home_screen.dart';
import 'package:loopgamer/screens/hydra_catalog_screen.dart';
import 'package:loopgamer/screens/library_screen.dart';
import 'package:loopgamer/screens/ps5_dashboard_screen.dart';
import 'package:loopgamer/services/game_asset_service.dart';
import 'package:loopgamer/services/igdb_steamgriddb_service.dart';
import 'package:loopgamer/services/rom_download_service.dart';
import 'package:loopgamer/theme/hydra_tokens.dart';
import 'package:loopgamer/theme/ps5_hydra_theme.dart';
import 'package:loopgamer/widgets/animated_fade_slide.dart';
import 'package:loopgamer/widgets/animated_game_logo.dart';
import 'package:loopgamer/widgets/loop_common_widgets.dart';
import 'package:loopgamer/widgets/procedural_cover.dart';

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

EmulationGame _sampleGame({
  int id = 19560,
  String name = 'God of War: Ghost of Sparta',
  String platformName = 'PSP',
  String platformSlug = 'psp',
}) {
  return EmulationGame(
    igdbId: id,
    name: name,
    canonicalNoIntroName: '$name (USA)',
    summary:
        'A jornada implacável de Kratos até a cidade submersa de Atlântida.',
    genres: const ['Ação'],
    developer: 'Ready at Dawn',
    releaseYear: 2010,
    rating: 91,
    platformName: platformName,
    platformSlug: platformSlug,
    directRomUrl: 'https://example.com/game.iso',
    estimatedSizeBytes: 1195376640,
  );
}

void main() {
  setUp(() {
    GameAssetService.clearMemoryCache();
  });

  group('GameAssetService & SessionMemoryCacheManager', () {
    test(
      'resolves transparent PNG logo, hero and cover via keyless Steam + GOG + Wikidata/Wikimedia',
      () async {
        int steamSearchHits = 0;
        final dio = Dio();
        dio.httpClientAdapter = _MockHttpAdapter((options) async {
          final uri = options.uri.toString();
          if (uri.contains('store.steampowered.com/api/storesearch')) {
            steamSearchHits++;
            return _jsonResponse({
              'total': 1,
              'items': [
                {'id': 613830, 'name': 'CHRONO TRIGGER'},
              ],
            });
          }
          if (options.method == 'HEAD' &&
              uri ==
                  'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/logo.png') {
            return ResponseBody.fromString('', 200, headers: const {
              Headers.contentTypeHeader: ['image/png'],
            });
          }
          if (options.method == 'HEAD' &&
              uri ==
                  'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/library_hero.jpg') {
            return ResponseBody.fromString('', 200, headers: const {
              Headers.contentTypeHeader: ['image/jpeg'],
            });
          }
          if (options.method == 'HEAD' &&
              uri ==
                  'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/library_600x900_2x.jpg') {
            return ResponseBody.fromString('', 200, headers: const {
              Headers.contentTypeHeader: ['image/jpeg'],
            });
          }
          if (uri.contains('catalog.gog.com/v1/catalog')) {
            return _jsonResponse({'products': const []});
          }
          return ResponseBody.fromString('', 404);
        });

        final service = GameAssetService(dio: dio, disableNetwork: false);
        addTearDown(service.dispose);

        final first = await service.fetchAssetsByTitle(
          'Chrono Trigger (USA)',
          platformSlug: 'snes',
        );
        expect(
          first.logoImageUrl,
          'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/logo.png',
        );
        expect(
          first.backgroundImageUrl,
          'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/library_hero.jpg',
        );
        expect(
          first.coverImageUrl,
          'https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/613830/library_600x900_2x.jpg',
        );

        // Segunda chamada deve retornar do cache em memória da sessão sem bater na rede
        final second = await service.fetchAssetsByTitle(
          'Chrono Trigger',
          platformSlug: 'snes',
        );
        expect(second.logoImageUrl, first.logoImageUrl);
        expect(steamSearchHits, 1);
      },
    );

    test(
      'falls back to Wikidata series (P179 -> P154) and Wikimedia Commons PNG conversion without API keys',
      () async {
        final dio = Dio();
        dio.httpClientAdapter = _MockHttpAdapter((options) async {
          final uri = options.uri.toString();
          if (uri.contains('store.steampowered.com') ||
              uri.contains('catalog.gog.com')) {
            return _jsonResponse({'items': const [], 'products': const []});
          }
          if (uri.contains('wikidata.org') && uri.contains('wbsearchentities')) {
            return _jsonResponse({
              'search': [
                {
                  'id': 'Q573779',
                  'label': 'God of War: Ghost of Sparta',
                  'description': '2010 video game',
                },
              ],
            });
          }
          if (uri.contains('wikidata.org') &&
              uri.contains('entity=Q573779') &&
              uri.contains('property=P154')) {
            return _jsonResponse({'claims': const {}});
          }
          if (uri.contains('wikidata.org') &&
              uri.contains('entity=Q573779') &&
              uri.contains('property=P179')) {
            return _jsonResponse({
              'claims': {
                'P179': [
                  {
                    'mainsnak': {
                      'datavalue': {
                        'value': {'id': 'Q390137'},
                      },
                    },
                  },
                ],
              },
            });
          }
          if (uri.contains('wikidata.org') &&
              uri.contains('entity=Q390137') &&
              uri.contains('property=P154')) {
            return _jsonResponse({
              'claims': {
                'P154': [
                  {
                    'mainsnak': {
                      'datavalue': {'value': 'God of War Logo.png'},
                    },
                  },
                ],
              },
            });
          }
          return ResponseBody.fromString('', 404);
        });

        final service = GameAssetService(dio: dio, disableNetwork: false);
        addTearDown(service.dispose);

        final assets = await service.fetchAssetsByTitle(
          'God of War: Ghost of Sparta',
          platformSlug: 'psp',
        );
        expect(
          assets.logoImageUrl,
          'https://commons.wikimedia.org/wiki/Special:FilePath/God_of_War_Logo.png?width=512',
        );
      },
    );

    test(
      'supports optional RAWG background_image/background_image_additional & SteamGridDB when keys are provided',
      () async {
        final dio = Dio();
        dio.httpClientAdapter = _MockHttpAdapter((options) async {
          final uri = options.uri.toString();
          if (uri.contains('api.rawg.io/api/games')) {
            return _jsonResponse({
              'results': [
                {
                  'name': 'Tekken 6',
                  'background_image': 'https://media.rawg.io/tekken6_bg.jpg',
                  'background_image_additional':
                      'https://media.rawg.io/tekken6_add.jpg',
                },
              ],
            });
          }
          if (uri.contains('steamgriddb.com/api/v2/search/autocomplete')) {
            return _jsonResponse({
              'data': [
                {'id': 777, 'name': 'Tekken 6'},
              ],
            });
          }
          if (uri.contains('steamgriddb.com/api/v2/logos/game/777')) {
            return _jsonResponse({
              'data': [
                {'url': 'https://cdn2.steamgriddb.com/logo/tekken6.png'},
              ],
            });
          }
          if (uri.contains('steamgriddb.com/api/v2/heroes/game/777')) {
            return _jsonResponse({'data': const []});
          }
          if (uri.contains('steamgriddb.com/api/v2/grids/game/777')) {
            return _jsonResponse({
              'data': [
                {'url': 'https://cdn2.steamgriddb.com/grid/tekken6.png'},
              ],
            });
          }
          return _jsonResponse(const {});
        });

        final service = GameAssetService(
          dio: dio,
          rawgApiKey: 'test_rawg',
          steamGridDbApiKey: 'test_sgdb',
          disableNetwork: false,
        );
        addTearDown(service.dispose);

        final assets = await service.fetchAssetsByTitle('Tekken 6');
        expect(
          assets.logoImageUrl,
          'https://cdn2.steamgriddb.com/logo/tekken6.png',
        );
        expect(
          assets.backgroundImageUrl,
          'https://media.rawg.io/tekken6_bg.jpg',
        );
        expect(
          assets.coverImageUrl,
          'https://cdn2.steamgriddb.com/grid/tekken6.png',
        );
      },
    );

    test(
      'SessionMemoryCacheManager caches downloaded image bytes in RAM only with zero disk writes',
      () async {
        final fakePng = Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]);
        final dio = Dio();
        int requests = 0;
        dio.httpClientAdapter = _MockHttpAdapter((options) async {
          requests++;
          return ResponseBody.fromBytes(
            fakePng,
            200,
            headers: const {
              Headers.contentTypeHeader: ['image/png'],
            },
          );
        });

        final cacheManager = SessionMemoryCacheManager.forTesting(dio: dio);
        addTearDown(() => cacheManager.dispose());

        const url = 'https://example.com/logo.png';
        final file1 = await cacheManager.getSingleFile(url);
        final file2 = await cacheManager.getSingleFile(url);

        expect(requests, 1);
        expect(file1.readAsBytesSync(), fakePng);
        expect(file2.path, file1.path);
        // MemoryFileSystem paths start at '/' rather than OS temp/app directories
        expect(file1.path.startsWith('/mem_'), isTrue);
      },
    );
  });

  group('ProceduralCover, AnimatedFadeSlide & AnimatedGameLogo', () {
    testWidgets(
      'ProceduralCover renders monogram and short title fallback without generic esports icon',
      (WidgetTester tester) async {
        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 90,
                height: 120,
                child: ProceduralCover(
                  title: 'God of War: Ghost of Sparta',
                  platformName: 'PSP',
                ),
              ),
            ),
          ),
        );

        expect(find.text('GW'), findsOneWidget);
        expect(find.text('God of War: Ghost of Sparta'), findsOneWidget);
        expect(find.byIcon(Icons.sports_esports_outlined), findsNothing);
      },
    );

    testWidgets(
      'AnimatedGameLogo uses ReadexPro 700 fallback when logo is missing and respects BoxFit.contain with CachedNetworkImage when present',
      (WidgetTester tester) async {
        final gameNoLogo = _sampleGame(id: 901, name: 'Daxter');
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AnimatedGameLogo(
                game: gameNoLogo,
                itemIndex: 2,
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));

        final fallbackText = tester.widget<Text>(find.text('Daxter'));
        expect(fallbackText.style?.fontFamily, 'ReadexPro');
        expect(fallbackText.style?.fontWeight, FontWeight.w700);

        const gameWithLogo = EmulationGame(
          igdbId: 902,
          name: 'Tekken 6',
          canonicalNoIntroName: 'Tekken 6 (USA)',
          summary: 'Torneio do Punho de Ferro.',
          genres: ['Luta'],
          developer: 'Namco',
          releaseYear: 2009,
          rating: 88,
          platformName: 'PSP',
          platformSlug: 'psp',
          directRomUrl: 'https://example.com/tekken6.iso',
          logoUrl: 'https://example.com/tekken6_logo.png',
        );

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 300,
                child: AnimatedGameLogo(
                  game: gameWithLogo,
                  height: 40,
                  maxWidthFraction: 0.80,
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));

        final cachedWidget = tester.widget<CachedNetworkImage>(
          find.byType(CachedNetworkImage),
        );
        expect(cachedWidget.fit, BoxFit.contain);
        expect(cachedWidget.height, 40);
        expect(
          cachedWidget.cacheManager,
          same(SessionMemoryCacheManager.instance),
        );
      },
    );

    testWidgets(
      'AnimatedHeroFadeSlideSwitcher uses FadeTransition + SlideTransition over 300ms',
      (WidgetTester tester) async {
        String label = 'Game A';
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Column(
                  children: [
                    AnimatedHeroFadeSlideSwitcher(
                      child: Text(label, key: ValueKey<String>(label)),
                    ),
                    ElevatedButton(
                      onPressed: () => setState(() => label = 'Game B'),
                      child: const Text('Switch'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.text('Switch'));
        await tester.pump(const Duration(milliseconds: 120));

        expect(find.byType(FadeTransition), findsAtLeastNWidgets(1));
        expect(find.byType(SlideTransition), findsAtLeastNWidgets(1));

        await tester.pump(const Duration(milliseconds: 220));
        expect(find.text('Game B'), findsOneWidget);
      },
    );
  });

  group('Console-first Horizontal Screens (915x412 & 1280x800)', () {
    testWidgets(
      'PS5DashboardScreen renders Horizontal Console-first (915x412 & 1280x800) with #000000 palette, 3:4 carousels and switches games',
      (WidgetTester tester) async {
        for (final size in const [Size(915, 412), Size(1280, 800)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          final games = [
            _sampleGame(id: 1, name: 'God of War: Ghost of Sparta'),
            _sampleGame(
              id: 2,
              name: 'Castlevania: Symphony of the Night',
              platformName: 'PS1',
              platformSlug: 'ps1',
            ),
          ];

          await tester.pumpWidget(
            MaterialApp(
              theme: HydraTokens.buildAppTheme(),
              home: PS5DashboardScreen(
                key: ValueKey<Size>(size),
                games: games,
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 450));

          final scaffold = tester.widget<Scaffold>(find.byType(Scaffold).first);
          expect(scaffold.backgroundColor, PS5HydraTheme.pitchBlack);

          expect(find.text('Jogos'), findsOneWidget);
          expect(find.text('Hydra'), findsOneWidget);
          expect(find.text('Gamepad'), findsOneWidget);
          expect(find.text('Shaders'), findsOneWidget);
          expect(find.text('Jogar Agora'), findsOneWidget);
          expect(find.text('Destaques'), findsOneWidget);
          expect(find.byType(AnimatedHeroFadeSlideSwitcher), findsOneWidget);
          expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
          expect(find.byType(AnimatedScale), findsAtLeastNWidgets(1));
          expect(find.byIcon(Icons.sports_esports_outlined), findsNothing);

          // Troca para o segundo jogo no carrossel horizontal
          final secondCardFinder =
              find.text('Castlevania: Symphony of the Night').first;
          await tester.ensureVisible(secondCardFinder);
          await tester.pump();
          await tester.tap(secondCardFinder);
          await tester.pump(const Duration(milliseconds: 350));
          expect(
            find.text('Castlevania: Symphony of the Night'),
            findsAtLeastNWidgets(1),
          );

          final dashScrollable = find
              .descendant(
                of: find.byType(PS5DashboardScreen),
                matching: find.byWidgetPredicate(
                  (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
                ),
              )
              .first;
          await tester.scrollUntilVisible(
            find.text('Continuar Jogando'),
            180,
            scrollable: dashScrollable,
          );
          expect(find.text('Continuar Jogando'), findsOneWidget);

          await tester.scrollUntilVisible(
            find.text('Favoritos'),
            180,
            scrollable: dashScrollable,
          );
          expect(find.text('Favoritos'), findsOneWidget);
        }
      },
    );

    testWidgets(
      'HydraCatalogScreen renders Horizontal-only (915x412 & 1280x800) with obsidianGlass cards and Clear Logos without overflow',
      (WidgetTester tester) async {
        for (final size in const [Size(915, 412), Size(1280, 800)]) {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);

          await tester.pumpWidget(
            MaterialApp(
              theme: HydraTokens.buildAppTheme(),
              home: HydraCatalogScreen(
                games: kVerifiedRealGamesCatalog.take(6).toList(),
              ),
            ),
          );
          await tester.pump(const Duration(milliseconds: 450));

          expect(find.text('Catálogo Hydra'), findsOneWidget);
          expect(find.byType(ChoiceChip), findsAtLeastNWidgets(1));
          expect(find.byType(ProceduralCover), findsAtLeastNWidgets(1));
          expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
          expect(find.byIcon(Icons.sports_esports_outlined), findsNothing);
        }
      },
    );

    testWidgets(
      'Live HomeScreen, ExploreScreen and LibraryScreen render Horizontal-only (915x412) without overflow',
      (WidgetTester tester) async {
        tester.view.physicalSize = const Size(915, 412);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final downloadService = RomDownloadService();
        addTearDown(downloadService.dispose);
        final apiService = IgdbSteamGridService();
        addTearDown(apiService.dispose);

        final sampleFeatured = kVerifiedRealGamesCatalog.take(4).toList();
        final sampleMeta = UserLibraryMeta(
          favorites: {sampleFeatured.first.igdbId},
          playtime: {
            sampleFeatured.first.igdbId: PlaytimeRecord(
              totalSeconds: 1800,
              sessions: 2,
              lastPlayed: DateTime(2026, 11, 16),
            ),
          },
        );

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: HomeScreen(
              featuredGames: sampleFeatured,
              popularGames: sampleFeatured,
              userMeta: sampleMeta,
              downloadService: downloadService,
              onStatusUpdated: (_, __) {},
              onLaunchGame: (_, __) {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 450));
        expect(find.text('LOOPGAMER'), findsOneWidget);
        expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
        expect(find.byType(AnimatedHeroFadeSlideSwitcher), findsOneWidget);

        final homeScrollable = find
            .descendant(
              of: find.byType(HomeScreen),
              matching: find.byWidgetPredicate(
                (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
              ),
            )
            .first;
        await tester.scrollUntilVisible(
          find.text('Continuar jogando'),
          180,
          scrollable: homeScrollable,
        );
        expect(find.text('Continuar jogando'), findsOneWidget);
        expect(find.byType(LoopRecentGameCard), findsAtLeastNWidgets(1));

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: ExploreScreen(
              apiService: apiService,
              downloadService: downloadService,
              settings: const AppSettings(),
              onStatusUpdated: (_, __) {},
              onLaunchGameInLibretro: (_, __) {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(PS5HydraTheme.pitchBlack, const Color(0xFF000000));
        expect(PS5HydraTheme.auroraSpringMint, const Color(0xFFFFFFFF));
        expect(HydraTokens.primaryAurora, const Color(0xFFFFFFFF));
        expect(find.text('Catálogo de ROMs'), findsOneWidget);
        expect(find.byType(LoopPlatformChip), findsNothing);
        expect(find.text('Categoria'), findsOneWidget);
        expect(find.text('Gênero'), findsOneWidget);
        expect(find.byType(RommCoverGridCard), findsAtLeastNWidgets(1));

        // Testa troca de filtro via Select (Gênero -> RPG)
        await tester.tap(find.text('Gênero'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('RPG').last);
        await tester.pumpAndSettle();
        expect(find.text('RPG'), findsOneWidget);

        // Alterna para visualização em lista para validar AnimatedGameLogo + ProceduralCover horizontal
        await tester.tap(find.byTooltip('Visualização em lista'));
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.byType(AnimatedGameLogo), findsAtLeastNWidgets(1));
        expect(find.byType(ProceduralCover), findsAtLeastNWidgets(1));
        expect(find.text('Baixar'), findsAtLeastNWidgets(1));

        await tester.pumpWidget(
          MaterialApp(
            theme: HydraTokens.buildAppTheme(),
            home: LibraryScreen(
              downloadedGames: [_sampleGame(id: 44, name: 'Crisis Core')],
              downloadingGames: const [],
              downloadStatuses: const {
                44: RomDownloadStatus(
                  state: RomActionState.readyToPlay,
                  progress: 1.0,
                  localPath: '/tmp/crisis.iso',
                ),
              },
              onImportNewRomPressed: () {},
              onLaunchGame: (_, __) {},
              onRemoveGame: (_) async {},
              onCancelDownload: (_) {},
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(find.text('Crisis Core'), findsAtLeastNWidgets(1));
        expect(find.byType(ProceduralCover), findsAtLeastNWidgets(1));
        expect(find.text('Jogar'), findsOneWidget);
      },
    );
  });
}
