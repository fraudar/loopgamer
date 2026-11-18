import 'dart:async';
import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/app_settings.dart';
import '../models/emulation_game.dart';
import '../services/game_asset_service.dart';
import '../services/igdb_steamgriddb_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import '../theme/ps5_hydra_theme.dart';
import '../widgets/animated_game_logo.dart';
import '../widgets/loop_common_widgets.dart';
import '../widgets/procedural_cover.dart';
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
  final GlobalKey _coreNoteKey = GlobalKey();
  final TextEditingController _searchController = TextEditingController();
  final Map<int, GameAssets> _resolvedAssets = {};
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
  int _gridColumns = 4;
  double _gridChildMainAxisExtent = 186.0;
  double _gridMainAxisStride = 198.0;

  CancelToken? _searchCancelToken;
  CancelToken? _platformCancelToken;
  Timer? _searchDebounceTimer;
  Timer? _prefetchBatchTimer;
  final Map<int, GameAssets> _pendingPrefetchAssets = {};
  int _searchSeq = 0;
  int _platformLoadSeq = 0;

  @override
  void initState() {
    super.initState();
    _recomputeFilteredCache();
    _prefetchAssetsFor(_filteredResults);
    unawaited(_loadInitialRealCatalog());
    if (widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.isActive && !_isPrimaryFocusEditable()) {
          _screenFocusNode.requestFocus();
        }
      });
    }
  }

  void _prefetchAssetsFor(List<EmulationGame> games) {
    bool resolvedImmediately = false;
    for (final game in games.take(16)) {
      if (_resolvedAssets.containsKey(game.igdbId)) continue;
      final cached = GameAssetService.instance.getCachedAssets(
        game.name,
        platformSlug: game.platformSlug,
      );
      if (cached != null) {
        _resolvedAssets[game.igdbId] = cached;
        resolvedImmediately = true;
        continue;
      }
      unawaited(
        GameAssetService.instance.fetchAssetsForGame(game).then((assets) {
          if (!mounted) return;
          if (assets.hasBackground || assets.hasCover || assets.hasLogo) {
            _pendingPrefetchAssets[game.igdbId] = assets;
            _prefetchBatchTimer ??= Timer(
              const Duration(milliseconds: 280),
              _flushPendingPrefetchAssets,
            );
          }
        }),
      );
    }
    if (resolvedImmediately && mounted) {
      // Já refletido sem disparar dezenas de rebuilds extras.
    }
  }

  void _flushPendingPrefetchAssets() {
    _prefetchBatchTimer = null;
    if (!mounted || _pendingPrefetchAssets.isEmpty) return;
    setState(() {
      _resolvedAssets.addAll(_pendingPrefetchAssets);
      _pendingPrefetchAssets.clear();
    });
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
    _searchDebounceTimer?.cancel();
    _prefetchBatchTimer?.cancel();
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

    final coreNoteHeight =
        (_coreNoteKey.currentContext?.findRenderObject() as RenderBox?)
                ?.size
                .height ??
            0.0;
    const double sliverTopPadding = 16.0;
    final double baseTop = coreNoteHeight + sliverTopPadding;

    final double itemTop;
    final double itemBottom;
    if (_gridViewMode) {
      final cols = math.max(1, _gridColumns);
      final row = idx ~/ cols;
      itemTop = baseTop + row * _gridMainAxisStride;
      itemBottom = itemTop + _gridChildMainAxisExtent;
    } else {
      const double listRowHeight = 82.0;
      const double listRowStride = 92.0;
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
    final normSearchQuery = EmulationGame.normalizeSearchText(
      _searchController.text,
    );
    final searchTokens =
        normSearchQuery.split(' ').where((t) => t.isNotEmpty).toList();
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
      if (searchTokens.isNotEmpty) {
        final normName = EmulationGame.normalizeSearchText(
          '${g.name} ${g.developer} ${g.platformName}',
        );
        final matchesAll = searchTokens.every(normName.contains);
        if (!matchesAll) continue;
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
      _prefetchAssetsFor(_filteredResults);
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
      _prefetchAssetsFor(_filteredResults);
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

  void _clearAllFilters() {
    _searchDebounceTimer?.cancel();
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

  void _onSearchChanged(String query) {
    _searchDebounceTimer?.cancel();
    // Filtragem local instantânea no catálogo em memória sem travar a digitação.
    setState(() {
      _selectedIndex = 0;
      _errorMessage = null;
      _recomputeFilteredCache();
    });
    final trimmed = query.trim();
    _searchDebounceTimer = Timer(
      const Duration(milliseconds: 280),
      () => unawaited(_performSearch(trimmed, silentLoading: trimmed.isEmpty)),
    );
  }

  Future<void> _performSearch(String query, {bool silentLoading = false}) async {
    _searchDebounceTimer?.cancel();
    final seq = ++_searchSeq;
    _searchCancelToken?.cancel('Superseded by new search');
    final token = CancelToken();
    _searchCancelToken = token;

    if (!silentLoading) {
      setState(() {
        _isLoading = true;
        _selectedIndex = 0;
        _errorMessage = null;
      });
    }

    try {
      final games = await widget.apiService.searchGames(
        query,
        platformFilter: _selectedPlatformSlug,
        rommServerUrl: widget.settings.rommServerUrl,
        rommApiToken: widget.settings.rommApiToken,
        cancelToken: token,
      );
      if (!mounted || seq != _searchSeq || token.isCancelled) return;

      final resolvedPaths = await widget.downloadService
          .resolveExistingRomPathsBatch(games.map((g) => g.igdbId));
      if (!mounted || seq != _searchSeq || token.isCancelled) return;

      final batch = <EmulationGame, RomDownloadStatus>{
        for (final game in games)
          if (resolvedPaths[game.igdbId] != null)
            game: RomDownloadStatus(
              state: RomActionState.readyToPlay,
              progress: 1.0,
              localPath: resolvedPaths[game.igdbId],
            ),
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
      _prefetchAssetsFor(_filteredResults);
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
    final focusedGame =
        _filteredResults.isNotEmpty ? _filteredResults[safeSelectedIndex] : null;
    final focusedBannerUrl = focusedGame == null
        ? null
        : (_resolvedAssets[focusedGame.igdbId]?.backgroundImageUrl ??
            focusedGame.heroBannerUrl ??
            focusedGame.resolvedHeroBannerUrl);
    final safePlatformValue =
        _visiblePlatforms.any((p) => p.slug == _selectedPlatformSlug)
            ? _selectedPlatformSlug
            : 'todos';

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
        backgroundColor: PS5HydraTheme.pitchBlack,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // Fundo full-bleed discreto alinhado com Início e Biblioteca
            if (focusedGame != null &&
                focusedBannerUrl != null &&
                focusedBannerUrl.isNotEmpty)
              Opacity(
                opacity: 0.26,
                child: AnimatedSwitcher(
                  duration: PS5HydraTheme.animStandard,
                  switchInCurve: Curves.easeOut,
                  child: SizedBox.expand(
                    key: ValueKey<String>(focusedBannerUrl),
                    child: ProceduralCover(
                      title: focusedGame.name,
                      platformName: focusedGame.platformName,
                      gameId: focusedGame.igdbId,
                      isBanner: true,
                      imageUrl: focusedBannerUrl,
                      borderRadius: 0,
                      showBottomLabel: false,
                    ),
                  ),
                ),
              ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.45, 1.0],
                  colors: [
                    PS5HydraTheme.pitchBlack.withOpacity(0.58),
                    PS5HydraTheme.pitchBlack.withOpacity(0.90),
                    PS5HydraTheme.pitchBlack,
                  ],
                ),
              ),
            ),

            SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Barra única compacta: Título + Busca + Selects + Grade/Lista
                  Container(
                    decoration: BoxDecoration(
                      color: PS5HydraTheme.obsidianGlass.withOpacity(0.86),
                      border: const Border(
                        bottom: BorderSide(color: PS5HydraTheme.borderSubtle),
                      ),
                    ),
                    padding: EdgeInsets.fromLTRB(
                      20,
                      MediaQuery.paddingOf(context).top + 56,
                      20,
                      10,
                    ),
                    child: Row(
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text(
                              'Catálogo de ROMs',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: PS5HydraTheme.textPrimary,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '· ${_filteredResults.length}',
                              style: PS5HydraTheme.metaMonoStyle.copyWith(
                                fontSize: 11,
                                color: PS5HydraTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerRight,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  SizedBox(
                                    width: 128,
                                    height: 34,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: PS5HydraTheme.abyssalCard,
                                        borderRadius: BorderRadius.circular(9),
                                        border: Border.all(
                                          color: PS5HydraTheme.borderSubtle,
                                        ),
                                      ),
                                      child: TextField(
                                        controller: _searchController,
                                        focusNode: _searchFocusNode,
                                        onChanged: _onSearchChanged,
                                        onSubmitted: (q) {
                                          unawaited(_performSearch(q));
                                          if (widget.isActive) {
                                            _screenFocusNode.requestFocus();
                                          }
                                        },
                                        textInputAction: TextInputAction.search,
                                        style: const TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w600,
                                          color: PS5HydraTheme.textPrimary,
                                        ),
                                        decoration: InputDecoration(
                                          filled: false,
                                          isDense: true,
                                          hintText: 'Buscar...',
                                          hintStyle: const TextStyle(
                                            fontFamily: 'Rubik',
                                            fontSize: 11,
                                            color: PS5HydraTheme.textSecondary,
                                          ),
                                          prefixIcon: Padding(
                                            padding: const EdgeInsets.only(
                                              left: 8,
                                              right: 4,
                                            ),
                                            child: PhosphorIcon(
                                              PhosphorIcons.magnifyingGlass(
                                                PhosphorIconsStyle.regular,
                                              ),
                                              color:
                                                  PS5HydraTheme.textSecondary,
                                              size: 13,
                                            ),
                                          ),
                                          prefixIconConstraints:
                                              const BoxConstraints(
                                            minWidth: 24,
                                            minHeight: 34,
                                          ),
                                          suffixIcon: IconButton(
                                            tooltip: 'Buscar',
                                            padding: EdgeInsets.zero,
                                            constraints: const BoxConstraints(
                                              minWidth: 26,
                                              minHeight: 34,
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
                                              color: PS5HydraTheme.textPrimary,
                                              size: 12,
                                            ),
                                          ),
                                          border: InputBorder.none,
                                          enabledBorder: InputBorder.none,
                                          focusedBorder: InputBorder.none,
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _CatalogSelectPill<RommPlatformCategory>(
                                    displayLabel: _selectedCategory ==
                                            RommPlatformCategory.all
                                        ? 'Categoria'
                                        : _selectedCategory.label,
                                    isFiltered: _selectedCategory !=
                                        RommPlatformCategory.all,
                                    tooltip: 'Filtrar categoria',
                                    value: _selectedCategory,
                                    items: RommPlatformCategory.values,
                                    labelOf: (c) => c.label,
                                    onChanged: _selectCategory,
                                  ),
                                  const SizedBox(width: 6),
                                  _CatalogSelectPill<String>(
                                    displayLabel: () {
                                      final count = _platformCounts[
                                              safePlatformValue.toLowerCase()] ??
                                          0;
                                      if (safePlatformValue == 'todos') {
                                        return 'Console ($count)';
                                      }
                                      final spec = _visiblePlatforms
                                          .where(
                                            (p) => p.slug == safePlatformValue,
                                          )
                                          .firstOrNull;
                                      return spec == null
                                          ? 'Console'
                                          : '${spec.shortName} ($count)';
                                    }(),
                                    isFiltered: safePlatformValue != 'todos',
                                    tooltip: 'Filtrar console',
                                    value: safePlatformValue,
                                    items: _visiblePlatforms
                                        .map((p) => p.slug)
                                        .toList(),
                                    labelOf: (slug) {
                                      final spec = _visiblePlatforms
                                          .where((p) => p.slug == slug)
                                          .firstOrNull;
                                      final count = _platformCounts[
                                              slug.toLowerCase()] ??
                                          0;
                                      if (spec == null) return 'Todos ($count)';
                                      return '${spec.shortName} ($count)';
                                    },
                                    onChanged: (slug) =>
                                        unawaited(_selectPlatform(slug)),
                                  ),
                                  const SizedBox(width: 6),
                                  _CatalogSelectPill<String>(
                                    displayLabel: _selectedGenre == 'Todos'
                                        ? 'Gênero'
                                        : _selectedGenre,
                                    isFiltered: _selectedGenre != 'Todos',
                                    tooltip: 'Filtrar gênero',
                                    value: _selectedGenre,
                                    items: _genreFilterLabels,
                                    labelOf: (g) => g,
                                    onChanged: (genre) => setState(() {
                                      _selectedGenre = genre;
                                      _selectedIndex = 0;
                                      _recomputeFilteredCache();
                                    }),
                                  ),
                                  const SizedBox(width: 6),
                                  _CatalogSelectPill<_CatalogSortMode>(
                                    displayLabel: _sortMode.shortLabel,
                                    isFiltered:
                                        _sortMode != _CatalogSortMode.featured,
                                    tooltip: 'Ordenar catálogo',
                                    value: _sortMode,
                                    items: _CatalogSortMode.values,
                                    labelOf: (m) => m.shortLabel,
                                    onChanged: (mode) => setState(() {
                                      _sortMode = mode;
                                      _selectedIndex = 0;
                                      _recomputeFilteredCache();
                                    }),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          height: 34,
                          padding: const EdgeInsets.all(2),
                          decoration: BoxDecoration(
                            color: PS5HydraTheme.abyssalCard,
                            borderRadius: BorderRadius.circular(9),
                            border: Border.all(
                              color: PS5HydraTheme.borderSubtle,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _ViewToggleIcon(
                                icon: PhosphorIcons.squaresFour(
                                  _gridViewMode
                                      ? PhosphorIconsStyle.fill
                                      : PhosphorIconsStyle.regular,
                                ),
                                active: _gridViewMode,
                                tooltip: 'Visualização em grade',
                                onTap: () => setState(() => _gridViewMode = true),
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
                  ),

                  // Conteúdo limpo de grade / lista
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final double gridAvailWidth =
                            (constraints.maxWidth - 40.0)
                                .clamp(1.0, double.infinity);
                        const double maxExtent = 136.0;
                        const double crossSpacing = 12.0;
                        const double mainSpacing = 12.0;
                        const double aspectRatio = 0.72;
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
                            if (effectiveLoading)
                              const SliverToBoxAdapter(
                                child: Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 28,
                                    ),
                                    child: LoopEmptyState.loading(
                                      compact: true,
                                      title: 'Carregando catálogo...',
                                      subtitle:
                                          'Buscando jogos compatíveis para esta plataforma.',
                                    ),
                                  ),
                                ),
                              )
                            else if (effectiveError != null)
                              SliverToBoxAdapter(
                                child: Center(
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 24,
                                      vertical: 28,
                                    ),
                                    child: LoopEmptyState.error(
                                      compact: true,
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
                                            _selectPlatform(
                                              _selectedPlatformSlug,
                                            ),
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
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      12,
                                      20,
                                      2,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: PS5HydraTheme.abyssalCard
                                            .withOpacity(0.90),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: PS5HydraTheme.borderSubtle,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          PhosphorIcon(
                                            PhosphorIcons.info(
                                              PhosphorIconsStyle.bold,
                                            ),
                                            size: 15,
                                            color: PS5HydraTheme.textPrimary,
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Text(
                                              selectedPlatformSpec!.coreNote!,
                                              style: const TextStyle(
                                                fontFamily: 'Rubik',
                                                fontSize: 12,
                                                color:
                                                    PS5HydraTheme.textSecondary,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              if (_filteredResults.isEmpty)
                                SliverToBoxAdapter(
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 24,
                                        vertical: 28,
                                      ),
                                      child: LoopEmptyState(
                                        compact: true,
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
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      14,
                                      20,
                                      20,
                                    ),
                                    sliver: SliverGrid(
                                      gridDelegate:
                                          const SliverGridDelegateWithMaxCrossAxisExtent(
                                        maxCrossAxisExtent: 136,
                                        mainAxisSpacing: 12,
                                        crossAxisSpacing: 12,
                                        childAspectRatio: 0.72,
                                      ),
                                      delegate: SliverChildBuilderDelegate(
                                        (context, index) {
                                          final game = _filteredResults[index];
                                          final status =
                                              statuses[game.igdbId] ??
                                                  const RomDownloadStatus();
                                          final isFocusedCard =
                                              _gamepadNavActive &&
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
                                                    ? PS5HydraTheme.glowFocus
                                                    : null,
                                              ),
                                              foregroundDecoration:
                                                  isFocusedCard
                                                      ? BoxDecoration(
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(14),
                                                          border: Border.all(
                                                            color: PS5HydraTheme
                                                                .auroraSpringMint,
                                                            width: 2.0,
                                                          ),
                                                        )
                                                      : null,
                                              child: RommCoverGridCard(
                                                game: game,
                                                status: status,
                                                onTap: () {
                                                  setState(
                                                    () =>
                                                        _selectedIndex = index,
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
                                    padding: const EdgeInsets.fromLTRB(
                                      20,
                                      14,
                                      20,
                                      20,
                                    ),
                                    sliver: SliverList.separated(
                                      itemCount: _filteredResults.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (context, index) {
                                        final game = _filteredResults[index];
                                        final status = statuses[game.igdbId] ??
                                            const RomDownloadStatus();
                                        final isFocusedCard =
                                            _gamepadNavActive &&
                                                index == safeSelectedIndex;
                                        return Semantics(
                                          selected: isFocusedCard,
                                          child: _RomListRowCard(
                                            game: game,
                                            status: status,
                                            itemIndex: index,
                                            isFocused: isFocusedCard,
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
                                              PS5HydraTheme.textPrimary,
                                          backgroundColor:
                                              PS5HydraTheme.abyssalCard,
                                          minimumSize: const Size(48, 44),
                                          side: const BorderSide(
                                            color: PS5HydraTheme.borderSubtle,
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
                                                child:
                                                    CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color:
                                                      PS5HydraTheme.textPrimary,
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
          ],
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

class _CatalogSelectPill<T> extends StatelessWidget {
  const _CatalogSelectPill({
    required this.displayLabel,
    required this.isFiltered,
    required this.tooltip,
    required this.value,
    required this.items,
    required this.labelOf,
    required this.onChanged,
  });

  final String displayLabel;
  final bool isFiltered;
  final String tooltip;
  final T value;
  final List<T> items;
  final String Function(T item) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<T>(
      tooltip: tooltip,
      initialValue: value,
      onSelected: onChanged,
      color: HydraTokens.surfaceElevated1,
      elevation: 10,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: PS5HydraTheme.borderSubtle),
      ),
      itemBuilder: (context) => items.map((item) {
        final selected = item == value;
        return PopupMenuItem<T>(
          value: item,
          height: 40,
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: selected
                    ? PhosphorIcon(
                        PhosphorIcons.check(PhosphorIconsStyle.bold),
                        size: 13,
                        color: PS5HydraTheme.auroraSpringMint,
                      )
                    : null,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  labelOf(item),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: selected
                        ? PS5HydraTheme.auroraSpringMint
                        : PS5HydraTheme.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: isFiltered
              ? HydraTokens.surfaceElevated1
              : PS5HydraTheme.abyssalCard,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: isFiltered
                ? PS5HydraTheme.auroraSpringMint.withOpacity(0.65)
                : PS5HydraTheme.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 11.5,
                fontWeight: isFiltered ? FontWeight.w700 : FontWeight.w600,
                color: isFiltered
                    ? PS5HydraTheme.textPrimary
                    : PS5HydraTheme.textSecondary,
              ),
            ),
            const SizedBox(width: 5),
            PhosphorIcon(
              PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
              size: 11,
              color: isFiltered
                  ? PS5HydraTheme.textPrimary
                  : PS5HydraTheme.textSecondary,
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
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: Container(
              width: 34,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color:
                    active ? HydraTokens.surfaceElevated2 : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: PhosphorIcon(
                icon,
                size: 16,
                color: active
                    ? PS5HydraTheme.auroraSpringMint
                    : PS5HydraTheme.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RomListRowCard extends StatefulWidget {
  const _RomListRowCard({
    required this.game,
    required this.status,
    required this.onTap,
    required this.onActionTap,
    this.itemIndex = 0,
    this.isFocused = false,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
  final VoidCallback onTap;
  final VoidCallback onActionTap;
  final int itemIndex;
  final bool isFocused;

  @override
  State<_RomListRowCard> createState() => _RomListRowCardState();
}

class _RomListRowCardState extends State<_RomListRowCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final game = widget.game;
    final status = widget.status;
    final isReady =
        status.state == RomActionState.readyToPlay && status.localPath != null;
    final isDownloading = status.state == RomActionState.downloading;
    final isPaused = status.state == RomActionState.paused;
    final isExternal = game.directRomUrl.startsWith('external://');
    final active = widget.isFocused || _hovered;
    final cachedCover = GameAssetService.instance
        .getCachedAssets(game.name, platformSlug: game.platformSlug)
        ?.coverImageUrl;

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

    final actionWidget = Semantics(
      button: true,
      label: actionSemantic,
      child: Tooltip(
        message: actionSemantic,
        child: isReady
            ? FilledButton(
                onPressed: widget.onActionTap,
                style: FilledButton.styleFrom(
                  backgroundColor: PS5HydraTheme.auroraSpringMint,
                  foregroundColor: PS5HydraTheme.textOnAurora,
                  minimumSize: const Size(82, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(PS5HydraTheme.radiusChip),
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: const TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            : OutlinedButton(
                onPressed: widget.onActionTap,
                style: OutlinedButton.styleFrom(
                  foregroundColor: isDownloading
                      ? HydraTokens.accentDanger
                      : PS5HydraTheme.textPrimary,
                  backgroundColor: PS5HydraTheme.pitchBlack.withOpacity(0.65),
                  minimumSize: const Size(82, 40),
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  side: BorderSide(
                    color: isDownloading
                        ? HydraTokens.accentDanger.withOpacity(0.55)
                        : PS5HydraTheme.borderSubtle,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius:
                        BorderRadius.circular(PS5HydraTheme.radiusChip),
                  ),
                ),
                child: Text(
                  actionLabel,
                  style: const TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      ),
    );

    final infoRow = Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 46,
          height: 62,
          child: ProceduralCover(
            title: game.name,
            platformName: game.platformName,
            gameId: game.igdbId,
            accentColor: game.platformAccentColor,
            imageUrl: cachedCover ?? game.gridCoverUrl ?? game.resolvedGridCoverUrl,
            borderRadius: 8,
            compact: true,
            showBottomLabel: false,
          ),
        ),
        const SizedBox(width: PS5HydraTheme.space12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedGameLogo(
                game: game,
                height: 28,
                maxWidthFraction: 0.75,
                itemIndex: widget.itemIndex,
                enableStagger: true,
                maxLines: 1,
                fallbackStyle: const TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: PS5HydraTheme.textPrimary,
                ),
              ),
              const SizedBox(height: 5),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(game.platformName, style: PS5HydraTheme.metaMonoStyle),
                    PS5HydraTheme.metaDivider(),
                    Text(
                      isDownloading
                          ? 'Baixando ${LoopProgressIndicator.formatPercent(status.progress)}'
                          : '${game.formattedSize} · ${game.romFormatLabel}',
                      style: PS5HydraTheme.metaMonoStyle.copyWith(
                        color: isDownloading
                            ? PS5HydraTheme.auroraSpringMint
                            : PS5HydraTheme.textSecondary,
                      ),
                    ),
                    PS5HydraTheme.metaDivider(),
                    Text(
                      '${game.developer} · ${game.releaseYear ?? 2000}',
                      style: PS5HydraTheme.metaMonoStyle,
                    ),
                  ],
                ),
              ),
              if (isDownloading) ...[
                const SizedBox(height: 6),
                LoopProgressIndicator(
                  progress: status.progress,
                  showLabelRow: false,
                  minHeight: 3,
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: PS5HydraTheme.space12),
        actionWidget,
      ],
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedScale(
        scale: active ? 1.015 : 1.0,
        duration: PS5HydraTheme.animFast,
        curve: Curves.easeOut,
        child: AnimatedContainer(
          duration: PS5HydraTheme.animFast,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: active ? PS5HydraTheme.glowFocus : null,
          ),
          foregroundDecoration: active
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: PS5HydraTheme.auroraSpringMint,
                    width: 1.8,
                  ),
                )
              : null,
          child: HydraTexturedCard(
            backgroundColor: PS5HydraTheme.obsidianGlass.withOpacity(0.92),
            borderRadius: 12,
            highlightedBorder: isReady || active,
            onTap: widget.onTap,
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 8,
            ),
            child: infoRow,
          ),
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

  String _compactSummary(EmulationGame game) {
    var text = game.summary
        .replaceAll('Catálogo integrado via RetroAPI & ROM-Gripper.', '')
        .trim();
    if (text.isEmpty) {
      return '${game.fullConsoleName} • ${game.genres.take(2).join(' / ')}';
    }
    return text;
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
    final coverUrl = GameAssetService.instance
            .getCachedAssets(
              game.name,
              platformSlug: game.platformSlug,
            )
            ?.coverImageUrl ??
        game.gridCoverUrl ??
        game.resolvedGridCoverUrl;
    final cleanCrc = game.crc32.trim().toUpperCase();
    final hasCrc = cleanCrc.isNotEmpty &&
        cleanCrc != '00000000' &&
        cleanCrc != 'N/A';

    final metaParts = <String>[
      game.platformName,
      game.romFormatLabel,
      if (game.hasKnownSize) game.formattedSize,
      game.region,
      if (game.releaseYear != null) '${game.releaseYear}',
      if (game.developer.trim().isNotEmpty) game.developer.trim(),
      if (hasCrc) 'CRC $cleanCrc',
    ];

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
      child: SafeArea(
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 540,
              maxHeight: MediaQuery.sizeOf(context).height * 0.88,
            ),
            child: Container(
              margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              decoration: BoxDecoration(
                color: HydraTokens.bgNearBlack,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: HydraTokens.borderSubtle10),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0xD8000000),
                    blurRadius: 24,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Cabeçalho direto: capa compacta + título + specs inline + fechar
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 72,
                          height: 100,
                          child: Container(
                            decoration: BoxDecoration(
                              color: HydraTokens.bgPureBlack,
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(
                                color: HydraTokens.borderSubtle10,
                              ),
                            ),
                            child: ProceduralCover(
                              title: game.name,
                              platformName: game.platformName,
                              gameId: game.igdbId,
                              imageUrl: coverUrl,
                              borderRadius: 8,
                              compact: true,
                              showBottomLabel: false,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      game.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontFamily: 'ReadexPro',
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        height: 1.18,
                                        color: HydraTokens.textPrimary,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Semantics(
                                    button: true,
                                    label: 'Fechar ficha do jogo',
                                    child: InkWell(
                                      borderRadius: BorderRadius.circular(8),
                                      onTap: () => Navigator.of(context).pop(),
                                      child: const Padding(
                                        padding: EdgeInsets.all(4),
                                        child: Icon(
                                          Icons.close_rounded,
                                          size: 18,
                                          color: HydraTokens.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              Text(
                                metaParts.join(' · '),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                  color: HydraTokens.primaryAurora,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _compactSummary(game),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 12,
                                  height: 1.35,
                                  color: HydraTokens.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    if (isDownloading || isPaused) ...[
                      const SizedBox(height: 10),
                      LoopProgressIndicator(
                        progress: _status.progress,
                        label: isDownloading
                            ? (_status.speedLabel ?? 'Baixando em 2º plano...')
                            : (_status.speedLabel ?? 'Pausado'),
                        minHeight: 5,
                      ),
                    ],

                    if (isExternal && !canPlay && !isDownloading) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Importe este jogo na Biblioteca ou configure um servidor RomM nos Ajustes.',
                        style: TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11.5,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ],

                    if (hasError) ...[
                      const SizedBox(height: 10),
                      Semantics(
                        liveRegion: true,
                        label:
                            'Erro no download: ${_sanitizeDownloadError(_status.errorMessage!)}',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: HydraTokens.accentDanger.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: HydraTokens.accentDanger.withOpacity(0.45),
                            ),
                          ),
                          child: Text(
                            _sanitizeDownloadError(_status.errorMessage!),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 11.5,
                              color: HydraTokens.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ],

                    if (hasWarning) ...[
                      const SizedBox(height: 8),
                      Text(
                        _status.warningMessage!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11.5,
                          color: HydraTokens.accentAmber,
                        ),
                      ),
                    ],

                    const SizedBox(height: 12),

                    // Barra única de ações diretas
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 44,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: HydraTokens.primaryAurora,
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
                                        ? 'Pausar (${LoopProgressIndicator.formatPercent(_status.progress)})'
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
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (isDownloading || isPaused) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () => widget.downloadService
                                  .cancelDownload(game.igdbId),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: HydraTokens.accentDanger,
                                side: BorderSide(
                                  color: HydraTokens.accentDanger
                                      .withOpacity(0.55),
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
                                'Cancelar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ] else if (hasError && !isExternal) ...[
                          const SizedBox(width: 8),
                          SizedBox(
                            height: 44,
                            child: OutlinedButton(
                              onPressed: () =>
                                  unawaited(_startBackgroundDownload()),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: HydraTokens.textPrimary,
                                side: const BorderSide(
                                  color: HydraTokens.borderSubtle10,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10),
                                ),
                              ),
                              child: const Text(
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
