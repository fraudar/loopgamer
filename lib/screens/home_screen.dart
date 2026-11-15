import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/cover_cache_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import '../widgets/loop_common_widgets.dart';
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
  int _selectedFeaturedIndex = 0;
  String _selectedPlatformSlug = 'todos';

  @override
  void didUpdateWidget(covariant HomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
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

  @override
  void dispose() {
    _screenFocusNode.dispose();
    super.dispose();
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
    final isLandscape = HydraTokens.isWideLayout(context);

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
      content = isLandscape
          ? _buildGameHubLandscapeHome(
              context,
              shelfGames: shelfGames,
              safeIndex: safeIndex,
              recentGames: recentGames,
              favoriteGames: favoriteGames,
              filteredCatalog: filteredCatalog,
            )
          : _buildGameHubPortraitHome(
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
      onKeyEvent: (node, event) => handleGamepadNavigationKey(
        event: event,
        itemCount: shelfGames.length,
        currentIndex: safeIndex,
        onIndexChanged: (next) {
          setState(() => _selectedFeaturedIndex = next);
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
      ),
      child: content,
    );
  }

  Widget _buildFullCatalogStateScreen(BuildContext context) {
    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
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
    );
  }

  // ==========================================================================
  // MODO DEITADO (LANDSCAPE)
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

    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Artwork atmosférica em tela cheia do jogo selecionado (alta definição)
          if (activeGame != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: SizedBox.expand(
                key: ValueKey<int>(activeGame.igdbId),
                child: LoopCoverImage(
                  url: activeGame.resolvedHeroBannerUrl,
                  fit: BoxFit.cover,
                  preset: LoopCoverImagePreset.hero,
                ),
              ),
            ),

          // Vinheta cinematográfica
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.35, 0.75, 1.0],
                colors: [
                  HydraTokens.bgPureBlack.withOpacity(0.55),
                  HydraTokens.bgPureBlack.withOpacity(0.38),
                  HydraTokens.bgPureBlack.withOpacity(0.84),
                  HydraTokens.bgPureBlack.withOpacity(0.98),
                ],
              ),
            ),
          ),

          // 2. Conteúdo rolável em Landscape (padding inferior 84 evita sobreposição com barra de atalhos)
          SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 84),
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 10,
                    runSpacing: 6,
                    children: [
                      const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'LOOPGAMER',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.6,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                          SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              'Destaques da Coleção',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                          ),
                        ],
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
                    height: 162,
                    child: ListView.separated(
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
                            isFocused: isFocused,
                            onTap: () {
                              if (isFocused) {
                                _openDetails(game);
                              } else {
                                setState(() => _selectedFeaturedIndex = idx);
                              }
                            },
                            onActionTap: () => _executeGameAction(game, status),
                          ),
                        );
                      },
                    ),
                  ),
                ),

                const SizedBox(height: 22),

                // Seção dedicada: Continuar jogando
                _SectionHeaderRow(
                  icon: PhosphorIcons.clockCounterClockwise(
                    PhosphorIconsStyle.bold,
                  ),
                  title: 'Continuar jogando',
                  trailing: recentGames.isNotEmpty
                      ? '${recentGames.length} títulos'
                      : null,
                ),
                const SizedBox(height: 10),
                if (recentGames.isNotEmpty)
                  SizedBox(
                    height: 116,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: recentGames.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final game = recentGames[idx];
                        final playtimeSec = widget.userMeta
                            .playtimeOf(game.igdbId)
                            .totalSeconds;
                        return LoopRecentGameCard(
                          game: game,
                          playtimeSeconds: playtimeSec,
                          isLandscape: true,
                          cover: LoopCoverImage(
                            url: game.resolvedGridCoverUrl,
                            fit: BoxFit.cover,
                            preset: LoopCoverImagePreset.thumbnail,
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

                const SizedBox(height: 20),

                // Seção dedicada: Favoritos
                _SectionHeaderRow(
                  icon: PhosphorIcons.star(PhosphorIconsStyle.fill),
                  iconColor: HydraTokens.accentAmber,
                  title: 'Favoritos',
                  trailing: favoriteGames.isNotEmpty
                      ? '${favoriteGames.length} jogos'
                      : null,
                ),
                const SizedBox(height: 10),
                if (favoriteGames.isNotEmpty)
                  SizedBox(
                    height: 116,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: favoriteGames.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 12),
                      itemBuilder: (context, idx) {
                        final game = favoriteGames[idx];
                        return _HomeFavoriteCard(
                          game: game,
                          isLandscape: true,
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

                const SizedBox(height: 22),

                // Catálogo por Console + Filtros acessíveis LoopPlatformChip
                Row(
                  children: [
                    const Text(
                      'Catálogo por Console',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${filteredCatalog.length} jogos disponíveis',
                      style: const TextStyle(
                        fontFamily: 'Rubik',
                        fontSize: 12,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                          accentColor: plat.accentColor,
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
                      height: 126,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: filteredCatalog.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 14),
                        itemBuilder: (context, idx) {
                          final game = filteredCatalog[idx];
                          final status = statuses[game.igdbId] ??
                              const RomDownloadStatus();
                          return _GameHubLandscapeSecondaryCard(
                            game: game,
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

          // 3. Barra flutuante inferior direita dentro do SafeArea (sem sobrepor cards ao rolar)
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
                      color: const Color(0xD914131B),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(color: Colors.white.withOpacity(0.14)),
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
                                  color: HydraTokens.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        _ShortcutBarAction(
                          onTap: shelfGames.isEmpty
                              ? null
                              : () {
                                  final nextIdx =
                                      (safeIndex + 1) % shelfGames.length;
                                  setState(
                                      () => _selectedFeaturedIndex = nextIdx);
                                },
                          semanticLabel: 'Trocar destaque (botões LB e RB)',
                          child: const Row(
                            children: [
                              _ControllerKeyBadge(label: 'LB', pill: true),
                              SizedBox(width: 4),
                              _ControllerKeyBadge(label: 'RB', pill: true),
                              SizedBox(width: 6),
                              Text(
                                'Trocar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w600,
                                  color: HydraTokens.textPrimary,
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
                                  color: HydraTokens.textPrimary,
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

  // ==========================================================================
  // MODO EM PÉ (PORTRAIT)
  // ==========================================================================
  Widget _buildGameHubPortraitHome(
    BuildContext context, {
    required List<EmulationGame> shelfGames,
    required int safeIndex,
    required List<EmulationGame> recentGames,
    required List<EmulationGame> favoriteGames,
    required List<EmulationGame> filteredCatalog,
  }) {
    final heroGame = shelfGames.isNotEmpty ? shelfGames[safeIndex] : null;

    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 1. Top Search Pill + Botão Lateral (>= 48dp)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _DownloadStatusesScope(
                      listenable: widget.downloadStatusesListenable,
                      fallback: widget.downloadStatuses,
                      builder: (context, statuses) {
                        final hasDownloading = statuses.values.any(
                          (s) => s.state == RomActionState.downloading,
                        );
                        final hasBadges =
                            widget.isLoadingCatalog || hasDownloading;
                        return SizedBox(
                          width: double.infinity,
                          child: Wrap(
                            alignment: hasBadges
                                ? WrapAlignment.spaceBetween
                                : WrapAlignment.start,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              const Text(
                                'LOOPGAMER',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.5,
                                  color: HydraTokens.textPrimary,
                                ),
                              ),
                              if (hasBadges)
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (widget.isLoadingCatalog)
                                      const _CatalogSyncBadge(),
                                    if (hasDownloading)
                                      Semantics(
                                        button: true,
                                        label:
                                            'Downloads ativos em segundo plano. Abrir Biblioteca.',
                                        child: InkWell(
                                          borderRadius:
                                              BorderRadius.circular(14),
                                          onTap: widget.onOpenLibraryTab,
                                          child: Container(
                                            constraints: const BoxConstraints(
                                              minHeight: 48,
                                            ),
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 12,
                                              vertical: 8,
                                            ),
                                            decoration: BoxDecoration(
                                              color: HydraTokens.accentAmber
                                                  .withOpacity(0.18),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: HydraTokens.accentAmber
                                                    .withOpacity(0.5),
                                              ),
                                            ),
                                            child: const Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                SizedBox(
                                                  width: 12,
                                                  height: 12,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                    color:
                                                        HydraTokens.accentAmber,
                                                  ),
                                                ),
                                                SizedBox(width: 6),
                                                Flexible(
                                                  child: Text(
                                                    'Baixando em 2º plano',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontFamily: 'ReadexPro',
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: HydraTokens
                                                          .accentAmber,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: Semantics(
                            button: true,
                            label: 'Encontre seu jogo na aba ROMs',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(24),
                              onTap: widget.onOpenSearchTab,
                              child: Container(
                                height: 48,
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: HydraTokens.bgNearBlack,
                                  borderRadius: BorderRadius.circular(24),
                                  border: Border.all(
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    PhosphorIcon(
                                      PhosphorIcons.magnifyingGlass(
                                        PhosphorIconsStyle.regular,
                                      ),
                                      size: 18,
                                      color: HydraTokens.textSecondary,
                                    ),
                                    const SizedBox(width: 10),
                                    const Expanded(
                                      child: Text(
                                        'Encontre seu jogo...',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'Rubik',
                                          fontSize: 13.5,
                                          color: HydraTokens.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Semantics(
                          button: true,
                          label: 'Abrir Biblioteca',
                          child: Tooltip(
                            message: 'Abrir Biblioteca',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: widget.onOpenLibraryTab,
                              child: Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: HydraTokens.bgNearBlack,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                ),
                                child: Center(
                                  child: PhosphorIcon(
                                    PhosphorIcons.devices(
                                      PhosphorIconsStyle.regular,
                                    ),
                                    size: 20,
                                    color: HydraTokens.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (widget.catalogError != null) ...[
                      const SizedBox(height: 12),
                      LoopEmptyState.error(
                        compact: true,
                        title: 'Falha ao atualizar catálogo online',
                        subtitle: widget.catalogError,
                        actionLabel: widget.onRetryCatalog != null
                            ? 'Tentar novamente'
                            : null,
                        onAction: widget.onRetryCatalog,
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // 2. Hero Card Principal Portrait (alta definição)
            if (heroGame != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                  child: GestureDetector(
                    onTap: () => _openDetails(heroGame),
                    child: Container(
                      height: 238,
                      decoration: BoxDecoration(
                        color: HydraTokens.bgNearBlack,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: HydraTokens.borderSubtle10),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x99000000),
                            blurRadius: 20,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(19),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            LoopCoverImage(
                              url: heroGame.resolvedHeroBannerUrl,
                              fit: BoxFit.cover,
                              preset: LoopCoverImagePreset.hero,
                            ),
                            Container(
                              decoration: const BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: [0.0, 0.38, 0.72, 1.0],
                                  colors: [
                                    Color(0x220A090E),
                                    Color(0x550A090E),
                                    Color(0xCC0D0C13),
                                    Color(0xFA121118),
                                  ],
                                ),
                              ),
                            ),
                            Positioned(
                              left: 16,
                              right: 12,
                              bottom: 14,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Flexible(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 5,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.black.withOpacity(0.65),
                                            borderRadius:
                                                BorderRadius.circular(16),
                                            border: Border.all(
                                              color:
                                                  Colors.white.withOpacity(0.14),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              PhosphorIcon(
                                                PhosphorIcons.fire(
                                                  PhosphorIconsStyle.fill,
                                                ),
                                                size: 13,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                child: Text(
                                                  'HOT TOP ${safeIndex + 1} • ${heroGame.platformName}',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: const TextStyle(
                                                    fontFamily: 'ReadexPro',
                                                    fontSize: 10.5,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.white,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Semantics(
                                        button: true,
                                        label: 'Trocar jogo em destaque',
                                        child: Tooltip(
                                          message: 'Próximo destaque',
                                          child: IconButton(
                                            constraints: const BoxConstraints(
                                              minWidth: 48,
                                              minHeight: 48,
                                            ),
                                            onPressed: () {
                                              final next = (safeIndex + 1) %
                                                  shelfGames.length;
                                              setState(() =>
                                                  _selectedFeaturedIndex =
                                                      next);
                                            },
                                            icon: Container(
                                              padding: const EdgeInsets.all(7),
                                              decoration: BoxDecoration(
                                                color: Colors.black
                                                    .withOpacity(0.60),
                                                shape: BoxShape.circle,
                                                border: Border.all(
                                                  color: Colors.white
                                                      .withOpacity(0.18),
                                                ),
                                              ),
                                              child: PhosphorIcon(
                                                PhosphorIcons.arrowsClockwise(
                                                  PhosphorIconsStyle.bold,
                                                ),
                                                size: 15,
                                                color: HydraTokens.textPrimary,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              heroGame.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'ReadexPro',
                                                fontSize: 18.5,
                                                fontWeight: FontWeight.w700,
                                                color: HydraTokens.textPrimary,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              heroGame.summary,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'Rubik',
                                                fontSize: 12,
                                                color:
                                                    HydraTokens.textSecondary,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            _DownloadStatusesScope(
                                              listenable: widget
                                                  .downloadStatusesListenable,
                                              fallback: widget.downloadStatuses,
                                              builder: (context, statuses) {
                                                final heroStatus = statuses[
                                                        heroGame.igdbId] ??
                                                    const RomDownloadStatus();
                                                return Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 9,
                                                    vertical: 3.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        const Color(0xFF332411),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      PhosphorIcon(
                                                        PhosphorIcons.star(
                                                          PhosphorIconsStyle
                                                              .fill,
                                                        ),
                                                        size: 11,
                                                        color: Colors.white,
                                                      ),
                                                      const SizedBox(width: 4),
                                                      Flexible(
                                                        child: Text(
                                                          heroStatus.state ==
                                                                  RomActionState
                                                                      .readyToPlay
                                                              ? 'Instalado'
                                                              : heroStatus.state ==
                                                                      RomActionState
                                                                          .downloading
                                                                  ? 'Baixando ${LoopProgressIndicator.formatPercent(heroStatus.progress)}'
                                                                  : 'Featured',
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style:
                                                              const TextStyle(
                                                            fontFamily:
                                                                'ReadexPro',
                                                            fontSize: 10.5,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            color: Colors.white,
                                                          ),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                );
                                              },
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            ((heroGame.rating ?? 91) / 10.0)
                                                .clamp(8.5, 9.9)
                                                .toStringAsFixed(1),
                                            style: const TextStyle(
                                              fontFamily: 'ReadexPro',
                                              fontSize: 22,
                                              fontWeight: FontWeight.w700,
                                              color: HydraTokens.textPrimary,
                                            ),
                                          ),
                                          const Text(
                                            'Player Rating',
                                            style: TextStyle(
                                              fontFamily: 'Rubik',
                                              fontSize: 10,
                                              color: HydraTokens.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
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

            // 2b. Seção dedicada: Continuar jogando (Portrait)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeaderRow(
                      icon: PhosphorIcons.clockCounterClockwise(
                        PhosphorIconsStyle.bold,
                      ),
                      title: 'Continuar jogando',
                      trailing: recentGames.isNotEmpty
                          ? '${recentGames.length} títulos'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    if (recentGames.isNotEmpty)
                      SizedBox(
                        height: 110,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: recentGames.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 12),
                          itemBuilder: (context, idx) {
                            final game = recentGames[idx];
                            final playtimeSec = widget.userMeta
                                .playtimeOf(game.igdbId)
                                .totalSeconds;
                            return LoopRecentGameCard(
                              game: game,
                              playtimeSeconds: playtimeSec,
                              isLandscape: false,
                              cover: LoopCoverImage(
                                url: game.resolvedGridCoverUrl,
                                fit: BoxFit.cover,
                                preset: LoopCoverImagePreset.thumbnail,
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
                            'Quando você iniciar uma partida, ela aparecerá aqui.',
                        actionLabel: widget.onOpenSearchTab != null
                            ? 'Explorar catálogo'
                            : null,
                        onAction: widget.onOpenSearchTab,
                      ),
                  ],
                ),
              ),
            ),

            // 2c. Seção dedicada: Favoritos (Portrait)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionHeaderRow(
                      icon: PhosphorIcons.star(PhosphorIconsStyle.fill),
                      iconColor: HydraTokens.accentAmber,
                      title: 'Favoritos',
                      trailing: favoriteGames.isNotEmpty
                          ? '${favoriteGames.length} jogos'
                          : null,
                    ),
                    const SizedBox(height: 10),
                    if (favoriteGames.isNotEmpty)
                      SizedBox(
                        height: 110,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: favoriteGames.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 12),
                          itemBuilder: (context, idx) {
                            final game = favoriteGames[idx];
                            return _HomeFavoriteCard(
                              game: game,
                              isLandscape: false,
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
                            ? 'Ir para Biblioteca'
                            : null,
                        onAction: widget.onOpenLibraryTab,
                      ),
                  ],
                ),
              ),
            ),

            // 3. Seção "Destaques da Coleção"
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 14, bottom: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text(
                              'Destaques da Coleção',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${shelfGames.length} títulos',
                            style: const TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 12,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    _DownloadStatusesScope(
                      listenable: widget.downloadStatusesListenable,
                      fallback: widget.downloadStatuses,
                      builder: (context, statuses) => SizedBox(
                        height: 188,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          itemCount: shelfGames.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(width: 12),
                          itemBuilder: (context, idx) {
                            final game = shelfGames[idx];
                            final status = statuses[game.igdbId] ??
                                const RomDownloadStatus();
                            return _GameHubPortraitPosterItem(
                              game: game,
                              status: status,
                              isSelected: idx == safeIndex,
                              onTap: () {
                                setState(() => _selectedFeaturedIndex = idx);
                                _openDetails(game);
                              },
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 4. Filtro Rápido de Plataformas ("Catálogo por Console") usando LoopPlatformChip
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Catálogo por Console',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: HydraTokens.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${filteredCatalog.length} jogos',
                          style: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 12,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
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
                              accentColor: plat.accentColor,
                              onTap: () => setState(
                                () => _selectedPlatformSlug = plat.slug,
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 5. Grade Responsiva (ou estado vazio se filtro sem jogos)
            if (filteredCatalog.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
                  child: LoopEmptyState(
                    compact: true,
                    title: 'Nenhum jogo nesta plataforma',
                    subtitle:
                        'Limpe o filtro para ver todo o catálogo ou busque outras ROMs.',
                    actionLabel: 'Mostrar todos',
                    onAction: () =>
                        setState(() => _selectedPlatformSlug = 'todos'),
                  ),
                ),
              )
            else
              _DownloadStatusesScope(
                listenable: widget.downloadStatusesListenable,
                fallback: widget.downloadStatuses,
                builder: (context, statuses) => SliverPadding(
                  padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
                  sliver: SliverGrid(
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 185,
                      mainAxisSpacing: 14,
                      crossAxisSpacing: 14,
                      childAspectRatio: 0.66,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final game = filteredCatalog[index];
                        final status = statuses[game.igdbId] ??
                            const RomDownloadStatus();
                        return RommCoverGridCard(
                          game: game,
                          status: status,
                          onTap: () => _openDetails(game),
                          onActionTap: () => _executeGameAction(game, status),
                        );
                      },
                      childCount: filteredCatalog.length,
                    ),
                  ),
                ),
              ),
          ],
        ),
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
              color: HydraTokens.accentAmber,
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

class _HomeFavoriteCard extends StatefulWidget {
  const _HomeFavoriteCard({
    required this.game,
    required this.onTap,
    this.isLandscape = false,
  });

  final EmulationGame game;
  final VoidCallback onTap;
  final bool isLandscape;

  @override
  State<_HomeFavoriteCard> createState() => _HomeFavoriteCardState();
}

class _HomeFavoriteCardState extends State<_HomeFavoriteCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isLandscape
        ? HydraTokens.bgPureBlack.withOpacity(0.58)
        : HydraTokens.bgNearBlack;

    return Semantics(
      button: true,
      label: '${widget.game.name}, favorito, ${widget.game.platformName}',
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: widget.isLandscape ? 182 : 174,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused
                  ? HydraTokens.accentAmber
                  : HydraTokens.borderSubtle10,
              width: _focused ? 2.0 : 1.0,
            ),
            boxShadow: _focused
                ? HydraTokens.neonBoxGlow(
                    opacity: 0.28,
                    blur: 12,
                    color: HydraTokens.accentAmber,
                  )
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(11),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onFocusChange: (hasFocus) {
                  if (_focused != hasFocus) {
                    setState(() => _focused = hasFocus);
                  }
                },
                onTap: widget.onTap,
                child: Row(
                  children: [
                    SizedBox(
                      width: widget.isLandscape ? 72 : 68,
                      height: double.infinity,
                      child: LoopCoverImage(
                        url: widget.game.resolvedGridCoverUrl,
                        fit: BoxFit.cover,
                        preset: LoopCoverImagePreset.thumbnail,
                      ),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              widget.game.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                PhosphorIcon(
                                  PhosphorIcons.star(PhosphorIconsStyle.fill),
                                  size: 11,
                                  color: HydraTokens.accentAmber,
                                ),
                                const SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    widget.game.platformName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'JetBrainsMono',
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: HydraTokens.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
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
class _GameHubLandscapeHeroCard extends StatelessWidget {
  const _GameHubLandscapeHeroCard({
    required this.game,
    required this.status,
    required this.isFocused,
    required this.onTap,
    required this.onActionTap,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final bool isFocused;
  final VoidCallback onTap;
  final VoidCallback onActionTap;

  @override
  Widget build(BuildContext context) {
    final width = isFocused ? 276.0 : 196.0;
    final height = isFocused ? 158.0 : 114.0;
    final isDownloading = status.state == RomActionState.downloading;
    final isReady =
        status.state == RomActionState.readyToPlay && status.localPath != null;
    final isPaused = status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');

    final actionLabel = isReady
        ? 'Jogar Agora'
        : isDownloading
            ? 'Cancelar (${LoopProgressIndicator.formatPercent(status.progress)})'
            : isExternal
                ? 'Ver Detalhes'
                : isPaused
                    ? 'Continuar'
                    : 'Baixar Agora';

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: HydraTokens.bgNearBlack,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isFocused
                ? HydraTokens.accentAmber
                : Colors.white.withOpacity(0.14),
            width: isFocused ? 2.2 : 1.0,
          ),
          boxShadow: isFocused
              ? HydraTokens.neonBoxGlow(
                  opacity: 0.32,
                  blur: 18,
                  color: HydraTokens.accentAmber,
                )
              : [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.45),
                    blurRadius: 10,
                    offset: const Offset(0, 8),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12.5),
          child: Stack(
            fit: StackFit.expand,
            children: [
              LoopCoverImage(
                url: game.resolvedHeroBannerUrl,
                fit: BoxFit.cover,
                preset: LoopCoverImagePreset.hero,
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
                      Colors.black.withOpacity(0.88),
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
                    color: Colors.black.withOpacity(0.72),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    game.platformName,
                    style: const TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
              if (isFocused)
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 6,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.name.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.4,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Semantics(
                        button: true,
                        label: '$actionLabel ${game.name}',
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            minWidth: 48,
                            minHeight: 48,
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: onActionTap,
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
                                      color: Colors.white,
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
                      Text(
                        game.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isDownloading
                            ? 'Baixando ${LoopProgressIndicator.formatPercent(status.progress)}'
                            : '${game.developer} • ${game.formattedSize}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 10,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card Widescreen da Segunda Fileira em Landscape
class _GameHubLandscapeSecondaryCard extends StatelessWidget {
  const _GameHubLandscapeSecondaryCard({
    required this.game,
    required this.status,
    required this.onTap,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isReady = status.state == RomActionState.readyToPlay;
    final isDownloading = status.state == RomActionState.downloading;

    return Semantics(
      button: true,
      label: 'Ver detalhes de ${game.name}, ${game.platformName}',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 204,
          decoration: BoxDecoration(
            color: HydraTokens.bgNearBlack,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: isReady
                  ? Colors.white.withOpacity(0.55)
                  : Colors.white.withOpacity(0.10),
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(13),
            child: Stack(
              fit: StackFit.expand,
              children: [
                LoopCoverImage(
                  url: game.resolvedHeroBannerUrl,
                  fit: BoxFit.cover,
                  preset: LoopCoverImagePreset.card,
                ),
                Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withOpacity(0.84),
                      ],
                    ),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 176),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: isReady
                          ? HydraTokens.accentSuccess.withOpacity(0.88)
                          : const Color(0xCC6D28D9),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      isReady
                          ? 'Instalado'
                          : isDownloading
                              ? LoopProgressIndicator.formatPercent(
                                  status.progress,
                                )
                              : game.platformName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 9.5,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Text(
                    game.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pôster Vertical da fileira "Destaques da Coleção" no Modo Portrait
class _GameHubPortraitPosterItem extends StatelessWidget {
  const _GameHubPortraitPosterItem({
    required this.game,
    required this.status,
    required this.isSelected,
    required this.onTap,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isReady = status.state == RomActionState.readyToPlay;
    final isDownloading = status.state == RomActionState.downloading;

    return Semantics(
      button: true,
      selected: isSelected,
      label: '${game.name}, ${game.platformName}',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: 116,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Container(
                  decoration: BoxDecoration(
                    color: HydraTokens.surfaceCatalog,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: isSelected
                          ? HydraTokens.accentAmber
                          : Colors.white.withOpacity(0.10),
                      width: isSelected ? 2.0 : 1.0,
                    ),
                    boxShadow: isSelected
                        ? HydraTokens.neonBoxGlow(
                            opacity: 0.28,
                            blur: 12,
                            color: HydraTokens.accentAmber,
                          )
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        LoopCoverImage(
                          url: game.resolvedGridCoverUrl,
                          fit: BoxFit.cover,
                          preset: LoopCoverImagePreset.card,
                        ),
                        if (isDownloading)
                          Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: LoopProgressIndicator(
                              progress: status.progress,
                              showLabelRow: false,
                              minHeight: 4,
                              borderRadius: 0,
                            ),
                          ),
                        if (isReady)
                          Positioned(
                            top: 6,
                            right: 6,
                            child: Container(
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.75),
                                shape: BoxShape.circle,
                              ),
                              child: PhosphorIcon(
                                PhosphorIcons.checkCircle(
                                  PhosphorIconsStyle.fill,
                                ),
                                size: 13,
                                color: HydraTokens.accentSuccess,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(
                game.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Rubik',
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: HydraTokens.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Card de Capa Vertical Responsivo para Grades (Início e Catálogo)
class RommCoverGridCard extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final isDownloaded =
        status.state == RomActionState.readyToPlay && status.localPath != null;
    final isDownloading = status.state == RomActionState.downloading;
    final isPaused = status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');

    final String actionTooltip;
    final PhosphorIconData actionIcon;
    final Color actionColor;

    if (onActionTap == null) {
      actionTooltip = 'Ver detalhes';
      actionIcon = PhosphorIcons.info(PhosphorIconsStyle.bold);
      actionColor = HydraTokens.textSecondary;
    } else if (isDownloaded) {
      actionTooltip = 'Jogar Agora';
      actionIcon = PhosphorIcons.playCircle(PhosphorIconsStyle.fill);
      actionColor = HydraTokens.textPrimary;
    } else if (isDownloading) {
      actionTooltip = 'Cancelar download';
      actionIcon = PhosphorIcons.xCircle(PhosphorIconsStyle.fill);
      actionColor = HydraTokens.accentDanger;
    } else if (isExternal) {
      actionTooltip = 'Ver detalhes';
      actionIcon = PhosphorIcons.info(PhosphorIconsStyle.bold);
      actionColor = HydraTokens.textSecondary;
    } else if (isPaused) {
      actionTooltip = 'Continuar download';
      actionIcon = PhosphorIcons.play(PhosphorIconsStyle.fill);
      actionColor = HydraTokens.accentAmber;
    } else {
      actionTooltip = 'Baixar ROM';
      actionIcon = PhosphorIcons.downloadSimple(PhosphorIconsStyle.bold);
      actionColor = HydraTokens.textSecondary;
    }

    return HydraTexturedCard(
      backgroundColor: HydraTokens.bgNearBlack,
      borderRadius: 14,
      highlightedBorder: isDownloaded,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                LoopCoverImage(
                  url: game.resolvedGridCoverUrl,
                  fit: BoxFit.cover,
                  preset: LoopCoverImagePreset.card,
                ),
                if (isDownloaded)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: HydraTokens.bgPureBlack.withOpacity(0.88),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.35),
                        ),
                      ),
                      child: const Text(
                        'INSTALADO',
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 8.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
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
                      color: Colors.black.withOpacity(0.82),
                      child: LoopProgressIndicator(
                        progress: status.progress,
                        label: 'Baixando...',
                        minHeight: 4,
                        borderRadius: 4,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
            decoration: const BoxDecoration(
              color: HydraTokens.bgNearBlack,
              border: Border(
                top: BorderSide(color: HydraTokens.borderSubtle8),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        game.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          Expanded(
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.08),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  game.platformName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: HydraTokens.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            isDownloading
                                ? LoopProgressIndicator.formatPercent(
                                    status.progress,
                                  )
                                : game.formattedSize,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 10.5,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Semantics(
                  button: true,
                  label: '$actionTooltip: ${game.name}',
                  child: IconButton(
                    tooltip: actionTooltip,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    padding: EdgeInsets.zero,
                    onPressed: onActionTap ?? onTap,
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
