import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/app_settings.dart';
import '../models/emulation_game.dart';
import '../models/user_library_meta.dart';
import '../services/cover_cache_service.dart';
import '../services/emulator_service.dart';
import '../services/settings_storage_service.dart';
import '../theme/hydra_tokens.dart';
import '../widgets/loop_common_widgets.dart';

enum _SidebarSection {
  saves,
  graphics,
  gamepad,
  hudInfo,
}

enum _GamepadEditTarget {
  global('Todos'),
  shoulders('Gatilhos L/R'),
  dpad('D-Pad'),
  stick('Analógico'),
  actions('Botões Ação'),
  selectStart('Select/Start');

  const _GamepadEditTarget(this.label);
  final String label;
}

class LibretroPlayerScreen extends StatefulWidget {
  const LibretroPlayerScreen({
    super.key,
    required this.game,
    required this.romPath,
    required this.emulatorService,
    required this.initialSettings,
    required this.onSettingsChanged,
  });

  final EmulationGame game;
  final String romPath;
  final EmulatorService emulatorService;
  final AppSettings initialSettings;
  final ValueChanged<AppSettings> onSettingsChanged;

  @override
  State<LibretroPlayerScreen> createState() => _LibretroPlayerScreenState();
}

class _LibretroPlayerScreenState extends State<LibretroPlayerScreen> {
  final GlobalKey _viewportRepaintKey = GlobalKey();
  final SettingsStorageService _settingsStorage = SettingsStorageService();

  late final ValueNotifier<AppSettings> _settingsNotifier =
      ValueNotifier<AppSettings>(widget.initialSettings);
  final ValueNotifier<int> _joypadMaskNotifier = ValueNotifier<int>(0);
  final ValueNotifier<Offset> _stickVectorNotifier =
      ValueNotifier<Offset>(Offset.zero);
  final ValueNotifier<LibretroTelemetryEvent> _telemetryNotifier =
      ValueNotifier<LibretroTelemetryEvent>(
    const LibretroTelemetryEvent(
      fps: 60.0,
      frameTimeMs: 16.6,
      frameWidth: 480,
      frameHeight: 272,
      coreName: 'Console',
    ),
  );
  final ValueNotifier<double> _consoleAspectNotifier =
      ValueNotifier<double>(480.0 / 272.0);
  final ValueNotifier<double> _coreDownloadProgressNotifier =
      ValueNotifier<double>(0.0);
  final ValueNotifier<({String message, bool isError})?> _toastNotifier =
      ValueNotifier<({String message, bool isError})?>(null);
  final ValueNotifier<bool> _hardwareGamepadNotifier =
      ValueNotifier<bool>(false);

  AppSettings get _settings => _settingsNotifier.value;

  int? _textureId;
  int _lastSentMask = 0;
  int _lastSentStickX = 0;
  int _lastSentStickY = 0;
  bool _isPreparingCore = true;

  bool _isSidebarOpen = false;
  bool _isDraggingGamepad = false;
  bool _isExitDialogOpen = false;
  _SidebarSection _sidebarSection = _SidebarSection.saves;

  List<SaveStateSlotInfo> _saveSlots = const [];
  Uint8List? _lastCapturedPreviewPng;
  Timer? _toastTimer;
  Timer? _overlaySaveDebounceTimer;
  bool _hasPendingOverlaySave = false;
  String? _errorMessage;

  StreamSubscription<LibretroTelemetryEvent>? _telemetrySub;
  StreamSubscription<void>? _gamepadSub;

  final DateTime _sessionStartTime = DateTime.now();
  bool _isGameSpecificProfile = false;
  bool _isFastForwardActive = false;

  bool _shouldShowTouchOverlayFor(AppSettings settings, bool hardwareActive) {
    switch (settings.touchOverlayMode) {
      case TouchOverlayMode.alwaysShow:
        return true;
      case TouchOverlayMode.alwaysHide:
        return false;
      case TouchOverlayMode.auto:
        return !hardwareActive;
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]),
    );
    _gamepadSub = widget.emulatorService.hardwareGamepadStream.listen((_) {
      if (mounted && !_hardwareGamepadNotifier.value) {
        _hardwareGamepadNotifier.value = true;
      }
    });
    unawaited(_bootLibretroSession());
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _flushPendingOverlaySave(syncNative: false);
    unawaited(_telemetrySub?.cancel());
    unawaited(_gamepadSub?.cancel());
    unawaited(widget.emulatorService.stopSession());
    // Preserva immersiveSticky para não divergir do modo do app em main.dart.
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
    );
    unawaited(
      SystemChrome.setPreferredOrientations(DeviceOrientation.values),
    );
    _settingsNotifier.dispose();
    _joypadMaskNotifier.dispose();
    _stickVectorNotifier.dispose();
    _telemetryNotifier.dispose();
    _consoleAspectNotifier.dispose();
    _coreDownloadProgressNotifier.dispose();
    _toastNotifier.dispose();
    _hardwareGamepadNotifier.dispose();
    super.dispose();
  }

  void _showToast(String message, {bool isError = false}) {
    _toastTimer?.cancel();
    if (!mounted) return;
    _toastNotifier.value = (message: message, isError: isError);
    _toastTimer = Timer(Duration(seconds: isError ? 3 : 2), () {
      if (mounted) {
        _toastNotifier.value = null;
      }
    });
  }

  void _setFastForward(bool active) {
    if (_isFastForwardActive == active) return;
    _isFastForwardActive = active;
    unawaited(widget.emulatorService.setFastForward(active ? 2.0 : 1.0));
    if (active) {
      unawaited(HapticFeedback.lightImpact());
      _showToast('Avanço Rápido 2x');
    }
  }

  void _updateDpadBits(int dpadBits) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    const dpadClear = RetroJoypadMask.up |
        RetroJoypadMask.down |
        RetroJoypadMask.left |
        RetroJoypadMask.right;
    final prev = _joypadMaskNotifier.value;
    final next = (prev & ~dpadClear) | (dpadBits & dpadClear);
    if (next == prev) return;
    _joypadMaskNotifier.value = next;
    if (dpadBits != 0 && _settings.hapticVibration) {
      unawaited(HapticFeedback.selectionClick());
    }
    _syncInputToCore();
  }

  void _persistSettings(AppSettings next) {
    if (_isGameSpecificProfile) {
      unawaited(
        _settingsStorage.loadGameProfiles().then((profiles) {
          profiles[widget.game.igdbId] = next;
          return _settingsStorage.saveGameProfiles(profiles);
        }),
      );
    } else {
      widget.onSettingsChanged(next);
    }
  }

  void _syncNativeAudioAndPerformance(AppSettings next) {
    unawaited(
      widget.emulatorService.setAudioConfig(
        enabled: next.audioEnabled,
        volume: next.masterVolume,
      ),
    );
    unawaited(
      widget.emulatorService.setPerformanceConfig(
        frameSkip: next.frameSkip,
        vsyncEnabled: next.vsyncEnabled,
        frameDup: next.frameDuplication,
      ),
    );
  }

  void _applyAndSaveSettings(AppSettings next) {
    _overlaySaveDebounceTimer?.cancel();
    _hasPendingOverlaySave = false;
    _settingsNotifier.value = next;
    _persistSettings(next);
    _syncNativeAudioAndPerformance(next);
  }

  void _scheduleDebouncedOverlayUpdate(
    AppSettings next, {
    bool syncNative = false,
  }) {
    _settingsNotifier.value = next;
    _hasPendingOverlaySave = true;
    _overlaySaveDebounceTimer?.cancel();
    _overlaySaveDebounceTimer = Timer(
      const Duration(milliseconds: 350),
      () => _flushPendingOverlaySave(syncNative: syncNative),
    );
  }

  void _flushPendingOverlaySave({bool syncNative = true}) {
    _overlaySaveDebounceTimer?.cancel();
    _overlaySaveDebounceTimer = null;
    if (!_hasPendingOverlaySave) return;
    _hasPendingOverlaySave = false;
    final current = _settings;
    _persistSettings(current);
    if (syncNative) {
      _syncNativeAudioAndPerformance(current);
    }
  }

  /// Opções que só são lidas na inicialização do core — avisa que é
  /// preciso reiniciar o jogo para aplicar.
  void _applyGraphicsSetting(AppSettings next, {bool restartRequired = true}) {
    _applyAndSaveSettings(next);
    if (restartRequired) {
      _showToast('Reinicie o jogo para aplicar as novas opções gráficas');
    }
  }

  Future<void> _refreshSaveSlots() async {
    final slots = await widget.emulatorService.listSaveSlots(
      widget.romPath,
      defaultGameTitle: widget.game.name,
    );
    if (mounted) {
      setState(() => _saveSlots = slots);
    }
  }

  Future<Uint8List?> _captureViewportPreviewPng() async {
    try {
      if (!kIsWeb && Platform.environment.containsKey('FLUTTER_TEST')) {
        return _lastCapturedPreviewPng;
      }
      final ctx = _viewportRepaintKey.currentContext;
      if (ctx == null) return _lastCapturedPreviewPng;
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return _lastCapturedPreviewPng;
      final image = await boundary
          .toImage(pixelRatio: 0.5)
          .timeout(const Duration(milliseconds: 500));
      try {
        final byteData = await image
            .toByteData(format: ui.ImageByteFormat.png)
            .timeout(const Duration(milliseconds: 500));
        if (byteData != null) {
          _lastCapturedPreviewPng = byteData.buffer.asUint8List();
          return _lastCapturedPreviewPng;
        }
      } finally {
        image.dispose();
      }
    } catch (_) {}
    return _lastCapturedPreviewPng;
  }

  Future<void> _openSidebar([_SidebarSection? section]) async {
    await _captureViewportPreviewPng();
    await _refreshSaveSlots();
    if (!mounted) return;
    setState(() {
      if (section != null) _sidebarSection = section;
      _isSidebarOpen = true;
      _isDraggingGamepad = false;
    });
    await widget.emulatorService.setPaused(true);
  }

  Future<void> _closeSidebarAndResume() async {
    if (!mounted) return;
    setState(() {
      _isSidebarOpen = false;
      _isDraggingGamepad = false;
    });
    await widget.emulatorService.setPaused(false);
  }

  Future<void> _bootLibretroSession() async {
    try {
      final profiles = await _settingsStorage.loadGameProfiles();
      if (profiles.containsKey(widget.game.igdbId) && mounted) {
        _settingsNotifier.value = profiles[widget.game.igdbId]!;
        _isGameSpecificProfile = true;
      }
    } catch (_) {}

    await _refreshSaveSlots();
    if (!mounted) return;

    _telemetrySub = widget.emulatorService.telemetryStream.listen((evt) {
      if (!mounted || _isSidebarOpen) return;
      _telemetryNotifier.value = evt;
      if (evt.frameWidth > 0 && evt.frameHeight > 0) {
        final nextRatio = evt.frameWidth / evt.frameHeight;
        if ((nextRatio - _consoleAspectNotifier.value).abs() > 0.001) {
          _consoleAspectNotifier.value = nextRatio;
        }
      }
    });

    try {
      final isPs3 =
          widget.game.libretroCoreSoName == 'rpcs3_libretro_android.so';
      final texId = await widget.emulatorService.startSession(
        platformSlug: widget.game.platformSlug,
        coreSoName: widget.game.libretroCoreSoName,
        romPath: widget.romPath,
        frameSkip: _settings.frameSkip,
        vsyncEnabled: _settings.vsyncEnabled,
        audioEnabled: _settings.audioEnabled,
        masterVolume: _settings.masterVolume,
        softwareRendering:
            isPs3 ? false : _settings.gpuBackend == GpuBackend.software,
        gpuBackend: isPs3 ? 'vulkan' : _settings.gpuBackend.name,
        screenScale: _settings.screenResolution.scale,
        frameDup: _settings.frameDuplication,
        customDriverDir: _settings.customVulkanDriverDir,
        customDriverName: _settings.customVulkanDriverName,
        adrenoTurbo: _settings.adrenoTurboMode,
        freedrenoPreset: _settings.freedrenoPreset.envValue,
        coreOptions: widget.game.platformSlug.toLowerCase() == 'psp'
            ? _settings.libretroCoreOptions
            : null,
        onCoreDownloadProgress: (p) {
          if (mounted) {
            _coreDownloadProgressNotifier.value = p;
          }
        },
      );
      if (mounted) {
        setState(() {
          _textureId = texId;
          _isPreparingCore = false;
        });
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Bad state: ', '');
        setState(() {
          _isPreparingCore = false;
          _errorMessage = msg;
        });
      }
    }

    // Só carrega automaticamente se a sessão subiu e o usuário ativou explicitamente
    if (mounted &&
        _textureId != null &&
        _errorMessage == null &&
        _settings.autoLoadOnStart &&
        _saveSlots.isNotEmpty &&
        _saveSlots.first.exists) {
      final loaded = await widget.emulatorService.loadState(
        0,
        romPath: widget.romPath,
      );
      if (mounted) {
        _showToast(
          loaded
              ? 'Save carregado automaticamente'
              : (widget.emulatorService.lastError ??
                  'Falha ao carregar Quick Save automático'),
          isError: !loaded,
        );
      }
    }
  }

  Future<void> _handleSaveToSlot(int slot) async {
    final label = slot == 0 ? 'Quick Save' : 'Slot $slot';
    final preview = await _captureViewportPreviewPng();
    final ok = await widget.emulatorService.saveState(
      slot,
      romPath: widget.romPath,
      gameTitle: widget.game.name,
      previewPngBytes: preview,
    );
    await _refreshSaveSlots();
    if (!mounted) return;
    if (ok) {
      _showToast('Salvo em $label (${widget.game.name})');
    } else {
      _showToast(
        widget.emulatorService.lastError ?? 'Falha ao salvar estado em $label',
        isError: true,
      );
    }
  }

  Future<void> _handleLoadFromSlot(int slot) async {
    final label = slot == 0 ? 'Quick Save' : 'Slot $slot';
    final ok = await widget.emulatorService.loadState(
      slot,
      romPath: widget.romPath,
    );
    if (!mounted) return;
    if (ok) {
      await _closeSidebarAndResume();
      _showToast('Carregado de $label');
    } else {
      final slotExists = _saveSlots.any((s) => s.slot == slot && s.exists);
      _showToast(
        widget.emulatorService.lastError ??
            (slotExists
                ? 'Falha ao carregar estado de $label'
                : 'Este slot está vazio'),
        isError: true,
      );
    }
  }

  Future<void> _handleDeleteSlot(int slot) async {
    await widget.emulatorService.deleteSaveState(
      slot,
      romPath: widget.romPath,
    );
    await _refreshSaveSlots();
    if (mounted) {
      _showToast('Save removido');
    }
  }

  Future<void> _confirmExitPlayer() async {
    if (_isExitDialogOpen || !mounted) return;
    _isExitDialogOpen = true;
    final wasSidebarOpen = _isSidebarOpen;
    if (!wasSidebarOpen) {
      unawaited(widget.emulatorService.setPaused(true));
    }

    String? choice;
    try {
      choice = await showDialog<String>(
        context: context,
        barrierDismissible: true,
        builder: (ctx) {
          return AlertDialog(
            backgroundColor: HydraTokens.bgNearBlack,
            shape: HydraTokens.dialogShape,
            title: const Text(
              'Encerrar partida?',
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: HydraTokens.textPrimary,
              ),
            ),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Deseja salvar no Quick Save antes de voltar para a biblioteca?',
                      style: TextStyle(
                        fontFamily: 'Rubik',
                        fontSize: 13,
                        height: 1.4,
                        color: HydraTokens.textSecondary,
                      ),
                    ),
                    if (_settings.autoSaveOnExit) ...[
                      const SizedBox(height: 10),
                      const Text(
                        'Auto-save ao sair está ativado nas configurações.',
                        style: TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11.5,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
            actions: [
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: HydraTokens.textSecondary,
                    ),
                    onPressed: () => Navigator.of(ctx).pop('cancel'),
                    child: const Text(
                      'Cancelar',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      foregroundColor: HydraTokens.accentDanger,
                      side: BorderSide(
                        color: HydraTokens.accentDanger.withOpacity(0.55),
                      ),
                    ),
                    onPressed: () => Navigator.of(ctx).pop('exit_only'),
                    child: const Text(
                      'Sair sem salvar',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      backgroundColor: HydraTokens.primaryAurora,
                      foregroundColor: HydraTokens.bgPureBlack,
                    ),
                    onPressed: () => Navigator.of(ctx).pop('save_and_exit'),
                    child: const Text(
                      'Salvar rápido e sair',
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      );
    } finally {
      _isExitDialogOpen = false;
    }

    if (!mounted) return;
    if (choice == 'save_and_exit') {
      final exited = await _exitPlayerToLibrary(saveQuickState: true);
      if (!exited && mounted && !wasSidebarOpen && !_isSidebarOpen) {
        unawaited(widget.emulatorService.setPaused(false));
      }
    } else if (choice == 'exit_only') {
      await _exitPlayerToLibrary(saveQuickState: false);
    } else if (!wasSidebarOpen && !_isSidebarOpen) {
      unawaited(widget.emulatorService.setPaused(false));
    }
  }

  /// Sai do jogo salvando Quick Save apenas quando solicitado explicitamente.
  Future<bool> _exitPlayerToLibrary({required bool saveQuickState}) async {
    _flushPendingOverlaySave(syncNative: false);
    if (saveQuickState) {
      final preview = await _captureViewportPreviewPng();
      final saved = await widget.emulatorService.saveState(
        0,
        romPath: widget.romPath,
        gameTitle: widget.game.name,
        previewPngBytes: preview,
      );
      if (!saved) {
        if (mounted) {
          _showToast(
            widget.emulatorService.lastError ??
                'Falha ao salvar Quick Save. Use "Sair sem salvar" para encerrar.',
            isError: true,
          );
        }
        return false;
      }
    }

    final elapsed = DateTime.now().difference(_sessionStartTime).inSeconds;
    if (elapsed > 0) {
      try {
        final UserLibraryMeta meta = await _settingsStorage.loadUserMeta();
        final updated =
            meta.recordSession(widget.game.igdbId, elapsed, DateTime.now());
        await _settingsStorage.saveUserMeta(updated);
      } catch (_) {}
    }
    if (mounted) {
      Navigator.of(context).pop();
      return true;
    }
    return false;
  }

  void _syncInputToCore() {
    final mask = _joypadMaskNotifier.value;
    final stick = _stickVectorNotifier.value;
    final qx = (stick.dx * 32767).round();
    final qy = (stick.dy * 32767).round();
    if (mask == _lastSentMask &&
        qx == _lastSentStickX &&
        qy == _lastSentStickY) {
      return;
    }
    _lastSentMask = mask;
    _lastSentStickX = qx;
    _lastSentStickY = qy;

    unawaited(
      widget.emulatorService.sendInputState(
        joypadMask: mask,
        leftStickX: stick.dx,
        leftStickY: stick.dy,
      ),
    );
  }

  void _updateButtonBit(int maskBit, bool pressed) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    final prev = _joypadMaskNotifier.value;
    final next = pressed ? (prev | maskBit) : (prev & ~maskBit);
    if (next == prev) return;
    _joypadMaskNotifier.value = next;
    if (pressed && _settings.hapticVibration) {
      unawaited(HapticFeedback.selectionClick());
    }
    _syncInputToCore();
  }

  bool _shouldUseSingleShoulderTriggers(AppSettings settings) =>
      settings.shouldUseSingleTriggers(widget.game.platformSlug);

  void _updateAnalogVector(double nx, double ny) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    final clampedX = nx.clamp(-1.0, 1.0);
    final clampedY = ny.clamp(-1.0, 1.0);
    final prev = _stickVectorNotifier.value;
    if ((prev.dx - clampedX).abs() < 0.0005 &&
        (prev.dy - clampedY).abs() < 0.0005) {
      return;
    }
    _stickVectorNotifier.value = Offset(clampedX, clampedY);
    _syncInputToCore();
  }

  double _resolveTargetAspectRatio(
    Size screen,
    AppSettings settings,
    double consoleAspect,
  ) {
    switch (settings.aspectRatio) {
      case AspectRatioPreset.widescreen169:
        return 16.0 / 9.0;
      case AspectRatioPreset.fullScreen:
        return screen.width / math.max(1.0, screen.height);
      case AspectRatioPreset.consoleOriginal:
        return consoleAspect;
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || _isExitDialogOpen) return;
        if (_isDraggingGamepad) {
          _flushPendingOverlaySave();
          setState(() {
            _isDraggingGamepad = false;
            _isSidebarOpen = true;
          });
          unawaited(widget.emulatorService.setPaused(true));
        } else if (_isSidebarOpen || _isPreparingCore || _errorMessage != null) {
          unawaited(_confirmExitPlayer());
        } else {
          unawaited(_openSidebar());
        }
      },
      child: Scaffold(
        backgroundColor: HydraTokens.bgPureBlack,
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            if (_hardwareGamepadNotifier.value) {
              _hardwareGamepadNotifier.value = false;
            }
          },
          child: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                // ==============================================================
                // 1. VIEWPORT DE VÍDEO (Isolado com RepaintBoundary para máximo FPS)
                // ==============================================================
                Center(
                  child: RepaintBoundary(
                    key: _viewportRepaintKey,
                    child: ValueListenableBuilder<AppSettings>(
                      valueListenable: _settingsNotifier,
                      builder: (_, settings, __) {
                        final filterQuality = settings.videoFilter ==
                                VideoFilterPreset.smoothBilinear
                            ? FilterQuality.medium
                            : FilterQuality.none;
                        return ValueListenableBuilder<double>(
                          valueListenable: _consoleAspectNotifier,
                          builder: (_, consoleAspect, __) {
                            final aspect = _resolveTargetAspectRatio(
                              screenSize,
                              settings,
                              consoleAspect,
                            );
                            return AspectRatio(
                              aspectRatio: aspect,
                              child: Container(
                                color: HydraTokens.bgPureBlack,
                                child: _isPreparingCore
                                    ? Center(
                                        child: ValueListenableBuilder<double>(
                                          valueListenable:
                                              _coreDownloadProgressNotifier,
                                          builder: (_, progress, __) {
                                            return Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const CircularProgressIndicator(
                                                  color:
                                                      HydraTokens.primaryAurora,
                                                ),
                                                const SizedBox(height: 14),
                                                Text(
                                                  'Iniciando ${widget.game.platformName} (${(progress * 100).toStringAsFixed(0)}%)',
                                                  style: const TextStyle(
                                                    fontFamily: 'JetBrainsMono',
                                                    fontSize: 12,
                                                    color:
                                                        HydraTokens.textPrimary,
                                                  ),
                                                ),
                                              ],
                                            );
                                          },
                                        ),
                                      )
                                    : Stack(
                                        fit: StackFit.expand,
                                        children: [
                                          if (_textureId != null)
                                            Texture(
                                              textureId: _textureId!,
                                              filterQuality: filterQuality,
                                            )
                                          else
                                            _FallbackGameplayPreview(
                                              game: widget.game,
                                              resolutionLabel:
                                                  settings.resolutionLabel,
                                              errorMessage: _errorMessage,
                                            ),
                                          if (settings.videoFilter ==
                                              VideoFilterPreset.crtScanlines)
                                            const IgnorePointer(
                                              child: CustomPaint(
                                                painter: _CrtScanlinePainter(),
                                              ),
                                            ),
                                          if (settings.videoFilter ==
                                              VideoFilterPreset.lcdHandheld)
                                            const IgnorePointer(
                                              child: CustomPaint(
                                                painter: _LcdGridPainter(),
                                              ),
                                            ),
                                        ],
                                      ),
                              ),
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),

                // ==============================================================
                // 2. CONTROLES TOUCH NA TELA (AUTO-HIDE SE GAMEPAD FÍSICO CONECTAR)
                // ==============================================================
                Positioned.fill(
                  child: RepaintBoundary(
                    child: ValueListenableBuilder<bool>(
                      valueListenable: _hardwareGamepadNotifier,
                      builder: (_, hardwareActive, __) {
                        return ValueListenableBuilder<AppSettings>(
                          valueListenable: _settingsNotifier,
                          builder: (_, settings, __) {
                            if (!_shouldShowTouchOverlayFor(
                              settings,
                              hardwareActive,
                            )) {
                              return const SizedBox.shrink();
                            }
                            final singleShoulders =
                                _shouldUseSingleShoulderTriggers(settings);
                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                // 3. GATILHO L
                                Positioned(
                                  left: 20,
                                  top: settings.shoulderTop,
                                  child: _buildDraggableOverlayControl(
                                    label: singleShoulders
                                        ? 'Gatilho L'
                                        : 'Gatilhos L1 / L2',
                                    target: _GamepadEditTarget.shoulders,
                                    opacity: settings.gamepadOpacity *
                                        settings.shoulderOpacity,
                                    scale: settings.gamepadScale *
                                        settings.shoulderScale,
                                    scaleAlignment: Alignment.topLeft,
                                    onDragDelta: (d) => settings.copyWith(
                                      shoulderTop:
                                          (settings.shoulderTop + d.delta.dy)
                                              .clamp(10.0, 190.0),
                                    ),
                                    child: _ShoulderTriggerCluster(
                                      isLeft: true,
                                      style: settings.shoulderStyle,
                                      buttonStyle: settings.buttonStyle,
                                      spacing: settings.shoulderSpacing,
                                      singleTriggerOnly: singleShoulders,
                                      joypadMaskListenable: _joypadMaskNotifier,
                                      onPrimaryChanged: (v) =>
                                          _updateButtonBit(RetroJoypadMask.l, v),
                                      onSecondaryChanged: (v) =>
                                          _updateButtonBit(
                                        RetroJoypadMask.l2,
                                        v,
                                      ),
                                    ),
                                  ),
                                ),
                                // 3. GATILHO R
                                Positioned(
                                  right: 20,
                                  top: settings.shoulderTop,
                                  child: _buildDraggableOverlayControl(
                                    label: singleShoulders
                                        ? 'Gatilho R'
                                        : 'Gatilhos R1 / R2',
                                    target: _GamepadEditTarget.shoulders,
                                    opacity: settings.gamepadOpacity *
                                        settings.shoulderOpacity,
                                    scale: settings.gamepadScale *
                                        settings.shoulderScale,
                                    scaleAlignment: Alignment.topRight,
                                    onDragDelta: (d) => settings.copyWith(
                                      shoulderTop:
                                          (settings.shoulderTop + d.delta.dy)
                                              .clamp(10.0, 190.0),
                                    ),
                                    child: _ShoulderTriggerCluster(
                                      isLeft: false,
                                      style: settings.shoulderStyle,
                                      buttonStyle: settings.buttonStyle,
                                      spacing: settings.shoulderSpacing,
                                      singleTriggerOnly: singleShoulders,
                                      joypadMaskListenable: _joypadMaskNotifier,
                                      onPrimaryChanged: (v) =>
                                          _updateButtonBit(RetroJoypadMask.r, v),
                                      onSecondaryChanged: (v) =>
                                          _updateButtonBit(
                                        RetroJoypadMask.r2,
                                        v,
                                      ),
                                    ),
                                  ),
                                ),
                                // 4. D-PAD DIRECIONAL
                                Positioned(
                                  left: settings.dpadLeft,
                                  bottom: settings.dpadBottom,
                                  child: _buildDraggableOverlayControl(
                                    label: 'Direcional D-Pad',
                                    target: _GamepadEditTarget.dpad,
                                    opacity: settings.gamepadOpacity *
                                        settings.dpadOpacity,
                                    scale: settings.gamepadScale *
                                        settings.dpadScale,
                                    onDragDelta: (d) => settings.copyWith(
                                      dpadLeft: (settings.dpadLeft + d.delta.dx)
                                          .clamp(8.0, 420.0),
                                      dpadBottom:
                                          (settings.dpadBottom - d.delta.dy)
                                              .clamp(8.0, 260.0),
                                    ),
                                    child: _DpadClusterWidget(
                                      joypadMaskListenable: _joypadMaskNotifier,
                                      spacing: settings.dpadSpacing,
                                      buttonStyle: settings.buttonStyle,
                                      onDpadBitsChanged: _updateDpadBits,
                                    ),
                                  ),
                                ),
                                // 5. ANALÓGICO VIRTUAL
                                Positioned(
                                  left: settings.stickLeft,
                                  bottom: settings.stickBottom,
                                  child: _buildDraggableOverlayControl(
                                    label: 'Alavanca Analógica',
                                    target: _GamepadEditTarget.stick,
                                    opacity: settings.gamepadOpacity *
                                        settings.stickOpacity,
                                    scale: settings.gamepadScale *
                                        settings.stickScale,
                                    onDragDelta: (d) => settings.copyWith(
                                      stickLeft:
                                          (settings.stickLeft + d.delta.dx)
                                              .clamp(8.0, 460.0),
                                      stickBottom:
                                          (settings.stickBottom - d.delta.dy)
                                              .clamp(8.0, 260.0),
                                    ),
                                    child: _VirtualAnalogStick(
                                      stickListenable: _stickVectorNotifier,
                                      enabled:
                                          !_isDraggingGamepad && !_isSidebarOpen,
                                      onStickChanged: _updateAnalogVector,
                                    ),
                                  ),
                                ),
                                // 6. BOTÕES DE AÇÃO DIREITOS
                                Positioned(
                                  right: settings.actionRight,
                                  bottom: settings.actionBottom,
                                  child: _buildDraggableOverlayControl(
                                    label: 'Botões Ação (A B X Y)',
                                    target: _GamepadEditTarget.actions,
                                    opacity: settings.gamepadOpacity *
                                        settings.actionOpacity,
                                    scale: settings.gamepadScale *
                                        settings.actionScale,
                                    onDragDelta: (d) => settings.copyWith(
                                      actionRight:
                                          (settings.actionRight - d.delta.dx)
                                              .clamp(8.0, 420.0),
                                      actionBottom:
                                          (settings.actionBottom - d.delta.dy)
                                              .clamp(8.0, 260.0),
                                    ),
                                    child: _ActionButtonsClusterWidget(
                                      joypadMaskListenable: _joypadMaskNotifier,
                                      spacing: settings.actionSpacing,
                                      buttonStyle: settings.buttonStyle,
                                      onBitChanged: _updateButtonBit,
                                    ),
                                  ),
                                ),
                                // 7. SELECT / START
                                Positioned(
                                  bottom: settings.selectStartBottom,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: _buildDraggableOverlayControl(
                                      label: 'Select & Start',
                                      target: _GamepadEditTarget.selectStart,
                                      opacity: settings.gamepadOpacity *
                                          settings.selectStartOpacity,
                                      scale: settings.gamepadScale *
                                          settings.selectStartScale,
                                      onDragDelta: (d) => settings.copyWith(
                                        selectStartBottom:
                                            (settings.selectStartBottom -
                                                    d.delta.dy)
                                                .clamp(6.0, 200.0),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _MaskSliceBuilder(
                                            maskListenable: _joypadMaskNotifier,
                                            watchMask: RetroJoypadMask.select,
                                            builder: (_, slice) =>
                                                _SelectPillButton(
                                              style: settings.buttonStyle,
                                              active: slice != 0,
                                              onChanged: (v) =>
                                                  _updateButtonBit(
                                                RetroJoypadMask.select,
                                                v,
                                              ),
                                              onFastForward: _setFastForward,
                                            ),
                                          ),
                                          SizedBox(
                                            width: settings.selectStartSpacing,
                                          ),
                                          _MaskSliceBuilder(
                                            maskListenable: _joypadMaskNotifier,
                                            watchMask: RetroJoypadMask.start,
                                            builder: (_, slice) =>
                                                _PillGamepadButton(
                                              label: 'START',
                                              style: settings.buttonStyle,
                                              active: slice != 0,
                                              onChanged: (v) =>
                                                  _updateButtonBit(
                                                RetroJoypadMask.start,
                                                v,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),
                  ),
                ),

                // ==============================================================
                // 3. HUD DISCRETO E CONFIGURÁVEL (Isolado em ValueNotifier + RepaintBoundary)
                // ==============================================================
                if (!_isDraggingGamepad)
                  Positioned(
                    top: 4,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: RepaintBoundary(
                        child: _HudTelemetryPill(
                          settingsListenable: _settingsNotifier,
                          telemetryListenable: _telemetryNotifier,
                          platformName: widget.game.platformName,
                          editing: false,
                          onTap: () => unawaited(_openSidebar()),
                        ),
                      ),
                    ),
                  ),

                // ==============================================================
                // 8. BARRA FLUTUANTE DO MODO "MOVER & EDITAR BOTÕES NA TELA"
                // ==============================================================
                if (_isDraggingGamepad)
                  Positioned(
                    top: 8,
                    left: 12,
                    right: 12,
                    child: Center(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.92),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: Colors.white,
                              width: 1.5,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PhosphorIcon(
                                PhosphorIcons.handTap(PhosphorIconsStyle.bold),
                                size: 15,
                                color: Colors.white,
                              ),
                              const SizedBox(width: 8),
                              const Text(
                                'Arraste para mover • Toque para ajustar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Semantics(
                                button: true,
                                label: 'Editar informações do HUD',
                                child: Tooltip(
                                  message: 'Personalizar HUD',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () => unawaited(_openHudCustomizer()),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 6,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white12,
                                            borderRadius:
                                                BorderRadius.circular(14),
                                            border: Border.all(
                                              color: Colors.white38,
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              PhosphorIcon(
                                                PhosphorIcons.slidersHorizontal(
                                                  PhosphorIconsStyle.bold,
                                                ),
                                                size: 13,
                                                color: Colors.white,
                                              ),
                                              const SizedBox(width: 5),
                                              const Text(
                                                'HUD',
                                                style: TextStyle(
                                                  fontFamily: 'ReadexPro',
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.white,
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
                              const SizedBox(width: 6),
                              Semantics(
                                button: true,
                                label: 'Concluir edição dos botões',
                                child: Tooltip(
                                  message: 'Salvar e concluir edição',
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(14),
                                    onTap: () {
                                      _flushPendingOverlaySave();
                                      setState(() {
                                        _isDraggingGamepad = false;
                                        _isSidebarOpen = true;
                                      });
                                      unawaited(
                                        widget.emulatorService.setPaused(true),
                                      );
                                      _showToast('Ajustes salvos com sucesso!');
                                    },
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      child: Center(
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 7,
                                          ),
                                          decoration: BoxDecoration(
                                            color: Colors.white,
                                            borderRadius:
                                                BorderRadius.circular(14),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.check,
                                                size: 14,
                                                color: Colors.black,
                                              ),
                                              SizedBox(width: 4),
                                              Text(
                                                'Concluir',
                                                style: TextStyle(
                                                  fontFamily: 'ReadexPro',
                                                  fontSize: 11.5,
                                                  fontWeight: FontWeight.w700,
                                                  color: Colors.black,
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
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),

                // Toast de Confirmação / Erro (Isolado em ValueNotifier + RepaintBoundary)
                Positioned(
                  top: 52,
                  left: 16,
                  right: 16,
                  child: IgnorePointer(
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<
                          ({String message, bool isError})?>(
                        valueListenable: _toastNotifier,
                        builder: (_, toast, __) {
                          if (toast == null) return const SizedBox.shrink();
                          return Center(
                            child: Semantics(
                              liveRegion: true,
                              label: toast.message,
                              child: Container(
                                constraints:
                                    const BoxConstraints(maxWidth: 480),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: HydraTokens.bgNearBlack
                                      .withOpacity(0.95),
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: toast.isError
                                        ? HydraTokens.accentDanger
                                        : Colors.white.withOpacity(0.35),
                                    width: toast.isError ? 1.5 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (toast.isError) ...[
                                      PhosphorIcon(
                                        PhosphorIcons.warningCircle(
                                          PhosphorIconsStyle.bold,
                                        ),
                                        size: 15,
                                        color: HydraTokens.accentDanger,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Flexible(
                                      child: Text(
                                        toast.message,
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          color: HydraTokens.textPrimary,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),

                // ==============================================================
                // 9. SIDEBAR AO VOLTAR (ESTILO PPSSPP / GAMEHUB)
                // ==============================================================
                if (_isSidebarOpen)
                  Positioned.fill(
                    child: Row(
                      children: [
                        // Área escura clicável à esquerda para fechar a sidebar e voltar ao jogo
                        Expanded(
                          child: Semantics(
                            button: true,
                            label: 'Toque para continuar o jogo',
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => unawaited(_closeSidebarAndResume()),
                              child: Container(
                                color: Colors.black.withOpacity(0.55),
                                alignment: Alignment.centerLeft,
                                padding: const EdgeInsets.only(left: 24),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 14,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.65),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.15),
                                    ),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      PhosphorIcon(
                                        PhosphorIcons.play(
                                          PhosphorIconsStyle.fill,
                                        ),
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                      const SizedBox(width: 8),
                                      const Flexible(
                                        child: Text(
                                          'Toque para Continuar',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'ReadexPro',
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        // Painel Lateral Direito (Sidebar)
                        Container(
                          width: math.min(460.0, screenSize.width * 0.72),
                          height: double.infinity,
                          decoration: const BoxDecoration(
                            color: HydraTokens.bgNearBlack,
                            border: Border(
                              left: BorderSide(
                                color: HydraTokens.borderSubtle10,
                              ),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Color(0xDD000000),
                                blurRadius: 28,
                                offset: Offset(-8, 0),
                              ),
                            ],
                          ),
                          child: LayoutBuilder(
                            builder: (context, sidebarConstraints) {
                              final header = _buildSidebarHeader(
                                sidebarConstraints.maxWidth,
                              );
                              final tabs = _buildSidebarTabs();
                              if (sidebarConstraints.maxHeight < 250) {
                                return SingleChildScrollView(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      header,
                                      tabs,
                                      SizedBox(
                                        height: 240,
                                        child: _buildSidebarBody(),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return Column(
                                children: [
                                  header,
                                  tabs,
                                  Expanded(child: _buildSidebarBody()),
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
        ),
      ),
    );
  }

  Widget _buildDraggableOverlayControl({
    required String label,
    required _GamepadEditTarget target,
    required double opacity,
    required double scale,
    Alignment scaleAlignment = Alignment.center,
    required AppSettings Function(DragUpdateDetails details) onDragDelta,
    required Widget child,
  }) {
    return RepaintBoundary(
      child: GestureDetector(
        onPanUpdate: _isDraggingGamepad
            ? (d) => _scheduleDebouncedOverlayUpdate(onDragDelta(d))
            : null,
        onPanEnd: _isDraggingGamepad
            ? (_) => _flushPendingOverlaySave()
            : null,
        onPanCancel: _isDraggingGamepad ? _flushPendingOverlaySave : null,
        child: _EditableControlFrame(
          editing: _isDraggingGamepad,
          label: label,
          onTapEdit: () => unawaited(_openElementCustomizer(target)),
          child: Opacity(
            opacity: opacity.clamp(0.15, 1.0),
            child: Transform.scale(
              scale: scale,
              alignment: scaleAlignment,
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarHeader(double maxWidth) {
    final compactButtons = maxWidth < 340;
    final coverAndTitle = Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            width: 34,
            height: 46,
            child: LoopCoverImage(
              url: widget.game.resolvedGridCoverUrl,
              fit: BoxFit.cover,
              width: 34,
              height: 46,
              preset: LoopCoverImagePreset.thumbnail,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.game.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: HydraTokens.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${widget.game.platformName} • Jogo Pausado',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 10,
                  color: HydraTokens.primaryAurora,
                ),
              ),
            ],
          ),
        ),
      ],
    );

    final actionButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          label: 'Continuar jogo',
          child: Tooltip(
            message: 'Continuar jogo',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => unawaited(_closeSidebarAndResume()),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 11,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: HydraTokens.surfaceElevated1,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: HydraTokens.borderSubtle10,
                        ),
                      ),
                      child: const Text(
                        'Continuar',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Semantics(
          button: true,
          label: 'Sair da partida',
          child: Tooltip(
            message: 'Sair da partida',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => unawaited(_confirmExitPlayer()),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      decoration: BoxDecoration(
                        color: HydraTokens.accentDanger.withOpacity(0.18),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: HydraTokens.accentDanger.withOpacity(0.55),
                        ),
                      ),
                      child: const Text(
                        'Sair',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.accentDanger,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
      decoration: const BoxDecoration(
        color: HydraTokens.bgPureBlack,
        border: Border(
          bottom: BorderSide(color: HydraTokens.borderSubtle8),
        ),
      ),
      child: compactButtons
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                coverAndTitle,
                const SizedBox(height: 6),
                Align(alignment: Alignment.centerRight, child: actionButtons),
              ],
            )
          : Row(
              children: [
                Expanded(child: coverAndTitle),
                const SizedBox(width: 8),
                actionButtons,
              ],
            ),
    );
  }

  Widget _buildSidebarTabs() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: HydraTokens.borderSubtle8),
        ),
      ),
      child: Row(
        children: [
          _SidebarTabButton(
            label: 'Saves',
            icon: PhosphorIcons.floppyDisk(PhosphorIconsStyle.bold),
            active: _sidebarSection == _SidebarSection.saves,
            onTap: () => setState(() => _sidebarSection = _SidebarSection.saves),
          ),
          const SizedBox(width: 6),
          _SidebarTabButton(
            label: 'Gráficos',
            icon: PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.bold),
            active: _sidebarSection == _SidebarSection.graphics,
            onTap: () =>
                setState(() => _sidebarSection = _SidebarSection.graphics),
          ),
          const SizedBox(width: 6),
          _SidebarTabButton(
            label: 'Gamepad',
            icon: PhosphorIcons.gameController(PhosphorIconsStyle.bold),
            active: _sidebarSection == _SidebarSection.gamepad,
            onTap: () =>
                setState(() => _sidebarSection = _SidebarSection.gamepad),
          ),
          const SizedBox(width: 6),
          _SidebarTabButton(
            label: 'HUD Info',
            icon: PhosphorIcons.gauge(PhosphorIconsStyle.bold),
            active: _sidebarSection == _SidebarSection.hudInfo,
            onTap: () =>
                setState(() => _sidebarSection = _SidebarSection.hudInfo),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebarBody() {
    switch (_sidebarSection) {
      case _SidebarSection.saves:
        return _buildPpssppSavesPanel();
      case _SidebarSection.graphics:
        return _buildGraphicsPanel();
      case _SidebarSection.gamepad:
        return _buildGamepadEditorPanel();
      case _SidebarSection.hudInfo:
        return _buildHudConfigPanel();
    }
  }

  // ==========================================================================
  // ABA 1 DA SIDEBAR: SAVE STATES ESTILO PPSSPP (COM PREVIEW ONDE PAROU + TÍTULO)
  // ==========================================================================
  Widget _buildPpssppSavesPanel() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 10),
          child: Text(
            'Escolha um slot para salvar ou carregar onde parou (Só salva quando você clicar em Salvar)',
            style: TextStyle(
              fontFamily: 'Rubik',
              fontSize: 11.5,
              color: HydraTokens.textSecondary,
            ),
          ),
        ),
        for (final slotInfo in _saveSlots)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: HydraTokens.surfaceCatalog,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: slotInfo.exists
                      ? Colors.white.withOpacity(0.30)
                      : HydraTokens.borderSubtle8,
                ),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final previewThumb = ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 96,
                      height: 58,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (slotInfo.exists &&
                              slotInfo.previewImagePath != null &&
                              File(slotInfo.previewImagePath!).existsSync())
                            Image.file(
                              File(slotInfo.previewImagePath!),
                              key: ValueKey<String>(
                                '${slotInfo.previewImagePath}_${slotInfo.updatedAt?.millisecondsSinceEpoch}',
                              ),
                              cacheWidth: 240,
                              fit: BoxFit.cover,
                            )
                          else if (slotInfo.exists)
                            LoopCoverImage(
                              url: widget.game.resolvedHeroBannerUrl,
                              fit: BoxFit.cover,
                              width: 96,
                              height: 58,
                              preset: LoopCoverImagePreset.thumbnail,
                            )
                          else
                            Container(
                              color: HydraTokens.bgPureBlack,
                              alignment: Alignment.center,
                              child: Text(
                                'VAZIO',
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 9,
                                  color: Colors.white.withOpacity(0.45),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 5,
                            top: 4,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.75),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                slotInfo.slot == 0
                                    ? 'QUICK'
                                    : '#${slotInfo.slot}',
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );

                  final infoColumn = Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slotInfo.gameTitle ?? widget.game.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slotInfo.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'Rubik',
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.primaryAurora,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        slotInfo.statusLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 10,
                          color: HydraTokens.textSecondary,
                        ),
                      ),
                    ],
                  );

                  final saveBtn = Semantics(
                    button: true,
                    label: 'Salvar em ${slotInfo.title}',
                    child: Tooltip(
                      message: 'Salvar em ${slotInfo.title}',
                      child: Material(
                        color: HydraTokens.primaryAurora,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: () =>
                              unawaited(_handleSaveToSlot(slotInfo.slot)),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth: 72,
                              minHeight: 48,
                            ),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Center(
                                child: Text(
                                  'Salvar',
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                    color: HydraTokens.bgPureBlack,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );

                  final loadBtn = Semantics(
                    button: true,
                    enabled: slotInfo.exists,
                    label: 'Carregar de ${slotInfo.title}',
                    child: Tooltip(
                      message: slotInfo.exists
                          ? 'Carregar ${slotInfo.title}'
                          : 'Slot vazio',
                      child: Material(
                        color: slotInfo.exists
                            ? HydraTokens.surfaceElevated2
                            : HydraTokens.bgPureBlack,
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: slotInfo.exists
                              ? () =>
                                  unawaited(_handleLoadFromSlot(slotInfo.slot))
                              : null,
                          child: Container(
                            constraints: const BoxConstraints(
                              minWidth: 68,
                              minHeight: 48,
                            ),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: HydraTokens.borderSubtle10,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                'Carregar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: slotInfo.exists
                                      ? HydraTokens.textPrimary
                                      : HydraTokens.textMuted,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  );

                  final deleteBtn = slotInfo.exists
                      ? Semantics(
                          button: true,
                          label: 'Remover save de ${slotInfo.title}',
                          child: Tooltip(
                            message: 'Remover save',
                            child: Material(
                              color:
                                  HydraTokens.accentDanger.withOpacity(0.16),
                              borderRadius: BorderRadius.circular(8),
                              child: InkWell(
                                borderRadius: BorderRadius.circular(8),
                                onTap: () => unawaited(
                                  _handleDeleteSlot(slotInfo.slot),
                                ),
                                child: SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Center(
                                    child: PhosphorIcon(
                                      PhosphorIcons.trash(
                                        PhosphorIconsStyle.bold,
                                      ),
                                      size: 16,
                                      color: HydraTokens.accentDanger,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        )
                      : null;

                  if (constraints.maxWidth < 340) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            previewThumb,
                            const SizedBox(width: 12),
                            Expanded(child: infoColumn),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          alignment: WrapAlignment.end,
                          children: [
                            saveBtn,
                            loadBtn,
                            if (deleteBtn != null) deleteBtn,
                          ],
                        ),
                      ],
                    );
                  }

                  return Row(
                    children: [
                      previewThumb,
                      const SizedBox(width: 12),
                      Expanded(child: infoColumn),
                      const SizedBox(width: 8),
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SizedBox(
                            width: deleteBtn != null ? 122 : 72,
                            child: saveBtn,
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              loadBtn,
                              if (deleteBtn != null) ...[
                                const SizedBox(width: 6),
                                deleteBtn,
                              ],
                            ],
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
      ],
    );
  }

  // ==========================================================================
  // ABA GRÁFICOS: backend, resoluções, filtros e toggles estilo PPSSPP
  // ==========================================================================
  Widget _buildGraphicsPanel() {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: _settingsNotifier,
      builder: (context, settings, _) {
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text(
              'Ajustes gráficos aplicados ao motor do jogo. Opções de renderização exigem reiniciar a partida.',
              style: TextStyle(
                fontFamily: 'Rubik',
                fontSize: 11.5,
                color: HydraTokens.textSecondary,
              ),
            ),
            const SizedBox(height: 12),

            // ---------------- Backend de renderização ----------------
            const _GraphicsGroupTitle('Backend de Renderização'),
            const SizedBox(height: 6),
            _GraphicsChipRow<GpuBackend>(
              values: GpuBackend.values,
              selected: settings.gpuBackend,
              labelOf: (v) => v.label,
              onSelected: (v) => _applyGraphicsSetting(
                settings.copyWith(gpuBackend: v),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              settings.gpuBackend.description,
              style: const TextStyle(
                fontFamily: 'Rubik',
                fontSize: 10.5,
                color: HydraTokens.textMuted,
              ),
            ),
            const SizedBox(height: 14),

            // ---------------- Resolução de render ----------------
            const _GraphicsGroupTitle('Resolução de Renderização'),
            const SizedBox(height: 6),
            _GraphicsChipRow<RenderResolutionPreset>(
              values: RenderResolutionPreset.values,
              selected: settings.renderResolution,
              labelOf: (v) => v.label,
              onSelected: (v) => _applyGraphicsSetting(
                settings.copyWith(renderResolution: v),
              ),
            ),
            const SizedBox(height: 14),

            // ---------------- Resolução da tela ----------------
            const _GraphicsGroupTitle('Resolução da Tela'),
            const SizedBox(height: 6),
            _GraphicsChipRow<ScreenResolutionScale>(
              values: ScreenResolutionScale.values,
              selected: settings.screenResolution,
              labelOf: (v) => v.label,
              onSelected: (v) => _applyGraphicsSetting(
                settings.copyWith(screenResolution: v),
              ),
            ),
            const SizedBox(height: 14),

            // ---------------- MSAA ----------------
            const _GraphicsGroupTitle('MSAA (Anti-Aliasing)'),
            const SizedBox(height: 6),
            _GraphicsChipRow<MsaaLevel>(
              values: MsaaLevel.values,
              selected: settings.msaaLevel,
              labelOf: (v) => v.label,
              onSelected: (v) => _applyGraphicsSetting(
                settings.copyWith(msaaLevel: v),
              ),
            ),
            const SizedBox(height: 14),

            // ---------------- Filtro de textura ----------------
            const _GraphicsGroupTitle('Filtragem de Textura'),
            const SizedBox(height: 6),
            _GraphicsChipRow<TextureFilterMode>(
              values: TextureFilterMode.values,
              selected: settings.textureFilter,
              labelOf: (v) => v.label,
              onSelected: (v) => _applyGraphicsSetting(
                settings.copyWith(textureFilter: v),
              ),
            ),
            const SizedBox(height: 16),

            // ---------------- Toggles ----------------
            const _GraphicsGroupTitle('Efeitos e Desempenho'),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Substituir Texturas',
              subtitle: 'Permite packs de textura HD do core',
              value: settings.textureReplacement,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(textureReplacement: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Flare de Luz da Lente',
              subtitle: 'Efeito de clarão nas fontes de luz',
              value: settings.lensFlare,
              onChanged: (v) =>
                  _applyGraphicsSetting(settings.copyWith(lensFlare: v)),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Ignorar Leituras da GPU',
              subtitle: 'Melhora muito o FPS (pode causar glitches visuais)',
              value: settings.skipGpuReadbacks,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(skipGpuReadbacks: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Cache de Textura Preguiçoso',
              subtitle: 'Atualização de texturas mais rápida e eficiente',
              value: settings.lazyTextureCache,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(lazyTextureCache: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Duplicar Frames a 60Hz',
              subtitle: 'Jogos a 30fps entregam imagem mais fluida',
              value: settings.frameDuplication,
              onChanged: (v) => _applyAndSaveSettings(
                settings.copyWith(frameDuplication: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Transformação por Hardware',
              subtitle: 'Vertex shader na GPU (desligue se houver glitches)',
              value: settings.hardwareTransform,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(hardwareTransform: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Skinning por Software',
              subtitle: 'Deformação de malha na CPU (mais compatível)',
              value: settings.softwareSkinning,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(softwareSkinning: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Filtragem Anisotrópica',
              subtitle: 'Texturas nítidas em ângulos rasos (custa FPS)',
              value: settings.anisotropicFiltering,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(anisotropicFiltering: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Deposterize de Textura',
              subtitle: 'Remove posterização de gradientes de cor',
              value: settings.textureDeposterize,
              onChanged: (v) => _applyGraphicsSetting(
                settings.copyWith(textureDeposterize: v),
              ),
            ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // ABA 2 DA SIDEBAR: CONTROLE GAMEPAD TOUCH & FÍSICO
  // ==========================================================================
  Widget _buildGamepadEditorPanel() {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: _settingsNotifier,
      builder: (context, settings, _) {
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Semantics(
              button: true,
              label: 'Mover e editar botões na tela',
              child: Tooltip(
                message: 'Entrar no modo de edição visual dos controles',
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () {
                      setState(() {
                        _isSidebarOpen = false;
                        _isDraggingGamepad = true;
                      });
                      _showToast(
                        'Arraste ou dê um toque no botão para customizá-lo',
                      );
                    },
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.handTap(PhosphorIconsStyle.bold),
                              size: 16,
                              color: Colors.black,
                            ),
                            const SizedBox(width: 8),
                            const Flexible(
                              child: Text(
                                'Mover e Editar Botões na Tela',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black,
                                ),
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
            const SizedBox(height: 10),
            Semantics(
              button: true,
              label: 'Resetar gamepad para o padrão',
              child: Tooltip(
                message: 'Restaurar posição e estilo originais do controle',
                child: Material(
                  color: HydraTokens.surfaceElevated1,
                  borderRadius: BorderRadius.circular(9),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(9),
                    onTap: () {
                      _applyAndSaveSettings(settings.resetGamepadLayout());
                      _showToast('Gamepad restaurado para o padrão');
                    },
                    child: Container(
                      constraints: const BoxConstraints(minHeight: 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: HydraTokens.borderSubtle10),
                      ),
                      alignment: Alignment.center,
                      child: const Text(
                        'Resetar Gamepad para o Padrão',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: HydraTokens.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
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
                    PhosphorIcons.cursorClick(PhosphorIconsStyle.bold),
                    size: 18,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Toque no botão acima para ver seus botões em tamanho real. No modo de edição, arraste para mover e dê um toque em qualquer botão (L/R, D-Pad, Ações) para mudar tamanho, opacidade e estilo ao vivo!',
                      style: TextStyle(
                        fontFamily: 'Rubik',
                        fontSize: 11.5,
                        height: 1.4,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Visibilidade do Controle na Tela:',
              style: TextStyle(
                fontFamily: 'ReadexPro',
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: HydraTokens.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              constraints: const BoxConstraints(minHeight: 48),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                color: HydraTokens.surfaceCatalog,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: HydraTokens.borderSubtle10),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<TouchOverlayMode>(
                  value: settings.touchOverlayMode,
                  isExpanded: true,
                  dropdownColor: HydraTokens.surfaceElevated1,
                  borderRadius: BorderRadius.circular(10),
                  icon: PhosphorIcon(
                    PhosphorIcons.caretDown(PhosphorIconsStyle.bold),
                    size: 14,
                    color: HydraTokens.primaryAurora,
                  ),
                  items: TouchOverlayMode.values.map((mode) {
                    final active = mode == settings.touchOverlayMode;
                    return DropdownMenuItem<TouchOverlayMode>(
                      value: mode,
                      child: Text(
                        mode.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: active
                              ? HydraTokens.primaryAurora
                              : HydraTokens.textPrimary,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (mode) {
                    if (mode != null) {
                      _applyAndSaveSettings(
                        settings.copyWith(touchOverlayMode: mode),
                      );
                    }
                  },
                ),
              ),
            ),
            const SizedBox(height: 12),
            _CompactSwitchRow(
              title: 'Vibração Tátil ao Tocar',
              subtitle: 'Feedback háptico nos botões virtuais',
              value: settings.hapticVibration,
              onChanged: (v) => _applyAndSaveSettings(
                settings.copyWith(hapticVibration: v),
              ),
            ),
            const SizedBox(height: 6),
            _CompactSwitchRow(
              title: 'Perfil Exclusivo deste Jogo',
              subtitle:
                  'Salva este layout customizado apenas para este jogo',
              value: _isGameSpecificProfile,
              onChanged: (v) async {
                setState(() => _isGameSpecificProfile = v);
                final profiles = await _settingsStorage.loadGameProfiles();
                if (v) {
                  profiles[widget.game.igdbId] = _settings;
                  await _settingsStorage.saveGameProfiles(profiles);
                  if (mounted) {
                    _showToast(
                      'Perfil exclusivo ativado para ${widget.game.name}',
                    );
                  }
                } else {
                  profiles.remove(widget.game.igdbId);
                  await _settingsStorage.saveGameProfiles(profiles);
                  if (mounted) {
                    _showToast('Usando configurações globais');
                  }
                }
              },
            ),
          ],
        );
      },
    );
  }

  // ==========================================================================
  // ABA 3 DA SIDEBAR: CONFIGURAR INFORMAÇÕES NA TELA (FPS, 3X, PSP, MS)
  // ==========================================================================
  Widget _buildHudConfigPanel() {
    return ValueListenableBuilder<AppSettings>(
      valueListenable: _settingsNotifier,
      builder: (context, settings, _) {
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            const Text(
              'Escolha quais informações aparecem na barra superior durante o jogo:',
              style: TextStyle(
                fontFamily: 'Rubik',
                fontSize: 12,
                color: HydraTokens.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            LoopHudToggleGroup(
              settings: settings,
              compact: true,
              onChanged: _applyAndSaveSettings,
            ),
          ],
        );
      },
    );
  }

  Future<void> _openElementCustomizer(_GamepadEditTarget target) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.92),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                border: const Border(
                  top: BorderSide(color: Colors.white24, width: 1.5),
                ),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: ValueListenableBuilder<AppSettings>(
                  valueListenable: _settingsNotifier,
                  builder: (_, settings, __) {
                    double currentScale;
                    double currentOpacity;
                    double? currentSpacing;

                    switch (target) {
                      case _GamepadEditTarget.global:
                        currentScale = settings.gamepadScale;
                        currentOpacity = settings.gamepadOpacity;
                        currentSpacing = null;
                        break;
                      case _GamepadEditTarget.shoulders:
                        currentScale = settings.shoulderScale;
                        currentOpacity = settings.shoulderOpacity;
                        currentSpacing = settings.shoulderSpacing;
                        break;
                      case _GamepadEditTarget.dpad:
                        currentScale = settings.dpadScale;
                        currentOpacity = settings.dpadOpacity;
                        currentSpacing = settings.dpadSpacing;
                        break;
                      case _GamepadEditTarget.stick:
                        currentScale = settings.stickScale;
                        currentOpacity = settings.stickOpacity;
                        currentSpacing = null;
                        break;
                      case _GamepadEditTarget.actions:
                        currentScale = settings.actionScale;
                        currentOpacity = settings.actionOpacity;
                        currentSpacing = settings.actionSpacing;
                        break;
                      case _GamepadEditTarget.selectStart:
                        currentScale = settings.selectStartScale;
                        currentOpacity = settings.selectStartOpacity;
                        currentSpacing = settings.selectStartSpacing;
                        break;
                    }

                    final title = switch (target) {
                      _GamepadEditTarget.global => 'Controles Gerais',
                      _GamepadEditTarget.shoulders =>
                        _shouldUseSingleShoulderTriggers(settings)
                            ? 'Gatilhos L & R (Adaptado)'
                            : 'Gatilhos L1, L2, R1, R2',
                      _GamepadEditTarget.dpad => 'Direcional D-Pad',
                      _GamepadEditTarget.stick => 'Alavanca Analógica',
                      _GamepadEditTarget.actions =>
                        'Botões de Ação (A, B, X, Y)',
                      _GamepadEditTarget.selectStart =>
                        'Botões Select & Start',
                    };

                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            PhosphorIcon(
                              PhosphorIcons.slidersHorizontal(
                                PhosphorIconsStyle.bold,
                              ),
                              size: 16,
                              color: Colors.white,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            _DoneSheetButton(
                              onTap: () => Navigator.of(ctx).pop(),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        // Slider de Tamanho
                        Row(
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                'Tamanho: ${(currentScale * 100).round()}%',
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: currentScale.clamp(0.60, 1.50),
                                min: 0.60,
                                max: 1.50,
                                activeColor: Colors.white,
                                onChanged: (v) {
                                  final next = switch (target) {
                                    _GamepadEditTarget.global =>
                                      settings.copyWith(gamepadScale: v),
                                    _GamepadEditTarget.shoulders =>
                                      settings.copyWith(shoulderScale: v),
                                    _GamepadEditTarget.dpad =>
                                      settings.copyWith(dpadScale: v),
                                    _GamepadEditTarget.stick =>
                                      settings.copyWith(stickScale: v),
                                    _GamepadEditTarget.actions =>
                                      settings.copyWith(actionScale: v),
                                    _GamepadEditTarget.selectStart =>
                                      settings.copyWith(selectStartScale: v),
                                  };
                                  _scheduleDebouncedOverlayUpdate(next);
                                },
                              ),
                            ),
                          ],
                        ),
                        // Slider de Opacidade
                        Row(
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                'Opacidade: ${(currentOpacity * 100).round()}%',
                                style: const TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Slider(
                                value: currentOpacity.clamp(0.15, 1.0),
                                min: 0.15,
                                max: 1.0,
                                activeColor: Colors.white,
                                onChanged: (v) {
                                  final next = switch (target) {
                                    _GamepadEditTarget.global =>
                                      settings.copyWith(gamepadOpacity: v),
                                    _GamepadEditTarget.shoulders =>
                                      settings.copyWith(shoulderOpacity: v),
                                    _GamepadEditTarget.dpad =>
                                      settings.copyWith(dpadOpacity: v),
                                    _GamepadEditTarget.stick =>
                                      settings.copyWith(stickOpacity: v),
                                    _GamepadEditTarget.actions =>
                                      settings.copyWith(actionOpacity: v),
                                    _GamepadEditTarget.selectStart =>
                                      settings.copyWith(selectStartOpacity: v),
                                  };
                                  _scheduleDebouncedOverlayUpdate(next);
                                },
                              ),
                            ),
                          ],
                        ),
                        // Slider de Espaçamento
                        if (currentSpacing != null)
                          Row(
                            children: [
                              SizedBox(
                                width: 120,
                                child: Text(
                                  'Espaço: ${currentSpacing.round()}px',
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 11,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              Expanded(
                                child: Slider(
                                  value: currentSpacing.clamp(0.0, 32.0),
                                  min: 0.0,
                                  max: 32.0,
                                  activeColor: Colors.white,
                                  onChanged: (v) {
                                    final next = switch (target) {
                                      _GamepadEditTarget.shoulders =>
                                        settings.copyWith(shoulderSpacing: v),
                                      _GamepadEditTarget.dpad =>
                                        settings.copyWith(dpadSpacing: v),
                                      _GamepadEditTarget.actions =>
                                        settings.copyWith(actionSpacing: v),
                                      _GamepadEditTarget.selectStart =>
                                        settings.copyWith(
                                          selectStartSpacing: v,
                                        ),
                                      _ => null,
                                    };
                                    if (next != null) {
                                      _scheduleDebouncedOverlayUpdate(next);
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                        // Se for Shoulders (Gatilhos): Adaptado (L/R) ou Seletor de Formato
                        if (target == _GamepadEditTarget.shoulders) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Formato dos Gatilhos:',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (AppSettings.isSingleTriggerPlatform(
                            widget.game.platformSlug,
                          ))
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 9,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white12,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text(
                                'Gatilho único (L e R) ativo automaticamente para ${widget.game.platformName}.',
                                style: const TextStyle(
                                  fontFamily: 'Rubik',
                                  fontSize: 11,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          else
                            Container(
                              constraints: const BoxConstraints(minHeight: 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white10,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<ShoulderTriggerStyle>(
                                  value: settings.shoulderStyle,
                                  isExpanded: true,
                                  dropdownColor: HydraTokens.surfaceElevated1,
                                  borderRadius: BorderRadius.circular(10),
                                  icon: PhosphorIcon(
                                    PhosphorIcons.caretDown(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  items:
                                      ShoulderTriggerStyle.values.map((st) {
                                    final active =
                                        settings.shoulderStyle == st;
                                    return DropdownMenuItem<
                                        ShoulderTriggerStyle>(
                                      value: st,
                                      child: Text(
                                        st.label,
                                        style: TextStyle(
                                          fontFamily: 'ReadexPro',
                                          fontSize: 11.5,
                                          fontWeight: FontWeight.w700,
                                          color: active
                                              ? HydraTokens.primaryAurora
                                              : Colors.white,
                                        ),
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (st) {
                                    if (st != null) {
                                      _applyAndSaveSettings(
                                        settings.copyWith(shoulderStyle: st),
                                      );
                                    }
                                  },
                                ),
                              ),
                            ),
                        ],
                        // Se for Shoulders, D-pad ou Ações: Estilo Visual dos Botões
                        if (target == _GamepadEditTarget.shoulders ||
                            target == _GamepadEditTarget.dpad ||
                            target == _GamepadEditTarget.actions) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Estilo dos Botões:',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: GamepadButtonStyle.values.map((bs) {
                              final active = settings.buttonStyle == bs;
                              return Semantics(
                                button: true,
                                selected: active,
                                label: 'Estilo ${bs.label}',
                                child: Material(
                                  color: active ? Colors.white : Colors.white12,
                                  borderRadius: BorderRadius.circular(8),
                                  child: InkWell(
                                    borderRadius: BorderRadius.circular(8),
                                    onTap: () => _applyAndSaveSettings(
                                      settings.copyWith(buttonStyle: bs),
                                    ),
                                    child: ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        minWidth: 48,
                                        minHeight: 48,
                                      ),
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 12,
                                        ),
                                        child: Center(
                                          widthFactor: 1.0,
                                          child: Text(
                                            bs.label,
                                            style: TextStyle(
                                              fontFamily: 'ReadexPro',
                                              fontSize: 10.5,
                                              fontWeight: FontWeight.w700,
                                              color: active
                                                  ? Colors.black
                                                  : Colors.white,
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
                        ],
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
    _flushPendingOverlaySave();
  }

  Future<void> _openHudCustomizer() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
            ),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.92),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(20)),
                border: const Border(
                  top: BorderSide(color: Colors.white24, width: 1.5),
                ),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        PhosphorIcon(
                          PhosphorIcons.gauge(PhosphorIconsStyle.bold),
                          size: 16,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Personalizar Informações na Tela (HUD)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 14.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _DoneSheetButton(
                          onTap: () => Navigator.of(ctx).pop(),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<AppSettings>(
                      valueListenable: _settingsNotifier,
                      builder: (_, settings, __) {
                        return LoopHudToggleGroup(
                          settings: settings,
                          compact: true,
                          onChanged: _applyAndSaveSettings,
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _HudTelemetryPill extends StatelessWidget {
  const _HudTelemetryPill({
    required this.settingsListenable,
    required this.telemetryListenable,
    required this.platformName,
    required this.editing,
    required this.onTap,
  });

  final ValueListenable<AppSettings> settingsListenable;
  final ValueListenable<LibretroTelemetryEvent> telemetryListenable;
  final String platformName;
  final bool editing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: editing
          ? 'Editar informações do HUD'
          : 'Abrir menu do emulador e telemetria',
      child: Tooltip(
        message: editing ? 'Editar HUD' : 'Abrir menu do jogo',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            child: Center(
              widthFactor: 1.0,
              child: ValueListenableBuilder<AppSettings>(
                valueListenable: settingsListenable,
                builder: (_, settings, __) {
                  return ValueListenableBuilder<LibretroTelemetryEvent>(
                    valueListenable: telemetryListenable,
                    builder: (_, telemetry, __) {
                      final parts = <String>[];
                      if (settings.showFpsTelemetry) {
                        if (settings.hudShowFps) {
                          parts.add('${telemetry.fps.toStringAsFixed(0)} FPS');
                        }
                        if (settings.hudShowResolution) {
                          parts.add(settings.resolutionLabel);
                        }
                        if (settings.hudShowConsole) {
                          parts.add(platformName);
                        }
                        if (settings.hudShowFrameTime) {
                          parts.add(
                            '${telemetry.frameTimeMs.toStringAsFixed(1)} ms',
                          );
                        }
                      }

                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.62),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: editing
                                ? Colors.white
                                : Colors.white.withOpacity(0.18),
                            width: editing ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PhosphorIcon(
                              editing
                                  ? PhosphorIcons.slidersHorizontal(
                                      PhosphorIconsStyle.bold,
                                    )
                                  : PhosphorIcons.sidebarSimple(
                                      PhosphorIconsStyle.bold,
                                    ),
                              size: 14,
                              color: Colors.white,
                            ),
                            if (parts.isNotEmpty) ...[
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  parts.join(' • '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontFamily: 'JetBrainsMono',
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ],
                            if (editing) ...[
                              const SizedBox(width: 6),
                              const Text(
                                'Editar HUD',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DoneSheetButton extends StatelessWidget {
  const _DoneSheetButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Fechar ajustes',
      child: Tooltip(
        message: 'Concluir',
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 14),
                child: Center(
                  widthFactor: 1.0,
                  child: Text(
                    'Pronto',
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: Colors.black,
                    ),
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

/// Reconstrói apenas o trecho visual dependente de [watchMask], evitando que
/// toques em botões disparem rebuild no player inteiro.
class _MaskSliceBuilder extends StatefulWidget {
  const _MaskSliceBuilder({
    required this.maskListenable,
    required this.watchMask,
    required this.builder,
  });

  final ValueListenable<int> maskListenable;
  final int watchMask;
  final Widget Function(BuildContext context, int slice) builder;

  @override
  State<_MaskSliceBuilder> createState() => _MaskSliceBuilderState();
}

class _MaskSliceBuilderState extends State<_MaskSliceBuilder> {
  late int _slice = widget.maskListenable.value & widget.watchMask;

  @override
  void initState() {
    super.initState();
    widget.maskListenable.addListener(_onMaskChanged);
  }

  @override
  void didUpdateWidget(covariant _MaskSliceBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.maskListenable != widget.maskListenable) {
      oldWidget.maskListenable.removeListener(_onMaskChanged);
      widget.maskListenable.addListener(_onMaskChanged);
    }
    _slice = widget.maskListenable.value & widget.watchMask;
  }

  @override
  void dispose() {
    widget.maskListenable.removeListener(_onMaskChanged);
    super.dispose();
  }

  void _onMaskChanged() {
    final next = widget.maskListenable.value & widget.watchMask;
    if (next != _slice) {
      setState(() => _slice = next);
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _slice);
}

class _SidebarTabButton extends StatelessWidget {
  const _SidebarTabButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Semantics(
        button: true,
        selected: active,
        label: 'Aba $label',
        child: Tooltip(
          message: label,
          child: Material(
            color: active
                ? HydraTokens.primaryAurora
                : HydraTokens.surfaceCatalog,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      PhosphorIcon(
                        icon,
                        size: 13,
                        color: active
                            ? HydraTokens.bgPureBlack
                            : HydraTokens.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: active
                                ? HydraTokens.bgPureBlack
                                : HydraTokens.textPrimary,
                          ),
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

class _CompactSwitchRow extends StatelessWidget {
  const _CompactSwitchRow({
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
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: title,
      hint: subtitle,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Material(
          color: HydraTokens.surfaceCatalog,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: enabled ? () => onChanged!(!value) : null,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: HydraTokens.borderSubtle8),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontFamily: 'ReadexPro',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          style: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 10.5,
                            color: HydraTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: value,
                    activeColor: HydraTokens.primaryAurora,
                    onChanged: onChanged,
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

class _GraphicsGroupTitle extends StatelessWidget {
  const _GraphicsGroupTitle(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        fontFamily: 'ReadexPro',
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: HydraTokens.textPrimary,
      ),
    );
  }
}

class _GraphicsChipRow<T> extends StatelessWidget {
  const _GraphicsChipRow({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: values.map((v) {
        final active = v == selected;
        final label = labelOf(v);
        return Semantics(
          button: true,
          selected: active,
          label: label,
          child: Material(
            color: active ? Colors.white : HydraTokens.surfaceCatalog,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              borderRadius: BorderRadius.circular(9),
              onTap: () => onSelected(v),
              child: Container(
                constraints: const BoxConstraints(
                  minWidth: 48,
                  minHeight: 48,
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: active
                        ? Colors.white
                        : HydraTokens.borderSubtle8,
                  ),
                ),
                child: Center(
                  widthFactor: 1.0,
                  child: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? HydraTokens.bgPureBlack
                          : HydraTokens.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

/// Gatilhos L1/L2 e R1/R2, ou gatilho único L / R em consoles como PSP, GBA e SNES.
class _ShoulderTriggerCluster extends StatelessWidget {
  const _ShoulderTriggerCluster({
    required this.isLeft,
    required this.style,
    required this.buttonStyle,
    required this.spacing,
    this.singleTriggerOnly = false,
    required this.joypadMaskListenable,
    required this.onPrimaryChanged,
    required this.onSecondaryChanged,
  });

  final bool isLeft;
  final ShoulderTriggerStyle style;
  final GamepadButtonStyle buttonStyle;
  final double spacing;
  final bool singleTriggerOnly;
  final ValueListenable<int> joypadMaskListenable;
  final ValueChanged<bool> onPrimaryChanged;
  final ValueChanged<bool> onSecondaryChanged;

  @override
  Widget build(BuildContext context) {
    final primaryBit = isLeft ? RetroJoypadMask.l : RetroJoypadMask.r;
    final secondaryBit = isLeft ? RetroJoypadMask.l2 : RetroJoypadMask.r2;

    return _MaskSliceBuilder(
      maskListenable: joypadMaskListenable,
      watchMask: primaryBit | secondaryBit,
      builder: (_, slice) {
        final primaryActive = (slice & primaryBit) != 0;
        final secondaryActive = (slice & secondaryBit) != 0;

        if (singleTriggerOnly || style == ShoulderTriggerStyle.singleLR) {
          return _PillGamepadButton(
            label: isLeft ? 'L' : 'R',
            style: buttonStyle,
            active: primaryActive,
            largeSingleTrigger: true,
            onChanged: onPrimaryChanged,
          );
        }

        final l1Label = isLeft ? 'L1' : 'R1';
        final l2Label = isLeft ? 'L2' : 'R2';

        if (style == ShoulderTriggerStyle.compactTogether) {
          final firstLabel = isLeft ? l1Label : l2Label;
          final firstActive = isLeft ? primaryActive : secondaryActive;
          final firstCb = isLeft ? onPrimaryChanged : onSecondaryChanged;

          final secondLabel = isLeft ? l2Label : l1Label;
          final secondActive = isLeft ? secondaryActive : primaryActive;
          final secondCb = isLeft ? onSecondaryChanged : onPrimaryChanged;

          return Container(
            decoration: BoxDecoration(
              color: HydraTokens.bgNearBlack.withOpacity(0.76),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withOpacity(0.22)),
            ),
            padding: EdgeInsets.all(spacing.clamp(1.0, 8.0)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _CompactBumperSegment(
                  label: firstLabel,
                  active: firstActive,
                  isLeftSegment: true,
                  onChanged: firstCb,
                ),
                Container(
                  width: 1,
                  height: 24,
                  margin: EdgeInsets.symmetric(
                    horizontal: spacing.clamp(1.0, 8.0),
                  ),
                  color: Colors.white.withOpacity(0.18),
                ),
                _CompactBumperSegment(
                  label: secondLabel,
                  active: secondActive,
                  isLeftSegment: false,
                  onChanged: secondCb,
                ),
              ],
            ),
          );
        }

        if (style == ShoulderTriggerStyle.stackedVertical) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PillGamepadButton(
                label: l2Label,
                style: buttonStyle,
                active: secondaryActive,
                onChanged: onSecondaryChanged,
              ),
              SizedBox(height: spacing.clamp(2.0, 16.0)),
              _PillGamepadButton(
                label: l1Label,
                style: buttonStyle,
                active: primaryActive,
                onChanged: onPrimaryChanged,
              ),
            ],
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PillGamepadButton(
              label: isLeft ? l1Label : l2Label,
              style: buttonStyle,
              active: isLeft ? primaryActive : secondaryActive,
              onChanged: isLeft ? onPrimaryChanged : onSecondaryChanged,
            ),
            SizedBox(width: spacing.clamp(4.0, 24.0)),
            _PillGamepadButton(
              label: isLeft ? l2Label : l1Label,
              style: buttonStyle,
              active: isLeft ? secondaryActive : primaryActive,
              onChanged: isLeft ? onSecondaryChanged : onPrimaryChanged,
            ),
          ],
        );
      },
    );
  }
}

class _CompactBumperSegment extends StatelessWidget {
  const _CompactBumperSegment({
    required this.label,
    required this.active,
    required this.isLeftSegment,
    required this.onChanged,
  });

  final String label;
  final bool active;
  final bool isLeftSegment;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: 'Botão $label',
      child: Listener(
        onPointerDown: (_) => onChanged(true),
        onPointerUp: (_) => onChanged(false),
        onPointerCancel: (_) => onChanged(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.horizontal(
              left: Radius.circular(isLeftSegment ? 11 : 5),
              right: Radius.circular(isLeftSegment ? 5 : 11),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: active ? HydraTokens.bgPureBlack : HydraTokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _DpadClusterWidget extends StatefulWidget {
  const _DpadClusterWidget({
    required this.joypadMaskListenable,
    required this.spacing,
    required this.buttonStyle,
    required this.onDpadBitsChanged,
  });

  final ValueListenable<int> joypadMaskListenable;
  final double spacing;
  final GamepadButtonStyle buttonStyle;
  final void Function(int newDpadMask) onDpadBitsChanged;

  @override
  State<_DpadClusterWidget> createState() => _DpadClusterWidgetState();
}

class _DpadClusterWidgetState extends State<_DpadClusterWidget> {
  static const int _dpadWatchMask = RetroJoypadMask.up |
      RetroJoypadMask.down |
      RetroJoypadMask.left |
      RetroJoypadMask.right;

  int _activeBits = 0;

  void _evalPointer(Offset localPos, double dim) {
    final center = Offset(dim / 2, dim / 2);
    final delta = localPos - center;
    final dist = delta.distance;
    final deadzone = dim * 0.14;

    int bits = 0;
    if (dist >= deadzone) {
      final deg = math.atan2(delta.dy, delta.dx) * 180 / math.pi;
      // Mapeamento contínuo em 8 direções (com diagonais ao deslizar sem soltar)
      if (deg >= -22.5 && deg <= 22.5) {
        bits = RetroJoypadMask.right;
      } else if (deg > 22.5 && deg <= 67.5) {
        bits = RetroJoypadMask.down | RetroJoypadMask.right;
      } else if (deg > 67.5 && deg <= 112.5) {
        bits = RetroJoypadMask.down;
      } else if (deg > 112.5 && deg <= 157.5) {
        bits = RetroJoypadMask.down | RetroJoypadMask.left;
      } else if (deg > 157.5 || deg <= -157.5) {
        bits = RetroJoypadMask.left;
      } else if (deg > -157.5 && deg <= -112.5) {
        bits = RetroJoypadMask.up | RetroJoypadMask.left;
      } else if (deg > -112.5 && deg <= -67.5) {
        bits = RetroJoypadMask.up;
      } else if (deg > -67.5 && deg < -22.5) {
        bits = RetroJoypadMask.up | RetroJoypadMask.right;
      }
    }

    if (_activeBits != bits) {
      _activeBits = bits;
      widget.onDpadBitsChanged(bits);
    }
  }

  void _onRelease() {
    if (_activeBits != 0) {
      _activeBits = 0;
      widget.onDpadBitsChanged(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dim = 152.0 + widget.spacing * 1.6;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _evalPointer(e.localPosition, dim),
      onPointerMove: (e) => _evalPointer(e.localPosition, dim),
      onPointerUp: (_) => _onRelease(),
      onPointerCancel: (_) => _onRelease(),
      child: SizedBox(
        width: dim,
        height: dim,
        child: _MaskSliceBuilder(
          maskListenable: widget.joypadMaskListenable,
          watchMask: _dpadWatchMask,
          builder: (_, slice) {
            final isUp = (slice & RetroJoypadMask.up) != 0;
            final isDown = (slice & RetroJoypadMask.down) != 0;
            final isLeft = (slice & RetroJoypadMask.left) != 0;
            final isRight = (slice & RetroJoypadMask.right) != 0;

            return Stack(
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withOpacity(0.04),
                      border: Border.all(
                        color: Colors.white.withOpacity(0.12),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topCenter,
                  child: _TouchCircleButton(
                    semanticLabel: 'Direcional Cima',
                    icon: PhosphorIcons.caretUp(
                      isUp ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                    ),
                    style: widget.buttonStyle,
                    active: isUp,
                    onChanged: (_) {},
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: _TouchCircleButton(
                    semanticLabel: 'Direcional Baixo',
                    icon: PhosphorIcons.caretDown(
                      isDown
                          ? PhosphorIconsStyle.fill
                          : PhosphorIconsStyle.bold,
                    ),
                    style: widget.buttonStyle,
                    active: isDown,
                    onChanged: (_) {},
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: _TouchCircleButton(
                    semanticLabel: 'Direcional Esquerda',
                    icon: PhosphorIcons.caretLeft(
                      isLeft
                          ? PhosphorIconsStyle.fill
                          : PhosphorIconsStyle.bold,
                    ),
                    style: widget.buttonStyle,
                    active: isLeft,
                    onChanged: (_) {},
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: _TouchCircleButton(
                    semanticLabel: 'Direcional Direita',
                    icon: PhosphorIcons.caretRight(
                      isRight
                          ? PhosphorIconsStyle.fill
                          : PhosphorIconsStyle.bold,
                    ),
                    style: widget.buttonStyle,
                    active: isRight,
                    onChanged: (_) {},
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ActionButtonsClusterWidget extends StatelessWidget {
  const _ActionButtonsClusterWidget({
    required this.joypadMaskListenable,
    required this.spacing,
    required this.buttonStyle,
    required this.onBitChanged,
  });

  final ValueListenable<int> joypadMaskListenable;
  final double spacing;
  final GamepadButtonStyle buttonStyle;
  final void Function(int bit, bool pressed) onBitChanged;

  @override
  Widget build(BuildContext context) {
    final dim = 148.0 + spacing * 1.6;
    final useAbxyLabels = buttonStyle == GamepadButtonStyle.xboxAbxy;

    return SizedBox(
      width: dim,
      height: dim,
      child: Stack(
        children: [
          Align(
            alignment: Alignment.topCenter,
            child: _MaskSliceBuilder(
              maskListenable: joypadMaskListenable,
              watchMask: RetroJoypadMask.x,
              builder: (_, slice) {
                final active = slice != 0;
                return _TouchCircleButton(
                  semanticLabel: useAbxyLabels ? 'Botão Y' : 'Botão Triângulo',
                  textLabel: useAbxyLabels ? 'Y' : null,
                  icon: PhosphorIcons.triangle(
                    active ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                  ),
                  style: buttonStyle,
                  active: active,
                  onChanged: (v) => onBitChanged(RetroJoypadMask.x, v),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _MaskSliceBuilder(
              maskListenable: joypadMaskListenable,
              watchMask: RetroJoypadMask.b,
              builder: (_, slice) {
                final active = slice != 0;
                return _TouchCircleButton(
                  semanticLabel: useAbxyLabels ? 'Botão A' : 'Botão Cruz',
                  textLabel: useAbxyLabels ? 'A' : null,
                  icon: PhosphorIcons.x(PhosphorIconsStyle.bold),
                  style: buttonStyle,
                  active: active,
                  onChanged: (v) => onBitChanged(RetroJoypadMask.b, v),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _MaskSliceBuilder(
              maskListenable: joypadMaskListenable,
              watchMask: RetroJoypadMask.y,
              builder: (_, slice) {
                final active = slice != 0;
                return _TouchCircleButton(
                  semanticLabel: useAbxyLabels ? 'Botão X' : 'Botão Quadrado',
                  textLabel: useAbxyLabels ? 'X' : null,
                  icon: PhosphorIcons.square(
                    active ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                  ),
                  style: buttonStyle,
                  active: active,
                  onChanged: (v) => onBitChanged(RetroJoypadMask.y, v),
                );
              },
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _MaskSliceBuilder(
              maskListenable: joypadMaskListenable,
              watchMask: RetroJoypadMask.a,
              builder: (_, slice) {
                final active = slice != 0;
                return _TouchCircleButton(
                  semanticLabel: useAbxyLabels ? 'Botão B' : 'Botão Círculo',
                  textLabel: useAbxyLabels ? 'B' : null,
                  icon: PhosphorIcons.circle(
                    active ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                  ),
                  style: buttonStyle,
                  active: active,
                  onChanged: (v) => onBitChanged(RetroJoypadMask.a, v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _EditableControlFrame extends StatelessWidget {
  const _EditableControlFrame({
    required this.editing,
    required this.label,
    required this.child,
    this.onTapEdit,
  });

  final bool editing;
  final String label;
  final Widget child;
  final VoidCallback? onTapEdit;

  @override
  Widget build(BuildContext context) {
    if (!editing) return child;
    return Semantics(
      button: true,
      label: 'Ajustar $label',
      child: Tooltip(
        message: 'Arrastar ou tocar para ajustar $label',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTapEdit,
          child: Container(
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.08),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: Colors.white,
                width: 1.5,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  margin: const EdgeInsets.only(bottom: 3),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.slidersHorizontal(
                          PhosphorIconsStyle.bold,
                        ),
                        size: 10,
                        color: Colors.black,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        label,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      ),
                    ],
                  ),
                ),
                child,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FallbackGameplayPreview extends StatelessWidget {
  const _FallbackGameplayPreview({
    required this.game,
    required this.resolutionLabel,
    this.errorMessage,
  });

  final EmulationGame game;
  final String resolutionLabel;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        LoopCoverImage(
          url: game.resolvedHeroBannerUrl,
          fit: BoxFit.cover,
          preset: LoopCoverImagePreset.hero,
        ),
        Container(color: Colors.black.withOpacity(0.45)),
        Center(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              errorMessage ??
                  '${game.name} (${game.platformName} • $resolutionLabel)',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                color: HydraTokens.textPrimary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CrtScanlinePainter extends CustomPainter {
  const _CrtScanlinePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x38000000)
      ..strokeWidth = 1.0;
    for (double y = 0; y < size.height; y += 3.0) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _LcdGridPainter extends CustomPainter {
  const _LcdGridPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x22000000)
      ..strokeWidth = 0.8;
    for (double y = 0; y < size.height; y += 4.0) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    for (double x = 0; x < size.width; x += 4.0) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _VirtualAnalogStick extends StatelessWidget {
  const _VirtualAnalogStick({
    required this.stickListenable,
    required this.enabled,
    required this.onStickChanged,
  });

  final ValueListenable<Offset> stickListenable;
  final bool enabled;
  final void Function(double x, double y) onStickChanged;

  @override
  Widget build(BuildContext context) {
    const double size = 102.0;
    const double maxRadius = 33.0;

    return Semantics(
      label: 'Alavanca analógica virtual',
      child: GestureDetector(
        onPanUpdate: enabled
            ? (details) {
                final local =
                    details.localPosition - const Offset(size / 2, size / 2);
                final dist = local.distance;
                final clamped = dist > maxRadius
                    ? Offset.fromDirection(local.direction, maxRadius)
                    : local;
                onStickChanged(clamped.dx / maxRadius, clamped.dy / maxRadius);
              }
            : null,
        onPanEnd: enabled ? (_) => onStickChanged(0.0, 0.0) : null,
        onPanCancel: enabled ? () => onStickChanged(0.0, 0.0) : null,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: HydraTokens.bgNearBlack.withOpacity(0.68),
            border: Border.all(color: Colors.white.withOpacity(0.22)),
          ),
          child: Center(
            child: RepaintBoundary(
              child: ValueListenableBuilder<Offset>(
                valueListenable: stickListenable,
                builder: (_, vector, __) {
                  final active = vector.dx != 0 || vector.dy != 0;
                  return Transform.translate(
                    offset: Offset(
                      vector.dx * maxRadius,
                      vector.dy * maxRadius,
                    ),
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: active ? Colors.white : HydraTokens.surfaceElevated2,
                        border: Border.all(
                          color: Colors.white.withOpacity(0.55),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TouchCircleButton extends StatelessWidget {
  const _TouchCircleButton({
    required this.icon,
    required this.style,
    required this.active,
    required this.onChanged,
    this.textLabel,
    this.semanticLabel,
  });

  final IconData icon;
  final GamepadButtonStyle style;
  final bool active;
  final ValueChanged<bool> onChanged;
  final String? textLabel;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final isMinimal = style == GamepadButtonStyle.minimalOutline;

    return Semantics(
      button: true,
      label: semanticLabel ?? textLabel ?? 'Botão de controle',
      child: Listener(
        onPointerDown: (_) => onChanged(true),
        onPointerUp: (_) => onChanged(false),
        onPointerCancel: (_) => onChanged(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          width: 50,
          height: 50,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active
                ? Colors.white
                : isMinimal
                    ? Colors.black.withOpacity(0.25)
                    : HydraTokens.bgNearBlack.withOpacity(0.75),
            border: Border.all(
              color: active
                  ? Colors.white
                  : Colors.white.withOpacity(isMinimal ? 0.42 : 0.22),
              width: isMinimal ? 1.4 : 1.0,
            ),
          ),
          child: Center(
            child: textLabel != null
                ? Text(
                    textLabel!,
                    style: TextStyle(
                      fontFamily: 'ReadexPro',
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: active
                          ? HydraTokens.bgPureBlack
                          : HydraTokens.textPrimary,
                    ),
                  )
                : PhosphorIcon(
                    icon,
                    size: 19,
                    color: active
                        ? HydraTokens.bgPureBlack
                        : HydraTokens.textPrimary,
                  ),
          ),
        ),
      ),
    );
  }
}

class _PillGamepadButton extends StatelessWidget {
  const _PillGamepadButton({
    required this.label,
    required this.style,
    required this.active,
    required this.onChanged,
    this.largeSingleTrigger = false,
  });

  final String label;
  final GamepadButtonStyle style;
  final bool active;
  final ValueChanged<bool> onChanged;
  final bool largeSingleTrigger;

  @override
  Widget build(BuildContext context) {
    final isMinimal = style == GamepadButtonStyle.minimalOutline;

    return Semantics(
      button: true,
      label: 'Botão $label',
      child: Listener(
        onPointerDown: (_) => onChanged(true),
        onPointerUp: (_) => onChanged(false),
        onPointerCancel: (_) => onChanged(false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          padding: EdgeInsets.symmetric(
            horizontal: largeSingleTrigger ? 22 : 13,
            vertical: largeSingleTrigger ? 10 : 6.5,
          ),
          decoration: BoxDecoration(
            color: active
                ? Colors.white
                : isMinimal
                    ? Colors.black.withOpacity(0.25)
                    : HydraTokens.bgNearBlack.withOpacity(0.72),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: active ? Colors.white : Colors.white.withOpacity(0.22),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: largeSingleTrigger ? 13 : 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: active ? HydraTokens.bgPureBlack : HydraTokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}

class _SelectPillButton extends StatefulWidget {
  const _SelectPillButton({
    required this.style,
    required this.active,
    required this.onChanged,
    required this.onFastForward,
  });

  final GamepadButtonStyle style;
  final bool active;
  final ValueChanged<bool> onChanged;
  final ValueChanged<bool> onFastForward;

  @override
  State<_SelectPillButton> createState() => _SelectPillButtonState();
}

class _SelectPillButtonState extends State<_SelectPillButton> {
  Timer? _holdTimer;
  bool _isFastForwarding = false;

  void _onPointerDown() {
    widget.onChanged(true);
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 320), () {
      if (mounted) {
        setState(() => _isFastForwarding = true);
        widget.onFastForward(true);
      }
    });
  }

  void _onPointerUp() {
    _holdTimer?.cancel();
    if (_isFastForwarding) {
      if (mounted) setState(() => _isFastForwarding = false);
      widget.onFastForward(false);
    }
    widget.onChanged(false);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMinimal = widget.style == GamepadButtonStyle.minimalOutline;

    return Semantics(
      button: true,
      label: 'Botão SELECT (segure para avanço rápido 2x)',
      child: Listener(
        onPointerDown: (_) => _onPointerDown(),
        onPointerUp: (_) => _onPointerUp(),
        onPointerCancel: (_) => _onPointerUp(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 70),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6.5),
          decoration: BoxDecoration(
            color: _isFastForwarding
                ? Colors.white
                : widget.active
                    ? Colors.white
                    : isMinimal
                        ? Colors.black.withOpacity(0.25)
                        : HydraTokens.bgNearBlack.withOpacity(0.72),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _isFastForwarding
                  ? Colors.white
                  : widget.active
                      ? Colors.white
                      : isMinimal
                          ? Colors.white.withOpacity(0.65)
                          : Colors.white.withOpacity(0.22),
              width: isMinimal || _isFastForwarding ? 1.5 : 1.0,
            ),
          ),
          child: Text(
            _isFastForwarding ? '2x FF' : 'SELECT',
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _isFastForwarding
                  ? Colors.black
                  : widget.active
                      ? HydraTokens.bgPureBlack
                      : Colors.white,
            ),
          ),
        ),
      ),
    );
  }
}
