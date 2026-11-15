import 'dart:convert';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

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
  });

  final String id;
  final String name;
  final String driverVersion;
  final String description;
  final String libraryName;
  final String directoryPath;
}

/// Gerencia drivers Adreno Turnip customizados para Vulkan (AdrenoTools).
/// Todos os binários ficam em storage interno do app (`filesDir/gpu_drivers/`)
/// para permitir `dlopen`/injeção rootless em dispositivos ARM64.
class GpuDriverService {
  // Repositórios Turnip AdrenoTools usados no ecossistema Eden/Android
  static const List<String> _repos = [
    'K11MCH1/AdrenoToolsDrivers',
    'MrPurple666/purple-turnip',
    'crueter/GameHub-8Elite-Drivers',
    'Weab-chan/freedreno_turnip-CI',
  ];

  static List<TurnipDriverRelease>? _cachedReleases;
  static DateTime? _cachedAt;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 12),
      receiveTimeout: const Duration(seconds: 40),
      headers: const {'User-Agent': 'LoopGamer-Emulator/2.4'},
    ),
  );

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
        } catch (_) {}
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
    final tmpZip = File('${root.path}/$safeId.part');
    await _dio.download(
      release.downloadUrl,
      tmpZip.path,
      onReceiveProgress: (rec, total) {
        if (total > 0 && onProgress != null) {
          onProgress(rec / total);
        }
      },
    );
    try {
      final bytes = await tmpZip.readAsBytes();
      return await _installFromZipBytes(safeId, bytes);
    } finally {
      if (await tmpZip.exists()) {
        await tmpZip.delete();
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
    final bytes = await file.readAsBytes();
    return _installFromZipBytes(safeId, bytes);
  }

  Future<InstalledGpuDriver> _installFromZipBytes(
    String driverId,
    List<int> zipBytes,
  ) async {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    Map<String, dynamic>? meta;
    String? detectedSoName;

    for (final entry in archive) {
      if (!entry.isFile) continue;
      final base = entry.name.split('/').last.split('\\').last;
      if (base.toLowerCase() == 'meta.json') {
        try {
          final jsonStr = utf8.decode(entry.content as List<int>);
          final decoded = jsonDecode(jsonStr);
          if (decoded is Map<String, dynamic>) {
            meta = decoded;
          }
        } catch (_) {}
      } else if (base.toLowerCase().endsWith('.so') &&
          detectedSoName == null) {
        detectedSoName = base;
      }
    }

    final libraryName =
        ((meta?['libraryName'] as String?)?.trim().isNotEmpty == true)
            ? (meta!['libraryName'] as String).trim()
            : detectedSoName;
    if (libraryName == null || libraryName.isEmpty) {
      throw StateError(
        'Pacote inválido: nenhuma biblioteca .so ou meta.json de driver Adreno foi encontrada.',
      );
    }

    final root = await _driversRootDir();
    final targetDir = Directory('${root.path}/$driverId');
    if (await targetDir.exists()) {
      await targetDir.delete(recursive: true);
    }
    await targetDir.create(recursive: true);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      final normalized = entry.name.replaceAll('\\', '/');
      if (normalized.contains('..')) continue;
      final fileName = normalized.split('/').last;
      if (fileName.isEmpty) continue;
      final outFile = File('${targetDir.path}/$fileName');
      await outFile.writeAsBytes(entry.content as List<int>, flush: true);
    }

    final name = (meta?['name'] as String?)?.trim();
    final ver = (meta?['driverVersion'] as String?)?.trim();
    final desc = (meta?['description'] as String?)?.trim();

    if (meta == null) {
      await File('${targetDir.path}/meta.json').writeAsString(
        jsonEncode({
          'name': driverId,
          'driverVersion': 'Custom',
          'description': 'Driver Vulkan importado',
          'libraryName': libraryName,
        }),
        flush: true,
      );
    }

    return InstalledGpuDriver(
      id: driverId,
      name: (name != null && name.isNotEmpty) ? name : driverId,
      driverVersion: (ver != null && ver.isNotEmpty) ? ver : 'Custom',
      description: (desc != null && desc.isNotEmpty)
          ? desc
          : 'Driver Vulkan AdrenoTools',
      libraryName: libraryName,
      directoryPath: '${targetDir.path}/',
    );
  }

  /// Lista todos os drivers customizados já extraídos em disco.
  Future<List<InstalledGpuDriver>> listInstalledDrivers() async {
    final root = await _driversRootDir();
    if (!await root.exists()) return const [];
    final List<InstalledGpuDriver> result = [];
    await for (final entity in root.list()) {
      if (entity is! Directory) continue;
      final metaFile = File('${entity.path}/meta.json');
      if (!await metaFile.exists()) continue;
      try {
        final decoded =
            jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
        final libName = (decoded['libraryName'] as String?)?.trim() ?? '';
        if (libName.isEmpty) continue;
        if (!await File('${entity.path}/$libName').exists()) continue;
        final id = entity.path.split(Platform.pathSeparator).last;
        result.add(
          InstalledGpuDriver(
            id: id,
            name: (decoded['name'] as String?) ?? id,
            driverVersion: (decoded['driverVersion'] as String?) ?? 'Custom',
            description:
                (decoded['description'] as String?) ?? 'Driver AdrenoTools',
            libraryName: libName,
            directoryPath: '${entity.path}/',
          ),
        );
      } catch (_) {}
    }
    result.sort((a, b) => a.name.compareTo(b.name));
    return result;
  }

  Future<void> deleteDriver(String driverId) async {
    final root = await _driversRootDir();
    final dir = Directory('${root.path}/$driverId');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }
}
