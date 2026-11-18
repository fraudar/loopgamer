import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/game_asset_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import '../theme/ps5_hydra_theme.dart';
import '../widgets/animated_fade_slide.dart';
import '../widgets/animated_game_logo.dart';
import '../widgets/loop_common_widgets.dart';
import '../widgets/procedural_cover.dart';
import 'game_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.featuredGames,
    required this.popularGames,
    this.downloadStatuses = const {},
    this.downloadStatusesListenable,
    required this.downloadService,
    required this.onStatusUpdated,
    required this.onLaunchGame,
    this.userMeta = const UserLibraryMeta(),
    this.onUserMetaChanged,
    this.onOpenSearchTab,
    this.onOpenLibraryTab,
    this.isActive = true,
    this.isLoadingCatalog = false,
    this.catalogError,
    this.onRetryCatalog,
  });

  final List<EmulationGame> featuredGames;
  final List<EmulationGame> popularGames;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final ValueListenable<Map<int, RomDownloadStatus>>? downloadStatusesListenable;
  final RomDownloadService downloadService;
  final void Function(EmulationGame game, RomDownloadStatus status)
      onStatusUpdated;
  final void Function(EmulationGame game, String localRomPath) onLaunchGame;
  final UserLibraryMeta userMeta;
  final ValueChanged<UserLibraryMeta>? onUserMetaChanged;
  final VoidCallback? onOpenSearchTab;
  final VoidCallback? onOpenLibraryTab;
  final bool isActive;
  final bool isLoadingCatalog;
  final String? catalogError;
  final VoidCallback? onRetryCatalog;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final FocusNode _screenFocusNode = FocusNode(debugLabel: 'HomeScreenFocus');
  final ScrollController _heroScrollController = ScrollController();
  final Map<int, GameAssets> _resolvedAssets = {};
  int _selectedFeaturedIndex = 0;
  String _selectedPlatformSlug = 'todos';

  @override
  void initState() {
    super.initState();
    _prefetchShelfAssets();
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _screenFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.featuredGames != widget.featuredGames ||
        oldWidget.popularGames != widget.popularGames) {
      _prefetchShelfAssets();
    }
    if (widget.isActive && !oldWidget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _screenFocusNode.requestFocus();
        }
      });
    } else if (!widget.isActive && oldWidget.isActive) {
      if (_screenFocusNode.hasFocus) {
        _screenFocusNode.unfocus();
      }
    }
  }

  void _prefetchShelfAssets() {
    final games = widget.featuredGames.isNotEmpty
        ? widget.featuredGames
        : widget.popularGames;
    final count = games.length < 12 ? games.length : 12;
    for (int i = 0; i < count; i++) {
      final game = games[i];
      final cached = GameAssetService.instance.getCachedAssets(
        game.name,
        platformSlug: game.platformSlug,
      );
      if (cached != null) {
        _resolvedAssets[game.igdbId] = cached;
        continue;
      }
      unawaited(
        GameAssetService.instance.fetchAssetsForGame(game).then((assets) {
          if (!mounted) return;
          if (assets.hasBackground || assets.hasCover || assets.hasLogo) {
            setState(() {
              _resolvedAssets[game.igdbId] = assets;
            });
          }
        }),
      );
    }
  }

  @override
  void dispose() {
    _heroScrollController.dispose();
    _screenFocusNode.dispose();
    super.dispose();
  }

  void _scrollHeroToIndex(int index) {
    if (!_heroScrollController.hasClients) return;
    const itemExtent = 210.0;
    final pos = _heroScrollController.position;
    final desired = (index * itemExtent - (pos.viewportDimension * 0.25))
        .clamp(0.0, pos.maxScrollExtent);
    unawaited(
      _heroScrollController.animateTo(
        desired,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      ),
    );
  }

  Map<int, RomDownloadStatus> _currentStatuses() =>
      widget.downloadStatusesListenable?.value ?? widget.downloadStatuses;

  void _openDetails(EmulationGame game) {
    final statuses = _currentStatuses();
    final initialStatus = statuses[game.igdbId] ??
        widget.downloadService.activeStatuses[game.igdbId] ??
        const RomDownloadStatus();
    unawaited(
      GameDetailScreen.showAsModal(
        context,
        game: game,
        downloadService: widget.downloadService,
        initialStatus: initialStatus,
        onStatusChanged: (status) => widget.onStatusUpdated(game, status),
        onPlayPressed: (romPath) => widget.onLaunchGame(game, romPath),
      ),
    );
  }

  void _executeGameAction(EmulationGame game, RomDownloadStatus status) {
    if (status.state == RomActionState.readyToPlay &&
        status.localPath != null) {
      widget.onLaunchGame(game, status.localPath!);
      return;
    }
    if (status.state == RomActionState.downloading) {
      widget.downloadService.cancelDownload(game.igdbId);
      return;
    }
    if (game.directRomUrl.startsWith('external://')) {
      _openDetails(game);
      return;
    }
    unawaited(
      widget.downloadService.startBackgroundDownload(
        game: game,
        onStatus: (st) => widget.onStatusUpdated(game, st),
      ),
    );
  }

  List<EmulationGame> _resolveRecentGames(List<EmulationGame> pool) {
    final byId = <int, EmulationGame>{
      for (final g in pool) g.igdbId: g,
    };
    final recentIds = widget.userMeta.recentlyPlayedIds();
    return [
      for (final id in recentIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  List<EmulationGame> _resolveFavoriteGames(List<EmulationGame> pool) {
    final seen = <int>{};
    final favorites = <EmulationGame>[];
    for (final g in pool) {
      if (widget.userMeta.isFavorite(g.igdbId) && seen.add(g.igdbId)) {
        favorites.add(g);
      }
    }
    return favorites;
  }

  @override
  Widget build(BuildContext context) {
    final shelfGames = widget.featuredGames.isNotEmpty
        ? widget.featuredGames
        : widget.popularGames;
    final safeIndex = shelfGames.isEmpty
        ? 0
        : _selectedFeaturedIndex.clamp(0, shelfGames.length - 1);

    final combinedPool = <EmulationGame>[
      ...widget.popularGames,
      ...widget.featuredGames,
    ];
    final recentGames = _resolveRecentGames(combinedPool);
    final favoriteGames = _resolveFavoriteGames(combinedPool);

    final filteredCatalog = _selectedPlatformSlug == 'todos'
        ? widget.popularGames
        : widget.popularGames
            .where(
              (g) =>
                  g.platformSlug.toLowerCase() ==
                  _selectedPlatformSlug.toLowerCase(),
            )
            .toList();

    final Widget content;
    if (shelfGames.isEmpty && widget.popularGames.isEmpty) {
      content = _buildFullCatalogStateScreen(context);
    } else {
      content = _buildGameHubLandscapeHome(
        context,
        shelfGames: shelfGames,
        safeIndex: safeIndex,
        recentGames: recentGames,
        favoriteGames: favoriteGames,
        filteredCatalog: filteredCatalog,
      );
    }

    return Focus(
      focusNode: _screenFocusNode,
      autofocus: widget.isActive,
      canRequestFocus: widget.isActive,
      descendantsAreFocusable: widget.isActive,
      onKeyEvent: (node, event) {
        // Permite que LB/RB e LT/RT subam para alternar as abas principais do app.
        if (event.logicalKey == LogicalKeyboardKey.gameButtonLeft1 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonRight1 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonLeft2 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonRight2) {
          return KeyEventResult.ignored;
        }
        return handleGamepadNavigationKey(
          event: event,
          itemCount: shelfGames.length,
          currentIndex: safeIndex,
          onIndexChanged: (next) {
            setState(() => _selectedFeaturedIndex = next);
            _scrollHeroToIndex(next);
          },
          axis: Axis.horizontal,
          wrapAround: true,
          onActivate: (idx) {
            if (idx >= 0 && idx < shelfGames.length) {
              _openDetails(shelfGames[idx]);
            }
          },
          onSecondaryAction: (_) => widget.onOpenSearchTab?.call(),
          allowSecondaryWhenEmpty: true,
          isActive: widget.isActive,
        );
      },
      child: content,
    );
  }

  Widget _buildFullCatalogStateScreen(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: HydraTokens.heroBackgroundGradient,
        ),
        child: SafeArea(
          top: false,
          child: Center(
            child: Padding(
              padding: EdgeInsets.fromLTRB(24, 24 + topInset, 24, 24),
              child: widget.isLoadingCatalog
                ? const LoopEmptyState.loading(
                    title: 'Carregando catálogo...',
                    subtitle: 'Buscando jogos, metadados e capas do sistema.',
                  )
                : widget.catalogError != null
                    ? LoopEmptyState.error(
                        title: 'Erro ao carregar catálogo',
                        subtitle: widget.catalogError,
                        actionLabel: widget.onRetryCatalog != null
                            ? 'Tentar novamente'
                            : null,
                        onAction: widget.onRetryCatalog,
                      )
                    : LoopEmptyState(
                        title: 'Nenhum jogo disponível',
                        subtitle:
                            'O catálogo está vazio no momento. Recarregue ou explore ROMs online.',
                        actionLabel: widget.onRetryCatalog != null
                            ? 'Recarregar'
                            : 'Explorar ROMs',
                        onAction:
                            widget.onRetryCatalog ?? widget.onOpenSearchTab,
                      ),
            ),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // MODO HORIZONTAL (CONSOLE-FIRST PS5 LANDSCAPE)
  // ==========================================================================
  Widget _buildGameHubLandscapeHome(
    BuildContext context, {
    required List<EmulationGame> shelfGames,
    required int safeIndex,
    required List<EmulationGame> recentGames,
    required List<EmulationGame> favoriteGames,
    required List<EmulationGame> filteredCatalog,
  }) {
    final activeGame = shelfGames.isNotEmpty ? shelfGames[safeIndex] : null;
    final activeAssets =
        activeGame != null ? _resolvedAssets[activeGame.igdbId] : null;
    final activeBannerUrl =
        activeAssets?.backgroundImageUrl ?? activeGame?.heroBannerUrl;

    return Scaffold(
      backgroundColor: PS5HydraTheme.pitchBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Banner full-bleed do jogo em foco
          if (activeGame != null)
            AnimatedSwitcher(
              duration: PS5HydraTheme.animStandard, // 300ms
              switchInCurve: Curves.easeOut,
              child: SizedBox.expand(
                key: ValueKey<String>(
                  activeBannerUrl ?? activeGame.resolvedHeroBannerUrl,
                ),
                child: ProceduralCover(
                  title: activeGame.name,
                  platformName: activeGame.platformName,
                  gameId: activeGame.igdbId,
                  isBanner: true,
                  imageUrl: activeBannerUrl ?? activeGame.resolvedHeroBannerUrl,
                  borderRadius: 0,
                  showBottomLabel: false,
                ),
              ),
            ),

          // Gradiente transparente -> #000000 na parte de baixo
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.35, 0.70, 1.0],
                  colors: [
                    PS5HydraTheme.pitchBlack.withOpacity(0.42),
                    PS5HydraTheme.pitchBlack.withOpacity(0.55),
                    PS5HydraTheme.pitchBlack.withOpacity(0.92),
                    PS5HydraTheme.pitchBlack,
                  ],
                ),
              ),
            ),
          ),

          // 2. Conteúdo rolável em Landscape
          SafeArea(
            top: false,
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                28,
                MediaQuery.paddingOf(context).top + 60,
                28,
                84,
              ),
              children: [
                const Center(
                  child: Text(
                    'LOOPGAMER',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'PressStart2P',
                      fontSize: 13.5,
                      letterSpacing: 1.6,
                      color: PS5HydraTheme.auroraSpringMint,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Bloco Hero focal com Clear Logo + Meta Row + Único CTA #00F5A0
                if (activeGame != null) ...[
                  _DownloadStatusesScope(
                    listenable: widget.downloadStatusesListenable,
                    fallback: widget.downloadStatuses,
                    builder: (context, statuses) {
                      final st = statuses[activeGame.igdbId] ??
                          const RomDownloadStatus();
                      final isReady = st.state == RomActionState.readyToPlay &&
                          st.localPath != null;
                      final isDownloading =
                          st.state == RomActionState.downloading;
                      final isExternal =
                          activeGame.directRomUrl.startsWith('external://');
                      final ctaText = isReady
                          ? 'Jogar Agora'
                          : isDownloading
                              ? 'Cancelar (${LoopProgressIndicator.formatPercent(st.progress)})'
                              : isExternal
                                  ? 'Ver Detalhes'
                                  : 'Baixar e Jogar';
                      return ClipRRect(
                        borderRadius:
                            BorderRadius.circular(PS5HydraTheme.radiusCard),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                          child: Container(
                            padding: const EdgeInsets.all(18),
                            decoration: PS5HydraTheme.surfaceGlass(
                              radius: PS5HydraTheme.radiusCard,
                              alpha: 0.78,
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: AnimatedHeroFadeSlideSwitcher(
                                    duration: PS5HydraTheme.animStandard,
                                    curve: Curves.easeOut,
                                    slideFractionY: 0.10,
                                    child: Column(
                                      key: ValueKey<int>(activeGame.igdbId),
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        AnimatedGameLogo(
                                          game: activeGame,
                                          height: 44,
                                          maxWidthFraction: 0.80,
                                          enableStagger: false,
                                          maxLines: 1,
                                          fallbackStyle: const TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 24,
                                            fontWeight: FontWeight.w700,
                                            color: PS5HydraTheme.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              activeGame.platformName,
                                              style:
                                                  PS5HydraTheme.metaMonoStyle,
                                            ),
                                            PS5HydraTheme.metaDivider(),
                                            const Text(
                                              'VULKAN',
                                              style:
                                                  PS5HydraTheme.metaMonoStyle,
                                            ),
                                            PS5HydraTheme.metaDivider(),
                                            Text(
                                              activeGame.formattedSize,
                                              style:
                                                  PS5HydraTheme.metaMonoStyle,
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          activeGame.summary,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: PS5HydraTheme.bodySynopsisStyle
                                              .copyWith(fontSize: 13),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 20),
                                FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                    backgroundColor:
                                        PS5HydraTheme.auroraSpringMint,
                                    foregroundColor: PS5HydraTheme.textOnAurora,
                                    minimumSize: const Size(164, 48),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 20,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(
                                        PS5HydraTheme.radiusChip,
                                      ),
                                    ),
                                  ),
                                  onPressed: () =>
                                      _executeGameAction(activeGame, st),
                                  icon: PhosphorIcon(
                                    isDownloading
                                        ? PhosphorIcons.xCircle(
                                            PhosphorIconsStyle.fill,
                                          )
                                        : PhosphorIcons.play(
                                            PhosphorIconsStyle.fill,
                                          ),
                                    size: 17,
                                  ),
                                  label: Text(
                                    ctaText,
                                    style: const TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 18),
                ],

                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      const Text(
                        'Destaques da Coleção',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: PS5HydraTheme.textPrimary,
                        ),
                      ),
                      if (widget.isLoadingCatalog) const _CatalogSyncBadge(),
                    ],
                  ),
                ),

                if (widget.catalogError != null) ...[
                  const SizedBox(height: 10),
                  LoopEmptyState.error(
                    compact: true,
                    title: 'Não foi possível atualizar o catálogo online',
                    subtitle: widget.catalogError,
                    actionLabel: widget.onRetryCatalog != null
                        ? 'Tentar novamente'
                        : null,
                    onAction: widget.onRetryCatalog,
                  ),
                ],

                const SizedBox(height: 12),

                // Carrossel Principal Widescreen
                _DownloadStatusesScope(
                  listenable: widget.downloadStatusesListenable,
                  fallback: widget.downloadStatuses,
                  builder: (context, statuses) => SizedBox(
                    height: 174,
                    child: ListView.separated(
                      controller: _heroScrollController,
                      clipBehavior: Clip.none,
                      scrollDirection: Axis.horizontal,
                      itemCount: shelfGames.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (context, idx) {
                        final game = shelfGames[idx];
                        final isFocused = idx == safeIndex;
                        final status =
                            statuses[game.igdbId] ?? const RomDownloadStatus();
                        return Align(
                          alignment: Alignment.bottomCenter,
                          child: _GameHubLandscapeHeroCard(
                            game: game,
                            status: status,
                            bannerUrl:
                                _resolvedAssets[game.igdbId]?.backgroundImageUrl,
                            isFocused: isFocused,
                            onTap: () {
                              if (isFocused) {
                                _openDetails(game);
                              } else {
                                setState(() => _selectedFeaturedIndex = idx);
                                _scrollHeroToIndex(idx);
                              }
                            },
                            onActionTap: () => _executeGameAction(game, status),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // Seção dedicada: Continuar jogando (Cards Verticais 3:4 estilo PS5)
                _SectionHeaderRow(
                  icon: PhosphorIcons.clockCounterClockwise(
                    PhosphorIconsStyle.bold,
                  ),
                  title: 'Continuar jogando',
                  trailing: recentGames.isNotEmpty
                      ? '${recentGames.length} títulos'
                      : null,
                ),
                const SizedBox(height: 12),
                if (recentGames.isNotEmpty)
                  SizedBox(
                    height: 192,
                    child: ListView.separated(
                      clipBehavior: Clip.none,
                      scrollDirection: Axis.horizontal,
                      itemCount: recentGames.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (context, idx) {
                        final game = recentGames[idx];
                        final playtimeSec = widget.userMeta
                            .playtimeOf(game.igdbId)
                            .totalSeconds;
                        final cachedCover = _resolvedAssets[game.igdbId]
                            ?.coverImageUrl;
                        return LoopRecentGameCard(
                          game: game,
                          playtimeSeconds: playtimeSec,
                          isLandscape: true,
                          cover: ProceduralCover(
                            title: game.name,
                            platformName: game.platformName,
                            gameId: game.igdbId,
                            imageUrl: cachedCover ??
                                game.gridCoverUrl ??
                                game.resolvedGridCoverUrl,
                            borderRadius: 0,
                            compact: true,
                            showBottomLabel: false,
                          ),
                          onTap: () => _openDetails(game),
                        );
                      },
                    ),
                  )
                else
                  LoopEmptyState(
                    compact: true,
                    icon: PhosphorIcons.clockCounterClockwise(
                      PhosphorIconsStyle.bold,
                    ),
                    title: 'Nenhum jogo em andamento',
                    subtitle:
                        'Inicie uma partida para retomar rapidamente daqui.',
                    actionLabel: widget.onOpenSearchTab != null
                        ? 'Explorar catálogo'
                        : null,
                    onAction: widget.onOpenSearchTab,
                  ),

                const SizedBox(height: 24),

                // Seção dedicada: Favoritos (Cards Verticais 3:4 estilo PS5)
                _SectionHeaderRow(
                  icon: PhosphorIcons.star(PhosphorIconsStyle.fill),
                  iconColor: PS5HydraTheme.textPrimary,
                  title: 'Favoritos',
                  trailing: favoriteGames.isNotEmpty
                      ? '${favoriteGames.length} jogos'
                      : null,
                ),
                const SizedBox(height: 12),
                if (favoriteGames.isNotEmpty)
                  SizedBox(
                    height: 192,
                    child: ListView.separated(
                      clipBehavior: Clip.none,
                      scrollDirection: Axis.horizontal,
                      itemCount: favoriteGames.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 14),
                      itemBuilder: (context, idx) {
                        final game = favoriteGames[idx];
                        return _HomeFavoriteCard(
                          game: game,
                          coverUrl:
                              _resolvedAssets[game.igdbId]?.coverImageUrl,
                          onTap: () => _openDetails(game),
                        );
                      },
                    ),
                  )
                else
                  LoopEmptyState(
                    compact: true,
                    icon: PhosphorIcons.star(PhosphorIconsStyle.bold),
                    title: 'Sem favoritos ainda',
                    subtitle:
                        'Marque seus jogos preferidos na Biblioteca para fixá-los aqui.',
                    actionLabel: widget.onOpenLibraryTab != null
                        ? 'Abrir Biblioteca'
                        : null,
                    onAction: widget.onOpenLibraryTab,
                  ),

                const SizedBox(height: 24),

                // Catálogo por Console + Filtros acessíveis LoopPlatformChip
                Row(
                  children: [
                    const Text(
                      'Catálogo por Console',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: PS5HydraTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${filteredCatalog.length} jogos disponíveis',
                      style: const TextStyle(
                        fontFamily: 'Rubik',
                        fontSize: 12,
                        color: PS5HydraTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: kRommPlatforms.map((plat) {
                      final active = _selectedPlatformSlug == plat.slug;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: LoopPlatformChip(
                          label: plat.shortName,
                          selected: active,
                          compact: true,
                          onTap: () =>
                              setState(() => _selectedPlatformSlug = plat.slug),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                const SizedBox(height: 12),

                if (filteredCatalog.isEmpty)
                  LoopEmptyState(
                    compact: true,
                    title: 'Nenhum jogo nesta plataforma',
                    subtitle:
                        'Limpe o filtro para ver todos os jogos ou explore novas ROMs.',
                    actionLabel: 'Mostrar todos',
                    onAction: () =>
                        setState(() => _selectedPlatformSlug = 'todos'),
                  )
                else
                  _DownloadStatusesScope(
                    listenable: widget.downloadStatusesListenable,
                    fallback: widget.downloadStatuses,
                    builder: (context, statuses) => SizedBox(
                      height: 186,
                      child: ListView.separated(
                        clipBehavior: Clip.none,
                        scrollDirection: Axis.horizontal,
                        itemCount: filteredCatalog.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 14),
                        itemBuilder: (context, idx) {
                          final game = filteredCatalog[idx];
                          final status = statuses[game.igdbId] ??
                              const RomDownloadStatus();
                          return _GameHubLandscapeSecondaryCard(
                            game: game,
                            coverUrl:
                                _resolvedAssets[game.igdbId]?.coverImageUrl,
                            status: status,
                            onTap: () => _openDetails(game),
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),

          // 3. Barra flutuante inferior direita dentro do SafeArea
          Positioned(
            right: 16,
            bottom: 8,
            child: SafeArea(
              top: false,
              left: false,
              child: _DownloadStatusesScope(
                listenable: widget.downloadStatusesListenable,
                fallback: widget.downloadStatuses,
                builder: (context, statuses) {
                  final activeStatus = activeGame != null
                      ? (statuses[activeGame.igdbId] ??
                          const RomDownloadStatus())
                      : const RomDownloadStatus();
                  final canLaunchActive =
                      activeStatus.state == RomActionState.readyToPlay &&
                          activeStatus.localPath != null;

                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: PS5HydraTheme.obsidianGlass.withOpacity(0.90),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: PS5HydraTheme.borderSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ShortcutBarAction(
                          onTap: widget.onOpenSearchTab,
                          semanticLabel: 'Buscar jogos (botão Y)',
                          child: const Row(
                            children: [
                              _ControllerKeyBadge(label: 'Y'),
                              SizedBox(width: 6),
                              Text(
                                'Buscar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: PS5HydraTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        _ShortcutBarAction(
                          onTap: widget.onOpenLibraryTab,
                          semanticLabel: 'Alternar seções (botões LB e RB)',
                          child: const Row(
                            children: [
                              _ControllerKeyBadge(label: 'LB', pill: true),
                              SizedBox(width: 4),
                              _ControllerKeyBadge(label: 'RB', pill: true),
                              SizedBox(width: 6),
                              Text(
                                'Seções',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: PS5HydraTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        _ShortcutBarAction(
                          onTap: activeGame == null
                              ? null
                              : () => _openDetails(activeGame),
                          semanticLabel: canLaunchActive
                              ? 'Abrir detalhes ou jogar (botão A)'
                              : 'Abrir detalhes (botão A)',
                          child: const Row(
                            children: [
                              _ControllerKeyBadge(label: 'A'),
                              SizedBox(width: 6),
                              Text(
                                'Detalhes',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: PS5HydraTheme.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DownloadStatusesScope extends StatelessWidget {
  const _DownloadStatusesScope({
    required this.listenable,
    required this.fallback,
    required this.builder,
  });

  final ValueListenable<Map<int, RomDownloadStatus>>? listenable;
  final Map<int, RomDownloadStatus> fallback;
  final Widget Function(
    BuildContext context,
    Map<int, RomDownloadStatus> statuses,
  ) builder;

  @override
  Widget build(BuildContext context) {
    if (listenable == null) {
      return builder(context, fallback);
    }
    return ValueListenableBuilder<Map<int, RomDownloadStatus>>(
      valueListenable: listenable!,
      builder: (context, statuses, _) => builder(context, statuses),
    );
  }
}

class _CatalogSyncBadge extends StatelessWidget {
  const _CatalogSyncBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: HydraTokens.bgNearBlack.withOpacity(0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HydraTokens.borderSubtle10),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: HydraTokens.primaryAurora,
            ),
          ),
          SizedBox(width: 6),
          Flexible(
            child: Text(
              'Sincronizando catálogo...',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Rubik',
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: HydraTokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeaderRow extends StatelessWidget {
  const _SectionHeaderRow({
    required this.icon,
    required this.title,
    this.iconColor = HydraTokens.textPrimary,
    this.trailing,
  });

  final PhosphorIconData icon;
  final String title;
  final Color iconColor;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        PhosphorIcon(icon, size: 15, color: iconColor),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 15.5,
              fontWeight: FontWeight.w700,
              color: HydraTokens.textPrimary,
            ),
          ),
        ),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(
              fontFamily: 'Rubik',
              fontSize: 12,
              color: HydraTokens.textSecondary,
            ),
          ),
      ],
    );
  }
}

/// Card vertical 3:4 estilo PS5 para Favoritos em horizontal
class _HomeFavoriteCard extends StatefulWidget {
  const _HomeFavoriteCard({
    required this.game,
    required this.onTap,
    this.coverUrl,
  });

  final EmulationGame game;
  final VoidCallback onTap;
  final String? coverUrl;

  @override
  State<_HomeFavoriteCard> createState() => _HomeFavoriteCardState();
}

class _HomeFavoriteCardState extends State<_HomeFavoriteCard> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || _hovered;
    final resolvedCover = widget.coverUrl ??
        widget.game.gridCoverUrl ??
        widget.game.resolvedGridCoverUrl;

    return Semantics(
      button: true,
      label: '${widget.game.name}, favorito, ${widget.game.platformName}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: active ? 1.05 : 1.0,
          duration: PS5HydraTheme.animFast,
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: PS5HydraTheme.animMedium,
            curve: Curves.easeOut,
            width: 138,
            decoration: BoxDecoration(
              color: PS5HydraTheme.obsidianGlass,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active
                    ? PS5HydraTheme.auroraSpringMint
                    : PS5HydraTheme.borderSubtle,
                width: active ? 1.8 : 1.0,
              ),
              boxShadow: active ? PS5HydraTheme.glowFocus : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(13),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onFocusChange: (hasFocus) {
                    if (_focused != hasFocus) {
                      setState(() => _focused = hasFocus);
                    }
                  },
                  onTap: widget.onTap,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ProceduralCover(
                        title: widget.game.name,
                        platformName: widget.game.platformName,
                        gameId: widget.game.igdbId,
                        imageUrl: resolvedCover,
                        borderRadius: 0,
                        compact: true,
                        showBottomLabel: false,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.30, 0.70, 1.0],
                            colors: [
                              Colors.transparent,
                              Color(0xB8000000),
                              Color(0xF5000000),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 10,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AnimatedGameLogo(
                              game: widget.game,
                              height: 24,
                              maxWidthFraction: 1.0,
                              enableStagger: false,
                              maxLines: 1,
                              fallbackStyle: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                color: PS5HydraTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              widget.game.platformName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PS5HydraTheme.metaMonoStyle
                                  .copyWith(fontSize: 10),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShortcutBarAction extends StatelessWidget {
  const _ShortcutBarAction({
    required this.onTap,
    required this.semanticLabel,
    required this.child,
  });

  final VoidCallback? onTap;
  final String semanticLabel;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: semanticLabel,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Center(widthFactor: 1.0, child: child),
          ),
        ),
      ),
    );
  }
}

/// Card Widescreen Principal do Carrossel Landscape
class _GameHubLandscapeHeroCard extends StatefulWidget {
  const _GameHubLandscapeHeroCard({
    required this.game,
    required this.status,
    required this.isFocused,
    required this.onTap,
    required this.onActionTap,
    this.bannerUrl,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback onActionTap;
  final String? bannerUrl;

  @override
  State<_GameHubLandscapeHeroCard> createState() =>
      _GameHubLandscapeHeroCardState();
}

class _GameHubLandscapeHeroCardState extends State<_GameHubLandscapeHeroCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isFocused || _hovered;
    final width = widget.isFocused ? 272.0 : 196.0;
    final height = widget.isFocused ? 156.0 : 114.0;
    final isDownloading = widget.status.state == RomActionState.downloading;
    final isReady = widget.status.state == RomActionState.readyToPlay &&
        widget.status.localPath != null;
    final isPaused = widget.status.state == RomActionState.paused;
    final isExternal = widget.game.directRomUrl.startsWith('external://');

    final actionLabel = isReady
        ? 'Jogar Agora'
        : isDownloading
            ? 'Cancelar (${LoopProgressIndicator.formatPercent(widget.status.progress)})'
            : isExternal
                ? 'Ver Detalhes'
                : isPaused
                    ? 'Continuar'
                    : 'Baixar Agora';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedScale(
          scale: active ? 1.05 : 1.0,
          duration: PS5HydraTheme.animFast,
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: PS5HydraTheme.animMedium,
            curve: Curves.easeOut,
            width: width,
            height: height,
            decoration: BoxDecoration(
              color: PS5HydraTheme.obsidianGlass,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: active
                    ? PS5HydraTheme.auroraSpringMint
                    : PS5HydraTheme.borderSubtle,
                width: active ? 2.0 : 1.0,
              ),
              boxShadow: active ? PS5HydraTheme.glowFocus : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12.5),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ProceduralCover(
                    title: widget.game.name,
                    platformName: widget.game.platformName,
                    gameId: widget.game.igdbId,
                    isBanner: true,
                    imageUrl:
                        widget.bannerUrl ?? widget.game.resolvedHeroBannerUrl,
                    borderRadius: 0,
                    compact: true,
                    showBottomLabel: false,
                  ),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        stops: const [0.0, 0.35, 1.0],
                        colors: [
                          Colors.transparent,
                          Colors.black.withOpacity(0.35),
                          Colors.black.withOpacity(0.90),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: PS5HydraTheme.obsidianGlass.withOpacity(0.88),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: PS5HydraTheme.borderSubtle),
                      ),
                      child: Text(
                        widget.game.platformName,
                        style: PS5HydraTheme.metaMonoStyle
                            .copyWith(fontSize: 9.5),
                      ),
                    ),
                  ),
                  if (widget.isFocused)
                    Positioned(
                      left: 14,
                      right: 14,
                      bottom: 6,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedGameLogo(
                            game: widget.game,
                            height: 28,
                            maxWidthFraction: 1.0,
                            enableStagger: false,
                            maxLines: 1,
                            fallbackStyle: const TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.4,
                              color: PS5HydraTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Semantics(
                            button: true,
                            label: '$actionLabel ${widget.game.name}',
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: widget.onActionTap,
                                child: Align(
                                  alignment: Alignment.centerLeft,
                                  widthFactor: 1.0,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const _ControllerKeyBadge(label: 'A'),
                                      const SizedBox(width: 7),
                                      Text(
                                        actionLabel,
                                        style: const TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: PS5HydraTheme.auroraSpringMint,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else
                    Positioned(
                      left: 10,
                      right: 10,
                      bottom: 8,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedGameLogo(
                            game: widget.game,
                            height: 22,
                            maxWidthFraction: 1.0,
                            enableStagger: false,
                            maxLines: 1,
                            fallbackStyle: const TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: PS5HydraTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            isDownloading
                                ? 'Baixando ${LoopProgressIndicator.formatPercent(widget.status.progress)}'
                                : '${widget.game.developer} • ${widget.game.formattedSize}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 10,
                              color: PS5HydraTheme.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Card Vertical 3:4 da seção "Catálogo por Console" em Landscape
class _GameHubLandscapeSecondaryCard extends StatefulWidget {
  const _GameHubLandscapeSecondaryCard({
    required this.game,
    required this.status,
    required this.onTap,
    this.coverUrl,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;
  final String? coverUrl;

  @override
  State<_GameHubLandscapeSecondaryCard> createState() =>
      _GameHubLandscapeSecondaryCardState();
}

class _GameHubLandscapeSecondaryCardState
    extends State<_GameHubLandscapeSecondaryCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final isReady = widget.status.state == RomActionState.readyToPlay;
    final isDownloading = widget.status.state == RomActionState.downloading;
    final active = _hovered || _focused;

    return Semantics(
      button: true,
      label: 'Ver detalhes de ${widget.game.name}, ${widget.game.platformName}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedScale(
            scale: active ? 1.05 : 1.0,
            duration: PS5HydraTheme.animFast,
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: PS5HydraTheme.animMedium,
              width: 136,
              decoration: BoxDecoration(
                color: PS5HydraTheme.obsidianGlass,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active
                      ? PS5HydraTheme.auroraSpringMint
                      : PS5HydraTheme.borderSubtle,
                  width: active ? 1.8 : 1.0,
                ),
                boxShadow: active ? PS5HydraTheme.glowFocus : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(13),
                child: Focus(
                  onFocusChange: (hasFocus) {
                    if (_focused != hasFocus) {
                      setState(() => _focused = hasFocus);
                    }
                  },
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      ProceduralCover(
                        title: widget.game.name,
                        platformName: widget.game.platformName,
                        gameId: widget.game.igdbId,
                        imageUrl: widget.coverUrl ??
                            widget.game.gridCoverUrl ??
                            widget.game.resolvedGridCoverUrl,
                        borderRadius: 0,
                        compact: true,
                        showBottomLabel: false,
                      ),
                      const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.30, 0.72, 1.0],
                            colors: [
                              Colors.transparent,
                              Color(0xB8000000),
                              Color(0xF5000000),
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          constraints: const BoxConstraints(maxWidth: 112),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: PS5HydraTheme.obsidianGlass.withOpacity(0.88),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isReady
                                  ? PS5HydraTheme.auroraSpringMint
                                  : PS5HydraTheme.borderSubtle,
                            ),
                          ),
                          child: Text(
                            isReady
                                ? 'Instalado'
                                : isDownloading
                                    ? LoopProgressIndicator.formatPercent(
                                        widget.status.progress,
                                      )
                                    : widget.game.platformName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: isReady
                                  ? PS5HydraTheme.auroraSpringMint
                                  : PS5HydraTheme.textPrimary,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 10,
                        child: AnimatedGameLogo(
                          game: widget.game,
                          height: 24,
                          maxWidthFraction: 1.0,
                          enableStagger: false,
                          maxLines: 1,
                          fallbackStyle: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: PS5HydraTheme.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Card de Poster Vertical 3:4 minimalista estilo PS5 para Grades
class RommCoverGridCard extends StatefulWidget {
  const RommCoverGridCard({
    super.key,
    required this.game,
    required this.status,
    required this.onTap,
    this.onActionTap,
    this.onLongPress,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;
  final VoidCallback? onActionTap;
  final VoidCallback? onLongPress;

  @override
  State<RommCoverGridCard> createState() => _RommCoverGridCardState();
}

class _RommCoverGridCardState extends State<RommCoverGridCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final status = widget.status;
    final isDownloaded =
        status.state == RomActionState.readyToPlay && status.localPath != null;
    final isDownloading = status.state == RomActionState.downloading;
    final isPaused = status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');
    final cachedCover = GameAssetService.instance
        .getCachedAssets(game.name, platformSlug: game.platformSlug)
        ?.coverImageUrl;

    final String actionTooltip;
    final PhosphorIconData actionIcon;
    final Color actionColor;

    if (widget.onActionTap == null) {
      actionTooltip = 'Ver detalhes';
      actionIcon = PhosphorIcons.info(PhosphorIconsStyle.bold);
      actionColor = PS5HydraTheme.textSecondary;
    } else if (isDownloaded) {
      actionTooltip = 'Jogar Agora';
      actionIcon = PhosphorIcons.playCircle(PhosphorIconsStyle.fill);
      actionColor = PS5HydraTheme.auroraSpringMint;
    } else if (isDownloading) {
      actionTooltip = 'Cancelar download';
      actionIcon = PhosphorIcons.xCircle(PhosphorIconsStyle.fill);
      actionColor = HydraTokens.accentDanger;
    } else if (isExternal) {
      actionTooltip = 'Ver detalhes';
      actionIcon = PhosphorIcons.info(PhosphorIconsStyle.bold);
      actionColor = PS5HydraTheme.textSecondary;
    } else if (isPaused) {
      actionTooltip = 'Continuar download';
      actionIcon = PhosphorIcons.play(PhosphorIconsStyle.fill);
      actionColor = PS5HydraTheme.auroraSpringMint;
    } else {
      actionTooltip = 'Baixar ROM';
      actionIcon = PhosphorIcons.downloadSimple(PhosphorIconsStyle.bold);
      actionColor = PS5HydraTheme.textPrimary;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: _hovered ? 1.04 : 1.0,
        duration: PS5HydraTheme.animFast,
        curve: Curves.easeOut,
        child: Container(
          decoration: BoxDecoration(
            color: PS5HydraTheme.obsidianGlass,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: (isDownloaded || _hovered)
                  ? PS5HydraTheme.auroraSpringMint
                  : PS5HydraTheme.borderSubtle,
              width: (isDownloaded || _hovered) ? 1.8 : 1.0,
            ),
            boxShadow: _hovered ? PS5HydraTheme.glowFocus : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12.5),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: widget.onLongPress,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ProceduralCover(
                      title: game.name,
                      platformName: game.platformName,
                      gameId: game.igdbId,
                      imageUrl: cachedCover ??
                          game.gridCoverUrl ??
                          game.resolvedGridCoverUrl,
                      borderRadius: 0,
                      compact: true,
                      showBottomLabel: false,
                    ),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: [0.35, 0.72, 1.0],
                          colors: [
                            Colors.transparent,
                            Color(0x9E000000),
                            Color(0xF5000000),
                          ],
                        ),
                      ),
                    ),
                    if (isDownloaded)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2.5,
                          ),
                          decoration: BoxDecoration(
                            color: PS5HydraTheme.auroraSpringMint,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Text(
                            'INSTALADO',
                            style: TextStyle(
                              fontFamily: 'JetBrainsMono',
                              fontSize: 8.5,
                              fontWeight: FontWeight.w700,
                              color: PS5HydraTheme.textOnAurora,
                            ),
                          ),
                        ),
                      )
                    else
                      Positioned(
                        top: 8,
                        left: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: PS5HydraTheme.pitchBlack.withOpacity(0.75),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.14),
                            ),
                          ),
                          child: Text(
                            game.platformName,
                            style: PS5HydraTheme.metaMonoStyle.copyWith(
                              fontSize: 9,
                              color: PS5HydraTheme.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    if (isDownloading)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          padding: const EdgeInsets.all(8),
                          color: Colors.black.withOpacity(0.86),
                          child: LoopProgressIndicator(
                            progress: status.progress,
                            label: 'Baixando...',
                            minHeight: 4,
                            borderRadius: 4,
                          ),
                        ),
                      )
                    else
                      Positioned(
                        left: 10,
                        right: 6,
                        bottom: 8,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  AnimatedGameLogo(
                                    game: game,
                                    height: 22,
                                    maxWidthFraction: 1.0,
                                    enableStagger: false,
                                    maxLines: 1,
                                    fallbackStyle: const TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 11.5,
                                      fontWeight: FontWeight.w700,
                                      color: PS5HydraTheme.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    game.formattedSize,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: PS5HydraTheme.metaMonoStyle.copyWith(
                                      fontSize: 9.5,
                                      color: PS5HydraTheme.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Semantics(
                              button: true,
                              label: '$actionTooltip: ${game.name}',
                              child: IconButton(
                                tooltip: actionTooltip,
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 36,
                                  minHeight: 36,
                                ),
                                padding: EdgeInsets.zero,
                                onPressed: widget.onActionTap ?? widget.onTap,
                                icon: PhosphorIcon(
                                  actionIcon,
                                  color: actionColor,
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ControllerKeyBadge extends StatelessWidget {
  const _ControllerKeyBadge({
    required this.label,
    this.pill = false,
  });

  final String label;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: pill ? 6 : 6.5,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.88),
        borderRadius: BorderRadius.circular(pill ? 5 : 12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'ReadexPro',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: HydraTokens.bgPureBlack,
        ),
      ),
    );
  }
}
