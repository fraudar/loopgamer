import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/emulation_game.dart';
import '../services/game_asset_service.dart';
import '../services/igdb_steamgriddb_service.dart';
import '../services/rom_download_service.dart';
import '../theme/ps5_hydra_theme.dart';
import '../widgets/animated_fade_slide.dart';
import '../widgets/animated_game_logo.dart';
import '../widgets/procedural_cover.dart';

/// Catálogo Hydra Horizontal-only (Console-first):
/// - Fundo `#000000`, cards em `obsidianGlass` (`#050B0D`), destaque neon `#00F5A0`
///   reservado ao CTA principal (`Jogar`) e foco
/// - Filtros horizontais `ChoiceChip`, capas 3:4 com fallback de iniciais + gradiente escuro,
///   e Clear Logos via [AnimatedGameLogo]
class HydraCatalogScreen extends StatefulWidget {
  const HydraCatalogScreen({
    super.key,
    this.games,
    this.downloadStatuses = const {},
    this.assetService,
    this.onBack,
    this.onGameAction,
    this.onOpenGame,
  });

  final List<EmulationGame>? games;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final GameAssetService? assetService;
  final VoidCallback? onBack;
  final ValueChanged<EmulationGame>? onGameAction;
  final ValueChanged<EmulationGame>? onOpenGame;

  @override
  State<HydraCatalogScreen> createState() => _HydraCatalogScreenState();
}

class _HydraCatalogScreenState extends State<HydraCatalogScreen> {
  String _selectedPlatformSlug = 'todos';
  final Map<int, GameAssets> _resolvedAssets = {};

  GameAssetService get _assets =>
      widget.assetService ?? GameAssetService.instance;

  List<EmulationGame> get _allGames =>
      (widget.games != null && widget.games!.isNotEmpty)
          ? widget.games!
          : kVerifiedRealGamesCatalog;

  List<EmulationGame> get _filteredGames {
    if (_selectedPlatformSlug == 'todos') return _allGames;
    return _allGames
        .where(
          (g) =>
              g.platformSlug.toLowerCase() ==
              _selectedPlatformSlug.toLowerCase(),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _prefetchCovers();
  }

  void _prefetchCovers() {
    final list = _allGames;
    final limit = list.length < 16 ? list.length : 16;
    for (int i = 0; i < limit; i++) {
      final game = list[i];
      final cached = _assets.getCachedAssets(
        game.name,
        platformSlug: game.platformSlug,
      );
      if (cached != null) {
        _resolvedAssets[game.igdbId] = cached;
        continue;
      }
      unawaited(
        _assets.fetchAssetsForGame(game).then((assets) {
          if (!mounted) return;
          setState(() => _resolvedAssets[game.igdbId] = assets);
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredGames;

    return Scaffold(
      backgroundColor: PS5HydraTheme.pitchBlack,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                PS5HydraTheme.space24,
                PS5HydraTheme.space16,
                PS5HydraTheme.space24,
                PS5HydraTheme.space16,
              ),
              sliver: SliverToBoxAdapter(
                child: _buildLandscapeHeader(context, items.length),
              ),
            ),
            SliverToBoxAdapter(
              child: _buildPlatformChoiceChips(),
            ),
            const SliverToBoxAdapter(
              child: SizedBox(height: PS5HydraTheme.space16),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(
                PS5HydraTheme.space24,
                0,
                PS5HydraTheme.space24,
                PS5HydraTheme.space32,
              ),
              sliver: SliverList.separated(
                itemCount: items.length,
                separatorBuilder: (_, __) =>
                    const SizedBox(height: PS5HydraTheme.space12),
                itemBuilder: (context, index) {
                  final game = items[index];
                  final assets = _resolvedAssets[game.igdbId];
                  final status = widget.downloadStatuses[game.igdbId];
                  final isReady = status?.state == RomActionState.readyToPlay;

                  return AnimatedFadeSlide(
                    key: ValueKey<String>('catalog_card_${game.igdbId}'),
                    duration: PS5HydraTheme.animStandard,
                    delay: PS5HydraTheme.staggerDelay * (index % 10),
                    offsetY: 10.0,
                    curve: Curves.easeOut,
                    child: _HydraLandscapeCatalogCard(
                      game: game,
                      assets: assets,
                      assetService: _assets,
                      itemIndex: index,
                      isReady: isReady,
                      onOpen: () => widget.onOpenGame?.call(game),
                      onAction: () => widget.onGameAction?.call(game),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLandscapeHeader(BuildContext context, int count) {
    return Row(
      children: [
        IconButton(
          onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          style: IconButton.styleFrom(
            backgroundColor: PS5HydraTheme.obsidianGlass,
            side: const BorderSide(color: PS5HydraTheme.borderSubtle),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PS5HydraTheme.radiusChip),
            ),
          ),
          icon: PhosphorIcon(
            PhosphorIcons.arrowLeft(PhosphorIconsStyle.bold),
            size: 18,
            color: PS5HydraTheme.textPrimary,
          ),
        ),
        const SizedBox(width: PS5HydraTheme.space16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Catálogo Hydra',
                style: PS5HydraTheme.displayTitleStyle,
              ),
              const SizedBox(height: PS5HydraTheme.space4),
              Text(
                '$count jogos verificados com capas 3:4, Clear Logos e download direto.',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PS5HydraTheme.bodySynopsisStyle,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlatformChoiceChips() {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: PS5HydraTheme.space24),
        itemCount: kRommPlatforms.length,
        separatorBuilder: (_, __) => const SizedBox(width: PS5HydraTheme.space8),
        itemBuilder: (context, index) {
          final plat = kRommPlatforms[index];
          final selected = _selectedPlatformSlug == plat.slug;
          return ChoiceChip(
            selected: selected,
            showCheckmark: false,
            label: Text(
              plat.shortName,
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontWeight: FontWeight.w600,
                fontSize: 12,
                color: selected
                    ? PS5HydraTheme.textPrimary
                    : PS5HydraTheme.textSecondary,
              ),
            ),
            backgroundColor: PS5HydraTheme.obsidianGlass,
            selectedColor: PS5HydraTheme.abyssalCard,
            side: BorderSide(
              color: selected
                  ? PS5HydraTheme.auroraSpringMint
                  : PS5HydraTheme.borderSubtle,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PS5HydraTheme.radiusChip),
            ),
            onSelected: (_) {
              setState(() => _selectedPlatformSlug = plat.slug);
            },
          );
        },
      ),
    );
  }
}

class _HydraLandscapeCatalogCard extends StatefulWidget {
  const _HydraLandscapeCatalogCard({
    required this.game,
    required this.assets,
    required this.assetService,
    required this.itemIndex,
    required this.isReady,
    required this.onOpen,
    required this.onAction,
  });

  final EmulationGame game;
  final GameAssets? assets;
  final GameAssetService assetService;
  final int itemIndex;
  final bool isReady;
  final VoidCallback onOpen;
  final VoidCallback onAction;

  @override
  State<_HydraLandscapeCatalogCard> createState() =>
      _HydraLandscapeCatalogCardState();
}

class _HydraLandscapeCatalogCardState extends State<_HydraLandscapeCatalogCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _hovered || _focused;
    final coverUrl = widget.assets?.coverImageUrl ?? widget.game.gridCoverUrl;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.02 : 1.0,
        duration: PS5HydraTheme.animFast,
        curve: Curves.easeOut,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(PS5HydraTheme.radiusCard),
            onFocusChange: (hasFocus) {
              if (_focused != hasFocus) setState(() => _focused = hasFocus);
            },
            onTap: widget.onOpen,
            child: AnimatedContainer(
              duration: PS5HydraTheme.animMedium,
              padding: const EdgeInsets.all(PS5HydraTheme.space16),
              decoration: BoxDecoration(
                color: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
                borderRadius: BorderRadius.circular(PS5HydraTheme.radiusCard),
                border: Border.all(
                  color: active
                      ? PS5HydraTheme.auroraSpringMint
                      : PS5HydraTheme.borderSubtle,
                  width: active ? 1.6 : 1.0,
                ),
                boxShadow: active ? PS5HydraTheme.glowFocus : null,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 60,
                    height: 80,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: PS5HydraTheme.borderSubtle),
                      ),
                      child: ProceduralCover(
                        title: widget.game.name,
                        platformName: widget.game.platformName,
                        imageUrl: coverUrl,
                        borderRadius: 9,
                        compact: true,
                        showBottomLabel: coverUrl == null || coverUrl.isEmpty,
                      ),
                    ),
                  ),
                  const SizedBox(width: PS5HydraTheme.space16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AnimatedGameLogo(
                          game: widget.game,
                          assetService: widget.assetService,
                          height: 40,
                          maxWidthFraction: 0.80,
                          itemIndex: widget.itemIndex,
                          enableStagger: false,
                          fallbackStyle: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                            color: PS5HydraTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: PS5HydraTheme.space8),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              widget.game.platformName,
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                            PS5HydraTheme.metaDivider(),
                            Text(
                              widget.game.romFormatLabel,
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                            PS5HydraTheme.metaDivider(),
                            Text(
                              widget.game.formattedSize,
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                          ],
                        ),
                        const SizedBox(height: PS5HydraTheme.space8),
                        Text(
                          widget.game.summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: PS5HydraTheme.bodySynopsisStyle
                              .copyWith(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PS5HydraTheme.space16),
                  if (widget.isReady)
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: PS5HydraTheme.auroraSpringMint,
                        foregroundColor: PS5HydraTheme.textOnAurora,
                        minimumSize: const Size(136, 48),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(PS5HydraTheme.radiusChip),
                        ),
                      ),
                      onPressed: widget.onAction,
                      icon: PhosphorIcon(
                        PhosphorIcons.play(PhosphorIconsStyle.fill),
                        size: 16,
                      ),
                      label: const Text(
                        'Jogar Agora',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  else
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: PS5HydraTheme.textPrimary,
                        backgroundColor: PS5HydraTheme.pitchBlack,
                        minimumSize: const Size(136, 48),
                        side:
                            const BorderSide(color: PS5HydraTheme.borderSubtle),
                        shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(PS5HydraTheme.radiusChip),
                        ),
                      ),
                      onPressed: widget.onAction,
                      icon: PhosphorIcon(
                        PhosphorIcons.downloadSimple(PhosphorIconsStyle.bold),
                        size: 16,
                        color: PS5HydraTheme.textSecondary,
                      ),
                      label: const Text(
                        'Baixar ROM',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontWeight: FontWeight.w700,
                        ),
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
