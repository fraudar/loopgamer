import 'dart:async';

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

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.downloadedGames,
    required this.downloadingGames,
    required this.downloadStatuses,
    required this.onImportNewRomPressed,
    this.onImportExternalIsoPressed,
    required this.onLaunchGame,
    required this.onRemoveGame,
    required this.onCancelDownload,
    this.userMeta = const UserLibraryMeta(),
    this.onUserMetaChanged,
    this.isActive = true,
  });

  final List<EmulationGame> downloadedGames;
  final List<EmulationGame> downloadingGames;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final VoidCallback onImportNewRomPressed;
  final VoidCallback? onImportExternalIsoPressed;
  final void Function(EmulationGame game, String localRomPath) onLaunchGame;
  final Future<void> Function(EmulationGame game) onRemoveGame;
  final void Function(EmulationGame game) onCancelDownload;
  final UserLibraryMeta userMeta;
  final ValueChanged<UserLibraryMeta>? onUserMetaChanged;
  final bool isActive;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final FocusNode _screenFocusNode = FocusNode(
    debugLabel: 'LibraryScreenFocus',
  );
  final ScrollController _landscapeScrollController = ScrollController();

  final Map<int, GameAssets> _resolvedAssets = {};
  int _selectedIndex = 0;
  String _activeFilter = 'todos';
  bool _hasFocus = false;
  bool _gamepadNavActive = false;
  double _landscapeCardExtent = 146.0;

  @override
  void initState() {
    super.initState();
    _prefetchAssetsFor(_allLibraryItems);
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _screenFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _prefetchAssetsFor(_allLibraryItems);
    if (!oldWidget.isActive && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive) {
          _screenFocusNode.requestFocus();
        }
      });
    } else if (oldWidget.isActive && !widget.isActive) {
      if (_screenFocusNode.hasFocus) {
        _screenFocusNode.unfocus();
      }
    }
  }

  @override
  void dispose() {
    _screenFocusNode.dispose();
    _landscapeScrollController.dispose();
    super.dispose();
  }

  void _prefetchAssetsFor(List<EmulationGame> games) {
    for (final game in games.take(12)) {
      if (_resolvedAssets.containsKey(game.igdbId)) continue;
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
          if (mounted &&
              (assets.hasBackground || assets.hasCover || assets.hasLogo)) {
            setState(() => _resolvedAssets[game.igdbId] = assets);
          }
        }),
      );
    }
  }

  List<EmulationGame> get _allLibraryItems {
    final Map<int, EmulationGame> map = {};
    for (final g in widget.downloadingGames) {
      map[g.igdbId] = g;
    }
    for (final g in widget.downloadedGames) {
      map[g.igdbId] = g;
    }
    return map.values.toList();
  }

  List<EmulationGame> get _filteredItems {
    final all = _allLibraryItems;
    if (_activeFilter == 'favoritos') {
      return all.where((g) => widget.userMeta.isFavorite(g.igdbId)).toList();
    }
    if (_activeFilter == 'recentes') {
      final list = List<EmulationGame>.from(all);
      list.sort((a, b) {
        final pa = widget.userMeta.playtimeOf(a.igdbId).lastPlayed;
        final pb = widget.userMeta.playtimeOf(b.igdbId).lastPlayed;
        if (pa == null && pb == null) return 0;
        if (pa == null) return 1;
        if (pb == null) return -1;
        return pb.compareTo(pa);
      });
      return list;
    }
    if (_activeFilter != 'todos') {
      final ids = widget.userMeta.collections[_activeFilter] ?? const [];
      return all.where((g) => ids.contains(g.igdbId)).toList();
    }
    return all;
  }

  void _selectIndex(
    int nextIndex, {
    bool viaGamepad = false,
  }) {
    setState(() {
      _selectedIndex = nextIndex;
      _gamepadNavActive = viaGamepad;
    });
    _scrollToSelected(nextIndex);
  }

  void _scrollToSelected(int idx) {
    final controller = _landscapeScrollController;
    if (!controller.hasClients) return;

    final itemExtent = _landscapeCardExtent;
    final viewport = controller.position.viewportDimension;
    final targetStart = idx * itemExtent;
    final targetEnd = targetStart + itemExtent;
    final currentOffset = controller.offset;

    double? nextOffset;
    if (targetStart < currentOffset) {
      nextOffset = targetStart;
    } else if (targetEnd > currentOffset + viewport) {
      nextOffset = targetEnd - viewport;
    }

    if (nextOffset != null) {
      final clamped = nextOffset.clamp(
        0.0,
        controller.position.maxScrollExtent,
      );
      unawaited(
        controller.animateTo(
          clamped,
          duration: PS5HydraTheme.animMedium,
          curve: Curves.easeOut,
        ),
      );
    }
  }

  void _toggleFavorite(EmulationGame game) {
    HapticFeedback.lightImpact();
    final next = widget.userMeta.toggleFavorite(game.igdbId);
    widget.onUserMetaChanged?.call(next);
  }

  Future<void> _showCreateCollectionDialog() async {
    final controller = TextEditingController();
    try {
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: HydraTokens.bgNearBlack,
          shape: HydraTokens.dialogShape,
          title: Text(
            'Nova Coleção',
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          content: SingleChildScrollView(
            child: TextField(
              controller: controller,
              autofocus: true,
              style: const TextStyle(
                color: HydraTokens.textPrimary,
                fontFamily: 'ReadexPro',
              ),
              decoration: InputDecoration(
                hintText: 'Ex: Melhores RPGs, Luta...',
                hintStyle: const TextStyle(color: HydraTokens.textMuted),
                filled: true,
                fillColor: HydraTokens.surfaceCatalog,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                'Cancelar',
                style: TextStyle(color: HydraTokens.textSecondary),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: HydraTokens.primaryAurora,
                foregroundColor: HydraTokens.bgPureBlack,
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: const Text(
                'Criar',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (name != null && name.isNotEmpty) {
        final next = widget.userMeta.createCollection(name);
        widget.onUserMetaChanged?.call(next);
        setState(() {
          _activeFilter = name;
          _selectedIndex = 0;
        });
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _showManageCollectionsDialog(EmulationGame game) async {
    final cols = widget.userMeta.collections.keys.toList();
    if (cols.isEmpty) {
      await _showCreateCollectionDialog();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final maxH = MediaQuery.sizeOf(ctx).height * 0.48;
          return AlertDialog(
            backgroundColor: HydraTokens.bgNearBlack,
            shape: HydraTokens.dialogShape,
            title: Text(
              'Coleções: ${game.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
            ),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 420,
                maxHeight: maxH.clamp(120.0, 360.0),
              ),
              child: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final col in cols)
                      CheckboxListTile(
                        activeColor: HydraTokens.primaryAurora,
                        checkColor: HydraTokens.bgPureBlack,
                        title: Text(
                          col,
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        value: widget.userMeta.collections[col]
                                ?.contains(game.igdbId) ??
                            false,
                        onChanged: (val) {
                          final next = widget.userMeta.setInCollection(
                            col,
                            game.igdbId,
                            val ?? false,
                          );
                          widget.onUserMetaChanged?.call(next);
                          setDialogState(() {});
                          setState(() {});
                        },
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _showCreateCollectionDialog();
                },
                child: const Text(
                  '+ Nova Coleção',
                  style: TextStyle(color: HydraTokens.primaryAurora),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: HydraTokens.primaryAurora,
                  foregroundColor: HydraTokens.bgPureBlack,
                  minimumSize: const Size(48, 48),
                ),
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Concluir'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showLongPressOptions(EmulationGame game) async {
    unawaited(HapticFeedback.mediumImpact());
    final status = widget.downloadStatuses[game.igdbId];
    final romPath = status?.localPath ?? game.localRomPath;
    final isDownloading = status?.state == RomActionState.downloading;

    final action = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final maxHeight = MediaQuery.sizeOf(ctx).height * 0.88;
        final isFav = widget.userMeta.isFavorite(game.igdbId);

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: HydraTokens.bgNearBlack,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: HydraTokens.borderSubtle10),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.20),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        SizedBox(
                          width: 46,
                          height: 64,
                          child: ProceduralCover(
                            title: game.name,
                            platformName: game.platformName,
                            gameId: game.igdbId,
                            imageUrl: _resolvedAssets[game.igdbId]
                                    ?.coverImageUrl ??
                                game.gridCoverUrl ??
                                game.resolvedGridCoverUrl,
                            borderRadius: 8,
                            compact: true,
                            showBottomLabel: false,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                game.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: HydraTokens.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${game.platformName} • ${game.formattedSize}',
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 12,
                                  color: HydraTokens.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    const Divider(color: HydraTokens.borderSubtle8, height: 1),
                    const SizedBox(height: 10),
                    if (!isDownloading && romPath != null)
                      ListTile(
                        minTileHeight: 48,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 8),
                        leading: PhosphorIcon(
                          PhosphorIcons.gameController(PhosphorIconsStyle.fill),
                          color: HydraTokens.textPrimary,
                        ),
                        title: const Text(
                          'Jogar Agora',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        onTap: () => Navigator.of(ctx).pop('play'),
                      ),
                    ListTile(
                      minTileHeight: 48,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: PhosphorIcon(
                        isFav
                            ? PhosphorIcons.star(PhosphorIconsStyle.fill)
                            : PhosphorIcons.star(PhosphorIconsStyle.regular),
                        color: isFav
                            ? HydraTokens.primaryAurora
                            : HydraTokens.textSecondary,
                      ),
                      title: Text(
                        isFav
                            ? 'Remover dos Favoritos'
                            : 'Adicionar aos Favoritos',
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                      onTap: () => Navigator.of(ctx).pop('toggle_fav'),
                    ),
                    ListTile(
                      minTileHeight: 48,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: PhosphorIcon(
                        PhosphorIcons.folders(PhosphorIconsStyle.regular),
                        color: HydraTokens.textPrimary,
                      ),
                      title: const Text(
                        'Organizar em Coleções...',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                      onTap: () => Navigator.of(ctx).pop('collections'),
                    ),
                    ListTile(
                      minTileHeight: 48,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      leading: PhosphorIcon(
                        PhosphorIcons.trash(PhosphorIconsStyle.fill),
                        color: HydraTokens.accentDanger,
                      ),
                      title: Text(
                        isDownloading
                            ? 'Cancelar Download e Remover'
                            : 'Remover Jogo da Biblioteca',
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.accentDanger,
                        ),
                      ),
                      subtitle: const Text(
                        'Apaga o arquivo ROM baixado do armazenamento local',
                        style: TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11.5,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                      onTap: () => Navigator.of(ctx).pop('remove'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    if (action == 'play' && romPath != null) {
      widget.onLaunchGame(game, romPath);
    } else if (action == 'toggle_fav') {
      _toggleFavorite(game);
    } else if (action == 'collections') {
      await _showManageCollectionsDialog(game);
    } else if (action == 'remove') {
      await _confirmAndRemoveGame(game);
    }
  }

  Future<void> _confirmAndRemoveGame(EmulationGame game) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: HydraTokens.bgNearBlack,
          shape: HydraTokens.dialogShape,
          title: Text(
            'Confirmar Remoção',
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          content: SingleChildScrollView(
            child: Text(
              'Tem certeza que deseja remover "${game.name}" da sua biblioteca e apagar o arquivo do dispositivo?',
              style: const TextStyle(
                fontFamily: 'Rubik',
                fontSize: 13.5,
                height: 1.45,
                color: HydraTokens.textSecondary,
              ),
            ),
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
              ),
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text(
                'Cancelar',
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontWeight: FontWeight.w600,
                  color: HydraTokens.textSecondary,
                ),
              ),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: HydraTokens.accentDanger,
                foregroundColor: HydraTokens.textPrimary,
                minimumSize: const Size(48, 48),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'Remover Jogo',
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        );
      },
    );

    if (confirmed == true && mounted) {
      await widget.onRemoveGame(game);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: HydraTokens.surfaceElevated1,
            behavior: SnackBarBehavior.floating,
            content: Text(
              '${game.name} foi removido da biblioteca.',
              style: const TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 12.5,
                color: HydraTokens.textPrimary,
              ),
            ),
          ),
        );
      }
    }
  }

  Widget _buildEmptyLibraryState() {
    final hasAnyGames = _allLibraryItems.isNotEmpty;
    if (hasAnyGames) {
      return LoopEmptyState(
        title: 'Nenhum jogo neste filtro',
        subtitle:
            'Nenhum título da sua biblioteca corresponde ao filtro selecionado.',
        actionLabel: 'Mostrar Todos',
        actionIcon: PhosphorIcons.squaresFour(PhosphorIconsStyle.bold),
        onAction: () => setState(() {
          _activeFilter = 'todos';
          _selectedIndex = 0;
        }),
        compact: true,
        backgroundColor: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LoopEmptyState(
          title: 'Nenhum jogo instalado ainda',
          subtitle:
              'Baixe jogos no catálogo ou importe uma ISO/ROM externa direto aqui.',
          actionLabel: 'Importar ISO / ROM',
          actionIcon: PhosphorIcons.folderPlus(PhosphorIconsStyle.bold),
          onAction:
              widget.onImportExternalIsoPressed ?? widget.onImportNewRomPressed,
          compact: true,
          backgroundColor: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
        ),
        const SizedBox(height: 10),
        Semantics(
          button: true,
          label: 'Explorar catálogo de ROMs',
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: PS5HydraTheme.textPrimary,
              backgroundColor: PS5HydraTheme.obsidianGlass,
              minimumSize: const Size(48, 48),
              side: const BorderSide(color: PS5HydraTheme.borderSubtle),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            onPressed: widget.onImportNewRomPressed,
            icon: PhosphorIcon(
              PhosphorIcons.compass(PhosphorIconsStyle.bold),
              size: 16,
            ),
            label: const Text(
              'Explorar Catálogo',
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final items = _filteredItems;
    final safeIdx = items.isEmpty ? 0 : _selectedIndex.clamp(0, items.length - 1);

    final content = _buildLandscapeLibrary(context, items, safeIdx);

    return Focus(
      focusNode: _screenFocusNode,
      autofocus: widget.isActive,
      canRequestFocus: widget.isActive,
      descendantsAreFocusable: widget.isActive,
      onFocusChange: (hasFocus) {
        if (_hasFocus != hasFocus || (!hasFocus && _gamepadNavActive)) {
          setState(() {
            _hasFocus = hasFocus;
            if (!hasFocus) _gamepadNavActive = false;
          });
        }
      },
      onKeyEvent: (node, event) {
        if (event.logicalKey == LogicalKeyboardKey.gameButtonLeft1 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonRight1 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonLeft2 ||
            event.logicalKey == LogicalKeyboardKey.gameButtonRight2) {
          return KeyEventResult.ignored;
        }
        return handleGamepadNavigationKey(
          event: event,
          itemCount: items.length,
          currentIndex: safeIdx,
          axis: Axis.horizontal,
          isActive: widget.isActive,
          onIndexChanged: (next) => _selectIndex(
            next,
            viaGamepad: true,
          ),
          onActivate: (idx) {
            final g = items[idx];
            final st = widget.downloadStatuses[g.igdbId];
            final path = st?.localPath ?? g.localRomPath;
            if (path != null && st?.state != RomActionState.downloading) {
              widget.onLaunchGame(g, path);
            }
          },
          onSecondaryAction: (idx) => _toggleFavorite(items[idx]),
          onTertiaryAction: (idx) =>
              unawaited(_confirmAndRemoveGame(items[idx])),
        );
      },
      child: content,
    );
  }

  // ==========================================================================
  // MODO HORIZONTAL EXCLUSIVO (CONSOLE-FIRST PS5 LIBRARY)
  // ==========================================================================
  Widget _buildLandscapeLibrary(
    BuildContext context,
    List<EmulationGame> items,
    int safeIdx,
  ) {
    final selectedGame = items.isNotEmpty ? items[safeIdx] : null;
    final selectedStatus = selectedGame != null
        ? widget.downloadStatuses[selectedGame.igdbId]
        : null;
    final selectedRomPath =
        selectedStatus?.localPath ?? selectedGame?.localRomPath;
    final selectedDownloading =
        selectedStatus?.state == RomActionState.downloading;
    final selectedAssets =
        selectedGame != null ? _resolvedAssets[selectedGame.igdbId] : null;
    final selectedBannerUrl = selectedGame == null
        ? null
        : (selectedAssets?.backgroundImageUrl ??
            selectedGame.heroBannerUrl ??
            selectedGame.resolvedHeroBannerUrl);

    return Scaffold(
      backgroundColor: PS5HydraTheme.pitchBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (selectedGame != null)
            AnimatedSwitcher(
              duration: PS5HydraTheme.animStandard,
              switchInCurve: Curves.easeOut,
              child: SizedBox.expand(
                key: ValueKey<int>(selectedGame.igdbId),
                child: ProceduralCover(
                  title: selectedGame.name,
                  platformName: selectedGame.platformName,
                  gameId: selectedGame.igdbId,
                  isBanner: true,
                  imageUrl: selectedBannerUrl,
                  borderRadius: 0,
                  showBottomLabel: false,
                ),
              ),
            ),

          // Gradiente full-bleed transparente -> #000000 para legibilidade
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.35, 0.78, 1.0],
                colors: [
                  Colors.transparent,
                  PS5HydraTheme.pitchBlack.withOpacity(0.50),
                  PS5HydraTheme.pitchBlack.withOpacity(0.90),
                  PS5HydraTheme.pitchBlack,
                ],
              ),
            ),
          ),

          SafeArea(
            top: false,
            child: _allLibraryItems.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        24,
                        MediaQuery.paddingOf(context).top + 58,
                        24,
                        24,
                      ),
                      child: _buildEmptyLibraryState(),
                    ),
                  )
                : Padding(
                    padding: EdgeInsets.fromLTRB(
                      28,
                      MediaQuery.paddingOf(context).top + 58,
                      28,
                      12,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: [
                                    Text(
                                      '${items.length} ${items.length == 1 ? 'jogo' : 'jogos'}',
                                      style: PS5HydraTheme.metaMonoStyle.copyWith(
                                        fontSize: 12,
                                        color: PS5HydraTheme.textSecondary,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    LoopPlatformChip(
                                      label: 'Todos',
                                      count: _allLibraryItems.length,
                                      selected: _activeFilter == 'todos',
                                      compact: true,
                                      onTap: () => setState(() {
                                        _activeFilter = 'todos';
                                        _selectedIndex = 0;
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                    LoopPlatformChip(
                                      label: 'Favoritos',
                                      count: widget.userMeta.favorites.length,
                                      selected: _activeFilter == 'favoritos',
                                      compact: true,
                                      onTap: () => setState(() {
                                        _activeFilter = 'favoritos';
                                        _selectedIndex = 0;
                                      }),
                                    ),
                                    const SizedBox(width: 8),
                                    LoopPlatformChip(
                                      label: 'Recentes',
                                      selected: _activeFilter == 'recentes',
                                      compact: true,
                                      onTap: () => setState(() {
                                        _activeFilter = 'recentes';
                                        _selectedIndex = 0;
                                      }),
                                    ),
                                    for (final col
                                        in widget.userMeta.collections.keys) ...[
                                      const SizedBox(width: 8),
                                      LoopPlatformChip(
                                        label: col,
                                        count: widget
                                                .userMeta.collections[col]?.length ??
                                            0,
                                        selected: _activeFilter == col,
                                        compact: true,
                                        onTap: () => setState(() {
                                          _activeFilter = col;
                                          _selectedIndex = 0;
                                        }),
                                      ),
                                    ],
                                    const SizedBox(width: 8),
                                    _NewCollectionChipButton(
                                      onTap: () => unawaited(
                                        _showCreateCollectionDialog(),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Semantics(
                              button: true,
                              label: 'Importar ISO ou ROM externa',
                              child: OutlinedButton.icon(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: PS5HydraTheme.obsidianGlass,
                                  foregroundColor: PS5HydraTheme.textPrimary,
                                  side: const BorderSide(
                                    color: PS5HydraTheme.borderSubtle,
                                  ),
                                  minimumSize: const Size(48, 48),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      PS5HydraTheme.radiusChip,
                                    ),
                                  ),
                                ),
                                onPressed: widget.onImportExternalIsoPressed ??
                                    widget.onImportNewRomPressed,
                                icon: PhosphorIcon(
                                  PhosphorIcons.folderPlus(
                                    PhosphorIconsStyle.bold,
                                  ),
                                  size: 16,
                                ),
                                label: const Text(
                                  'Importar ISO / ROM',
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Expanded(
                          child: items.isEmpty
                              ? Center(
                                  child: SingleChildScrollView(
                                    child: _buildEmptyLibraryState(),
                                  ),
                                )
                              : LayoutBuilder(
                                  builder: (context, constraints) {
                                    final listHeight =
                                        constraints.maxHeight.clamp(120.0, 214.0);
                                    final selectedHeight =
                                        (listHeight - 8).clamp(112.0, 206.0);
                                    final selectedWidth =
                                        selectedHeight * 0.72;
                                    final normalHeight =
                                        (selectedHeight * 0.90).clamp(
                                      100.0,
                                      186.0,
                                    );
                                    final normalWidth = normalHeight * 0.72;
                                    _landscapeCardExtent = normalWidth + 14.0;

                                    return Center(
                                      child: SizedBox(
                                        height: listHeight,
                                        child: ListView.separated(
                                          controller:
                                              _landscapeScrollController,
                                          scrollDirection: Axis.horizontal,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 4,
                                          ),
                                          itemCount: items.length,
                                          separatorBuilder: (_, __) =>
                                              const SizedBox(width: 14),
                                          itemBuilder: (context, idx) {
                                            final game = items[idx];
                                            final isSelected = idx == safeIdx;
                                            final status = widget
                                                .downloadStatuses[game.igdbId];
                                            final isDl = status?.state ==
                                                RomActionState.downloading;
                                            final romPath = status?.localPath ??
                                                game.localRomPath;

                                            return _LibraryHorizontalGameCard(
                                              game: game,
                                              itemIndex: idx,
                                              isSelected: isSelected,
                                              width: isSelected
                                                  ? selectedWidth
                                                  : normalWidth,
                                              height: isSelected
                                                  ? selectedHeight
                                                  : normalHeight,
                                              coverUrl: _resolvedAssets[
                                                          game.igdbId]
                                                      ?.coverImageUrl ??
                                                  game.gridCoverUrl ??
                                                  game.resolvedGridCoverUrl,
                                              status: status,
                                              isDownloading: isDl,
                                              onTap: () {
                                                if (isSelected &&
                                                    !isDl &&
                                                    romPath != null) {
                                                  widget.onLaunchGame(
                                                    game,
                                                    romPath,
                                                  );
                                                } else {
                                                  _selectIndex(idx);
                                                }
                                              },
                                              onLongPress: () {
                                                _selectIndex(idx);
                                                unawaited(
                                                  _showLongPressOptions(game),
                                                );
                                              },
                                            );
                                          },
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                        const SizedBox(height: 10),
                        if (selectedGame != null)
                          _buildLandscapeBottomBar(
                            context,
                            selectedGame: selectedGame,
                            selectedStatus: selectedStatus,
                            selectedRomPath: selectedRomPath,
                            selectedDownloading: selectedDownloading,
                          ),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }


  Widget _buildLandscapeBottomBar(
    BuildContext context, {
    required EmulationGame selectedGame,
    required RomDownloadStatus? selectedStatus,
    required String? selectedRomPath,
    required bool selectedDownloading,
  }) {
    final isFavorite = widget.userMeta.isFavorite(selectedGame.igdbId);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: AnimatedHeroFadeSlideSwitcher(
                  child: KeyedSubtree(
                    key: ValueKey<int>(selectedGame.igdbId),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: AnimatedGameLogo(
                            game: selectedGame,
                            height: 36,
                            maxWidthFraction: 1.0,
                            enableStagger: false,
                            maxLines: 1,
                            fallbackStyle: const TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              color: PS5HydraTheme.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: PS5HydraTheme.surfaceGlass(
                            radius: 8,
                            alpha: 0.92,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PhosphorIcon(
                                selectedDownloading
                                    ? PhosphorIcons.downloadSimple(
                                        PhosphorIconsStyle.bold,
                                      )
                                    : PhosphorIcons.clock(
                                        PhosphorIconsStyle.regular,
                                      ),
                                size: 13,
                                color: PS5HydraTheme.textPrimary,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                selectedDownloading
                                    ? 'Baixando ${LoopProgressIndicator.formatPercent(selectedStatus?.progress ?? 0)} (${selectedStatus?.speedLabel ?? "2º plano"})'
                                    : formatPlaytime(
                                        widget.userMeta
                                            .playtimeOf(selectedGame.igdbId)
                                            .totalSeconds,
                                      ),
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: selectedDownloading
                                      ? PS5HydraTheme.auroraSpringMint
                                      : PS5HydraTheme.textPrimary,
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
              const SizedBox(width: 6),
              Semantics(
                button: true,
                toggled: isFavorite,
                label: isFavorite
                    ? 'Remover ${selectedGame.name} dos favoritos'
                    : 'Adicionar ${selectedGame.name} aos favoritos',
                child: Tooltip(
                  message: isFavorite
                      ? 'Remover dos favoritos'
                      : 'Adicionar aos favoritos',
                  child: IconButton(
                    onPressed: () => _toggleFavorite(selectedGame),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: PS5HydraTheme.obsidianGlass,
                      side: BorderSide(
                        color: isFavorite
                            ? PS5HydraTheme.auroraSpringMint
                            : PS5HydraTheme.borderSubtle,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: PhosphorIcon(
                      isFavorite
                          ? PhosphorIcons.star(PhosphorIconsStyle.fill)
                          : PhosphorIcons.star(PhosphorIconsStyle.regular),
                      size: 18,
                      color: isFavorite
                          ? PS5HydraTheme.auroraSpringMint
                          : PS5HydraTheme.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Semantics(
                button: true,
                label: 'Opções de ${selectedGame.name}',
                child: Tooltip(
                  message: 'Opções do jogo',
                  child: IconButton(
                    onPressed: () =>
                        unawaited(_showLongPressOptions(selectedGame)),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: PS5HydraTheme.obsidianGlass,
                      side: const BorderSide(
                        color: PS5HydraTheme.borderSubtle,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    icon: PhosphorIcon(
                      PhosphorIcons.dotsThreeVertical(PhosphorIconsStyle.bold),
                      size: 18,
                      color: PS5HydraTheme.textPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              button: true,
              label: 'Remover ${selectedGame.name} da biblioteca',
              child: Tooltip(
                message: 'Remover da biblioteca (X)',
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: PS5HydraTheme.textSecondary,
                    backgroundColor: PS5HydraTheme.obsidianGlass,
                    minimumSize: const Size(48, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    side: const BorderSide(color: PS5HydraTheme.borderSubtle),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        PS5HydraTheme.radiusChip,
                      ),
                    ),
                  ),
                  onPressed: () =>
                      unawaited(_confirmAndRemoveGame(selectedGame)),
                  child: const Text(
                    'Remover',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            if (selectedDownloading)
              Semantics(
                button: true,
                label: 'Cancelar download de ${selectedGame.name}',
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HydraTokens.accentDanger,
                    backgroundColor: PS5HydraTheme.obsidianGlass,
                    minimumSize: const Size(84, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    side: BorderSide(
                      color: HydraTokens.accentDanger.withOpacity(0.55),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        PS5HydraTheme.radiusChip,
                      ),
                    ),
                  ),
                  onPressed: () => widget.onCancelDownload(selectedGame),
                  child: const Text(
                    'Cancelar',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            else
              Semantics(
                button: true,
                enabled: selectedRomPath != null,
                label: 'Jogar ${selectedGame.name}',
                child: Tooltip(
                  message: 'Jogar (A)',
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: PS5HydraTheme.auroraSpringMint,
                      foregroundColor: PS5HydraTheme.textOnAurora,
                      minimumSize: const Size(92, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          PS5HydraTheme.radiusChip,
                        ),
                      ),
                    ),
                    onPressed: selectedRomPath != null
                        ? () => widget.onLaunchGame(
                              selectedGame,
                              selectedRomPath,
                            )
                        : null,
                    icon: PhosphorIcon(
                      PhosphorIcons.play(PhosphorIconsStyle.fill),
                      size: 16,
                    ),
                    label: const Text(
                      'Jogar',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _LibraryHorizontalGameCard extends StatefulWidget {
  const _LibraryHorizontalGameCard({
    required this.game,
    required this.itemIndex,
    required this.isSelected,
    required this.width,
    required this.height,
    required this.coverUrl,
    required this.status,
    required this.isDownloading,
    required this.onTap,
    required this.onLongPress,
  });

  final EmulationGame game;
  final int itemIndex;
  final bool isSelected;
  final double width;
  final double height;
  final String? coverUrl;
  final RomDownloadStatus? status;
  final bool isDownloading;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  State<_LibraryHorizontalGameCard> createState() =>
      _LibraryHorizontalGameCardState();
}

class _LibraryHorizontalGameCardState
    extends State<_LibraryHorizontalGameCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.isSelected || _hovered;
    return Center(
      child: Semantics(
        button: true,
        selected: widget.isSelected,
        label: '${widget.game.name}, ${widget.game.platformName}',
        hint: 'Toque para selecionar ou jogar',
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: AnimatedScale(
              scale: active ? 1.05 : 1.0,
              duration: PS5HydraTheme.animFast,
              curve: Curves.easeOut,
              child: AnimatedContainer(
                duration: PS5HydraTheme.animMedium,
                curve: Curves.easeOut,
                width: widget.width,
                height: widget.height,
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
                            stops: [0.32, 0.72, 1.0],
                            colors: [
                              Colors.transparent,
                              Color(0xAD000000),
                              Color(0xF5000000),
                            ],
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
                          itemIndex: widget.itemIndex,
                          enableStagger: true,
                          maxLines: 1,
                          fallbackStyle: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: PS5HydraTheme.textPrimary,
                          ),
                        ),
                      ),
                      if (widget.isDownloading)
                        Container(
                          color: Colors.black.withOpacity(0.72),
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox(
                                width: 40,
                                height: 40,
                                child: CircularProgressIndicator(
                                  value: widget.status?.progress,
                                  strokeWidth: 3.5,
                                  color: PS5HydraTheme.auroraSpringMint,
                                  backgroundColor: Colors.white24,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Text(
                                LoopProgressIndicator.formatPercent(
                                  widget.status?.progress ?? 0,
                                ),
                                style: PS5HydraTheme.metaMonoStyle.copyWith(
                                  fontSize: 13,
                                  color: PS5HydraTheme.textPrimary,
                                ),
                              ),
                              if (widget.status?.speedLabel != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  widget.status!.speedLabel!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'Rubik',
                                    fontSize: 10,
                                    color: PS5HydraTheme.textSecondary,
                                  ),
                                ),
                              ],
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


class _NewCollectionChipButton extends StatefulWidget {
  const _NewCollectionChipButton({required this.onTap});

  final VoidCallback onTap;

  @override
  State<_NewCollectionChipButton> createState() =>
      _NewCollectionChipButtonState();
}

class _NewCollectionChipButtonState extends State<_NewCollectionChipButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Criar nova coleção',
      child: Tooltip(
        message: 'Criar nova coleção',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onFocusChange: (hasFocus) {
                if (_focused != hasFocus) {
                  setState(() => _focused = hasFocus);
                }
              },
              onTap: widget.onTap,
              child: Center(
                widthFactor: 1.0,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: HydraTokens.surfaceCatalog,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _focused
                          ? HydraTokens.primaryAurora
                          : HydraTokens.borderSubtle10,
                      width: _focused ? 1.5 : 1.0,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.plus(PhosphorIconsStyle.bold),
                        size: 12,
                        color: HydraTokens.primaryAurora,
                      ),
                      const SizedBox(width: 4),
                      const Text(
                        'Nova Coleção',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.primaryAurora,
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
