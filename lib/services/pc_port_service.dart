import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/pc_port.dart';

enum PcPortDownloadState { idle, resolving, downloading, downloaded, installing, error }

/// Resolve e baixa APKs de ports de PC a partir do catálogo [PcPortCatalog].
class PcPortService {
  PcPortService._();

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 15),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'LoopGamer-App',
      },
    ),
  );

  /// Resolve a URL do APK de um item [PcPortSource.githubRelease] consultando
  /// o release mais recente do repositório no GitHub.
  static Future<String> resolveApkUrl(PcPortEntry entry) async {
    if (entry.source == PcPortSource.directApk) {
      final url = entry.directApkUrl;
      if (url == null || url.isEmpty) {
        throw StateError('Item ${entry.id} não possui URL de APK.');
      }
      return url;
    }
    if (entry.source != PcPortSource.githubRelease ||
        entry.githubRepo == null) {
      throw StateError('Item ${entry.id} não é baixável diretamente.');
    }

    final repo = entry.githubRepo!;
    final response = await _dio.get<String>(
      'https://api.github.com/repos/$repo/releases/latest',
    );
    if (response.statusCode != 200 || response.data == null) {
      throw StateError('Falha ao consultar releases de $repo '
          '(HTTP ${response.statusCode}).');
    }
    final json = jsonDecode(response.data!) as Map<String, dynamic>;
    final assets = json['assets'];
    if (assets is! List) {
      throw StateError('Release de $repo não possui assets.');
    }

    final prefix = entry.apkAssetPrefix ?? '';
    final suffix = entry.apkAssetSuffix ?? '.apk';
    for (final asset in assets) {
      if (asset is Map<String, dynamic>) {
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String? ?? '';
        if (name.startsWith(prefix) && name.endsWith(suffix) && url.isNotEmpty) {
          return url;
        }
      }
    }
    throw StateError(
      'Nenhum APK compatível encontrado no release de $repo '
      '(prefixo "$prefix", sufixo "$suffix").',
    );
  }

  /// Baixa o APK e retorna o [File] pronto para instalação.
  static Future<File> downloadApk(
    PcPortEntry entry, {
    void Function(int received, int total)? onProgress,
  }) async {
    final apkUrl = await resolveApkUrl(entry);
    final dir = await getApplicationDocumentsDirectory();
    final safeName = '${entry.id}.apk';
    final apkFile = File('${dir.path}/pc_ports/$safeName');
    await apkFile.parent.create(recursive: true);

    final partial = File('${apkFile.path}.part');
    try {
      await _dio.download(
        apkUrl,
        partial.path,
        onReceiveProgress: (received, total) => onProgress?.call(received, total),
        options: Options(
          receiveTimeout: const Duration(minutes: 15),
          sendTimeout: const Duration(seconds: 30),
          headers: const {'User-Agent': 'LoopGamer-App'},
        ),
      );
      final length = await partial.length();
      if (length < 512 * 1024) {
        throw StateError('APK baixado é pequeno demais ($length bytes).');
      }
      if (await apkFile.exists()) await apkFile.delete();
      await partial.rename(apkFile.path);
      return apkFile;
    } finally {
      try {
        if (await partial.exists()) await partial.delete();
      } catch (_) {}
    }
  }

  /// Abre o APK no instalador nativo do Android.
  static Future<bool> installApk(File apkFile) async {
    if (!Platform.isAndroid) return false;
    final result = await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  }

  /// Abre link externo (Play Store / F-Droid / site oficial).
  static Future<bool> openExternal(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    return launchUrl(uri);
  }
}
