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
  static const int l3 = 1 << 14;
  static const int r3 = 1 << 15;
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
    this.coreError,
    this.coreFatal = false,
    this.coreShutdown = false,
    this.hasRenderedFrame = true,
  });

  final double fps;
  final double frameTimeMs;
  final int frameWidth;
  final int frameHeight;
  final String coreName;
  final String? coreError;
  final bool coreFatal;
  final bool coreShutdown;
  final bool hasRenderedFrame;

  factory LibretroTelemetryEvent.fromMap(Map<dynamic, dynamic> map) {
    final fpsVal = (map['fps'] as num?)?.toDouble() ?? 60.0;
    final ftVal = (map['frameTimeMs'] as num?)?.toDouble() ??
        (fpsVal > 0 ? 1000.0 / fpsVal : 16.6);
    final rawError = (map['coreError'] as String?)?.trim();
    return LibretroTelemetryEvent(
      fps: fpsVal,
      frameTimeMs: ftVal,
      frameWidth: (map['width'] as num?)?.toInt() ?? 480,
      frameHeight: (map['height'] as num?)?.toInt() ?? 272,
      coreName: (map['coreName'] as String?) ?? 'Libretro',
      coreError: (rawError != null && rawError.isNotEmpty) ? rawError : null,
      coreFatal: map['coreFatal'] == true,
      coreShutdown: map['coreShutdown'] == true,
      hasRenderedFrame: map['hasRenderedFrame'] != false,
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
  bool _isHardwareGamepadConnected = false;
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
  late final StreamController<Map<String, dynamic>> _gamepadUiActionController =
      StreamController<Map<String, dynamic>>.broadcast(
    onListen: _ensureEventSubscription,
    onCancel: _maybeCancelEventSubscription,
  );
  late final StreamController<bool> _hardwareGamepadStateController =
      StreamController<bool>.broadcast(
    onListen: _ensureEventSubscription,
    onCancel: _maybeCancelEventSubscription,
  );

  /// Último erro registrado em operações de save/load ou canal nativo.
  String? get lastError => _lastError;

  /// Indica se um gamepad físico está conectado/ativo segundo eventos nativos.
  bool get isHardwareGamepadConnected => _isHardwareGamepadConnected;

  Stream<LibretroTelemetryEvent> get telemetryStream =>
      _telemetryController.stream;

  /// Stream emitido quando botões ou analógicos de um gamepad físico são detectados
  Stream<void> get hardwareGamepadStream => _gamepadController.stream;

  /// Stream de ações de UI disparadas pelo gamepad físico (ex.: menu, quick save).
  Stream<Map<String, dynamic>> get gamepadUiActionStream =>
      _gamepadUiActionController.stream;

  /// Stream de mudanças no estado de conexão do gamepad físico.
  Stream<bool> get hardwareGamepadStateStream =>
      _hardwareGamepadStateController.stream;

  void _ensureEventSubscription() {
    if (_isDisposed || _eventSubscription != null) return;
    try {
      _eventSubscription = _eventChannel.receiveBroadcastStream().listen(
        (event) {
          if (_isDisposed || event is! Map) return;
          final eventName = event['event'];
          if (event.containsKey('fps') && !_telemetryController.isClosed) {
            _telemetryController.add(LibretroTelemetryEvent.fromMap(event));
          } else if (eventName == 'hardwareGamepadActive') {
            if (!_isHardwareGamepadConnected) {
              _isHardwareGamepadConnected = true;
              if (!_hardwareGamepadStateController.isClosed) {
                _hardwareGamepadStateController.add(true);
              }
            }
            if (!_gamepadController.isClosed) {
              _gamepadController.add(null);
            }
          } else if (eventName == 'hardwareGamepadState') {
            final connected = event['connected'] == true;
            _isHardwareGamepadConnected = connected;
            if (!_hardwareGamepadStateController.isClosed) {
              _hardwareGamepadStateController.add(connected);
            }
            if (connected && !_gamepadController.isClosed) {
              _gamepadController.add(null);
            }
          } else if (eventName == 'gamepadUiAction') {
            if (!_gamepadUiActionController.isClosed) {
              _gamepadUiActionController.add(
                Map<String, dynamic>.from(event),
              );
            }
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
    if (!_telemetryController.hasListener &&
        !_gamepadController.hasListener &&
        !_gamepadUiActionController.hasListener &&
        !_hardwareGamepadStateController.hasListener) {
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

      final extractedOk = await _runExtractCoreSoInIsolate(
        tempZipPath,
        coreFile.path,
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

  static Future<bool> _runExtractCoreSoInIsolate(
    String zipPath,
    String outPath,
  ) {
    return Isolate.run(() => _extractCoreSoFromZipSync(zipPath, outPath));
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

  static const String _ppssppSysUrl =
      'https://buildbot.libretro.com/assets/system/PPSSPP.zip';

  /// BIOS do PC Engine CD (Super CD-ROM² System v3.0) exigida pelo core
  /// Beetle PCE Fast para imagens de CD (.chd/.cue/.iso). Jogos HuCard (.pce)
  /// não precisam de BIOS. MD5 oficial: 38179df8f4ac870017db21ebcbf53114.
  static const String _pceCdBiosUrl =
      'https://raw.githubusercontent.com/archtaurus/RetroPieBIOS/master/BIOS/syscard3.pce';

  static const int _pceCdBiosMinBytes = 256 * 1024 - 4096;

  static const String _ppssppAssetsMissingMessage =
      'Não foi possível preparar os arquivos de sistema do PPSSPP. '
      'Sem eles (fontes, shaders e compat.ini) os jogos de PSP não inicializam. '
      'Verifique sua conexão e tente novamente.';

  static const String _dolphinSysMissingMessage =
      'Não foi possível preparar os arquivos de sistema do Dolphin (Wii / GameCube). '
      'Sem eles o jogo fecha sozinho na inicialização. Verifique sua conexão e tente novamente.';

  /// Confere se os assets oficiais do Dolphin já estão instalados.
  ///
  /// O marcador `Sys/codehandler.bin` é um arquivo real do pacote oficial
  /// `Dolphin.zip` do buildbot do Libretro.
  static Future<bool> _hasDolphinSys(Directory systemDir) async {
    final marker = File('${systemDir.path}/dolphin-emu/Sys/codehandler.bin');
    try {
      return await marker.exists() && await marker.length() > 100;
    } catch (e) {
      debugPrint('[EmulatorService] Falha ao verificar Dolphin Sys: $e');
      return false;
    }
  }

  /// Baixa e extrai os assets do Dolphin, com uma nova tentativa em caso de
  /// falha. Lança [StateError] quando os arquivos continuam ausentes, para que
  /// a tela do jogo mostre o motivo em vez de fechar silenciosamente.
  Future<void> _ensureDolphinSys(Directory systemDir) async {
    if (await _hasDolphinSys(systemDir)) return;

    final tmpZip = File('${systemDir.path}/dolphin_sys.zip.part');
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _dio
            .download(
              _dolphinSysUrl,
              tmpZip.path,
              options: Options(
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 15),
              ),
            )
            .timeout(const Duration(seconds: 180));
        if (!await tmpZip.exists() || await tmpZip.length() < 100 * 1024) {
          throw StateError('pacote Dolphin Sys incompleto ou pequeno demais');
        }
        await _runExtractDolphinAssetsInIsolate(tmpZip.path, systemDir.path);
      } catch (e) {
        lastError = e;
        debugPrint(
          '[EmulatorService] Falha ao preparar Dolphin Sys (tentativa $attempt/2): $e',
        );
      } finally {
        try {
          if (await tmpZip.exists()) {
            await tmpZip.delete();
          }
        } catch (e) {
          debugPrint('[EmulatorService] Falha ao limpar zip do Dolphin Sys: $e');
        }
      }
      if (await _hasDolphinSys(systemDir)) return;
    }

    throw StateError(
      lastError == null
          ? _dolphinSysMissingMessage
          : '$_dolphinSysMissingMessage ($lastError)',
    );
  }

  static Future<void> _runExtractDolphinAssetsInIsolate(
    String zipPath,
    String systemDirPath,
  ) {
    return Isolate.run(() => _extractDolphinAssetsSync(zipPath, systemDirPath));
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

  /// Confere se os assets oficiais do PPSSPP já estão instalados.
  ///
  /// O marcador `PPSSPP/flash0/font/jpn0.pgf` é um arquivo real do pacote
  /// oficial `PPSSPP.zip` do buildbot do Libretro.
  static Future<bool> _hasPpssppAssets(Directory systemDir) async {
    final marker = File('${systemDir.path}/PPSSPP/flash0/font/jpn0.pgf');
    try {
      return await marker.exists() && await marker.length() > 1000;
    } catch (e) {
      debugPrint('[EmulatorService] Falha ao verificar assets PPSSPP: $e');
      return false;
    }
  }

  /// Baixa e extrai os assets do PPSSPP (fontes, shaders, compat.ini, lang),
  /// sem os quais o core `ppsspp_libretro_android.so` não inicializa jogos.
  /// Lança [StateError] quando os arquivos continuam ausentes, para que a
  /// tela do jogo mostre o motivo em vez de fechar silenciosamente.
  Future<void> _ensurePpssppAssets(Directory systemDir) async {
    if (await _hasPpssppAssets(systemDir)) return;

    final tmpZip = File('${systemDir.path}/ppsspp_sys.zip.part');
    Object? lastError;
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _dio
            .download(
              _ppssppSysUrl,
              tmpZip.path,
              options: Options(
                receiveTimeout: const Duration(seconds: 60),
                sendTimeout: const Duration(seconds: 15),
              ),
            )
            .timeout(const Duration(seconds: 180));
        if (!await tmpZip.exists() || await tmpZip.length() < 1024 * 1024) {
          throw StateError('pacote PPSSPP Sys incompleto ou pequeno demais');
        }
        await _runExtractPpssppAssetsInIsolate(tmpZip.path, systemDir.path);
      } catch (e) {
        lastError = e;
        debugPrint(
          '[EmulatorService] Falha ao preparar assets PPSSPP (tentativa $attempt/2): $e',
        );
      } finally {
        try {
          if (await tmpZip.exists()) {
            await tmpZip.delete();
          }
        } catch (e) {
          debugPrint('[EmulatorService] Falha ao limpar zip do PPSSPP: $e');
        }
      }
      if (await _hasPpssppAssets(systemDir)) return;
    }

    throw StateError(
      lastError == null
          ? _ppssppAssetsMissingMessage
          : '$_ppssppAssetsMissingMessage ($lastError)',
    );
  }

  static Future<void> _runExtractPpssppAssetsInIsolate(
    String zipPath,
    String systemDirPath,
  ) {
    return Isolate.run(() => _extractPpssppAssetsSync(zipPath, systemDirPath));
  }

  /// Extrai `PPSSPP.zip` (raiz `PPSSPP/...`) dentro de `systemDir`, mantendo
  /// os caminhos relativos — o resultado final é `systemDir/PPSSPP/...`,
  /// que é exatamente onde o core libretro PPSSPP procura os assets.
  static void _extractPpssppAssetsSync(String zipPath, String systemDirPath) {
    final bytes = File(zipPath).readAsBytesSync();
    final archive = ZipDecoder().decodeBytes(bytes);
    final rootDir = Directory(systemDirPath);
    if (!rootDir.existsSync()) {
      rootDir.createSync(recursive: true);
    }
    final canonicalRoot = rootDir.resolveSymbolicLinksSync();
    final prefix = canonicalRoot.endsWith(Platform.pathSeparator)
        ? canonicalRoot
        : '$canonicalRoot${Platform.pathSeparator}';

    var extracted = 0;
    for (final entry in archive) {
      if (!entry.isFile) continue;
      final normalized = entry.name.replaceAll('\\', '/');
      if (normalized.contains('..') || normalized.startsWith('/')) continue;
      final relPath = normalized.startsWith('PPSSPP/')
          ? normalized
          : 'PPSSPP/$normalized';
      final outFile = File('${rootDir.path}/$relPath');
      outFile.parent.createSync(recursive: true);
      final parentCanonical = outFile.parent.resolveSymbolicLinksSync();
      if (parentCanonical != canonicalRoot &&
          !parentCanonical.startsWith(prefix)) {
        continue;
      }
      outFile.writeAsBytesSync(entry.content as List<int>, flush: true);
      extracted++;
    }
    if (extracted == 0) {
      throw StateError('Pacote PPSSPP Sys não continha arquivos válidos.');
    }
  }

  /// Garante `syscard3.pce` para jogos de PC Engine CD. Falhas de download
  /// não bloqueiam o boot (o core exibe seu próprio erro de BIOS
  /// ausente) — apenas registra no log.
  Future<void> _ensurePceCdBios(Directory systemDir, String romPath) async {
    final lower = romPath.toLowerCase();
    final isCdImage = lower.endsWith('.chd') ||
        lower.endsWith('.cue') ||
        lower.endsWith('.ccd') ||
        lower.endsWith('.toc') ||
        lower.endsWith('.m3u') ||
        lower.endsWith('.iso') ||
        lower.endsWith('.img') ||
        lower.endsWith('.bin');
    if (!isCdImage) return;

    try {
      final biosFile = File('${systemDir.path}/syscard3.pce');
      if (await biosFile.exists() &&
          await biosFile.length() >= _pceCdBiosMinBytes) {
        return;
      }
      final tmpFile = File('${biosFile.path}.part');
      await _dio
          .download(
            _pceCdBiosUrl,
            tmpFile.path,
            options: Options(
              receiveTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 10),
            ),
          )
          .timeout(const Duration(seconds: 60));
      if (await tmpFile.exists() &&
          await tmpFile.length() >= _pceCdBiosMinBytes) {
        await tmpFile.rename(biosFile.path);
      } else {
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint(
        '[EmulatorService] Falha ao preparar syscard3.pce (BIOS PC Engine CD): $e',
      );
    }
  }

  /// Limpa com segurança arquivos temporários criados pelo `file_picker`.
  static Future<void> cleanFilePickerTempCache({String? pickedPath}) async {
    Directory? tempDir;
    Directory? cacheDir;
    Directory? supportDir;
    try {
      tempDir = await getTemporaryDirectory();
    } catch (_) {}
    try {
      cacheDir = await getApplicationCacheDirectory();
    } catch (_) {}
    try {
      supportDir = await getApplicationSupportDirectory();
    } catch (_) {}

    final fpDirs = <String>{
      if (tempDir != null) '${tempDir.path}/file_picker',
      if (cacheDir != null) '${cacheDir.path}/file_picker',
    };
    for (final dirPath in fpDirs) {
      try {
        final dir = Directory(dirPath);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }

    if (pickedPath != null && pickedPath.trim().isNotEmpty) {
      try {
        final pickedFile = File(pickedPath);
        if (await pickedFile.exists()) {
          final normPicked = pickedFile.absolute.path.replaceAll('\\', '/');
          final inFilePickerDir = normPicked.contains('/file_picker/');
          final inTempDir = tempDir != null &&
              supportDir?.path != tempDir.path &&
              normPicked.startsWith('${tempDir.path.replaceAll('\\', '/')}/');
          final inCacheDir = cacheDir != null &&
              supportDir?.path != cacheDir.path &&
              normPicked.startsWith('${cacheDir.path.replaceAll('\\', '/')}/');
          if (inFilePickerDir || inTempDir || inCacheDir) {
            await pickedFile.delete();
          }
        }
      } catch (_) {}
    }
  }

  static const int _minPs3FirmwareBytes = 1024 * 1024;

  Future<File?> _findExistingPs3Pup(Directory dir) async {
    if (!await dir.exists()) return null;
    try {
      await for (final entry in dir.list(followLinks: false)) {
        if (entry is! File) continue;
        final name = entry.uri.pathSegments.isEmpty
            ? ''
            : entry.uri.pathSegments.last.toLowerCase();
        if (name == 'ps3updat.pup' &&
            await entry.length() > _minPs3FirmwareBytes) {
          return entry;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Garante que o firmware PS3UPDAT.PUP esteja no caminho exato esperado pelo
  /// core libretro RPCS3 (`<system_dir>/rpcs3/firmware/PS3UPDAT.PUP`),
  /// migrando instalações antigas de `system/` ou `system/rpcs3/` sem manter
  /// cópias duplicadas no armazenamento.
  Future<bool> _ensureCanonicalPs3FirmwareLayout(Directory systemDir) async {
    final firmwareDir = Directory('${systemDir.path}/rpcs3/firmware');
    final canonicalPup = File('${firmwareDir.path}/PS3UPDAT.PUP');

    if (await canonicalPup.exists() &&
        await canonicalPup.length() > _minPs3FirmwareBytes) {
      await _deleteIfExists(File('${systemDir.path}/PS3UPDAT.PUP'));
      await _deleteIfExists(File('${systemDir.path}/rpcs3/PS3UPDAT.PUP'));
      return true;
    }

    final existingLowerInFirmware = await _findExistingPs3Pup(firmwareDir);
    if (existingLowerInFirmware != null) {
      if (existingLowerInFirmware.path != canonicalPup.path) {
        await existingLowerInFirmware.rename(canonicalPup.path);
      }
      await _deleteIfExists(File('${systemDir.path}/PS3UPDAT.PUP'));
      await _deleteIfExists(File('${systemDir.path}/rpcs3/PS3UPDAT.PUP'));
      return true;
    }

    final legacyCandidates = [
      File('${systemDir.path}/rpcs3/PS3UPDAT.PUP'),
      File('${systemDir.path}/PS3UPDAT.PUP'),
      await _findExistingPs3Pup(Directory('${systemDir.path}/rpcs3')),
      await _findExistingPs3Pup(systemDir),
    ];

    for (final candidate in legacyCandidates) {
      if (candidate == null || !await candidate.exists()) continue;
      if (await candidate.length() <= _minPs3FirmwareBytes) continue;
      if (!await firmwareDir.exists()) {
        await firmwareDir.create(recursive: true);
      }
      try {
        await candidate.rename(canonicalPup.path);
      } catch (_) {
        await candidate.copy(canonicalPup.path);
        await _deleteIfExists(candidate);
      }
      await _deleteIfExists(File('${systemDir.path}/PS3UPDAT.PUP'));
      await _deleteIfExists(File('${systemDir.path}/rpcs3/PS3UPDAT.PUP'));
      return true;
    }
    return false;
  }

  Future<void> _deleteIfExists(File file) async {
    try {
      if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {}
  }

  Future<bool> hasPs3Firmware() async {
    final systemDir = await getApplicationSupportDirectory();
    final canonicalPup = File('${systemDir.path}/rpcs3/firmware/PS3UPDAT.PUP');
    if (await canonicalPup.exists() &&
        await canonicalPup.length() > _minPs3FirmwareBytes) {
      return true;
    }
    final rootPup = File('${systemDir.path}/PS3UPDAT.PUP');
    if (await rootPup.exists() && await rootPup.length() > _minPs3FirmwareBytes) {
      return true;
    }
    final rpcs3Pup = File('${systemDir.path}/rpcs3/PS3UPDAT.PUP');
    if (await rpcs3Pup.exists() &&
        await rpcs3Pup.length() > _minPs3FirmwareBytes) {
      return true;
    }
    if (await _findExistingPs3Pup(Directory('${systemDir.path}/rpcs3/firmware')) !=
        null) {
      return true;
    }
    final devFlashSys = Directory('${systemDir.path}/rpcs3/dev_flash/sys');
    if (await devFlashSys.exists()) {
      final entries = await devFlashSys.list().toList();
      if (entries.isNotEmpty) return true;
    }
    return false;
  }

  Future<bool> ensureCanonicalPs3FirmwareLayout([Directory? customDir]) async {
    final systemDir = customDir ?? await getApplicationSupportDirectory();
    if (await _ensureCanonicalPs3FirmwareLayout(systemDir)) {
      return true;
    }
    final devFlashSys = Directory('${systemDir.path}/rpcs3/dev_flash/sys');
    if (await devFlashSys.exists()) {
      final entries = await devFlashSys.list().toList();
      if (entries.isNotEmpty) return true;
    }
    return false;
  }

  Future<bool> _hasPs3SaveFiles(Directory rpcs3Dir) async {
    final homeDir = Directory('${rpcs3Dir.path}/dev_hdd0/home');
    try {
      if (!await homeDir.exists()) return false;
      await for (final entity
          in homeDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final normalized = entity.path.replaceAll('\\', '/').toLowerCase();
        if (normalized.contains('/savedata/')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<bool> removePs3Firmware() async {
    try {
      final systemDir = await getApplicationSupportDirectory();
      final rpcs3Dir = Directory('${systemDir.path}/rpcs3');

      final filesToDelete = [
        File('${systemDir.path}/PS3UPDAT.PUP'),
        File('${rpcs3Dir.path}/PS3UPDAT.PUP'),
        File('${rpcs3Dir.path}/firmware/PS3UPDAT.PUP'),
      ];
      for (final f in filesToDelete) {
        await _deleteIfExists(f);
      }
      for (final dir in [systemDir, rpcs3Dir]) {
        try {
          if (!await dir.exists()) continue;
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is File && entity.path.toLowerCase().endsWith('.pup')) {
              await _deleteIfExists(entity);
            }
          }
        } catch (_) {}
      }

      // Remove firmware, flash extra (dev_flash3), caches JIT/shader (cache/dev_hdd1)
      // e dados de instalação/configuração (dev_hdd0/game, config, tmp, logs).
      final dirsToDelete = [
        Directory('${rpcs3Dir.path}/firmware'),
        Directory('${rpcs3Dir.path}/dev_flash'),
        Directory('${rpcs3Dir.path}/dev_flash2'),
        Directory('${rpcs3Dir.path}/dev_flash3'),
        Directory('${rpcs3Dir.path}/dev_hdd1'),
        Directory('${rpcs3Dir.path}/cache'),
        Directory('${rpcs3Dir.path}/tmp'),
        Directory('${rpcs3Dir.path}/config'),
        Directory('${rpcs3Dir.path}/logs'),
        Directory('${rpcs3Dir.path}/Icons'),
        Directory('${rpcs3Dir.path}/captures'),
        Directory('${rpcs3Dir.path}/dev_hdd0/game'),
        Directory('${rpcs3Dir.path}/dev_hdd0/tmp'),
      ];
      for (final d in dirsToDelete) {
        if (await d.exists()) {
          await d.delete(recursive: true);
        }
      }

      // Se não restarem saves de jogos PS3 em dev_hdd0/home/*/savedata/,
      // remove toda a pasta rpcs3/ para não deixar resíduos ocultos.
      if (await rpcs3Dir.exists()) {
        if (!await _hasPs3SaveFiles(rpcs3Dir)) {
          await rpcs3Dir.delete(recursive: true);
        } else {
          await for (final entity in rpcs3Dir.list(followLinks: false)) {
            if (entity is File) {
              await _deleteIfExists(entity);
            }
          }
        }
      }
      return true;
    } catch (e) {
      debugPrint('[EmulatorService] Falha ao remover firmware PS3: $e');
      return false;
    }
  }

  Future<String?> importPs3Firmware() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );
    final pickedPath = result?.files.single.path;
    if (pickedPath == null) return null;

    try {
      final sourceFile = File(pickedPath);
      if (!await sourceFile.exists()) return null;
      final len = await sourceFile.length();
      if (len < _minPs3FirmwareBytes) {
        throw StateError(
          'Arquivo inválido para PS3UPDAT.PUP (tamanho inferior a 1 MB). Selecione o firmware oficial PS3UPDAT.PUP.',
        );
      }

      final systemDir = await getApplicationSupportDirectory();
      final firmwareDir = Directory('${systemDir.path}/rpcs3/firmware');
      if (!await firmwareDir.exists()) {
        await firmwareDir.create(recursive: true);
      }
      final canonicalPup = File('${firmwareDir.path}/PS3UPDAT.PUP');
      await sourceFile.copy(canonicalPup.path);
      // Remove possíveis cópias legadas para evitar uso dobrado de armazenamento
      await _deleteIfExists(File('${systemDir.path}/PS3UPDAT.PUP'));
      await _deleteIfExists(File('${systemDir.path}/rpcs3/PS3UPDAT.PUP'));
      return canonicalPup.path;
    } finally {
      await cleanFilePickerTempCache(pickedPath: pickedPath);
    }
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
    bool? singleTrigger,
    Map<String, String>? coreOptions,
    void Function(double coreProgress)? onCoreDownloadProgress,
  }) async {
    final serializedCoreOptions = serializeCoreOptions(coreOptions);
    debugPrint(
      '[Session] platform=$platformSlug core=$coreSoName rom=$romPath',
    );
    final systemDir = await getApplicationSupportDirectory();
    final savesDir = await _savesDirectory();
    final lowerPlatform = platformSlug.toLowerCase();

    if (coreSoName == 'rpcs3_libretro_android.so' || lowerPlatform == 'ps3') {
      final hasPup = await _ensureCanonicalPs3FirmwareLayout(systemDir) ||
          await hasPs3Firmware();
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

    // Para PC Engine CD (Beetle PCE Fast), garante a BIOS syscard3.pce
    if (lowerPlatform == 'pce') {
      await _ensurePceCdBios(systemDir, romPath);
    }

    // Para PSP (PPSSPP), instala os assets oficiais do sistema (fontes,
    // shaders, compat.ini) — sem eles o core não inicializa nenhum jogo.
    if (lowerPlatform == 'psp') {
      await _ensurePpssppAssets(systemDir);
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
FastMemory = True
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

    final int? textureId;
    try {
      textureId = await _methodChannel.invokeMethod<int>(
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
          if (singleTrigger != null) 'singleTrigger': singleTrigger,
          'coreOptions': serializedCoreOptions,
        },
      );
    } on PlatformException catch (e) {
      final msg = e.message?.trim();
      throw StateError(
        (msg != null && msg.isNotEmpty)
            ? msg
            : 'Falha ao carregar motor ou ROM no núcleo selecionado.',
      );
    }

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
    double? rightStickX,
    double? rightStickY,
  }) async {
    try {
      final payload = <String, dynamic>{
        'joypadMask': joypadMask,
        'leftX': (leftStickX * 32767).round(),
        'leftY': (leftStickY * 32767).round(),
      };
      if (rightStickX != null) {
        payload['rightX'] = (rightStickX * 32767).round();
      }
      if (rightStickY != null) {
        payload['rightY'] = (rightStickY * 32767).round();
      }
      await _methodChannel.invokeMethod<void>('updateInput', payload);
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

  /// Consulta o estado real de Wi-Fi / conectividade via Android ConnectivityManager.
  static Future<({bool connected, bool wifi})> fetchNetworkStatus() async {
    try {
      final res = await _methodChannel.invokeMapMethod<String, dynamic>(
        'getNetworkStatus',
      );
      if (res == null) {
        return (connected: true, wifi: true);
      }
      return (
        connected: res['connected'] as bool? ?? false,
        wifi: res['wifi'] as bool? ?? false,
      );
    } on MissingPluginException {
      return (connected: true, wifi: true);
    } catch (_) {
      return (connected: false, wifi: false);
    }
  }

  /// Sincroniza a notificação persistente de progresso de downloads no Android.
  static Future<void> syncDownloadNotification({
    required int activeCount,
    required int queuedCount,
    int completedCount = 0,
    int failedCount = 0,
    int progressPercent = 0,
    bool indeterminate = false,
    String title = '',
    String detail = '',
  }) async {
    try {
      await _methodChannel.invokeMethod<void>('syncDownloadNotification', {
        'activeCount': activeCount,
        'queuedCount': queuedCount,
        'completedCount': completedCount,
        'failedCount': failedCount,
        'progressPercent': progressPercent.clamp(0, 100),
        'indeterminate': indeterminate,
        'title': title,
        'detail': detail,
      });
    } on MissingPluginException {
      // Ignora em ambientes sem ponte Android ativa (ex.: testes unitários).
    } catch (e) {
      debugPrint(
        '[EmulatorService] MethodChannel "syncDownloadNotification" falhou: $e',
      );
    }
  }

  /// Solicita permissão de notificações no Android 13+ (não bloqueante).
  static Future<bool> requestNotificationPermission() async {
    try {
      final granted = await _methodChannel.invokeMethod<bool>(
        'requestNotificationPermission',
      );
      return granted ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint(
        '[EmulatorService] MethodChannel "requestNotificationPermission" falhou: $e',
      );
      return false;
    }
  }

  /// Verifica se o app possui permissão de acesso direto a arquivos locais
  /// (`MANAGE_EXTERNAL_STORAGE` no Android 11+ ou `READ_EXTERNAL_STORAGE` até Android 10).
  static Future<bool> hasDirectStorageAccess() async {
    try {
      final granted = await _methodChannel.invokeMethod<bool>(
        'hasDirectStorageAccess',
      );
      return granted ?? false;
    } on MissingPluginException {
      return true;
    } catch (e) {
      debugPrint(
        '[EmulatorService] MethodChannel "hasDirectStorageAccess" falhou: $e',
      );
      return false;
    }
  }

  /// Solicita acesso direto aos arquivos locais para rodar ISOs sem copiar/duplicar.
  static Future<bool> requestDirectStorageAccess() async {
    try {
      final granted = await _methodChannel.invokeMethod<bool>(
        'requestDirectStorageAccess',
      );
      return granted ?? false;
    } on MissingPluginException {
      return true;
    } catch (e) {
      debugPrint(
        '[EmulatorService] MethodChannel "requestDirectStorageAccess" falhou: $e',
      );
      return false;
    }
  }

  /// Seleciona uma ROM/ISO via seletor nativo do sistema (`ACTION_OPEN_DOCUMENT`)
  /// resolvendo o caminho direto no armazenamento, sem copiar para o cache do app.
  static Future<
      ({String path, String uri, String name, int sizeBytes, bool isDirect})?>
      pickExternalRomDirect() async {
    try {
      final res = await _methodChannel.invokeMapMethod<String, dynamic>(
        'pickExternalRomFile',
      );
      if (res == null) return null;
      return (
        path: (res['path'] as String? ?? '').trim(),
        uri: (res['uri'] as String? ?? '').trim(),
        name: (res['name'] as String? ?? '').trim(),
        sizeBytes: (res['sizeBytes'] as num?)?.toInt() ?? 0,
        isDirect: res['isDirect'] as bool? ?? false,
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      debugPrint(
        '[EmulatorService] MethodChannel "pickExternalRomFile" falhou: $e',
      );
      return null;
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
    if (!_gamepadUiActionController.isClosed) {
      unawaited(_gamepadUiActionController.close());
    }
    if (!_hardwareGamepadStateController.isClosed) {
      unawaited(_hardwareGamepadStateController.close());
    }
    if (_ownsDio) {
      _dio.close(force: true);
    }
  }
}
