enum VideoFilterPreset {
  sharpPixels('Pixel Nítido', 'Pixels definidos sem borramento'),
  smoothBilinear('Suavização HD', 'Filtro suave para gráficos 3D'),
  crtScanlines('CRT Arcade', 'Linhas clássicas de monitor de tubo'),
  lcdHandheld('Matriz LCD', 'Grade estilo portátil clássico');

  const VideoFilterPreset(this.label, this.description);
  final String label;
  final String description;
}

enum AspectRatioPreset {
  consoleOriginal('Original', 'Proporção nativa do console'),
  widescreen169('16:9', 'Formato panorâmico widescreen'),
  fullScreen('Tela Cheia', 'Preenche toda a tela');

  const AspectRatioPreset(this.label, this.description);
  final String label;
  final String description;
}

enum GamepadButtonStyle {
  gamehubGlass('GameHub Glass', 'Visual translúcido moderno estilo GameHub'),
  playstation('PlayStation', 'Símbolos clássicos △ ○ × □'),
  xboxAbxy('Xbox ABXY', 'Botões com letras A B X Y'),
  minimalOutline('Minimalista', 'Contornos finos e discretos');

  const GamepadButtonStyle(this.label, this.description);
  final String label;
  final String description;
}

enum ShoulderTriggerStyle {
  compactTogether('Compactos Juntos', 'L1/L2 e R1/R2 unidos para clique rápido'),
  stackedVertical('Empilhados', 'L2 em cima de L1 verticalmente'),
  sideBySide('Separados', 'Gatilhos lado a lado tradicionais');

  const ShoulderTriggerStyle(this.label, this.description);
  final String label;
  final String description;
}

enum GpuBackend {
  vulkan('Vulkan', 'Renderização Vulkan (recomendado, experimental)'),
  openGL('OpenGL ES', 'Renderização por hardware na GPU'),
  software('Software (CPU)', 'Renderização por software no processador');

  const GpuBackend(this.label, this.description);
  final String label;
  final String description;
}

enum RenderResolutionPreset {
  x1('1x PSP'),
  x2('2x PSP'),
  x3('3x PSP'),
  x4('4x PSP'),
  x5('5x PSP'),
  x6('6x PSP'),
  x7('7x PSP'),
  x8('8x PSP'),
  x9('9x PSP'),
  x10('10x PSP'),
  p1080('1080p'),
  k4('4K');

  const RenderResolutionPreset(this.label);
  final String label;

  /// Valor exato aceito pela core option `ppsspp_internal_resolution` no PPSSPP libretro.
  String get coreValue {
    switch (this) {
      case RenderResolutionPreset.x1:
        return '480x272';
      case RenderResolutionPreset.x2:
        return '960x544';
      case RenderResolutionPreset.x3:
        return '1440x816';
      case RenderResolutionPreset.x4:
      case RenderResolutionPreset.p1080:
        return '1920x1088';
      case RenderResolutionPreset.x5:
        return '2400x1360';
      case RenderResolutionPreset.x6:
        return '2880x1632';
      case RenderResolutionPreset.x7:
        return '3360x1904';
      case RenderResolutionPreset.x8:
      case RenderResolutionPreset.k4:
        return '3840x2176';
      case RenderResolutionPreset.x9:
        return '4320x2448';
      case RenderResolutionPreset.x10:
        return '4800x2720';
    }
  }
}

enum TextureFilterMode {
  nearest('Vizinho mais próximo', 'Pixels nítidos e definidos'),
  bilinear('Bilinear', 'Texturas suavizadas');

  const TextureFilterMode(this.label, this.description);
  final String label;
  final String description;
}

enum ScreenResolutionScale {
  native('Nativa', 1),
  x2('2x', 2),
  x3('3x', 3),
  x4('4x', 4);

  const ScreenResolutionScale(this.label, this.scale);
  final String label;
  final int scale;
}

enum MsaaLevel {
  off('Desligado', 'Disabled'),
  x2('2x MSAA', 'x2'),
  x4('4x MSAA', 'x4');

  const MsaaLevel(this.label, this.coreValue);
  final String label;
  final String coreValue;
}

enum TouchOverlayMode {
  auto('Automático', 'Esconde o controle da tela quando um gamepad físico conecta'),
  alwaysShow('Sempre Mostrar', 'Controle na tela sempre visível'),
  alwaysHide('Sempre Esconder', 'Usar só gamepad físico');

  const TouchOverlayMode(this.label, this.description);
  final String label;
  final String description;
}

class AppSettings {
  const AppSettings({
    this.fastForwardSpeed = 2,
    this.fastForwardHold = false,
    this.showFastForwardButton = true,
    this.turboMask = 0,
    this.turboHalfPeriodFrames = 3,
    this.showTurboButton = true,
    this.touchOverlayMode = TouchOverlayMode.auto,
    this.gpuRenderer = true,
    this.internalResolutionScale = 1,
    this.gpuBackend = GpuBackend.vulkan,
    this.renderResolution = RenderResolutionPreset.x1,
    this.msaaLevel = MsaaLevel.off,
    this.screenResolution = ScreenResolutionScale.native,
    this.textureFilter = TextureFilterMode.nearest,
    this.textureReplacement = true,
    this.lensFlare = false,
    this.skipGpuReadbacks = true,
    this.lazyTextureCache = true,
    this.frameDuplication = false,
    this.hardwareTransform = true,
    this.softwareSkinning = true,
    this.anisotropicFiltering = false,
    this.textureDeposterize = false,
    this.videoFilter = VideoFilterPreset.sharpPixels,
    this.aspectRatio = AspectRatioPreset.consoleOriginal,
    this.vsyncEnabled = false,
    this.frameSkip = 0,
    this.performanceBoost = true,
    this.showFpsTelemetry = true,
    this.hudShowFps = true,
    this.hudShowResolution = true,
    this.hudShowConsole = true,
    this.hudShowFrameTime = false,
    this.audioEnabled = true,
    this.masterVolume = 0.85,
    this.autoSaveOnExit = false,
    this.autoLoadOnStart = false,
    this.hapticVibration = true,
    this.buttonStyle = GamepadButtonStyle.gamehubGlass,
    this.shoulderStyle = ShoulderTriggerStyle.compactTogether,
    this.gamepadScale = 1.0,
    this.gamepadOpacity = 0.82,
    this.dpadScale = 1.0,
    this.dpadOpacity = 0.85,
    this.dpadSpacing = 4.0,
    this.stickScale = 1.0,
    this.stickOpacity = 0.85,
    this.actionScale = 1.0,
    this.actionOpacity = 0.85,
    this.actionSpacing = 6.0,
    this.shoulderScale = 1.0,
    this.shoulderOpacity = 0.88,
    this.shoulderSpacing = 2.0,
    this.selectStartScale = 0.95,
    this.selectStartOpacity = 0.78,
    this.selectStartSpacing = 12.0,
    this.dpadLeft = 24.0,
    this.dpadBottom = 32.0,
    this.stickLeft = 186.0,
    this.stickBottom = 24.0,
    this.actionRight = 24.0,
    this.actionBottom = 32.0,
    this.shoulderTop = 18.0,
    this.selectStartBottom = 14.0,
    this.rommServerUrl = '',
    this.rommApiToken = '',
    this.customVulkanDriverDir = '',
    this.customVulkanDriverName = '',
    this.customVulkanDriverLabel = '',
    this.adrenoTurboMode = false,
  });

  // Fast-Forward (2x/3x/4x) — segurar ou alternar
  final int fastForwardSpeed;
  final bool fastForwardHold;
  final bool showFastForwardButton;

  // Turbo (auto-fire): bitmask Libretro dos botões com turbo ativo
  final int turboMask;
  final int turboHalfPeriodFrames; // 2..8 (menor = mais rápido)
  final bool showTurboButton;

  // Entrada: controle na tela x gamepad físico
  final TouchOverlayMode touchOverlayMode;

  // Renderizador GPU (OpenGL ES) com fallback automático para CPU
  final bool gpuRenderer; // legado: false → backend software

  // Gráficos estilo PPSSPP
  final GpuBackend gpuBackend;
  final RenderResolutionPreset renderResolution;
  final MsaaLevel msaaLevel;
  final ScreenResolutionScale screenResolution;
  final TextureFilterMode textureFilter;
  final bool textureReplacement;
  final bool lensFlare;
  final bool skipGpuReadbacks;
  final bool lazyTextureCache;
  final bool frameDuplication;
  final bool hardwareTransform;
  final bool softwareSkinning;
  final bool anisotropicFiltering;
  final bool textureDeposterize;

  // Qualidade, Vídeo e Desempenho
  final int internalResolutionScale; // legado 1x..4x (substituído por renderResolution)
  final VideoFilterPreset videoFilter;
  final AspectRatioPreset aspectRatio;
  final bool vsyncEnabled;
  final int frameSkip; // 0, 1, 2
  final bool performanceBoost;

  // HUD / Telemetria Configurável (Escolher quais infos aparecem)
  final bool showFpsTelemetry;
  final bool hudShowFps;
  final bool hudShowResolution;
  final bool hudShowConsole;
  final bool hudShowFrameTime;

  // Som e Áudio
  final bool audioEnabled;
  final double masterVolume; // 0.0 .. 1.0

  // Save States Estilo PPSSPP (Só salva se a pessoa salvar por padrão!)
  final bool autoSaveOnExit;
  final bool autoLoadOnStart;

  // Controles Touch (Personalização Global e Individual por Botão/Grupo)
  final bool hapticVibration;
  final GamepadButtonStyle buttonStyle;
  final ShoulderTriggerStyle shoulderStyle;
  final double gamepadScale; // 0.65 .. 1.45
  final double gamepadOpacity; // 0.20 .. 1.0

  final double dpadScale;
  final double dpadOpacity;
  final double dpadSpacing;

  final double stickScale;
  final double stickOpacity;

  final double actionScale;
  final double actionOpacity;
  final double actionSpacing;

  final double shoulderScale;
  final double shoulderOpacity;
  final double shoulderSpacing;

  final double selectStartScale;
  final double selectStartOpacity;
  final double selectStartSpacing;

  final double dpadLeft;
  final double dpadBottom;
  final double stickLeft;
  final double stickBottom;
  final double actionRight;
  final double actionBottom;
  final double shoulderTop;
  final double selectStartBottom;

  // Integração RomM (servidor próprio de ROMs do usuário)
  final String rommServerUrl;
  final String rommApiToken;

  // Driver Adreno Turnip customizado para cores Vulkan (AdrenoTools)
  final String customVulkanDriverDir;
  final String customVulkanDriverName;
  final String customVulkanDriverLabel;
  final bool adrenoTurboMode;

  String get resolutionLabel => renderResolution.label;

  /// Opções de core no formato libretro (`chave=valor`), aplicadas via
  /// RETRO_ENVIRONMENT_GET_VARIABLE. Usado principalmente pelo core PPSSPP.
  Map<String, String> get libretroCoreOptions => {
        'ppsspp_backend': switch (gpuBackend) {
          GpuBackend.vulkan => 'vulkan',
          GpuBackend.software => 'none',
          GpuBackend.openGL => 'opengl',
        },
        'ppsspp_software_rendering':
            gpuBackend == GpuBackend.software ? 'enabled' : 'disabled',
        'ppsspp_internal_resolution': renderResolution.coreValue,
        'ppsspp_mulitsample_level': msaaLevel.coreValue,
        'ppsspp_texture_filtering':
            textureFilter == TextureFilterMode.bilinear ? 'Linear' : 'Nearest',
        'ppsspp_texture_anisotropic_filtering':
            anisotropicFiltering ? '8x' : 'disabled',
        'ppsspp_texture_deposterize':
            textureDeposterize ? 'enabled' : 'disabled',
        'ppsspp_texture_scaling_level': 'disabled',
        'ppsspp_skip_buffer_effects': 'disabled',
        'ppsspp_skip_gpu_readbacks':
            skipGpuReadbacks ? 'enabled' : 'disabled',
        'ppsspp_lower_resolution_for_effects':
            performanceBoost ? 'Balanced' : 'disabled',
        'ppsspp_depth_raster': lensFlare ? 'low' : 'off',
        'ppsspp_frame_duplication':
            frameDuplication ? 'enabled' : 'disabled',
        'ppsspp_auto_frameskip':
            (frameSkip > 0 || performanceBoost) ? 'enabled' : 'disabled',
        'ppsspp_frameskip': frameSkip > 0
            ? '$frameSkip'
            : (performanceBoost && !frameDuplication ? '1' : 'disabled'),
        'ppsspp_inflight_frames': 'Up to 2',
        'ppsspp_cpu_core': 'JIT',
        'ppsspp_fast_memory': 'disabled',
        'ppsspp_ignore_bad_memory_access': 'enabled',
        'ppsspp_io_timing_method': 'Fast',
        'ppsspp_lazy_texture_caching':
            lazyTextureCache ? 'enabled' : 'disabled',
        'ppsspp_texture_replacement':
            textureReplacement ? 'enabled' : 'disabled',
        'ppsspp_lens_flare': lensFlare ? 'enabled' : 'disabled',
        'ppsspp_hardware_transform':
            hardwareTransform ? 'enabled' : 'disabled',
        'ppsspp_software_skinning':
            softwareSkinning ? 'enabled' : 'disabled',
      };

  AppSettings copyWith({
    int? fastForwardSpeed,
    bool? fastForwardHold,
    bool? showFastForwardButton,
    int? turboMask,
    int? turboHalfPeriodFrames,
    bool? showTurboButton,
    TouchOverlayMode? touchOverlayMode,
    bool? gpuRenderer,
    int? internalResolutionScale,
    GpuBackend? gpuBackend,
    RenderResolutionPreset? renderResolution,
    MsaaLevel? msaaLevel,
    ScreenResolutionScale? screenResolution,
    TextureFilterMode? textureFilter,
    bool? textureReplacement,
    bool? lensFlare,
    bool? skipGpuReadbacks,
    bool? lazyTextureCache,
    bool? frameDuplication,
    bool? hardwareTransform,
    bool? softwareSkinning,
    bool? anisotropicFiltering,
    bool? textureDeposterize,
    VideoFilterPreset? videoFilter,
    AspectRatioPreset? aspectRatio,
    bool? vsyncEnabled,
    int? frameSkip,
    bool? performanceBoost,
    bool? showFpsTelemetry,
    bool? hudShowFps,
    bool? hudShowResolution,
    bool? hudShowConsole,
    bool? hudShowFrameTime,
    bool? audioEnabled,
    double? masterVolume,
    bool? autoSaveOnExit,
    bool? autoLoadOnStart,
    bool? hapticVibration,
    GamepadButtonStyle? buttonStyle,
    ShoulderTriggerStyle? shoulderStyle,
    double? gamepadScale,
    double? gamepadOpacity,
    double? dpadScale,
    double? dpadOpacity,
    double? dpadSpacing,
    double? stickScale,
    double? stickOpacity,
    double? actionScale,
    double? actionOpacity,
    double? actionSpacing,
    double? shoulderScale,
    double? shoulderOpacity,
    double? shoulderSpacing,
    double? selectStartScale,
    double? selectStartOpacity,
    double? selectStartSpacing,
    double? dpadLeft,
    double? dpadBottom,
    double? stickLeft,
    double? stickBottom,
    double? actionRight,
    double? actionBottom,
    double? shoulderTop,
    double? selectStartBottom,
    String? rommServerUrl,
    String? rommApiToken,
    String? customVulkanDriverDir,
    String? customVulkanDriverName,
    String? customVulkanDriverLabel,
    bool? adrenoTurboMode,
  }) {
    return AppSettings(
      fastForwardSpeed: fastForwardSpeed ?? this.fastForwardSpeed,
      fastForwardHold: fastForwardHold ?? this.fastForwardHold,
      showFastForwardButton:
          showFastForwardButton ?? this.showFastForwardButton,
      turboMask: turboMask ?? this.turboMask,
      turboHalfPeriodFrames:
          turboHalfPeriodFrames ?? this.turboHalfPeriodFrames,
      showTurboButton: showTurboButton ?? this.showTurboButton,
      touchOverlayMode: touchOverlayMode ?? this.touchOverlayMode,
      gpuRenderer: gpuRenderer ?? this.gpuRenderer,
      internalResolutionScale:
          internalResolutionScale ?? this.internalResolutionScale,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      renderResolution: renderResolution ?? this.renderResolution,
      msaaLevel: msaaLevel ?? this.msaaLevel,
      screenResolution: screenResolution ?? this.screenResolution,
      textureFilter: textureFilter ?? this.textureFilter,
      textureReplacement: textureReplacement ?? this.textureReplacement,
      lensFlare: lensFlare ?? this.lensFlare,
      skipGpuReadbacks: skipGpuReadbacks ?? this.skipGpuReadbacks,
      lazyTextureCache: lazyTextureCache ?? this.lazyTextureCache,
      frameDuplication: frameDuplication ?? this.frameDuplication,
      hardwareTransform: hardwareTransform ?? this.hardwareTransform,
      softwareSkinning: softwareSkinning ?? this.softwareSkinning,
      anisotropicFiltering:
          anisotropicFiltering ?? this.anisotropicFiltering,
      textureDeposterize: textureDeposterize ?? this.textureDeposterize,
      videoFilter: videoFilter ?? this.videoFilter,
      aspectRatio: aspectRatio ?? this.aspectRatio,
      vsyncEnabled: vsyncEnabled ?? this.vsyncEnabled,
      frameSkip: frameSkip ?? this.frameSkip,
      performanceBoost: performanceBoost ?? this.performanceBoost,
      showFpsTelemetry: showFpsTelemetry ?? this.showFpsTelemetry,
      hudShowFps: hudShowFps ?? this.hudShowFps,
      hudShowResolution: hudShowResolution ?? this.hudShowResolution,
      hudShowConsole: hudShowConsole ?? this.hudShowConsole,
      hudShowFrameTime: hudShowFrameTime ?? this.hudShowFrameTime,
      audioEnabled: audioEnabled ?? this.audioEnabled,
      masterVolume: masterVolume ?? this.masterVolume,
      autoSaveOnExit: autoSaveOnExit ?? this.autoSaveOnExit,
      autoLoadOnStart: autoLoadOnStart ?? this.autoLoadOnStart,
      hapticVibration: hapticVibration ?? this.hapticVibration,
      buttonStyle: buttonStyle ?? this.buttonStyle,
      shoulderStyle: shoulderStyle ?? this.shoulderStyle,
      gamepadScale: gamepadScale ?? this.gamepadScale,
      gamepadOpacity: gamepadOpacity ?? this.gamepadOpacity,
      dpadScale: dpadScale ?? this.dpadScale,
      dpadOpacity: dpadOpacity ?? this.dpadOpacity,
      dpadSpacing: dpadSpacing ?? this.dpadSpacing,
      stickScale: stickScale ?? this.stickScale,
      stickOpacity: stickOpacity ?? this.stickOpacity,
      actionScale: actionScale ?? this.actionScale,
      actionOpacity: actionOpacity ?? this.actionOpacity,
      actionSpacing: actionSpacing ?? this.actionSpacing,
      shoulderScale: shoulderScale ?? this.shoulderScale,
      shoulderOpacity: shoulderOpacity ?? this.shoulderOpacity,
      shoulderSpacing: shoulderSpacing ?? this.shoulderSpacing,
      selectStartScale: selectStartScale ?? this.selectStartScale,
      selectStartOpacity: selectStartOpacity ?? this.selectStartOpacity,
      selectStartSpacing: selectStartSpacing ?? this.selectStartSpacing,
      dpadLeft: dpadLeft ?? this.dpadLeft,
      dpadBottom: dpadBottom ?? this.dpadBottom,
      stickLeft: stickLeft ?? this.stickLeft,
      stickBottom: stickBottom ?? this.stickBottom,
      actionRight: actionRight ?? this.actionRight,
      actionBottom: actionBottom ?? this.actionBottom,
      shoulderTop: shoulderTop ?? this.shoulderTop,
      selectStartBottom: selectStartBottom ?? this.selectStartBottom,
      rommServerUrl: rommServerUrl ?? this.rommServerUrl,
      rommApiToken: rommApiToken ?? this.rommApiToken,
      customVulkanDriverDir:
          customVulkanDriverDir ?? this.customVulkanDriverDir,
      customVulkanDriverName:
          customVulkanDriverName ?? this.customVulkanDriverName,
      customVulkanDriverLabel:
          customVulkanDriverLabel ?? this.customVulkanDriverLabel,
      adrenoTurboMode: adrenoTurboMode ?? this.adrenoTurboMode,
    );
  }

  AppSettings resetGamepadLayout() {
    return copyWith(
      buttonStyle: GamepadButtonStyle.gamehubGlass,
      shoulderStyle: ShoulderTriggerStyle.compactTogether,
      gamepadScale: 1.0,
      gamepadOpacity: 0.82,
      dpadScale: 1.0,
      dpadOpacity: 0.85,
      dpadSpacing: 4.0,
      stickScale: 1.0,
      stickOpacity: 0.85,
      actionScale: 1.0,
      actionOpacity: 0.85,
      actionSpacing: 6.0,
      shoulderScale: 1.0,
      shoulderOpacity: 0.88,
      shoulderSpacing: 2.0,
      selectStartScale: 0.95,
      selectStartOpacity: 0.78,
      selectStartSpacing: 12.0,
      hapticVibration: true,
      dpadLeft: 24.0,
      dpadBottom: 32.0,
      stickLeft: 186.0,
      stickBottom: 24.0,
      actionRight: 24.0,
      actionBottom: 32.0,
      shoulderTop: 18.0,
      selectStartBottom: 14.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fastForwardSpeed': fastForwardSpeed,
      'fastForwardHold': fastForwardHold,
      'showFastForwardButton': showFastForwardButton,
      'turboMask': turboMask,
      'turboHalfPeriodFrames': turboHalfPeriodFrames,
      'showTurboButton': showTurboButton,
      'touchOverlayMode': touchOverlayMode.name,
      'gpuRenderer': gpuRenderer,
      'internalResolutionScale': internalResolutionScale,
      'gpuBackend': gpuBackend.name,
      'renderResolution': renderResolution.name,
      'msaaLevel': msaaLevel.name,
      'screenResolution': screenResolution.name,
      'textureFilter': textureFilter.name,
      'textureReplacement': textureReplacement,
      'lensFlare': lensFlare,
      'skipGpuReadbacks': skipGpuReadbacks,
      'lazyTextureCache': lazyTextureCache,
      'frameDuplication': frameDuplication,
      'hardwareTransform': hardwareTransform,
      'softwareSkinning': softwareSkinning,
      'anisotropicFiltering': anisotropicFiltering,
      'textureDeposterize': textureDeposterize,
      'videoFilter': videoFilter.name,
      'aspectRatio': aspectRatio.name,
      'vsyncEnabled': vsyncEnabled,
      'frameSkip': frameSkip,
      'performanceBoost': performanceBoost,
      'showFpsTelemetry': showFpsTelemetry,
      'hudShowFps': hudShowFps,
      'hudShowResolution': hudShowResolution,
      'hudShowConsole': hudShowConsole,
      'hudShowFrameTime': hudShowFrameTime,
      'audioEnabled': audioEnabled,
      'masterVolume': masterVolume,
      'autoSaveOnExit': autoSaveOnExit,
      'autoLoadOnStart': autoLoadOnStart,
      'hapticVibration': hapticVibration,
      'buttonStyle': buttonStyle.name,
      'shoulderStyle': shoulderStyle.name,
      'gamepadScale': gamepadScale,
      'gamepadOpacity': gamepadOpacity,
      'dpadScale': dpadScale,
      'dpadOpacity': dpadOpacity,
      'dpadSpacing': dpadSpacing,
      'stickScale': stickScale,
      'stickOpacity': stickOpacity,
      'actionScale': actionScale,
      'actionOpacity': actionOpacity,
      'actionSpacing': actionSpacing,
      'shoulderScale': shoulderScale,
      'shoulderOpacity': shoulderOpacity,
      'shoulderSpacing': shoulderSpacing,
      'selectStartScale': selectStartScale,
      'selectStartOpacity': selectStartOpacity,
      'selectStartSpacing': selectStartSpacing,
      'dpadLeft': dpadLeft,
      'dpadBottom': dpadBottom,
      'stickLeft': stickLeft,
      'stickBottom': stickBottom,
      'actionRight': actionRight,
      'actionBottom': actionBottom,
      'shoulderTop': shoulderTop,
      'selectStartBottom': selectStartBottom,
      'rommServerUrl': rommServerUrl,
      'rommApiToken': rommApiToken,
      'customVulkanDriverDir': customVulkanDriverDir,
      'customVulkanDriverName': customVulkanDriverName,
      'customVulkanDriverLabel': customVulkanDriverLabel,
      'adrenoTurboMode': adrenoTurboMode,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    return AppSettings(
      fastForwardSpeed:
          ((map['fastForwardSpeed'] as num?)?.toInt() ?? 2).clamp(2, 4),
      fastForwardHold: (map['fastForwardHold'] as bool?) ?? false,
      showFastForwardButton: (map['showFastForwardButton'] as bool?) ?? true,
      turboMask: ((map['turboMask'] as num?)?.toInt() ?? 0) & 0x3FFF,
      turboHalfPeriodFrames:
          ((map['turboHalfPeriodFrames'] as num?)?.toInt() ?? 3).clamp(2, 8),
      showTurboButton: (map['showTurboButton'] as bool?) ?? true,
      touchOverlayMode: TouchOverlayMode.values.firstWhere(
        (e) => e.name == map['touchOverlayMode'],
        orElse: () => TouchOverlayMode.auto,
      ),
      gpuRenderer: (map['gpuRenderer'] as bool?) ?? true,
      internalResolutionScale:
          ((map['internalResolutionScale'] as num?)?.toInt() ?? 1).clamp(1, 4),
      gpuBackend: GpuBackend.values.firstWhere(
        (e) => e.name == map['gpuBackend'],
        // legado: gpuRenderer == false forçava software; senão padrão é Vulkan
        orElse: () => (map['gpuRenderer'] as bool?) == false
            ? GpuBackend.software
            : GpuBackend.vulkan,
      ),
      renderResolution: RenderResolutionPreset.values.firstWhere(
        (e) => e.name == map['renderResolution'],
        // legado: internalResolutionScale 1..4 → presets x1..x4
        orElse: () {
          final legacy =
              ((map['internalResolutionScale'] as num?)?.toInt() ?? 1)
                  .clamp(1, 4);
          return RenderResolutionPreset
              .values[legacy - 1];
        },
      ),
      msaaLevel: MsaaLevel.values.firstWhere(
        (e) => e.name == map['msaaLevel'],
        orElse: () => MsaaLevel.off,
      ),
      screenResolution: ScreenResolutionScale.values.firstWhere(
        (e) => e.name == map['screenResolution'],
        orElse: () => ScreenResolutionScale.native,
      ),
      textureFilter: TextureFilterMode.values.firstWhere(
        (e) => e.name == map['textureFilter'],
        orElse: () => TextureFilterMode.nearest,
      ),
      textureReplacement: (map['textureReplacement'] as bool?) ?? true,
      lensFlare: (map['lensFlare'] as bool?) ?? false,
      skipGpuReadbacks: (map['skipGpuReadbacks'] as bool?) ?? true,
      lazyTextureCache: (map['lazyTextureCache'] as bool?) ?? true,
      frameDuplication: (map['frameDuplication'] as bool?) ?? false,
      hardwareTransform: (map['hardwareTransform'] as bool?) ?? true,
      softwareSkinning: (map['softwareSkinning'] as bool?) ?? true,
      anisotropicFiltering:
          (map['anisotropicFiltering'] as bool?) ?? false,
      textureDeposterize: (map['textureDeposterize'] as bool?) ?? false,
      videoFilter: VideoFilterPreset.values.firstWhere(
        (e) => e.name == map['videoFilter'],
        orElse: () => VideoFilterPreset.sharpPixels,
      ),
      aspectRatio: AspectRatioPreset.values.firstWhere(
        (e) => e.name == map['aspectRatio'],
        orElse: () => AspectRatioPreset.consoleOriginal,
      ),
      vsyncEnabled: (map['vsyncEnabled'] as bool?) ?? false,
      frameSkip: ((map['frameSkip'] as num?)?.toInt() ?? 0).clamp(0, 2),
      performanceBoost: (map['performanceBoost'] as bool?) ?? true,
      showFpsTelemetry: (map['showFpsTelemetry'] as bool?) ?? true,
      hudShowFps: (map['hudShowFps'] as bool?) ?? true,
      hudShowResolution: (map['hudShowResolution'] as bool?) ?? true,
      hudShowConsole: (map['hudShowConsole'] as bool?) ?? true,
      hudShowFrameTime: (map['hudShowFrameTime'] as bool?) ?? false,
      audioEnabled: (map['audioEnabled'] as bool?) ?? true,
      masterVolume:
          ((map['masterVolume'] as num?)?.toDouble() ?? 0.85).clamp(0.0, 1.0),
      autoSaveOnExit: (map['autoSaveOnExit'] as bool?) ?? false,
      autoLoadOnStart: (map['autoLoadOnStart'] as bool?) ?? false,
      hapticVibration: (map['hapticVibration'] as bool?) ?? true,
      buttonStyle: GamepadButtonStyle.values.firstWhere(
        (e) => e.name == map['buttonStyle'],
        orElse: () => GamepadButtonStyle.gamehubGlass,
      ),
      shoulderStyle: ShoulderTriggerStyle.values.firstWhere(
        (e) => e.name == map['shoulderStyle'],
        orElse: () => ShoulderTriggerStyle.compactTogether,
      ),
      gamepadScale:
          ((map['gamepadScale'] as num?)?.toDouble() ?? 1.0).clamp(0.65, 1.45),
      gamepadOpacity:
          ((map['gamepadOpacity'] as num?)?.toDouble() ?? 0.82).clamp(0.20, 1.0),
      dpadScale:
          ((map['dpadScale'] as num?)?.toDouble() ?? 1.0).clamp(0.65, 1.45),
      dpadOpacity:
          ((map['dpadOpacity'] as num?)?.toDouble() ?? 0.85).clamp(0.20, 1.0),
      dpadSpacing:
          ((map['dpadSpacing'] as num?)?.toDouble() ?? 4.0).clamp(0.0, 24.0),
      stickScale:
          ((map['stickScale'] as num?)?.toDouble() ?? 1.0).clamp(0.65, 1.45),
      stickOpacity:
          ((map['stickOpacity'] as num?)?.toDouble() ?? 0.85).clamp(0.20, 1.0),
      actionScale:
          ((map['actionScale'] as num?)?.toDouble() ?? 1.0).clamp(0.65, 1.45),
      actionOpacity:
          ((map['actionOpacity'] as num?)?.toDouble() ?? 0.85).clamp(0.20, 1.0),
      actionSpacing:
          ((map['actionSpacing'] as num?)?.toDouble() ?? 6.0).clamp(0.0, 24.0),
      shoulderScale:
          ((map['shoulderScale'] as num?)?.toDouble() ?? 1.0).clamp(0.65, 1.45),
      shoulderOpacity:
          ((map['shoulderOpacity'] as num?)?.toDouble() ?? 0.88).clamp(0.20, 1.0),
      shoulderSpacing:
          ((map['shoulderSpacing'] as num?)?.toDouble() ?? 2.0).clamp(0.0, 24.0),
      selectStartScale:
          ((map['selectStartScale'] as num?)?.toDouble() ?? 0.95).clamp(0.65, 1.45),
      selectStartOpacity:
          ((map['selectStartOpacity'] as num?)?.toDouble() ?? 0.78).clamp(0.20, 1.0),
      selectStartSpacing:
          ((map['selectStartSpacing'] as num?)?.toDouble() ?? 12.0).clamp(4.0, 48.0),
      dpadLeft: ((map['dpadLeft'] as num?)?.toDouble() ?? 24.0).clamp(8.0, 420.0),
      dpadBottom:
          ((map['dpadBottom'] as num?)?.toDouble() ?? 32.0).clamp(8.0, 280.0),
      stickLeft:
          ((map['stickLeft'] as num?)?.toDouble() ?? 186.0).clamp(8.0, 460.0),
      stickBottom:
          ((map['stickBottom'] as num?)?.toDouble() ?? 24.0).clamp(8.0, 280.0),
      actionRight:
          ((map['actionRight'] as num?)?.toDouble() ?? 24.0).clamp(8.0, 420.0),
      actionBottom:
          ((map['actionBottom'] as num?)?.toDouble() ?? 32.0).clamp(8.0, 280.0),
      shoulderTop:
          ((map['shoulderTop'] as num?)?.toDouble() ?? 18.0).clamp(10.0, 200.0),
      selectStartBottom:
          ((map['selectStartBottom'] as num?)?.toDouble() ?? 14.0).clamp(6.0, 200.0),
      rommServerUrl: (map['rommServerUrl'] as String?) ?? '',
      rommApiToken: (map['rommApiToken'] as String?) ?? '',
      customVulkanDriverDir: (map['customVulkanDriverDir'] as String?) ?? '',
      customVulkanDriverName: (map['customVulkanDriverName'] as String?) ?? '',
      customVulkanDriverLabel:
          (map['customVulkanDriverLabel'] as String?) ?? '',
      adrenoTurboMode: (map['adrenoTurboMode'] as bool?) ?? false,
    );
  }
}
