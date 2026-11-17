import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

/// Verifica e instala atualizações do LoopGamer via GitHub Releases.
///
/// O app compara a versão instalada (versionName do Android) com a tag do
/// release mais recente do repositório `fraudar/loopgamer`. Quando há versão
/// nova, baixa o APK do release e abre o instalador do sistema
/// (`ACTION_VIEW` + `FileProvider`), que cuida da permissão de instalação.
class UpdateService {
  UpdateService._();

  static const String _repoOwner = 'fraudar';
  static const String _repoName = 'loopgamer';
  static const String _repoApiUrl =
      'https://api.github.com/repos/$_repoOwner/$_repoName/releases/latest';

  static const String _apkAssetName = 'loopgamer-release.apk';

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

  /// Resultado da verificação de atualização.
  static Future<UpdateCheckResult> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version.trim();
      if (current.isEmpty) return UpdateCheckResult.unknown();

      final response = await _dio.get<String>(_repoApiUrl);
      if (response.statusCode != 200 || response.data == null) {
        return UpdateCheckResult.unknown();
      }
      final json = jsonDecode(response.data!) as Map<String, dynamic>;
      final tag = (json['tag_name'] as String?)?.trim() ?? '';
      final releaseVersion = _versionFromTag(tag);
      if (releaseVersion == null) return UpdateCheckResult.unknown();

      final isNewer = _compareVersions(releaseVersion, current) > 0;
      return UpdateCheckResult(
        hasUpdate: isNewer,
        currentVersion: current,
        latestVersion: releaseVersion,
        releaseTag: tag,
        releaseName: (json['name'] as String?) ?? tag,
        releaseUrl: (json['html_url'] as String?) ?? '',
        apkUrl: _findApkUrl(json),
      );
    } catch (e) {
      debugPrint('[UpdateService] Falha ao verificar atualização: $e');
      return UpdateCheckResult.unknown(error: e.toString());
    }
  }

  /// Baixa o APK do release mais recente e abre o instalador.
  ///
  /// Retorna a [File] baixada quando o download termina; a abertura do
  /// instalador é feita pelo chamador via [openApkInstaller].
  static Future<File> downloadLatestApk({
    void Function(int received, int total)? onProgress,
  }) async {
    final result = await checkForUpdate();
    final apkUrl = result.apkUrl;
    if (apkUrl == null || apkUrl.isEmpty) {
      throw StateError(
        'Release ${result.releaseTag.isEmpty ? '(sem tag)' : result.releaseTag} '
        'não possui o asset $_apkAssetName.',
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final apkFile = File('${dir.path}/updates/$_apkAssetName');
    await apkFile.parent.create(recursive: true);

    final partial = File('${apkFile.path}.part');
    try {
      await _dio.download(
        apkUrl,
        partial.path,
        onReceiveProgress: (received, total) => onProgress?.call(received, total),
        options: Options(
          receiveTimeout: const Duration(minutes: 10),
          sendTimeout: const Duration(seconds: 30),
          headers: const {'User-Agent': 'LoopGamer-App'},
        ),
      );
      final length = await partial.length();
      if (length < 1024 * 1024) {
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

  /// Abre o APK com o instalador nativo do Android via FileProvider
  /// (open_filex gerencia o content:// URI exigido desde o Android 7).
  static Future<bool> openApkInstaller(File apkFile) async {
    if (!Platform.isAndroid) return false;
    final result = await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done;
  }

  /// Abre a página do release no GitHub (fallback quando o APK não existe).
  static Future<bool> openReleasePage(String releaseUrl) async {
    final uri = Uri.parse(releaseUrl);
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static String? _findApkUrl(Map<String, dynamic> releaseJson) {
    final assets = releaseJson['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map<String, dynamic> &&
          asset['name'] == _apkAssetName &&
          asset['browser_download_url'] is String) {
        return asset['browser_download_url'] as String;
      }
    }
    return null;
  }

  /// Extrai a versão numérica de uma tag tipo `v2.3.0` ou `2.3.0`.
  static String? _versionFromTag(String tag) {
    final match = RegExp(r'(\d+(?:\.\d+)+)').firstMatch(tag);
    return match?.group(1);
  }

  /// Compara versões `x.y.z` (semver simples). Retorna >0 se [a] > [b].
  static int _compareVersions(String a, String b) {
    final pa = a.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final pb = b.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final len = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < len; i++) {
      final va = i < pa.length ? pa[i] : 0;
      final vb = i < pb.length ? pb[i] : 0;
      if (va != vb) return va.compareTo(vb);
    }
    return 0;
  }
}

class UpdateCheckResult {
  final bool hasUpdate;
  final String currentVersion;
  final String latestVersion;
  final String releaseTag;
  final String releaseName;
  final String releaseUrl;
  final String? apkUrl;
  final String? error;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseTag,
    required this.releaseName,
    required this.releaseUrl,
    this.apkUrl,
    this.error,
  });

  factory UpdateCheckResult.unknown({String? error}) => UpdateCheckResult(
        hasUpdate: false,
        currentVersion: '',
        latestVersion: '',
        releaseTag: '',
        releaseName: '',
        releaseUrl: '',
        error: error,
      );
}
