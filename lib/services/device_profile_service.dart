import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Faixa de hardware usada para calibrar o preset gráfico.
enum DeviceTier {
  /// Até 3 GB de RAM — aparelhos de entrada (Galaxy A0x, Redmi 9A, Moto E).
  weak,

  /// 4 a 6 GB — intermediário (Galaxy A3x/A5x, Redmi Note 1x, Moto G5x).
  mid,

  /// 7 a 11 GB — intermediário-premium (Galaxy S21 FE, Redmi Note Pro, Edge 40).
  strong,

  /// 12 GB ou mais / lowRam = false com 8 núcleos — topo de linha.
  flagship,
}

extension DeviceTierX on DeviceTier {
  String get label => switch (this) {
        DeviceTier.weak => 'Aparelho fraco',
        DeviceTier.mid => 'Intermediário',
        DeviceTier.strong => 'Intermediário forte',
        DeviceTier.flagship => 'Topo de linha',
      };

  String get hint => switch (this) {
        DeviceTier.weak => '1x de resolução, frameskip 1, 55–60 fps',
        DeviceTier.mid => '1x de resolução, frameskip 0, 60 fps',
        DeviceTier.strong => '1x–2x, MSAA off, 60 fps',
        DeviceTier.flagship => '2x de resolução, MSAA 2x, 60 fps',
      };
}

/// Perfil real do aparelho lido pelo canal nativo (RAM total, núcleos, SoC).
class DeviceProfile {
  const DeviceProfile({
    required this.totalMemMb,
    required this.availMemMb,
    required this.cores,
    required this.lowRam,
    required this.sdkInt,
    required this.manufacturer,
    required this.model,
    required this.soc,
  });

  final int totalMemMb;
  final int availMemMb;
  final int cores;
  final bool lowRam;
  final int sdkInt;
  final String manufacturer;
  final String model;
  final String soc;

  static const DeviceProfile unknown = DeviceProfile(
    totalMemMb: 0,
    availMemMb: 0,
    cores: 4,
    lowRam: false,
    sdkInt: 0,
    manufacturer: '',
    model: '',
    soc: '',
  );

  bool get isKnown => totalMemMb > 0;

  /// Fabricante normalizado, útil para regras específicas.
  String get brand => manufacturer.toLowerCase();

  bool get isSamsung => brand.contains('samsung');
  bool get isXiaomi => brand.contains('xiaomi') || brand.contains('redmi') ||
      brand.contains('poco');
  bool get isMotorola => brand.contains('motorola') || brand.contains('moto');
  bool get isQualcomm => soc.toLowerCase().contains('sm') ||
      soc.toLowerCase().contains('msm') ||
      soc.toLowerCase().contains('qualcomm');
  bool get isMali => soc.toLowerCase().contains('exynos') ||
      soc.toLowerCase().contains('mt') ||
      soc.toLowerCase().contains('helio') ||
      soc.toLowerCase().contains('dimensity');

  DeviceTier get tier {
    if (!isKnown) return cores >= 8 ? DeviceTier.strong : DeviceTier.mid;
    if (totalMemMb <= 3200 || (lowRam && totalMemMb < 5000)) {
      return DeviceTier.weak;
    }
    if (totalMemMb <= 6500) return DeviceTier.mid;
    if (totalMemMb <= 11800) return DeviceTier.strong;
    return DeviceTier.flagship;
  }

  /// Memória livre abaixo disto indica pressão — o preset cai um degrau.
  bool get underMemoryPressure =>
      isKnown && availMemMb > 0 && availMemMb < 700;

  String get summary {
    if (!isKnown) return 'Perfil do aparelho indisponível';
    final gb = (totalMemMb / 1024).toStringAsFixed(0);
    return '$model · ${gb}GB · $cores núcleos · Android $sdkInt';
  }
}

class DeviceProfileService {
  DeviceProfileService._();

  static const MethodChannel _channel =
      MethodChannel('org.loopgamer.libretro/methods');

  static DeviceProfile? _cached;

  static Future<DeviceProfile> load({bool refresh = false}) async {
    if (!refresh && _cached != null) return _cached!;
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'getDeviceProfile',
      );
      if (res == null) {
        _cached = DeviceProfile.unknown;
        return _cached!;
      }
      _cached = DeviceProfile(
        totalMemMb: (res['totalMemMb'] as num?)?.toInt() ?? 0,
        availMemMb: (res['availMemMb'] as num?)?.toInt() ?? 0,
        cores: (res['cores'] as num?)?.toInt() ?? 4,
        lowRam: res['lowRam'] as bool? ?? false,
        sdkInt: (res['sdkInt'] as num?)?.toInt() ?? 0,
        manufacturer: (res['manufacturer'] as String? ?? '').trim(),
        model: (res['model'] as String? ?? '').trim(),
        soc: (res['soc'] as String? ?? '').trim(),
      );
    } on MissingPluginException {
      _cached = DeviceProfile.unknown;
    } catch (e) {
      debugPrint('[DeviceProfileService] Falha ao ler perfil: $e');
      _cached = DeviceProfile.unknown;
    }
    return _cached!;
  }

  static void resetCache() => _cached = null;
}
