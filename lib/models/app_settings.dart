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
  sideBySide('Separados', 'Gatilhos lado a lado tradicionais'),
  singleLR(
    'Gatilho Único (L / R)',
    'Apenas L e R maiores (automático em PSP / God of War, GBA e SNES)',
  );

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

enum TurnipFreedrenoPreset {
  standard('Padrão', 'Configuração padrão do driver Vulkan/Turnip', ''),
  sysmem('Sysmem', 'Desativa tiling GMEM (corrige glitch em algumas Adreno)', 'sysmem'),
  noubwc('Sem UBWC', 'Desativa compressão UBWC para compatibilidade extra', 'noubwc'),
  nobin('Sem Binning', 'Desativa binning Freedreno em cenas complexas', 'nobin'),
  gmem('GMEM Forçado', 'Força cache GMEM em Adreno para maior throughput', 'gmem');

  const TurnipFreedrenoPreset(this.label, this.description, this.envValue);
  final String label;
  final String description;
  final String envValue;
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

enum HudOverlayToggleKind {
  masterBar,
  fps,
  resolution,
  consoleName,
  frameTime,
}

/// Especificação única dos toggles do HUD em jogo, compartilhada entre
/// configurações globais e sidebar/modal do player.
class HudOverlayToggleSpec {
  const HudOverlayToggleSpec({
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.isMaster,
    required this.readValue,
    required this.applyValue,
  });

  final HudOverlayToggleKind kind;
  final String title;
  final String subtitle;
  final bool isMaster;
  final bool Function(AppSettings settings) readValue;
  final AppSettings Function(AppSettings settings, bool value) applyValue;

  bool isEnabled(AppSettings settings) =>
      isMaster || settings.showFpsTelemetry;
}

class AppSettings {
  static const int currentSchemaVersion = 2;

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
    this.dpadButtonStyle,
    this.stickButtonStyle,
    this.actionButtonStyle,
    this.shoulderButtonStyle,
    this.selectStartButtonStyle,
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
    this.freedrenoPreset = TurnipFreedrenoPreset.standard,
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
  final GamepadButtonStyle? dpadButtonStyle;
  final GamepadButtonStyle? stickButtonStyle;
  final GamepadButtonStyle? actionButtonStyle;
  final GamepadButtonStyle? shoulderButtonStyle;
  final GamepadButtonStyle? selectStartButtonStyle;
  final ShoulderTriggerStyle shoulderStyle;

  GamepadButtonStyle get effectiveDpadStyle => dpadButtonStyle ?? buttonStyle;
  GamepadButtonStyle get effectiveStickStyle => stickButtonStyle ?? buttonStyle;
  GamepadButtonStyle get effectiveActionStyle =>
      actionButtonStyle ?? buttonStyle;
  GamepadButtonStyle get effectiveShoulderStyle =>
      shoulderButtonStyle ?? buttonStyle;
  GamepadButtonStyle get effectiveSelectStartStyle =>
      selectStartButtonStyle ?? buttonStyle;
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
  final TurnipFreedrenoPreset freedrenoPreset;

  /// Consoles que possuem apenas gatilhos simples L e R (sem L2/R2 no controle original).
  static const Set<String> singleTriggerPlatforms = <String>{
    'psp',
    'gba',
    'snes',
    'nds',
    'gbc',
    'gb',
    'nes',
    'gamegear',
    'mastersystem',
    'md',
    'pce',
  };

  static bool isSingleTriggerPlatform(String platformSlug) =>
      singleTriggerPlatforms.contains(platformSlug.trim().toLowerCase());

  /// Valida se [raw] é uma URL HTTP/HTTPS bem formada com host não vazio.
  /// Para limpar/desconectar o servidor RomM, o chamador pode tratar string vazia antes.
  static bool isValidRommServerUrl(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || trimmed.contains(RegExp(r'\s'))) {
      return false;
    }
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !uri.hasScheme) {
      return false;
    }
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https') {
      return false;
    }
    return uri.hasAuthority && uri.host.trim().isNotEmpty;
  }

  static bool _readShowFpsTelemetry(AppSettings s) => s.showFpsTelemetry;
  static bool _readHudShowFps(AppSettings s) => s.hudShowFps;
  static bool _readHudShowResolution(AppSettings s) => s.hudShowResolution;
  static bool _readHudShowConsole(AppSettings s) => s.hudShowConsole;
  static bool _readHudShowFrameTime(AppSettings s) => s.hudShowFrameTime;

  static AppSettings _writeShowFpsTelemetry(AppSettings s, bool v) =>
      s.copyWith(showFpsTelemetry: v);
  static AppSettings _writeHudShowFps(AppSettings s, bool v) =>
      s.copyWith(hudShowFps: v);
  static AppSettings _writeHudShowResolution(AppSettings s, bool v) =>
      s.copyWith(hudShowResolution: v);
  static AppSettings _writeHudShowConsole(AppSettings s, bool v) =>
      s.copyWith(hudShowConsole: v);
  static AppSettings _writeHudShowFrameTime(AppSettings s, bool v) =>
      s.copyWith(hudShowFrameTime: v);

  /// Especificação compartilhada dos 5 toggles do HUD (elimina cópias duplicadas).
  static const List<HudOverlayToggleSpec> hudToggleSpecs = [
    HudOverlayToggleSpec(
      kind: HudOverlayToggleKind.masterBar,
      title: 'Exibir Barra de Informações (HUD)',
      subtitle: 'Ativa ou oculta todos os indicadores técnicos durante a partida',
      isMaster: true,
      readValue: _readShowFpsTelemetry,
      applyValue: _writeShowFpsTelemetry,
    ),
    HudOverlayToggleSpec(
      kind: HudOverlayToggleKind.fps,
      title: 'Mostrar Contador de FPS',
      subtitle: 'Exibe a taxa de quadros por segundo (ex.: 60 FPS)',
      isMaster: false,
      readValue: _readHudShowFps,
      applyValue: _writeHudShowFps,
    ),
    HudOverlayToggleSpec(
      kind: HudOverlayToggleKind.resolution,
      title: 'Mostrar Multiplicador de Resolução',
      subtitle: 'Exibe a resolução interna ativa (ex.: 2x, 3x, 4x)',
      isMaster: false,
      readValue: _readHudShowResolution,
      applyValue: _writeHudShowResolution,
    ),
    HudOverlayToggleSpec(
      kind: HudOverlayToggleKind.consoleName,
      title: 'Mostrar Plataforma / Console',
      subtitle: 'Exibe o console em execução (ex.: PSP, PS1, GBA)',
      isMaster: false,
      readValue: _readHudShowConsole,
      applyValue: _writeHudShowConsole,
    ),
    HudOverlayToggleSpec(
      kind: HudOverlayToggleKind.frameTime,
      title: 'Mostrar Tempo de Quadro (ms)',
      subtitle: 'Exibe a latência de renderização (ex.: 16.6 ms)',
      isMaster: false,
      readValue: _readHudShowFrameTime,
      applyValue: _writeHudShowFrameTime,
    ),
  ];

  bool shouldUseSingleTriggers(String platformSlug) =>
      shoulderStyle == ShoulderTriggerStyle.singleLR ||
      isSingleTriggerPlatform(platformSlug);

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
        'ppsspp_fast_memory': 'enabled',
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
        // Play! (PS2): 2x padrão evita visual pixelado em 640x448 e
        // bilinear suaviza polígonos 3D sem cintilação.
        'play_res_multi': switch (renderResolution) {
          RenderResolutionPreset.x1 || RenderResolutionPreset.x2 => '2x',
          RenderResolutionPreset.x3 ||
          RenderResolutionPreset.x4 ||
          RenderResolutionPreset.p1080 =>
            '4x',
          _ => '8x',
        },
        'play_bilinear_filtering': 'true',
        'play_presentation_mode': 'Fit Screen',
        // RPCS3 (PS3) — ajustes estáveis para Android: mantém HLE lwmutex, SPU
        // verification e streaming de texturas nos padrões seguros do núcleo
        // e limita threads LLVM/shader para evitar OOM ao finalizar compilação.
        'rpcs3_database_override': 'disabled',
        'rpcs3_ppu_decoder': 'llvm',
        'rpcs3_spu_decoder': 'llvm',
        'rpcs3_ppu_threads': '2',
        'rpcs3_llvm_threads': '2',
        'rpcs3_llvm_precompilation': 'enabled',
        'rpcs3_shader_mode': 'async',
        'rpcs3_shader_compiler_threads': '1',
        'rpcs3_shader_quality': 'low',
        'rpcs3_spu_block_size': 'safe',
        'rpcs3_spu_cache': 'enabled',
        'rpcs3_spu_verification': 'enabled',
        'rpcs3_spu_loop_detection': 'disabled',
        'rpcs3_strict_rendering': 'disabled',
        'rpcs3_write_color_buffers': 'disabled',
        'rpcs3_async_texture_streaming': 'disabled',
        'rpcs3_emulate_hdd_speed': 'disabled',
        'rpcs3_emulate_bdvd_speed': 'disabled',
        'rpcs3_hle_lwmutex': 'disabled',
        'rpcs3_multithreaded_rsx': 'disabled',
        'rpcs3_thread_scheduler': 'os',
        'rpcs3_silence_all_logs': 'disabled',
        'rpcs3_resolution_scale': '100',
        'rpcs3_default_resolution': '720p',
        'rpcs3_frame_limit': 'auto',
        'rpcs3_driver_wakeup_delay': '0',
        'rpcs3_driver_recovery_timeout': '1000',
        'rpcs3_sleep_timers_accuracy': 'auto',
        'rpcs3_max_spurs_threads': '4',
        'rpcs3_disk_cache_size': '1gb',
        'rpcs3_show_ppu_compilation_hint': 'enabled',
        'rpcs3_show_shader_compilation_hint': 'enabled',
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
    GamepadButtonStyle? dpadButtonStyle,
    GamepadButtonStyle? stickButtonStyle,
    GamepadButtonStyle? actionButtonStyle,
    GamepadButtonStyle? shoulderButtonStyle,
    GamepadButtonStyle? selectStartButtonStyle,
    bool clearElementButtonStyles = false,
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
    TurnipFreedrenoPreset? freedrenoPreset,
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
      dpadButtonStyle: clearElementButtonStyles
          ? null
          : (dpadButtonStyle ?? this.dpadButtonStyle),
      stickButtonStyle: clearElementButtonStyles
          ? null
          : (stickButtonStyle ?? this.stickButtonStyle),
      actionButtonStyle: clearElementButtonStyles
          ? null
          : (actionButtonStyle ?? this.actionButtonStyle),
      shoulderButtonStyle: clearElementButtonStyles
          ? null
          : (shoulderButtonStyle ?? this.shoulderButtonStyle),
      selectStartButtonStyle: clearElementButtonStyles
          ? null
          : (selectStartButtonStyle ?? this.selectStartButtonStyle),
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
      freedrenoPreset: freedrenoPreset ?? this.freedrenoPreset,
    );
  }

  AppSettings resetGamepadLayout() {
    return copyWith(
      buttonStyle: GamepadButtonStyle.gamehubGlass,
      clearElementButtonStyles: true,
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
      'version': currentSchemaVersion,
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
      if (dpadButtonStyle != null) 'dpadButtonStyle': dpadButtonStyle!.name,
      if (stickButtonStyle != null) 'stickButtonStyle': stickButtonStyle!.name,
      if (actionButtonStyle != null)
        'actionButtonStyle': actionButtonStyle!.name,
      if (shoulderButtonStyle != null)
        'shoulderButtonStyle': shoulderButtonStyle!.name,
      if (selectStartButtonStyle != null)
        'selectStartButtonStyle': selectStartButtonStyle!.name,
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
      'freedrenoPreset': freedrenoPreset.name,
    };
  }

  static bool _asBool(Map<String, dynamic> map, String key, bool fallback) {
    final v = map[key];
    return v is bool ? v : fallback;
  }

  static int _asInt(Map<String, dynamic> map, String key, int fallback) {
    final v = map[key];
    return v is num ? v.toInt() : fallback;
  }

  static double _asDouble(
    Map<String, dynamic> map,
    String key,
    double fallback,
  ) {
    final v = map[key];
    return v is num ? v.toDouble() : fallback;
  }

  static String _asString(
    Map<String, dynamic> map,
    String key,
    String fallback,
  ) {
    final v = map[key];
    return v is String ? v : fallback;
  }

  static GamepadButtonStyle? _asOptionalButtonStyle(
    Map<String, dynamic> map,
    String key,
  ) {
    final raw = map[key];
    if (raw is! String || raw.isEmpty) return null;
    for (final style in GamepadButtonStyle.values) {
      if (style.name == raw) return style;
    }
    return null;
  }

  factory AppSettings.fromJson(Map<String, dynamic> map) {
    // Configs antigos sem campo 'version' são tratados como esquema v1 e migrados suavemente.
    final legacyGpuRenderer = _asBool(map, 'gpuRenderer', true);
    final legacyResolutionScale =
        _asInt(map, 'internalResolutionScale', 1).clamp(1, 4);

    return AppSettings(
      fastForwardSpeed: _asInt(map, 'fastForwardSpeed', 2).clamp(2, 4),
      fastForwardHold: _asBool(map, 'fastForwardHold', false),
      showFastForwardButton: _asBool(map, 'showFastForwardButton', true),
      turboMask: _asInt(map, 'turboMask', 0) & 0x3FFF,
      turboHalfPeriodFrames:
          _asInt(map, 'turboHalfPeriodFrames', 3).clamp(2, 8),
      showTurboButton: _asBool(map, 'showTurboButton', true),
      touchOverlayMode: TouchOverlayMode.values.firstWhere(
        (e) => e.name == map['touchOverlayMode'],
        orElse: () => TouchOverlayMode.auto,
      ),
      gpuRenderer: legacyGpuRenderer,
      internalResolutionScale: legacyResolutionScale,
      gpuBackend: GpuBackend.values.firstWhere(
        (e) => e.name == map['gpuBackend'],
        // legado: gpuRenderer == false forçava software; senão padrão é Vulkan
        orElse: () =>
            !legacyGpuRenderer ? GpuBackend.software : GpuBackend.vulkan,
      ),
      renderResolution: RenderResolutionPreset.values.firstWhere(
        (e) => e.name == map['renderResolution'],
        // legado: internalResolutionScale 1..4 → presets x1..x4
        orElse: () => RenderResolutionPreset.values[legacyResolutionScale - 1],
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
      textureReplacement: _asBool(map, 'textureReplacement', true),
      lensFlare: _asBool(map, 'lensFlare', false),
      skipGpuReadbacks: _asBool(map, 'skipGpuReadbacks', true),
      lazyTextureCache: _asBool(map, 'lazyTextureCache', true),
      frameDuplication: _asBool(map, 'frameDuplication', false),
      hardwareTransform: _asBool(map, 'hardwareTransform', true),
      softwareSkinning: _asBool(map, 'softwareSkinning', true),
      anisotropicFiltering: _asBool(map, 'anisotropicFiltering', false),
      textureDeposterize: _asBool(map, 'textureDeposterize', false),
      videoFilter: VideoFilterPreset.values.firstWhere(
        (e) => e.name == map['videoFilter'],
        orElse: () => VideoFilterPreset.sharpPixels,
      ),
      aspectRatio: AspectRatioPreset.values.firstWhere(
        (e) => e.name == map['aspectRatio'],
        orElse: () => AspectRatioPreset.consoleOriginal,
      ),
      vsyncEnabled: _asBool(map, 'vsyncEnabled', false),
      frameSkip: _asInt(map, 'frameSkip', 0).clamp(0, 2),
      performanceBoost: _asBool(map, 'performanceBoost', true),
      showFpsTelemetry: _asBool(map, 'showFpsTelemetry', true),
      hudShowFps: _asBool(map, 'hudShowFps', true),
      hudShowResolution: _asBool(map, 'hudShowResolution', true),
      hudShowConsole: _asBool(map, 'hudShowConsole', true),
      hudShowFrameTime: _asBool(map, 'hudShowFrameTime', false),
      audioEnabled: _asBool(map, 'audioEnabled', true),
      masterVolume: _asDouble(map, 'masterVolume', 0.85).clamp(0.0, 1.0),
      autoSaveOnExit: _asBool(map, 'autoSaveOnExit', false),
      autoLoadOnStart: _asBool(map, 'autoLoadOnStart', false),
      hapticVibration: _asBool(map, 'hapticVibration', true),
      buttonStyle: GamepadButtonStyle.values.firstWhere(
        (e) => e.name == map['buttonStyle'],
        orElse: () => GamepadButtonStyle.gamehubGlass,
      ),
      dpadButtonStyle: _asOptionalButtonStyle(map, 'dpadButtonStyle'),
      stickButtonStyle: _asOptionalButtonStyle(map, 'stickButtonStyle'),
      actionButtonStyle: _asOptionalButtonStyle(map, 'actionButtonStyle'),
      shoulderButtonStyle: _asOptionalButtonStyle(map, 'shoulderButtonStyle'),
      selectStartButtonStyle: _asOptionalButtonStyle(
        map,
        'selectStartButtonStyle',
      ),
      shoulderStyle: ShoulderTriggerStyle.values.firstWhere(
        (e) => e.name == map['shoulderStyle'],
        orElse: () => ShoulderTriggerStyle.compactTogether,
      ),
      gamepadScale: _asDouble(map, 'gamepadScale', 1.0).clamp(0.65, 1.45),
      gamepadOpacity: _asDouble(map, 'gamepadOpacity', 0.82).clamp(0.20, 1.0),
      dpadScale: _asDouble(map, 'dpadScale', 1.0).clamp(0.65, 1.45),
      dpadOpacity: _asDouble(map, 'dpadOpacity', 0.85).clamp(0.20, 1.0),
      dpadSpacing: _asDouble(map, 'dpadSpacing', 4.0).clamp(0.0, 24.0),
      stickScale: _asDouble(map, 'stickScale', 1.0).clamp(0.65, 1.45),
      stickOpacity: _asDouble(map, 'stickOpacity', 0.85).clamp(0.20, 1.0),
      actionScale: _asDouble(map, 'actionScale', 1.0).clamp(0.65, 1.45),
      actionOpacity: _asDouble(map, 'actionOpacity', 0.85).clamp(0.20, 1.0),
      actionSpacing: _asDouble(map, 'actionSpacing', 6.0).clamp(0.0, 24.0),
      shoulderScale: _asDouble(map, 'shoulderScale', 1.0).clamp(0.65, 1.45),
      shoulderOpacity: _asDouble(map, 'shoulderOpacity', 0.88).clamp(0.20, 1.0),
      shoulderSpacing: _asDouble(map, 'shoulderSpacing', 2.0).clamp(0.0, 24.0),
      selectStartScale:
          _asDouble(map, 'selectStartScale', 0.95).clamp(0.65, 1.45),
      selectStartOpacity:
          _asDouble(map, 'selectStartOpacity', 0.78).clamp(0.20, 1.0),
      selectStartSpacing:
          _asDouble(map, 'selectStartSpacing', 12.0).clamp(4.0, 48.0),
      dpadLeft: _asDouble(map, 'dpadLeft', 24.0).clamp(8.0, 420.0),
      dpadBottom: _asDouble(map, 'dpadBottom', 32.0).clamp(8.0, 280.0),
      stickLeft: _asDouble(map, 'stickLeft', 186.0).clamp(8.0, 460.0),
      stickBottom: _asDouble(map, 'stickBottom', 24.0).clamp(8.0, 280.0),
      actionRight: _asDouble(map, 'actionRight', 24.0).clamp(8.0, 420.0),
      actionBottom: _asDouble(map, 'actionBottom', 32.0).clamp(8.0, 280.0),
      shoulderTop: _asDouble(map, 'shoulderTop', 18.0).clamp(10.0, 200.0),
      selectStartBottom:
          _asDouble(map, 'selectStartBottom', 14.0).clamp(6.0, 200.0),
      rommServerUrl: _asString(map, 'rommServerUrl', ''),
      rommApiToken: _asString(map, 'rommApiToken', ''),
      customVulkanDriverDir: _asString(map, 'customVulkanDriverDir', ''),
      customVulkanDriverName: _asString(map, 'customVulkanDriverName', ''),
      customVulkanDriverLabel: _asString(map, 'customVulkanDriverLabel', ''),
      adrenoTurboMode: _asBool(map, 'adrenoTurboMode', false),
      freedrenoPreset: TurnipFreedrenoPreset.values.firstWhere(
        (e) => e.name == map['freedrenoPreset'],
        orElse: () => TurnipFreedrenoPreset.standard,
      ),
    );
  }
}
