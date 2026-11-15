import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;
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

enum _SidebarSection {
  saves,
  graphics,
  gamepad,
  hudInfo,
}

enum _GamepadEditTarget {
  global('Todos'),
  shoulders('L1/L2 & R1/R2'),
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
  late AppSettings _settings = widget.initialSettings;
  int? _textureId;
  int _joypadMask = 0;
  int _lastSentMask = 0;
  int _lastSentStickX = 0;
  int _lastSentStickY = 0;
  double _stickX = 0.0;
  double _stickY = 0.0;
  double _coreDownloadProgress = 0.0;
  bool _isPreparingCore = true;

  bool _isSidebarOpen = false;
  bool _isDraggingGamepad = false;
  _SidebarSection _sidebarSection = _SidebarSection.saves;

  List<SaveStateSlotInfo> _saveSlots = const [];
  Uint8List? _lastCapturedPreviewPng;
  String? _toastBanner;
  Timer? _toastTimer;
  String? _errorMessage;

  LibretroTelemetryEvent _telemetry = const LibretroTelemetryEvent(
    fps: 60.0,
    frameTimeMs: 16.6,
    frameWidth: 480,
    frameHeight: 272,
    coreName: 'Console',
  );
  StreamSubscription<LibretroTelemetryEvent>? _telemetrySub;
  StreamSubscription<void>? _gamepadSub;

  final DateTime _sessionStartTime = DateTime.now();
  bool _isGameSpecificProfile = false;
  bool _isFastForwardActive = false;
  bool _isHardwareGamepadActive = false;

  bool get _shouldShowTouchOverlay {
    switch (_settings.touchOverlayMode) {
      case TouchOverlayMode.alwaysShow:
        return true;
      case TouchOverlayMode.alwaysHide:
        return false;
      case TouchOverlayMode.auto:
        return !_isHardwareGamepadActive;
    }
  }

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    _gamepadSub = widget.emulatorService.hardwareGamepadStream.listen((_) {
      if (mounted && !_isHardwareGamepadActive) {
        setState(() => _isHardwareGamepadActive = true);
      }
    });
    _bootLibretroSession();
  }

  @override
  void dispose() {
    _toastTimer?.cancel();
    _telemetrySub?.cancel();
    _gamepadSub?.cancel();
    widget.emulatorService.stopSession();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    if (!mounted) return;
    setState(() => _toastBanner = message);
    _toastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _toastBanner = null);
      }
    });
  }

  void _setFastForward(bool active) {
    if (_isFastForwardActive == active) return;
    setState(() => _isFastForwardActive = active);
    widget.emulatorService.setFastForward(
      active ? 2.0 : 1.0,
    );
    if (active) {
      HapticFeedback.lightImpact();
      _showToast('Avanço Rápido 2x');
    }
  }

  void _updateDpadBits(int dpadBits) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    const dpadClear = RetroJoypadMask.up |
        RetroJoypadMask.down |
        RetroJoypadMask.left |
        RetroJoypadMask.right;
    final prev = _joypadMask;
    _joypadMask = (_joypadMask & ~dpadClear) | (dpadBits & dpadClear);
    if (_joypadMask == prev) return;
    if (dpadBits != 0 && _settings.hapticVibration) {
      HapticFeedback.selectionClick();
    }
    _syncInputToCore();
    setState(() {});
  }

  void _applyAndSaveSettings(AppSettings next) {
    setState(() => _settings = next);
    if (_isGameSpecificProfile) {
      final storage = SettingsStorageService();
      storage.loadGameProfiles().then((profiles) {
        profiles[widget.game.igdbId] = next;
        storage.saveGameProfiles(profiles);
      });
    } else {
      widget.onSettingsChanged(next);
    }
    widget.emulatorService.setAudioConfig(
      enabled: next.audioEnabled,
      volume: next.masterVolume,
    );
    widget.emulatorService.setPerformanceConfig(
      frameSkip: next.frameSkip,
      vsyncEnabled: next.vsyncEnabled,
      frameDup: next.frameDuplication,
    );
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
      final ctx = _viewportRepaintKey.currentContext;
      if (ctx == null) return _lastCapturedPreviewPng;
      final boundary = ctx.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return _lastCapturedPreviewPng;
      final image = await boundary.toImage(pixelRatio: 0.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        _lastCapturedPreviewPng = byteData.buffer.asUint8List();
        return _lastCapturedPreviewPng;
      }
    } catch (_) {}
    return _lastCapturedPreviewPng;
  }

  Future<void> _openSidebar([_SidebarSection? section]) async {
    await _captureViewportPreviewPng();
    await _refreshSaveSlots();
    setState(() {
      if (section != null) _sidebarSection = section;
      _isSidebarOpen = true;
      _isDraggingGamepad = false;
    });
    await widget.emulatorService.setPaused(true);
  }

  Future<void> _closeSidebarAndResume() async {
    setState(() {
      _isSidebarOpen = false;
      _isDraggingGamepad = false;
    });
    await widget.emulatorService.setPaused(false);
  }

  Future<void> _bootLibretroSession() async {
    final storage = SettingsStorageService();
    try {
      final profiles = await storage.loadGameProfiles();
      if (profiles.containsKey(widget.game.igdbId)) {
        _settings = profiles[widget.game.igdbId]!;
        _isGameSpecificProfile = true;
      }
    } catch (_) {}

    await _refreshSaveSlots();

    _telemetrySub = widget.emulatorService.telemetryStream.listen((evt) {
      if (mounted && !_isSidebarOpen) {
        setState(() => _telemetry = evt);
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
        coreOptions:
            widget.game.platformSlug.toLowerCase() == 'psp'
                ? _settings.libretroCoreOptions
                : null,
        onCoreDownloadProgress: (p) {
          if (mounted) {
            setState(() => _coreDownloadProgress = p);
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
    if (_textureId != null &&
        _errorMessage == null &&
        _settings.autoLoadOnStart &&
        _saveSlots.isNotEmpty &&
        _saveSlots.first.exists) {
      await widget.emulatorService.loadState(0, romPath: widget.romPath);
      _showToast('Save carregado automaticamente');
    }
  }

  Future<void> _handleSaveToSlot(int slot) async {
    final preview = await _captureViewportPreviewPng();
    await widget.emulatorService.saveState(
      slot,
      romPath: widget.romPath,
      gameTitle: widget.game.name,
      previewPngBytes: preview,
    );
    await _refreshSaveSlots();
    final label = slot == 0 ? 'Quick Save' : 'Slot $slot';
    _showToast('Salvo em $label (${widget.game.name})');
  }

  Future<void> _handleLoadFromSlot(int slot) async {
    final ok = await widget.emulatorService.loadState(
      slot,
      romPath: widget.romPath,
    );
    if (ok) {
      await _closeSidebarAndResume();
      final label = slot == 0 ? 'Quick Save' : 'Slot $slot';
      _showToast('Carregado de $label');
    } else {
      _showToast('Este slot está vazio');
    }
  }

  Future<void> _handleDeleteSlot(int slot) async {
    await widget.emulatorService.deleteSaveState(
      slot,
      romPath: widget.romPath,
    );
    await _refreshSaveSlots();
    _showToast('Save removido');
  }

  /// Sai do jogo: só salva automaticamente se o usuário tiver ativado explicitamente!
  /// Por padrão, NÃO força auto-save para não atrapalhar jogos de luta/arcade.
  Future<void> _exitPlayerToLibrary() async {
    final elapsed = DateTime.now().difference(_sessionStartTime).inSeconds;
    if (elapsed > 0) {
      try {
        final storage = SettingsStorageService();
        final UserLibraryMeta meta = await storage.loadUserMeta();
        final updated = meta.recordSession(widget.game.igdbId, elapsed, DateTime.now());
        await storage.saveUserMeta(updated);
      } catch (_) {}
    }
    if (_settings.autoSaveOnExit) {
      final preview = await _captureViewportPreviewPng();
      await widget.emulatorService.saveState(
        0,
        romPath: widget.romPath,
        gameTitle: widget.game.name,
        previewPngBytes: preview,
      );
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _syncInputToCore() {
    final qx = (_stickX * 32767).round();
    final qy = (_stickY * 32767).round();
    if (_joypadMask == _lastSentMask &&
        qx == _lastSentStickX &&
        qy == _lastSentStickY) {
      return;
    }
    _lastSentMask = _joypadMask;
    _lastSentStickX = qx;
    _lastSentStickY = qy;

    widget.emulatorService.sendInputState(
      joypadMask: _joypadMask,
      leftStickX: _stickX,
      leftStickY: _stickY,
    );
  }

  void _updateButtonBit(int maskBit, bool pressed) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    final prev = _joypadMask;
    if (pressed) {
      _joypadMask |= maskBit;
    } else {
      _joypadMask &= ~maskBit;
    }
    if (_joypadMask == prev) return;
    if (pressed && _settings.hapticVibration) {
      HapticFeedback.selectionClick();
    }
    _syncInputToCore();
    setState(() {});
  }

  void _updateAnalogVector(double nx, double ny) {
    if (_isDraggingGamepad || _isSidebarOpen) return;
    _stickX = nx.clamp(-1.0, 1.0);
    _stickY = ny.clamp(-1.0, 1.0);
    _syncInputToCore();
    setState(() {});
  }

  double _resolveTargetAspectRatio(Size screen) {
    switch (_settings.aspectRatio) {
      case AspectRatioPreset.widescreen169:
        return 16.0 / 9.0;
      case AspectRatioPreset.fullScreen:
        return screen.width / math.max(1.0, screen.height);
      case AspectRatioPreset.consoleOriginal:
        return _telemetry.frameWidth / math.max(1, _telemetry.frameHeight);
    }
  }

  List<String> _buildHudBadges() {
    if (!_settings.showFpsTelemetry) return const [];
    final List<String> parts = [];
    if (_settings.hudShowFps) {
      parts.add('${_telemetry.fps.toStringAsFixed(0)} FPS');
    }
    if (_settings.hudShowResolution) {
      parts.add(_settings.resolutionLabel);
    }
    if (_settings.hudShowConsole) {
      parts.add(widget.game.platformName);
    }
    if (_settings.hudShowFrameTime) {
      parts.add('${_telemetry.frameTimeMs.toStringAsFixed(1)} ms');
    }
    return parts;
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.sizeOf(context);
    final aspect = _resolveTargetAspectRatio(screenSize);
    final filterQuality =
        _settings.videoFilter == VideoFilterPreset.smoothBilinear
            ? FilterQuality.medium
            : FilterQuality.none;
    final hudParts = _buildHudBadges();

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Ao pressionar Voltar no celular: abre ou fecha a Sidebar estilo PPSSPP/GameHub!
        if (_isDraggingGamepad) {
          setState(() {
            _isDraggingGamepad = false;
            _isSidebarOpen = true;
          });
        } else if (_isSidebarOpen) {
          _closeSidebarAndResume();
        } else {
          _openSidebar();
        }
      },
      child: Scaffold(
        backgroundColor: HydraTokens.bgPureBlack,
        body: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            if (_isHardwareGamepadActive) {
              setState(() => _isHardwareGamepadActive = false);
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
                  child: AspectRatio(
                    aspectRatio: aspect,
                    child: Container(
                      color: HydraTokens.bgPureBlack,
                      child: _isPreparingCore
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CircularProgressIndicator(
                                    color: HydraTokens.primaryAurora,
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    'Iniciando ${widget.game.platformName} (${(_coreDownloadProgress * 100).toStringAsFixed(0)}%)',
                                    style: const TextStyle(
                                      fontFamily: 'JetBrainsMono',
                                      fontSize: 12,
                                      color: HydraTokens.textPrimary,
                                    ),
                                  ),
                                ],
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
                                    resolutionLabel: _settings.resolutionLabel,
                                    errorMessage: _errorMessage,
                                  ),
                                if (_settings.videoFilter ==
                                    VideoFilterPreset.crtScanlines)
                                  const IgnorePointer(
                                    child: CustomPaint(
                                      painter: _CrtScanlinePainter(),
                                    ),
                                  ),
                                if (_settings.videoFilter ==
                                    VideoFilterPreset.lcdHandheld)
                                  const IgnorePointer(
                                    child: CustomPaint(
                                      painter: _LcdGridPainter(),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 2. HUD DISCRETO E CONFIGURÁVEL (FPS, ms, escala, console)
              // ==============================================================
              Positioned(
                top: 8,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: () {
                      if (_isDraggingGamepad) {
                        _openHudCustomizer();
                      } else {
                        _openSidebar();
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.62),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isDraggingGamepad
                              ? Colors.white
                              : Colors.white.withOpacity(0.18),
                          width: _isDraggingGamepad ? 1.5 : 1.0,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          PhosphorIcon(
                            _isDraggingGamepad
                                ? PhosphorIcons.slidersHorizontal(
                                    PhosphorIconsStyle.bold,
                                  )
                                : PhosphorIcons.sidebarSimple(
                                    PhosphorIconsStyle.bold,
                                  ),
                            size: 14,
                            color: Colors.white,
                          ),
                          if (hudParts.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              hudParts.join(' • '),
                              style: const TextStyle(
                                fontFamily: 'JetBrainsMono',
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                          if (_isDraggingGamepad) ...[
                            const SizedBox(width: 6),
                            const Text(
                              '⚙️ Editar HUD',
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 3. CONTROLES TOUCH NA TELA (AUTO-HIDE SE GAMEPAD FÍSICO CONECTAR)
              // ==============================================================
              if (_shouldShowTouchOverlay) ...[
              // ==============================================================
              // 3. GATILHOS L1/L2 & R1/R2 COMPACTOS JUNTOS (OU ESTILO ESCOLHIDO)
              // ==============================================================
              Positioned(
                left: 20,
                top: _settings.shoulderTop,
                child: GestureDetector(
                  onPanUpdate: _isDraggingGamepad
                      ? (d) => _applyAndSaveSettings(
                            _settings.copyWith(
                              shoulderTop: (_settings.shoulderTop + d.delta.dy)
                                  .clamp(10.0, 190.0),
                            ),
                          )
                      : null,
                  child: _EditableControlFrame(
                    editing: _isDraggingGamepad,
                    label: 'Gatilhos L1 / L2',
                    onTapEdit: () =>
                        _openElementCustomizer(_GamepadEditTarget.shoulders),
                    child: Opacity(
                      opacity: (_settings.gamepadOpacity *
                              _settings.shoulderOpacity)
                          .clamp(0.15, 1.0),
                      child: Transform.scale(
                        scale:
                            _settings.gamepadScale * _settings.shoulderScale,
                        alignment: Alignment.topLeft,
                        child: _ShoulderTriggerCluster(
                          isLeft: true,
                          style: _settings.shoulderStyle,
                          buttonStyle: _settings.buttonStyle,
                          spacing: _settings.shoulderSpacing,
                          primaryActive:
                              (_joypadMask & RetroJoypadMask.l) != 0,
                          secondaryActive:
                              (_joypadMask & RetroJoypadMask.l2) != 0,
                          onPrimaryChanged: (v) =>
                              _updateButtonBit(RetroJoypadMask.l, v),
                          onSecondaryChanged: (v) =>
                              _updateButtonBit(RetroJoypadMask.l2, v),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                right: 20,
                top: _settings.shoulderTop,
                child: GestureDetector(
                  onPanUpdate: _isDraggingGamepad
                      ? (d) => _applyAndSaveSettings(
                            _settings.copyWith(
                              shoulderTop: (_settings.shoulderTop + d.delta.dy)
                                  .clamp(10.0, 190.0),
                            ),
                          )
                      : null,
                  child: _EditableControlFrame(
                    editing: _isDraggingGamepad,
                    label: 'Gatilhos R1 / R2',
                    onTapEdit: () =>
                        _openElementCustomizer(_GamepadEditTarget.shoulders),
                    child: Opacity(
                      opacity: (_settings.gamepadOpacity *
                              _settings.shoulderOpacity)
                          .clamp(0.15, 1.0),
                      child: Transform.scale(
                        scale:
                            _settings.gamepadScale * _settings.shoulderScale,
                        alignment: Alignment.topRight,
                        child: _ShoulderTriggerCluster(
                          isLeft: false,
                          style: _settings.shoulderStyle,
                          buttonStyle: _settings.buttonStyle,
                          spacing: _settings.shoulderSpacing,
                          primaryActive:
                              (_joypadMask & RetroJoypadMask.r) != 0,
                          secondaryActive:
                              (_joypadMask & RetroJoypadMask.r2) != 0,
                          onPrimaryChanged: (v) =>
                              _updateButtonBit(RetroJoypadMask.r, v),
                          onSecondaryChanged: (v) =>
                              _updateButtonBit(RetroJoypadMask.r2, v),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 4. D-PAD DIRECIONAL CUSTOMIZÁVEL (Tamanho, Opacidade, Espaçamento)
              // ==============================================================
              Positioned(
                left: _settings.dpadLeft,
                bottom: _settings.dpadBottom,
                child: GestureDetector(
                  onPanUpdate: _isDraggingGamepad
                      ? (d) => _applyAndSaveSettings(
                            _settings.copyWith(
                              dpadLeft: (_settings.dpadLeft + d.delta.dx)
                                  .clamp(8.0, 420.0),
                              dpadBottom: (_settings.dpadBottom - d.delta.dy)
                                  .clamp(8.0, 260.0),
                            ),
                          )
                      : null,
                  child: _EditableControlFrame(
                    editing: _isDraggingGamepad,
                    label: 'Direcional D-Pad',
                    onTapEdit: () =>
                        _openElementCustomizer(_GamepadEditTarget.dpad),
                    child: Opacity(
                      opacity:
                          (_settings.gamepadOpacity * _settings.dpadOpacity)
                              .clamp(0.15, 1.0),
                      child: Transform.scale(
                        scale: _settings.gamepadScale * _settings.dpadScale,
                        child: _DpadClusterWidget(
                          joypadMask: _joypadMask,
                          spacing: _settings.dpadSpacing,
                          buttonStyle: _settings.buttonStyle,
                          onDpadBitsChanged: _updateDpadBits,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 5. ANALÓGICO VIRTUAL CUSTOMIZÁVEL
              // ==============================================================
              Positioned(
                left: _settings.stickLeft,
                bottom: _settings.stickBottom,
                child: GestureDetector(
                  onPanUpdate: _isDraggingGamepad
                      ? (d) => _applyAndSaveSettings(
                            _settings.copyWith(
                              stickLeft: (_settings.stickLeft + d.delta.dx)
                                  .clamp(8.0, 460.0),
                              stickBottom: (_settings.stickBottom - d.delta.dy)
                                  .clamp(8.0, 260.0),
                            ),
                          )
                      : null,
                  child: _EditableControlFrame(
                    editing: _isDraggingGamepad,
                    label: 'Alavanca Analógica',
                    onTapEdit: () =>
                        _openElementCustomizer(_GamepadEditTarget.stick),
                    child: Opacity(
                      opacity:
                          (_settings.gamepadOpacity * _settings.stickOpacity)
                              .clamp(0.15, 1.0),
                      child: Transform.scale(
                        scale: _settings.gamepadScale * _settings.stickScale,
                        child: _VirtualAnalogStick(
                          stickX: _stickX,
                          stickY: _stickY,
                          enabled: !_isDraggingGamepad && !_isSidebarOpen,
                          onStickChanged: _updateAnalogVector,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 6. BOTÕES DE AÇÃO DIREITOS (Tamanho, Opacidade, Espaçamento, Estilo)
              // ==============================================================
              Positioned(
                right: _settings.actionRight,
                bottom: _settings.actionBottom,
                child: GestureDetector(
                  onPanUpdate: _isDraggingGamepad
                      ? (d) => _applyAndSaveSettings(
                            _settings.copyWith(
                              actionRight: (_settings.actionRight - d.delta.dx)
                                  .clamp(8.0, 420.0),
                              actionBottom:
                                  (_settings.actionBottom - d.delta.dy)
                                      .clamp(8.0, 260.0),
                            ),
                          )
                      : null,
                  child: _EditableControlFrame(
                    editing: _isDraggingGamepad,
                    label: 'Botões Ação (A B X Y)',
                    onTapEdit: () =>
                        _openElementCustomizer(_GamepadEditTarget.actions),
                    child: Opacity(
                      opacity:
                          (_settings.gamepadOpacity * _settings.actionOpacity)
                              .clamp(0.15, 1.0),
                      child: Transform.scale(
                        scale: _settings.gamepadScale * _settings.actionScale,
                        child: _ActionButtonsClusterWidget(
                          joypadMask: _joypadMask,
                          spacing: _settings.actionSpacing,
                          buttonStyle: _settings.buttonStyle,
                          onBitChanged: _updateButtonBit,
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // ==============================================================
              // 7. SELECT / START ORGANIZADOS E COMPACTOS
              // ==============================================================
              Positioned(
                bottom: _settings.selectStartBottom,
                left: 0,
                right: 0,
                child: Center(
                  child: GestureDetector(
                    onPanUpdate: _isDraggingGamepad
                        ? (d) => _applyAndSaveSettings(
                              _settings.copyWith(
                                selectStartBottom: (_settings
                                            .selectStartBottom -
                                        d.delta.dy)
                                    .clamp(6.0, 200.0),
                              ),
                            )
                        : null,
                    child: _EditableControlFrame(
                      editing: _isDraggingGamepad,
                      label: 'Select & Start',
                      onTapEdit: () =>
                          _openElementCustomizer(_GamepadEditTarget.selectStart),
                      child: Opacity(
                        opacity: (_settings.gamepadOpacity *
                                _settings.selectStartOpacity)
                            .clamp(0.15, 1.0),
                        child: Transform.scale(
                          scale: _settings.gamepadScale *
                              _settings.selectStartScale,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _SelectPillButton(
                                style: _settings.buttonStyle,
                                active:
                                    (_joypadMask & RetroJoypadMask.select) != 0,
                                onChanged: (v) =>
                                    _updateButtonBit(RetroJoypadMask.select, v),
                                onFastForward: (active) =>
                                    _setFastForward(active),
                              ),
                              SizedBox(width: _settings.selectStartSpacing),
                              _PillGamepadButton(
                                label: 'START',
                                style: _settings.buttonStyle,
                                active:
                                    (_joypadMask & RetroJoypadMask.start) != 0,
                                onChanged: (v) =>
                                    _updateButtonBit(RetroJoypadMask.start, v),
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

              // ==============================================================
              // 8. BARRA FLUTUANTE DO MODO "MOVER & EDITAR BOTÕES NA TELA"
              // ==============================================================
              if (_isDraggingGamepad)
                Positioned(
                  top: 14,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
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
                          const SizedBox(width: 14),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _isDraggingGamepad = false;
                                _isSidebarOpen = true;
                              });
                              _showToast('Ajustes salvos com sucesso!');
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(14),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.check, size: 13, color: Colors.black),
                                  SizedBox(width: 3),
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
                        ],
                      ),
                    ),
                  ),
                ),

              // Toast de Confirmação
              if (_toastBanner != null)
                Positioned(
                  top: 46,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: HydraTokens.bgNearBlack.withOpacity(0.95),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.35),
                        ),
                      ),
                      child: Text(
                        _toastBanner!,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: HydraTokens.textPrimary,
                        ),
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
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _closeSidebarAndResume,
                          child: Container(
                            color: Colors.black.withOpacity(0.55),
                            alignment: Alignment.centerLeft,
                            padding: const EdgeInsets.only(left: 28),
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
                                    PhosphorIcons.play(PhosphorIconsStyle.fill),
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Toque para Continuar',
                                    style: TextStyle(
                                      fontFamily: 'ReadexPro',
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
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
                            left: BorderSide(color: HydraTokens.borderSubtle10),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Color(0xDD000000),
                              blurRadius: 28,
                              offset: Offset(-8, 0),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            // Cabeçalho da Sidebar: Capa + Título + Botão Continuar + Botão Sair
                            Container(
                              padding:
                                  const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              decoration: const BoxDecoration(
                                color: HydraTokens.bgPureBlack,
                                border: Border(
                                  bottom: BorderSide(
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(6),
                                    child: SizedBox(
                                      width: 34,
                                      height: 46,
                                      child: LoopCoverImage(
                                        url: widget.game.resolvedGridCoverUrl,
                                        fit: BoxFit.cover,
                                        platformSlug: widget.game.platformSlug,
                                        gameTitle: widget.game.name,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
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
                                          style: const TextStyle(
                                            fontFamily: 'JetBrainsMono',
                                            fontSize: 10,
                                            color: HydraTokens.secondaryTeal,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: _closeSidebarAndResume,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 11,
                                        vertical: 7,
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
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: _exitPlayerToLibrary,
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 11,
                                        vertical: 7,
                                      ),
                                      decoration: BoxDecoration(
                                        color: HydraTokens.accentDanger
                                            .withOpacity(0.18),
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: HydraTokens.accentDanger
                                              .withOpacity(0.55),
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
                                ],
                              ),
                            ),

                            // Abas de navegação da Sidebar
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: const BoxDecoration(
                                border: Border(
                                  bottom: BorderSide(
                                    color: HydraTokens.borderSubtle8,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  _SidebarTabButton(
                                    label: 'Saves',
                                    icon: PhosphorIcons.floppyDisk(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    active: _sidebarSection ==
                                        _SidebarSection.saves,
                                    onTap: () => setState(
                                      () => _sidebarSection =
                                          _SidebarSection.saves,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _SidebarTabButton(
                                    label: 'Gráficos',
                                    icon: PhosphorIcons.slidersHorizontal(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    active: _sidebarSection ==
                                        _SidebarSection.graphics,
                                    onTap: () => setState(
                                      () => _sidebarSection =
                                          _SidebarSection.graphics,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _SidebarTabButton(
                                    label: 'Gamepad',
                                    icon: PhosphorIcons.gameController(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    active: _sidebarSection ==
                                        _SidebarSection.gamepad,
                                    onTap: () => setState(
                                      () => _sidebarSection =
                                          _SidebarSection.gamepad,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  _SidebarTabButton(
                                    label: 'HUD Info',
                                    icon: PhosphorIcons.gauge(
                                      PhosphorIconsStyle.bold,
                                    ),
                                    active: _sidebarSection ==
                                        _SidebarSection.hudInfo,
                                    onTap: () => setState(
                                      () => _sidebarSection =
                                          _SidebarSection.hudInfo,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // Conteúdo da aba selecionada na Sidebar
                            Expanded(
                              child: _buildSidebarBody(),
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
              child: Row(
                children: [
                  // Preview de onde parou estilo PPSSPP (16:9 thumbnail)
                  ClipRRect(
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
                              fit: BoxFit.cover,
                            )
                          else if (slotInfo.exists)
                            LoopCoverImage(
                              url: widget.game.resolvedHeroBannerUrl,
                              fit: BoxFit.cover,
                              platformSlug: widget.game.platformSlug,
                              gameTitle: widget.game.name,
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
                                  color: Colors.white.withOpacity(0.35),
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
                  ),
                  const SizedBox(width: 12),
                  // Título do Jogo + Slot + Data/Hora
                  Expanded(
                    child: Column(
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
                          style: const TextStyle(
                            fontFamily: 'Rubik',
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: HydraTokens.secondaryTeal,
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
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Botões Salvar / Carregar / Apagar
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () => _handleSaveToSlot(slotInfo.slot),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 11,
                            vertical: 5.5,
                          ),
                          decoration: BoxDecoration(
                            color: HydraTokens.primaryAurora,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: const Text(
                            'Salvar',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: HydraTokens.bgPureBlack,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 5),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          GestureDetector(
                            onTap: slotInfo.exists
                                ? () => _handleLoadFromSlot(slotInfo.slot)
                                : null,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: slotInfo.exists
                                    ? HydraTokens.surfaceElevated2
                                    : HydraTokens.bgPureBlack,
                                borderRadius: BorderRadius.circular(7),
                                border: Border.all(
                                  color: HydraTokens.borderSubtle10,
                                ),
                              ),
                              child: Text(
                                'Carregar',
                                style: TextStyle(
                                  fontFamily: 'ReadexPro',
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: slotInfo.exists
                                      ? HydraTokens.textPrimary
                                      : HydraTokens.textMuted,
                                ),
                              ),
                            ),
                          ),
                          if (slotInfo.exists) ...[
                            const SizedBox(width: 4),
                            GestureDetector(
                              onTap: () => _handleDeleteSlot(slotInfo.slot),
                              child: Container(
                                padding: const EdgeInsets.all(5),
                                decoration: BoxDecoration(
                                  color: HydraTokens.accentDanger
                                      .withOpacity(0.16),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: PhosphorIcon(
                                  PhosphorIcons.trash(PhosphorIconsStyle.bold),
                                  size: 13,
                                  color: HydraTokens.accentDanger,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ==========================================================================
  // ABA 2 DA SIDEBAR: CONTROLE GAMEPAD TOUCH & FÍSICO
  // ==========================================================================
  // ==========================================================================
  // ABA GRÁFICOS: backend, resoluções, filtros e toggles estilo PPSSPP
  // ==========================================================================
  Widget _buildGraphicsPanel() {
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
          selected: _settings.gpuBackend,
          labelOf: (v) => v.label,
          onSelected: (v) => _applyGraphicsSetting(
            _settings.copyWith(gpuBackend: v),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _settings.gpuBackend.description,
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
          selected: _settings.renderResolution,
          labelOf: (v) => v.label,
          onSelected: (v) => _applyGraphicsSetting(
            _settings.copyWith(renderResolution: v),
          ),
        ),
        const SizedBox(height: 14),

        // ---------------- Resolução da tela ----------------
        const _GraphicsGroupTitle('Resolução da Tela'),
        const SizedBox(height: 6),
        _GraphicsChipRow<ScreenResolutionScale>(
          values: ScreenResolutionScale.values,
          selected: _settings.screenResolution,
          labelOf: (v) => v.label,
          onSelected: (v) => _applyGraphicsSetting(
            _settings.copyWith(screenResolution: v),
          ),
        ),
        const SizedBox(height: 14),

        // ---------------- MSAA ----------------
        const _GraphicsGroupTitle('MSAA (Anti-Aliasing)'),
        const SizedBox(height: 6),
        _GraphicsChipRow<MsaaLevel>(
          values: MsaaLevel.values,
          selected: _settings.msaaLevel,
          labelOf: (v) => v.label,
          onSelected: (v) => _applyGraphicsSetting(
            _settings.copyWith(msaaLevel: v),
          ),
        ),
        const SizedBox(height: 14),

        // ---------------- Filtro de textura ----------------
        const _GraphicsGroupTitle('Filtragem de Textura'),
        const SizedBox(height: 6),
        _GraphicsChipRow<TextureFilterMode>(
          values: TextureFilterMode.values,
          selected: _settings.textureFilter,
          labelOf: (v) => v.label,
          onSelected: (v) => _applyGraphicsSetting(
            _settings.copyWith(textureFilter: v),
          ),
        ),
        const SizedBox(height: 16),

        // ---------------- Toggles ----------------
        const _GraphicsGroupTitle('Efeitos e Desempenho'),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Substituir Texturas',
          subtitle: 'Permite packs de textura HD do core',
          value: _settings.textureReplacement,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(textureReplacement: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Flare de Luz da Lente',
          subtitle: 'Efeito de clarão nas fontes de luz',
          value: _settings.lensFlare,
          onChanged: (v) =>
              _applyGraphicsSetting(_settings.copyWith(lensFlare: v)),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Ignorar Leituras da GPU',
          subtitle: 'Melhora muito o FPS (pode causar glitches visuais)',
          value: _settings.skipGpuReadbacks,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(skipGpuReadbacks: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Cache de Textura Preguiçoso',
          subtitle: 'Atualização de texturas mais rápida e eficiente',
          value: _settings.lazyTextureCache,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(lazyTextureCache: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Duplicar Frames a 60Hz',
          subtitle: 'Jogos a 30fps entregam imagem mais fluida',
          value: _settings.frameDuplication,
          onChanged: (v) => _applyAndSaveSettings(
            _settings.copyWith(frameDuplication: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Transformação por Hardware',
          subtitle: 'Vertex shader na GPU (desligue se houver glitches)',
          value: _settings.hardwareTransform,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(hardwareTransform: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Skinning por Software',
          subtitle: 'Deformação de malha na CPU (mais compatível)',
          value: _settings.softwareSkinning,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(softwareSkinning: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Filtragem Anisotrópica',
          subtitle: 'Texturas nítidas em ângulos rasos (custa FPS)',
          value: _settings.anisotropicFiltering,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(anisotropicFiltering: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Deposterize de Textura',
          subtitle: 'Remove posterização de gradientes de cor',
          value: _settings.textureDeposterize,
          onChanged: (v) => _applyGraphicsSetting(
            _settings.copyWith(textureDeposterize: v),
          ),
        ),
      ],
    );
  }

  Widget _buildGamepadEditorPanel() {
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _isSidebarOpen = false;
              _isDraggingGamepad = true;
            });
            _showToast('Arraste ou dê um toque no botão para customizá-lo');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                PhosphorIcon(
                  PhosphorIcons.handTap(PhosphorIconsStyle.bold),
                  size: 16,
                  color: Colors.black,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Mover e Editar Botões na Tela',
                  style: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Colors.black,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        GestureDetector(
          onTap: () {
            _applyAndSaveSettings(_settings.resetGamepadLayout());
            _showToast('Gamepad restaurado para o padrão');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: HydraTokens.surfaceElevated1,
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
                  'Toque no botão acima para ver seus botões em tamanho real. No modo de edição, você pode arrastar para mover e dar um toque em qualquer botão (L1, R2, D-Pad, Ações) para mudar tamanho, opacidade e estilo ao vivo!',
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
          'Modo do Controle na Tela:',
          style: TextStyle(
            fontFamily: 'ReadexPro',
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: HydraTokens.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: TouchOverlayMode.values.map((mode) {
            final active = _settings.touchOverlayMode == mode;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: mode != TouchOverlayMode.alwaysHide ? 6 : 0,
                ),
                child: GestureDetector(
                  onTap: () => _applyAndSaveSettings(
                    _settings.copyWith(touchOverlayMode: mode),
                  ),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: active
                          ? Colors.white
                          : HydraTokens.surfaceCatalog,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      mode.label,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontFamily: 'ReadexPro',
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: active
                            ? HydraTokens.bgPureBlack
                            : HydraTokens.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 12),
        _CompactSwitchRow(
          title: 'Vibração Tátil ao Tocar',
          subtitle: 'Feedback háptico nos botões virtuais',
          value: _settings.hapticVibration,
          onChanged: (v) => _applyAndSaveSettings(
            _settings.copyWith(hapticVibration: v),
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
            final storage = SettingsStorageService();
            final profiles = await storage.loadGameProfiles();
            if (v) {
              profiles[widget.game.igdbId] = _settings;
              await storage.saveGameProfiles(profiles);
              _showToast('Perfil exclusivo ativado para ${widget.game.name}');
            } else {
              profiles.remove(widget.game.igdbId);
              await storage.saveGameProfiles(profiles);
              _showToast('Usando configurações globais');
            }
          },
        ),
      ],
    );
  }

  // ==========================================================================
  // ABA 3 DA SIDEBAR: CONFIGURAR INFORMAÇÕES NA TELA (FPS, 3X, PSP, MS)
  // ==========================================================================
  Widget _buildHudConfigPanel() {
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
        _CompactSwitchRow(
          title: 'Exibir Barra de Informações (HUD)',
          subtitle: 'Mostra ou oculta todos os indicadores técnicos',
          value: _settings.showFpsTelemetry,
          onChanged: (v) => _applyAndSaveSettings(
            _settings.copyWith(showFpsTelemetry: v),
          ),
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Taxa de Quadros (FPS)',
          subtitle: 'Exibe a velocidade em tempo real (ex.: 60 FPS)',
          value: _settings.hudShowFps,
          onChanged: _settings.showFpsTelemetry
              ? (v) => _applyAndSaveSettings(
                    _settings.copyWith(hudShowFps: v),
                  )
              : null,
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Escala de Resolução (2x / 3x / 4x)',
          subtitle: 'Mostra o multiplicador gráfico ativo',
          value: _settings.hudShowResolution,
          onChanged: _settings.showFpsTelemetry
              ? (v) => _applyAndSaveSettings(
                    _settings.copyWith(hudShowResolution: v),
                  )
              : null,
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Nome do Console (PSP, PS1, GBA...)',
          subtitle: 'Mostra a plataforma em execução',
          value: _settings.hudShowConsole,
          onChanged: _settings.showFpsTelemetry
              ? (v) => _applyAndSaveSettings(
                    _settings.copyWith(hudShowConsole: v),
                  )
              : null,
        ),
        const SizedBox(height: 6),
        _CompactSwitchRow(
          title: 'Tempo de Quadro (Latência em ms)',
          subtitle: 'Exibe o tempo de renderização (ex.: 16.6 ms)',
          value: _settings.hudShowFrameTime,
          onChanged: _settings.showFpsTelemetry
              ? (v) => _applyAndSaveSettings(
                    _settings.copyWith(hudShowFrameTime: v),
                  )
              : null,
        ),
      ],
    );
  }

  void _openElementCustomizer(_GamepadEditTarget target) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            double currentScale;
            double currentOpacity;
            double? currentSpacing;

            switch (target) {
              case _GamepadEditTarget.global:
                currentScale = _settings.gamepadScale;
                currentOpacity = _settings.gamepadOpacity;
                currentSpacing = null;
                break;
              case _GamepadEditTarget.shoulders:
                currentScale = _settings.shoulderScale;
                currentOpacity = _settings.shoulderOpacity;
                currentSpacing = _settings.shoulderSpacing;
                break;
              case _GamepadEditTarget.dpad:
                currentScale = _settings.dpadScale;
                currentOpacity = _settings.dpadOpacity;
                currentSpacing = _settings.dpadSpacing;
                break;
              case _GamepadEditTarget.stick:
                currentScale = _settings.stickScale;
                currentOpacity = _settings.stickOpacity;
                currentSpacing = null;
                break;
              case _GamepadEditTarget.actions:
                currentScale = _settings.actionScale;
                currentOpacity = _settings.actionOpacity;
                currentSpacing = _settings.actionSpacing;
                break;
              case _GamepadEditTarget.selectStart:
                currentScale = _settings.selectStartScale;
                currentOpacity = _settings.selectStartOpacity;
                currentSpacing = _settings.selectStartSpacing;
                break;
            }

            final title = switch (target) {
              _GamepadEditTarget.global => 'Controles Gerais',
              _GamepadEditTarget.shoulders => 'Gatilhos L1, L2, R1, R2',
              _GamepadEditTarget.dpad => 'Direcional D-Pad',
              _GamepadEditTarget.stick => 'Alavanca Analógica',
              _GamepadEditTarget.actions => 'Botões de Ação (A, B, X, Y)',
              _GamepadEditTarget.selectStart => 'Botões Select & Start',
            };

            return Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.92),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: const Border(
                  top: BorderSide(color: Colors.white24, width: 1.5),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      PhosphorIcon(
                        PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.bold),
                        size: 16,
                        color: Colors.white,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        title,
                        style: const TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Pronto',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                            ),
                          ),
                        ),
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
                            AppSettings next;
                            switch (target) {
                              case _GamepadEditTarget.global:
                                next = _settings.copyWith(gamepadScale: v);
                                break;
                              case _GamepadEditTarget.shoulders:
                                next = _settings.copyWith(shoulderScale: v);
                                break;
                              case _GamepadEditTarget.dpad:
                                next = _settings.copyWith(dpadScale: v);
                                break;
                              case _GamepadEditTarget.stick:
                                next = _settings.copyWith(stickScale: v);
                                break;
                              case _GamepadEditTarget.actions:
                                next = _settings.copyWith(actionScale: v);
                                break;
                              case _GamepadEditTarget.selectStart:
                                next = _settings.copyWith(selectStartScale: v);
                                break;
                            }
                            _applyAndSaveSettings(next);
                            setModalState(() {});
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
                            AppSettings next;
                            switch (target) {
                              case _GamepadEditTarget.global:
                                next = _settings.copyWith(gamepadOpacity: v);
                                break;
                              case _GamepadEditTarget.shoulders:
                                next = _settings.copyWith(shoulderOpacity: v);
                                break;
                              case _GamepadEditTarget.dpad:
                                next = _settings.copyWith(dpadOpacity: v);
                                break;
                              case _GamepadEditTarget.stick:
                                next = _settings.copyWith(stickOpacity: v);
                                break;
                              case _GamepadEditTarget.actions:
                                next = _settings.copyWith(actionOpacity: v);
                                break;
                              case _GamepadEditTarget.selectStart:
                                next = _settings.copyWith(selectStartOpacity: v);
                                break;
                            }
                            _applyAndSaveSettings(next);
                            setModalState(() {});
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
                              AppSettings next;
                              switch (target) {
                                case _GamepadEditTarget.shoulders:
                                  next = _settings.copyWith(shoulderSpacing: v);
                                  break;
                                case _GamepadEditTarget.dpad:
                                  next = _settings.copyWith(dpadSpacing: v);
                                  break;
                                case _GamepadEditTarget.actions:
                                  next = _settings.copyWith(actionSpacing: v);
                                  break;
                                case _GamepadEditTarget.selectStart:
                                  next = _settings.copyWith(selectStartSpacing: v);
                                  break;
                                default:
                                  return;
                              }
                              _applyAndSaveSettings(next);
                              setModalState(() {});
                            },
                          ),
                        ),
                      ],
                    ),
                  // Se for Shoulders (Gatilhos): Formato Compacto / Empilhado / Separado
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
                    Row(
                      children: ShoulderTriggerStyle.values.map((st) {
                        final active = _settings.shoulderStyle == st;
                        return Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: GestureDetector(
                              onTap: () {
                                _applyAndSaveSettings(
                                  _settings.copyWith(shoulderStyle: st),
                                );
                                setModalState(() {});
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                decoration: BoxDecoration(
                                  color: active ? Colors.white : Colors.white12,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                alignment: Alignment.center,
                                child: Text(
                                  st.label,
                                  style: TextStyle(
                                    fontFamily: 'ReadexPro',
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    color: active ? Colors.black : Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
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
                      runSpacing: 4,
                      children: GamepadButtonStyle.values.map((bs) {
                        final active = _settings.buttonStyle == bs;
                        return GestureDetector(
                          onTap: () {
                            _applyAndSaveSettings(
                              _settings.copyWith(buttonStyle: bs),
                            );
                            setModalState(() {});
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              color: active ? Colors.white : Colors.white12,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              bs.label,
                              style: TextStyle(
                                fontFamily: 'ReadexPro',
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                color: active ? Colors.black : Colors.white,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  void _openHudCustomizer() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.92),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                border: const Border(
                  top: BorderSide(color: Colors.white24, width: 1.5),
                ),
              ),
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
                      const Text(
                        'Personalizar Informações na Tela (HUD)',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          fontSize: 14.5,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () => Navigator.of(ctx).pop(),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Text(
                            'Pronto',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _CompactSwitchRow(
                    title: 'Exibir Barra HUD',
                    subtitle: 'Ativa ou oculta a cápsula de informações',
                    value: _settings.showFpsTelemetry,
                    onChanged: (v) {
                      _applyAndSaveSettings(_settings.copyWith(showFpsTelemetry: v));
                      setModalState(() {});
                    },
                  ),
                  _CompactSwitchRow(
                    title: 'Mostrar FPS (Quadros por segundo)',
                    subtitle: 'Exibe fluidez da emulação (ex.: 60 FPS)',
                    value: _settings.hudShowFps,
                    onChanged: _settings.showFpsTelemetry
                        ? (v) {
                            _applyAndSaveSettings(_settings.copyWith(hudShowFps: v));
                            setModalState(() {});
                          }
                        : null,
                  ),
                  _CompactSwitchRow(
                    title: 'Mostrar Tempo de Quadro (ms)',
                    subtitle: 'Exibe a latência de renderização (ex.: 16.6 ms)',
                    value: _settings.hudShowFrameTime,
                    onChanged: _settings.showFpsTelemetry
                        ? (v) {
                            _applyAndSaveSettings(_settings.copyWith(hudShowFrameTime: v));
                            setModalState(() {});
                          }
                        : null,
                  ),
                  _CompactSwitchRow(
                    title: 'Mostrar Escala Gráfica',
                    subtitle: 'Exibe a resolução interna ativa (ex.: 2x)',
                    value: _settings.hudShowResolution,
                    onChanged: _settings.showFpsTelemetry
                        ? (v) {
                            _applyAndSaveSettings(_settings.copyWith(hudShowResolution: v));
                            setModalState(() {});
                          }
                        : null,
                  ),
                  _CompactSwitchRow(
                    title: 'Mostrar Nome do Console',
                    subtitle: 'Exibe a plataforma em execução (PSP, PS1, GBA)',
                    value: _settings.hudShowConsole,
                    onChanged: _settings.showFpsTelemetry
                        ? (v) {
                            _applyAndSaveSettings(_settings.copyWith(hudShowConsole: v));
                            setModalState(() {});
                          }
                        : null,
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
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
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? HydraTokens.primaryAurora
                : HydraTokens.surfaceCatalog,
            borderRadius: BorderRadius.circular(8),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: HydraTokens.surfaceCatalog,
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
        return GestureDetector(
          onTap: () => onSelected(v),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: BoxDecoration(
              color: active ? Colors.white : HydraTokens.surfaceCatalog,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: active
                    ? Colors.white
                    : HydraTokens.borderSubtle8,
              ),
            ),
            child: Text(
              labelOf(v),
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
        );
      }).toList(),
    );
  }
}

/// Gatilhos L1/L2 e R1/R2 com modo "Compactos Juntos" (Unidos numa cápsula ergonômica fácil de clicar!)
class _ShoulderTriggerCluster extends StatelessWidget {
  const _ShoulderTriggerCluster({
    required this.isLeft,
    required this.style,
    required this.buttonStyle,
    required this.spacing,
    required this.primaryActive,
    required this.secondaryActive,
    required this.onPrimaryChanged,
    required this.onSecondaryChanged,
  });

  final bool isLeft;
  final ShoulderTriggerStyle style;
  final GamepadButtonStyle buttonStyle;
  final double spacing;
  final bool primaryActive;
  final bool secondaryActive;
  final ValueChanged<bool> onPrimaryChanged;
  final ValueChanged<bool> onSecondaryChanged;

  @override
  Widget build(BuildContext context) {
    final l1Label = isLeft ? 'L1' : 'R1';
    final l2Label = isLeft ? 'L2' : 'R2';

    if (style == ShoulderTriggerStyle.compactTogether) {
      // Cápsula dupla compacta onde L1 e L2 ficam juntos com divisória fina
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
              margin: EdgeInsets.symmetric(horizontal: spacing.clamp(1.0, 8.0)),
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
    return Listener(
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
            fontWeight: FontWeight.w800,
            color: active ? HydraTokens.bgPureBlack : HydraTokens.textPrimary,
          ),
        ),
      ),
    );
  }
}

class _DpadClusterWidget extends StatefulWidget {
  const _DpadClusterWidget({
    required this.joypadMask,
    required this.spacing,
    required this.buttonStyle,
    required this.onDpadBitsChanged,
  });

  final int joypadMask;
  final double spacing;
  final GamepadButtonStyle buttonStyle;
  final void Function(int newDpadMask) onDpadBitsChanged;

  @override
  State<_DpadClusterWidget> createState() => _DpadClusterWidgetState();
}

class _DpadClusterWidgetState extends State<_DpadClusterWidget> {
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
    final isUp = (widget.joypadMask & RetroJoypadMask.up) != 0;
    final isDown = (widget.joypadMask & RetroJoypadMask.down) != 0;
    final isLeft = (widget.joypadMask & RetroJoypadMask.left) != 0;
    final isRight = (widget.joypadMask & RetroJoypadMask.right) != 0;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _evalPointer(e.localPosition, dim),
      onPointerMove: (e) => _evalPointer(e.localPosition, dim),
      onPointerUp: (_) => _onRelease(),
      onPointerCancel: (_) => _onRelease(),
      child: SizedBox(
        width: dim,
        height: dim,
        child: Stack(
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
                icon: PhosphorIcons.caretDown(
                  isDown ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                ),
                style: widget.buttonStyle,
                active: isDown,
                onChanged: (_) {},
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: _TouchCircleButton(
                icon: PhosphorIcons.caretLeft(
                  isLeft ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                ),
                style: widget.buttonStyle,
                active: isLeft,
                onChanged: (_) {},
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _TouchCircleButton(
                icon: PhosphorIcons.caretRight(
                  isRight ? PhosphorIconsStyle.fill : PhosphorIconsStyle.bold,
                ),
                style: widget.buttonStyle,
                active: isRight,
                onChanged: (_) {},
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionButtonsClusterWidget extends StatelessWidget {
  const _ActionButtonsClusterWidget({
    required this.joypadMask,
    required this.spacing,
    required this.buttonStyle,
    required this.onBitChanged,
  });

  final int joypadMask;
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
            child: _TouchCircleButton(
              textLabel: useAbxyLabels ? 'Y' : null,
              icon: PhosphorIcons.triangle(
                (joypadMask & RetroJoypadMask.x) != 0
                    ? PhosphorIconsStyle.fill
                    : PhosphorIconsStyle.bold,
              ),
              style: buttonStyle,
              active: (joypadMask & RetroJoypadMask.x) != 0,
              onChanged: (v) => onBitChanged(RetroJoypadMask.x, v),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: _TouchCircleButton(
              textLabel: useAbxyLabels ? 'A' : null,
              icon: PhosphorIcons.x(PhosphorIconsStyle.bold),
              style: buttonStyle,
              active: (joypadMask & RetroJoypadMask.b) != 0,
              onChanged: (v) => onBitChanged(RetroJoypadMask.b, v),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _TouchCircleButton(
              textLabel: useAbxyLabels ? 'X' : null,
              icon: PhosphorIcons.square(
                (joypadMask & RetroJoypadMask.y) != 0
                    ? PhosphorIconsStyle.fill
                    : PhosphorIconsStyle.bold,
              ),
              style: buttonStyle,
              active: (joypadMask & RetroJoypadMask.y) != 0,
              onChanged: (v) => onBitChanged(RetroJoypadMask.y, v),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: _TouchCircleButton(
              textLabel: useAbxyLabels ? 'B' : null,
              icon: PhosphorIcons.circle(
                (joypadMask & RetroJoypadMask.a) != 0
                    ? PhosphorIconsStyle.fill
                    : PhosphorIconsStyle.bold,
              ),
              style: buttonStyle,
              active: (joypadMask & RetroJoypadMask.a) != 0,
              onChanged: (v) => onBitChanged(RetroJoypadMask.a, v),
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
    return GestureDetector(
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
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              margin: const EdgeInsets.only(bottom: 3),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PhosphorIcon(
                    PhosphorIcons.slidersHorizontal(PhosphorIconsStyle.bold),
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
          platformSlug: game.platformSlug,
          gameTitle: game.name,
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
    required this.stickX,
    required this.stickY,
    required this.enabled,
    required this.onStickChanged,
  });

  final double stickX;
  final double stickY;
  final bool enabled;
  final void Function(double x, double y) onStickChanged;

  @override
  Widget build(BuildContext context) {
    const double size = 102.0;
    const double maxRadius = 33.0;

    return GestureDetector(
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
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: HydraTokens.bgNearBlack.withOpacity(0.68),
          border: Border.all(color: Colors.white.withOpacity(0.22)),
        ),
        child: Center(
          child: Transform.translate(
            offset: Offset(stickX * maxRadius, stickY * maxRadius),
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: (stickX != 0 || stickY != 0)
                    ? Colors.white
                    : HydraTokens.surfaceElevated2,
                border: Border.all(color: Colors.white.withOpacity(0.55)),
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
  });

  final IconData icon;
  final GamepadButtonStyle style;
  final bool active;
  final ValueChanged<bool> onChanged;
  final String? textLabel;

  @override
  Widget build(BuildContext context) {
    final isMinimal = style == GamepadButtonStyle.minimalOutline;

    return Listener(
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
                    fontWeight: FontWeight.w800,
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
    );
  }
}

class _PillGamepadButton extends StatelessWidget {
  const _PillGamepadButton({
    required this.label,
    required this.style,
    required this.active,
    required this.onChanged,
  });

  final String label;
  final GamepadButtonStyle style;
  final bool active;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final isMinimal = style == GamepadButtonStyle.minimalOutline;

    return Listener(
      onPointerDown: (_) => onChanged(true),
      onPointerUp: (_) => onChanged(false),
      onPointerCancel: (_) => onChanged(false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 70),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6.5),
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
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
            color: active ? HydraTokens.bgPureBlack : HydraTokens.textPrimary,
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

    return Listener(
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
            fontWeight: FontWeight.w800,
            color: _isFastForwarding
                ? Colors.black
                : widget.active
                    ? HydraTokens.bgPureBlack
                    : Colors.white,
          ),
        ),
      ),
    );
  }
}
