import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Bitmask padrão Libretro (RETRO_DEVICE_ID_JOYPAD_*)
class RetroJoypadMask {
  static const int b = 1 << 0;
  static const int y = 1 << 1;
  static const int select = 1 << 2;
  static const int start = 1 << 3;
  static const int up = 1 << 4;
  static const int down = 1 << 5;
  static const int left = 1 << 6;
  static const int right = 1 << 7;
  static const int a = 1 << 8;
  static const int x = 1 << 9;
  static const int l = 1 << 10;
  static const int r = 1 << 11;
  static const int l2 = 1 << 12;
  static const int r2 = 1 << 13;
}

class SaveStateSlotInfo {
  const SaveStateSlotInfo({
    required this.slot,
    required this.exists,
    this.updatedAt,
    this.sizeBytes = 0,
    this.previewImagePath,
    this.gameTitle,
  });

  final int slot;
  final bool exists;
  final DateTime? updatedAt;
  final int sizeBytes;
  final String? previewImagePath;
  final String? gameTitle;

  String get title =>
      slot == 0 ? 'Slot Rápido (Quick Save)' : 'Slot $slot';

  String get statusLabel {
    if (!exists || updatedAt == null) return 'Vazio — Toque em Salvar';
    final d = updatedAt!;
    final day = d.day.toString().padLeft(2, '0');
    final month = d.month.toString().padLeft(2, '0');
    final year = d.year;
    final hour = d.hour.toString().padLeft(2, '0');
    final min = d.minute.toString().padLeft(2, '0');
    final sec = d.second.toString().padLeft(2, '0');
    return '$day/$month/$year  $hour:$min:$sec';
  }
}

class LibretroTelemetryEvent {
  const LibretroTelemetryEvent({
    required this.fps,
    required this.frameTimeMs,
    required this.frameWidth,
    required this.frameHeight,
    required this.coreName,
  });

  final double fps;
  final double frameTimeMs;
  final int frameWidth;
  final int frameHeight;
  final String coreName;

  factory LibretroTelemetryEvent.fromMap(Map<dynamic, dynamic> map) {
    final fpsVal = (map['fps'] as num?)?.toDouble() ?? 60.0;
    final ftVal = (map['frameTimeMs'] as num?)?.toDouble() ??
        (fpsVal > 0 ? 1000.0 / fpsVal : 16.6);
    return LibretroTelemetryEvent(
      fps: fpsVal,
      frameTimeMs: ftVal,
      frameWidth: (map['width'] as num?)?.toInt() ?? 480,
      frameHeight: (map['height'] as num?)?.toInt() ?? 272,
      coreName: (map['coreName'] as String?) ?? 'Libretro',
    );
  }
}

class EmulatorService {
  EmulatorService({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 15),
              ),
            );

  static const MethodChannel _methodChannel =
      MethodChannel('org.loopgamer.libretro/methods');
  static const EventChannel _eventChannel =
      EventChannel('org.loopgamer.libretro/events');

  static const String _buildbotBaseUrl =
      'https://buildbot.libretro.com/nightly/android/latest/arm64-v8a';

  /// Tamanho mínimo aceito para uma biblioteca `.so` válida (16 KB).
  static const int minCoreSoBytes = 16 * 1024;

  final bool _ownsDio;
  final Dio _dio;
  bool _isDisposed = false;
  String? _lastError;
  final Map<String, DateTime> _lastChannelLogAt = {};

  StreamSubscription<dynamic>? _eventSubscription;
  late final StreamController<LibretroTelemetryEvent> _telemetryController =
      StreamController<LibretroTelemetryEvent>.broadcast(
    onListen: _ensureEventSubscription,
    onCancel: _maybeCancelEventSubscription,
  );
  late final StreamController<void> _gamepadController =
      StreamController<void>.broadcast(
    onListen: _ensureEventSubscription,
    onCancel: _maybeCancelEventSubscription,
  );

  /// Último erro registrado em operações de save/load ou canal nativo.
  String? get lastError => _lastError;

  Stream<LibretroTelemetryEvent> get telemetryStream =>
      _telemetryController.stream;

  /// Stream emitido quando botões ou analógicos de um gamepad físico são detectados
  Stream<void> get hardwareGamepadStream => _gamepadController.stream;

  void _ensureEventSubscription() {
    if (_isDisposed || _eventSubscription != null) return;
    try {
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
        (event) {
          if (_isDisposed || event is! Map) return;
          if (event.containsKey('fps') && !_telemetryController.isClosed) {
            _telemetryController.add(LibretroTelemetryEvent.fromMap(event));
          } else if (event['event'] == 'hardwareGamepadActive' &&
              !_gamepadController.isClosed) {
            _gamepadController.add(null);
          }
        },
        onError: (Object error) {
          _logChannelError('events', error);
        },
      );
    } catch (e) {
      _logChannelError('events.subscribe', e);
    }
  }

  void _maybeCancelEventSubscription() {
    if (!_telemetryController.hasListener && !_gamepadController.hasListener) {
      unawaited(_eventSubscription?.cancel());
      _eventSubscription = null;
    }
  }

  void _logChannelError(
    String method,
    Object error, {
    bool throttle = false,
  }) {
    if (throttle) {
      final now = DateTime.now();
      final last = _lastChannelLogAt[method];
      if (last != null && now.difference(last).inSeconds < 5) {
        return;
      }
      _lastChannelLogAt[method] = now;
    }
    debugPrint('[EmulatorService] MethodChannel "$method" falhou: $error');
  }

  /// Valida e serializa `coreOptions` no formato `chave=valor;...` esperado pelo JNI.
  /// Rejeita chaves vazias ou chaves/valores contendo `=`, `;` ou quebras de linha.
  static String serializeCoreOptions(Map<String, String>? coreOptions) {
    if (coreOptions == null || coreOptions.isEmpty) return '';
    final pairs = <String>[];
    for (final entry in coreOptions.entries) {
      final k = entry.key;
      final v = entry.value;
      if (k.trim().isEmpty ||
          k.contains('=') ||
          k.contains(';') ||
          k.contains('\n') ||
          k.contains('\r') ||
          v.contains('=') ||
          v.contains(';') ||
          v.contains('\n') ||
          v.contains('\r')) {
        throw ArgumentError.value(
          '$k=$v',
          'coreOptions',
          'Chaves e valores de coreOptions não podem ser vazios nem conter "=", ";" ou quebras de linha.',
        );
      }
      pairs.add('$k=$v');
    }
    return pairs.join(';');
  }

  /// Verifica se o arquivo existe, possui tamanho mínimo e cabeçalho mágico ELF (`0x7F E L F`).
  static Future<bool> isValidElfSharedLibrary(
    File file, {
    int minBytes = minCoreSoBytes,
  }) async {
    if (!await file.exists()) return false;
    final len = await file.length();
    if (len < minBytes || len < 4) return false;
    final raf = await file.open();
    try {
      final header = await raf.read(4);
      return _hasElfMagic(header);
    } catch (_) {
      return false;
    } finally {
      await raf.close();
    }
  }

  static bool _hasElfMagic(List<int> bytes) =>
      bytes.length >= 4 &&
      bytes[0] == 0x7F &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4C &&
      bytes[3] == 0x46;

  static bool _isValidElfSync(File file, {int minBytes = minCoreSoBytes}) {
    if (!file.existsSync()) return false;
    final len = file.lengthSync();
    if (len < minBytes || len < 4) return false;
    final raf = file.openSync(mode: FileMode.read);
    try {
      final header = raf.readSync(4);
      return _hasElfMagic(header);
    } finally {
      raf.closeSync();
    }
  }

  Future<Directory> _savesDirectory() async {
    final systemDir = await getApplicationSupportDirectory();
    final savesDir = Directory('${systemDir.path}/saves');
    if (!await savesDir.exists()) {
      await savesDir.create(recursive: true);
    }
    return savesDir;
  }

  String _romBaseName(String romPath) {
    final fileName = romPath.split('/').last;
    final dotIndex = fileName.lastIndexOf('.');
    return dotIndex > 0 ? fileName.substring(0, dotIndex) : fileName;
  }

  Future<File> _slotFile(String romPath, int slot) async {
    final savesDir = await _savesDirectory();
    final base = _romBaseName(romPath);
    return File('${savesDir.path}/${base}_slot$slot.state');
  }

  Future<File> _slotPreviewFile(String romPath, int slot) async {
    final savesDir = await _savesDirectory();
    final base = _romBaseName(romPath);
    return File('${savesDir.path}/${base}_slot$slot.png');
  }

  Future<File> _slotMetaFile(String romPath, int slot) async {
    final savesDir = await _savesDirectory();
    final base = _romBaseName(romPath);
    return File('${savesDir.path}/${base}_slot$slot.json');
  }

  /// Lista os 6 slots estilo PPSSPP (Slot 0..5) com screenshot preview e título
  Future<List<SaveStateSlotInfo>> listSaveSlots(
    String romPath, {
    String? defaultGameTitle,
  }) async {
    final List<SaveStateSlotInfo> slots = [];
    for (int slot = 0; slot <= 5; slot++) {
      final file = await _slotFile(romPath, slot);
      if (await file.exists()) {
        final stat = await file.stat();
        if (stat.size > 0) {
          final previewFile = await _slotPreviewFile(romPath, slot);
          final metaFile = await _slotMetaFile(romPath, slot);
          String? savedTitle = defaultGameTitle;
          if (await metaFile.exists()) {
            try {
              final decoded =
                  jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
              savedTitle = (decoded['gameTitle'] as String?) ?? defaultGameTitle;
            } catch (e) {
              debugPrint(
                '[EmulatorService] Metadados inválidos no slot $slot: $e',
              );
            }
          }
          slots.add(
            SaveStateSlotInfo(
              slot: slot,
              exists: true,
              updatedAt: stat.modified,
              sizeBytes: stat.size,
              previewImagePath:
                  await previewFile.exists() ? previewFile.path : null,
              gameTitle: savedTitle,
            ),
          );
          continue;
        }
      }
      slots.add(
        SaveStateSlotInfo(
          slot: slot,
          exists: false,
          gameTitle: defaultGameTitle,
        ),
      );
    }
    return slots;
  }

  Future<String> ensureCoreDownloaded({
    required String coreSoName,
    void Function(double progress)? onDownloadProgress,
  }) async {
    final supportDir = await getApplicationSupportDirectory();
    final coresDir = Directory('${supportDir.path}/libretro_cores');
    if (!await coresDir.exists()) {
      await coresDir.create(recursive: true);
    }

    final coreFile = File('${coresDir.path}/$coreSoName');
    if (await isValidElfSharedLibrary(coreFile)) {
      return coreFile.path;
    }
    if (await coreFile.exists()) {
      debugPrint(
        '[EmulatorService] Core $coreSoName inválido/truncado em disco; baixando novamente.',
      );
      try {
        await coreFile.delete();
      } catch (e) {
        debugPrint('[EmulatorService] Falha ao remover core inválido: $e');
      }
    }

    final zipUrl = '$_buildbotBaseUrl/$coreSoName.zip';
    final tempZipPath =
        '${coresDir.path}/$coreSoName.zip.tmp_${DateTime.now().microsecondsSinceEpoch}';
    final tempZip = File(tempZipPath);

    try {
      final response = await _dio.download(
        zipUrl,
        tempZipPath,
        options: Options(
          receiveTimeout: const Duration(seconds: 60),
          sendTimeout: const Duration(seconds: 15),
        ),
        onReceiveProgress: (received, total) {
          if (total > 0 && onDownloadProgress != null) {
            onDownloadProgress(received / total);
          }
        },
      );
      final statusCode = response.statusCode ?? 200;
      if (statusCode < 200 || statusCode >= 300) {
        throw StateError(
          'Falha ao baixar núcleo $coreSoName (HTTP $statusCode).',
        );
      }

      final extractedOk = await Isolate.run(
        () => _extractCoreSoFromZipSync(tempZipPath, coreFile.path),
      );
      if (!extractedOk || !await isValidElfSharedLibrary(coreFile)) {
        try {
          if (await coreFile.exists()) {
            await coreFile.delete();
          }
        } catch (e) {
          debugPrint('[EmulatorService] Falha ao limpar core corrompido: $e');
        }
        throw StateError(
          'Core $coreSoName baixado está corrompido ou não é um binário ELF ARM64 válido.',
        );
      }
      return coreFile.path;
    } finally {
      try {
        if (await tempZip.exists()) {
          await tempZip.delete();
        }
      } catch (e) {
        debugPrint('[EmulatorService] Falha ao limpar zip de core: $e');
      }
    }
  }

  static bool _extractCoreSoFromZipSync(String zipPath, String outPath) {
    final zipFile = File(zipPath);
    if (!zipFile.existsSync()) return false;
    final zipBytes = zipFile.readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(zipBytes);
    final tmpOut = File(
      '$outPath.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      for (final entry in archive) {
        if (entry.isFile && entry.name.endsWith('.so')) {
          final data = entry.content as List<int>;
          tmpOut.writeAsBytesSync(data, flush: true);
          if (!_isValidElfSync(tmpOut)) {
            if (tmpOut.existsSync()) tmpOut.deleteSync();
            return false;
          }
          tmpOut.renameSync(outPath);
          return true;
        }
      }
      return false;
    } finally {
      if (tmpOut.existsSync()) {
        try {
          tmpOut.deleteSync();
        } catch (e) {
          debugPrint('[EmulatorService] Falha ao remover tmpOut de core: $e');
        }
      }
    }
  }

  static const String _neogeoBiosUrl =
      'https://archive.org/download/neogeo_202402/neogeo.zip';

  Future<void> _ensureNeoGeoBios(Directory systemDir, String romPath) async {
    try {
      final fbneoDir = Directory('${systemDir.path}/fbneo');
      if (!await fbneoDir.exists()) {
        await fbneoDir.create(recursive: true);
      }
      final biosFile = File('${fbneoDir.path}/neogeo.zip');
      if (!await biosFile.exists() || await biosFile.length() < 64 * 1024) {
        final tmpFile = File('${biosFile.path}.part');
        await _dio
            .download(
              _neogeoBiosUrl,
              tmpFile.path,
              options: Options(
                receiveTimeout: const Duration(seconds: 25),
                sendTimeout: const Duration(seconds: 10),
              ),
            )
            .timeout(const Duration(seconds: 25));
        if (await tmpFile.exists() && await tmpFile.length() >= 64 * 1024) {
          await tmpFile.rename(biosFile.path);
        }
      }
      if (await biosFile.exists() && await biosFile.length() >= 64 * 1024) {
        final sysBios = File('${systemDir.path}/neogeo.zip');
        if (!await sysBios.exists()) {
          await biosFile.copy(sysBios.path);
        }
        final romParent = File(romPath).parent;
        if (romParent.path.contains('arcade_')) {
          final romDirBios = File('${romParent.path}/neogeo.zip');
          if (!await romDirBios.exists()) {
            await biosFile.copy(romDirBios.path);
          }
        }
      }
    } catch (e) {
      debugPrint('[EmulatorService] Falha ao preparar BIOS NeoGeo: $e');
    }
  }

  static const String _dolphinSysUrl =
      'https://buildbot.libretro.com/assets/system/Dolphin.zip';

  Future<void> _ensureDolphinSys(Directory systemDir) async {
    final tmpZip = File('${systemDir.path}/dolphin_sys.zip.part');
    try {
      final marker = File('${systemDir.path}/dolphin-emu/Sys/codehandler.bin');
      if (await marker.exists() && await marker.length() > 100) {
        return;
      }
      await _dio
          .download(
            _dolphinSysUrl,
            tmpZip.path,
            options: Options(
              receiveTimeout: const Duration(seconds: 40),
              sendTimeout: const Duration(seconds: 12),
            ),
          )
          .timeout(const Duration(seconds: 45));
      if (!await tmpZip.exists() || await tmpZip.length() < 100 * 1024) {
        return;
      }
      final tmpPath = tmpZip.path;
      final sysPath = systemDir.path;
      await Isolate.run(() => _extractDolphinAssetsSync(tmpPath, sysPath));
    } catch (e) {
      debugPrint('[EmulatorService] Falha ao baixar/extrair Dolphin Sys: $e');
    } finally {
      try {
        if (await tmpZip.exists()) {
          await tmpZip.delete();
        }
      } catch (e) {
        debugPrint('[EmulatorService] Falha ao limpar zip do Dolphin Sys: $e');
      }
    }
  }

  static void _extractDolphinAssetsSync(String zipPath, String systemDirPath) {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final rootDir = Directory('$systemDirPath/dolphin-emu');
    if (!rootDir.existsSync()) {
      rootDir.createSync(recursive: true);
    }
    final canonicalRoot = rootDir.resolveSymbolicLinksSync();
    final prefix = canonicalRoot.endsWith(Platform.pathSeparator)
        ? canonicalRoot
        : '$canonicalRoot${Platform.pathSeparator}';

    for (final entry in archive) {
      if (!entry.isFile) continue;
      final normalized = entry.name.replaceAll('\\', '/');
      if (normalized.contains('..') || normalized.startsWith('/')) continue;
      final relPath = normalized.startsWith('dolphin-emu/')
          ? normalized.substring('dolphin-emu/'.length)
          : normalized;
      if (relPath.isEmpty) continue;
      final outFile = File('${rootDir.path}/$relPath');
      outFile.parent.createSync(recursive: true);
      final parentCanonical = outFile.parent.resolveSymbolicLinksSync();
      if (parentCanonical != canonicalRoot &&
          !parentCanonical.startsWith(prefix)) {
        continue;
      }
      outFile.writeAsBytesSync(entry.content as List<int>, flush: true);
    }
  }

  Future<bool> hasPs3Firmware() async {
    final systemDir = await getApplicationSupportDirectory();
    final rootPup = File('${systemDir.path}/PS3UPDAT.PUP');
    if (await rootPup.exists() && await rootPup.length() > 1024 * 1024) {
      return true;
    }
    final rpcs3Pup = File('${systemDir.path}/rpcs3/PS3UPDAT.PUP');
    if (await rpcs3Pup.exists() && await rpcs3Pup.length() > 1024 * 1024) {
      return true;
    }
    final devFlashSys = Directory('${systemDir.path}/rpcs3/dev_flash/sys');
    if (await devFlashSys.exists()) {
      final entries = await devFlashSys.list().toList();
      if (entries.isNotEmpty) return true;
    }
    return false;
  }

  Future<String?> importPs3Firmware() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final pickedPath = result?.files.single.path;
    if (pickedPath == null) return null;

    final sourceFile = File(pickedPath);
    if (!await sourceFile.exists()) return null;
    final len = await sourceFile.length();
    if (len < 1024 * 1024) {
      throw StateError(
        'Arquivo inválido para PS3UPDAT.PUP (tamanho inferior a 1 MB). Selecione o firmware oficial PS3UPDAT.PUP.',
      );
    }

    final systemDir = await getApplicationSupportDirectory();
    final rpcs3Dir = Directory('${systemDir.path}/rpcs3');
    if (!await rpcs3Dir.exists()) {
      await rpcs3Dir.create(recursive: true);
    }
    final targetRoot = File('${systemDir.path}/PS3UPDAT.PUP');
    final targetRpcs3 = File('${rpcs3Dir.path}/PS3UPDAT.PUP');
    await sourceFile.copy(targetRoot.path);
    await sourceFile.copy(targetRpcs3.path);
    return targetRoot.path;
  }

  Future<int> startSession({
    required String platformSlug,
    required String coreSoName,
    required String romPath,
    int resolutionScale = 2,
    int frameSkip = 0,
    bool vsyncEnabled = false,
    bool audioEnabled = true,
    double masterVolume = 0.85,
    bool softwareRendering = false,
    String gpuBackend = 'opengl',
    int screenScale = 1,
    bool frameDup = false,
    String customDriverDir = '',
    String customDriverName = '',
    bool adrenoTurbo = false,
    String freedrenoPreset = '',
    Map<String, String>? coreOptions,
    void Function(double coreProgress)? onCoreDownloadProgress,
  }) async {
    final serializedCoreOptions = serializeCoreOptions(coreOptions);
    final systemDir = await getApplicationSupportDirectory();
    final savesDir = await _savesDirectory();
    final lowerPlatform = platformSlug.toLowerCase();

    if (coreSoName == 'rpcs3_libretro_android.so' || lowerPlatform == 'ps3') {
      final hasPup = await hasPs3Firmware();
      if (!hasPup) {
        throw StateError(
          'Firmware de PS3 (PS3UPDAT.PUP) não encontrada. Vá em Configurações > Drivers, Firmware & Saves e importe o arquivo PS3UPDAT.PUP antes de iniciar.',
        );
      }
      gpuBackend = 'vulkan';
      softwareRendering = false;
    }

    final coreAbsolutePath = await ensureCoreDownloaded(
      coreSoName: coreSoName,
      onDownloadProgress: onCoreDownloadProgress,
    );

    // Para NeoGeo (FBNeo), garante neogeo.zip em system/fbneo/ e ao lado da ROM arcade
    if (lowerPlatform == 'neogeo') {
      await _ensureNeoGeoBios(systemDir, romPath);
    }

    // Para GameCube / Wii (Dolphin), baixa os assets de sistema oficiais do Libretro
    if (coreSoName == 'dolphin_libretro_android.so' ||
        lowerPlatform == 'gamecube' ||
        lowerPlatform == 'wii') {
      await _ensureDolphinSys(systemDir);
    }

    // Garante inicialização do PPSSPP com backend alinhado ao modo escolhido
    if (lowerPlatform == 'psp') {
      try {
        final ppssppDir = Directory('${systemDir.path}/PPSSPP/system');
        if (!await ppssppDir.exists()) {
          await ppssppDir.create(recursive: true);
        }
        final iniBackend = gpuBackend == 'vulkan' ? 3 : 0;
        final clampedResolution = resolutionScale.clamp(1, 2);
        final iniFile = File('${ppssppDir.path}/ppsspp.ini');
        await iniFile.writeAsString('''[General]
FirstRun = False

[CPU]
CPUCore = 1
SeparateSASThread = True
SeparateIOThread = True
IOTimingMethod = 0
FastMemory = False
LockedCPUSpeed = 0

[Graphics]
GraphicsBackend = $iniBackend
InternalResolution = $clampedResolution
AutoFrameSkip = ${frameSkip > 0 ? 'True' : 'False'}
FrameSkip = ${frameSkip.clamp(0, 3)}
FrameSkipType = 0
SoftwareSkinning = True
VertexCache = True
TextureBackingType = 0
TextureSecondaryCache = False
DisableSlowFramebufEffects = True
SkipGPUReadbacks = 1
BloomHack = 3
DepthRaster = 2
SplineQuality = 0
HardwareTransform = True
LazyTextureCache = True
TexScalingType = 0
TexScalingLevel = 1
AnisotropyLevel = 0
TexDeposterize = False

[Sound]
EnableSound = ${audioEnabled ? 'True' : 'False'}
AudioSync = False
SoundSpeedHack = True
''');
      } catch (e) {
        debugPrint('[EmulatorService] Falha ao gravar ppsspp.ini: $e');
      }
    }

    final textureId = await _methodChannel.invokeMethod<int>(
      'startLibretroSession',
      {
        'platform': platformSlug,
        'corePath': coreAbsolutePath,
        'romPath': romPath,
        'systemDir': systemDir.path,
        'savesDir': savesDir.path,
        'resolutionScale': resolutionScale,
        'frameSkip': frameSkip,
        'vsyncEnabled': vsyncEnabled,
        'audioEnabled': audioEnabled,
        'masterVolume': masterVolume,
        'softwareRendering': softwareRendering,
        'gpuBackend': gpuBackend,
        'screenScale': screenScale,
        'frameDup': frameDup,
        'customDriverDir': customDriverDir,
        'customDriverName': customDriverName,
        'adrenoTurbo': adrenoTurbo,
        'freedrenoPreset': freedrenoPreset,
        'coreOptions': serializedCoreOptions,
      },
    );

    if (textureId == null) {
      throw StateError('Falha ao alocar Texture para a sessão do emulador.');
    }
    return textureId;
  }

  Future<void> setAudioConfig({
    required bool enabled,
    required double volume,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>('setAudioConfig', {
        'enabled': enabled,
        'volume': volume.clamp(0.0, 1.0),
      });
    } catch (e) {
      _logChannelError('setAudioConfig', e);
    }
  }

  Future<void> setPerformanceConfig({
    required int frameSkip,
    required bool vsyncEnabled,
    bool frameDup = false,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>('setPerformanceConfig', {
        'frameSkip': frameSkip.clamp(0, 3),
        'vsyncEnabled': vsyncEnabled,
        'frameDup': frameDup,
      });
    } catch (e) {
      _logChannelError('setPerformanceConfig', e);
    }
  }

  /// Acelera o emulador (Fast-Forward: 2x, 3x, 4x)
  Future<void> setFastForward(double speed) async {
    try {
      await _methodChannel.invokeMethod<void>('setFastForward', {
        'speed': speed.clamp(1.0, 8.0),
      });
    } catch (e) {
      _logChannelError('setFastForward', e);
    }
  }

  /// Configura o disparo contínuo automático nos botões desejados (Turbo / Rapid-Fire)
  Future<void> setTurboConfig({
    required int turboMask,
    int halfPeriodFrames = 3,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>('setTurboConfig', {
        'turboMask': turboMask,
        'halfPeriodFrames': halfPeriodFrames.clamp(1, 10),
      });
    } catch (e) {
      _logChannelError('setTurboConfig', e);
    }
  }

  Future<void> sendInputState({
    required int joypadMask,
    double leftStickX = 0.0,
    double leftStickY = 0.0,
  }) async {
    try {
      await _methodChannel.invokeMethod<void>('updateInput', {
        'joypadMask': joypadMask,
        'leftX': (leftStickX * 32767).round(),
        'leftY': (leftStickY * 32767).round(),
      });
    } catch (e) {
      _logChannelError('updateInput', e, throttle: true);
    }
  }

  /// Salva o estado atual do jogo no slot indicado (estilo PPSSPP) com preview e metadados.
  /// Retorna estritamente o resultado real da camada nativa (nunca escreve JSON falso em `.state`).
  Future<bool> saveState(
    int slot, {
    String? romPath,
    String? gameTitle,
    Uint8List? previewPngBytes,
  }) async {
    _lastError = null;
    bool nativeOk = false;
    try {
      final res = await _methodChannel.invokeMethod<bool>(
        'saveState',
        {'slot': slot},
      );
      nativeOk = res == true;
      if (!nativeOk) {
        _lastError =
            'O núcleo do emulador não suporta ou falhou ao salvar neste slot.';
      }
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Erro nativo ao salvar estado.';
      _logChannelError('saveState', e);
      return false;
    } catch (e) {
      _lastError = 'Falha ao salvar estado do emulador.';
      _logChannelError('saveState', e);
      return false;
    }

    if (!nativeOk) {
      return false;
    }

    if (romPath != null) {
      try {
        if (previewPngBytes != null && previewPngBytes.isNotEmpty) {
          final previewFile = await _slotPreviewFile(romPath, slot);
          await previewFile.writeAsBytes(previewPngBytes, flush: true);
        }

        final metaFile = await _slotMetaFile(romPath, slot);
        await metaFile.writeAsString(
          jsonEncode({
            'gameTitle': gameTitle ?? _romBaseName(romPath),
            'slot': slot,
            'savedAtIso': DateTime.now().toIso8601String(),
          }),
          flush: true,
        );
      } catch (e) {
        debugPrint(
          '[EmulatorService] Save nativo ok, mas falhou ao gravar preview/meta do slot $slot: $e',
        );
      }
    }
    return true;
  }

  /// Carrega o estado salvo do jogo a partir do slot indicado.
  /// Retorna estritamente o resultado real da camada nativa.
  Future<bool> loadState(int slot, {String? romPath}) async {
    _lastError = null;
    if (romPath != null) {
      final file = await _slotFile(romPath, slot);
      if (!await file.exists() || await file.length() == 0) {
        _lastError = 'Nenhum save state encontrado neste slot.';
        return false;
      }
    }
    try {
      final res = await _methodChannel.invokeMethod<bool>(
        'loadState',
        {'slot': slot},
      );
      final ok = res == true;
      if (!ok) {
        _lastError =
            'O núcleo do emulador não conseguiu carregar o estado deste slot.';
      }
      return ok;
    } on PlatformException catch (e) {
      _lastError = e.message ?? 'Erro nativo ao carregar estado.';
      _logChannelError('loadState', e);
      return false;
    } catch (e) {
      _lastError = 'Falha ao carregar estado do emulador.';
      _logChannelError('loadState', e);
      return false;
    }
  }

  /// Remove um save state e seu preview de um slot específico.
  Future<void> deleteSaveState(int slot, {required String romPath}) async {
    final file = await _slotFile(romPath, slot);
    if (await file.exists()) {
      await file.delete();
    }
    final preview = await _slotPreviewFile(romPath, slot);
    if (await preview.exists()) {
      await preview.delete();
    }
    final meta = await _slotMetaFile(romPath, slot);
    if (await meta.exists()) {
      await meta.delete();
    }
  }

  Future<void> setPaused(bool paused) async {
    try {
      await _methodChannel.invokeMethod<void>('setPaused', {'paused': paused});
    } catch (e) {
      _logChannelError('setPaused', e);
    }
  }

  Future<void> stopSession() async {
    try {
      await _methodChannel.invokeMethod<void>('stopLibretroSession');
    } catch (e) {
      _logChannelError('stopLibretroSession', e);
    }
  }

  /// Libera streams e fecha o cliente HTTP quando próprio.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    unawaited(_eventSubscription?.cancel());
    _eventSubscription = null;
    if (!_telemetryController.isClosed) {
      unawaited(_telemetryController.close());
    }
    if (!_gamepadController.isClosed) {
      unawaited(_gamepadController.close());
    }
    if (_ownsDio) {
      _dio.close(force: true);
    }
  }
}
