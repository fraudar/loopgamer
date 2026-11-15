import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

import '../models/app_settings.dart';
import '../services/emulator_service.dart';
import '../services/gpu_driver_service.dart';
import '../services/rom_download_service.dart';
import '../theme/hydra_tokens.dart';
import '../widgets/loop_common_widgets.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.settings,
    required this.downloadService,
    required this.onSettingsChanged,
    this.emulatorService,
    this.isActive = true,
    this.libraryCount,
  });

  final AppSettings settings;
  final RomDownloadService downloadService;
  final ValueChanged<AppSettings> onSettingsChanged;
  final EmulatorService? emulatorService;
  final bool isActive;
  final int? libraryCount;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  EmulatorService? _ownedEmulatorService;
  final GpuDriverService _gpuDriverService = GpuDriverService();
  StreamSubscription<RomDownloadEvent>? _downloadEventsSub;
  final Map<int, RomActionState> _lastSeenDownloadStates = {};

  final FocusNode _screenFocusNode = FocusNode(
    debugLabel: 'SettingsScreenFocus',
  );
  final FocusNode _rightPaneContainerFocusNode = FocusNode(
    debugLabel: 'SettingsRightPaneFocus',
  );
  late final List<FocusNode> _categoryFocusNodes = List<FocusNode>.generate(
    _categories.length,
    (i) => FocusNode(debugLabel: 'SettingsCategoryFocus_$i'),
  );
  final ScrollController _portraitScrollController = ScrollController();
  final ScrollController _landscapeScrollController = ScrollController();

  AppStorageBreakdown _storageBreakdown = const AppStorageBreakdown();
  int _storageRefreshSeq = 0;
  bool _hasPs3Firmware = false;
  bool _importingPs3Firmware = false;
  bool _removingPs3Firmware = false;
  bool _isCleaningStorage = false;
  bool _isCleaningSavesAndCovers = false;
  int _selectedCategory = 0;
  int _focusedCategoryIndex = -1;

  EmulatorService get _emulatorService =>
      widget.emulatorService ?? (_ownedEmulatorService ??= EmulatorService());

  static const List<({String title, String subtitle})> _categories = [
    (title: 'HUD na Tela', subtitle: 'Escolher FPS, ms, escala e console'),
    (title: 'Gamepad Touch & Físico', subtitle: 'Modo do controle e vibração'),
    (
      title: 'Drivers, Firmware & Saves',
      subtitle: 'Turnip GPU, Firmware PS3, Saves e RomM',
    ),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _subscribeDownloadEvents();
    unawaited(_refreshAllDiskState());
  }

  @override
  void didUpdateWidget(covariant SettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.emulatorService != null &&
        oldWidget.emulatorService == null &&
        _ownedEmulatorService != null) {
      _ownedEmulatorService!.dispose();
      _ownedEmulatorService = null;
    }

    if (widget.downloadService != oldWidget.downloadService) {
      _lastSeenDownloadStates.clear();
      _subscribeDownloadEvents();
      unawaited(_refreshStorageBytes());
    }

    if (!oldWidget.isActive && widget.isActive) {
      unawaited(_refreshAllDiskState());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !widget.isActive) return;
        if (HydraTokens.isWideLayout(context)) {
          _categoryFocusNodes[_selectedCategory].requestFocus();
        } else {
          _screenFocusNode.requestFocus();
        }
      });
    } else if (oldWidget.isActive && !widget.isActive) {
      if (_screenFocusNode.hasFocus) {
        _screenFocusNode.unfocus();
      }
      if (_focusedCategoryIndex != -1) {
        setState(() => _focusedCategoryIndex = -1);
      }
    } else if (widget.libraryCount != null &&
        widget.libraryCount != oldWidget.libraryCount) {
      unawaited(_refreshStorageBytes());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && widget.isActive) {
      unawaited(_refreshAllDiskState());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_downloadEventsSub?.cancel());
    _downloadEventsSub = null;
    _ownedEmulatorService?.dispose();
    _ownedEmulatorService = null;
    _gpuDriverService.dispose();
    _screenFocusNode.dispose();
    _rightPaneContainerFocusNode.dispose();
    for (final node in _categoryFocusNodes) {
      node.dispose();
    }
    _portraitScrollController.dispose();
    _landscapeScrollController.dispose();
    super.dispose();
  }

  void _subscribeDownloadEvents() {
    unawaited(_downloadEventsSub?.cancel());
    _downloadEventsSub = widget.downloadService.downloadEvents.listen((event) {
      final prev = _lastSeenDownloadStates[event.game.igdbId];
      final next = event.status.state;
      _lastSeenDownloadStates[event.game.igdbId] = next;

      if (next != prev &&
          (next == RomActionState.readyToPlay ||
              next == RomActionState.notDownloaded ||
              next == RomActionState.paused)) {
        unawaited(_refreshStorageBytes());
      }
    });
  }

  Future<void> _refreshAllDiskState() async {
    await Future.wait([
      _refreshStorageBytes(),
      _refreshPs3FirmwareStatus(),
    ]);
  }

  Future<void> _refreshPs3FirmwareStatus() async {
    final installed = await _emulatorService.hasPs3Firmware();
    if (mounted) {
      setState(() => _hasPs3Firmware = installed);
    }
  }

  Future<void> _openGpuDriverManagerModal(AppSettings s) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _GpuDriverManagerSheet(
        gpuDriverService: _gpuDriverService,
        activeDriverDir: s.customVulkanDriverDir,
        activeDriverName: s.customVulkanDriverName,
        onDriversChanged: () => unawaited(_refreshStorageBytes()),
        onDriverSelected: (InstalledGpuDriver? driver) {
          if (driver == null) {
            _update(
              s.copyWith(
                customVulkanDriverDir: '',
                customVulkanDriverName: '',
                customVulkanDriverLabel: '',
              ),
            );
          } else {
            _update(
              s.copyWith(
                customVulkanDriverDir: driver.directoryPath,
                customVulkanDriverName: driver.libraryName,
                customVulkanDriverLabel:
                    '${driver.name} (${driver.driverVersion})',
              ),
            );
          }
        },
      ),
    );
    if (mounted) {
      await _refreshStorageBytes();
    }
  }

  Future<void> _handleImportPs3Firmware() async {
    if (_importingPs3Firmware || _removingPs3Firmware) return;
    setState(() => _importingPs3Firmware = true);
    try {
      final path = await _emulatorService.importPs3Firmware();
      if (!mounted) return;
      if (path != null) {
        setState(() => _hasPs3Firmware = true);
        unawaited(_refreshAllDiskState());
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Firmware PS3 (PS3UPDAT.PUP) importada com sucesso!'),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _importingPs3Firmware = false);
      }
    }
  }

  Future<void> _handleRemovePs3Firmware() async {
    if (_removingPs3Firmware || _importingPs3Firmware || !_hasPs3Firmware) {
      return;
    }
    final sizeInfo = _storageBreakdown.ps3FirmwareBytes > 0
        ? ' (${_formatStorage(_storageBreakdown.ps3FirmwareBytes)})'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HydraTokens.bgNearBlack,
        shape: HydraTokens.dialogShape,
        title: Text(
          'Remover firmware de PS3?',
          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        content: SingleChildScrollView(
          child: Text(
            'Isso removerá o arquivo PS3UPDAT.PUP$sizeInfo e liberará espaço no aparelho. Você precisará importar o PS3UPDAT.PUP novamente para abrir jogos de PS3 no RPCS3.',
            style: const TextStyle(
              fontFamily: 'Rubik',
              fontSize: 12.5,
              height: 1.45,
              color: HydraTokens.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: HydraTokens.accentDanger,
              foregroundColor: HydraTokens.textPrimary,
              minimumSize: const Size(48, 48),
            ),
            child: const Text('Remover'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _removingPs3Firmware = true);
    try {
      final removed = await _emulatorService.removePs3Firmware();
      if (!mounted) return;
      if (removed) {
        setState(() => _hasPs3Firmware = false);
      }
      await _refreshAllDiskState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            removed
                ? 'Firmware PS3 (PS3UPDAT.PUP) removido com sucesso.'
                : 'Nenhum firmware PS3 encontrado para remover.',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Bad state: ', ''))),
      );
    } finally {
      if (mounted) {
        setState(() => _removingPs3Firmware = false);
      }
    }
  }

  Future<void> _handleCleanStorage() async {
    if (_isCleaningStorage ||
        _isCleaningSavesAndCovers ||
        _importingPs3Firmware ||
        _removingPs3Firmware) {
      return;
    }
    setState(() => _isCleaningStorage = true);
    try {
      final freedBytes =
          await widget.downloadService.cleanOrphanPartAndCacheFiles();
      if (!mounted) return;
      await _refreshAllDiskState();
      if (!mounted) return;
      final message = freedBytes > 0
          ? 'Limpeza concluída: ${_formatStorage(freedBytes)} liberados.'
          : 'Nenhum arquivo temporário ou .part órfão encontrado.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Não foi possível limpar o cache agora: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCleaningStorage = false);
      }
    }
  }

  Future<void> _handleCleanSavesAndCovers() async {
    if (_isCleaningStorage ||
        _isCleaningSavesAndCovers ||
        _importingPs3Firmware ||
        _removingPs3Firmware) {
      return;
    }

    final savesBytes = _storageBreakdown.savesBytes;
    final coversBytes = _storageBreakdown.coversBytes;
    final choice = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: HydraTokens.bgNearBlack,
        shape: HydraTokens.dialogShape,
        title: Text(
          'Limpar capas e saves?',
          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
        content: SingleChildScrollView(
          child: Text(
            'Espaço atual:\n'
            '• Capas em cache: ${_formatStorage(coversBytes)}\n'
            '• Saves & Save States: ${_formatStorage(savesBytes)}\n\n'
            'Apagar saves remove o progresso salvo e save states dos jogos. Suas ROMs, firmware, drivers e configurações não serão apagados.',
            style: const TextStyle(
              fontFamily: 'Rubik',
              fontSize: 12.5,
              height: 1.45,
              color: HydraTokens.textSecondary,
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
            onPressed: () => Navigator.of(ctx).pop(null),
            child: const Text('Cancelar'),
          ),
          if (coversBytes > 0 && savesBytes > 0)
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(48, 48),
                foregroundColor: HydraTokens.primaryAurora,
                side: const BorderSide(color: HydraTokens.borderSubtle10),
              ),
              onPressed: () => Navigator.of(ctx).pop('covers'),
              child: const Text('Só capas'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop('all'),
            style: FilledButton.styleFrom(
              backgroundColor: savesBytes > 0
                  ? HydraTokens.accentDanger
                  : HydraTokens.primaryAurora,
              foregroundColor: savesBytes > 0
                  ? HydraTokens.textPrimary
                  : HydraTokens.bgPureBlack,
              minimumSize: const Size(48, 48),
            ),
            child: Text(
              savesBytes > 0 ? 'Limpar tudo' : 'Limpar capas',
            ),
          ),
        ],
      ),
    );
    if (choice == null || !mounted) return;

    setState(() => _isCleaningSavesAndCovers = true);
    try {
      final freedBytes = await widget.downloadService.cleanSavesAndCovers(
        deleteSaves: choice == 'all',
        deleteCovers: true,
      );
      if (!mounted) return;
      await _refreshAllDiskState();
      if (!mounted) return;
      final message = freedBytes > 0
          ? choice == 'covers'
              ? 'Capas removidas: ${_formatStorage(freedBytes)} liberados.'
              : 'Capas e saves removidos: ${_formatStorage(freedBytes)} liberados.'
          : 'Nenhuma capa ou save encontrado para limpar.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Não foi possível limpar capas e saves agora: $e'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isCleaningSavesAndCovers = false);
      }
    }
  }

  Future<void> _showRommConfigDialog(AppSettings s) async {
    final urlController = TextEditingController(text: s.rommServerUrl);
    final tokenController = TextEditingController(text: s.rommApiToken);
    String? urlError;

    try {
      final saved = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              return AlertDialog(
                backgroundColor: HydraTokens.bgNearBlack,
                shape: HydraTokens.dialogShape,
                title: Text(
                  'Servidor RomM Próprio',
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Conecte sua instância RomM (opcional) para listar e baixar sua coleção privada direto no Catálogo.',
                        style: TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 12,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: urlController,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        onChanged: (_) {
                          if (urlError != null) {
                            setDialogState(() => urlError = null);
                          }
                        },
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12.5,
                          color: HydraTokens.textPrimary,
                        ),
                        decoration: InputDecoration(
                          labelText: 'URL do Servidor RomM',
                          hintText: 'https://romm.exemplo.com',
                          errorText: urlError,
                          errorMaxLines: 2,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: tokenController,
                        obscureText: true,
                        autocorrect: false,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12.5,
                          color: HydraTokens.textPrimary,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Bearer Token (opcional)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancelar'),
                  ),
                  FilledButton(
                    onPressed: () {
                      final rawUrl = urlController.text.trim();
                      if (rawUrl.isNotEmpty &&
                          !AppSettings.isValidRommServerUrl(rawUrl)) {
                        setDialogState(() {
                          urlError =
                              'Informe uma URL HTTP ou HTTPS válida com host (ex.: https://romm.exemplo.com).';
                        });
                        return;
                      }
                      Navigator.of(ctx).pop(true);
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: HydraTokens.primaryAurora,
                      foregroundColor: HydraTokens.bgPureBlack,
                      minimumSize: const Size(48, 48),
                    ),
                    child: const Text('Salvar'),
                  ),
                ],
              );
            },
          );
        },
      );
      if (saved == true && mounted) {
        final cleanedUrl = urlController.text.trim();
        _update(
          s.copyWith(
            rommServerUrl: cleanedUrl,
            rommApiToken: tokenController.text.trim(),
          ),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              cleanedUrl.isEmpty
                  ? 'Servidor RomM removido.'
                  : 'Servidor RomM salvo! A sincronização foi iniciada.',
            ),
          ),
        );
      }
    } finally {
      urlController.dispose();
      tokenController.dispose();
    }
  }

  bool _isSameBreakdown(AppStorageBreakdown a, AppStorageBreakdown b) {
    return a.readyRomsBytes == b.readyRomsBytes &&
        a.partialDownloadsBytes == b.partialDownloadsBytes &&
        a.systemAndCoresBytes == b.systemAndCoresBytes &&
        a.savesAndCoversBytes == b.savesAndCoversBytes &&
        a.savesBytes == b.savesBytes &&
        a.coversBytes == b.coversBytes &&
        a.tempCacheBytes == b.tempCacheBytes &&
        a.ps3FirmwareBytes == b.ps3FirmwareBytes &&
        a.orphanPartCount == b.orphanPartCount;
  }

  Future<void> _refreshStorageBytes() async {
    final seq = ++_storageRefreshSeq;
    final breakdown = await widget.downloadService.getAppStorageBreakdown();
    if (!mounted || seq != _storageRefreshSeq) return;
    if (!_isSameBreakdown(_storageBreakdown, breakdown)) {
      setState(() => _storageBreakdown = breakdown);
    }
  }

  String _formatStorage(int bytes) {
    if (bytes <= 0) return '0 MB';
    if (bytes < 100 * 1024) {
      return '${(bytes / 1024).ceil()} KB';
    }
    final mb = bytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} GB';
    }
    return '${mb.toStringAsFixed(1)} MB';
  }

  void _update(AppSettings next) {
    widget.onSettingsChanged(next);
  }

  void _focusRightPaneFirstControl() {
    final first = _rightPaneContainerFocusNode.traversalDescendants
        .where((n) => n.canRequestFocus && n != _rightPaneContainerFocusNode)
        .firstOrNull;
    if (first != null) {
      first.requestFocus();
      final ctx = first.context;
      if (ctx != null) {
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.2,
            duration: const Duration(milliseconds: 140),
          ),
        );
      }
    }
  }

  KeyEventResult _handleScreenKeyEvent(FocusNode node, KeyEvent event) {
    if (!widget.isActive) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (_screenFocusNode.hasPrimaryFocus &&
        (key == LogicalKeyboardKey.arrowDown ||
            key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      if (HydraTokens.isWideLayout(context)) {
        _categoryFocusNodes[_selectedCategory].requestFocus();
      } else {
        _screenFocusNode.nextFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final isLandscape = HydraTokens.isWideLayout(context);
    final s = widget.settings;

    return Focus(
      focusNode: _screenFocusNode,
      autofocus: widget.isActive,
      canRequestFocus: widget.isActive,
      descendantsAreFocusable: widget.isActive,
      onKeyEvent: _handleScreenKeyEvent,
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
        },
        child: Scaffold(
          backgroundColor: HydraTokens.bgPureBlack,
          body: SafeArea(
            top: false,
            child: isLandscape
                ? _buildLandscapeSplitSettings(s)
                : _buildPortraitSettings(s),
          ),
        ),
      ),
    );
  }

  // ==========================================================================
  // MODO DEITADO (LANDSCAPE): PAINEL DIVIDIDO ESTILO CONSOLE GAMEHUB / PS5
  // ==========================================================================
  Widget _buildLandscapeSplitSettings(AppSettings s) {
    return Row(
      children: [
        Container(
          width: 244,
          decoration: const BoxDecoration(
            color: HydraTokens.bgNearBlack,
            border: Border(
              right: BorderSide(color: HydraTokens.borderSubtle8),
            ),
          ),
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + 58,
            16,
            16,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Configurações',
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
                    const SizedBox(width: 4),
                    _HelpTriggerButton(
                      compact: true,
                      onPressed: () => _showHelpGuide(context),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: FocusTraversalGroup(
                  child: ListView.separated(
                    itemCount: _categories.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, idx) {
                      final cat = _categories[idx];
                      final active = _selectedCategory == idx;
                      final focused = _focusedCategoryIndex == idx;
                      return Semantics(
                        button: true,
                        selected: active,
                        label: '${cat.title}. ${cat.subtitle}',
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Material(
                            color: Colors.transparent,
                            child: Focus(
                              canRequestFocus: false,
                              skipTraversal: true,
                              onKeyEvent: (node, event) {
                                if (event is! KeyDownEvent &&
                                    event is! KeyRepeatEvent) {
                                  return KeyEventResult.ignored;
                                }
                                final key = event.logicalKey;
                                if (key == LogicalKeyboardKey.arrowUp) {
                                  if (idx > 0) {
                                    setState(
                                      () => _selectedCategory = idx - 1,
                                    );
                                    _categoryFocusNodes[idx - 1].requestFocus();
                                  }
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.arrowDown) {
                                  if (idx < _categories.length - 1) {
                                    setState(
                                      () => _selectedCategory = idx + 1,
                                    );
                                    _categoryFocusNodes[idx + 1].requestFocus();
                                  }
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.arrowRight) {
                                  _focusRightPaneFirstControl();
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: InkWell(
                                focusNode: _categoryFocusNodes[idx],
                                borderRadius: BorderRadius.circular(12),
                                onFocusChange: (hasFocus) {
                                  if (hasFocus) {
                                    if (_focusedCategoryIndex != idx ||
                                        _selectedCategory != idx) {
                                      setState(() {
                                        _focusedCategoryIndex = idx;
                                        _selectedCategory = idx;
                                      });
                                    }
                                  } else if (_focusedCategoryIndex == idx) {
                                    setState(() => _focusedCategoryIndex = -1);
                                  }
                                },
                                onTap: () {
                                  setState(() => _selectedCategory = idx);
                                  _categoryFocusNodes[idx].requestFocus();
                                },
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 160),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 11,
                                  ),
                                  decoration: BoxDecoration(
                                    color: active
                                        ? Colors.white.withOpacity(0.12)
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(12),
                                    border: Border.all(
                                      color: focused
                                          ? HydraTokens.primaryAurora
                                          : (active
                                              ? Colors.white.withOpacity(0.35)
                                              : Colors.transparent),
                                      width: focused ? 2.0 : 1.0,
                                    ),
                                    boxShadow: focused
                                        ? HydraTokens.neonBoxGlow(
                                            opacity: 0.24,
                                            blur: 10,
                                            color: HydraTokens.primaryAurora,
                                          )
                                        : null,
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        cat.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 13,
                                          fontWeight: active
                                              ? FontWeight.w700
                                              : FontWeight.w500,
                                          color: active
                                              ? HydraTokens.textPrimary
                                              : HydraTokens.textSecondary,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        cat.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontFamily: 'Rubik',
                                          fontSize: 10.5,
                                          color: HydraTokens.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: HydraTokens.surfaceCatalog,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'Total do App',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 11.5,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatStorage(_storageBreakdown.totalAppBytes),
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: HydraTokens.primaryAurora,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'ROMs instaladas',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 10.5,
                              color: HydraTokens.textMuted,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _formatStorage(_storageBreakdown.readyRomsBytes),
                          style: const TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textSecondary,
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
        Expanded(
          child: Focus(
            focusNode: _rightPaneContainerFocusNode,
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: (node, event) {
              if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                return KeyEventResult.ignored;
              }
              final key = event.logicalKey;
              if (key == LogicalKeyboardKey.gameButtonB) {
                _categoryFocusNodes[_selectedCategory].requestFocus();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowLeft) {
                final primary = FocusManager.instance.primaryFocus;
                final rect = primary?.rect;
                if (rect != null) {
                  final hasLeftInPane = _rightPaneContainerFocusNode
                      .traversalDescendants
                      .any((n) {
                    if (n == primary || !n.canRequestFocus) return false;
                    final r = n.rect;
                    final verticalOverlap =
                        r.bottom > rect.top + 4 && r.top < rect.bottom - 4;
                    return verticalOverlap && r.right <= rect.left + 8;
                  });
                  if (!hasLeftInPane) {
                    _categoryFocusNodes[_selectedCategory].requestFocus();
                    return KeyEventResult.handled;
                  }
                }
              }
              return KeyEventResult.ignored;
            },
            child: FocusTraversalGroup(
              child: ListView(
                controller: _landscapeScrollController,
                cacheExtent: 800,
                padding: EdgeInsets.fromLTRB(
                  24,
                  MediaQuery.paddingOf(context).top + 58,
                  24,
                  28,
                ),
                children: [
                  if (_selectedCategory == 0) _buildHudTelemetrySection(s),
                  if (_selectedCategory == 1) _buildGamepadSection(s),
                  if (_selectedCategory == 2) _buildSavesAndStorageSection(s),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==========================================================================
  // MODO EM PÉ (PORTRAIT): SEÇÕES ORGANIZADAS ESTILO GAMEHUB OS
  // ==========================================================================
  Widget _buildPortraitSettings(AppSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: EdgeInsets.fromLTRB(
            20,
            MediaQuery.paddingOf(context).top + 14,
            16,
            12,
          ),
          decoration: const BoxDecoration(
            gradient: HydraTokens.heroBackgroundGradient,
            border: Border(
              bottom: BorderSide(color: HydraTokens.borderSubtle8),
            ),
          ),
          child: Row(
            children: [
              const Expanded(
                child: Text(
                  'Configurações',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: HydraTokens.textPrimary,
                  ),
                ),
              ),
              _HelpTriggerButton(
                compact: false,
                onPressed: () => _showHelpGuide(context),
              ),
              const SizedBox(width: 8),
              Semantics(
                label:
                    'Total usado pelo app: ${_formatStorage(_storageBreakdown.totalAppBytes)}',
                child: Tooltip(
                  message: 'Total usado pelo app',
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: HydraTokens.bgNearBlack,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: HydraTokens.borderSubtle10),
                    ),
                    child: Text(
                      'Total ${_formatStorage(_storageBreakdown.totalAppBytes)}',
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: HydraTokens.primaryAurora,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: FocusTraversalGroup(
            child: ListView(
              controller: _portraitScrollController,
              cacheExtent: 1200,
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 34),
              children: [
                _buildHudTelemetrySection(s),
                const SizedBox(height: 22),
                _buildGamepadSection(s),
                const SizedBox(height: 22),
                _buildSavesAndStorageSection(s),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHudTelemetrySection(AppSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'Informações na Tela (HUD / Telemetria)',
          subtitle:
              'Escolha exatamente quais informações aparecem durante o jogo',
        ),
        const SizedBox(height: 10),
        _SettingsSurfaceCard(
          child: LoopHudToggleGroup(
            settings: s,
            onChanged: _update,
          ),
        ),
      ],
    );
  }

  Widget _buildGamepadSection(AppSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'Gamepad Touch & Controles Físicos',
          subtitle: 'Configure o comportamento do overlay e vibração ao tocar',
        ),
        const SizedBox(height: 10),
        _SettingsSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Visibilidade do Controle na Tela',
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: HydraTokens.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.touchOverlayMode.description,
                style: const TextStyle(
                  fontFamily: 'Rubik',
                  fontSize: 12,
                  color: HydraTokens.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              _SettingsSelectMenu<TouchOverlayMode>(
                value: s.touchOverlayMode,
                items: TouchOverlayMode.values,
                labelOf: (mode) => mode.label,
                descriptionOf: (mode) => mode.description,
                onChanged: (mode) =>
                    _update(s.copyWith(touchOverlayMode: mode)),
              ),
              const SizedBox(height: 14),
              const Divider(color: HydraTokens.borderSubtle8, height: 1),
              const SizedBox(height: 12),
              _SettingsSwitchTile(
                title: 'Vibração Tátil nos Botões',
                subtitle: 'Resposta háptica ao pressionar comandos na tela',
                value: s.hapticVibration,
                onChanged: (v) => _update(s.copyWith(hapticVibration: v)),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: Row(
                  children: [
                    PhosphorIcon(
                      PhosphorIcons.handTap(PhosphorIconsStyle.bold),
                      size: 18,
                      color: HydraTokens.textPrimary,
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Dica: Durante qualquer partida, abra a Sidebar (botão Voltar) e toque em "Mover e Editar Botões na Tela". Consoles como PSP (God of War), GBA e SNES adaptam automaticamente os gatilhos para apenas L e R.',
                        style: TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11.5,
                          height: 1.4,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSavesAndStorageSection(AppSettings s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'Save States (PPSSPP) e Armazenamento',
          subtitle: 'Gerencie salvamento manual de onde parou e espaço de ROMs',
        ),
        const SizedBox(height: 10),
        _SettingsSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SettingsSwitchTile(
                title: 'Salvar Automaticamente ao Sair (Opcional)',
                subtitle:
                    'Desativado por padrão: só salva quando você clicar em Salvar na Sidebar do jogo (ideal para jogos de luta)',
                value: s.autoSaveOnExit,
                onChanged: (v) => _update(s.copyWith(autoSaveOnExit: v)),
              ),
              _SettingsSwitchTile(
                title: 'Carregar Último Save ao Abrir (Opcional)',
                subtitle:
                    'Desativado por padrão para arcade e lutas iniciarem do início normalmente',
                value: s.autoLoadOnStart,
                onChanged: (v) => _update(s.copyWith(autoLoadOnStart: v)),
              ),
              const Divider(color: HydraTokens.borderSubtle8, height: 18),
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.hardDrive(PhosphorIconsStyle.regular),
                    size: 18,
                    color: HydraTokens.textPrimary,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Total usado pelo app',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatStorage(_storageBreakdown.totalAppBytes),
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 13.5,
                      fontWeight: FontWeight.w700,
                      color: HydraTokens.primaryAurora,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Semantics(
                    button: true,
                    label: 'Recalcular armazenamento do aplicativo',
                    child: Tooltip(
                      message: 'Recalcular armazenamento',
                      child: IconButton(
                        onPressed: () => unawaited(_refreshAllDiskState()),
                        constraints: const BoxConstraints(
                          minWidth: 48,
                          minHeight: 48,
                        ),
                        icon: PhosphorIcon(
                          PhosphorIcons.arrowsClockwise(
                            PhosphorIconsStyle.bold,
                          ),
                          size: 17,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Espaço Ocupado pelas ROMs',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatStorage(_storageBreakdown.readyRomsBytes),
                    style: const TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: HydraTokens.textPrimary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: HydraTokens.surfaceCatalog,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: HydraTokens.borderSubtle8),
                ),
                child: Column(
                  children: [
                    _StorageBreakdownRow(
                      label: 'ROMs instaladas',
                      value: _formatStorage(_storageBreakdown.readyRomsBytes),
                    ),
                    const SizedBox(height: 8),
                    _StorageBreakdownRow(
                      label: _storageBreakdown.orphanPartCount > 0
                          ? 'Downloads incompletos (.part · ${_storageBreakdown.orphanPartCount})'
                          : 'Downloads incompletos (.part)',
                      value: _formatStorage(
                        _storageBreakdown.partialDownloadsBytes,
                      ),
                      highlight: _storageBreakdown.partialDownloadsBytes > 0,
                    ),
                    const SizedBox(height: 8),
                    _StorageBreakdownRow(
                      label: 'Sistema, Cores, Firmware & Drivers',
                      subtitle: _storageBreakdown.ps3FirmwareBytes > 0
                          ? 'Inclui PS3UPDAT.PUP / flash (${_formatStorage(_storageBreakdown.ps3FirmwareBytes)})'
                          : null,
                      value: _formatStorage(
                        _storageBreakdown.systemAndCoresBytes +
                            _storageBreakdown.ps3FirmwareBytes,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _StorageBreakdownRow(
                      label: 'Saves & Capas',
                      subtitle: (_storageBreakdown.savesBytes > 0 ||
                              _storageBreakdown.coversBytes > 0)
                          ? 'Saves: ${_formatStorage(_storageBreakdown.savesBytes)} • Capas: ${_formatStorage(_storageBreakdown.coversBytes)}'
                          : null,
                      value: _formatStorage(
                        _storageBreakdown.savesAndCoversBytes,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _StorageBreakdownRow(
                      label: 'Cache temporário',
                      value: _formatStorage(_storageBreakdown.tempCacheBytes),
                      highlight: _storageBreakdown.tempCacheBytes > 0,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_isCleaningStorage ||
                          _isCleaningSavesAndCovers ||
                          _importingPs3Firmware ||
                          _removingPs3Firmware)
                      ? null
                      : () => unawaited(_handleCleanStorage()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HydraTokens.primaryAurora,
                    minimumSize: const Size(48, 48),
                    side: const BorderSide(color: HydraTokens.borderSubtle10),
                  ),
                  icon: _isCleaningStorage
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: HydraTokens.primaryAurora,
                          ),
                        )
                      : PhosphorIcon(
                          PhosphorIcons.broom(PhosphorIconsStyle.bold),
                          size: 17,
                        ),
                  label: Text(
                    _isCleaningStorage
                        ? 'Limpando cache...'
                        : _storageBreakdown.tempCacheBytes > 0
                            ? 'Limpar cache e .part (${_formatStorage(_storageBreakdown.tempCacheBytes)})'
                            : 'Limpar cache e .part',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: (_isCleaningStorage ||
                          _isCleaningSavesAndCovers ||
                          _importingPs3Firmware ||
                          _removingPs3Firmware)
                      ? null
                      : () => unawaited(_handleCleanSavesAndCovers()),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: HydraTokens.textPrimary,
                    minimumSize: const Size(48, 48),
                    side: const BorderSide(color: HydraTokens.borderSubtle10),
                  ),
                  icon: _isCleaningSavesAndCovers
                      ? const SizedBox(
                          width: 15,
                          height: 15,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: HydraTokens.primaryAurora,
                          ),
                        )
                      : PhosphorIcon(
                          PhosphorIcons.trash(PhosphorIconsStyle.bold),
                          size: 17,
                        ),
                  label: Text(
                    _isCleaningSavesAndCovers
                        ? 'Limpando capas e saves...'
                        : _storageBreakdown.savesAndCoversBytes > 0
                            ? 'Limpar capas e saves (${_formatStorage(_storageBreakdown.savesAndCoversBytes)})'
                            : 'Limpar capas e saves',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionHeader(
          title: 'Drivers, Firmware & Adreno Turnip',
          subtitle:
              'Driver Vulkan Turnip (AdrenoTools), Freedreno (TU_DEBUG) e Firmware PS3',
        ),
        const SizedBox(height: 10),
        _SettingsSurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.graphicsCard(PhosphorIconsStyle.regular),
                    size: 18,
                    color: HydraTokens.textPrimary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Driver Vulkan Customizado (Turnip)',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.customVulkanDriverLabel.trim().isEmpty
                              ? 'Padrão do Sistema (GPU Nativa)'
                              : s.customVulkanDriverLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 11.5,
                            color: s.customVulkanDriverLabel.trim().isEmpty
                                ? HydraTokens.textSecondary
                                : HydraTokens.primaryAurora,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => unawaited(_openGpuDriverManagerModal(s)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HydraTokens.primaryAurora,
                      minimumSize: const Size(48, 48),
                      side: const BorderSide(color: HydraTokens.borderSubtle10),
                    ),
                    child: const Text('Gerenciar'),
                  ),
                ],
              ),
              const Divider(color: HydraTokens.borderSubtle8, height: 22),
              _SettingsSwitchTile(
                title: 'Adreno Turbo Clock (AdrenoTools)',
                subtitle:
                    'Força perfil máximo de GPU em chips Qualcomm Adreno usando Vulkan',
                value: s.adrenoTurboMode,
                onChanged: (v) => _update(s.copyWith(adrenoTurboMode: v)),
              ),
              const Divider(color: HydraTokens.borderSubtle8, height: 22),
              const Text(
                'Perfil Freedreno / Turnip (TU_DEBUG)',
                style: TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: HydraTokens.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                s.freedrenoPreset.description,
                style: const TextStyle(
                  fontFamily: 'Rubik',
                  fontSize: 11.5,
                  color: HydraTokens.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              _SettingsSelectMenu<TurnipFreedrenoPreset>(
                value: s.freedrenoPreset,
                items: TurnipFreedrenoPreset.values,
                labelOf: (preset) => preset.label,
                descriptionOf: (preset) => preset.description,
                onChanged: (preset) =>
                    _update(s.copyWith(freedrenoPreset: preset)),
              ),
              const Divider(color: HydraTokens.borderSubtle8, height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PhosphorIcon(
                    PhosphorIcons.cpu(PhosphorIconsStyle.regular),
                    size: 18,
                    color: HydraTokens.textPrimary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Firmware PS3 (PS3UPDAT.PUP)',
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _hasPs3Firmware
                              ? (_storageBreakdown.ps3FirmwareBytes > 0
                                  ? 'Instalado (${_formatStorage(_storageBreakdown.ps3FirmwareBytes)}) — pronto para RPCS3 (Vulkan)'
                                  : 'Instalado — pronto para RPCS3 (Vulkan)')
                              : 'Pendente — importe o PS3UPDAT.PUP para abrir jogos de PS3',
                          style: TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 11.5,
                            color: _hasPs3Firmware
                                ? HydraTokens.primaryAurora
                                : HydraTokens.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            OutlinedButton(
                              onPressed: (_importingPs3Firmware ||
                                      _removingPs3Firmware ||
                                      _isCleaningStorage)
                                  ? null
                                  : () => unawaited(_handleImportPs3Firmware()),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: HydraTokens.primaryAurora,
                                minimumSize: const Size(48, 48),
                                side: const BorderSide(
                                  color: HydraTokens.borderSubtle10,
                                ),
                              ),
                              child: Text(
                                _importingPs3Firmware
                                    ? 'Importando...'
                                    : (_hasPs3Firmware
                                        ? 'Atualizar'
                                        : 'Importar PUP'),
                              ),
                            ),
                            if (_hasPs3Firmware)
                              OutlinedButton.icon(
                                onPressed: (_importingPs3Firmware ||
                                        _removingPs3Firmware ||
                                        _isCleaningStorage)
                                    ? null
                                    : () =>
                                        unawaited(_handleRemovePs3Firmware()),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: HydraTokens.accentDanger,
                                  minimumSize: const Size(48, 48),
                                  side: BorderSide(
                                    color: HydraTokens.accentDanger
                                        .withOpacity(0.55),
                                  ),
                                ),
                                icon: PhosphorIcon(
                                  PhosphorIcons.trash(PhosphorIconsStyle.bold),
                                  size: 16,
                                  color: HydraTokens.accentDanger,
                                ),
                                label: Text(
                                  _removingPs3Firmware
                                      ? 'Removendo...'
                                      : 'Remover',
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        const _SectionHeader(
          title: 'Servidor RomM Privado',
          subtitle: 'Integre sua biblioteca privada RomM (opcional)',
        ),
        const SizedBox(height: 10),
        _SettingsSurfaceCard(
          child: Row(
            children: [
              PhosphorIcon(
                PhosphorIcons.cloudArrowDown(PhosphorIconsStyle.regular),
                size: 18,
                color: HydraTokens.textPrimary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'URL e Token do Servidor',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      s.rommServerUrl.trim().isEmpty
                          ? 'Não configurado (usando RetroAPI & Archive.org)'
                          : s.rommServerUrl.trim(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: () => unawaited(_showRommConfigDialog(s)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: HydraTokens.primaryAurora,
                  minimumSize: const Size(48, 48),
                  side: const BorderSide(color: HydraTokens.borderSubtle10),
                ),
                child: Text(
                  s.rommServerUrl.trim().isEmpty ? 'Configurar' : 'Editar',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _showHelpGuide(BuildContext context) {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) {
          return Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.gameButtonB ||
                      event.logicalKey == LogicalKeyboardKey.escape)) {
                Navigator.of(ctx).pop();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: SafeArea(
              top: false,
              child: FractionallySizedBox(
                heightFactor: 0.88,
                child: Container(
                  decoration: const BoxDecoration(
                    color: HydraTokens.bgNearBlack,
                    borderRadius:
                        BorderRadius.vertical(top: Radius.circular(24)),
                    border: Border(
                      top: BorderSide(
                        color: HydraTokens.borderSubtle10,
                        width: 1.5,
                      ),
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.25),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          PhosphorIcon(
                            PhosphorIcons.question(PhosphorIconsStyle.bold),
                            size: 20,
                            color: HydraTokens.textPrimary,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Guia e Ajuda do LoopGamer',
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
                          Tooltip(
                            message: 'Fechar guia',
                            child: IconButton(
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                              icon: const Icon(
                                Icons.close,
                                color: HydraTokens.textSecondary,
                              ),
                              onPressed: () => Navigator.of(ctx).pop(),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: ListView(
                          children: [
                            _HelpGuideItem(
                              icon:
                                  PhosphorIcons.gauge(PhosphorIconsStyle.bold),
                              title: 'HUD e Informações na Tela',
                              description:
                                  'Mostra dados em tempo real da emulação:\n'
                                  '• FPS: Quantos quadros por segundo o jogo está rodando (o padrão ideal é 60 FPS).\n'
                                  '• ms: Tempo de resposta de cada quadro (quanto menor, mais rápido o jogo responde).\n'
                                  '• Escala e Console: Qual resolução interna e nome do console em execução.\n'
                                  'Você pode ativar ou desativar cada item nas configurações ou tocando no HUD durante o modo de edição na tela.',
                            ),
                            const SizedBox(height: 12),
                            _HelpGuideItem(
                              icon: PhosphorIcons.gameController(
                                PhosphorIconsStyle.bold,
                              ),
                              title: 'Gamepad na Tela e Controles Físicos',
                              description:
                                  '• Botão Xbox / Logo (Mode): abre as Configurações (ou Menu Rápido durante a partida).\n'
                                  '• LB / RB (ou L2 / R2): alterna entre as seções do app (Início, ROMs, Biblioteca, Ajustes).\n'
                                  '• SELECT (segurar 0.3s): ativa/mantém Turbo / Fast-Forward 2x (funciona no controle físico e na tela!).\n'
                                  '• Mover e Customizar Botões: Durante a partida, abra a Sidebar (botão Voltar do celular ou Botão Xbox / Mode) e clique em "Mover e Editar Botões". Arraste os botões para onde preferir e dê um toque em qualquer um deles (L1, R2, D-Pad, Ações) para mudar tamanho, opacidade e estilo com prévia ao vivo!\n'
                                  '• Controles Físicos (USB/Bluetooth): Se conectar um joystick no celular, o app oculta os botões táteis automaticamente para liberar a visão da tela.',
                            ),
                            const SizedBox(height: 12),
                            _HelpGuideItem(
                              icon: PhosphorIcons.fastForward(
                                PhosphorIconsStyle.bold,
                              ),
                              title: 'Turbo / Avanço Rápido (Fast-Forward 2x)',
                              description:
                                  'Quer adiantar um diálogo ou parte demorada do jogo? Use SELECT (segurar 0.3s): ativa/mantém Turbo / Fast-Forward 2x (funciona no controle físico e na tela!). Solte para voltar à velocidade normal.',
                            ),
                            const SizedBox(height: 12),
                            _HelpGuideItem(
                              icon: PhosphorIcons.floppyDisk(
                                PhosphorIconsStyle.bold,
                              ),
                              title: 'Saves Estilo PPSSPP (Onde Parou)',
                              description:
                                  'O jogo NÃO salva sozinho sem sua autorização (ideal para jogos de luta e arcade). Quando quiser salvar, abra a Sidebar, escolha um dos slots e clique em "Salvar". Ele gera uma foto do exato instante onde você parou com data e hora para você carregar quando quiser.',
                            ),
                            const SizedBox(height: 12),
                            _HelpGuideItem(
                              icon: PhosphorIcons.downloadSimple(
                                PhosphorIconsStyle.bold,
                              ),
                              title: 'Downloads Resilientes em 2º Plano',
                              description:
                                  'Seus downloads continuam em segundo plano mesmo navegando pelo app. Se a conexão cair ou você quiser pausar, pode retomar mais tarde sem perder nenhum megabyte já baixado.',
                            ),
                            const SizedBox(height: 12),
                            _HelpGuideItem(
                              icon: PhosphorIcons.star(PhosphorIconsStyle.bold),
                              title: 'Favoritos e Coleções',
                              description:
                                  'Toque na estrela para favoritar seus jogos preferidos e crie coleções customizadas (ex.: Luta, RPG, Favoritos) para organizar sua biblioteca como preferir.',
                            ),
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
    );
  }
}

class _HelpTriggerButton extends StatefulWidget {
  const _HelpTriggerButton({
    required this.compact,
    required this.onPressed,
  });

  final bool compact;
  final VoidCallback onPressed;

  @override
  State<_HelpTriggerButton> createState() => _HelpTriggerButtonState();
}

class _HelpTriggerButtonState extends State<_HelpTriggerButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Abrir guia e ajuda do LoopGamer',
      child: Tooltip(
        message: 'Guia e ajuda',
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onFocusChange: (hasFocus) {
                if (_focused != hasFocus) {
                  setState(() => _focused = hasFocus);
                }
              },
              onTap: widget.onPressed,
              child: Center(
                widthFactor: 1.0,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.compact ? 8 : 11,
                    vertical: widget.compact ? 8 : 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.10),
                    borderRadius: BorderRadius.circular(
                      widget.compact ? 10 : 16,
                    ),
                    border: Border.all(
                      color: _focused
                          ? HydraTokens.primaryAurora
                          : Colors.white.withOpacity(0.20),
                      width: _focused ? 2.0 : 1.0,
                    ),
                  ),
                  child: widget.compact
                      ? PhosphorIcon(
                          PhosphorIcons.question(PhosphorIconsStyle.bold),
                          size: 16,
                          color: HydraTokens.textPrimary,
                        )
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.question(PhosphorIconsStyle.bold),
                              size: 14,
                              color: HydraTokens.textPrimary,
                            ),
                            const SizedBox(width: 5),
                            const Text(
                              'Ajuda',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 11.5,
                                fontWeight: FontWeight.w700,
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
      ),
    );
  }
}

class _StorageBreakdownRow extends StatelessWidget {
  const _StorageBreakdownRow({
    required this.label,
    required this.value,
    this.subtitle,
    this.highlight = false,
  });

  final String label;
  final String value;
  final String? subtitle;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Rubik',
                  fontSize: 12,
                  color: HydraTokens.textSecondary,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'Rubik',
                    fontSize: 11,
                    color: HydraTokens.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(
          value,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color:
                highlight ? HydraTokens.accentAmber : HydraTokens.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _HelpGuideItem extends StatelessWidget {
  const _HelpGuideItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  final PhosphorIconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: HydraTokens.surfaceCatalog,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: HydraTokens.borderSubtle8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              PhosphorIcon(icon, size: 16, color: HydraTokens.textPrimary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: HydraTokens.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontFamily: 'Rubik',
              fontSize: 12,
              height: 1.45,
              color: HydraTokens.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.title,
    required this.subtitle,
  });

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontFamily: 'ReadexPro',
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: HydraTokens.textPrimary,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: const TextStyle(
            fontFamily: 'Rubik',
            fontSize: 12,
            color: HydraTokens.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _SettingsSelectMenu<T> extends StatefulWidget {
  const _SettingsSelectMenu({
    required this.value,
    required this.items,
    required this.labelOf,
    this.descriptionOf,
    required this.onChanged,
  });

  final T value;
  final List<T> items;
  final String Function(T) labelOf;
  final String Function(T)? descriptionOf;
  final ValueChanged<T> onChanged;

  @override
  State<_SettingsSelectMenu<T>> createState() => _SettingsSelectMenuState<T>();
}

class _SettingsSelectMenuState<T> extends State<_SettingsSelectMenu<T>> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (hasFocus) {
        if (_focused != hasFocus) {
          setState(() => _focused = hasFocus);
        }
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: HydraTokens.surfaceCatalog,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _focused
                  ? HydraTokens.primaryAurora
                  : HydraTokens.borderSubtle10,
              width: _focused ? 1.8 : 1.0,
            ),
            boxShadow: _focused
                ? HydraTokens.neonBoxGlow(
                    opacity: 0.20,
                    blur: 10,
                    color: HydraTokens.primaryAurora,
                  )
                : null,
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: widget.value,
              isExpanded: true,
              itemHeight: null,
              dropdownColor: HydraTokens.surfaceElevated1,
              borderRadius: BorderRadius.circular(12),
              icon: PhosphorIcon(
                PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
                size: 16,
                color: HydraTokens.primaryAurora,
              ),
              selectedItemBuilder: (context) => widget.items.map((item) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.labelOf(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: HydraTokens.textPrimary,
                    ),
                  ),
                );
              }).toList(),
              items: widget.items.map((item) {
                final selected = item == widget.value;
                final desc = widget.descriptionOf?.call(item);
                return DropdownMenuItem<T>(
                  value: item,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.labelOf(item),
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? HydraTokens.primaryAurora
                                : HydraTokens.textPrimary,
                          ),
                        ),
                        if (desc != null && desc.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            desc,
                            style: const TextStyle(
                              fontFamily: 'Rubik',
                              fontSize: 11,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
              onChanged: (next) {
                if (next != null) widget.onChanged(next);
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSurfaceCard extends StatelessWidget {
  const _SettingsSurfaceCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: HydraTokens.bgNearBlack,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: HydraTokens.borderSubtle8),
      ),
      child: child,
    );
  }
}

class _SettingsSwitchTile extends StatefulWidget {
  const _SettingsSwitchTile({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  State<_SettingsSwitchTile> createState() => _SettingsSwitchTileState();
}

class _SettingsSwitchTileState extends State<_SettingsSwitchTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onChanged != null;
    return Semantics(
      toggled: widget.value,
      enabled: enabled,
      label: widget.title,
      hint: widget.subtitle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onFocusChange: (hasFocus) {
              if (_focused != hasFocus) {
                setState(() => _focused = hasFocus);
              }
            },
            onTap: enabled ? () => widget.onChanged!(!widget.value) : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              decoration: BoxDecoration(
                color: _focused
                    ? Colors.white.withOpacity(0.06)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      _focused ? HydraTokens.primaryAurora : Colors.transparent,
                  width: _focused ? 1.5 : 1.0,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 11.5,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ExcludeFocus(
                    child: Switch(
                      value: widget.value,
                      activeColor: HydraTokens.bgPureBlack,
                      activeTrackColor: HydraTokens.primaryAurora,
                      onChanged: widget.onChanged,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GpuDriverManagerSheet extends StatefulWidget {
  const _GpuDriverManagerSheet({
    required this.gpuDriverService,
    required this.activeDriverDir,
    required this.activeDriverName,
    required this.onDriverSelected,
    this.onDriversChanged,
  });

  final GpuDriverService gpuDriverService;
  final String activeDriverDir;
  final String activeDriverName;
  final ValueChanged<InstalledGpuDriver?> onDriverSelected;
  final VoidCallback? onDriversChanged;

  @override
  State<_GpuDriverManagerSheet> createState() => _GpuDriverManagerSheetState();
}

class _GpuDriverManagerSheetState extends State<_GpuDriverManagerSheet> {
  List<InstalledGpuDriver> _installed = const [];
  List<TurnipDriverRelease> _releases = const [];
  bool _loadingInstalled = true;
  bool _loadingReleases = true;
  bool _importingZip = false;
  String? _downloadingUrl;
  double _downloadProgress = 0;
  String? _statusMessage;
  late String _selectedDir = widget.activeDriverDir;
  late String _selectedName = widget.activeDriverName;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalled());
    unawaited(_loadReleases());
  }

  Future<void> _loadInstalled() async {
    setState(() => _loadingInstalled = true);
    try {
      final list = await widget.gpuDriverService.listInstalledDrivers();
      if (mounted) {
        setState(() {
          _installed = list;
          _loadingInstalled = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingInstalled = false;
          _statusMessage = 'Erro ao ler drivers locais: $e';
        });
      }
    }
  }

  Future<void> _loadReleases() async {
    setState(() => _loadingReleases = true);
    try {
      final list = await widget.gpuDriverService.fetchAvailableDrivers();
      if (mounted) {
        setState(() {
          _releases = list;
          _loadingReleases = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _loadingReleases = false);
      }
    }
  }

  void _applyDriver(InstalledGpuDriver? driver) {
    setState(() {
      _selectedDir = driver?.directoryPath ?? '';
      _selectedName = driver?.libraryName ?? '';
    });
    widget.onDriverSelected(driver);
  }

  Future<void> _importZip() async {
    if (_importingZip) return;
    setState(() {
      _importingZip = true;
      _statusMessage = null;
    });
    try {
      final driver = await widget.gpuDriverService.importLocalDriverZip();
      if (!mounted) return;
      if (driver != null) {
        await _loadInstalled();
        if (!mounted) return;
        _applyDriver(driver);
        widget.onDriversChanged?.call();
        setState(
          () => _statusMessage = 'Driver "${driver.name}" importado e ativado.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _statusMessage = e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _importingZip = false);
      }
    }
  }

  Future<void> _downloadRelease(TurnipDriverRelease release) async {
    if (_downloadingUrl != null) return;
    setState(() {
      _downloadingUrl = release.downloadUrl;
      _downloadProgress = 0;
      _statusMessage = null;
    });
    try {
      final driver = await widget.gpuDriverService.downloadAndInstallDriver(
        release,
        onProgress: (p) {
          if (mounted) setState(() => _downloadProgress = p);
        },
      );
      if (!mounted) return;
      await _loadInstalled();
      if (!mounted) return;
      _applyDriver(driver);
      widget.onDriversChanged?.call();
      setState(
        () => _statusMessage = 'Driver "${driver.name}" baixado e ativado!',
      );
    } catch (e) {
      if (mounted) {
        setState(() => _statusMessage = 'Falha no download do driver: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingUrl = null;
          _downloadProgress = 0;
        });
      }
    }
  }

  Future<void> _deleteInstalled(InstalledGpuDriver driver) async {
    await widget.gpuDriverService.deleteDriver(driver.id);
    if (!mounted) return;
    if (_selectedDir == driver.directoryPath &&
        _selectedName == driver.libraryName) {
      _applyDriver(null);
    }
    widget.onDriversChanged?.call();
    await _loadInstalled();
  }

  @override
  Widget build(BuildContext context) {
    final isDefault = _selectedDir.isEmpty || _selectedName.isEmpty;

    return SafeArea(
      top: false,
      child: FractionallySizedBox(
        heightFactor: 0.88,
        child: Container(
          decoration: const BoxDecoration(
            color: HydraTokens.bgNearBlack,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
            border: Border(
              top: BorderSide(color: HydraTokens.borderSubtle10, width: 1.5),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  PhosphorIcon(
                    PhosphorIcons.cpu(PhosphorIconsStyle.bold),
                    size: 20,
                    color: HydraTokens.primaryAurora,
                  ),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Gerenciador de Drivers Vulkan (Turnip)',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Fechar gerenciador',
                    child: IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      icon: const Icon(
                        Icons.close,
                        color: HydraTokens.textSecondary,
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                ],
              ),
              const Text(
                'Drivers Mesa Turnip via AdrenoTools (ARM64 rootless). Aplicado automaticamente na próxima sessão Vulkan.',
                style: TextStyle(
                  fontFamily: 'Rubik',
                  fontSize: 11.5,
                  color: HydraTokens.textSecondary,
                ),
              ),
              if (_statusMessage != null) ...[
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: HydraTokens.surfaceCatalog,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: HydraTokens.borderSubtle10),
                  ),
                  child: Text(
                    _statusMessage!,
                    style: const TextStyle(
                      fontFamily: 'Rubik',
                      fontSize: 11.5,
                      color: HydraTokens.primaryAurora,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _importingZip ? null : () => unawaited(_importZip()),
                      icon: const Icon(Icons.folder_zip_outlined, size: 17),
                      label: Text(
                        _importingZip ? 'Importando...' : 'Importar .ZIP Local',
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: HydraTokens.primaryAurora,
                        minimumSize: const Size(48, 48),
                        side: const BorderSide(
                          color: HydraTokens.borderSubtle10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: isDefault ? null : () => _applyDriver(null),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: HydraTokens.textPrimary,
                      minimumSize: const Size(48, 48),
                      side: const BorderSide(color: HydraTokens.borderSubtle10),
                    ),
                    child: Text(isDefault ? 'Padrão Ativo' : 'Usar Padrão'),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView(
                  children: [
                    const Text(
                      'DRIVERS INSTALADOS',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.7,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (_loadingInstalled)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_installed.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Nenhum driver customizado instalado. Baixe abaixo ou importe um .zip.',
                          style: TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 12,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      )
                    else
                      ..._installed.map((driver) {
                        final active = _selectedDir == driver.directoryPath &&
                            _selectedName == driver.libraryName;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: HydraTokens.surfaceCatalog,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: active
                                  ? HydraTokens.primaryAurora
                                  : HydraTokens.borderSubtle8,
                            ),
                          ),
                          child: ListTile(
                            minTileHeight: 48,
                            onTap: () => _applyDriver(driver),
                            leading: Icon(
                              active
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: active
                                  ? HydraTokens.primaryAurora
                                  : HydraTokens.textSecondary,
                              size: 20,
                            ),
                            title: Text(
                              '${driver.name} (${driver.driverVersion})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: HydraTokens.textPrimary,
                              ),
                            ),
                            subtitle: Text(
                              driver.libraryName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 10.5,
                                color: HydraTokens.textSecondary,
                              ),
                            ),
                            trailing: Tooltip(
                              message: 'Remover driver',
                              child: IconButton(
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                tooltip: 'Remover driver',
                                icon: const Icon(
                                  Icons.delete_outline,
                                  color: HydraTokens.textSecondary,
                                  size: 19,
                                ),
                                onPressed: () =>
                                    unawaited(_deleteInstalled(driver)),
                              ),
                            ),
                          ),
                        );
                      }),
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        const Expanded(
                          child: Text(
                            'BAIXAR TURNIP (GITHUB ADRENOTOOLS)',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.7,
                              color: HydraTokens.textSecondary,
                            ),
                          ),
                        ),
                        if (!_loadingReleases)
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () => unawaited(_loadReleases()),
                            child: const Text('Atualizar'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (_loadingReleases)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (_releases.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          'Sem resposta das releases do GitHub no momento. Verifique sua internet ou importe um .zip.',
                          style: TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 12,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      )
                    else
                      ..._releases.map((rel) {
                        final downloadingThis =
                            _downloadingUrl == rel.downloadUrl;
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: HydraTokens.surfaceCatalog,
                            borderRadius: BorderRadius.circular(12),
                            border:
                                Border.all(color: HydraTokens.borderSubtle8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          rel.assetName,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: HydraTokens.textPrimary,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${rel.repo} • ${rel.tag} • ${rel.formattedSize}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontFamily: 'JetBrainsMono',
                                            fontSize: 10.5,
                                            color: HydraTokens.textSecondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  OutlinedButton(
                                    onPressed: _downloadingUrl != null
                                        ? null
                                        : () => unawaited(
                                              _downloadRelease(rel),
                                            ),
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor:
                                          HydraTokens.primaryAurora,
                                      minimumSize: const Size(48, 48),
                                      side: const BorderSide(
                                        color: HydraTokens.borderSubtle10,
                                      ),
                                    ),
                                    child: Text(
                                      downloadingThis
                                          ? LoopProgressIndicator.formatPercent(
                                              _downloadProgress,
                                            )
                                          : 'Baixar',
                                    ),
                                  ),
                                ],
                              ),
                              if (downloadingThis) ...[
                                const SizedBox(height: 8),
                                LoopProgressIndicator(
                                  progress: _downloadProgress > 0
                                      ? _downloadProgress
                                      : null,
                                  showLabelRow: false,
                                  color: HydraTokens.primaryAurora,
                                  backgroundColor: Colors.white12,
                                  semanticsLabel:
                                      'Progresso de download do driver ${rel.assetName}',
                                ),
                              ],
                            ],
                          ),
                        );
                      }),
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
