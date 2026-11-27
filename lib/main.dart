import 'dart:async';
import 'dart:io';
import 'dart:ui';
import 'package:file_picker/file_picker.dart';
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
import 'services/diagnostic_log_service.dart';
import 'services/emulator_service.dart';
import 'services/game_asset_service.dart';
import 'services/igdb_steamgriddb_service.dart';
import 'services/library_storage_service.dart';
import 'services/rom_download_service.dart';
import 'services/rom_platform_detector.dart';
import 'services/settings_storage_service.dart';
import 'theme/hydra_tokens.dart';
import 'theme/ps5_hydra_theme.dart';
import 'widgets/loop_common_widgets.dart';

const SystemUiOverlayStyle _kLoopEdgeOverlayStyle = SystemUiOverlayStyle(
  statusBarColor: Colors.transparent,
  statusBarIconBrightness: Brightness.light,
  statusBarBrightness: Brightness.dark,
  systemNavigationBarColor: Colors.transparent,
  systemNavigationBarIconBrightness: Brightness.light,
  systemNavigationBarDividerColor: Colors.transparent,
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  DiagnosticLogService.instance.installGlobalHooks();
  SystemChrome.setSystemUIOverlayStyle(_kLoopEdgeOverlayStyle);
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const LoopGamerApp());
}

class LoopGamerApp extends StatefulWidget {
  const LoopGamerApp({super.key, this.emulatorService});

  final EmulatorService? emulatorService;

  @override
  State<LoopGamerApp> createState() => _LoopGamerAppState();
}

class _LoopGamerAppState extends State<LoopGamerApp>
    with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final IgdbSteamGridService _apiService = IgdbSteamGridService();
  final RomDownloadService _downloadService = RomDownloadService();
  final LibraryStorageService _libraryStorage = LibraryStorageService();
  final SettingsStorageService _settingsStorage = SettingsStorageService();
  late final EmulatorService _emulatorService =
      widget.emulatorService ?? EmulatorService();
  final CoverCacheService _coverCacheService = CoverCacheService.instance;

  final ValueNotifier<Map<int, RomDownloadStatus>> _downloadStatusesNotifier =
      ValueNotifier<Map<int, RomDownloadStatus>>(const {});
  final ValueNotifier<int> _libraryBadgeCountNotifier = ValueNotifier<int>(0);
  final ValueNotifier<bool> _hasActiveDownloadNotifier =
      ValueNotifier<bool>(false);
  final ValueNotifier<bool> _hardwareGamepadNotifier =
      ValueNotifier<bool>(false);

  StreamSubscription<RomDownloadEvent>? _downloadEventsSub;
  StreamSubscription<bool>? _gamepadStateSub;
  StreamSubscription<Map<String, dynamic>>? _gamepadUiSub;
  StreamSubscription<bool>? _networkStateSub;

  int _selectedTab = 0;
  bool _isPlayerActive = false;
  bool _isImportingExternalIso = false;
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
    WidgetsBinding.instance.addObserver(this);
    SystemChrome.setSystemUIOverlayStyle(_kLoopEdgeOverlayStyle);
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(_coverCacheService.precacheCatalog(kVerifiedRealGamesCatalog));
    _downloadEventsSub = _downloadService.downloadEvents.listen((event) {
      unawaited(_handleStatusUpdated(event.game, event.status));
    });
    if (widget.emulatorService != null ||
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      _hardwareGamepadNotifier.value =
          _emulatorService.isHardwareGamepadConnected;
      _gamepadStateSub = _emulatorService.hardwareGamepadStateStream.listen(
        (connected) {
          if (mounted && _hardwareGamepadNotifier.value != connected) {
            _hardwareGamepadNotifier.value = connected;
          }
        },
        onError: (_) {},
      );
      _gamepadUiSub = _emulatorService.gamepadUiActionStream.listen(
        _handleGlobalGamepadUiAction,
        onError: (_) {},
      );
      _networkStateSub = _emulatorService.networkStateStream.listen(
        (connected) {
          if (connected && mounted) {
            unawaited(_downloadService.onAppOrNetworkResumed());
          }
        },
        onError: (_) {},
      );
    }
    unawaited(_restoreState());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_downloadService.onAppOrNetworkResumed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final dlSub = _downloadEventsSub;
    if (dlSub != null) {
      unawaited(dlSub.cancel());
    }
    final gpStateSub = _gamepadStateSub;
    if (gpStateSub != null) {
      unawaited(gpStateSub.cancel());
    }
    final gpUiSub = _gamepadUiSub;
    if (gpUiSub != null) {
      unawaited(gpUiSub.cancel());
    }
    final netSub = _networkStateSub;
    if (netSub != null) {
      unawaited(netSub.cancel());
    }
    if (widget.emulatorService == null) {
      _emulatorService.dispose();
    }
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
      await _coverCacheService.ensureCacheDirectory();
      loadedSettings = await _settingsStorage.loadSettings();
      loadedMeta = await _settingsStorage.loadUserMeta();
      final savedGames = await _libraryStorage.loadPersistedLibrary();

      for (final g in savedGames) {
        _catalogById[g.igdbId] = g;
        debugPrint(
          '[Library] #${g.igdbId} "${g.name}" slug=${g.platformSlug} '
          'path=${g.localRomPath}',
        );
      }

      final catalogSnapshot = _catalogById.values.toList();
      final resolvedPaths = await Future.wait(
        catalogSnapshot.map(
          (game) => _downloadService.resolveExistingRomPath(
            game.igdbId,
            knownLocalPath: game.localRomPath,
          ),
        ),
      );
      final resolvedSizes = await Future.wait(
        List<Future<int>>.generate(catalogSnapshot.length, (i) async {
          final localPath = resolvedPaths[i];
          if (localPath == null) return 0;
          return LibraryStorageService.resolveInstalledRomSizeBytes(
            localPath,
            fallbackBytes: catalogSnapshot[i].estimatedSizeBytes,
          );
        }),
      );
      for (int i = 0; i < catalogSnapshot.length; i++) {
        final localPath = resolvedPaths[i];
        final baseGame = catalogSnapshot[i];
        if (localPath != null) {
          final sizeBytes = resolvedSizes[i];
          if (sizeBytes > 0 && sizeBytes != baseGame.estimatedSizeBytes ||
              baseGame.localRomPath != localPath) {
            _catalogById[baseGame.igdbId] = baseGame.copyWith(
              estimatedSizeBytes:
                  sizeBytes > 0 ? sizeBytes : baseGame.estimatedSizeBytes,
              localRomPath: localPath,
            );
          }
          nextStatuses[baseGame.igdbId] = RomDownloadStatus(
            state: RomActionState.readyToPlay,
            progress: 1.0,
            localPath: localPath,
          );
        } else if (baseGame.localRomPath != null) {
          _catalogById[baseGame.igdbId] = baseGame.copyWith(localRomPath: null);
          nextStatuses.remove(baseGame.igdbId);
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
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(_persistMediaAndPrewarmInstalledGames(nextStatuses));
        unawaited(_downloadService.onAppOrNetworkResumed());
      }
    } catch (e) {
      debugPrint('[LoopGamerApp] Erro ao restaurar estado local: $e');
    }

    await _loadRealCatalog(
      rommServerUrl: loadedSettings.rommServerUrl,
      rommApiToken: loadedSettings.rommApiToken,
    );
    if (!Platform.environment.containsKey('FLUTTER_TEST') && mounted) {
      unawaited(_recoverPendingLocalArchives());
    }
  }

  Future<void> _recoverPendingLocalArchives() async {
    if (!mounted) return;
    try {
      final result = await _downloadService.recoverOrCleanUnextractedArchives(
        catalogById: _catalogById,
      );
      if (!mounted) return;
      var changed = false;
      final nextStatuses =
          Map<int, RomDownloadStatus>.from(_downloadStatusesNotifier.value);

      for (final badId in result.cleanedInvalidIds) {
        final existing = _catalogById[badId];
        if (existing != null && existing.localRomPath != null) {
          _catalogById[badId] = existing.copyWith(localRomPath: null);
          nextStatuses.remove(badId);
          await _libraryStorage.removeGameFromLibrary(badId);
          changed = true;
        }
      }

      for (final item in result.recovered) {
        var game = item.game;
        if (game == null) continue;
        game = game.copyWith(
          localRomPath: item.localPath,
          estimatedSizeBytes:
              item.sizeBytes > 0 ? item.sizeBytes : game.estimatedSizeBytes,
        );
        _catalogById[game.igdbId] = game;
        await _libraryStorage.saveGameToLibrary(
          game,
          item.localPath,
        );
        nextStatuses[game.igdbId] = RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: item.localPath,
          downloadedBytes: item.sizeBytes,
          totalBytes: item.sizeBytes,
        );
        unawaited(_persistMediaForInstalledGame(game));
        changed = true;
      }

      if (changed && mounted) {
        _refreshCatalogListCache();
        _downloadStatusesNotifier.value = Map.unmodifiable(nextStatuses);
        _syncSummaryNotifiers(_downloadStatusesNotifier.value);
        setState(() {});
      }
    } catch (e) {
      debugPrint('[LoopGamerApp] Erro ao recuperar pacotes locais: $e');
    }
  }

  Future<void> _persistMediaForInstalledGame(EmulationGame game) async {
    if (Platform.environment.containsKey('FLUTTER_TEST') || !mounted) return;
    try {
      var updated = game;
      var coverUrl = game.gridCoverUrl;
      var bannerUrl = game.heroBannerUrl;
      var logoUrl = game.logoUrl;
      if (coverUrl == null ||
          coverUrl.isEmpty ||
          bannerUrl == null ||
          bannerUrl.isEmpty) {
        final assets = await GameAssetService.instance.fetchAssetsForGame(game);
        if (assets.coverImageUrl != null && assets.coverImageUrl!.isNotEmpty) {
          coverUrl = assets.coverImageUrl;
        }
        if (assets.backgroundImageUrl != null &&
            assets.backgroundImageUrl!.isNotEmpty) {
          bannerUrl = assets.backgroundImageUrl;
        }
        if (assets.logoImageUrl != null && assets.logoImageUrl!.isNotEmpty) {
          logoUrl = assets.logoImageUrl;
        }
      }
      updated = game.copyWith(
        gridCoverUrl: coverUrl ?? game.resolvedGridCoverUrl,
        heroBannerUrl: bannerUrl ?? game.resolvedHeroBannerUrl,
        logoUrl: logoUrl,
      );
      _catalogById[game.igdbId] = updated;
      await _libraryStorage.updateInstalledGameMetadata(updated);
      await _coverCacheService.persistMediaForGame(
        updated,
        coverUrl: updated.resolvedGridCoverUrl,
        bannerUrl: updated.resolvedHeroBannerUrl,
      );
    } catch (e) {
      debugPrint('[LoopGamerApp] Erro ao salvar capa/banner offline: $e');
    }
  }

  Future<void> _persistMediaAndPrewarmInstalledGames(
    Map<int, RomDownloadStatus> statuses,
  ) async {
    for (final entry in statuses.entries) {
      if (entry.value.state != RomActionState.readyToPlay ||
          entry.value.localPath == null) {
        continue;
      }
      final game = _catalogById[entry.key];
      if (game == null) continue;
      unawaited(_persistMediaForInstalledGame(game));
      unawaited(
        _emulatorService.prewarmPlatformAssets(
          platformSlug: game.platformSlug,
          coreSoName: game.libretroCoreSoName,
        ),
      );
    }
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
        a.crcVerified == b.crcVerified &&
        a.isQueued == b.isQueued &&
        a.queuePosition == b.queuePosition;
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
            prev?.localPath != status.localPath ||
            game.estimatedSizeBytes < 1024)) {
      final resolvedBytes =
          await LibraryStorageService.resolveInstalledRomSizeBytes(
        status.localPath!,
        fallbackBytes: game.estimatedSizeBytes,
      );
      final normalizedGame = game.copyWith(
        estimatedSizeBytes:
            resolvedBytes > 0 ? resolvedBytes : game.estimatedSizeBytes,
        localRomPath: status.localPath,
      );
      await _libraryStorage.saveGameToLibrary(normalizedGame, status.localPath!);
      if (!mounted) return;
      _catalogById[game.igdbId] = normalizedGame;
      _refreshCatalogListCache();
      setState(() {});
      unawaited(_persistMediaForInstalledGame(normalizedGame));
      unawaited(
        _emulatorService.prewarmPlatformAssets(
          platformSlug: normalizedGame.platformSlug,
          coreSoName: normalizedGame.libretroCoreSoName,
        ),
      );
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

  bool _isPrimaryFocusTextInput() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.widget is EditableText;
  }

  void _openSettingsFromGuideButton() {
    if (!mounted || _isPlayerActive) return;
    _navigatorKey.currentState?.popUntil((route) => route.isFirst);
    if (_selectedTab != 3) {
      setState(() => _selectedTab = 3);
    }
  }

  void _stepSectionFromGamepad(int delta) {
    if (!mounted || _isPlayerActive) return;
    if (_navigatorKey.currentState?.canPop() ?? false) return;
    if (_isPrimaryFocusTextInput()) return;
    setState(() {
      _selectedTab = (_selectedTab + delta + 4) % 4;
    });
  }

  void _dispatchSyntheticKeyDown(
    LogicalKeyboardKey logicalKey,
    PhysicalKeyboardKey physicalKey,
  ) {
    final primary = FocusManager.instance.primaryFocus;
    if (primary != null) {
      final syntheticEvent = KeyDownEvent(
        physicalKey: physicalKey,
        logicalKey: logicalKey,
        timeStamp: Duration.zero,
      );
      final chain = <FocusNode>[primary, ...primary.ancestors];
      for (final node in chain) {
        final result = node.onKeyEvent?.call(node, syntheticEvent);
        if (result == KeyEventResult.handled) {
          return;
        }
      }
    }

    if (logicalKey == LogicalKeyboardKey.arrowUp) {
      primary?.focusInDirection(TraversalDirection.up);
    } else if (logicalKey == LogicalKeyboardKey.arrowDown) {
      primary?.focusInDirection(TraversalDirection.down);
    } else if (logicalKey == LogicalKeyboardKey.arrowLeft) {
      primary?.focusInDirection(TraversalDirection.left);
    } else if (logicalKey == LogicalKeyboardKey.arrowRight) {
      primary?.focusInDirection(TraversalDirection.right);
    } else if (logicalKey == LogicalKeyboardKey.gameButtonA ||
        logicalKey == LogicalKeyboardKey.enter) {
      final ctx = primary?.context;
      if (ctx != null) {
        Actions.maybeInvoke<ActivateIntent>(ctx, const ActivateIntent());
      }
    } else if (logicalKey == LogicalKeyboardKey.gameButtonB ||
        logicalKey == LogicalKeyboardKey.escape) {
      final nav = _navigatorKey.currentState;
      if (nav != null && nav.canPop()) {
        unawaited(nav.maybePop());
      } else if (_selectedTab != 0 && mounted) {
        setState(() => _selectedTab = 0);
      }
    }
  }

  void _handleGlobalGamepadUiAction(Map<String, dynamic> event) {
    if (!mounted || _isPlayerActive) return;
    final action = (event['action'] as String?) ?? '';
    switch (action) {
      case 'guide':
        _openSettingsFromGuideButton();
        return;
      case 'l1':
      case 'l2':
        _stepSectionFromGamepad(-1);
        return;
      case 'r1':
      case 'r2':
        _stepSectionFromGamepad(1);
        return;
      case 'dpadUp':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.arrowUp,
          PhysicalKeyboardKey.arrowUp,
        );
        return;
      case 'dpadDown':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.arrowDown,
          PhysicalKeyboardKey.arrowDown,
        );
        return;
      case 'dpadLeft':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.arrowLeft,
          PhysicalKeyboardKey.arrowLeft,
        );
        return;
      case 'dpadRight':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.arrowRight,
          PhysicalKeyboardKey.arrowRight,
        );
        return;
      case 'a':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.gameButtonA,
          PhysicalKeyboardKey.keyA,
        );
        return;
      case 'b':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.gameButtonB,
          PhysicalKeyboardKey.keyB,
        );
        return;
      case 'x':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.gameButtonX,
          PhysicalKeyboardKey.keyX,
        );
        return;
      case 'y':
        _dispatchSyntheticKeyDown(
          LogicalKeyboardKey.gameButtonY,
          PhysicalKeyboardKey.keyY,
        );
        return;
      default:
        return;
    }
  }

  KeyEventResult _handleRootAppKeyEvent(FocusNode node, KeyEvent event) {
    if (_isPlayerActive) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.gameButtonMode) {
      if (event is KeyDownEvent) {
        _openSettingsFromGuideButton();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.gameButtonLeft1 ||
        key == LogicalKeyboardKey.gameButtonLeft2) {
      if (!(_navigatorKey.currentState?.canPop() ?? false) &&
          !_isPrimaryFocusTextInput()) {
        if (event is KeyDownEvent) {
          _stepSectionFromGamepad(-1);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.gameButtonRight1 ||
        key == LogicalKeyboardKey.gameButtonRight2) {
      if (!(_navigatorKey.currentState?.canPop() ?? false) &&
          !_isPrimaryFocusTextInput()) {
        if (event is KeyDownEvent) {
          _stepSectionFromGamepad(1);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if ((key == LogicalKeyboardKey.gameButtonB ||
            key == LogicalKeyboardKey.gameButton2 ||
            key == LogicalKeyboardKey.goBack) &&
        !_isPrimaryFocusTextInput()) {
      if (event is KeyDownEvent) {
        final nav = _navigatorKey.currentState;
        if (nav != null && nav.canPop()) {
          unawaited(nav.maybePop());
          return KeyEventResult.handled;
        }
        if (_selectedTab != 0 && mounted) {
          setState(() => _selectedTab = 0);
          return KeyEventResult.handled;
        }
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handleImportExternalIsoFromLibrary(
    BuildContext navContext,
  ) async {
    if (_isImportingExternalIso) return;
    _isImportingExternalIso = true;
    String? pickedPath;
    var usedDirectAndroidPicker = false;
    var keepPickedPathForCopy = false;
    var pickedIsDirectory = false;

    try {
      String? rawFileName;

      // Pergunta se o usuário deseja importar um arquivo (.iso/.zip/.7z/etc.)
      // ou uma pasta de dump de jogo (como PS3_GAME/USRDIR/EBOOT.BIN).
      if (!navContext.mounted) return;
      final pickKind = await showDialog<String?>(
        context: navContext,
        builder: (ctx) => AlertDialog(
          backgroundColor: HydraTokens.bgNearBlack,
          shape: HydraTokens.dialogShape,
          title: const Text(
            'Importar Jogo ou Dump',
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: HydraTokens.textPrimary,
            ),
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Escolha entre selecionar um arquivo (.iso, .zip, .7z, .chd, .pkg, EBOOT.BIN...) ou a pasta do jogo (PS3_GAME/USRDIR/EBOOT.BIN).',
                  style: TextStyle(
                    fontFamily: 'Rubik',
                    fontSize: 12.5,
                    height: 1.4,
                    color: HydraTokens.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: HydraTokens.surfaceElevated1,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: HydraTokens.borderSubtle10),
                  ),
                  child: const Text(
                    'Dica para PS3: aceita pasta (PS3_GAME/USRDIR/EBOOT.BIN), ISO já descriptografada e .zip ou .7z. Para gerar esse dump a partir dos seus discos, use o próprio PS3 com CFW ou HEN e ferramentas como ManaGunZ, multiMAN ou IRISMAN — elas já criam ISO descriptografada ou pasta prontas para o RPCS3.',
                    style: TextStyle(
                      fontFamily: 'Rubik',
                      fontSize: 11.5,
                      height: 1.38,
                      color: HydraTokens.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: HydraTokens.primaryAurora,
                    foregroundColor: HydraTokens.bgPureBlack,
                    minimumSize: const Size(48, 46),
                  ),
                  onPressed: () => Navigator.of(ctx).pop('file'),
                  icon: PhosphorIcon(
                    PhosphorIcons.fileArchive(PhosphorIconsStyle.bold),
                    size: 16,
                  ),
                  label: const Text(
                    'Selecionar Arquivo (.iso, .zip, .7z...)',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HydraTokens.textPrimary,
                    side: const BorderSide(color: HydraTokens.borderSubtle10),
                    minimumSize: const Size(48, 46),
                  ),
                  onPressed: () => Navigator.of(ctx).pop('folder'),
                  icon: PhosphorIcon(
                    PhosphorIcons.folderOpen(PhosphorIconsStyle.bold),
                    size: 16,
                  ),
                  label: const Text(
                    'Selecionar Pasta do Jogo (PS3_GAME)',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('Cancelar'),
            ),
          ],
        ),
      );

      if (pickKind == null || !mounted || !navContext.mounted) {
        return;
      }

      if (pickKind == 'folder') {
        if (Platform.isAndroid) {
          var hasAccess = await EmulatorService.hasDirectStorageAccess();
          if (!hasAccess && navContext.mounted) {
            final askPermission = await showDialog<bool>(
                  context: navContext,
                  builder: (ctx) => AlertDialog(
                    backgroundColor: HydraTokens.bgNearBlack,
                    shape: HydraTokens.dialogShape,
                    title: const Text('Acesso às pastas do armazenamento'),
                    content: const Text(
                      'Conceda permissão para abrir pastas PS3_GAME/USRDIR diretamente sem copiar gigabytes no aparelho.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(false),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(ctx).pop(true),
                        child: const Text('Permitir acesso'),
                      ),
                    ],
                  ),
                ) ??
                false;
            if (!askPermission) return;
            hasAccess = await EmulatorService.requestDirectStorageAccess();
          }
          if (!hasAccess) return;
        }

        final dirPath = await EmulatorService.pickExternalRomDirectory();
        if (dirPath == null || dirPath.trim().isEmpty || !mounted || !navContext.mounted) {
          return;
        }
        pickedPath = dirPath.trim();
        pickedIsDirectory = true;
        usedDirectAndroidPicker = true;
        keepPickedPathForCopy = true;
        rawFileName = pickedPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
      } else if (Platform.isAndroid) {
        var hasAccess = await EmulatorService.hasDirectStorageAccess();
        if (!hasAccess && navContext.mounted) {
          final askPermission = await showDialog<bool>(
                context: navContext,
                builder: (ctx) => AlertDialog(
                  backgroundColor: HydraTokens.bgNearBlack,
                  shape: HydraTokens.dialogShape,
                  title: const Text(
                    'Executar ISOs direto sem copiar',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: HydraTokens.textPrimary,
                    ),
                  ),
                  content: const Text(
                    'Para abrir ISOs e ROMs diretamente da pasta onde foram baixadas — sem duplicar arquivos no app nem esperar cópia — conceda acesso de leitura ao armazenamento.',
                    style: TextStyle(
                      fontFamily: 'Rubik',
                      fontSize: 13.5,
                      color: HydraTokens.textSecondary,
                      height: 1.4,
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancelar'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: HydraTokens.primaryAurora,
                        foregroundColor: HydraTokens.bgPureBlack,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Permitir acesso'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!askPermission) return;
          hasAccess = await EmulatorService.requestDirectStorageAccess();
        }
        if (!hasAccess) {
          if (navContext.mounted) {
            ScaffoldMessenger.of(navContext).showSnackBar(
              const SnackBar(
                content: Text(
                  'Permissão necessária para abrir ISOs direto do armazenamento sem duplicar.',
                ),
              ),
            );
          }
          return;
        }

        final pickedDirect = await EmulatorService.pickExternalRomDirect();
        if (pickedDirect == null || !mounted || !navContext.mounted) {
          return;
        }
        if (!pickedDirect.isDirect || pickedDirect.path.isEmpty) {
          ScaffoldMessenger.of(navContext).showSnackBar(
            SnackBar(
              content: Text(
                'Não foi possível acessar "${pickedDirect.name}" diretamente sem cópia. Selecione um arquivo no Armazenamento Interno / Downloads (não nuvem).',
              ),
            ),
          );
          return;
        }
        usedDirectAndroidPicker = true;
        keepPickedPathForCopy = true;
        pickedPath = pickedDirect.path;
        rawFileName = pickedDirect.name.isNotEmpty
            ? pickedDirect.name
            : pickedPath.split(Platform.pathSeparator).last;
      } else {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.any,
          allowMultiple: false,
        );
        final picked = result?.files.single;
        pickedPath = picked?.path;
        if (pickedPath == null || !mounted || !navContext.mounted) {
          return;
        }
        rawFileName =
            (picked?.name ?? pickedPath.split(Platform.pathSeparator).last)
                .trim();
      }

      rawFileName = rawFileName.trim();
      final resolvedFileName = rawFileName;
      final dotIdx = resolvedFileName.lastIndexOf('.');
      final rawStem = !pickedIsDirectory && dotIdx > 0
          ? resolvedFileName.substring(0, dotIdx)
          : resolvedFileName;
      final defaultTitle = rawStem
          .replaceAll('_', ' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      final detection = await RomPlatformDetector.detect(
        resolvedFileName,
        filePath: pickedPath,
      );
      debugPrint(
        '[Import] origem="$resolvedFileName" dir=$pickedIsDirectory path=$pickedPath '
        'detectado=${detection?.slug ?? "null"} '
        'fonte=${detection?.sourceLabel ?? "-"}',
      );
      if (!mounted || !navContext.mounted) return;
      final selectableSlugs = kRommPlatforms
          .map((p) => p.slug)
          .where((slug) => slug != 'todos')
          .toSet();
      String? selectedSlug = detection != null &&
              selectableSlugs.contains(detection.slug)
          ? detection.slug
          : (pickedIsDirectory ? 'ps3' : null);

      String platformLabel(String? slug) => kRommPlatforms
          .firstWhere((p) => p.slug == slug, orElse: () => kRommPlatforms.first)
          .fullName;

      final titleController = TextEditingController(
        text: defaultTitle.isEmpty ? 'Jogo Importado' : defaultTitle,
      );
      String? chosenSlug;
      try {
        chosenSlug = await showDialog<String?>(
              context: navContext,
              builder: (ctx) => StatefulBuilder(
                builder: (ctx, setDialogState) {
                  final lowerExt = resolvedFileName.toLowerCase();
                  final isConsoleArchive = !pickedIsDirectory &&
                      (lowerExt.endsWith('.zip') || lowerExt.endsWith('.7z')) &&
                      !const {'arcade', 'neogeo', 'fbneo', 'cps1', 'cps2', 'cps3'}
                          .contains(selectedSlug);
                  final isUnsupportedRar =
                      !pickedIsDirectory && lowerExt.endsWith('.rar');
                  final slug = selectedSlug;
                  final platformCompatible = slug != null &&
                      (pickedIsDirectory ||
                          RomDownloadService.isImportExtensionCompatible(
                            slug,
                            resolvedFileName,
                          ));
                  return AlertDialog(
                    backgroundColor: HydraTokens.bgNearBlack,
                    shape: HydraTokens.dialogShape,
                    title: const Text(
                      'Adicionar ISO / ROM externa',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                    content: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 440),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              resolvedFileName,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 11,
                                color: HydraTokens.primaryAurora,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              isUnsupportedRar
                                  ? 'Arquivo .rar: converta ou descompacte para .zip, .7z, ISO ou pasta antes.'
                                  : isConsoleArchive
                                      ? 'Será extraído em 2º plano (Isolate) com barra de progresso e validação de conteúdo.'
                                      : 'Execução direta sem cópia (arquivo/pasta original mantido em $pickedPath).',
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Rubik',
                                fontSize: 11.5,
                                color: isUnsupportedRar
                                    ? const Color(0xFFFFB74D)
                                    : HydraTokens.textSecondary,
                              ),
                            ),
                            if (selectedSlug == 'ps3') ...[
                              const SizedBox(height: 8),
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: HydraTokens.surfaceElevated1,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: HydraTokens.borderSubtle10,
                                  ),
                                ),
                                child: const Text(
                                  'Dumps PS3 válidos: pasta PS3_GAME/USRDIR/EBOOT.BIN, ISO descriptografada ou .zip/.7z contendo esse dump. Use PS3 com CFW/HEN (ManaGunZ, multiMAN ou IRISMAN).',
                                  style: TextStyle(
                                    fontFamily: 'Rubik',
                                    fontSize: 11,
                                    height: 1.35,
                                    color: HydraTokens.textSecondary,
                                  ),
                                ),
                              ),
                            ],
                            if (selectedSlug == null) ...[
                              const SizedBox(height: 6),
                              const Text(
                                'Plataforma não reconhecida. Escolha o console correto — o emulador é selecionado pela plataforma.',
                                style: TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: Color(0xFFFFB74D),
                                ),
                              ),
                            ] else if (detection != null &&
                                detection.slug == selectedSlug) ...[
                              const SizedBox(height: 6),
                              Text(
                                'Plataforma detectada (${detection.sourceLabel}): ${platformLabel(selectedSlug)}.',
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: HydraTokens.textSecondary,
                                ),
                              ),
                            ],
                            const SizedBox(height: 12),
                            TextField(
                              controller: titleController,
                              style: const TextStyle(
                                fontFamily: 'Rubik',
                                fontSize: 13.5,
                                color: HydraTokens.textPrimary,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'Nome do jogo na Biblioteca',
                                border: OutlineInputBorder(),
                              ),
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<String>(
                              value: selectedSlug,
                              dropdownColor: HydraTokens.bgNearBlack,
                              decoration: const InputDecoration(
                                labelText: 'Console / Plataforma',
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                const DropdownMenuItem<String>(
                                  value: null,
                                  child: Text(
                                    'Escolha o console...',
                                    style: TextStyle(
                                      fontFamily: 'Rubik',
                                      fontSize: 13,
                                      color: HydraTokens.textSecondary,
                                    ),
                                  ),
                                ),
                                ...kRommPlatforms
                                    .where((p) => p.slug != 'todos')
                                    .map(
                                      (p) => DropdownMenuItem<String>(
                                        value: p.slug,
                                        child: Text(
                                          '${p.fullName} (${p.shortName})',
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'Rubik',
                                            fontSize: 13,
                                            color: HydraTokens.textPrimary,
                                          ),
                                        ),
                                      ),
                                    ),
                              ],
                              onChanged: (value) {
                                setDialogState(() => selectedSlug = value);
                              },
                            ),
                            if (slug != null && !platformCompatible) ...[
                              const SizedBox(height: 8),
                              Text(
                                'A extensão "${dotIdx > 0 ? resolvedFileName.substring(dotIdx) : ''}" não é compatível com ${platformLabel(slug)}. Escolha outro console ou importe o arquivo correto.',
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 11.5,
                                  height: 1.4,
                                  color: Color(0xFFF87171),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    actions: [
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancelar'),
                      ),
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(48, 48),
                          backgroundColor: HydraTokens.primaryAurora,
                          foregroundColor: HydraTokens.bgPureBlack,
                        ),
                        onPressed: platformCompatible && !isUnsupportedRar
                            ? () => Navigator.of(ctx).pop(slug)
                            : null,
                        child: const Text(
                          'Adicionar',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            );
      } finally {
        final finalTitle = titleController.text.trim();
        titleController.dispose();
        if (chosenSlug != null && mounted) {
          keepPickedPathForCopy = true;
          int importId = _stableImportId(pickedPath);
          while (_catalogById.containsKey(importId)) {
            importId++;
          }
          final lowerExt = resolvedFileName.toLowerCase();
          final needsProgressModal = (!pickedIsDirectory &&
                  (lowerExt.endsWith('.zip') || lowerExt.endsWith('.7z')) &&
                  !const {'arcade', 'neogeo', 'fbneo', 'cps1', 'cps2', 'cps3'}
                      .contains(chosenSlug)) ||
              chosenSlug == 'ps3';

          final progressNotifier = ValueNotifier<({double p, String msg})>(
            (p: 0.0, msg: 'Preparando importação...'),
          );
          var progressDialogShown = false;
          BuildContext? dialogCtx;
          if (needsProgressModal && navContext.mounted) {
            progressDialogShown = true;
            unawaited(
              showDialog<void>(
                context: navContext,
                barrierDismissible: false,
                builder: (dCtx) {
                  dialogCtx = dCtx;
                  return PopScope(
                    canPop: false,
                    child: AlertDialog(
                      backgroundColor: HydraTokens.bgNearBlack,
                      shape: HydraTokens.dialogShape,
                      title: Text(
                        chosenSlug == 'ps3'
                            ? 'Processando Dump de PS3'
                            : 'Extraindo Pacote',
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                      content: SizedBox(
                        width: 340,
                        child: ValueListenableBuilder<({double p, String msg})>(
                          valueListenable: progressNotifier,
                          builder: (_, state, __) => LoopProgressIndicator(
                            progress: state.p,
                            label: state.msg,
                            minHeight: 7,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            );
          }

          ({String localPath, int totalBytes})? imported;
          try {
            imported = await _downloadService.importExternalRomFile(
              igdbId: importId,
              sourcePath: pickedPath,
              platformSlug: chosenSlug,
              onProgress: (p, label) {
                progressNotifier.value = (p: p, msg: label);
              },
            );
          } finally {
            progressNotifier.dispose();
            if (progressDialogShown && dialogCtx != null && dialogCtx!.mounted) {
              Navigator.of(dialogCtx!).pop();
            } else if (progressDialogShown && navContext.mounted) {
              unawaited(Navigator.of(navContext, rootNavigator: true).maybePop());
            }
          }

          debugPrint(
            '[Import] id=$importId slug=$chosenSlug '
            'origem=$pickedPath -> ${imported?.localPath ?? "FALHOU"}',
          );
          if (imported != null && mounted) {
            final platformSpec = kRommPlatforms.firstWhere(
              (p) => p.slug == chosenSlug,
              orElse: () => kRommPlatforms.first,
            );
            final displayTitle = finalTitle.isEmpty
                ? (defaultTitle.isEmpty ? resolvedFileName : defaultTitle)
                : finalTitle;
            final importedGame = EmulationGame(
              igdbId: importId,
              name: displayTitle,
              canonicalNoIntroName: displayTitle,
              summary: 'ROM/ISO vinculada localmente (${platformSpec.fullName}).',
              genres: const ['Importado'],
              developer: 'Arquivo Local',
              releaseYear: null,
              rating: null,
              platformName: platformSpec.fullName,
              platformSlug: platformSpec.slug,
              directRomUrl: '',
              estimatedSizeBytes: imported.totalBytes,
              localRomPath: imported.localPath,
            );
            await _handleStatusUpdated(
              importedGame,
              RomDownloadStatus(
                state: RomActionState.readyToPlay,
                progress: 1.0,
                localPath: imported.localPath,
                crcVerified: true,
              ),
            );
            if (navContext.mounted) {
              ScaffoldMessenger.of(navContext).showSnackBar(
                SnackBar(
                  content: Text(
                    '${importedGame.name} (${importedGame.formattedSize}) adicionado à Biblioteca.',
                  ),
                ),
              );
            }
          } else if (navContext.mounted) {
            ScaffoldMessenger.of(navContext).showSnackBar(
              const SnackBar(
                content: Text('Não foi possível vincular o arquivo selecionado.'),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (navContext.mounted) {
        final msg = e is StateError ? e.message : 'Falha ao vincular ISO/ROM: $e';
        await showDialog<void>(
          context: navContext,
          builder: (ctx) => AlertDialog(
            backgroundColor: HydraTokens.bgNearBlack,
            shape: HydraTokens.dialogShape,
            title: const Text(
              'Falha na Importação',
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 15.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFFF87171),
              ),
            ),
            content: Text(
              msg,
              style: const TextStyle(
                fontFamily: 'Rubik',
                fontSize: 12.5,
                height: 1.4,
                color: HydraTokens.textPrimary,
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Entendi'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (!keepPickedPathForCopy && !usedDirectAndroidPicker) {
        await EmulatorService.cleanFilePickerTempCache(pickedPath: pickedPath);
      }
      _isImportingExternalIso = false;
    }
  }

  Future<void> _launchLibretroPlayer(
    BuildContext navContext,
    EmulationGame game,
    String localRomPath,
  ) async {
    debugPrint(
      '[Launch] #${game.igdbId} "${game.name}" slug=${game.platformSlug} '
      'core=${game.libretroCoreSoName} rom=$localRomPath',
    );
    final navigator = Navigator.of(navContext);
    navigator.popUntil((route) => route.isFirst);
    _isPlayerActive = true;
    try {
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
    } finally {
      _isPlayerActive = false;
    }
    SystemChrome.setSystemUIOverlayStyle(_kLoopEdgeOverlayStyle);
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
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
      navigatorKey: _navigatorKey,
      title: 'LoopGamer',
      debugShowCheckedModeBanner: false,
      theme: HydraTokens.buildAppTheme(),
      builder: (context, child) => Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _handleRootAppKeyEvent,
        child: child ?? const SizedBox.shrink(),
      ),
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
          return Scaffold(
            backgroundColor: PS5HydraTheme.pitchBlack,
            body: Stack(
              children: [
                Positioned.fill(
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
                        isActive: _selectedTab == 1,
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
                            onImportExternalIsoPressed: () => unawaited(
                              _handleImportExternalIsoFromLibrary(navContext),
                            ),
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
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: _GameHubLandscapeTopBar(
                    currentIndex: _selectedTab,
                    libraryBadgeCountListenable: _libraryBadgeCountNotifier,
                    hasActiveDownloadListenable: _hasActiveDownloadNotifier,
                    hardwareGamepadListenable: _hardwareGamepadNotifier,
                    onSelectTab: (index) =>
                        setState(() => _selectedTab = index),
                    onNetworkRestored: () =>
                        unawaited(_downloadService.onAppOrNetworkResumed()),
                  ),
                ),
              ],
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

/// Indicador real de Wi-Fi na barra superior (sem estado estático falso).
class _LiveTopBarWifi extends StatefulWidget {
  const _LiveTopBarWifi({this.onNetworkRestored});

  final VoidCallback? onNetworkRestored;

  @override
  State<_LiveTopBarWifi> createState() => _LiveTopBarWifiState();
}

class _LiveTopBarWifiState extends State<_LiveTopBarWifi>
    with WidgetsBindingObserver {
  Timer? _timer;
  bool _connected = true;
  bool _wifi = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_refreshNetwork());
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      unawaited(_refreshNetwork());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_refreshNetwork());
    }
  }

  Future<void> _refreshNetwork() async {
    final status = await EmulatorService.fetchNetworkStatus();
    if (!mounted) return;
    final restored = !_connected && status.connected;
    if (status.connected != _connected || status.wifi != _wifi) {
      setState(() {
        _connected = status.connected;
        _wifi = status.wifi;
      });
    }
    if (restored) {
      widget.onNetworkRestored?.call();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final String label;
    final PhosphorIconData icon;
    final Color color;

    if (_wifi) {
      label = 'Wi-Fi conectado';
      icon = PhosphorIcons.wifiHigh(PhosphorIconsStyle.bold);
      color = HydraTokens.textPrimary;
    } else if (_connected) {
      label = 'Sem Wi-Fi (dados móveis)';
      icon = PhosphorIcons.wifiSlash(PhosphorIconsStyle.regular);
      color = HydraTokens.textSecondary;
    } else {
      label = 'Sem conexão';
      icon = PhosphorIcons.wifiSlash(PhosphorIconsStyle.regular);
      color = HydraTokens.textMuted;
    }

    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Tooltip(
        message: label,
        child: PhosphorIcon(
          icon,
          size: 16,
          color: color,
        ),
      ),
    );
  }
}

/// Cápsula translúcida estilo iOS para a barra flutuante no modo horizontal.
class _IosFloatingCapsule extends StatelessWidget {
  const _IosFloatingCapsule({
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.32),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: HydraTokens.surfaceTopBar.withOpacity(0.76),
              borderRadius: radius,
              border: Border.all(
                color: Colors.white.withOpacity(0.14),
                width: 1.0,
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// Top Bar flutuante estilo iOS (cápsulas arredondadas sem faixa preta de fundo)
class _GameHubLandscapeTopBar extends StatelessWidget {
  const _GameHubLandscapeTopBar({
    required this.currentIndex,
    required this.libraryBadgeCountListenable,
    required this.hasActiveDownloadListenable,
    required this.hardwareGamepadListenable,
    required this.onSelectTab,
    this.onNetworkRestored,
  });

  final int currentIndex;
  final ValueListenable<int> libraryBadgeCountListenable;
  final ValueListenable<bool> hasActiveDownloadListenable;
  final ValueListenable<bool> hardwareGamepadListenable;
  final ValueChanged<int> onSelectTab;
  final VoidCallback? onNetworkRestored;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Flexible(
                    child: _IosFloatingCapsule(
                      padding: const EdgeInsets.all(4),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Stack(
                          children: [
                            AnimatedPositioned(
                              duration: PS5HydraTheme.animStandard,
                              curve: Curves.easeOut,
                              left: currentIndex * 100.0 + 18.0,
                              bottom: 0,
                              width: 64.0,
                              height: 2.0,
                              child: const DecoratedBox(
                                decoration: BoxDecoration(
                                  color: PS5HydraTheme.auroraSpringMint,
                                ),
                              ),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: List.generate(navItems.length, (i) {
                                final active = i == currentIndex;
                                return SizedBox(
                                  width: 100.0,
                                  child: Semantics(
                                    button: true,
                                    selected: active,
                                    label: navItems[i].label,
                                    child: Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        borderRadius: BorderRadius.circular(999),
                                        onTap: () => onSelectTab(i),
                                        child: AnimatedContainer(
                                          duration: const Duration(
                                            milliseconds: 200,
                                          ),
                                          curve: Curves.easeOut,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 8,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: active
                                                ? PS5HydraTheme.abyssalCard
                                                : Colors.transparent,
                                            borderRadius:
                                                BorderRadius.circular(999),
                                          ),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              PhosphorIcon(
                                                navItems[i].icon,
                                                size: 15,
                                                color: active
                                                    ? PS5HydraTheme
                                                        .auroraSpringMint
                                                    : PS5HydraTheme
                                                        .textSecondary,
                                              ),
                                              const SizedBox(width: 5),
                                              Flexible(
                                                child: Text(
                                                  navItems[i].label,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontFamily: 'ReadexPro',
                                                    fontSize: 11.5,
                                                    fontWeight: active
                                                        ? FontWeight.w700
                                                        : FontWeight.w600,
                                                    color: active
                                                        ? PS5HydraTheme
                                                            .textPrimary
                                                        : PS5HydraTheme
                                                            .textSecondary,
                                                  ),
                                                ),
                                              ),
                                              if (navItems[i].badge != null) ...[
                                                const SizedBox(width: 4),
                                                Container(
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 5,
                                                    vertical: 1,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color: PS5HydraTheme
                                                        .auroraSpringMint,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      8,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    navItems[i].badge!,
                                                    style: const TextStyle(
                                                      fontFamily:
                                                          'JetBrainsMono',
                                                      fontSize: 9,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                      color: PS5HydraTheme
                                                          .textOnAurora,
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
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _IosFloatingCapsule(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 4,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          button: true,
                          label: 'Buscar ROMs',
                          excludeSemantics: true,
                          child: Tooltip(
                            message: 'Buscar ROMs',
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => onSelectTab(1),
                                child: Padding(
                                  padding: const EdgeInsets.all(7),
                                  child: PhosphorIcon(
                                    PhosphorIcons.magnifyingGlass(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    size: 16,
                                    color: HydraTokens.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: hasActiveDownload
                              ? 'Downloads em andamento'
                              : 'Abrir Biblioteca',
                          excludeSemantics: true,
                          child: Tooltip(
                            message: hasActiveDownload
                                ? 'Downloads em andamento'
                                : 'Abrir Biblioteca',
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                customBorder: const CircleBorder(),
                                onTap: () => onSelectTab(2),
                                child: Padding(
                                  padding: const EdgeInsets.all(7),
                                  child: PhosphorIcon(
                                    PhosphorIcons.floppyDisk(
                                      hasActiveDownload
                                          ? PhosphorIconsStyle.fill
                                          : PhosphorIconsStyle.regular,
                                    ),
                                    size: 16,
                                    color: HydraTokens.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        ValueListenableBuilder<bool>(
                          valueListenable: hardwareGamepadListenable,
                          builder: (context, gamepadActive, _) {
                            if (!gamepadActive) return const SizedBox.shrink();
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              child: Tooltip(
                                message: 'Controle físico ativo',
                                child: Semantics(
                                  label: 'Controle físico ativo',
                                  child: PhosphorIcon(
                                    PhosphorIcons.gameController(
                                      PhosphorIconsStyle.fill,
                                    ),
                                    size: 16,
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
                          margin: const EdgeInsets.symmetric(horizontal: 6),
                          color: Colors.white.withOpacity(0.18),
                        ),
                        _LiveTopBarWifi(onNetworkRestored: onNetworkRestored),
                        const SizedBox(width: 6),
                        const _LiveTopBarClock(),
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// ID determinístico para ROM importada. `hashCode` não é estável entre
/// execuções e gerava entrada duplicada na biblioteca após reiniciar o app.
int _stableImportId(String path) {
  final normalized = path.replaceAll('\\', '/').toLowerCase();
  var hash = 0x811c9dc5;
  for (final codeUnit in normalized.codeUnits) {
    hash ^= codeUnit;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return 900000000 + (hash % 90000000);
}
