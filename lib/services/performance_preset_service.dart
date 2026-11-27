import '../models/app_settings.dart';
import 'device_profile_service.dart';

/// Resultado de um auto-ajuste: configuração nova + o que mudou, em texto.
class PerformanceTuning {
  const PerformanceTuning({
    required this.settings,
    required this.changes,
    required this.tier,
    required this.headline,
  });

  final AppSettings settings;
  final List<String> changes;
  final DeviceTier tier;
  final String headline;
}

/// Calibra as opções gráficas para mirar 60 fps estáveis.
///
/// A regra é simples: identifica a faixa do aparelho pela RAM/núcleos, aplica
/// o preset dessa faixa e corrige o que costuma doer em cada fabricante
/// (Mali/Exynos pede OpenGL; Adreno vai bem de Vulkan; 3 GB pede frameskip).
class PerformancePresetService {
  PerformancePresetService._();

  static PerformanceTuning tune(
    AppSettings base, {
    required DeviceProfile profile,
    bool preferQuality = false,
  }) {
    final tier = profile.tier;
    final changes = <String>[];

    // Resolution / MSAA
    final targetRes = switch (tier) {
      DeviceTier.weak => RenderResolutionPreset.x1,
      DeviceTier.mid => RenderResolutionPreset.x1,
      DeviceTier.strong =>
        preferQuality ? RenderResolutionPreset.x2 : RenderResolutionPreset.x1,
      DeviceTier.flagship =>
        preferQuality ? RenderResolutionPreset.x3 : RenderResolutionPreset.x2,
    };

    var frameSkip = 0;
    if (tier == DeviceTier.weak) frameSkip = 1;
    if (profile.underMemoryPressure) frameSkip += 1;
    frameSkip = frameSkip.clamp(0, 3);

    // Mali/Exynos historicamente engasga com Vulkan em vários cores.
    final backend = profile.isMali && tier != DeviceTier.flagship
        ? GpuBackend.openGL
        : GpuBackend.vulkan;

    final msaa = tier == DeviceTier.flagship && preferQuality
        ? MsaaLevel.x2
        : MsaaLevel.off;

    var tuned = base.copyWith(
      gpuRenderer: true,
      gpuBackend: backend,
      renderResolution: targetRes,
      msaaLevel: msaa,
      screenResolution: ScreenResolutionScale.native,
      textureFilter: TextureFilterMode.nearest,
      anisotropicFiltering: false,
      textureDeposterize: false,
      lensFlare: false,
      skipGpuReadbacks: true,
      lazyTextureCache: true,
      frameDuplication: false,
      hardwareTransform: true,
      softwareSkinning: true,
      videoFilter: VideoFilterPreset.sharpPixels,
      vsyncEnabled: false,
      frameSkip: frameSkip,
      performanceBoost: true,
    );

    // RAM apertada: texturas de reposição e cache ocioso custam caro.
    if (tier == DeviceTier.weak && !preferQuality) {
      tuned = tuned.copyWith(
        textureReplacement: false,
        hudShowFrameTime: false,
        showFpsTelemetry: true,
        hudShowFps: true,
      );
      changes.add('Texturas de reposição desligadas (RAM curta)');
    }

    changes
      ..add('Resolução: ${targetRes.label}')
      ..add('Backend: ${backend.label}')
      ..add('Frameskip: $frameSkip (${frameSkip == 0 ? 'nenhum' : 'até $frameSkip quadro(s)'})')
      ..add('MSAA: ${msaa.label}')
      ..add('Leitura de GPU: desativada (ganho direto de FPS)')
      ..add('Filtro: Pixel Nítido, sem V-Sync');

    if (profile.isMali) {
      changes.add('SoC Mali/Exynos detectado — OpenGL evita travadas de Vulkan');
    } else if (profile.isQualcomm) {
      changes.add('SoC Qualcomm Adreno — Vulkan é o caminho mais rápido');
    }
    if (profile.isSamsung) {
      changes.add('Samsung: escala nativa + frameskip curto seguram 60 fps no Game Optimizing Service');
    } else if (profile.isXiaomi) {
      changes.add('Xiaomi/Redmi: modo performance ativo, sem V-Sync para o MIUI não travar o compositor');
    } else if (profile.isMotorola) {
      changes.add('Motorola: leitura de GPU desligada compensa o driver mais lento');
    }

    final headline = switch (tier) {
      DeviceTier.weak => 'Preset Fraco: 1x, frameskip $frameSkip, alvo 55–60 fps',
      DeviceTier.mid => 'Preset Médio: 1x, sem frameskip, alvo 60 fps',
      DeviceTier.strong =>
        'Preset Forte: ${targetRes.label}, sem frameskip, alvo 60 fps',
      DeviceTier.flagship =>
        'Preset Topo: ${targetRes.label}, MSAA ${msaa.label}, alvo 60 fps',
    };

    return PerformanceTuning(
      settings: tuned,
      changes: changes,
      tier: tier,
      headline: headline,
    );
  }
}
