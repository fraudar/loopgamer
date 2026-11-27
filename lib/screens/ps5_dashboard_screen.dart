import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/game_asset_service.dart';
import '../services/igdb_steamgriddb_service.dart';
import '../services/rom_download_service.dart';
import '../services/update_service.dart';
import '../theme/ps5_hydra_theme.dart';
import 'pc_ports_screen.dart';
import '../widgets/animated_fade_slide.dart';
import '../widgets/animated_game_logo.dart';
import '../widgets/procedural_cover.dart';

/// Painel Console-first Horizontal (Landscape-only) estilo PS5:
/// - Fundo `#000000` com banner full-bleed da API e gradiente transparente -> `#000000`
/// - Cards em `obsidianGlass` (`#050B0D`) com único destaque neon verde (`#00F5A0`) para "Jogar Agora" e foco
/// - Carrosséis horizontais com cards verticais 3:4 (capa no topo + Clear Logo/tempo embaixo)
/// - Transições de título, Clear Logo e sinopse via `AnimatedSwitcher` (Fade + 10px slide, 300ms, `Curves.easeOut`)
class PS5DashboardScreen extends StatefulWidget {
  const PS5DashboardScreen({
    super.key,
    this.games,
    this.recentGames,
    this.favoriteGames,
    this.downloadStatuses = const {},
    this.userMeta = const UserLibraryMeta(),
    this.assetService,
    this.onPlayGame,
    this.onOpenHydraCatalog,
    this.onOpenGamepadStudio,
    this.onOpenShaders,
  });

  final List<EmulationGame>? games;
  final List<EmulationGame>? recentGames;
  final List<EmulationGame>? favoriteGames;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final UserLibraryMeta userMeta;
  final GameAssetService? assetService;
  final ValueChanged<EmulationGame>? onPlayGame;
  final VoidCallback? onOpenHydraCatalog;
  final VoidCallback? onOpenGamepadStudio;
  final VoidCallback? onOpenShaders;

  @override
  State<PS5DashboardScreen> createState() => _PS5DashboardScreenState();
}

class _PS5DashboardScreenState extends State<PS5DashboardScreen> {
  final ScrollController _featuredScrollController = ScrollController();
  final Map<int, GameAssets> _resolvedAssets = {};
  int _focusedIndex = 0;
  int _activeNavIndex = 0;

  GameAssetService get _assets =>
      widget.assetService ?? GameAssetService.instance;

  List<EmulationGame> get _games =>
      (widget.games != null && widget.games!.isNotEmpty)
          ? widget.games!
          : kVerifiedRealGamesCatalog;

  List<EmulationGame> get _recentGames =>
      widget.recentGames ?? _games.take(6).toList();

  List<EmulationGame> get _favoriteGames =>
      widget.favoriteGames ?? _games.skip(2).take(6).toList();

  @override
  void initState() {
    super.initState();
    _prefetchAssets();
    // Checagem silenciosa de update do GitHub Releases ao abrir o dashboard.
    unawaited(_checkForUpdates(silent: true));
  }

  @override
  void didUpdateWidget(covariant PS5DashboardScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.games != widget.games) {
      _prefetchAssets();
    }
  }

  void _prefetchAssets() {
    final pool = <EmulationGame>{
      ..._games.take(12),
      ..._recentGames.take(6),
      ..._favoriteGames.take(6),
    };
    for (final game in pool) {
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
          if (assets.hasBackground || assets.hasCover || assets.hasLogo) {
            setState(() => _resolvedAssets[game.igdbId] = assets);
          }
        }),
      );
    }
  }

  void _handleNavSelect(int index) {
    setState(() => _activeNavIndex = index);
    if (index == 1) {
      widget.onOpenHydraCatalog?.call();
    } else if (index == 2) {
      widget.onOpenGamepadStudio?.call();
    } else if (index == 3) {
      widget.onOpenShaders?.call();
    } else if (index == 4) {
      // "Ports" abre uma tela empilhada — volta para o dashboard depois.
      setState(() => _activeNavIndex = 0);
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const PcPortsScreen(),
        ),
      );
    }
  }

  /// Verifica updates no GitHub Releases. Com [silent], só avisa quando há
  /// versão nova; caso contrário mostra o resultado em SnackBar/dialog.
  Future<void> _checkForUpdates({bool silent = false}) async {
    if (!mounted) return;
    if (!silent) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Verificando atualizações...')),
      );
    }
    final result = await UpdateService.instance.checkForUpdate();
    if (!mounted) return;

    if (result.error != null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Falha ao verificar atualizações: ${result.error}'),
          ),
        );
      }
      return;
    }

    if (!result.hasUpdate) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.currentVersion.isEmpty
                  ? 'Você já está na versão mais recente.'
                  : 'LoopGamer ${result.currentVersion} é a versão mais recente.',
            ),
          ),
        );
      }
      return;
    }

    // Há update: pergunta antes de baixar o APK oficial do release.
    final update = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PS5HydraTheme.obsidianGlass,
        title: const Text(
          'Atualização disponível',
          style: TextStyle(color: PS5HydraTheme.textPrimary),
        ),
        content: Text(
          'LoopGamer ${result.latestVersion} está disponível '
          '(você está na ${result.currentVersion}).\n\n'
          'Baixar e instalar agora?',
          style: const TextStyle(color: PS5HydraTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Depois'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Atualizar'),
          ),
        ],
      ),
    );
    if (update == true && mounted) {
      await _downloadAndInstallUpdate();
    }
  }

  /// Baixa o APK do release mais recente e abre o instalador nativo.
  Future<void> _downloadAndInstallUpdate() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(content: Text('Baixando atualização...')),
    );
    try {
      final apk = await UpdateService.instance.downloadLatestApk(
        onProgress: (received, total) {
          if (total > 0 && received % (8 * 1024 * 1024) < 256 * 1024) {
            debugPrint(
              '[Update] Download: ${(received / total * 100).toStringAsFixed(0)}%',
            );
          }
        },
      );
      if (!mounted) return;
      final opened = await UpdateService.instance.installApk(apk);
      if (!opened && mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Não foi possível abrir o instalador.'),
          ),
        );
      }
    } catch (e) {
      debugPrint('[Update] Falha no auto-update: $e');
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Falha ao baixar atualização: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _featuredScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final games = _games;
    final safeIdx =
        games.isEmpty ? 0 : _focusedIndex.clamp(0, games.length - 1);
    final focusedGame = games.isNotEmpty ? games[safeIdx] : null;
    final focusedAssets =
        focusedGame != null ? _resolvedAssets[focusedGame.igdbId] : null;
    final bannerUrl =
        focusedAssets?.backgroundImageUrl ?? focusedGame?.heroBannerUrl;

    return Scaffold(
      backgroundColor: PS5HydraTheme.pitchBlack,
      body: LayoutBuilder(
        builder: (context, constraints) {
          return Stack(
            fit: StackFit.expand,
            children: [
              // 1. Banner full-bleed do jogo em foco
              if (bannerUrl != null && bannerUrl.isNotEmpty)
                AnimatedSwitcher(
                  duration: PS5HydraTheme.animStandard, // 300ms
                  switchInCurve: Curves.easeOut,
                  child: SizedBox.expand(
                    key: ValueKey<String>(bannerUrl),
                    child: CachedNetworkImage(
                      imageUrl: bannerUrl,
                      cacheManager: SessionMemoryCacheManager.instance,
                      fit: BoxFit.cover,
                      errorWidget: (_, __, ___) => const ColoredBox(
                        color: PS5HydraTheme.pitchBlack,
                      ),
                    ),
                  ),
                ),

              // 2. Gradiente full-bleed de transparente para #000000
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      stops: const [0.0, 0.35, 0.70, 1.0],
                      colors: [
                        PS5HydraTheme.pitchBlack.withOpacity(0.45),
                        PS5HydraTheme.pitchBlack.withOpacity(0.55),
                        PS5HydraTheme.pitchBlack.withOpacity(0.92),
                        PS5HydraTheme.pitchBlack,
                      ],
                    ),
                  ),
                ),
              ),

              // 3. Conteúdo horizontal rolável sem cortes
              SafeArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    PS5HydraTheme.space24,
                    PS5HydraTheme.space16,
                    PS5HydraTheme.space24,
                    PS5HydraTheme.space32,
                  ),
                  children: [
                    _PS5LandscapeTopBar(
                      currentIndex: _activeNavIndex,
                      onSelect: _handleNavSelect,
                      onCheckUpdates: _checkForUpdates,
                    ),
                    const SizedBox(height: PS5HydraTheme.space24),

                    if (focusedGame != null) ...[
                      _buildFocusedHeroBlock(context, focusedGame),
                      const SizedBox(height: PS5HydraTheme.space24),
                    ],

                    const _PS5SectionTitle(title: 'Destaques'),
                    const SizedBox(height: PS5HydraTheme.space12),
                    SizedBox(
                      height: 204,
                      child: ListView.builder(
                        controller: _featuredScrollController,
                        clipBehavior: Clip.none,
                        scrollDirection: Axis.horizontal,
                        itemCount: games.length,
                        itemBuilder: (context, idx) {
                          final game = games[idx];
                          final assets = _resolvedAssets[game.igdbId];
                          final isSelected = idx == safeIdx;
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: PS5HydraTheme.space12,
                            ),
                            child: _PS5VerticalGameCard(
                              game: game,
                              coverUrl:
                                  assets?.coverImageUrl ?? game.gridCoverUrl,
                              subtitleText: game.platformName,
                              isFocused: isSelected,
                              assetService: _assets,
                              onTap: () {
                                if (isSelected) {
                                  widget.onPlayGame?.call(game);
                                } else {
                                  setState(() => _focusedIndex = idx);
                                }
                              },
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: PS5HydraTheme.space24),
                    const _PS5SectionTitle(title: 'Continuar Jogando'),
                    const SizedBox(height: PS5HydraTheme.space12),
                    SizedBox(
                      height: 204,
                      child: ListView.builder(
                        clipBehavior: Clip.none,
                        scrollDirection: Axis.horizontal,
                        itemCount: _recentGames.length,
                        itemBuilder: (context, idx) {
                          final game = _recentGames[idx];
                          final assets = _resolvedAssets[game.igdbId];
                          final playtimeSec = widget.userMeta
                              .playtimeOf(game.igdbId)
                              .totalSeconds;
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: PS5HydraTheme.space12,
                            ),
                            child: _PS5VerticalGameCard(
                              game: game,
                              coverUrl:
                                  assets?.coverImageUrl ?? game.gridCoverUrl,
                              subtitleText: playtimeSec > 0
                                  ? formatPlaytime(playtimeSec)
                                  : 'Recente',
                              showClockIcon: true,
                              isFocused: false,
                              assetService: _assets,
                              onTap: () => widget.onPlayGame?.call(game),
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: PS5HydraTheme.space24),
                    const _PS5SectionTitle(title: 'Favoritos'),
                    const SizedBox(height: PS5HydraTheme.space12),
                    SizedBox(
                      height: 204,
                      child: ListView.builder(
                        clipBehavior: Clip.none,
                        scrollDirection: Axis.horizontal,
                        itemCount: _favoriteGames.length,
                        itemBuilder: (context, idx) {
                          final game = _favoriteGames[idx];
                          final assets = _resolvedAssets[game.igdbId];
                          return Padding(
                            padding: const EdgeInsets.only(
                              right: PS5HydraTheme.space12,
                            ),
                            child: _PS5VerticalGameCard(
                              game: game,
                              coverUrl:
                                  assets?.coverImageUrl ?? game.gridCoverUrl,
                              subtitleText: game.platformName,
                              isFocused: false,
                              assetService: _assets,
                              onTap: () => widget.onPlayGame?.call(game),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFocusedHeroBlock(BuildContext context, EmulationGame game) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(PS5HydraTheme.radiusCard),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          padding: const EdgeInsets.all(PS5HydraTheme.space24),
          decoration: PS5HydraTheme.surfaceGlass(
            radius: PS5HydraTheme.radiusCard,
            alpha: 0.78,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                flex: 7,
                child: AnimatedHeroFadeSlideSwitcher(
                  duration: PS5HydraTheme.animStandard, // 300ms
                  curve: Curves.easeOut,
                  slideFractionY: 0.10,
                  child: Column(
                    key: ValueKey<int>(game.igdbId),
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedGameLogo(
                        game: game,
                        assetService: _assets,
                        height: 48,
                        maxWidthFraction: 0.80,
                        enableStagger: false,
                        maxLines: 1,
                        fallbackStyle: PS5HydraTheme.displayTitleStyle,
                      ),
                      const SizedBox(height: PS5HydraTheme.space12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PS5HydraTheme.space12,
                          vertical: PS5HydraTheme.space8,
                        ),
                        decoration: BoxDecoration(
                          color: PS5HydraTheme.pitchBlack.withOpacity(0.65),
                          borderRadius:
                              BorderRadius.circular(PS5HydraTheme.radiusChip),
                          border: Border.all(color: PS5HydraTheme.borderSubtle),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              game.platformName,
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                            PS5HydraTheme.metaDivider(),
                            const Text(
                              'VULKAN',
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                            PS5HydraTheme.metaDivider(),
                            Text(
                              game.formattedSize,
                              style: PS5HydraTheme.metaMonoStyle,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: PS5HydraTheme.space12),
                      Text(
                        game.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: PS5HydraTheme.bodySynopsisStyle,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: PS5HydraTheme.space24),
              // Único destaque neon verde sólido (#00F5A0) para o botão Jogar
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: PS5HydraTheme.auroraSpringMint,
                  foregroundColor: PS5HydraTheme.textOnAurora,
                  minimumSize: const Size(176, 52),
                  padding: const EdgeInsets.symmetric(
                    horizontal: PS5HydraTheme.space24,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(PS5HydraTheme.radiusChip),
                  ),
                ),
                onPressed: () => widget.onPlayGame?.call(game),
                icon: PhosphorIcon(
                  PhosphorIcons.play(PhosphorIconsStyle.fill),
                  size: 18,
                ),
                label: const Text(
                  'Jogar Agora',
                  style: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PS5LandscapeTopBar extends StatelessWidget {
  const _PS5LandscapeTopBar({
    required this.currentIndex,
    required this.onSelect,
    this.onCheckUpdates,
  });

  final int currentIndex;
  final ValueChanged<int> onSelect;
  final VoidCallback? onCheckUpdates;

  static const _tabs = ['Jogos', 'Hydra', 'Gamepad', 'Shaders', 'Ports'];
  static const double _tabWidth = 104.0;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'loopgamer',
          style: TextStyle(
            fontFamily: 'ReadexPro',
            fontWeight: FontWeight.w700,
            fontSize: 20,
            letterSpacing: -0.5,
            color: PS5HydraTheme.textPrimary,
          ),
        ),
        Flexible(
          child: Container(
            padding: const EdgeInsets.all(PS5HydraTheme.space4),
            decoration: BoxDecoration(
              color: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: PS5HydraTheme.borderSubtle),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Stack(
                children: [
                  AnimatedPositioned(
                    duration: PS5HydraTheme.animStandard, // 300ms
                    curve: Curves.easeOut,
                    left: currentIndex * _tabWidth + 18,
                    bottom: 0,
                    width: _tabWidth - 36,
                    height: 2,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: PS5HydraTheme.auroraSpringMint,
                      ),
                    ),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(_tabs.length, (i) {
                      final active = i == currentIndex;
                      return SizedBox(
                        width: _tabWidth,
                        child: Semantics(
                          button: true,
                          selected: active,
                          label: _tabs[i],
                          child: InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => onSelect(i),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10),
                              child: Text(
                                _tabs[i],
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontWeight: active
                                      ? FontWeight.w700
                                      : FontWeight.w600,
                                  fontSize: 13,
                                  color: active
                                      ? PS5HydraTheme.textPrimary
                                      : PS5HydraTheme.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ),
            ),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onCheckUpdates != null)
              Padding(
                padding: const EdgeInsets.only(right: PS5HydraTheme.space8),
                child: IconButton(
                  tooltip: 'Verificar atualizações',
                  onPressed: onCheckUpdates,
                  icon: const Icon(
                    Icons.system_update_alt_rounded,
                    color: PS5HydraTheme.auroraSpringMint,
                    size: 20,
                  ),
                ),
              ),
            Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PS5HydraTheme.space12,
            vertical: PS5HydraTheme.space8,
          ),
          decoration: BoxDecoration(
            color: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
            borderRadius: BorderRadius.circular(PS5HydraTheme.radiusChip),
            border: Border.all(color: PS5HydraTheme.borderSubtle),
          ),
          child: const Text(
            'CONSOLE HORIZONTAL',
            style: PS5HydraTheme.metaMonoStyle,
          ),
            ),
          ],
        ),
      ],
    );
  }
}

class _PS5SectionTitle extends StatelessWidget {
  const _PS5SectionTitle({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 16,
        color: PS5HydraTheme.textPrimary,
      ),
    );
  }
}

/// Card Vertical PS5 (3:4): capa no topo preenchendo o card, fundo escuro com fade,
/// Clear Logo (ou título fallback) + metadado/tempo embaixo,
/// e foco `AnimatedScale(1.05x)` + `boxShadow` neon `#00F5A0`.
class _PS5VerticalGameCard extends StatefulWidget {
  const _PS5VerticalGameCard({
    required this.game,
    required this.subtitleText,
    required this.isFocused,
    required this.assetService,
    required this.onTap,
    this.coverUrl,
    this.showClockIcon = false,
  });

  final EmulationGame game;
  final String? coverUrl;
  final String subtitleText;
  final bool isFocused;
  final GameAssetService assetService;
  final VoidCallback onTap;
  final bool showClockIcon;

  @override
  State<_PS5VerticalGameCard> createState() => _PS5VerticalGameCardState();
}

class _PS5VerticalGameCardState extends State<_PS5VerticalGameCard> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isFocused || _hovered || _focused;

    return Semantics(
      button: true,
      selected: active,
      label: '${widget.game.name}, ${widget.subtitleText}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedScale(
          scale: active ? 1.05 : 1.0,
          duration: PS5HydraTheme.animFast, // 200ms
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: PS5HydraTheme.animMedium,
            curve: Curves.easeOut,
            width: 144,
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
                        imageUrl: widget.coverUrl,
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
                              Color(0xBB000000),
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
                              assetService: widget.assetService,
                              height: 24,
                              maxWidthFraction: 1.0,
                              enableStagger: false,
                              maxLines: 1,
                              fallbackStyle: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontWeight: FontWeight.w700,
                                fontSize: 12.5,
                                color: PS5HydraTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(height: PS5HydraTheme.space4),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (widget.showClockIcon) ...[
                                  PhosphorIcon(
                                    PhosphorIcons.clock(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    size: 10,
                                    color: active
                                        ? PS5HydraTheme.auroraSpringMint
                                        : PS5HydraTheme.textSecondary,
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Flexible(
                                  child: Text(
                                    widget.subtitleText,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: PS5HydraTheme.metaMonoStyle.copyWith(
                                      fontSize: 10,
                                    ),
                                  ),
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
      ),
    );
  }
}
