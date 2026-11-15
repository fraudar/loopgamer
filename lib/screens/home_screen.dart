import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/cover_cache_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import 'game_detail_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.featuredGames,
    required this.popularGames,
    required this.downloadStatuses,
    required this.downloadService,
    required this.onStatusUpdated,
    required this.onLaunchGame,
    this.userMeta = const UserLibraryMeta(),
    this.onUserMetaChanged,
    this.onOpenSearchTab,
    this.onOpenLibraryTab,
  });

  final List<EmulationGame> featuredGames;
  final List<EmulationGame> popularGames;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final RomDownloadService downloadService;
  final void Function(EmulationGame game, RomDownloadStatus status)
      onStatusUpdated;
  final void Function(EmulationGame game, String localRomPath) onLaunchGame;
  final UserLibraryMeta userMeta;
  final ValueChanged<UserLibraryMeta>? onUserMetaChanged;
  final VoidCallback? onOpenSearchTab;
  final VoidCallback? onOpenLibraryTab;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedFeaturedIndex = 0;
  String _selectedPlatformSlug = 'todos';

  void _openDetails(EmulationGame game) {
    GameDetailScreen.showAsModal(
      context,
      game: game,
      downloadService: widget.downloadService,
      initialStatus:
          widget.downloadStatuses[game.igdbId] ?? const RomDownloadStatus(),
      onStatusChanged: (status) => widget.onStatusUpdated(game, status),
      onPlayPressed: (romPath) => widget.onLaunchGame(game, romPath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height && size.width >= 560;

    final shelfGames = widget.featuredGames.isNotEmpty
        ? widget.featuredGames
        : widget.popularGames;
    final safeIndex = shelfGames.isEmpty
        ? 0
        : _selectedFeaturedIndex.clamp(0, shelfGames.length - 1);

    final filteredCatalog = _selectedPlatformSlug == 'todos'
        ? widget.popularGames
        : widget.popularGames
            .where(
              (g) =>
                  g.platformSlug.toLowerCase() ==
                  _selectedPlatformSlug.toLowerCase(),
            )
            .toList();

    final content = isLandscape
        ? _buildGameHubLandscapeHome(
            context,
            shelfGames: shelfGames,
            safeIndex: safeIndex,
            filteredCatalog: filteredCatalog,
          )
        : _buildGameHubPortraitHome(
            context,
            shelfGames: shelfGames,
            safeIndex: safeIndex,
            filteredCatalog: filteredCatalog,
          );

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.gameButtonRight1) {
            if (shelfGames.isNotEmpty) {
              setState(() {
                _selectedFeaturedIndex =
                    (_selectedFeaturedIndex + 1) % shelfGames.length;
              });
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.gameButtonLeft1) {
            if (shelfGames.isNotEmpty) {
              setState(() {
                _selectedFeaturedIndex =
                    (_selectedFeaturedIndex - 1 + shelfGames.length) %
                        shelfGames.length;
              });
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.gameButtonA ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (shelfGames.isNotEmpty) {
              _openDetails(shelfGames[safeIndex]);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.gameButtonY) {
            widget.onOpenSearchTab?.call();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: content,
    );
  }

  // ==========================================================================
  // MODO DEITADO (LANDSCAPE) — EXATAMENTE NO ESTILO GAMEHUB (IMAGEM 1)
  // ==========================================================================
  Widget _buildGameHubLandscapeHome(
    BuildContext context, {
    required List<EmulationGame> shelfGames,
    required int safeIndex,
    required List<EmulationGame> filteredCatalog,
  }) {
    final activeGame = shelfGames.isNotEmpty ? shelfGames[safeIndex] : null;
    final recentIds = widget.userMeta.recentlyPlayedIds();
    final recentGames = recentIds
        .map((id) => widget.popularGames.firstWhere(
              (g) => g.igdbId == id,
              orElse: () => EmulationGame.empty(),
            ))
        .where((g) => g.igdbId != 0)
        .toList();

    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Artwork atmosférica em tela cheia do jogo selecionado (GameHub Backdrop)
          if (activeGame != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 350),
              child: SizedBox.expand(
                key: ValueKey<int>(activeGame.igdbId),
                child: LoopCoverImage(
                  url: activeGame.resolvedHeroBannerUrl,
                  fit: BoxFit.cover,
                  platformSlug: activeGame.platformSlug,
                  gameTitle: activeGame.name,
                ),
              ),
            ),

          // Vinheta cinematográfica estilo GameHub para leitura perfeita dos cards
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

          // 2. Conteúdo rolável suave em modo Landscape
          SafeArea(
            top: false,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(28, 12, 28, 22),
              children: [
                // Título invisível/compacto mantendo semântica e identidade LOOPGAMER
                Row(
                  children: [
                    const Text(
                      'LOOPGAMER',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.6,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Destaques da Coleção',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 14),
                    // Filtros de console estilo ícones/pílulas GameHub
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: kRommPlatforms.map((plat) {
                          final active = _selectedPlatformSlug == plat.slug;
                          return Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: GestureDetector(
                              onTap: () => setState(
                                () => _selectedPlatformSlug = plat.slug,
                              ),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: active
                                      ? Colors.white.withOpacity(0.20)
                                      : Colors.black.withOpacity(0.38),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: active
                                        ? Colors.white.withOpacity(0.65)
                                        : Colors.white.withOpacity(0.10),
                                  ),
                                ),
                                child: Text(
                                  plat.shortName,
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 10.5,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: active
                                        ? Colors.white
                                        : HydraTokens.textSecondary,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 12),

                // Carrossel Principal Widescreen GameHub (Card ativo maior à esquerda + cards vizinhos alinhados na base)
                SizedBox(
                  height: 162,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: shelfGames.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, idx) {
                      final game = shelfGames[idx];
                      final isFocused = idx == safeIndex;
                      final status = widget.downloadStatuses[game.igdbId] ??
                          const RomDownloadStatus();
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
                          onActionTap: () => _openDetails(game),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 22),

                // Jogados Recentemente (Modo Landscape)
                if (recentGames.isNotEmpty) ...[
                  Row(
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.clockCounterClockwise(
                          PhosphorIconsStyle.bold,
                        ),
                        size: 15,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Jogados Recentemente',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
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
                        return GestureDetector(
                          onTap: () => _openDetails(game),
                          child: Container(
                            width: 172,
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.55),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.12),
                              ),
                            ),
                            child: Row(
                              children: [
                                ClipRRect(
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(11),
                                  ),
                                  child: SizedBox(
                                    width: 72,
                                    height: double.infinity,
                                    child: LoopCoverImage(
                                      url: game.resolvedGridCoverUrl,
                                      fit: BoxFit.cover,
                                      platformSlug: game.platformSlug,
                                      gameTitle: game.name,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          game.name,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w700,
                                            color: Colors.white,
                                          ),
                                        ),
                                        const SizedBox(height: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.white.withOpacity(0.10),
                                            borderRadius:
                                                BorderRadius.circular(6),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              PhosphorIcon(
                                                PhosphorIcons.clock(
                                                  PhosphorIconsStyle.bold,
                                                ),
                                                size: 10,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                formatPlaytime(playtimeSec),
                                                style: const TextStyle(
                                                  fontFamily: 'JetBrainsMono',
                                                  fontSize: 9.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 18),
                ],

                // Segunda fileira estilo "PC games, cross-border playing" da Imagem 1
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
                const SizedBox(height: 12),

                SizedBox(
                  height: 126,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: filteredCatalog.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 14),
                    itemBuilder: (context, idx) {
                      final game = filteredCatalog[idx];
                      final status = widget.downloadStatuses[game.igdbId] ??
                          const RomDownloadStatus();
                      return _GameHubLandscapeSecondaryCard(
                        game: game,
                        status: status,
                        onTap: () => _openDetails(game),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),

          // 3. Barra flutuante inferior direita de atalhos de controle (Igual à Imagem 1: Y Search, LB/RB Switch, Menu)
          Positioned(
            right: 24,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: const Color(0xCC14131B),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withOpacity(0.12)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: widget.onOpenSearchTab,
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
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: () {
                      final nextIdx =
                          (safeIndex + 1) % (shelfGames.isEmpty ? 1 : shelfGames.length);
                      setState(() => _selectedFeaturedIndex = nextIdx);
                    },
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
                  const SizedBox(width: 14),
                  GestureDetector(
                    onTap: () {
                      if (activeGame != null) _openDetails(activeGame);
                    },
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
            ),
          ),
        ],
      ),
    );
  }

  // ==========================================================================
  // MODO EM PÉ (PORTRAIT) — EXATAMENTE NO ESTILO GAMEHUB (IMAGEM 3)
  // ==========================================================================
  Widget _buildGameHubPortraitHome(
    BuildContext context, {
    required List<EmulationGame> shelfGames,
    required int safeIndex,
    required List<EmulationGame> filteredCatalog,
  }) {
    final heroGame = shelfGames.isNotEmpty ? shelfGames[safeIndex] : null;
    final heroStatus = heroGame != null
        ? (widget.downloadStatuses[heroGame.igdbId] ??
            const RomDownloadStatus())
        : const RomDownloadStatus();
    final recentIds = widget.userMeta.recentlyPlayedIds();
    final recentGames = recentIds
        .map((id) => widget.popularGames.firstWhere(
              (g) => g.igdbId == id,
              orElse: () => EmulationGame.empty(),
            ))
        .where((g) => g.igdbId != 0)
        .toList();

    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 1. Top Search Pill + Botão Lateral (Igual à Imagem 3: "Find your game" + ícone à direita)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
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
                        const Spacer(),
                        if (widget.downloadStatuses.values.any(
                          (s) => s.state == RomActionState.downloading,
                        ))
                          GestureDetector(
                            onTap: widget.onOpenLibraryTab,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: HydraTokens.secondaryTeal
                                    .withOpacity(0.18),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: HydraTokens.secondaryTeal
                                      .withOpacity(0.5),
                                ),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: HydraTokens.secondaryTeal,
                                    ),
                                  ),
                                  SizedBox(width: 6),
                                  Text(
                                    'Baixando em 2º plano',
                                    style: TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.w600,
                                      color: HydraTokens.secondaryTeal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: widget.onOpenSearchTab,
                            child: Container(
                              height: 44,
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
                        const SizedBox(width: 12),
                        GestureDetector(
                          onTap: widget.onOpenLibraryTab,
                          child: Container(
                            width: 44,
                            height: 44,
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
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 2. Hero Card Principal Estilo GameHub Portrait (Igual ao card "Hollow Knight: Silksong" da Imagem 3)
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
                              platformSlug: heroGame.platformSlug,
                              gameTitle: heroGame.name,
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
                            // Selo "HOT TOP" + Botão de trocar destaque
                            Positioned(
                              left: 16,
                              right: 16,
                              bottom: 14,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withOpacity(0.65),
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
                                            Text(
                                              'HOT TOP ${safeIndex + 1} • ${heroGame.platformName}',
                                              style: const TextStyle(
                                                fontFamily: 'ReadexPro',
                                                fontSize: 10.5,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const Spacer(),
                                      // Botão discreto para alternar jogo em destaque
                                      GestureDetector(
                                        onTap: () {
                                          final next = (safeIndex + 1) %
                                              shelfGames.length;
                                          setState(() =>
                                              _selectedFeaturedIndex = next);
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.all(6),
                                          decoration: BoxDecoration(
                                            color:
                                                Colors.black.withOpacity(0.55),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white
                                                  .withOpacity(0.15),
                                            ),
                                          ),
                                          child: PhosphorIcon(
                                            PhosphorIcons.arrowsClockwise(
                                              PhosphorIconsStyle.bold,
                                            ),
                                            size: 14,
                                            color: HydraTokens.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
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
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 9,
                                                    vertical: 3.5,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: const Color(
                                                      0xFF332411,
                                                    ),
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
                                                      Text(
                                                        heroStatus.state ==
                                                                RomActionState
                                                                    .readyToPlay
                                                            ? 'Instalado'
                                                            : heroStatus.state ==
                                                                    RomActionState
                                                                        .downloading
                                                                ? 'Baixando ${(heroStatus.progress * 100).toStringAsFixed(0)}%'
                                                                : 'Featured',
                                                        style: const TextStyle(
                                                          fontFamily:
                                                              'ReadexPro',
                                                          fontSize: 10.5,
                                                          fontWeight:
                                                              FontWeight.w700,
                                                          color: Colors.white,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
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

            // Jogados Recentemente (Modo Portrait)
            if (recentGames.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 12, 18, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          PhosphorIcon(
                            PhosphorIcons.clockCounterClockwise(
                              PhosphorIconsStyle.bold,
                            ),
                            size: 15,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Jogados Recentemente',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
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
                            return GestureDetector(
                              onTap: () => _openDetails(game),
                              child: Container(
                                width: 170,
                                decoration: BoxDecoration(
                                  color: HydraTokens.bgNearBlack,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: HydraTokens.borderSubtle10,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius:
                                          const BorderRadius.horizontal(
                                        left: Radius.circular(11),
                                      ),
                                      child: SizedBox(
                                        width: 68,
                                        height: double.infinity,
                                        child: LoopCoverImage(
                                          url: game.resolvedGridCoverUrl,
                                          fit: BoxFit.cover,
                                          platformSlug: game.platformSlug,
                                          gameTitle: game.name,
                                        ),
                                      ),
                                    ),
                                    Expanded(
                                      child: Padding(
                                        padding: const EdgeInsets.all(8),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Text(
                                              game.name,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontFamily: 'ReadexPro',
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.white,
                                              ),
                                            ),
                                            const SizedBox(height: 5),
                                            Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                PhosphorIcon(
                                                  PhosphorIcons.clock(
                                                    PhosphorIconsStyle.bold,
                                                  ),
                                                  size: 10,
                                                  color: Colors.white,
                                                ),
                                                const SizedBox(width: 4),
                                                Text(
                                                  formatPlaytime(playtimeSec),
                                                  style: const TextStyle(
                                                    fontFamily: 'JetBrainsMono',
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w700,
                                                    color: Colors.white,
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
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            // 3. Seção "Destaques da Coleção" / "Your Next Favorite" estilo GameHub Portrait (Imagem 3)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 6),
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
                    SizedBox(
                      height: 188,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        itemCount: shelfGames.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 12),
                        itemBuilder: (context, idx) {
                          final game = shelfGames[idx];
                          final status = widget.downloadStatuses[game.igdbId] ??
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
                  ],
                ),
              ),
            ),

            // 4. Filtro Rápido de Plataformas ("Catálogo por Console")
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
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
                    const SizedBox(height: 12),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: kRommPlatforms.map((plat) {
                          final active = _selectedPlatformSlug == plat.slug;
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: GestureDetector(
                              onTap: () => setState(
                                () => _selectedPlatformSlug = plat.slug,
                              ),
                              child: AnimatedContainer(
                                duration: const Duration(milliseconds: 160),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 7.5,
                                ),
                                decoration: BoxDecoration(
                                  color: active
                                      ? HydraTokens.primaryAurora
                                      : HydraTokens.bgNearBlack,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: active
                                        ? HydraTokens.primaryAurora
                                        : HydraTokens.borderSubtle8,
                                  ),
                                ),
                                child: Text(
                                  plat.shortName,
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: active
                                        ? HydraTokens.bgPureBlack
                                        : HydraTokens.textSecondary,
                                  ),
                                ),
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

            // 5. Grade Responsiva GameHub (Nunca fica gigante ao girar a tela)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 2, 18, 28),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 185,
                  mainAxisSpacing: 14,
                  crossAxisSpacing: 14,
                  childAspectRatio: 0.66,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, index) {
                    final game = filteredCatalog[index];
                    final status = widget.downloadStatuses[game.igdbId] ??
                        const RomDownloadStatus();
                    return RommCoverGridCard(
                      game: game,
                      status: status,
                      onTap: () => _openDetails(game),
                    );
                  },
                  childCount: filteredCatalog.length,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Card Widescreen Principal do Carrossel Landscape GameHub (Imagem 1)
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
    final isReady = status.state == RomActionState.readyToPlay;

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
                ? Colors.white.withOpacity(0.85)
                : Colors.white.withOpacity(0.14),
            width: isFocused ? 1.8 : 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(isFocused ? 0.68 : 0.45),
              blurRadius: isFocused ? 20 : 10,
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
                platformSlug: game.platformSlug,
                gameTitle: game.name,
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
                  bottom: 12,
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
                      const SizedBox(height: 8),
                      GestureDetector(
                        onTap: onActionTap,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const _ControllerKeyBadge(label: 'A'),
                            const SizedBox(width: 7),
                            Text(
                              isReady
                                  ? 'Jogar Agora'
                                  : isDownloading
                                      ? 'Baixando ${(status.progress * 100).toStringAsFixed(0)}%'
                                      : 'Ver Detalhes',
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ],
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
                            ? 'Baixando ${(status.progress * 100).toStringAsFixed(0)}%'
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

/// Card Widescreen da Segunda Fileira em Landscape (Imagem 1 — "PC games, cross-border playing")
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

    return GestureDetector(
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
                platformSlug: game.platformSlug,
                gameTitle: game.name,
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
                            ? '${(status.progress * 100).toStringAsFixed(0)}%'
                            : game.platformName,
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
    );
  }
}

/// Pôster Vertical da fileira "Your Next Favorite" no Modo Portrait (Imagem 3)
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

    return GestureDetector(
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
                        ? Colors.white.withOpacity(0.75)
                        : Colors.white.withOpacity(0.10),
                    width: isSelected ? 1.6 : 1.0,
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(13),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LoopCoverImage(
                        url: game.resolvedGridCoverUrl,
                        fit: BoxFit.cover,
                        platformSlug: game.platformSlug,
                        gameTitle: game.name,
                      ),
                      if (isDownloading)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: LinearProgressIndicator(
                            value: status.progress,
                            minHeight: 4,
                            backgroundColor: Colors.black54,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              HydraTokens.secondaryTeal,
                            ),
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
    this.onLongPress,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final isDownloaded = status.state == RomActionState.readyToPlay;
    final isDownloading = status.state == RomActionState.downloading;

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
                  platformSlug: game.platformSlug,
                  gameTitle: game.name,
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Baixando...',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              Text(
                                '${(status.progress * 100).toStringAsFixed(0)}%',
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 10,
                                  fontWeight: FontWeight.w700,
                                  color: HydraTokens.secondaryTeal,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: status.progress,
                              minHeight: 4,
                              backgroundColor: HydraTokens.surfaceElevated2,
                              valueColor: const AlwaysStoppedAnimation<Color>(
                                HydraTokens.secondaryTeal,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
            decoration: const BoxDecoration(
              color: HydraTokens.bgNearBlack,
              border: Border(
                top: BorderSide(color: HydraTokens.borderSubtle8),
              ),
            ),
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
                    Container(
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
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isDownloading
                            ? '${(status.progress * 100).toStringAsFixed(0)}%'
                            : game.formattedSize,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 10.5,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ),
                    PhosphorIcon(
                      isDownloaded
                          ? PhosphorIcons.playCircle(PhosphorIconsStyle.fill)
                          : PhosphorIcons.downloadSimple(
                              PhosphorIconsStyle.bold,
                            ),
                      color: isDownloaded
                          ? Colors.white
                          : HydraTokens.textSecondary,
                      size: 16,
                    ),
                  ],
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
          fontWeight: FontWeight.w800,
          color: HydraTokens.bgPureBlack,
        ),
      ),
    );
  }
}


