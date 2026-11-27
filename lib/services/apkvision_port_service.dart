import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../models/apkvision_port.dart';
import 'pc_port_service.dart';

/// Download de APKs e pacotes de dados dos ports listados no APKVision.
///
/// Os arquivos ficam em `<docs>/pc_ports/apkvision/` para não misturar com
/// os ports open-source do catálogo antigo. Downloads usam o mesmo mecanismo
/// de retomada por `Range` já em [PcPortService].
class ApkVisionPortService {
  ApkVisionPortService._();

  static const int _minApkBytes = 512 * 1024;
  static const int _minDataBytes = 1024;

  static Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final root = Directory('${docs.path}/pc_ports/apkvision');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  static Future<File> _apkFile(ApkVisionPortEntry entry) async {
    final root = await _root();
    return File('${root.path}/${entry.id}.apk');
  }

  static Future<File> _dataFile(ApkVisionPortEntry entry) async {
    if (!entry.hasData) {
      throw StateError('Port ${entry.id} não possui pacote de dados.');
    }
    final root = await _root();
    final dir = Directory('${root.path}/${entry.id}_data');
    if (!await dir.exists()) await dir.create(recursive: true);
    final uri = Uri.parse(entry.dataUrl!);
    final rawName = uri.pathSegments.isEmpty
        ? 'game-data.${entry.dataKind.name}'
        : uri.pathSegments.last;
    final name = PcPortService.safeAssetName(rawName);
    return File('${dir.path}/$name');
  }

  static Future<File> downloadApk(
    ApkVisionPortEntry entry, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!entry.hasApk) {
      throw StateError('Port ${entry.id} não possui APK direto.');
    }
    final out = await _apkFile(entry);
    final partial = File('${out.path}.part');

    final complete = await out.exists() ? await out.length() : 0;
    if (complete >= _minApkBytes) return out;
    if (complete > 0) await out.delete();

    final length = await PcPortService.downloadRawFile(
      partial,
      entry.apkUrl!,
      onProgress: onProgress,
    );
    if (length < _minApkBytes) {
      await partial.delete();
      throw StateError('APK baixado é pequeno demais ($length bytes).');
    }
    if (await out.exists()) await out.delete();
    await partial.rename(out.path);
    return out;
  }

  static Future<File> downloadData(
    ApkVisionPortEntry entry, {
    void Function(int received, int total)? onProgress,
  }) async {
    final out = await _dataFile(entry);
    final partial = File('${out.path}.part');

    final complete = await out.exists() ? await out.length() : 0;
    if (complete >= _minDataBytes) return out;
    if (complete > 0) await out.delete();

    final length = await PcPortService.downloadRawFile(
      partial,
      entry.dataUrl!,
      onProgress: onProgress,
    );
    if (length < _minDataBytes) {
      await partial.delete();
      throw StateError('Pacote baixado é pequeno demais ($length bytes).');
    }
    if (await out.exists()) await out.delete();
    await partial.rename(out.path);
    return out;
  }

  static Future<File?> findDownloadedApk(ApkVisionPortEntry entry) async {
    final file = await _apkFile(entry);
    if (!await file.exists()) return null;
    if (await file.length() < _minApkBytes) return null;
    return file;
  }

  static Future<File?> findDownloadedData(ApkVisionPortEntry entry) async {
    if (!entry.hasData) return null;
    final file = await _dataFile(entry);
    if (!await file.exists()) return null;
    if (await file.length() < _minDataBytes) return null;
    return file;
  }

  static Future<bool> installApk(File apk) => PcPortService.installApk(apk);

  /// Abre o `.7z`/`.zip`/`.iso` em um gerenciador de arquivos instalado.
  static Future<OpenResult> openArchive(File archive) =>
      OpenFilex.open(archive.path);

  static Future<bool> openExternal(String url) =>
      PcPortService.openExternal(url);
}
