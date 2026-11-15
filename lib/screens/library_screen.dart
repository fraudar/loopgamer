import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/cover_cache_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({
    super.key,
    required this.downloadedGames,
    required this.downloadingGames,
    required this.downloadStatuses,
    required this.onImportNewRomPressed,
    required this.onLaunchGame,
    required this.onRemoveGame,
    required this.onCancelDownload,
    this.userMeta = const UserLibraryMeta(),
    this.onUserMetaChanged,
  });

  final List<EmulationGame> downloadedGames;
  final List<EmulationGame> downloadingGames;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final VoidCallback onImportNewRomPressed;
  final void Function(EmulationGame game, String localRomPath) onLaunchGame;
  final Future<void> Function(EmulationGame game) onRemoveGame;
  final void Function(EmulationGame game) onCancelDownload;
  final UserLibraryMeta userMeta;
  final ValueChanged<UserLibraryMeta>? onUserMetaChanged;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  int _selectedIndex = 0;
  String _activeFilter = 'todos';

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

  void _toggleFavorite(EmulationGame game) {
    HapticFeedback.lightImpact();
    final next = widget.userMeta.toggleFavorite(game.igdbId);
    widget.onUserMetaChanged?.call(next);
  }

  Future<void> _showCreateCollectionDialog() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HydraTokens.bgNearBlack,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: HydraTokens.borderSubtle10),
        ),
        title: const Text(
          'Nova Coleção',
          style: TextStyle(
            fontFamily: 'ReadexPro',
            fontWeight: FontWeight.w700,
            color: HydraTokens.textPrimary,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white, fontFamily: 'ReadexPro'),
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
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancelar',
                style: TextStyle(color: HydraTokens.textSecondary)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: HydraTokens.primaryAurora,
              foregroundColor: HydraTokens.bgPureBlack,
            ),
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Criar',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) {
      final next = widget.userMeta.createCollection(name);
      widget.onUserMetaChanged?.call(next);
      setState(() => _activeFilter = name);
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
          return AlertDialog(
            backgroundColor: HydraTokens.bgNearBlack,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: const BorderSide(color: HydraTokens.borderSubtle10),
            ),
            title: Text(
              'Coleções: ${game.name}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: HydraTokens.textPrimary,
              ),
            ),
            content: SizedBox(
              width: double.maxFinite,
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final col in cols)
                    CheckboxListTile(
                      activeColor: HydraTokens.secondaryTeal,
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
                        final next = widget.userMeta
                            .setInCollection(col, game.igdbId, val ?? false);
                        widget.onUserMetaChanged?.call(next);
                        setDialogState(() {});
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  Navigator.of(ctx).pop();
                  await _showCreateCollectionDialog();
                },
                child: const Text('+ Nova Coleção',
                    style: TextStyle(color: HydraTokens.secondaryTeal)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: HydraTokens.primaryAurora,
                  foregroundColor: HydraTokens.bgPureBlack,
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
    HapticFeedback.mediumImpact();
    final status = widget.downloadStatuses[game.igdbId];
    final romPath = status?.localPath ?? game.localRomPath;
    final isDownloading = status?.state == RomActionState.downloading;

    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          margin: const EdgeInsets.all(16),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          decoration: BoxDecoration(
            color: HydraTokens.bgNearBlack,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: HydraTokens.borderSubtle10),
          ),
          child: SafeArea(
            top: false,
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
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        width: 46,
                        height: 64,
                        child: LoopCoverImage(
                          url: game.resolvedGridCoverUrl,
                          fit: BoxFit.cover,
                          platformSlug: game.platformSlug,
                          gameTitle: game.name,
                        ),
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
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: PhosphorIcon(
                    widget.userMeta.isFavorite(game.igdbId)
                        ? PhosphorIcons.star(PhosphorIconsStyle.fill)
                        : PhosphorIcons.star(PhosphorIconsStyle.regular),
                    color: widget.userMeta.isFavorite(game.igdbId)
                        ? const Color(0xFFFFB703)
                        : HydraTokens.textPrimary,
                  ),
                  title: Text(
                    widget.userMeta.isFavorite(game.igdbId)
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                  leading: PhosphorIcon(
                    PhosphorIcons.folders(PhosphorIconsStyle.regular),
                    color: HydraTokens.secondaryTeal,
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: HydraTokens.borderSubtle10),
          ),
          title: const Text(
            'Confirmar Remoção',
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: HydraTokens.textPrimary,
            ),
          ),
          content: Text(
            'Tem certeza que deseja remover "${game.name}" da sua biblioteca e apagar o arquivo do dispositivo?',
            style: const TextStyle(
              fontFamily: 'Rubik',
              fontSize: 13.5,
              height: 1.45,
              color: HydraTokens.textSecondary,
            ),
          ),
          actions: [
            TextButton(
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
                foregroundColor: Colors.white,
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height && size.width >= 560;
    final items = _filteredItems;

    final content = isLandscape
        ? _buildLandscapeLibrary(context, items)
        : _buildPortraitLibrary(context, items);

    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.gameButtonRight1) {
            if (items.isNotEmpty) {
              setState(() =>
                  _selectedIndex = (_selectedIndex + 1) % items.length);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.gameButtonLeft1) {
            if (items.isNotEmpty) {
              setState(() => _selectedIndex =
                  (_selectedIndex - 1 + items.length) % items.length);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.gameButtonA ||
              event.logicalKey == LogicalKeyboardKey.enter) {
            if (items.isNotEmpty) {
              final g = items[_selectedIndex.clamp(0, items.length - 1)];
              final st = widget.downloadStatuses[g.igdbId];
              final path = st?.localPath ?? g.localRomPath;
              if (path != null && st?.state != RomActionState.downloading) {
                widget.onLaunchGame(g, path);
              }
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.gameButtonY) {
            if (items.isNotEmpty) {
              final g = items[_selectedIndex.clamp(0, items.length - 1)];
              _toggleFavorite(g);
            }
            return KeyEventResult.handled;
          } else if (event.logicalKey == LogicalKeyboardKey.gameButtonX) {
            if (items.isNotEmpty) {
              final g = items[_selectedIndex.clamp(0, items.length - 1)];
              _confirmAndRemoveGame(g);
            }
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: content,
    );
  }

  // ==========================================================================
  // MODO DEITADO (LANDSCAPE) — EXATAMENTE NO ESTILO GAMEHUB LIBRARY (IMAGEM 2)
  // ==========================================================================
  Widget _buildLandscapeLibrary(
    BuildContext context,
    List<EmulationGame> items,
  ) {
    final safeIdx =
        items.isEmpty ? 0 : _selectedIndex.clamp(0, items.length - 1);
    final selectedGame = items.isNotEmpty ? items[safeIdx] : null;
    final selectedStatus = selectedGame != null
        ? widget.downloadStatuses[selectedGame.igdbId]
        : null;
    final selectedRomPath =
        selectedStatus?.localPath ?? selectedGame?.localRomPath;
    final selectedDownloading =
        selectedStatus?.state == RomActionState.downloading;

    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 1. Background Artwork do jogo selecionado (GameHub Library Backdrop)
          if (selectedGame != null)
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: SizedBox.expand(
                key: ValueKey<int>(selectedGame.igdbId),
                child: LoopCoverImage(
                  url: selectedGame.resolvedHeroBannerUrl,
                  fit: BoxFit.cover,
                  platformSlug: selectedGame.platformSlug,
                  gameTitle: selectedGame.name,
                ),
              ),
            ),

          // Vinheta escura cinematográfica
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.35, 0.78, 1.0],
                colors: [
                  HydraTokens.bgPureBlack.withOpacity(0.68),
                  HydraTokens.bgPureBlack.withOpacity(0.54),
                  HydraTokens.bgPureBlack.withOpacity(0.86),
                  HydraTokens.bgPureBlack.withOpacity(0.97),
                ],
              ),
            ),
          ),

          // 2. Conteúdo Central: Fileira Horizontal de Pôsteres Verticais (Imagem 2)
          SafeArea(
            child: items.isEmpty
                ? Center(
                    child: HydraTexturedCard(
                      backgroundColor: HydraTokens.bgNearBlack.withOpacity(0.9),
                      borderRadius: 18,
                      padding: const EdgeInsets.all(28),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text(
                            'Nenhum jogo instalado ainda',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              color: HydraTokens.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Baixe jogos no catálogo em segundo plano ou importe um arquivo ROM local.',
                            style: TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 13,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: HydraTokens.primaryAurora,
                              foregroundColor: HydraTokens.bgPureBlack,
                            ),
                            onPressed: widget.onImportNewRomPressed,
                            child: const Text(
                              'Explorar Catálogo',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : Padding(
                    padding: const EdgeInsets.fromLTRB(32, 12, 32, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          height: 214,
                          child: ListView.separated(
                            scrollDirection: Axis.horizontal,
                            itemCount: items.length,
                            separatorBuilder: (_, __) =>
                                const SizedBox(width: 14),
                            itemBuilder: (context, idx) {
                              final game = items[idx];
                              final isSelected = idx == safeIdx;
                              final status =
                                  widget.downloadStatuses[game.igdbId];
                              final isDl =
                                  status?.state == RomActionState.downloading;
                              final romPath =
                                  status?.localPath ?? game.localRomPath;

                              return Center(
                                child: GestureDetector(
                                  onTap: () {
                                    if (isSelected &&
                                        !isDl &&
                                        romPath != null) {
                                      widget.onLaunchGame(game, romPath);
                                    } else {
                                      setState(() => _selectedIndex = idx);
                                    }
                                  },
                                  onLongPress: () {
                                    setState(() => _selectedIndex = idx);
                                    _showLongPressOptions(game);
                                  },
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    curve: Curves.easeOutCubic,
                                    width: isSelected ? 148 : 132,
                                    height: isSelected ? 210 : 186,
                                    decoration: BoxDecoration(
                                      color: HydraTokens.surfaceCatalog,
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isSelected
                                            ? Colors.white.withOpacity(0.90)
                                            : Colors.white.withOpacity(0.12),
                                        width: isSelected ? 2.2 : 1.0,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(
                                            isSelected ? 0.72 : 0.42,
                                          ),
                                          blurRadius: isSelected ? 22 : 12,
                                          offset: const Offset(0, 8),
                                        ),
                                      ],
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(14),
                                      child: Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          LoopCoverImage(
                                            url: game.resolvedGridCoverUrl,
                                            fit: BoxFit.cover,
                                            platformSlug: game.platformSlug,
                                            gameTitle: game.name,
                                          ),
                                          if (isDl)
                                            Container(
                                              color:
                                                  Colors.black.withOpacity(0.68),
                                              padding: const EdgeInsets.all(12),
                                              child: Column(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  SizedBox(
                                                    width: 42,
                                                    height: 42,
                                                    child:
                                                        CircularProgressIndicator(
                                                      value: status?.progress,
                                                      strokeWidth: 3.5,
                                                      color: HydraTokens
                                                          .secondaryTeal,
                                                      backgroundColor:
                                                          Colors.white24,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 10),
                                                  Text(
                                                    '${((status?.progress ?? 0) * 100).toStringAsFixed(0)}%',
                                                    style: const TextStyle(
                                                      fontFamily:
                                                          'JetBrainsMono',
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: Colors.white,
                                                    ),
                                                  ),
                                                  if (status?.speedLabel !=
                                                      null) ...[
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      status!.speedLabel!,
                                                      style: const TextStyle(
                                                        fontFamily: 'Rubik',
                                                        fontSize: 10,
                                                        color: HydraTokens
                                                            .textSecondary,
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
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        if (selectedGame != null)
                          Row(
                            children: [
                              Text(
                                selectedGame.name,
                                style: const TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.10),
                                  borderRadius: BorderRadius.circular(8),
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
                                      color: selectedDownloading
                                          ? HydraTokens.secondaryTeal
                                          : Colors.white,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      selectedDownloading
                                          ? 'Baixando ${((selectedStatus?.progress ?? 0) * 100).toStringAsFixed(0)}% (${selectedStatus?.speedLabel ?? "2º plano"})'
                                          : formatPlaytime(widget.userMeta
                                              .playtimeOf(selectedGame.igdbId)
                                              .totalSeconds),
                                      style: TextStyle(
                                        fontFamily: 'JetBrainsMono',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        color: selectedDownloading
                                            ? HydraTokens.secondaryTeal
                                            : Colors.white,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _toggleFavorite(selectedGame),
                                child: Container(
                                  padding: const EdgeInsets.all(5),
                                  decoration: BoxDecoration(
                                    color: Colors.white.withOpacity(0.10),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: PhosphorIcon(
                                    widget.userMeta.isFavorite(selectedGame.igdbId)
                                        ? PhosphorIcons.star(
                                            PhosphorIconsStyle.fill,
                                          )
                                        : PhosphorIcons.star(
                                            PhosphorIconsStyle.regular,
                                          ),
                                    size: 14,
                                    color: widget.userMeta
                                            .isFavorite(selectedGame.igdbId)
                                        ? const Color(0xFFFFB703)
                                        : HydraTokens.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                'Segure no jogo para opções',
                                style: TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 11,
                                  color: HydraTokens.textMuted,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
          ),

          // 3. Botão Inferior Direito "(A) Launch / Jogar" e "(X) Remover" (Igual à Imagem 2)
          if (selectedGame != null)
            Positioned(
              right: 28,
              bottom: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: () => _confirmAndRemoveGame(selectedGame),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.14),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: HydraTokens.accentDanger,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'X',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Text(
                            'Remover',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: (!selectedDownloading && selectedRomPath != null)
                        ? () =>
                            widget.onLaunchGame(selectedGame, selectedRomPath)
                        : null,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 7,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.68),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.24),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6.5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'A',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                color: HydraTokens.bgPureBlack,
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Text(
                            selectedDownloading ? 'Baixando...' : 'Jogar',
                            style: const TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ],
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

  // ==========================================================================
  // MODO EM PÉ (PORTRAIT) — COM DOWNLOAD EM 2º PLANO + SEGURAR PARA REMOVER
  // ==========================================================================
  Widget _buildPortraitLibrary(
    BuildContext context,
    List<EmulationGame> items,
  ) {
    return Scaffold(
      backgroundColor: HydraTokens.bgPureBlack,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: HydraTokens.heroBackgroundGradient,
                border: Border(
                  bottom: BorderSide(color: HydraTokens.borderSubtle8),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Minha Biblioteca',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          items.isEmpty
                              ? 'Seus jogos e downloads aparecem aqui'
                              : 'Segure em um jogo para remover da biblioteca',
                          style: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 11.5,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HydraTokens.textPrimary,
                      backgroundColor: HydraTokens.bgNearBlack,
                      side: const BorderSide(color: HydraTokens.borderSubtle10),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    onPressed: widget.onImportNewRomPressed,
                    child: const Text(
                      'Explorar Catálogo',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Barra de Filtros: Todos, Favoritos, Recentes, Coleções Customizadas
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterChip(
                      label: 'Todos (${_allLibraryItems.length})',
                      active: _activeFilter == 'todos',
                      onTap: () => setState(() => _activeFilter = 'todos'),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label:
                          '★ Favoritos (${widget.userMeta.favorites.length})',
                      active: _activeFilter == 'favoritos',
                      activeColor: const Color(0xFFFFB703),
                      onTap: () => setState(() => _activeFilter = 'favoritos'),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: 'Recentes',
                      active: _activeFilter == 'recentes',
                      onTap: () => setState(() => _activeFilter = 'recentes'),
                    ),
                    for (final col in widget.userMeta.collections.keys) ...[
                      const SizedBox(width: 8),
                      _FilterChip(
                        label:
                            '$col (${widget.userMeta.collections[col]?.length ?? 0})',
                        active: _activeFilter == col,
                        onTap: () => setState(() => _activeFilter = col),
                      ),
                    ],
                    const SizedBox(width: 8),
                    GestureDetector(
                      onTap: _showCreateCollectionDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 11,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: HydraTokens.surfaceCatalog,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color:
                                HydraTokens.secondaryTeal.withOpacity(0.55),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.plus(PhosphorIconsStyle.bold),
                              size: 11,
                              color: HydraTokens.secondaryTeal,
                            ),
                            const SizedBox(width: 4),
                            const Text(
                              'Nova Coleção',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 11,
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
              ),
            ),
            Expanded(
              child: items.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(28),
                        child: HydraTexturedCard(
                          backgroundColor: HydraTokens.bgNearBlack,
                          borderRadius: 16,
                          padding: EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Nenhum jogo instalado ainda',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 16.5,
                                  fontWeight: FontWeight.w700,
                                  color: HydraTokens.textPrimary,
                                ),
                              ),
                              SizedBox(height: 8),
                              Text(
                                'Escolha qualquer título na aba Início ou no Catálogo de ROMs para baixar em segundo plano.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 13.5,
                                  height: 1.45,
                                  color: HydraTokens.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(18),
                      itemCount: items.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final game = items[index];
                        final status = widget.downloadStatuses[game.igdbId];
                        final isDownloading =
                            status?.state == RomActionState.downloading;
                        final progress = status?.progress ?? 0.0;
                        final romPath = status?.localPath ?? game.localRomPath;

                        return HydraTexturedCard(
                          backgroundColor: HydraTokens.bgNearBlack,
                          borderRadius: 14,
                          highlightedBorder: !isDownloading,
                          padding: const EdgeInsets.all(12),
                          onTap: (!isDownloading && romPath != null)
                              ? () => widget.onLaunchGame(game, romPath)
                              : null,
                          onLongPress: () => _showLongPressOptions(game),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(10),
                                    child: SizedBox(
                                      width: 68,
                                      height: 94,
                                      child: LoopCoverImage(
                                        url: game.resolvedGridCoverUrl,
                                        fit: BoxFit.cover,
                                        platformSlug: game.platformSlug,
                                        gameTitle: game.name,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 7,
                                                vertical: 2,
                                              ),
                                              decoration: BoxDecoration(
                                                color: Colors.white
                                                    .withOpacity(0.08),
                                                borderRadius:
                                                    BorderRadius.circular(5),
                                              ),
                                              child: Text(
                                                game.platformName,
                                                style: const TextStyle(
                                                  fontFamily: 'JetBrainsMono',
                                                  fontSize: 10,
                                                  fontWeight: FontWeight.w700,
                                                  color:
                                                      HydraTokens.textPrimary,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                isDownloading
                                                    ? (status?.speedLabel ??
                                                        'Baixando em 2º plano...')
                                                    : '${game.formattedSize} • ${game.romFormatLabel}',
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontFamily: 'JetBrainsMono',
                                                  fontSize: 11,
                                                  color: isDownloading
                                                      ? HydraTokens
                                                          .secondaryTeal
                                                      : HydraTokens
                                                          .textSecondary,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          game.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 15.5,
                                            fontWeight: FontWeight.w700,
                                            color: HydraTokens.textPrimary,
                                          ),
                                        ),
                                        if (!isDownloading) ...[
                                          const SizedBox(height: 3),
                                          Row(
                                            children: [
                                              PhosphorIcon(
                                                PhosphorIcons.clock(
                                                  PhosphorIconsStyle.regular,
                                                ),
                                                size: 11,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 4),
                                              Text(
                                                formatPlaytime(widget.userMeta
                                                    .playtimeOf(game.igdbId)
                                                    .totalSeconds),
                                                style: const TextStyle(
                                                  fontFamily: 'JetBrainsMono',
                                                  fontSize: 10.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              if (widget.userMeta
                                                      .playtimeOf(game.igdbId)
                                                      .lastPlayed !=
                                                  null) ...[
                                                const SizedBox(width: 8),
                                                Text(
                                                  '• ${formatLastPlayed(widget.userMeta.playtimeOf(game.igdbId).lastPlayed)}',
                                                  style: const TextStyle(
                                                    fontFamily: 'Rubik',
                                                    fontSize: 10.5,
                                                    color:
                                                        HydraTokens.textMuted,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ],
                                        const SizedBox(height: 4),
                                        Text(
                                          isDownloading
                                              ? 'Progresso: ${(progress * 100).toStringAsFixed(0)}%'
                                              : '${game.developer} • Segure para opções',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'Rubik',
                                            fontSize: 11.5,
                                            color: HydraTokens.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  if (isDownloading)
                                    OutlinedButton(
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            HydraTokens.accentDanger,
                                        side: BorderSide(
                                          color: HydraTokens.accentDanger
                                              .withOpacity(0.5),
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                          vertical: 10,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                      ),
                                      onPressed: () =>
                                          widget.onCancelDownload(game),
                                      child: const Text(
                                        'Cancelar',
                                        style: TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    )
                                  else
                                    FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            HydraTokens.primaryAurora,
                                        foregroundColor:
                                            HydraTokens.bgPureBlack,
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                          vertical: 12,
                                        ),
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                      ),
                                      onPressed: romPath == null
                                          ? null
                                          : () => widget.onLaunchGame(
                                                game,
                                                romPath,
                                              ),
                                      child: const Text(
                                        'Jogar',
                                        style: TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontWeight: FontWeight.w700,
                                          color: HydraTokens.bgPureBlack,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              if (isDownloading) ...[
                                const SizedBox(height: 10),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(6),
                                  child: LinearProgressIndicator(
                                    value: progress,
                                    minHeight: 6,
                                    backgroundColor:
                                        HydraTokens.surfaceElevated2,
                                    valueColor:
                                        const AlwaysStoppedAnimation<Color>(
                                      HydraTokens.secondaryTeal,
                                    ),
                                  ),
                                ),
                              ],
                            ],
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
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.active,
    required this.onTap,
    this.activeColor,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final Color? activeColor;

  @override
  Widget build(BuildContext context) {
    final col = activeColor ?? HydraTokens.primaryAurora;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? col.withOpacity(0.20) : HydraTokens.surfaceCatalog,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: active ? col : Colors.white.withOpacity(0.12),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'ReadexPro',
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? col : HydraTokens.textSecondary,
          ),
        ),
      ),
    );
  }
}
