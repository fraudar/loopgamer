import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/app_settings.dart';
import '../models/emulation_game.dart';
import '../services/cover_cache_service.dart';
import '../services/igdb_steamgriddb_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import '../widgets/loop_common_widgets.dart';
import 'game_detail_screen.dart';
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
    this.downloadStatuses = const {},
    this.downloadStatusesListenable,
    required this.settings,
    required this.onStatusUpdated,
    this.onBatchStatusUpdated,
    required this.onLaunchGameInLibretro,
    this.isActive = true,
    this.isLoadingCatalog = false,
    this.catalogError,
    this.onRetryCatalog,
  });

  final IgdbSteamGridService apiService;
  final RomDownloadService downloadService;
  final Map<int, RomDownloadStatus> downloadStatuses;
  final ValueListenable<Map<int, RomDownloadStatus>>?
      downloadStatusesListenable;
  final AppSettings settings;
  final void Function(EmulationGame game, RomDownloadStatus status)
      onStatusUpdated;
  final void Function(Map<EmulationGame, RomDownloadStatus> updates)?
      onBatchStatusUpdated;
  final void Function(EmulationGame game, String localRomPath)
      onLaunchGameInLibretro;
  final bool isActive;
  final bool isLoadingCatalog;
  final String? catalogError;
  final VoidCallback? onRetryCatalog;

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

  final FocusNode _screenFocusNode = FocusNode(
    debugLabel: 'ExploreScreenFocus',
  );
  final FocusNode _searchFocusNode = FocusNode(
    debugLabel: 'ExploreSearchFocus',
  );
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _filterHeaderKey = GlobalKey();
  final GlobalKey _coreNoteKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  List<EmulationGame> _results = kVerifiedRealGamesCatalog;
  List<EmulationGame> _filteredResults = kVerifiedRealGamesCatalog;
  List<RommPlatformSpec> _visiblePlatforms = kRommPlatforms;
  Map<String, int> _platformCounts = const {};
  int _currentPlatformRetroCount = 0;

  RommPlatformCategory _selectedCategory = RommPlatformCategory.all;
  String _selectedPlatformSlug = 'todos';
  String _selectedGenre = 'Todos';
  _CatalogSortMode _sortMode = _CatalogSortMode.featured;
  bool _gridViewMode = true;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;

  int _selectedIndex = 0;
  bool _gamepadNavActive = false;
  int _gridColumns = 2;
  double _gridChildMainAxisExtent = 260.0;
  double _gridMainAxisStride = 274.0;

  CancelToken? _searchCancelToken;
  CancelToken? _platformCancelToken;
  int _searchSeq = 0;
  int _platformLoadSeq = 0;

  @override
  void initState() {
    super.initState();
    _recomputeFilteredCache();
    unawaited(_loadInitialRealCatalog());
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive && !_isPrimaryFocusEditable()) {
          _screenFocusNode.requestFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.rommServerUrl != widget.settings.rommServerUrl ||
        oldWidget.settings.rommApiToken != widget.settings.rommApiToken) {
      unawaited(_loadInitialRealCatalog());
    }
    if (!oldWidget.isActive && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive && !_isPrimaryFocusEditable()) {
          _screenFocusNode.requestFocus();
        }
      });
    } else if (oldWidget.isActive && !widget.isActive) {
      if (_searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
      }
      if (_screenFocusNode.hasFocus) {
        _screenFocusNode.unfocus();
      }
      if (_gamepadNavActive) {
        setState(() => _gamepadNavActive = false);
      }
    }
  }

  @override
  void dispose() {
    _searchCancelToken?.cancel('ExploreScreen disposed');
    _platformCancelToken?.cancel('ExploreScreen disposed');
    _searchController.dispose();
    _searchFocusNode.dispose();
    _screenFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool _isPrimaryFocusEditable() {
    if (_searchFocusNode.hasFocus) return true;
    final primary = FocusManager.instance.primaryFocus;
    final ctx = primary?.context;
    if (ctx == null) return false;
    if (ctx.widget is EditableText) return true;
    return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  void _focusSearchBox() {
    if (!widget.isActive) return;
    _searchFocusNode.requestFocus();
  }

  void _scrollToSelected(int idx) {
    if (!_scrollController.hasClients) return;
    if (idx <= 0) {
      if (_scrollController.offset > 0) {
        unawaited(
          _scrollController.animateTo(
            0.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
          ),
        );
      }
      return;
    }

    final headerHeight =
        (_filterHeaderKey.currentContext?.findRenderObject() as RenderBox?)
                ?.size
                .height ??
            160.0;
    final coreNoteHeight =
        (_coreNoteKey.currentContext?.findRenderObject() as RenderBox?)
                ?.size
                .height ??
            0.0;
    const double sliverTopPadding = 18.0;
    final double baseTop = headerHeight + coreNoteHeight + sliverTopPadding;

    final double itemTop;
    final double itemBottom;
    if (_gridViewMode) {
      final cols = math.max(1, _gridColumns);
      final row = idx ~/ cols;
      itemTop = baseTop + row * _gridMainAxisStride;
      itemBottom = itemTop + _gridChildMainAxisExtent;
    } else {
      const double listRowHeight = 114.0;
      const double listRowStride = 126.0;
      itemTop = baseTop + idx * listRowStride;
      itemBottom = itemTop + listRowHeight;
    }

    final viewport = _scrollController.position.viewportDimension;
    final currentOffset = _scrollController.offset;
    double? nextOffset;
    if (itemTop < currentOffset) {
      nextOffset = itemTop - 12.0;
    } else if (itemBottom > currentOffset + viewport) {
      nextOffset = itemBottom - viewport + 12.0;
    }

    if (nextOffset != null) {
      final clamped = nextOffset.clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      unawaited(
        _scrollController.animateTo(
          clamped,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
        ),
      );
    }
  }

  KeyEventResult _handleScreenKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.isActive) return KeyEventResult.ignored;

    if (_isPrimaryFocusEditable()) {
      if (event is KeyDownEvent &&
          (event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.gameButtonB)) {
        _searchFocusNode.unfocus();
        _screenFocusNode.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final items = _filteredResults;
    final safeIndex =
        items.isEmpty ? 0 : _selectedIndex.clamp(0, items.length - 1);

    return handleGamepadNavigationKey(
      event: event,
      itemCount: items.length,
      currentIndex: safeIndex,
      crossAxisCount: _gridViewMode ? math.max(1, _gridColumns) : 1,
      axis: Axis.vertical,
      wrapAround: true,
      allowSecondaryWhenEmpty: true,
      isActive: widget.isActive,
      onIndexChanged: (next) {
        setState(() {
          _selectedIndex = next;
          _gamepadNavActive = true;
        });
        _scrollToSelected(next);
      },
      onActivate: (idx) {
        if (idx >= 0 && idx < items.length) {
          setState(() {
            _selectedIndex = idx;
            _gamepadNavActive = true;
          });
          _openGameDetailModal(items[idx]);
        }
      },
      onSecondaryAction: (_) => _focusSearchBox(),
    );
  }

  String _friendlyCatalogError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401 || code == 403) {
        return 'Acesso negado ao servidor de catálogo. Verifique o token RomM nos Ajustes.';
      }
      if (code == 404) {
        return 'Fonte do catálogo não encontrada. Verifique o endereço configurado.';
      }
      if (code != null && code >= 500) {
        return 'O servidor do catálogo está instável no momento. Tente novamente.';
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.receiveTimeout ||
          error.type == DioExceptionType.sendTimeout) {
        return 'A consulta demorou mais que o esperado. Verifique sua internet e tente de novo.';
      }
      if (error.type == DioExceptionType.connectionError) {
        return 'Sem conexão com a internet ou servidor inacessível.';
      }
    }
    return 'Não foi possível atualizar o catálogo agora. Tente novamente em instantes.';
  }

  void _recomputeFilteredCache() {
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

    final counts = <String, int>{};
    int categoryTotal = 0;
    int selectedRetroCount = 0;
    final selectedLower = _selectedPlatformSlug.toLowerCase();
    final filtered = <EmulationGame>[];

    for (final g in _results) {
      final pSlug = g.platformSlug.toLowerCase();
      counts[pSlug] = (counts[pSlug] ?? 0) + 1;
      if (categorySlugs.isEmpty || categorySlugs.contains(pSlug)) {
        categoryTotal++;
      }
      if (selectedLower != 'todos' &&
          pSlug == selectedLower &&
          g.igdbId >= 100000) {
        selectedRetroCount++;
      }

      if (selectedLower != 'todos') {
        if (pSlug != selectedLower) continue;
      } else if (categorySlugs.isNotEmpty && !categorySlugs.contains(pSlug)) {
        continue;
      }
      if (_matchesGenre(g, _selectedGenre)) {
        filtered.add(g);
      }
    }

    counts['todos'] = categoryTotal;

    if (_sortMode == _CatalogSortMode.alphaAsc) {
      filtered.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    } else if (_sortMode == _CatalogSortMode.yearDesc) {
      filtered.sort(
        (a, b) => (b.releaseYear ?? 0).compareTo(a.releaseYear ?? 0),
      );
    }

    _visiblePlatforms = visiblePlatforms;
    _platformCounts = counts;
    _filteredResults = filtered;
    _currentPlatformRetroCount = selectedRetroCount;
  }

  Future<void> _loadInitialRealCatalog() async {
    final seq = ++_platformLoadSeq;
    _platformCancelToken?.cancel('reload_initial_catalog');
    final token = CancelToken();
    _platformCancelToken = token;

    if (mounted) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final catalog = await widget.apiService.fetchRealCatalog(
        rommServerUrl: widget.settings.rommServerUrl,
        rommApiToken: widget.settings.rommApiToken,
        cancelToken: token,
      );
      if (!mounted || seq != _platformLoadSeq || token.isCancelled) return;
      setState(() {
        _results = catalog;
        _isLoading = false;
        _errorMessage = catalog.isEmpty
            ? 'Nenhum jogo retornado pelo catálogo online.'
            : null;
        _recomputeFilteredCache();
      });
      unawaited(CoverCacheService.instance.precacheCatalog(catalog));
    } on DioException catch (e) {
      if (!mounted ||
          seq != _platformLoadSeq ||
          token.isCancelled ||
          e.type == DioExceptionType.cancel) {
        return;
      }
      setState(() {
        _isLoading = false;
        if (_results.isEmpty) {
          _errorMessage = _friendlyCatalogError(e);
        }
      });
    } catch (e) {
      if (!mounted || seq != _platformLoadSeq || token.isCancelled) return;
      setState(() {
        _isLoading = false;
        if (_results.isEmpty) {
          _errorMessage = _friendlyCatalogError(e);
        }
      });
    }
  }

  void _selectCategory(RommPlatformCategory category) {
    setState(() {
      _selectedCategory = category;
      _selectedPlatformSlug = 'todos';
      _selectedIndex = 0;
      _errorMessage = null;
      _recomputeFilteredCache();
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
    _results = merged;
    _recomputeFilteredCache();
    unawaited(CoverCacheService.instance.precacheCatalog(merged));
  }

  Future<void> _selectPlatform(String slug) async {
    final seq = ++_platformLoadSeq;
    _platformCancelToken?.cancel('platform_changed');

    setState(() {
      _selectedPlatformSlug = slug;
      _selectedIndex = 0;
      _errorMessage = null;
      if (slug != 'todos') {
        final spec = kRommPlatforms.where((p) => p.slug == slug);
        if (spec.isNotEmpty && _selectedCategory != RommPlatformCategory.all) {
          _selectedCategory = spec.first.resolvedCategory;
        }
      }
      _isLoading = slug != 'todos';
      _recomputeFilteredCache();
    });

    if (slug == 'todos') return;

    final token = CancelToken();
    _platformCancelToken = token;
    try {
      final extra = await widget.apiService.fetchFromRetroApiPlatform(
        slug,
        maxPerPlatform: 48,
        cancelToken: token,
      );
      if (!mounted || seq != _platformLoadSeq || token.isCancelled) return;
      setState(() {
        _mergeIntoResults(extra);
        _isLoading = false;
      });
    } on DioException catch (e) {
      if (!mounted ||
          seq != _platformLoadSeq ||
          token.isCancelled ||
          e.type == DioExceptionType.cancel) {
        return;
      }
      setState(() {
        _isLoading = false;
        if (_filteredResults.isEmpty) {
          _errorMessage = _friendlyCatalogError(e);
        }
      });
    } catch (e) {
      if (!mounted || seq != _platformLoadSeq || token.isCancelled) return;
      setState(() {
        _isLoading = false;
        if (_filteredResults.isEmpty) {
          _errorMessage = _friendlyCatalogError(e);
        }
      });
    }
  }

  Future<void> _loadMoreForSelectedPlatform() async {
    final slug = _selectedPlatformSlug.toLowerCase();
    if (slug == 'todos' || _isLoadingMore) return;
    setState(() => _isLoadingMore = true);
    try {
      final extra = await widget.apiService.fetchFromRetroApiPlatform(
        slug,
        offset: _currentPlatformRetroCount,
        maxPerPlatform: 48,
      );
      if (!mounted) return;
      setState(() {
        _mergeIntoResults(extra);
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_friendlyCatalogError(e)),
          ),
        );
      }
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
    setState(() {
      _sortMode = next;
      _selectedIndex = 0;
      _recomputeFilteredCache();
    });
  }

  void _clearAllFilters() {
    _searchController.clear();
    setState(() {
      _selectedCategory = RommPlatformCategory.all;
      _selectedPlatformSlug = 'todos';
      _selectedGenre = 'Todos';
      _selectedIndex = 0;
      _errorMessage = null;
      _recomputeFilteredCache();
    });
    unawaited(_loadInitialRealCatalog());
  }

  Future<void> _performSearch(String query) async {
    final seq = ++_searchSeq;
    _searchCancelToken?.cancel('Superseded by new search');
    final token = CancelToken();
    _searchCancelToken = token;

    setState(() {
      _isLoading = true;
      _selectedIndex = 0;
      _errorMessage = null;
    });

    try {
      final games = await widget.apiService.searchGames(
        query,
        platformFilter: _selectedPlatformSlug,
        rommServerUrl: widget.settings.rommServerUrl,
        rommApiToken: widget.settings.rommApiToken,
        cancelToken: token,
      );
      if (!mounted || seq != _searchSeq || token.isCancelled) return;

      final resolvedEntries = await Future.wait(
        games.map((game) async {
          final existing =
              await widget.downloadService.resolveExistingRomPath(game.igdbId);
          return existing != null
              ? MapEntry(
                  game,
                  RomDownloadStatus(
                    state: RomActionState.readyToPlay,
                    progress: 1.0,
                    localPath: existing,
                  ),
                )
              : null;
        }),
      );
      if (!mounted || seq != _searchSeq || token.isCancelled) return;

      final batch = <EmulationGame, RomDownloadStatus>{
        for (final entry in resolvedEntries)
          if (entry != null) entry.key: entry.value,
      };
      if (batch.isNotEmpty) {
        if (widget.onBatchStatusUpdated != null) {
          widget.onBatchStatusUpdated!(batch);
        } else {
          for (final entry in batch.entries) {
            widget.onStatusUpdated(entry.key, entry.value);
          }
        }
      }

      setState(() {
        _results = games;
        _isLoading = false;
        _recomputeFilteredCache();
      });
    } on DioException catch (e) {
      if (!mounted ||
          seq != _searchSeq ||
          token.isCancelled ||
          e.type == DioExceptionType.cancel) {
        return;
      }
      setState(() {
        _isLoading = false;
        _errorMessage = _friendlyCatalogError(e);
      });
    } catch (e) {
      if (!mounted || seq != _searchSeq || token.isCancelled) return;
      setState(() {
        _isLoading = false;
        _errorMessage = _friendlyCatalogError(e);
      });
    }
  }

  Map<int, RomDownloadStatus> _currentStatuses() =>
      widget.downloadStatusesListenable?.value ?? widget.downloadStatuses;

  void _openGameDetailModal(EmulationGame game) {
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
        onStatusChanged: (newStatus) => widget.onStatusUpdated(game, newStatus),
        onPlayPressed: (localPath) =>
            widget.onLaunchGameInLibretro(game, localPath),
      ),
    );
  }

  void _executeCardAction(EmulationGame game, RomDownloadStatus status) {
    if (status.state == RomActionState.readyToPlay &&
        status.localPath != null) {
      widget.onLaunchGameInLibretro(game, status.localPath!);
      return;
    }
    if (status.state == RomActionState.downloading) {
      widget.downloadService.cancelDownload(game.igdbId);
      return;
    }
    if (game.directRomUrl.startsWith('external://')) {
      _openGameDetailModal(game);
      return;
    }
    unawaited(
      widget.downloadService.startBackgroundDownload(
        game: game,
        onStatus: (st) => widget.onStatusUpdated(game, st),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = HydraTokens.isWideLayout(context);
    final selectedPlatformSpec = _selectedPlatformSlug == 'todos'
        ? null
        : kRommPlatforms
            .where((p) => p.slug == _selectedPlatformSlug)
            .firstOrNull;

    final canLoadMore = _selectedPlatformSlug != 'todos' &&
        _searchController.text.trim().isEmpty &&
        widget.apiService.hasMoreRetroApiGames(
          _selectedPlatformSlug,
          _currentPlatformRetroCount,
        );

    final effectiveError = _errorMessage ??
        (_results.isEmpty && !widget.isLoadingCatalog
            ? widget.catalogError
            : null);
    final effectiveLoading = _isLoading ||
        (_results.isEmpty && widget.isLoadingCatalog && effectiveError == null);

    final safeSelectedIndex = _filteredResults.isEmpty
        ? 0
        : _selectedIndex.clamp(0, _filteredResults.length - 1);

    return Focus(
      focusNode: _screenFocusNode,
      autofocus: widget.isActive,
      canRequestFocus: widget.isActive,
      descendantsAreFocusable: widget.isActive,
      onFocusChange: (hasFocus) {
        if (!hasFocus && _gamepadNavActive) {
          setState(() => _gamepadNavActive = false);
        }
      },
      onKeyEvent: _handleScreenKeyEvent,
      child: Scaffold(
        backgroundColor: HydraTokens.bgPureBlack,
        body: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Cabeçalho fixo compacto (título, busca e ordenação/visualização)
              Container(
                decoration: const BoxDecoration(
                  gradient: HydraTokens.heroBackgroundGradient,
                  border: Border(
                    bottom: BorderSide(color: HydraTokens.borderSubtle8),
                  ),
                ),
                padding: EdgeInsets.fromLTRB(
                  18,
                  isLandscape
                      ? MediaQuery.paddingOf(context).top + 58
                      : MediaQuery.paddingOf(context).top + 14,
                  18,
                  isLandscape ? 8 : 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Catálogo de ROMs',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
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
                            width: 260,
                            height: 48,
                            child: HydraTexturedCard(
                              backgroundColor: HydraTokens.bgNearBlack,
                              borderRadius: 20,
                              child: Center(
                                child: TextField(
                                  controller: _searchController,
                                  focusNode: _searchFocusNode,
                                  onSubmitted: (q) {
                                    unawaited(_performSearch(q));
                                    if (widget.isActive) {
                                      _screenFocusNode.requestFocus();
                                    }
                                  },
                                  textInputAction: TextInputAction.search,
                                  style: const TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w600,
                                    color: HydraTokens.textPrimary,
                                  ),
                                  decoration: InputDecoration(
                                    filled: false,
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
                                    suffixIcon: IconButton(
                                      tooltip: 'Buscar',
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      onPressed: () {
                                        unawaited(
                                          _performSearch(
                                            _searchController.text,
                                          ),
                                        );
                                        if (widget.isActive) {
                                          _screenFocusNode.requestFocus();
                                        }
                                      },
                                      icon: PhosphorIcon(
                                        PhosphorIcons.arrowRight(
                                          PhosphorIconsStyle.bold,
                                        ),
                                        color: HydraTokens.primaryAurora,
                                        size: 16,
                                      ),
                                    ),
                                    border: InputBorder.none,
                                    enabledBorder: InputBorder.none,
                                    focusedBorder: InputBorder.none,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 12,
                                    ),
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
                            border:
                                Border.all(color: HydraTokens.borderSubtle8),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Semantics(
                                button: true,
                                label: 'Ordenar por ${_sortMode.shortLabel}',
                                child: Tooltip(
                                  message:
                                      'Alternar ordenação (${_sortMode.shortLabel})',
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      minWidth: 48,
                                      minHeight: 48,
                                    ),
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(10),
                                      onTap: _cycleSortMode,
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            PhosphorIcon(
                                              PhosphorIcons.arrowsDownUp(
                                                PhosphorIconsStyle.bold,
                                              ),
                                              size: 14,
                                              color: HydraTokens.primaryAurora,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              _sortMode.shortLabel,
                                              style: const TextStyle(
                                                fontFamily: 'ReadexPro',
                                                fontSize: 11.5,
                                                fontWeight: FontWeight.w600,
                                                color: HydraTokens.textPrimary,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Container(
                                width: 1,
                                height: 24,
                                color: HydraTokens.borderSubtle8,
                              ),
                              _ViewToggleIcon(
                                icon: PhosphorIcons.squaresFour(
                                  _gridViewMode
                                      ? PhosphorIconsStyle.fill
                                      : PhosphorIconsStyle.regular,
                                ),
                                active: _gridViewMode,
                                tooltip: 'Visualização em grade',
                                onTap: () =>
                                    setState(() => _gridViewMode = true),
                              ),
                              _ViewToggleIcon(
                                icon: PhosphorIcons.listBullets(
                                  !_gridViewMode
                                      ? PhosphorIconsStyle.fill
                                      : PhosphorIconsStyle.regular,
                                ),
                                active: !_gridViewMode,
                                tooltip: 'Visualização em lista',
                                onTap: () =>
                                    setState(() => _gridViewMode = false),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (!isLandscape) ...[
                      const SizedBox(height: 10),
                      HydraTexturedCard(
                        backgroundColor: HydraTokens.bgNearBlack,
                        borderRadius: 22,
                        child: SizedBox(
                          height: 48,
                          child: TextField(
                            controller: _searchController,
                            focusNode: _searchFocusNode,
                            onSubmitted: (q) {
                              unawaited(_performSearch(q));
                              if (widget.isActive) {
                                _screenFocusNode.requestFocus();
                              }
                            },
                            textInputAction: TextInputAction.search,
                            style: const TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                              color: HydraTokens.textPrimary,
                            ),
                            decoration: InputDecoration(
                              filled: false,
                              hintText:
                                  'Buscar jogo ou console (ex.: Zelda, Sonic, Metal Slug)...',
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
                                tooltip: 'Buscar jogos',
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed: () {
                                  unawaited(
                                    _performSearch(_searchController.text),
                                  );
                                  if (widget.isActive) {
                                    _screenFocusNode.requestFocus();
                                  }
                                },
                                icon: PhosphorIcon(
                                  PhosphorIcons.arrowRight(
                                    PhosphorIconsStyle.bold,
                                  ),
                                  color: HydraTokens.primaryAurora,
                                  size: 17,
                                ),
                              ),
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Filtros roláveis + Conteúdo (nunca estoura em landscape baixo!)
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final double gridAvailWidth = (constraints.maxWidth - 36.0)
                        .clamp(1.0, double.infinity);
                    const double maxExtent = 185.0;
                    const double crossSpacing = 14.0;
                    const double mainSpacing = 14.0;
                    const double aspectRatio = 0.66;
                    final int cols = math.max(
                      1,
                      (gridAvailWidth / (maxExtent + crossSpacing)).ceil(),
                    );
                    final double usableWidth = math.max(
                      0.0,
                      gridAvailWidth - crossSpacing * (cols - 1),
                    );
                    final double childCross = usableWidth / cols;
                    final double childMain = childCross / aspectRatio;
                    _gridColumns = cols;
                    _gridChildMainAxisExtent = childMain;
                    _gridMainAxisStride = childMain + mainSpacing;

                    return CustomScrollView(
                      controller: _scrollController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: Container(
                            key: _filterHeaderKey,
                            decoration: const BoxDecoration(
                              color: HydraTokens.bgPureBlack,
                              border: Border(
                                bottom: BorderSide(
                                  color: HydraTokens.borderSubtle8,
                                ),
                              ),
                            ),
                            padding: EdgeInsets.fromLTRB(
                              18,
                              isLandscape ? 8 : 10,
                              18,
                              isLandscape ? 8 : 10,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 1. Categorias principais
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children:
                                        RommPlatformCategory.values.map((cat) {
                                      final active = _selectedCategory == cat;
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: Semantics(
                                          button: true,
                                          selected: active,
                                          label: 'Categoria ${cat.label}',
                                          child: ConstrainedBox(
                                            constraints: const BoxConstraints(
                                              minWidth: 48,
                                              minHeight: 48,
                                            ),
                                            child: InkWell(
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              onTap: () => _selectCategory(cat),
                                              child: Center(
                                                widthFactor: 1.0,
                                                child: Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 12,
                                                    vertical: 6,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: active
                                                        ? Colors.white
                                                            .withOpacity(0.14)
                                                        : Colors.transparent,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      14,
                                                    ),
                                                    border: Border.all(
                                                      color: active
                                                          ? HydraTokens
                                                              .primaryAurora
                                                              .withOpacity(0.85)
                                                          : HydraTokens
                                                              .borderSubtle8,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    cat.label,
                                                    style: TextStyle(
                                                      fontFamily: 'ReadexPro',
                                                      fontSize: 11.5,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: active
                                                          ? HydraTokens
                                                              .primaryAurora
                                                          : HydraTokens
                                                              .textSecondary,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // 2. Consoles filtrados pela categoria ativa (LoopPlatformChip)
                                SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: _visiblePlatforms.map((plat) {
                                      final active =
                                          _selectedPlatformSlug == plat.slug;
                                      final count = _platformCounts[
                                              plat.slug.toLowerCase()] ??
                                          0;
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 8),
                                        child: LoopPlatformChip(
                                          label: plat.shortName,
                                          count: count,
                                          selected: active,
                                          compact: isLandscape,
                                          accentColor: plat.accentColor,
                                          onTap: () => unawaited(
                                            _selectPlatform(plat.slug),
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // 3. Gêneros + contador total visível
                                Row(
                                  children: [
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          children:
                                              _genreFilterLabels.map((genre) {
                                            final active =
                                                _selectedGenre == genre;
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                right: 6,
                                              ),
                                              child: Semantics(
                                                button: true,
                                                selected: active,
                                                label: 'Gênero $genre',
                                                child: ConstrainedBox(
                                                  constraints:
                                                      const BoxConstraints(
                                                    minWidth: 48,
                                                    minHeight: 48,
                                                  ),
                                                  child: InkWell(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                    onTap: () => setState(() {
                                                      _selectedGenre = genre;
                                                      _selectedIndex = 0;
                                                      _recomputeFilteredCache();
                                                    }),
                                                    child: Center(
                                                      widthFactor: 1.0,
                                                      child: Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                          horizontal: 10,
                                                          vertical: 5,
                                                        ),
                                                        decoration:
                                                            BoxDecoration(
                                                          color: active
                                                              ? HydraTokens
                                                                  .primaryAurora
                                                                  .withOpacity(
                                                                  0.18,
                                                                )
                                                              : Colors
                                                                  .transparent,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(12),
                                                          border: Border.all(
                                                            color: active
                                                                ? HydraTokens
                                                                    .primaryAurora
                                                                : HydraTokens
                                                                    .borderSubtle8,
                                                          ),
                                                        ),
                                                        child: Text(
                                                          genre,
                                                          style: TextStyle(
                                                            fontFamily: 'Rubik',
                                                            fontSize: 11,
                                                            fontWeight: active
                                                                ? FontWeight
                                                                    .w600
                                                                : FontWeight
                                                                    .w500,
                                                            color: active
                                                                ? HydraTokens
                                                                    .primaryAurora
                                                                : HydraTokens
                                                                    .textSecondary,
                                                          ),
                                                        ),
                                                      ),
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
                                      '${_filteredResults.length} jogos',
                                      style: const TextStyle(
                                        fontFamily: 'JetBrainsMono',
                                        fontSize: 11,
                                        color: HydraTokens.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                        if (effectiveLoading)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: LoopEmptyState.loading(
                                  title: 'Carregando catálogo...',
                                  subtitle:
                                      'Buscando jogos compatíveis para esta plataforma.',
                                ),
                              ),
                            ),
                          )
                        else if (effectiveError != null)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: LoopEmptyState.error(
                                  title: 'Falha ao carregar catálogo',
                                  subtitle: effectiveError,
                                  actionLabel: 'Tentar novamente',
                                  onAction: () {
                                    final q = _searchController.text.trim();
                                    if (q.isNotEmpty) {
                                      unawaited(_performSearch(q));
                                    } else if (_selectedPlatformSlug !=
                                        'todos') {
                                      unawaited(
                                        _selectPlatform(_selectedPlatformSlug),
                                      );
                                    } else {
                                      unawaited(_loadInitialRealCatalog());
                                    }
                                  },
                                ),
                              ),
                            ),
                          )
                        else ...[
                          if (selectedPlatformSpec?.coreNote != null)
                            SliverToBoxAdapter(
                              child: Padding(
                                key: _coreNoteKey,
                                padding:
                                    const EdgeInsets.fromLTRB(18, 12, 18, 2),
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
                                        color: selectedPlatformSpec.accentColor,
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          selectedPlatformSpec.coreNote!,
                                          style: const TextStyle(
                                            fontFamily: 'Rubik',
                                            fontSize: 12,
                                            color: HydraTokens.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          if (_filteredResults.isEmpty)
                            SliverFillRemaining(
                              hasScrollBody: false,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(24),
                                  child: LoopEmptyState(
                                    title: 'Nenhum jogo encontrado',
                                    subtitle:
                                        'Nenhum jogo corresponde aos filtros ou busca atuais.',
                                    actionLabel: 'Limpar filtros',
                                    actionIcon: PhosphorIcons.funnelSimpleX(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    onAction: _clearAllFilters,
                                  ),
                                ),
                              ),
                            )
                          else if (_gridViewMode)
                            _CatalogStatusesSliver(
                              listenable: widget.downloadStatusesListenable,
                              fallback: widget.downloadStatuses,
                              builder: (context, statuses) => SliverPadding(
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
                                      final game = _filteredResults[index];
                                      final status = statuses[game.igdbId] ??
                                          const RomDownloadStatus();
                                      final isFocusedCard = _gamepadNavActive &&
                                          index == safeSelectedIndex;
                                      return Semantics(
                                        selected: isFocusedCard,
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 140,
                                          ),
                                          decoration: BoxDecoration(
                                            borderRadius:
                                                BorderRadius.circular(14),
                                            boxShadow: isFocusedCard
                                                ? HydraTokens.neonBoxGlow(
                                                    opacity: 0.28,
                                                    blur: 14,
                                                    color: HydraTokens
                                                        .primaryAurora,
                                                  )
                                                : null,
                                          ),
                                          foregroundDecoration: isFocusedCard
                                              ? BoxDecoration(
                                                  borderRadius:
                                                      BorderRadius.circular(14),
                                                  border: Border.all(
                                                    color: HydraTokens
                                                        .primaryAurora,
                                                    width: 2.2,
                                                  ),
                                                )
                                              : null,
                                          child: RommCoverGridCard(
                                            game: game,
                                            status: status,
                                            onTap: () {
                                              setState(
                                                () => _selectedIndex = index,
                                              );
                                              _openGameDetailModal(game);
                                            },
                                            onActionTap: () =>
                                                _executeCardAction(
                                              game,
                                              status,
                                            ),
                                          ),
                                        ),
                                      );
                                    },
                                    childCount: _filteredResults.length,
                                  ),
                                ),
                              ),
                            )
                          else
                            _CatalogStatusesSliver(
                              listenable: widget.downloadStatusesListenable,
                              fallback: widget.downloadStatuses,
                              builder: (context, statuses) => SliverPadding(
                                padding: const EdgeInsets.all(18),
                                sliver: SliverList.separated(
                                  itemCount: _filteredResults.length,
                                  separatorBuilder: (_, __) =>
                                      const SizedBox(height: 12),
                                  itemBuilder: (context, index) {
                                    final game = _filteredResults[index];
                                    final status = statuses[game.igdbId] ??
                                        const RomDownloadStatus();
                                    final isFocusedCard = _gamepadNavActive &&
                                        index == safeSelectedIndex;
                                    return Semantics(
                                      selected: isFocusedCard,
                                      child: _RomListRowCard(
                                        game: game,
                                        status: status,
                                        isFocused: isFocusedCard,
                                        onTap: () {
                                          setState(
                                            () => _selectedIndex = index,
                                          );
                                          _openGameDetailModal(game);
                                        },
                                        onActionTap: () =>
                                            _executeCardAction(game, status),
                                      ),
                                    );
                                  },
                                ),
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
                                        : () => unawaited(
                                              _loadMoreForSelectedPlatform(),
                                            ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor:
                                          HydraTokens.primaryAurora,
                                      minimumSize: const Size(48, 48),
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
                                              color: HydraTokens.primaryAurora,
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
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CatalogStatusesSliver extends StatelessWidget {
  const _CatalogStatusesSliver({
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

class _ViewToggleIcon extends StatelessWidget {
  const _ViewToggleIcon({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: active,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Center(
              widthFactor: 1.0,
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: active
                      ? HydraTokens.primaryAurora.withOpacity(0.18)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: PhosphorIcon(
                  icon,
                  size: 17,
                  color: active
                      ? HydraTokens.primaryAurora
                      : HydraTokens.textSecondary,
                ),
              ),
            ),
          ),
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
    required this.onActionTap,
    this.isFocused = false,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;
  final VoidCallback onActionTap;
  final bool isFocused;

  @override
  Widget build(BuildContext context) {
    final isReady =
        status.state == RomActionState.readyToPlay && status.localPath != null;
    final isDownloading = status.state == RomActionState.downloading;
    final isPaused = status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');

    final actionLabel = isReady
        ? 'Jogar'
        : isDownloading
            ? 'Cancelar'
            : isExternal
                ? 'Detalhes'
                : isPaused
                    ? 'Continuar'
                    : 'Baixar';

    final actionSemantic = isReady
        ? 'Jogar ${game.name}'
        : isDownloading
            ? 'Cancelar download de ${game.name}'
            : isExternal
                ? 'Ver detalhes de ${game.name}'
                : isPaused
                    ? 'Continuar download de ${game.name}'
                    : 'Baixar ${game.name}';

    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        boxShadow: isFocused
            ? HydraTokens.neonBoxGlow(
                opacity: 0.26,
                blur: 12,
                color: HydraTokens.primaryAurora,
              )
            : null,
      ),
      foregroundDecoration: isFocused
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: HydraTokens.primaryAurora,
                width: 2.0,
              ),
            )
          : null,
      child: HydraTexturedCard(
        backgroundColor: HydraTokens.bgNearBlack,
        borderRadius: 14,
        highlightedBorder: isReady || isFocused,
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
                  preset: LoopCoverImagePreset.thumbnail,
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
                      Expanded(
                        child: Text(
                          isDownloading
                              ? 'Baixando ${LoopProgressIndicator.formatPercent(status.progress)}'
                              : '${game.formattedSize} • ${game.romFormatLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11,
                            color: isDownloading
                                ? HydraTokens.primaryAurora
                                : HydraTokens.textSecondary,
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
                  if (isDownloading) ...[
                    const SizedBox(height: 6),
                    LoopProgressIndicator(
                      progress: status.progress,
                      showLabelRow: false,
                      minHeight: 4,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Semantics(
              button: true,
              label: actionSemantic,
              child: Tooltip(
                message: actionSemantic,
                child: isReady
                    ? FilledButton(
                        onPressed: onActionTap,
                        style: FilledButton.styleFrom(
                          backgroundColor: HydraTokens.primaryAurora,
                          foregroundColor: HydraTokens.bgPureBlack,
                          minimumSize: const Size(76, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          actionLabel,
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      )
                    : OutlinedButton(
                        onPressed: onActionTap,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: isDownloading
                              ? HydraTokens.accentDanger
                              : HydraTokens.textPrimary,
                          backgroundColor: HydraTokens.surfaceElevated1,
                          minimumSize: const Size(76, 48),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          side: BorderSide(
                            color: isDownloading
                                ? HydraTokens.accentDanger.withOpacity(0.55)
                                : HydraTokens.borderSubtle10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                        child: Text(
                          actionLabel,
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
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

/// Ficha de Jogo com Download Turbo em 2º Plano e Feedback Inline de Erros
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
  final FocusNode _sheetFocusNode = FocusNode(
    debugLabel: 'GameDetailSheetFocus',
  );
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
      if (event.game.igdbId == widget.game.igdbId && mounted) {
        setState(() => _status = event.status);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _sheetFocusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    final sub = _sub;
    if (sub != null) {
      unawaited(sub.cancel());
    }
    _sheetFocusNode.dispose();
    super.dispose();
  }

  String _sanitizeDownloadError(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return 'Não foi possível baixar este jogo. Verifique sua conexão e tente novamente.';
    }
    final lower = trimmed.toLowerCase();
    if (lower.startsWith('exception:') ||
        lower.contains('dioexception') ||
        lower.contains('socketexception') ||
        lower.contains('stacktrace')) {
      return 'Erro de conexão durante o download. Tente novamente em instantes.';
    }
    return trimmed;
  }

  Future<void> _startBackgroundDownload() async {
    unawaited(
      widget.downloadService.startBackgroundDownload(
        game: widget.game,
        onStatus: (st) {
          widget.onStatusChanged(st);
          if (mounted) {
            setState(() => _status = st);
          }
        },
      ),
    );
  }

  VoidCallback? _resolvePrimaryAction() {
    final canPlay = _status.state == RomActionState.readyToPlay &&
        _status.localPath != null;
    final isDownloading = _status.state == RomActionState.downloading;
    final isExternal = widget.game.directRomUrl.startsWith('external://');

    if (canPlay) {
      return () => widget.onPlayPressed(_status.localPath!);
    }
    if (isDownloading) {
      return () => widget.downloadService.pauseDownload(widget.game.igdbId);
    }
    if (isExternal) {
      // Jogos externos são importados na Biblioteca ou configurados via RomM.
      return null;
    }
    return () => unawaited(_startBackgroundDownload());
  }

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final canPlay = _status.state == RomActionState.readyToPlay &&
        _status.localPath != null;
    final isDownloading = _status.state == RomActionState.downloading;
    final isPaused = _status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');
    final rawError = _status.errorMessage?.trim() ?? '';
    final isCancelledNotice = rawError.toLowerCase().contains('cancelado');
    final hasError = rawError.isNotEmpty && !isCancelledNotice;
    final hasWarning = _status.warningMessage != null &&
        _status.warningMessage!.trim().isNotEmpty;
    final primaryAction = _resolvePrimaryAction();

    return Focus(
      focusNode: _sheetFocusNode,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.gameButtonB ||
            key == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.gameButtonA ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.select) {
          primaryAction?.call();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: DraggableScrollableSheet(
        initialChildSize: 0.84,
        minChildSize: 0.58,
        maxChildSize: 0.94,
        builder: (context, scrollController) {
          return Container(
            decoration: BoxDecoration(
              color: HydraTokens.bgPureBlack,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              border: Border.all(color: HydraTokens.borderSubtle10),
            ),
            child: ClipRRect(
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(22)),
              child: SafeArea(
                top: false,
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
                            preset: LoopCoverImagePreset.hero,
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
                            top: 6,
                            right: 10,
                            child: Semantics(
                              button: true,
                              label: 'Fechar ficha do jogo',
                              child: IconButton(
                                tooltip: 'Fechar',
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                onPressed: () => Navigator.of(context).pop(),
                                icon: PhosphorIcon(
                                  PhosphorIcons.x(PhosphorIconsStyle.bold),
                                  size: 18,
                                  color: HydraTokens.textPrimary,
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
                                      preset: LoopCoverImagePreset.thumbnail,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 3,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withOpacity(0.10),
                                          borderRadius:
                                              BorderRadius.circular(6),
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
                          // 2. Barra de Ação Principal + Erro Inline Visível
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: HydraTokens.bgNearBlack,
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: HydraTokens.borderSubtle8),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  height: 48,
                                  child: FilledButton(
                                    style: FilledButton.styleFrom(
                                      backgroundColor:
                                          HydraTokens.primaryAurora,
                                      foregroundColor: HydraTokens.bgPureBlack,
                                      disabledBackgroundColor:
                                          HydraTokens.surfaceElevated1,
                                      disabledForegroundColor:
                                          HydraTokens.textSecondary,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                    onPressed: primaryAction,
                                    child: Text(
                                      canPlay
                                          ? 'Jogar Agora'
                                          : isDownloading
                                              ? 'Pausar ${LoopProgressIndicator.formatPercent(_status.progress)} (${_status.speedLabel ?? "Turbo"})'
                                              : isExternal
                                                  ? 'Importe pela Biblioteca'
                                                  : isPaused
                                                      ? 'Continuar (${LoopProgressIndicator.formatPercent(_status.progress)})'
                                                      : game.hasKnownSize
                                                          ? 'Baixar (${game.formattedSize})'
                                                          : 'Baixar ROM',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'ReadexPro',
                                        fontSize: 13.5,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                                if (isExternal &&
                                    !canPlay &&
                                    !isDownloading) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: HydraTokens.surfaceElevated1,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: HydraTokens.borderSubtle10,
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        PhosphorIcon(
                                          PhosphorIcons.info(
                                            PhosphorIconsStyle.bold,
                                          ),
                                          size: 16,
                                          color: HydraTokens.primaryAurora,
                                        ),
                                        const SizedBox(width: 8),
                                        const Expanded(
                                          child: Text(
                                            'Use a opção "Importar ISO" na Biblioteca ou configure um servidor RomM nos Ajustes.',
                                            style: TextStyle(
                                              fontFamily: 'Rubik',
                                              fontSize: 12,
                                              height: 1.4,
                                              color: HydraTokens.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (isDownloading) ...[
                                  const SizedBox(height: 12),
                                  LoopProgressIndicator(
                                    progress: _status.progress,
                                    label:
                                        'Download ativo em 2º plano (visível na Biblioteca)',
                                    minHeight: 7,
                                  ),
                                  const SizedBox(height: 6),
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.end,
                                    children: [
                                      TextButton(
                                        onPressed: () => widget.downloadService
                                            .cancelDownload(game.igdbId),
                                        style: TextButton.styleFrom(
                                          foregroundColor:
                                              HydraTokens.accentDanger,
                                          minimumSize: const Size(48, 48),
                                        ),
                                        child: const Text(
                                          'Cancelar',
                                          style: TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(),
                                        style: TextButton.styleFrom(
                                          foregroundColor:
                                              HydraTokens.primaryAurora,
                                          minimumSize: const Size(48, 48),
                                        ),
                                        child: const Text(
                                          'Minimizar',
                                          style: TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                                if (isCancelledNotice) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 9,
                                    ),
                                    decoration: BoxDecoration(
                                      color: HydraTokens.surfaceElevated1,
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: HydraTokens.borderSubtle10,
                                      ),
                                    ),
                                    child: Row(
                                      children: [
                                        PhosphorIcon(
                                          PhosphorIcons.info(
                                            PhosphorIconsStyle.bold,
                                          ),
                                          size: 16,
                                          color: HydraTokens.textSecondary,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            rawError,
                                            style: const TextStyle(
                                              fontFamily: 'Rubik',
                                              fontSize: 12,
                                              color: HydraTokens.textSecondary,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (hasError) ...[
                                  const SizedBox(height: 12),
                                  Semantics(
                                    liveRegion: true,
                                    label:
                                        'Erro no download: ${_sanitizeDownloadError(_status.errorMessage!)}',
                                    child: Container(
                                      padding: const EdgeInsets.all(12),
                                      decoration: BoxDecoration(
                                        color: HydraTokens.accentDanger
                                            .withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(
                                          color: HydraTokens.accentDanger
                                              .withOpacity(0.55),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              PhosphorIcon(
                                                PhosphorIcons.warningCircle(
                                                  PhosphorIconsStyle.fill,
                                                ),
                                                size: 18,
                                                color: HydraTokens.accentDanger,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      'Falha ao baixar ROM',
                                                      style: TextStyle(
                                                        fontFamily: 'ReadexPro',
                                                        fontSize: 12.5,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        color: HydraTokens
                                                            .textPrimary,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      _sanitizeDownloadError(
                                                        _status.errorMessage!,
                                                      ),
                                                      style: const TextStyle(
                                                        fontFamily: 'Rubik',
                                                        fontSize: 12,
                                                        height: 1.4,
                                                        color: HydraTokens
                                                            .textPrimary,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (!isExternal) ...[
                                            const SizedBox(height: 10),
                                            Align(
                                              alignment: Alignment.centerRight,
                                              child: FilledButton.icon(
                                                onPressed: () => unawaited(
                                                  _startBackgroundDownload(),
                                                ),
                                                style: FilledButton.styleFrom(
                                                  backgroundColor:
                                                      HydraTokens.accentDanger,
                                                  foregroundColor:
                                                      HydraTokens.textPrimary,
                                                  minimumSize:
                                                      const Size(48, 48),
                                                ),
                                                icon: PhosphorIcon(
                                                  PhosphorIcons.arrowClockwise(
                                                    PhosphorIconsStyle.bold,
                                                  ),
                                                  size: 15,
                                                ),
                                                label: const Text(
                                                  'Tentar novamente',
                                                  style: TextStyle(
                                                    fontFamily: 'ReadexPro',
                                                    fontSize: 12,
                                                    fontWeight: FontWeight.w700,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                                if (hasWarning) ...[
                                  const SizedBox(height: 10),
                                  Container(
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: HydraTokens.accentAmber
                                          .withOpacity(0.12),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: HydraTokens.accentAmber
                                            .withOpacity(0.45),
                                      ),
                                    ),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        PhosphorIcon(
                                          PhosphorIcons.warning(
                                            PhosphorIconsStyle.bold,
                                          ),
                                          size: 16,
                                          color: HydraTokens.accentAmber,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _status.warningMessage!,
                                            style: const TextStyle(
                                              fontFamily: 'Rubik',
                                              fontSize: 12,
                                              color: HydraTokens.textPrimary,
                                            ),
                                          ),
                                        ),
                                      ],
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
                              border:
                                  Border.all(color: HydraTokens.borderSubtle8),
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
                                          subValue:
                                              'Formato ${game.romFormatLabel}',
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
                              border:
                                  Border.all(color: HydraTokens.borderSubtle8),
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
            ),
          );
        },
      ),
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
              fontSize: 10.5,
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
