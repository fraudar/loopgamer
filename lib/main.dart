import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  StreamSubscription<RomDownloadEvent>? _downloadEventsSub;
  int _selectedTab = 0;
  AppSettings _settings = const AppSettings();
  UserLibraryMeta _userMeta = const UserLibraryMeta();
  final Map<int, RomDownloadStatus> _downloadStatuses = {};
  final Map<int, EmulationGame> _catalogById = {
    for (final g in kVerifiedRealGamesCatalog) g.igdbId: g,
  };

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    CoverCacheService.instance.precacheCatalog(kVerifiedRealGamesCatalog);
    _downloadEventsSub = _downloadService.downloadEvents.listen((event) {
      _handleStatusUpdated(event.game, event.status);
    });
    _restoreState();
  }

  @override
  void dispose() {
    _downloadEventsSub?.cancel();
    super.dispose();
  }

  Future<void> _restoreState() async {
    final loadedSettings = await _settingsStorage.loadSettings();
    final loadedMeta = await _settingsStorage.loadUserMeta();
    final savedGames = await _libraryStorage.loadPersistedLibrary();
    for (final g in savedGames) {
      _catalogById[g.igdbId] = g;
      if (g.localRomPath != null) {
        _downloadStatuses[g.igdbId] = RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: g.localRomPath,
        );
      }
    }

    for (final game in _catalogById.values) {
      final localPath =
          await _downloadService.resolveExistingRomPath(game.igdbId);
      if (localPath != null) {
        _downloadStatuses[game.igdbId] = RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: localPath,
        );
      }
    }
    if (mounted) {
      setState(() {
        _settings = loadedSettings;
        _userMeta = loadedMeta;
      });
    }

    final expandedCatalog = await _apiService.fetchRealCatalog(
      rommServerUrl: loadedSettings.rommServerUrl,
      rommApiToken: loadedSettings.rommApiToken,
    );
    if (mounted && expandedCatalog.isNotEmpty) {
      setState(() {
        for (final g in expandedCatalog) {
          _catalogById.putIfAbsent(g.igdbId, () => g);
        }
      });
    }
  }

  Future<void> _handleSettingsUpdated(AppSettings next) async {
    final rommChanged =
        next.rommServerUrl != _settings.rommServerUrl ||
        next.rommApiToken != _settings.rommApiToken;
    setState(() => _settings = next);
    await _settingsStorage.saveSettings(next);
    if (rommChanged && next.rommServerUrl.trim().isNotEmpty) {
      final remote = await _apiService.fetchFromRommServer(
        serverUrl: next.rommServerUrl,
        apiToken: next.rommApiToken,
      );
      if (mounted && remote.isNotEmpty) {
        setState(() {
          for (final g in remote) {
            _catalogById[g.igdbId] = g;
          }
        });
      }
    }
  }

  Future<void> _handleUserMetaUpdated(UserLibraryMeta next) async {
    setState(() => _userMeta = next);
    await _settingsStorage.saveUserMeta(next);
  }

  Future<void> _handleStatusUpdated(
    EmulationGame game,
    RomDownloadStatus status,
  ) async {
    if (!mounted) return;
    setState(() {
      _catalogById[game.igdbId] = game;
      _downloadStatuses[game.igdbId] = status;
    });
    if (status.state == RomActionState.readyToPlay &&
        status.localPath != null) {
      await _libraryStorage.saveGameToLibrary(game, status.localPath!);
    }
  }

  Future<void> _handleRemoveGameFromLibrary(EmulationGame game) async {
    final currentStatus = _downloadStatuses[game.igdbId];
    final localPath = currentStatus?.localPath ?? game.localRomPath;

    await _downloadService.deleteRomFilesForGame(
      game.igdbId,
      localPath: localPath,
    );
    await _libraryStorage.removeGameFromLibrary(game.igdbId);

    if (mounted) {
      setState(() {
        _downloadStatuses[game.igdbId] = const RomDownloadStatus(
          state: RomActionState.notDownloaded,
          progress: 0.0,
        );
        _catalogById[game.igdbId] = game.copyWith(localRomPath: null);
      });
    }
  }

  void _handleCancelDownload(EmulationGame game) {
    _downloadService.cancelDownload(game.igdbId);
    if (mounted) {
      setState(() {
        _downloadStatuses[game.igdbId] = const RomDownloadStatus(
          state: RomActionState.notDownloaded,
          progress: 0.0,
        );
      });
    }
  }

  Future<void> _launchLibretroPlayer(
    BuildContext navContext,
    EmulationGame game,
    String localRomPath,
  ) async {
    await Navigator.of(navContext).push(
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
    final reloadedMeta = await _settingsStorage.loadUserMeta();
    if (mounted) {
      setState(() => _userMeta = reloadedMeta);
    }
  }

  @override
  Widget build(BuildContext context) {
    final allCatalog = _catalogById.values.toList();
    final downloadedGames = allCatalog.where((g) {
      final st = _downloadStatuses[g.igdbId];
      return st != null &&
          st.state == RomActionState.readyToPlay &&
          st.localPath != null;
    }).toList();

    final downloadingGames = allCatalog.where((g) {
      final st = _downloadStatuses[g.igdbId];
      return st != null && st.state == RomActionState.downloading;
    }).toList();

    final libraryBadgeCount = downloadedGames.length + downloadingGames.length;

    return MaterialApp(
      title: 'LoopGamer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: HydraTokens.bgPureBlack,
      ),
      home: Builder(
        builder: (navContext) {
          final size = MediaQuery.sizeOf(navContext);
          final isLandscape = size.width > size.height && size.width >= 560;

          return Scaffold(
            backgroundColor: HydraTokens.bgPureBlack,
            body: Column(
              children: [
                if (isLandscape)
                  _GameHubLandscapeTopBar(
                    currentIndex: _selectedTab,
                    libraryBadgeCount: libraryBadgeCount,
                    hasActiveDownload: downloadingGames.isNotEmpty,
                    onSelectTab: (index) =>
                        setState(() => _selectedTab = index),
                  ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedTab,
                    children: [
                      HomeScreen(
                        featuredGames: kVerifiedRealGamesCatalog,
                        popularGames: allCatalog,
                        downloadStatuses: _downloadStatuses,
                        downloadService: _downloadService,
                        onStatusUpdated: _handleStatusUpdated,
                        onLaunchGame: (game, path) =>
                            _launchLibretroPlayer(navContext, game, path),
                        userMeta: _userMeta,
                        onUserMetaChanged: _handleUserMetaUpdated,
                        onOpenSearchTab: () =>
                            setState(() => _selectedTab = 1),
                        onOpenLibraryTab: () =>
                            setState(() => _selectedTab = 2),
                      ),
                      ExploreScreen(
                        apiService: _apiService,
                        downloadService: _downloadService,
                        downloadStatuses: _downloadStatuses,
                        settings: _settings,
                        onStatusUpdated: _handleStatusUpdated,
                        onLaunchGameInLibretro: (game, path) =>
                            _launchLibretroPlayer(navContext, game, path),
                      ),
                      LibraryScreen(
                        downloadedGames: downloadedGames,
                        downloadingGames: downloadingGames,
                        downloadStatuses: _downloadStatuses,
                        onImportNewRomPressed: () =>
                            setState(() => _selectedTab = 1),
                        onLaunchGame: (game, path) =>
                            _launchLibretroPlayer(navContext, game, path),
                        onRemoveGame: _handleRemoveGameFromLibrary,
                        onCancelDownload: _handleCancelDownload,
                        userMeta: _userMeta,
                        onUserMetaChanged: _handleUserMetaUpdated,
                      ),
                      SettingsScreen(
                        settings: _settings,
                        downloadService: _downloadService,
                        onSettingsChanged: _handleSettingsUpdated,
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
                    installedCount: libraryBadgeCount,
                    isDownloading: downloadingGames.isNotEmpty,
                    onSelect: (index) => setState(() => _selectedTab = index),
                  ),
          );
        },
      ),
    );
  }
}

/// Top Bar Estilo GameHub para Modo Deitado (Landscape — igual às Imagens 1 e 2)
class _GameHubLandscapeTopBar extends StatelessWidget {
  const _GameHubLandscapeTopBar({
    required this.currentIndex,
    required this.libraryBadgeCount,
    required this.hasActiveDownload,
    required this.onSelectTab,
  });

  final int currentIndex;
  final int libraryBadgeCount;
  final bool hasActiveDownload;
  final ValueChanged<int> onSelectTab;

  @override
  Widget build(BuildContext context) {
    final now = TimeOfDay.now();
    final timeStr =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

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

    return Container(
      color: HydraTokens.bgPureBlack.withOpacity(0.95),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 6),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            // Abas estilo GameHub (Rolável horizontalmente se a tela for compacta)
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (int i = 0; i < navItems.length; i++) ...[
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => onSelectTab(i),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
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
                                    ? Colors.white
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
                                      : FontWeight.w500,
                                  color: i == currentIndex
                                      ? Colors.white
                                      : HydraTokens.textSecondary,
                                ),
                              ),
                              if (navItems[i].badge != null) ...[
                                const SizedBox(width: 5),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 5,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: hasActiveDownload
                                        ? HydraTokens.secondaryTeal
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    navItems[i].badge!,
                                    style: const TextStyle(
                                      fontFamily: 'JetBrainsMono',
                                      fontSize: 9,
                                      fontWeight: FontWeight.w700,
                                      color: HydraTokens.bgPureBlack,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(width: 8),

            // Indicadores do canto superior direito igual ao GameHub (Busca, SD/ROM, Gamepad, Relógio, Wi-Fi, Bateria)
            GestureDetector(
              onTap: () => onSelectTab(1),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: PhosphorIcon(
                  PhosphorIcons.magnifyingGlass(PhosphorIconsStyle.bold),
                  size: 17,
                  color: HydraTokens.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => onSelectTab(2),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: PhosphorIcon(
                  PhosphorIcons.floppyDisk(PhosphorIconsStyle.regular),
                  size: 17,
                  color: hasActiveDownload
                      ? HydraTokens.secondaryTeal
                      : HydraTokens.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: 8),
            PhosphorIcon(
              PhosphorIcons.gameController(PhosphorIconsStyle.regular),
              size: 18,
              color: HydraTokens.textPrimary,
            ),
            Container(
              width: 1,
              height: 13,
              margin: const EdgeInsets.symmetric(horizontal: 10),
              color: Colors.white.withOpacity(0.22),
            ),
            Text(
              timeStr,
              style: const TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: HydraTokens.textPrimary,
              ),
            ),
            const SizedBox(width: 8),
            PhosphorIcon(
              PhosphorIcons.wifiHigh(PhosphorIconsStyle.bold),
              size: 15,
              color: HydraTokens.textPrimary,
            ),
            const SizedBox(width: 8),
            PhosphorIcon(
              PhosphorIcons.batteryHigh(PhosphorIconsStyle.fill),
              size: 17,
              color: HydraTokens.textPrimary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom Navigation Bar Estilo GameHub para Modo em Pé (Portrait — igual à Imagem 3)
class _GameHubPortraitDockBar extends StatelessWidget {
  const _GameHubPortraitDockBar({
    required this.currentIndex,
    required this.installedCount,
    required this.isDownloading,
    required this.onSelect,
  });

  final int currentIndex;
  final int installedCount;
  final bool isDownloading;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final items = [
      (
        label: 'Início',
        outline: PhosphorIcons.planet(PhosphorIconsStyle.regular),
        fill: PhosphorIcons.planet(PhosphorIconsStyle.fill),
        badge: null,
      ),
      (
        label: 'ROMs',
        outline: PhosphorIcons.gameController(PhosphorIconsStyle.regular),
        fill: PhosphorIcons.gameController(PhosphorIconsStyle.fill),
        badge: null,
      ),
      (
        label: 'Biblioteca',
        outline: PhosphorIcons.squaresFour(PhosphorIconsStyle.regular),
        fill: PhosphorIcons.squaresFour(PhosphorIconsStyle.fill),
        badge: installedCount > 0 ? '$installedCount' : null,
      ),
      (
        label: 'Ajustes',
        outline: PhosphorIcons.smiley(PhosphorIconsStyle.regular),
        fill: PhosphorIcons.smiley(PhosphorIconsStyle.fill),
        badge: null,
      ),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: HydraTokens.bgPureBlack,
      ),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFF15141C),
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
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: active
                          ? const Color(0xFF262432)
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
                                  ? Colors.white
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
                                        ? HydraTokens.secondaryTeal
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(8),
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
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500,
                            color: active
                                ? Colors.white
                                : HydraTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
