import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Informações básicas do aparelho usadas por serviços como o
/// `GpuDriverService` (ex.: `minApi` de pacotes de driver AdrenoTools).
class AppDeviceInfo {
  const AppDeviceInfo({
    required this.sdkInt,
    required this.release,
    required this.model,
    required this.manufacturer,
  });

  /// `Build.VERSION.SDK_INT` no Android; 0 em outras plataformas.
  final int sdkInt;
  final String release;
  final String model;
  final String manufacturer;
}

class DeviceInfoService {
  DeviceInfoService._();

  static AppDeviceInfo? _cached;

  /// Retorna as informações do aparelho (cacheadas após a primeira chamada).
  /// Em plataformas não-Android retorna `sdkInt = 0`.
  static Future<AppDeviceInfo?> load() async {
    if (_cached != null) return _cached;
    try {
      final plugin = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final info = await plugin.androidInfo;
        _cached = AppDeviceInfo(
          sdkInt: info.version.sdkInt,
          release: info.version.release,
          model: info.model,
          manufacturer: info.manufacturer,
        );
      } else {
        _cached = const AppDeviceInfo(
          sdkInt: 0,
          release: '',
          model: '',
          manufacturer: '',
        );
      }
    } catch (e) {
      debugPrint('[DeviceInfoService] Falha ao ler info do aparelho: $e');
      _cached = const AppDeviceInfo(
        sdkInt: 0,
        release: '',
        model: '',
        manufacturer: '',
      );
    }
    return _cached;
  }

  /// Atalho para testes/diagnóstico: limpa o cache.
  static void resetCache() => _cached = null;
}
