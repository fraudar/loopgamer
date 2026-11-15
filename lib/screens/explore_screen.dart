import 'dart:async';
import 'package:flutter/material.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/app_settings.dart';
import '../models/emulation_game.dart';
import '../services/cover_cache_service.dart';
import '../services/igdb_steamgriddb_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import 'home_screen.dart';

enum _CatalogSortMode { featured, alphaAsc, yearDesc }

extension _CatalogSortModeX on _CatalogSortMode {
  String get shortLabel {
    switch (this) {
      case _CatalogSortMode.featured:
        return 'Destaques';
      case _CatalogSortMode.alphaAsc:
        return 'A–Z';
      case _CatalogSortMode.yearDesc:
        return 'Mais Novos';
    }
  }
}

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({
    super.key,
    required this.apiService,
    required this.downloadService,
    required this.downloadStatuses,
    required this.settings,
    required this.onStatusUpdated,
    required this.onLaunchGameInLibretro,
  });

  final IgdbSteamGridService apiService;
  final RomDownloadService downloadService;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final AppSettings settings;
  final void Function(EmulationGame game, RomDownloadStatus status)
      onStatusUpdated;
  final void Function(EmulationGame game, String localRomPath)
      onLaunchGameInLibretro;

  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  static const List<String> _genreFilterLabels = [
    'Todos',
    'Ação',
    'Aventura',
    'RPG',
    'Plataforma',
    'Luta',
    'Corrida',
    'Shooter',
    'Esportes',
  ];

  final TextEditingController _searchController = TextEditingController();
  List<EmulationGame> _results = kVerifiedRealGamesCatalog;
  RommPlatformCategory _selectedCategory = RommPlatformCategory.all;
  String _selectedPlatformSlug = 'todos';
  String _selectedGenre = 'Todos';
  _CatalogSortMode _sortMode = _CatalogSortMode.featured;
  bool _gridViewMode = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadInitialRealCatalog();
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.rommServerUrl != widget.settings.rommServerUrl ||
        oldWidget.settings.rommApiToken != widget.settings.rommApiToken) {
      _loadInitialRealCatalog();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadInitialRealCatalog() async {
    final catalog = await widget.apiService.fetchRealCatalog(
      rommServerUrl: widget.settings.rommServerUrl,
      rommApiToken: widget.settings.rommApiToken,
    );
    if (mounted) {
      setState(() => _results = catalog);
    }
    CoverCacheService.instance.precacheCatalog(catalog);
  }

  void _selectCategory(RommPlatformCategory category) {
    setState(() {
      _selectedCategory = category;
      _selectedPlatformSlug = 'todos';
    });
  }

  void _mergeIntoResults(List<EmulationGame> extra) {
    if (extra.isEmpty || !mounted) return;
    final merged = List<EmulationGame>.from(_results);
    final seen = <String>{
      for (final m in merged)
        '${m.platformSlug.toLowerCase()}|${m.name.toLowerCase()}',
    };
    for (final g in extra) {
      final key = '${g.platformSlug.toLowerCase()}|${g.name.toLowerCase()}';
      if (seen.add(key)) {
        merged.add(g);
      }
    }
    setState(() => _results = merged);
    CoverCacheService.instance.precacheCatalog(merged);
  }

  Future<void> _selectPlatform(String slug) async {
    setState(() {
      _selectedPlatformSlug = slug;
      if (slug != 'todos') {
        final spec = kRommPlatforms.where((p) => p.slug == slug);
        if (spec.isNotEmpty && _selectedCategory != RommPlatformCategory.all) {
          _selectedCategory = spec.first.resolvedCategory;
        }
      }
    });
    if (slug != 'todos') {
      final extra = await widget.apiService.fetchFromRetroApiPlatform(
        slug,
        maxPerPlatform: 48,
      );
      _mergeIntoResults(extra);
    }
  }

  Future<void> _loadMoreForSelectedPlatform() async {
    final slug = _selectedPlatformSlug.toLowerCase();
    if (slug == 'todos' || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final currentRetroCount = _results
          .where(
            (g) =>
                g.platformSlug.toLowerCase() == slug &&
                g.igdbId >= 100000,
          )
          .length;
      final extra = await widget.apiService.fetchFromRetroApiPlatform(
        slug,
        offset: currentRetroCount,
        maxPerPlatform: 48,
      );
      _mergeIntoResults(extra);
    } finally {
      if (mounted) {
        setState(() => _isLoadingMore = false);
      }
    }
  }

  bool _matchesGenre(EmulationGame game, String selectedGenre) {
    if (selectedGenre == 'Todos') return true;
    final joined = game.genres.join(' ').toLowerCase();
    switch (selectedGenre) {
      case 'Ação':
        return joined.contains('ação') ||
            joined.contains('action') ||
            joined.contains('hack') ||
            joined.contains('beat');
      case 'Aventura':
        return joined.contains('aventura') || joined.contains('adventure');
      case 'RPG':
        return joined.contains('rpg') || joined.contains('role');
      case 'Plataforma':
        return joined.contains('plataforma') || joined.contains('platform');
      case 'Luta':
        return joined.contains('luta') || joined.contains('fighting');
      case 'Corrida':
        return joined.contains('corrida') || joined.contains('racing');
      case 'Shooter':
        return joined.contains('shooter') || joined.contains('shmup');
      case 'Esportes':
        return joined.contains('esporte') || joined.contains('sport');
      default:
        return true;
    }
  }

  void _cycleSortMode() {
    const order = _CatalogSortMode.values;
    final next = order[(_sortMode.index + 1) % order.length];
    setState(() => _sortMode = next);
  }

  Future<void> _performSearch(String query) async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final games = await widget.apiService.searchGames(
        query,
        platformFilter: _selectedPlatformSlug,
        rommServerUrl: widget.settings.rommServerUrl,
        rommApiToken: widget.settings.rommApiToken,
      );
      for (final game in games) {
        final existing =
            await widget.downloadService.resolveExistingRomPath(game.igdbId);
        if (existing != null) {
          widget.onStatusUpdated(
            game,
            RomDownloadStatus(
              state: RomActionState.readyToPlay,
              progress: 1.0,
              localPath: existing,
            ),
          );
        }
      }
      if (mounted) {
        setState(() {
          _results = games;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _openGameDetailModal(EmulationGame game) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => GameDetailSheet(
        game: game,
        downloadService: widget.downloadService,
        initialStatus:
            widget.downloadStatuses[game.igdbId] ?? const RomDownloadStatus(),
        onStatusChanged: (newStatus) {
          widget.onStatusUpdated(game, newStatus);
        },
        onPlayPressed: (localPath) {
          Navigator.of(context).pop();
          widget.onLaunchGameInLibretro(game, localPath);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final isLandscape = size.width > size.height && size.width >= 560;

    final visiblePlatforms = _selectedCategory == RommPlatformCategory.all
        ? kRommPlatforms
        : kRommPlatforms
            .where(
              (p) =>
                  p.slug == 'todos' || p.resolvedCategory == _selectedCategory,
            )
            .toList();

    final categorySlugs = _selectedCategory == RommPlatformCategory.all
        ? const <String>{}
        : visiblePlatforms
            .where((p) => p.slug != 'todos')
            .map((p) => p.slug.toLowerCase())
            .toSet();

    final filteredResults = _results.where((g) {
      final pSlug = g.platformSlug.toLowerCase();
      if (_selectedPlatformSlug != 'todos') {
        if (pSlug != _selectedPlatformSlug.toLowerCase()) return false;
      } else if (categorySlugs.isNotEmpty && !categorySlugs.contains(pSlug)) {
        return false;
      }
      return _matchesGenre(g, _selectedGenre);
    }).toList();

    if (_sortMode == _CatalogSortMode.alphaAsc) {
      filteredResults.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    } else if (_sortMode == _CatalogSortMode.yearDesc) {
      filteredResults.sort(
        (a, b) => (b.releaseYear ?? 0).compareTo(a.releaseYear ?? 0),
      );
    }

    final selectedPlatformSpec = _selectedPlatformSlug == 'todos'
        ? null
        : kRommPlatforms
            .where((p) => p.slug == _selectedPlatformSlug)
            .firstOrNull;

    final currentPlatformRetroCount = _selectedPlatformSlug == 'todos'
        ? 0
        : _results
            .where(
              (g) =>
                  g.platformSlug.toLowerCase() ==
                      _selectedPlatformSlug.toLowerCase() &&
                  g.igdbId >= 100000,
            )
            .length;
    final canLoadMore = _selectedPlatformSlug != 'todos' &&
        _searchController.text.trim().isEmpty &&
        widget.apiService.hasMoreRetroApiGames(
          _selectedPlatformSlug,
          currentPlatformRetroCount,
        );

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
              padding: EdgeInsets.fromLTRB(
                20,
                isLandscape ? 10 : 16,
                20,
                isLandscape ? 10 : 14,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Catálogo de ROMs',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                      ),
                      if (isLandscape) ...[
                        SizedBox(
                          width: 280,
                          height: 38,
                          child: HydraTexturedCard(
                            backgroundColor: HydraTokens.bgNearBlack,
                            borderRadius: 20,
                            child: TextField(
                              controller: _searchController,
                              onSubmitted: _performSearch,
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 12.5,
                                color: HydraTokens.textPrimary,
                              ),
                              decoration: InputDecoration(
                                hintText: 'Buscar jogo ou console...',
                                hintStyle: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 12,
                                  color: HydraTokens.textSecondary,
                                ),
                                prefixIcon: PhosphorIcon(
                                  PhosphorIcons.magnifyingGlass(
                                    PhosphorIconsStyle.regular,
                                  ),
                                  color: HydraTokens.textSecondary,
                                  size: 16,
                                ),
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 9,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Container(
                        decoration: BoxDecoration(
                          color: HydraTokens.bgNearBlack,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: HydraTokens.borderSubtle8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              onTap: _cycleSortMode,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    PhosphorIcon(
                                      PhosphorIcons.arrowsDownUp(
                                        PhosphorIconsStyle.bold,
                                      ),
                                      size: 13.5,
                                      color: HydraTokens.primaryAurora,
                                    ),
                                    const SizedBox(width: 5),
                                    Text(
                                      _sortMode.shortLabel,
                                      style: const TextStyle(
                                        fontFamily: 'ReadexPro',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w600,
                                        color: HydraTokens.textPrimary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            Container(
                              width: 1,
                              height: 18,
                              color: HydraTokens.borderSubtle8,
                            ),
                            _ViewToggleIcon(
                              icon: PhosphorIcons.squaresFour(
                                _gridViewMode
                                    ? PhosphorIconsStyle.fill
                                    : PhosphorIconsStyle.regular,
                              ),
                              active: _gridViewMode,
                              onTap: () => setState(() => _gridViewMode = true),
                            ),
                            _ViewToggleIcon(
                              icon: PhosphorIcons.listBullets(
                                !_gridViewMode
                                    ? PhosphorIconsStyle.fill
                                    : PhosphorIconsStyle.regular,
                              ),
                              active: !_gridViewMode,
                              onTap: () =>
                                  setState(() => _gridViewMode = false),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if (!isLandscape) ...[
                    const SizedBox(height: 12),
                    HydraTexturedCard(
                      backgroundColor: HydraTokens.bgNearBlack,
                      borderRadius: 22,
                      child: TextField(
                        controller: _searchController,
                        onSubmitted: _performSearch,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 13.5,
                          color: HydraTokens.textPrimary,
                        ),
                        decoration: InputDecoration(
                          hintText:
                              'Buscar jogo ou console (ex.: Zelda, Sonic, Metal Slug, Tekken)...',
                          hintStyle: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 12.5,
                            color: HydraTokens.textSecondary,
                          ),
                          prefixIcon: PhosphorIcon(
                            PhosphorIcons.magnifyingGlass(
                              PhosphorIconsStyle.regular,
                            ),
                            color: HydraTokens.textSecondary,
                            size: 18,
                          ),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                _performSearch(_searchController.text),
                            icon: PhosphorIcon(
                              PhosphorIcons.arrowRight(PhosphorIconsStyle.bold),
                              color: HydraTokens.primaryAurora,
                              size: 17,
                            ),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  // 1. Categorias principais (organiza 23 consoles sem bagunça)
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: RommPlatformCategory.values.map((cat) {
                        final active = _selectedCategory == cat;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: GestureDetector(
                            onTap: () => _selectCategory(cat),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 11,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? Colors.white.withOpacity(0.14)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: active
                                      ? HydraTokens.primaryAurora.withOpacity(
                                          0.85,
                                        )
                                      : HydraTokens.borderSubtle8,
                                ),
                              ),
                              child: Text(
                                cat.label,
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: active
                                      ? HydraTokens.primaryAurora
                                      : HydraTokens.textSecondary,
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 2. Consoles filtrados pela categoria ativa
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: visiblePlatforms.map((plat) {
                        final active = _selectedPlatformSlug == plat.slug;
                        final count = plat.slug == 'todos'
                            ? (_selectedCategory == RommPlatformCategory.all
                                ? _results.length
                                : _results
                                    .where(
                                      (g) => categorySlugs.contains(
                                        g.platformSlug.toLowerCase(),
                                      ),
                                    )
                                    .length)
                            : _results
                                .where(
                                  (g) =>
                                      g.platformSlug.toLowerCase() == plat.slug,
                                )
                                .length;
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: GestureDetector(
                            onTap: () => _selectPlatform(plat.slug),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6.5,
                              ),
                              decoration: BoxDecoration(
                                color: active
                                    ? HydraTokens.primaryAurora
                                    : HydraTokens.bgNearBlack,
                                borderRadius: BorderRadius.circular(18),
                                border: Border.all(
                                  color: active
                                      ? HydraTokens.primaryAurora
                                      : HydraTokens.borderSubtle8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    plat.shortName,
                                    style: TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                      color: active
                                          ? HydraTokens.bgPureBlack
                                          : HydraTokens.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '$count',
                                    style: TextStyle(
                                      fontFamily: 'JetBrainsMono',
                                      fontSize: 10,
                                      color: active
                                          ? HydraTokens.bgPureBlack
                                              .withOpacity(0.70)
                                          : HydraTokens.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 3. Gêneros + contador total visível
                  Row(
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: _genreFilterLabels.map((genre) {
                              final active = _selectedGenre == genre;
                              return Padding(
                                padding: const EdgeInsets.only(right: 6),
                                child: GestureDetector(
                                  onTap: () =>
                                      setState(() => _selectedGenre = genre),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 9,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: active
                                          ? HydraTokens.primaryAurora
                                              .withOpacity(0.18)
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: active
                                            ? HydraTokens.primaryAurora
                                            : HydraTokens.borderSubtle8,
                                      ),
                                    ),
                                    child: Text(
                                      genre,
                                      style: TextStyle(
                                        fontFamily: 'Rubik',
                                        fontSize: 10.5,
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w500,
                                        color: active
                                            ? HydraTokens.primaryAurora
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
                      const SizedBox(width: 8),
                      Text(
                        '${filteredResults.length} jogos',
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10.5,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Conteúdo do Catálogo com Grade Responsiva e Paginação
            Expanded(
              child: _isLoading
                  ? const Center(
                      child: CircularProgressIndicator(
                        color: HydraTokens.primaryAurora,
                      ),
                    )
                  : _errorMessage != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 12.5,
                                color: HydraTokens.textSecondary,
                              ),
                            ),
                          ),
                        )
                      : CustomScrollView(
                          slivers: [
                            if (selectedPlatformSpec?.coreNote != null)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    12,
                                    18,
                                    2,
                                  ),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: HydraTokens.bgNearBlack,
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(
                                        color: selectedPlatformSpec!.accentColor
                                            .withOpacity(0.45),
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        PhosphorIcon(
                                          PhosphorIcons.info(
                                            PhosphorIconsStyle.bold,
                                          ),
                                          size: 16,
                                          color:
                                              selectedPlatformSpec.accentColor,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(
                                            selectedPlatformSpec.coreNote!,
                                            style: const TextStyle(
                                              fontFamily: 'Rubik',
                                              fontSize: 11.5,
                                              color: HydraTokens.textPrimary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            if (filteredResults.isEmpty)
                              SliverFillRemaining(
                                hasScrollBody: false,
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Nenhum jogo corresponde aos filtros atuais.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            fontFamily: 'Rubik',
                                            fontSize: 13,
                                            color: HydraTokens.textSecondary,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        OutlinedButton(
                                          onPressed: () {
                                            _searchController.clear();
                                            setState(() {
                                              _selectedCategory =
                                                  RommPlatformCategory.all;
                                              _selectedPlatformSlug = 'todos';
                                              _selectedGenre = 'Todos';
                                            });
                                            _loadInitialRealCatalog();
                                          },
                                          child: const Text('Limpar filtros'),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            else if (_gridViewMode)
                              SliverPadding(
                                padding: const EdgeInsets.all(18),
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
                                      final game = filteredResults[index];
                                      final status =
                                          widget.downloadStatuses[game.igdbId] ??
                                              const RomDownloadStatus();
                                      return RommCoverGridCard(
                                        game: game,
                                        status: status,
                                        onTap: () => _openGameDetailModal(game),
                                      );
                                    },
                                    childCount: filteredResults.length,
                                  ),
                                ),
                              )
                            else
                              SliverPadding(
                                padding: const EdgeInsets.all(18),
                                sliver: SliverList.separated(
                                  itemCount: filteredResults.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    final game = filteredResults[index];
                                    final status =
                                        widget.downloadStatuses[game.igdbId] ??
                                            const RomDownloadStatus();
                                    return _RomListRowCard(
                                      game: game,
                                      status: status,
                                      onTap: () => _openGameDetailModal(game),
                                    );
                                  },
                                ),
                              ),
                            if (canLoadMore)
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.only(bottom: 24),
                                  child: Center(
                                    child: OutlinedButton.icon(
                                      onPressed: _isLoadingMore
                                          ? null
                                          : _loadMoreForSelectedPlatform,
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            HydraTokens.primaryAurora,
                                        side: const BorderSide(
                                          color: HydraTokens.borderSubtle10,
                                        ),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 18,
                                          vertical: 10,
                                        ),
                                      ),
                                      icon: _isLoadingMore
                                          ? const SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                                color:
                                                    HydraTokens.primaryAurora,
                                              ),
                                            )
                                          : PhosphorIcon(
                                              PhosphorIcons.plusCircle(
                                                PhosphorIconsStyle.bold,
                                              ),
                                              size: 16,
                                            ),
                                      label: Text(
                                        _isLoadingMore
                                            ? 'Carregando mais...'
                                            : 'Carregar mais jogos',
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ViewToggleIcon extends StatelessWidget {
  const _ViewToggleIcon({
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active
              ? HydraTokens.primaryAurora.withOpacity(0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: PhosphorIcon(
          icon,
          size: 16,
          color: active ? HydraTokens.primaryAurora : HydraTokens.textSecondary,
        ),
      ),
    );
  }
}

class _RomListRowCard extends StatelessWidget {
  const _RomListRowCard({
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

    return HydraTexturedCard(
      backgroundColor: HydraTokens.bgNearBlack,
      borderRadius: 14,
      highlightedBorder: isReady,
      onTap: onTap,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              width: 64,
              height: 90,
              child: LoopCoverImage(
                url: game.resolvedGridCoverUrl,
                width: 64,
                height: 90,
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
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
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
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isDownloading
                          ? 'Baixando ${(status.progress * 100).toStringAsFixed(0)}%'
                          : '${game.formattedSize} • ${game.romFormatLabel}',
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: isDownloading
                            ? HydraTokens.secondaryTeal
                            : HydraTokens.textSecondary,
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
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: HydraTokens.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${game.developer} • ${game.releaseYear ?? 2000}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Rubik',
                    fontSize: 12,
                    color: HydraTokens.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isReady
                  ? HydraTokens.primaryAurora
                  : HydraTokens.surfaceElevated1,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isReady
                    ? HydraTokens.primaryAurora
                    : HydraTokens.borderSubtle10,
              ),
            ),
            child: Text(
              isReady
                  ? 'Jogar'
                  : isDownloading
                      ? '${(status.progress * 100).toStringAsFixed(0)}%'
                      : 'Baixar',
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: isReady
                    ? HydraTokens.bgPureBlack
                    : HydraTokens.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Ficha de Jogo com Download Turbo em 2º Plano
class GameDetailSheet extends StatefulWidget {
  const GameDetailSheet({
    super.key,
    required this.game,
    required this.downloadService,
    required this.initialStatus,
    required this.onStatusChanged,
    required this.onPlayPressed,
  });

  final EmulationGame game;
  final RomDownloadService downloadService;
  final RomDownloadStatus initialStatus;
  final ValueChanged<RomDownloadStatus> onStatusChanged;
  final ValueChanged<String> onPlayPressed;

  @override
  State<GameDetailSheet> createState() => _GameDetailSheetState();
}

class _GameDetailSheetState extends State<GameDetailSheet> {
  late RomDownloadStatus _status = widget.initialStatus;
  StreamSubscription<RomDownloadEvent>? _sub;

  @override
  void initState() {
    super.initState();
    final active = widget.downloadService.activeStatuses[widget.game.igdbId];
    if (active != null) {
      _status = active;
    }
    _sub = widget.downloadService.downloadEvents.listen((event) {
      if (event.game.igdbId == widget.game.igdbId) {
        if (mounted) {
          setState(() => _status = event.status);
        }
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _updateStatus(RomDownloadStatus next) {
    if (mounted) {
      setState(() => _status = next);
    }
    widget.onStatusChanged(next);
  }

  Future<void> _startBackgroundDownload() async {
    unawaited(
      widget.downloadService.startBackgroundDownload(
        game: widget.game,
        onStatus: (st) {
          widget.onStatusChanged(st);
          if (mounted) {
            setState(() => _status = st);
            if (st.errorMessage != null && st.errorMessage!.isNotEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    st.errorMessage!,
                    style: const TextStyle(fontFamily: 'ReadexPro'),
                  ),
                  backgroundColor: const Color(0xFFEF4444),
                  duration: const Duration(seconds: 4),
                ),
              );
            }
          }
        },
      ),
    );
  }

  Future<void> _pickLocalRomFile() async {
    final importedPath = await widget.downloadService.importRomFromDevice(
      widget.game.igdbId,
      platformSlug: widget.game.platformSlug,
      preferredZipName: widget.game.directRomUrl,
    );
    if (importedPath != null) {
      _updateStatus(
        RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: importedPath,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final canPlay = _status.state == RomActionState.readyToPlay &&
        _status.localPath != null;
    final isDownloading = _status.state == RomActionState.downloading;

    return DraggableScrollableSheet(
      initialChildSize: 0.84,
      minChildSize: 0.58,
      maxChildSize: 0.94,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: HydraTokens.bgPureBlack,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            border: Border.all(color: HydraTokens.borderSubtle10),
          ),
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.zero,
              children: [
                // 1. Header com Banner In-Game + Capa Vertical + Título
                SizedBox(
                  height: 224,
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
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            stops: [0.0, 0.35, 1.0],
                            colors: [
                              Color(0x550A090E),
                              Color(0xAA0A090E),
                              HydraTokens.bgPureBlack,
                            ],
                          ),
                        ),
                      ),
                      Positioned(
                        top: 10,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            width: 40,
                            height: 4,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.24),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        left: 20,
                        right: 20,
                        bottom: 12,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Container(
                              width: 84,
                              height: 118,
                              decoration: BoxDecoration(
                                color: HydraTokens.bgNearBlack,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Colors.white.withOpacity(0.20),
                                ),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Color(0xCC000000),
                                    blurRadius: 16,
                                    offset: Offset(0, 6),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(11),
                                child: LoopCoverImage(
                                  url: game.resolvedGridCoverUrl,
                                  fit: BoxFit.cover,
                                  platformSlug: game.platformSlug,
                                  gameTitle: game.name,
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withOpacity(0.10),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      game.fullConsoleName.toUpperCase(),
                                      style: const TextStyle(
                                        fontFamily: 'JetBrainsMono',
                                        fontSize: 10,
                                        fontWeight: FontWeight.w700,
                                        color: HydraTokens.textPrimary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    game.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                      height: 1.15,
                                      color: HydraTokens.textPrimary,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '${game.developer} • ${game.releaseYear ?? 2000}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontFamily: 'Rubik',
                                      fontSize: 12.5,
                                      color: HydraTokens.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 2. Barra de Ação Principal (Baixar em 2º plano / Jogar + Arquivo Local)
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: HydraTokens.bgNearBlack,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: HydraTokens.borderSubtle8),
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 48,
                                    child: FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            HydraTokens.primaryAurora,
                                        foregroundColor:
                                            HydraTokens.bgPureBlack,
                                        shape: RoundedRectangleBorder(
                                          borderRadius:
                                              BorderRadius.circular(10),
                                        ),
                                      ),
                                      onPressed: () {
                                        if (canPlay) {
                                          widget.onPlayPressed(
                                            _status.localPath!,
                                          );
                                        } else if (game.directRomUrl
                                            .startsWith('external://')) {
                                          _pickLocalRomFile();
                                        } else if (!isDownloading) {
                                          _startBackgroundDownload();
                                        }
                                      },
                                        child: Text(
                                        canPlay
                                            ? 'Jogar Agora'
                                            : isDownloading
                                                ? 'Baixando ${(100 * _status.progress).toStringAsFixed(0)}% (${_status.speedLabel ?? "Turbo"})'
                                                : game.directRomUrl
                                                        .startsWith('external://')
                                                    ? 'Importar Arquivo Local'
                                                    : 'Baixar (${game.formattedSize})',
                                        style: const TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 13.5,
                                          fontWeight: FontWeight.w700,
                                          color: HydraTokens.bgPureBlack,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                SizedBox(
                                  height: 48,
                                  child: OutlinedButton(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: HydraTokens.textPrimary,
                                      backgroundColor:
                                          HydraTokens.surfaceElevated1,
                                      side: const BorderSide(
                                        color: HydraTokens.borderSubtle10,
                                      ),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                      ),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: _pickLocalRomFile,
                                    child: const Text(
                                      'Arquivo Local',
                                      style: TextStyle(
                                        fontFamily: 'ReadexPro',
                                        fontSize: 12.5,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            if (isDownloading) ...[
                              const SizedBox(height: 12),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: LinearProgressIndicator(
                                  value: _status.progress,
                                  minHeight: 7,
                                  backgroundColor: HydraTokens.surfaceElevated2,
                                  valueColor:
                                      const AlwaysStoppedAnimation<Color>(
                                    HydraTokens.secondaryTeal,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text(
                                    'Download ativo em 2º plano (visível na Biblioteca)',
                                    style: TextStyle(
                                      fontFamily: 'Rubik',
                                      fontSize: 11.5,
                                      color: HydraTokens.textSecondary,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () => Navigator.of(context).pop(),
                                    child: const Text(
                                      'Minimizar',
                                      style: TextStyle(
                                        fontFamily: 'ReadexPro',
                                        fontSize: 11.5,
                                        fontWeight: FontWeight.w700,
                                        color: HydraTokens.secondaryTeal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                            if (_status.errorMessage != null) ...[
                              const SizedBox(height: 10),
                              Text(
                                _status.errorMessage!,
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 12,
                                  color: Color(0xFFF87171),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // 3. Painel de Informações do Jogo
                      Container(
                        decoration: BoxDecoration(
                          color: HydraTokens.bgNearBlack,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: HydraTokens.borderSubtle8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 12,
                              ),
                              child: Text(
                                'Informações do Jogo',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w700,
                                  color: HydraTokens.textPrimary,
                                ),
                              ),
                            ),
                            const Divider(
                              color: HydraTokens.borderSubtle8,
                              height: 1,
                            ),
                            IntrinsicHeight(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _SpecInfoCell(
                                      label: 'TAMANHO',
                                      value: game.formattedSize,
                                      subValue: 'Formato ${game.romFormatLabel}',
                                    ),
                                  ),
                                  Container(
                                    width: 1,
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                  Expanded(
                                    child: _SpecInfoCell(
                                      label: 'PLATAFORMA',
                                      value:
                                          '${game.platformName} • ${game.region}',
                                      subValue: game.fullConsoleName,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(
                              color: HydraTokens.borderSubtle8,
                              height: 1,
                            ),
                            IntrinsicHeight(
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _SpecInfoCell(
                                      label: 'LANÇAMENTO',
                                      value: '${game.releaseYear ?? 2000}',
                                      subValue: game.developer,
                                    ),
                                  ),
                                  Container(
                                    width: 1,
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                  Expanded(
                                    child: _SpecInfoCell(
                                      label: 'GÊNERO',
                                      value: game.genres.isNotEmpty
                                          ? game.genres.first
                                          : 'Retro',
                                      subValue: game.genres.join(' • '),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 16),

                      // 4. Painel Sobre o Jogo
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: HydraTokens.bgNearBlack,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(color: HydraTokens.borderSubtle8),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Sinopse',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              game.summary,
                              style: const TextStyle(
                                fontFamily: 'Rubik',
                                fontSize: 13.5,
                                height: 1.5,
                                color: HydraTokens.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _SpecInfoCell extends StatelessWidget {
  const _SpecInfoCell({
    required this.label,
    required this.value,
    required this.subValue,
  });

  final String label;
  final String value;
  final String subValue;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: HydraTokens.textSecondary,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: HydraTokens.textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            subValue,
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
    );
  }
}
