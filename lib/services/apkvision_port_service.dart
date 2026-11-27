import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../models/apkvision_port.dart';
import 'archive_extract_service.dart';
import 'emulator_service.dart';
import 'pc_port_service.dart';

/// Download e extração dos APKs/pacotes de dados dos ports do APKVision.
///
/// Os arquivos ficam **visíveis** em `Documents/LoopGamer/Ports/<id>/` no
/// armazenamento interno (`/storage/emulated/0/LoopGamer/Ports/...`), para o
/// jogador conseguir abrir o gerenciador de arquivos e mover a pasta extraída
/// para dentro do port. Sem permissão de armazenamento direto, cai para a
/// pasta privada do app — e a UI avisa.
class ApkVisionPortService {
  ApkVisionPortService._();

  static const int _minApkBytes = 512 * 1024;
  static const int _minDataBytes = 1024;

  static const String publicRootPath = '/storage/emulated/0/LoopGamer/Ports';

  static String? _resolvedRoot;

  /// `true` quando a pasta usada é a pública (visível em qualquer gerenciador).
  static bool get isPublicRoot => _resolvedRoot == publicRootPath;

  /// Resolve a raiz: pública com permissão, privada sem.
  static Future<Directory> root() async {
    if (_resolvedRoot != null) {
      final cached = Directory(_resolvedRoot!);
      if (await cached.exists()) return cached;
    }
    Directory? chosen;
    try {
      final allowed = await EmulatorService.hasDirectStorageAccess();
      if (allowed) {
        final pub = Directory(publicRootPath);
        if (!await pub.exists()) await pub.create(recursive: true);
        // Confirma que é gravável de verdade, não só existente.
        final probe = File('${pub.path}/.write_probe');
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        chosen = pub;
      }
    } catch (e) {
      debugPrint('[ApkVision] Sem acesso à pasta pública: $e');
    }
    if (chosen == null) {
      final docs = await getApplicationDocumentsDirectory();
      chosen = Directory('${docs.path}/pc_ports/apkvision');
      if (!await chosen.exists()) await chosen.create(recursive: true);
    }
    _resolvedRoot = chosen.path;
    return chosen;
  }

  /// Pasta do port: `.../Ports/<id>/` — é a pasta que o jogador move/limpa.
  static Future<Directory> portDir(ApkVisionPortEntry entry) async {
    final base = await root();
    final dir = Directory('${base.path}/${entry.id}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Pasta onde o pacote de dados é salvo antes de extrair.
  static Future<Directory> downloadsDir(ApkVisionPortEntry entry) async {
    final base = await portDir(entry);
    final dir = Directory('${base.path}/_downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// Pasta de destino da extração — `.../<id>/game/`.
  static Future<Directory> gameDir(ApkVisionPortEntry entry) async {
    final base = await portDir(entry);
    final dir = Directory('${base.path}/game');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> apkFile(ApkVisionPortEntry entry) async {
    final base = await downloadsDir(entry);
    return File('${base.path}/${entry.id}.apk');
  }

  static Future<File> dataFile(ApkVisionPortEntry entry) async {
    if (!entry.hasData) {
      throw StateError('Port ${entry.id} não possui pacote de dados.');
    }
    final base = await downloadsDir(entry);
    final uri = Uri.parse(entry.dataUrl!);
    final rawName = uri.pathSegments.isEmpty
        ? 'game-data.${entry.dataKind.name}'
        : uri.pathSegments.last;
    final name = PcPortService.safeAssetName(rawName);
    return File('${base.path}/$name');
  }

  static Future<File> downloadApk(
    ApkVisionPortEntry entry, {
    void Function(int received, int total)? onProgress,
  }) async {
    if (!entry.hasApk) {
      throw StateError('Port ${entry.id} não possui APK direto.');
    }
    final out = await apkFile(entry);
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
    final out = await dataFile(entry);
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

  /// Extrai o pacote baixado para `.../game/`. Formatos compactados apenas.
  static Future<ArchiveExtractResult> extractData(
    ApkVisionPortEntry entry, {
    bool deleteSource = false,
  }) async {
    final archive = await dataFile(entry);
    if (!await archive.exists()) {
      throw StateError('Baixe o pacote de dados antes de extrair.');
    }
    final dest = await gameDir(entry);
    return ArchiveExtractService.extract(
      archive,
      destDir: dest,
      deleteSource: deleteSource,
    );
  }

  /// `true` quando `.../game/` já tem conteúdo extraído.
  static Future<bool> hasExtractedData(ApkVisionPortEntry entry) async {
    final dir = await gameDir(entry);
    if (!await dir.exists()) return false;
    await for (final _ in dir.list(followLinks: false)) {
      return true;
    }
    return false;
  }

  static Future<File?> findDownloadedApk(ApkVisionPortEntry entry) async {
    final file = await apkFile(entry);
    if (!await file.exists()) return null;
    if (await file.length() < _minApkBytes) return null;
    return file;
  }

  static Future<File?> findDownloadedData(ApkVisionPortEntry entry) async {
    if (!entry.hasData) return null;
    final file = await dataFile(entry);
    if (!await file.exists()) return null;
    if (await file.length() < _minDataBytes) return null;
    return file;
  }

  static Future<bool> installApk(File apk) => PcPortService.installApk(apk);

  /// Abre o `.7z`/`.zip`/`.iso` em um gerenciador de arquivos instalado.
  static Future<OpenResult> openArchive(File archive) =>
      OpenFilex.open(archive.path);

  static Future<bool> openDocumentRoot() =>
      ArchiveExtractService.openDocumentRoot();

  static Future<bool> openExternal(String url) =>
      PcPortService.openExternal(url);
}
