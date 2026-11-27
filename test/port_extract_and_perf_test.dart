import 'package:flutter_test/flutter_test.dart';
import 'package:loopgamer/models/app_settings.dart';
import 'package:loopgamer/services/archive_extract_service.dart';
import 'package:loopgamer/services/device_profile_service.dart';
import 'package:loopgamer/services/performance_preset_service.dart';

DeviceProfile _profile({
  int ramMb = 4096,
  int cores = 8,
  bool lowRam = false,
  int availMb = 2000,
  String manufacturer = 'samsung',
  String model = 'SM-A546E',
  String soc = 'exynos 1380',
}) {
  return DeviceProfile(
    totalMemMb: ramMb,
    availMemMb: availMb,
    cores: cores,
    lowRam: lowRam,
    sdkInt: 34,
    manufacturer: manufacturer,
    model: model,
    soc: soc,
  );
}

void main() {
  group('DeviceProfile', () {
    test('classifica 3 GB como fraco mesmo com 8 núcleos', () {
      final p = _profile(ramMb: 3000, cores: 8);
      expect(p.tier, DeviceTier.weak);
    });

    test('classifica 4 a 6 GB como intermediário', () {
      expect(_profile(ramMb: 4096).tier, DeviceTier.mid);
      expect(_profile(ramMb: 6000).tier, DeviceTier.mid);
    });

    test('classifica 8 GB como forte e 12 GB como topo', () {
      expect(_profile(ramMb: 8000).tier, DeviceTier.strong);
      expect(_profile(ramMb: 12000).tier, DeviceTier.flagship);
    });

    test('detecta fabricante mesmo com caixa diferente', () {
      expect(
        _profile(manufacturer: 'Xiaomi', model: 'Redmi Note 12').isXiaomi,
        isTrue,
      );
      expect(_profile(manufacturer: 'motorola').isMotorola, isTrue);
      expect(_profile(manufacturer: 'Samsung').isSamsung, isTrue);
    });

    test('memória livre curta sinaliza pressão', () {
      expect(_profile(availMb: 500).underMemoryPressure, isTrue);
      expect(_profile(availMb: 2500).underMemoryPressure, isFalse);
    });
  });

  group('PerformancePresetService', () {
    test('aparelho fraco recebe frameskip e 1x', () {
      final tuning = PerformancePresetService.tune(
        const AppSettings(renderResolution: RenderResolutionPreset.x4),
        profile: _profile(ramMb: 3000, availMb: 1500),
      );
      expect(tuning.settings.renderResolution, RenderResolutionPreset.x1);
      expect(tuning.settings.frameSkip, 1);
      expect(tuning.settings.msaaLevel, MsaaLevel.off);
      expect(tuning.settings.skipGpuReadbacks, isTrue);
      expect(tuning.settings.performanceBoost, isTrue);
      expect(tuning.tier, DeviceTier.weak);
    });

    test('pressão de memória soma um degrau de frameskip', () {
      final tuning = PerformancePresetService.tune(
        const AppSettings(),
        profile: _profile(ramMb: 3000, availMb: 400),
      );
      expect(tuning.settings.frameSkip, 2);
    });

    test('Mali/Exynos fora do topo cai para OpenGL', () {
      final tuning = PerformancePresetService.tune(
        const AppSettings(),
        profile: _profile(soc: 'exynos 2200', ramMb: 8000),
      );
      expect(tuning.settings.gpuBackend, GpuBackend.openGL);
    });

    test('Adreno mantém Vulkan', () {
      final tuning = PerformancePresetService.tune(
        const AppSettings(),
        profile: _profile(soc: 'SM8550', manufacturer: 'Xiaomi', ramMb: 12000),
      );
      expect(tuning.settings.gpuBackend, GpuBackend.vulkan);
    });

    test('topo de linha com nitidez sobe resolução e MSAA', () {
      final tuning = PerformancePresetService.tune(
        const AppSettings(),
        profile: _profile(ramMb: 16384, manufacturer: 'samsung', soc: 'SM8650'),
        preferQuality: true,
      );
      expect(tuning.settings.renderResolution, RenderResolutionPreset.x3);
      expect(tuning.settings.msaaLevel, MsaaLevel.x2);
      expect(tuning.changes, isNotEmpty);
      expect(tuning.headline, contains('60 fps'));
    });
  });

  group('ArchiveExtractService.canExtractPath', () {
    test('aceita formatos compactados', () {
      expect(ArchiveExtractService.canExtractPath('/a/b/game.7z'), isTrue);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.zip'), isTrue);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.rar'), isTrue);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.tar.xz'), isTrue);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.tgz'), isTrue);
    });

    test('recusa imagem e obb', () {
      expect(ArchiveExtractService.canExtractPath('/a/b/game.iso'), isFalse);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.rvz'), isFalse);
      expect(ArchiveExtractService.canExtractPath('/a/b/game.obb'), isFalse);
      expect(ArchiveExtractService.canExtractPath(''), isFalse);
    });

    test('aceita URL com query string', () {
      expect(
        ArchiveExtractService.canExtractPath(
          'https://dl.apkvision.net/x/Silksong.apk?sig=1',
        ),
        isFalse,
      );
      expect(
        ArchiveExtractService.canExtractPath(
          'https://dl.apkvision.net/x/Silksong.zip?token=abc',
        ),
        isTrue,
      );
    });
  });
}
