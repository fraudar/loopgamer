import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import 'models/app_settings.dart';
import 'models/emulation_game.dart';
import 'models/user_library_meta.dart';
import 'screens/explore_screen.dart';
import 'screens/home_screen.dart';
import 'screens/library_screen.dart';
import 'screens/libretro_player_screen.dart';
import 'screens/settings_screen.dart';
import 'services/cover_cache_service.dart';
import 'services/emulator_service.dart';
import 'services/igdb_steamgriddb_service.dart';
import 'services/library_storage_service.dart';
import 'services/rom_download_service.dart';
import 'services/settings_storage_service.dart';
import 'theme/hydra_tokens.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const LoopGamerApp());
}

class LoopGamerApp extends StatefulWidget {
  const LoopGamerApp({super.key});

  @override
  State<LoopGamerApp> createState() => _LoopGamerAppState();
}

class _LoopGamerAppState extends State<LoopGamerApp> {
  final IgdbSteamGridService _apiService = IgdbSteamGridService();
  final RomDownloadService _downloadService = RomDownloadService();
  final LibraryStorageService _libraryStorage = LibraryStorageService();
  final SettingsStorageService _settingsStorage = SettingsStorageService();
  final EmulatorService _emulatorService = EmulatorService();
  final CoverCacheService _coverCacheService = CoverCacheService.instance;

  final ValueNotifier<Map<int, RomDownloadStatus>> _downloadStatusesNotifier =
      ValueNotifier<Map<int, RomDownloadStatus>>(const {});
  final ValueNotifier<int> _libraryBadgeCountNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _hasActiveDownloadNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _hardwareGamepadNotifier =
      ValueNotifier<bool>(false);

  StreamSubscription<RomDownloadEvent>? _downloadEventsSub;
  StreamSubscription<void>? _gamepadSub;

  int _selectedTab = 0;
  AppSettings _settings = const AppSettings();
  UserLibraryMeta _userMeta = const UserLibraryMeta();
  bool _isLoadingCatalog = true;
  String? _catalogError;

  final Map<int, EmulationGame> _catalogById = {
    for (final g in kVerifiedRealGamesCatalog) g.igdbId: g,
  };
  List<EmulationGame> _catalogListCache = List<EmulationGame>.unmodifiable(
    kVerifiedRealGamesCatalog,
  );

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_coverCacheService.precacheCatalog(kVerifiedRealGamesCatalog));
    _downloadEventsSub = _downloadService.downloadEvents.listen((event) {
      unawaited(_handleStatusUpdated(event.game, event.status));
    });
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      _gamepadSub = _emulatorService.hardwareGamepadStream.listen(
        (_) {
          if (mounted && !_hardwareGamepadNotifier.value) {
            _hardwareGamepadNotifier.value = true;
          }
        },
        onError: (_) {},
      );
    }
    unawaited(_restoreState());
  }

  @override
  void dispose() {
    final dlSub = _downloadEventsSub;
    if (dlSub != null) {
      unawaited(dlSub.cancel());
    }
    final gpSub = _gamepadSub;
    if (gpSub != null) {
      unawaited(gpSub.cancel());
    }
    _emulatorService.dispose();
    _downloadService.dispose();
    _apiService.dispose();
    _coverCacheService.dispose();
    _downloadStatusesNotifier.dispose();
    _libraryBadgeCountNotifier.dispose();
    _hasActiveDownloadNotifier.dispose();
    _hardwareGamepadNotifier.dispose();
    super.dispose();
  }

  void _refreshCatalogListCache() {
    _catalogListCache = List<EmulationGame>.unmodifiable(_catalogById.values);
  }

  void _syncSummaryNotifiers(Map<int, RomDownloadStatus> statuses) {
    int count = 0;
    bool hasDownloading = false;
    for (final st in statuses.values) {
      if (st.state == RomActionState.readyToPlay && st.localPath != null) {
        count++;
      } else if (st.state == RomActionState.downloading) {
        count++;
        hasDownloading = true;
      }
    }
    if (_libraryBadgeCountNotifier.value != count) {
      _libraryBadgeCountNotifier.value = count;
    }
    if (_hasActiveDownloadNotifier.value != hasDownloading) {
      _hasActiveDownloadNotifier.value = hasDownloading;
    }
  }

  Future<void> _restoreState() async {
    AppSettings loadedSettings = _settings;
    UserLibraryMeta loadedMeta = _userMeta;
    final nextStatuses =
        Map<int, RomDownloadStatus>.from(_downloadStatusesNotifier.value);

    try {
      loadedSettings = await _settingsStorage.loadSettings();
      loadedMeta = await _settingsStorage.loadUserMeta();
      final savedGames = await _libraryStorage.loadPersistedLibrary();

      for (final g in savedGames) {
        _catalogById[g.igdbId] = g;
        if (g.localRomPath != null) {
          nextStatuses[g.igdbId] = RomDownloadStatus(
            state: RomActionState.readyToPlay,
            progress: 1.0,
            localPath: g.localRomPath,
          );
        }
      }

      final catalogSnapshot = _catalogById.values.toList();
      final resolvedPaths = await Future.wait(
        catalogSnapshot.map(
          (game) => _downloadService.resolveExistingRomPath(game.igdbId),
        ),
      );
      for (int i = 0; i < catalogSnapshot.length; i++) {
        final localPath = resolvedPaths[i];
        if (localPath != null) {
          nextStatuses[catalogSnapshot[i].igdbId] = RomDownloadStatus(
            state: RomActionState.readyToPlay,
            progress: 1.0,
            localPath: localPath,
          );
        }
      }

      if (!mounted) return;
      _refreshCatalogListCache();
      _downloadStatusesNotifier.value = Map.unmodifiable(nextStatuses);
      _syncSummaryNotifiers(_downloadStatusesNotifier.value);
      setState(() {
        _settings = loadedSettings;
        _userMeta = loadedMeta;
      });
    } catch (e) {
      debugPrint('[LoopGamerApp] Erro ao restaurar estado local: $e');
    }

    await _loadRealCatalog(
      rommServerUrl: loadedSettings.rommServerUrl,
      rommApiToken: loadedSettings.rommApiToken,
    );
  }

  Future<void> _loadRealCatalog({
    String? rommServerUrl,
    String? rommApiToken,
  }) async {
    if (!mounted) return;
    setState(() {
      _isLoadingCatalog = true;
      _catalogError = null;
    });

    try {
      final expandedCatalog = await _apiService.fetchRealCatalog(
        rommServerUrl: rommServerUrl ?? _settings.rommServerUrl,
        rommApiToken: rommApiToken ?? _settings.rommApiToken,
      );
      if (!mounted) return;

      for (final g in expandedCatalog) {
        _catalogById.putIfAbsent(g.igdbId, () => g);
      }
      _refreshCatalogListCache();
      setState(() {
        _isLoadingCatalog = false;
        _catalogError = _catalogById.isEmpty
            ? 'Nenhum jogo disponível no catálogo. Verifique sua conexão e tente novamente.'
            : null;
      });
    } catch (e) {
      debugPrint('[LoopGamerApp] Erro ao carregar catálogo: $e');
      if (!mounted) return;
      setState(() {
        _isLoadingCatalog = false;
        _catalogError =
            'Não foi possível atualizar o catálogo online. Verifique sua conexão e tente novamente.';
      });
    }
  }

  Future<void> _handleSettingsUpdated(AppSettings next) async {
    final rommChanged = next.rommServerUrl != _settings.rommServerUrl ||
        next.rommApiToken != _settings.rommApiToken;
    setState(() => _settings = next);
    await _settingsStorage.saveSettings(next);
    if (rommChanged && next.rommServerUrl.trim().isNotEmpty) {
      try {
        final remote = await _apiService.fetchFromRommServer(
          serverUrl: next.rommServerUrl,
          apiToken: next.rommApiToken,
        );
        if (mounted && remote.isNotEmpty) {
          for (final g in remote) {
            _catalogById[g.igdbId] = g;
          }
          _refreshCatalogListCache();
          setState(() {});
        }
      } catch (e) {
        debugPrint('[LoopGamerApp] Erro ao sincronizar RomM: $e');
      }
    }
  }

  Future<void> _handleUserMetaUpdated(UserLibraryMeta next) async {
    setState(() => _userMeta = next);
    await _settingsStorage.saveUserMeta(next);
  }

  bool _isSameStatus(RomDownloadStatus? a, RomDownloadStatus b) {
    if (a == null) return false;
    return a.state == b.state &&
        a.progress == b.progress &&
        a.localPath == b.localPath &&
        a.errorMessage == b.errorMessage &&
        a.speedLabel == b.speedLabel &&
        a.warningMessage == b.warningMessage &&
        a.crcVerified == b.crcVerified;
  }

  Future<void> _handleStatusUpdated(
    EmulationGame game,
    RomDownloadStatus status,
  ) async {
    if (!mounted) return;
    final current = _downloadStatusesNotifier.value;
    final prev = current[game.igdbId];
    final hadEntry = _catalogById.containsKey(game.igdbId);

    _catalogById[game.igdbId] = game;
    if (!hadEntry) {
      _refreshCatalogListCache();
    }

    if (!_isSameStatus(prev, status)) {
      final updated = Map<int, RomDownloadStatus>.from(current);
      updated[game.igdbId] = status;
      final frozen = Map<int, RomDownloadStatus>.unmodifiable(updated);
      _downloadStatusesNotifier.value = frozen;
      _syncSummaryNotifiers(frozen);
    }

    if (status.state == RomActionState.readyToPlay &&
        status.localPath != null &&
        (prev?.state != RomActionState.readyToPlay ||
            prev?.localPath != status.localPath)) {
      await _libraryStorage.saveGameToLibrary(game, status.localPath!);
    }
  }

  void _handleBatchStatusUpdated(
    Map<EmulationGame, RomDownloadStatus> updates,
  ) {
    if (!mounted || updates.isEmpty) return;
    final next =
        Map<int, RomDownloadStatus>.from(_downloadStatusesNotifier.value);
    bool catalogChanged = false;
    bool statusChanged = false;

    for (final entry in updates.entries) {
      final game = entry.key;
      final status = entry.value;
      if (!_catalogById.containsKey(game.igdbId)) {
        catalogChanged = true;
      }
      _catalogById[game.igdbId] = game;
      if (!_isSameStatus(next[game.igdbId], status)) {
        next[game.igdbId] = status;
        statusChanged = true;
      }
    }

    if (catalogChanged) {
      _refreshCatalogListCache();
    }
    if (statusChanged) {
      final frozen = Map<int, RomDownloadStatus>.unmodifiable(next);
      _downloadStatusesNotifier.value = frozen;
      _syncSummaryNotifiers(frozen);
    }
  }

  Future<void> _handleRemoveGameFromLibrary(EmulationGame game) async {
    final currentStatus = _downloadStatusesNotifier.value[game.igdbId];
    final localPath = currentStatus?.localPath ?? game.localRomPath;

    await _downloadService.deleteRomFilesForGame(
      game.igdbId,
      localPath: localPath,
    );
    await _libraryStorage.removeGameFromLibrary(game.igdbId);

    if (!mounted) return;
    _catalogById[game.igdbId] = game.copyWith(localRomPath: null);
    _refreshCatalogListCache();

    final next =
        Map<int, RomDownloadStatus>.from(_downloadStatusesNotifier.value);
    next[game.igdbId] = const RomDownloadStatus(
      state: RomActionState.notDownloaded,
      progress: 0.0,
    );
    final frozen = Map<int, RomDownloadStatus>.unmodifiable(next);
    _downloadStatusesNotifier.value = frozen;
    _syncSummaryNotifiers(frozen);
  }

  void _handleCancelDownload(EmulationGame game) {
    _downloadService.cancelDownload(game.igdbId);
    if (!mounted) return;
    final next =
        Map<int, RomDownloadStatus>.from(_downloadStatusesNotifier.value);
    next[game.igdbId] = const RomDownloadStatus(
      state: RomActionState.notDownloaded,
      progress: 0.0,
    );
    final frozen = Map<int, RomDownloadStatus>.unmodifiable(next);
    _downloadStatusesNotifier.value = frozen;
    _syncSummaryNotifiers(frozen);
  }

  Future<void> _launchLibretroPlayer(
    BuildContext navContext,
    EmulationGame game,
    String localRomPath,
  ) async {
    final navigator = Navigator.of(navContext);
    navigator.popUntil((route) => route.isFirst);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LibretroPlayerScreen(
          game: game,
          romPath: localRomPath,
          emulatorService: _emulatorService,
          initialSettings: _settings,
          onSettingsChanged: _handleSettingsUpdated,
        ),
      ),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    final reloadedMeta = await _settingsStorage.loadUserMeta();
    if (mounted) {
      setState(() => _userMeta = reloadedMeta);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoopGamer',
      debugShowCheckedModeBanner: false,
      theme: HydraTokens.buildAppTheme(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('pt', 'BR'),
        Locale('en'),
      ],
      home: Builder(
        builder: (navContext) {
          final isLandscape = HydraTokens.isWideLayout(navContext);

          return Scaffold(
            backgroundColor: HydraTokens.bgPureBlack,
            body: Column(
              children: [
                if (isLandscape)
                  _GameHubLandscapeTopBar(
                    currentIndex: _selectedTab,
                    libraryBadgeCountListenable: _libraryBadgeCountNotifier,
                    hasActiveDownloadListenable: _hasActiveDownloadNotifier,
                    hardwareGamepadListenable: _hardwareGamepadNotifier,
                    onSelectTab: (index) =>
                        setState(() => _selectedTab = index),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedTab,
                    children: [
                      HomeScreen(
                        featuredGames: kVerifiedRealGamesCatalog,
                        popularGames: _catalogListCache,
                        downloadStatusesListenable: _downloadStatusesNotifier,
                        downloadService: _downloadService,
                        onStatusUpdated: _handleStatusUpdated,
                        onLaunchGame: (game, path) => unawaited(
                          _launchLibretroPlayer(navContext, game, path),
                        ),
                        userMeta: _userMeta,
                        onUserMetaChanged: _handleUserMetaUpdated,
                        onOpenSearchTab: () =>
                            setState(() => _selectedTab = 1),
                        onOpenLibraryTab: () =>
                            setState(() => _selectedTab = 2),
                        isActive: _selectedTab == 0,
                        isLoadingCatalog: _isLoadingCatalog,
                        catalogError: _catalogError,
                        onRetryCatalog: () => unawaited(_loadRealCatalog()),
                      ),
                      ExploreScreen(
                        apiService: _apiService,
                        downloadService: _downloadService,
                        downloadStatusesListenable: _downloadStatusesNotifier,
                        settings: _settings,
                        onStatusUpdated: _handleStatusUpdated,
                        onBatchStatusUpdated: _handleBatchStatusUpdated,
                        onLaunchGameInLibretro: (game, path) => unawaited(
                          _launchLibretroPlayer(navContext, game, path),
                        ),
                        isLoadingCatalog: _isLoadingCatalog,
                        catalogError: _catalogError,
                        onRetryCatalog: () => unawaited(_loadRealCatalog()),
                      ),
                      ValueListenableBuilder<Map<int, RomDownloadStatus>>(
                        valueListenable: _downloadStatusesNotifier,
                        builder: (context, statuses, _) {
                          final allCatalog = _catalogById.values;
                          final downloadedGames = allCatalog.where((g) {
                            final st = statuses[g.igdbId];
                            return st != null &&
                                st.state == RomActionState.readyToPlay &&
                                st.localPath != null;
                          }).toList();

                          final downloadingGames = allCatalog.where((g) {
                            final st = statuses[g.igdbId];
                            return st != null &&
                                st.state == RomActionState.downloading;
                          }).toList();

                          return LibraryScreen(
                            downloadedGames: downloadedGames,
                            downloadingGames: downloadingGames,
                            downloadStatuses: statuses,
                            onImportNewRomPressed: () =>
                                setState(() => _selectedTab = 1),
                            onLaunchGame: (game, path) => unawaited(
                              _launchLibretroPlayer(navContext, game, path),
                            ),
                            onRemoveGame: _handleRemoveGameFromLibrary,
                            onCancelDownload: _handleCancelDownload,
                            userMeta: _userMeta,
                            onUserMetaChanged: _handleUserMetaUpdated,
                            isActive: _selectedTab == 2,
                          );
                        },
                      ),
                      ValueListenableBuilder<int>(
                        valueListenable: _libraryBadgeCountNotifier,
                        builder: (context, libraryCount, _) => SettingsScreen(
                          settings: _settings,
                          downloadService: _downloadService,
                          onSettingsChanged: _handleSettingsUpdated,
                          emulatorService: _emulatorService,
                          isActive: _selectedTab == 3,
                          libraryCount: libraryCount,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            bottomNavigationBar: isLandscape
                ? null
                : _GameHubPortraitDockBar(
                    currentIndex: _selectedTab,
                    installedCountListenable: _libraryBadgeCountNotifier,
                    isDownloadingListenable: _hasActiveDownloadNotifier,
                    onSelect: (index) => setState(() => _selectedTab = index),
                  ),
          );
        },
      ),
    );
  }
}

/// Relógio isolado da Top Bar com atualização periódica leve (sem rebuild da árvore pai).
class _LiveTopBarClock extends StatefulWidget {
  const _LiveTopBarClock();

  @override
  State<_LiveTopBarClock> createState() => _LiveTopBarClockState();
}

class _LiveTopBarClockState extends State<_LiveTopBarClock> {
  Timer? _timer;
  late DateTime _now;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      if (!mounted) return;
      final current = DateTime.now();
      if (current.minute != _now.minute || current.hour != _now.hour) {
        setState(() => _now = current);
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final timeStr =
        '${_now.hour.toString().padLeft(2, '0')}:${_now.minute.toString().padLeft(2, '0')}';
    return Semantics(
      label: 'Relógio $timeStr',
      child: Text(
        timeStr,
        style: const TextStyle(
          fontFamily: 'ReadexPro',
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
          color: HydraTokens.textPrimary,
        ),
      ),
    );
  }
}

/// Top Bar Estilo GameHub para Modo Deitado (Landscape)
class _GameHubLandscapeTopBar extends StatelessWidget {
  const _GameHubLandscapeTopBar({
    required this.currentIndex,
    required this.libraryBadgeCountListenable,
    required this.hasActiveDownloadListenable,
    required this.hardwareGamepadListenable,
    required this.onSelectTab,
  });

  final int currentIndex;
  final ValueListenable<int> libraryBadgeCountListenable;
  final ValueListenable<bool> hasActiveDownloadListenable;
  final ValueListenable<bool> hardwareGamepadListenable;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: HydraTokens.bgPureBlack.withOpacity(0.95),
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
      child: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<int>(
          valueListenable: libraryBadgeCountListenable,
          builder: (context, libraryBadgeCount, _) =>
              ValueListenableBuilder<bool>(
            valueListenable: hasActiveDownloadListenable,
            builder: (context, hasActiveDownload, _) {
              final navItems = [
                (
                  label: 'Início',
                  icon: PhosphorIcons.planet(
                    currentIndex == 0
                        ? PhosphorIconsStyle.fill
                        : PhosphorIconsStyle.regular,
                  ),
                  badge: null,
                ),
                (
                  label: 'ROMs',
                  icon: PhosphorIcons.gameController(
                    currentIndex == 1
                        ? PhosphorIconsStyle.fill
                        : PhosphorIconsStyle.regular,
                  ),
                  badge: null,
                ),
                (
                  label: 'Biblioteca',
                  icon: PhosphorIcons.squaresFour(
                    currentIndex == 2
                        ? PhosphorIconsStyle.fill
                        : PhosphorIconsStyle.regular,
                  ),
                  badge: libraryBadgeCount > 0 ? '$libraryBadgeCount' : null,
                ),
                (
                  label: 'Ajustes',
                  icon: PhosphorIcons.slidersHorizontal(
                    currentIndex == 3
                        ? PhosphorIconsStyle.fill
                        : PhosphorIconsStyle.regular,
                  ),
                  badge: null,
                ),
              ];

              return Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int i = 0; i < navItems.length; i++) ...[
                            Semantics(
                              button: true,
                              selected: i == currentIndex,
                              label: navItems[i].label,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(18),
                                  onTap: () => onSelectTab(i),
                                  child: Center(
                                    widthFactor: 1.0,
                                    child: AnimatedContainer(
                                      duration:
                                          const Duration(milliseconds: 180),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 6,
                                      ),
                                      decoration: BoxDecoration(
                                        color: i == currentIndex
                                            ? Colors.white.withOpacity(0.12)
                                            : Colors.transparent,
                                        borderRadius: BorderRadius.circular(18),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          PhosphorIcon(
                                            navItems[i].icon,
                                            size: 17,
                                            color: i == currentIndex
                                                ? HydraTokens.textPrimary
                                                : HydraTokens.textSecondary,
                                          ),
                                          const SizedBox(width: 5),
                                          Text(
                                            navItems[i].label,
                                            style: TextStyle(
                                              fontFamily: 'ReadexPro',
                                              fontSize: 12,
                                              fontWeight: i == currentIndex
                                                  ? FontWeight.w700
                                                  : FontWeight.w600,
                                              color: i == currentIndex
                                                  ? HydraTokens.textPrimary
                                                  : HydraTokens.textSecondary,
                                            ),
                                          ),
                                          if (navItems[i].badge != null) ...[
                                            const SizedBox(width: 5),
                                            Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 5,
                                                vertical: 1,
                                              ),
                                              decoration: BoxDecoration(
                                                color: hasActiveDownload
                                                    ? HydraTokens.accentAmber
                                                    : HydraTokens.textPrimary,
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                              child: Text(
                                                navItems[i].badge!,
                                                style: const TextStyle(
                                                  fontFamily: 'JetBrainsMono',
                                                  fontSize: 9,
                                                  fontWeight: FontWeight.w700,
                                                  color:
                                                      HydraTokens.bgPureBlack,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Semantics(
                    button: true,
                    label: 'Buscar ROMs',
                    child: IconButton(
                      tooltip: 'Buscar ROMs',
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => onSelectTab(1),
                      icon: PhosphorIcon(
                        PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.bold),
                        size: 17,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: hasActiveDownload
                        ? 'Biblioteca com downloads ativos'
                        : 'Abrir Biblioteca',
                    child: IconButton(
                      tooltip: hasActiveDownload
                          ? 'Downloads em andamento'
                          : 'Abrir Biblioteca',
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => onSelectTab(2),
                      icon: PhosphorIcon(
                        PhosphorIcons.floppyDisk(PhosphorIconsStyle.regular),
                        size: 17,
                        color: hasActiveDownload
                            ? HydraTokens.accentAmber
                            : HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                  ValueListenableBuilder<bool>(
                    valueListenable: hardwareGamepadListenable,
                    builder: (context, gamepadActive, _) {
                      if (!gamepadActive) return const SizedBox.shrink();
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Tooltip(
                          message: 'Controle físico ativo',
                          child: Semantics(
                            label: 'Controle físico ativo',
                            child: PhosphorIcon(
                              PhosphorIcons.gameController(
                                PhosphorIconsStyle.fill,
                              ),
                              size: 17,
                              color: HydraTokens.accentTeal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  Container(
                    width: 1,
                    height: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    color: Colors.white.withOpacity(0.22),
                  ),
                  const _LiveTopBarClock(),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Bottom Navigation Bar Estilo GameHub para Modo em Pé (Portrait)
class _GameHubPortraitDockBar extends StatelessWidget {
  const _GameHubPortraitDockBar({
    required this.currentIndex,
    required this.installedCountListenable,
    required this.isDownloadingListenable,
    required this.onSelect,
  });

  final int currentIndex;
  final ValueListenable<int> installedCountListenable;
  final ValueListenable<bool> isDownloadingListenable;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: HydraTokens.bgPureBlack,
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: SafeArea(
        top: false,
        child: ValueListenableBuilder<int>(
          valueListenable: installedCountListenable,
          builder: (context, installedCount, _) =>
              ValueListenableBuilder<bool>(
            valueListenable: isDownloadingListenable,
            builder: (context, isDownloading, _) {
              final items = [
                (
                  label: 'Início',
                  outline: PhosphorIcons.planet(PhosphorIconsStyle.regular),
                  fill: PhosphorIcons.planet(PhosphorIconsStyle.fill),
                  badge: null,
                ),
                (
                  label: 'ROMs',
                  outline:
                      PhosphorIcons.gameController(PhosphorIconsStyle.regular),
                  fill: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
                  badge: null,
                ),
                (
                  label: 'Biblioteca',
                  outline:
                      PhosphorIcons.squaresFour(PhosphorIconsStyle.regular),
                  fill: PhosphorIcons.squaresFour(PhosphorIconsStyle.fill),
                  badge: installedCount > 0 ? '$installedCount' : null,
                ),
                (
                  label: 'Ajustes',
                  outline: PhosphorIcons.slidersHorizontal(
                    PhosphorIconsStyle.regular,
                  ),
                  fill:
                      PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.fill),
                  badge: null,
                ),
              ];

              return Container(
                height: 64,
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: BoxDecoration(
                  color: HydraTokens.surfaceTopBar,
                  borderRadius: BorderRadius.circular(28),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0xAA000000),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: Row(
                  children: List.generate(items.length, (i) {
                    final active = i == currentIndex;
                    final item = items[i];
                    return Expanded(
                      child: Semantics(
                        button: true,
                        selected: active,
                        label: item.badge != null
                            ? '${item.label}, ${item.badge} itens'
                            : item.label,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(22),
                          onTap: () => onSelect(i),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            curve: Curves.easeOutCubic,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: active
                                  ? HydraTokens.surfaceElevated2
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(22),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    PhosphorIcon(
                                      active ? item.fill : item.outline,
                                      size: 21,
                                      color: active
                                          ? HydraTokens.textPrimary
                                          : HydraTokens.textSecondary,
                                    ),
                                    if (item.badge != null)
                                      Positioned(
                                        right: -9,
                                        top: -5,
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4.5,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: isDownloading
                                                ? HydraTokens.accentAmber
                                                : HydraTokens.textPrimary,
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          child: Text(
                                            item.badge!,
                                            style: const TextStyle(
                                              fontFamily: 'JetBrainsMono',
                                              fontSize: 8.5,
                                              fontWeight: FontWeight.w700,
                                              color: HydraTokens.bgPureBlack,
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  item.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 10.5,
                                    fontWeight: active
                                        ? FontWeight.w700
                                        : FontWeight.w600,
                                    color: active
                                        ? HydraTokens.textPrimary
                                        : HydraTokens.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
