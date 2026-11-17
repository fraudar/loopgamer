import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'device_info_service.dart';
import 'emulator_service.dart';

class TurnipDriverRelease {
  const TurnipDriverRelease({
    required this.repo,
    required this.tag,
    required this.assetName,
    required this.downloadUrl,
    required this.sizeBytes,
  });

  final String repo;
  final String tag;
  final String assetName;
  final String downloadUrl;
  final int sizeBytes;

  String get formattedSize {
    if (sizeBytes <= 0) return '-- MB';
    return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

class InstalledGpuDriver {
  const InstalledGpuDriver({
    required this.id,
    required this.name,
    required this.driverVersion,
    required this.description,
    required this.libraryName,
    required this.directoryPath,
    this.author = '',
    this.vendor = '',
    this.packageVersion = '',
    this.minApi = 0,
  });

  final String id;
  final String name;
  final String driverVersion;
  final String description;
  final String libraryName;
  final String directoryPath;

  /// Campos opcionais do `meta.json` AdrenoTools (`author`, `vendor`,
  /// `packageVersion`, `minApi`).
  final String author;
  final String vendor;
  final String packageVersion;
  final int minApi;

  /// Turnip/Freedreno (Mesa): habilita a prioridade KGSL no nativo.
  bool get isMesa {
    final v = vendor.toLowerCase();
    final lib = libraryName.toLowerCase();
    return v == 'mesa' || lib.contains('turnip') || lib.contains('freedreno');
  }

  /// Linha curta "autor • fornecedor • pacote" para a UI (sem campos vazios).
  String get credits => [
        if (author.isNotEmpty) author,
        if (vendor.isNotEmpty) vendor,
        if (packageVersion.isNotEmpty) 'pacote $packageVersion',
      ].join(' • ');
}

/// Motivo pelo qual um pacote de driver foi recusado (inspirado no
/// `GpuDriverHelper.AddError` do hakuX).
enum GpuDriverInstallError {
  /// Não é um zip legível.
  unreadable,

  /// Sem `meta.json` e sem nenhuma biblioteca `.so`.
  notADriver,

  /// `meta.json` cita uma `libraryName` que não existe no pacote.
  missingLibrary,

  /// A biblioteca não é um ELF AArch64 (ex.: driver 32-bit).
  wrongArchitecture,

  /// `minApi` do pacote é maior que o Android do aparelho.
  androidTooOld,

  /// Conteúdo descompactado excede o limite de segurança.
  tooLarge,
}

class GpuDriverInstallException implements Exception {
  const GpuDriverInstallException(this.error, this.message);

  final GpuDriverInstallError error;
  final String message;

  @override
  String toString() => message;
}

/// Gerencia drivers Adreno Turnip customizados para Vulkan (AdrenoTools).
/// Todos os binários ficam em storage interno do app (`filesDir/gpu_drivers/`)
/// para permitir `dlopen`/injeção rootless em dispositivos ARM64.
class GpuDriverService {
  GpuDriverService({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 40),
                headers: const {'User-Agent': 'LoopGamer-Emulator/2.4'},
              ),
            );

  // Repositórios Turnip AdrenoTools usados no ecossistema Eden/Android
  static const List<String> _repos = [
    'K11MCH1/AdrenoToolsDrivers',
    'MrPurple666/purple-turnip',
    'crueter/GameHub-8Elite-Drivers',
    'Weab-chan/freedreno_turnip-CI',
  ];

  static List<TurnipDriverRelease>? _cachedReleases;
  static DateTime? _cachedAt;

  final bool _ownsDio;
  final Dio _dio;

  /// Valida um identificador de driver impedindo traversal (`..`, `/`, `\`, NUL).
  static bool isValidDriverId(String driverId) {
    final trimmed = driverId.trim();
    if (trimmed.isEmpty || trimmed != driverId) return false;
    if (driverId == '.' || driverId == '..') return false;
    if (driverId.contains('..') ||
        driverId.contains('/') ||
        driverId.contains('\\') ||
        driverId.contains('\x00')) {
      return false;
    }
    return true;
  }

  Future<Directory> _driversRootDir() async {
    final baseDir = await getApplicationSupportDirectory();
    final dir = Directory('${baseDir.path}/gpu_drivers');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Lista releases públicas de drivers Turnip nos repositórios AdrenoTools no GitHub.
  Future<List<TurnipDriverRelease>> fetchAvailableDrivers({
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    if (!forceRefresh &&
        _cachedReleases != null &&
        _cachedAt != null &&
        now.difference(_cachedAt!).inMinutes < 15) {
      return _cachedReleases!;
    }

    final lists = await Future.wait(
      _repos.map((repo) async {
        final List<TurnipDriverRelease> repoReleases = [];
        try {
          final res = await _dio.get<List<dynamic>>(
            'https://api.github.com/repos/$repo/releases',
            queryParameters: {'per_page': 5},
          );
          final code = res.statusCode ?? 200;
          if (code < 200 || code >= 300) {
            debugPrint(
              '[GpuDriverService] HTTP $code ao consultar releases de $repo',
            );
            return repoReleases;
          }
          final list = res.data ?? const [];
          for (final item in list.whereType<Map<String, dynamic>>()) {
            final tag = (item['tag_name'] as String?) ?? '';
            final assets = item['assets'] as List<dynamic>? ?? const [];
            for (final asset in assets.whereType<Map<String, dynamic>>()) {
              final name = (asset['name'] as String?) ?? '';
              final lower = name.toLowerCase();
              if (!lower.endsWith('.zip')) continue;
              final url = (asset['browser_download_url'] as String?) ?? '';
              final size = (asset['size'] as num?)?.toInt() ?? 0;
              if (url.isEmpty) continue;
              repoReleases.add(
                TurnipDriverRelease(
                  repo: repo,
                  tag: tag,
                  assetName: name,
                  downloadUrl: url,
                  sizeBytes: size,
                ),
              );
            }
          }
        } catch (e) {
          debugPrint('[GpuDriverService] Falha ao buscar releases de $repo: $e');
        }
        return repoReleases;
      }),
    );
    final releases = [for (final batch in lists) ...batch];
    if (releases.isNotEmpty) {
      _cachedReleases = releases;
      _cachedAt = now;
    }
    return releases;
  }

  /// Baixa e instala um driver AdrenoTools `.zip` no diretório privado do app.
  Future<InstalledGpuDriver> downloadAndInstallDriver(
    TurnipDriverRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    final root = await _driversRootDir();
    final safeId = '${release.tag}_${release.assetName}'
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    final tmpZip = File(
      '${root.path}/$safeId.part_${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      final res = await _dio.download(
        release.downloadUrl,
        tmpZip.path,
        onReceiveProgress: (rec, total) {
          if (total > 0 && onProgress != null) {
            onProgress(rec / total);
          }
        },
      );
      final code = res.statusCode ?? 200;
      if (code < 200 || code >= 300) {
        throw StateError('Falha ao baixar driver (HTTP $code).');
      }
      return await _installFromZipFile(safeId, tmpZip.path);
    } finally {
      try {
        if (await tmpZip.exists()) {
          await tmpZip.delete();
        }
      } catch (e) {
        debugPrint('[GpuDriverService] Falha ao limpar zip temporário: $e');
      }
    }
  }

  /// Importa um arquivo `.zip` local de driver Turnip / AdrenoTools.
  Future<InstalledGpuDriver?> importLocalDriverZip() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['zip'],
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    final file = File(path);
    if (!await file.exists()) return null;

    final safeId = result!.files.single.name
        .replaceAll(RegExp(r'\.zip$', caseSensitive: false), '')
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    try {
      return await _installFromZipFile(safeId, file.path);
    } finally {
      await EmulatorService.cleanFilePickerTempCache(pickedPath: path);
    }
  }

  Future<InstalledGpuDriver> _installFromZipFile(
    String driverId,
    String zipPath,
  ) async {
    final normalizedId = driverId.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (!isValidDriverId(normalizedId) || normalizedId.startsWith('.')) {
      throw ArgumentError.value(driverId, 'driverId', 'ID de driver inválido.');
    }
    final root = await _driversRootDir();
    final rootPath = root.path;
    final sdkInt = (await DeviceInfoService.load())?.sdkInt;

    return _runExtractDriverZipInIsolate(
      zipPath: zipPath,
      rootPath: rootPath,
      driverId: normalizedId,
      sdkInt: sdkInt,
    );
  }

  static Future<InstalledGpuDriver> _runExtractDriverZipInIsolate({
    required String zipPath,
    required String rootPath,
    required String driverId,
    int? sdkInt,
  }) {
    return Isolate.run(
      () => extractDriverZipSync(
        zipPath: zipPath,
        rootPath: rootPath,
        driverId: driverId,
        sdkInt: sdkInt,
      ),
    );
  }

  /// Limite de conteúdo descompactado de um pacote (drivers Turnip têm
  /// ~10-40 MB); protege contra zip bombs.
  static const int maxUncompressedBytes = 256 * 1024 * 1024;

  /// `EM_AARCH64` no cabeçalho ELF.
  static const int _elfMachineAarch64 = 183;

  static String _basename(String entryName) =>
      entryName.replaceAll('\\', '/').split('/').last;

  static String _metaString(Map<String, dynamic>? meta, String key) {
    final value = meta?[key];
    return value is String ? value.trim() : '';
  }

  static int _metaInt(Map<String, dynamic>? meta, String key) {
    final value = meta?[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static bool _isSafeFileName(String name) =>
      name.isNotEmpty &&
      name != '.' &&
      name != '..' &&
      !name.contains('..') &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains('\x00');

  /// ELF 64-bit little-endian para AArch64 (o loader recusaria outro).
  static bool _isAarch64Elf(List<int> bytes) {
    if (bytes.length < 20) return false;
    final isElf = bytes[0] == 0x7F &&
        bytes[1] == 0x45 && // E
        bytes[2] == 0x4C && // L
        bytes[3] == 0x46; // F
    if (!isElf) return false;
    final is64 = bytes[4] == 2;
    final isLittleEndian = bytes[5] == 1;
    final machine = bytes[18] | (bytes[19] << 8);
    return is64 && isLittleEndian && machine == _elfMachineAarch64;
  }

  /// Valida e instala um pacote AdrenoTools de forma atômica.
  ///
  /// Como no `GpuDriverHelper` do hakuX, o pacote é checado antes de tocar no
  /// driver instalado: `meta.json` (ou o primeiro `.json`), a biblioteca que ele
  /// cita, a arquitetura (AArch64) e o `minApi`. Os arquivos são extraídos num
  /// diretório de staging e só substituem a versão anterior depois de
  /// completos — falha no meio deixa o driver antigo intacto.
  @visibleForTesting
  static InstalledGpuDriver extractDriverZipSync({
    required String zipPath,
    required String rootPath,
    required String driverId,
    int? sdkInt,
  }) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    } catch (e) {
      throw GpuDriverInstallException(
        GpuDriverInstallError.unreadable,
        'Não foi possível ler o pacote do driver ($e).',
      );
    }

    final files = archive.where((e) => e.isFile).toList();
    var totalBytes = 0;
    for (final entry in files) {
      totalBytes += entry.size;
    }
    if (totalBytes > maxUncompressedBytes) {
      throw const GpuDriverInstallException(
        GpuDriverInstallError.tooLarge,
        'Pacote de driver grande demais (limite de 256 MB descompactado).',
      );
    }

    final jsonEntries = files
        .where((e) => _basename(e.name).toLowerCase().endsWith('.json'))
        .toList();
    final metaEntry = jsonEntries
            .where((e) => _basename(e.name).toLowerCase() == 'meta.json')
            .firstOrNull ??
        jsonEntries.firstOrNull;
    Map<String, dynamic>? meta;
    if (metaEntry != null) {
      try {
        final decoded = jsonDecode(
          utf8.decode(metaEntry.content as List<int>, allowMalformed: true),
        );
        if (decoded is Map<String, dynamic>) meta = decoded;
      } catch (e) {
        debugPrint('[GpuDriverService] meta.json inválido em $driverId: $e');
      }
    }

    ArchiveFile? findLibrary(String name) => files
        .where((e) => _basename(e.name) == name)
        .firstOrNull;

    final declaredLibrary = _metaString(meta, 'libraryName');
    ArchiveFile? libraryEntry;
    if (declaredLibrary.isNotEmpty) {
      if (!_isSafeFileName(declaredLibrary)) {
        throw const GpuDriverInstallException(
          GpuDriverInstallError.missingLibrary,
          'meta.json do driver cita uma libraryName inválida.',
        );
      }
      libraryEntry = findLibrary(declaredLibrary);
      if (libraryEntry == null) {
        throw GpuDriverInstallException(
          GpuDriverInstallError.missingLibrary,
          'Pacote incompleto: meta.json cita "$declaredLibrary", mas o arquivo não está no .zip.',
        );
      }
    } else {
      libraryEntry = files
          .where((e) => _basename(e.name).toLowerCase().endsWith('.so'))
          .firstOrNull;
      if (libraryEntry == null) {
        throw const GpuDriverInstallException(
          GpuDriverInstallError.notADriver,
          'Pacote inválido: nenhuma biblioteca .so ou meta.json de driver Adreno foi encontrada.',
        );
      }
    }
    final libraryName = _basename(libraryEntry.name);
    if (!_isSafeFileName(libraryName)) {
      throw const GpuDriverInstallException(
        GpuDriverInstallError.notADriver,
        'Pacote inválido: nome de biblioteca inseguro.',
      );
    }

    if (!_isAarch64Elf(libraryEntry.content as List<int>)) {
      throw GpuDriverInstallException(
        GpuDriverInstallError.wrongArchitecture,
        '"$libraryName" não é uma biblioteca ARM64 (AArch64) — este driver não roda no LoopGamer.',
      );
    }

    final minApi = _metaInt(meta, 'minApi');
    if (sdkInt != null && sdkInt > 0 && minApi > sdkInt) {
      throw GpuDriverInstallException(
        GpuDriverInstallError.androidTooOld,
        'Este driver exige Android API $minApi; o aparelho está na API $sdkInt.',
      );
    }

    final root = Directory(rootPath)..createSync(recursive: true);
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final staging = Directory('${root.path}/.staging_${driverId}_$stamp');
    final backup = Directory('${root.path}/.old_${driverId}_$stamp');
    final targetDir = Directory('${root.path}/$driverId');
    try {
      staging.createSync(recursive: true);
      final canonicalStaging = staging.resolveSymbolicLinksSync();
      final stagingPrefix = canonicalStaging.endsWith(Platform.pathSeparator)
          ? canonicalStaging
          : '$canonicalStaging${Platform.pathSeparator}';

      for (final entry in files) {
        final fileName = _basename(entry.name);
        if (!_isSafeFileName(fileName)) continue;
        if (entry.name.replaceAll('\\', '/').contains('..')) continue;
        final outFile = File('${staging.path}/$fileName');
        outFile.writeAsBytesSync(entry.content as List<int>, flush: true);
        if (!outFile.resolveSymbolicLinksSync().startsWith(stagingPrefix)) {
          outFile.deleteSync();
        }
      }

      if (!File('${staging.path}/$libraryName').existsSync()) {
        throw GpuDriverInstallException(
          GpuDriverInstallError.missingLibrary,
          'Falha ao extrair "$libraryName" do pacote.',
        );
      }

      final normalizedMeta = <String, dynamic>{
        ...?meta,
        'name': _metaString(meta, 'name').isNotEmpty
            ? _metaString(meta, 'name')
            : driverId,
        'driverVersion': _metaString(meta, 'driverVersion').isNotEmpty
            ? _metaString(meta, 'driverVersion')
            : 'Custom',
        'description': _metaString(meta, 'description').isNotEmpty
            ? _metaString(meta, 'description')
            : 'Driver Vulkan AdrenoTools',
        'libraryName': libraryName,
      };
      File('${staging.path}/meta.json').writeAsStringSync(
        jsonEncode(normalizedMeta),
        flush: true,
      );

      // Troca atômica: antigo -> backup, staging -> alvo, remove backup.
      if (targetDir.existsSync()) targetDir.renameSync(backup.path);
      try {
        staging.renameSync(targetDir.path);
      } catch (_) {
        if (backup.existsSync()) backup.renameSync(targetDir.path);
        rethrow;
      }
      if (backup.existsSync()) backup.deleteSync(recursive: true);

      return _driverFromMeta(driverId, targetDir.path, normalizedMeta);
    } finally {
      if (staging.existsSync()) {
        try {
          staging.deleteSync(recursive: true);
        } catch (e) {
          debugPrint('[GpuDriverService] Falha ao limpar staging: $e');
        }
      }
    }
  }

  static InstalledGpuDriver _driverFromMeta(
    String id,
    String dirPath,
    Map<String, dynamic> meta,
  ) {
    String orDefault(String key, String fallback) {
      final v = _metaString(meta, key);
      return v.isNotEmpty ? v : fallback;
    }

    return InstalledGpuDriver(
      id: id,
      name: orDefault('name', id),
      driverVersion: orDefault('driverVersion', 'Custom'),
      description: orDefault('description', 'Driver Vulkan AdrenoTools'),
      libraryName: _metaString(meta, 'libraryName'),
      directoryPath: dirPath.endsWith('/') ? dirPath : '$dirPath/',
      author: _metaString(meta, 'author'),
      vendor: _metaString(meta, 'vendor'),
      packageVersion: _metaString(meta, 'packageVersion'),
      minApi: _metaInt(meta, 'minApi'),
    );
  }

  /// Remove diretórios temporários deixados por uma instalação interrompida
  /// (app morto durante a troca atômica).
  static void _cleanupStaleStaging(Directory root) {
    try {
      for (final entity in root.listSync()) {
        if (entity is! Directory) continue;
        final name = entity.path.split(Platform.pathSeparator).last;
        if (name.startsWith('.staging_')) {
          entity.deleteSync(recursive: true);
        } else if (name.startsWith('.old_')) {
          // Restaura o backup se a troca não terminou (alvo ausente).
          final rest = name.substring('.old_'.length);
          final cut = rest.lastIndexOf('_');
          final id = cut > 0 ? rest.substring(0, cut) : '';
          final target = Directory('${root.path}/$id');
          if (id.isNotEmpty && isValidDriverId(id) && !target.existsSync()) {
            entity.renameSync(target.path);
          } else {
            entity.deleteSync(recursive: true);
          }
        }
      }
    } catch (e) {
      debugPrint('[GpuDriverService] Falha ao limpar staging antigo: $e');
    }
  }

  /// Lista todos os drivers customizados já extraídos em disco.
  Future<List<InstalledGpuDriver>> listInstalledDrivers() async {
    final root = await _driversRootDir();
    if (!await root.exists()) return const [];
    _cleanupStaleStaging(root);
    final List<InstalledGpuDriver> result = [];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final id = entity.path.split(Platform.pathSeparator).last;
      if (id.startsWith('.')) continue;
      final metaFile = File('${entity.path}/meta.json');
      if (!await metaFile.exists()) continue;
      try {
        final decoded =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final libName = _metaString(decoded, 'libraryName');
        if (!_isSafeFileName(libName)) continue;
        if (!await File('${entity.path}/$libName').exists()) continue;
        result.add(_driverFromMeta(id, entity.path, decoded));
      } catch (e) {
        debugPrint(
          '[GpuDriverService] Falha ao ler metadados de driver em ${entity.path}: $e',
        );
      }
    }
    result.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return result;
  }

  Future<void> deleteDriver(String driverId) async {
    if (!isValidDriverId(driverId)) {
      throw ArgumentError.value(
        driverId,
        'driverId',
        'ID de driver inválido para remoção.',
      );
    }
    final root = await _driversRootDir();
    final rootCanonical = await root.resolveSymbolicLinks();
    final dir = Directory('${root.path}/$driverId');
    if (!await dir.exists()) return;

    final targetCanonical = await dir.resolveSymbolicLinks();
    final expectedPrefix = rootCanonical.endsWith(Platform.pathSeparator)
        ? rootCanonical
        : '$rootCanonical${Platform.pathSeparator}';
    if (targetCanonical == rootCanonical ||
        !targetCanonical.startsWith(expectedPrefix)) {
      throw ArgumentError.value(
        driverId,
        'driverId',
        'Caminho do driver resolve fora do diretório gpu_drivers.',
      );
    }
    await dir.delete(recursive: true);
  }

  void dispose() {
    if (_ownsDio) {
      _dio.close(force: true);
    }
  }
}
