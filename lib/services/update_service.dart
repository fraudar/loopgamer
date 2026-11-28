import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// Verificação e instalação de atualizações via GitHub Releases.
///
/// A checagem não depende de nenhuma tela específica: [UpdateCoordinator]
/// dispara [checkForUpdate] no startup do app. O resultado também fica em
/// cache em disco para o app não consultar o GitHub a cada abertura.
class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const String repoOwner = 'bugaram';
  static const String repoName = 'loopgamer';
  static const String _repoApiUrl =
      'https://api.github.com/repos/$repoOwner/$repoName/releases/latest';
  static const String apkAssetName = 'loopgamer-release.apk';
  static const String installChannelName = 'org.loopgamer.update/methods';

  static const Duration checkCacheTtl = Duration(minutes: 30);
  static const int _minApkBytes = 1024 * 1024;
  static const int _maxDownloadAttempts = 3;

  static const MethodChannel _installChannel = MethodChannel(
    installChannelName,
  );

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 20),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'LoopGamer-App',
      },
    ),
  );

  UpdateCheckResult? _cached;
  DateTime? _cachedAt;
  UpdateState? _loadedState;

  /// Estado persistido: última checagem, última versão oferecida e versão
  /// dispensada pelo usuário ("Depois").
  Future<UpdateState> loadState() async {
    final cachedState = _loadedState;
    if (cachedState != null) return cachedState;
    final state = await _readState();
    _loadedState = state;
    return state;
  }

  Future<void> saveState(UpdateState state) async {
    _loadedState = state;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}update_state.json');
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode(state.toJson()),
        flush: true,
      );
    } catch (e) {
      debugPrint('[UpdateService] Falha ao persistir estado: $e');
    }
  }

  Future<UpdateState> _readState() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}update_state.json');
      if (!await file.exists()) return const UpdateState();
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const UpdateState();
      return UpdateState.fromJson(decoded);
    } catch (e) {
      debugPrint('[UpdateService] Falha ao ler estado: $e');
      return const UpdateState();
    }
  }

  /// Consulta o release mais recente. Com [force], ignora o cache de 30 min.
  Future<UpdateCheckResult> checkForUpdate({bool force = false}) async {
    final now = DateTime.now();
    final cached = _cached;
    final cachedAt = _cachedAt;
    if (!force &&
        cached != null &&
        cachedAt != null &&
        now.difference(cachedAt) < checkCacheTtl) {
      return cached;
    }

    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version.trim();
      final currentBuild = info.buildNumber.trim();
      if (current.isEmpty) return UpdateCheckResult.unknown();

      final response = await _dio.get<String>(
        _repoApiUrl,
        options: Options(
          headers: const {'Cache-Control': 'no-cache'},
          responseType: ResponseType.plain,
        ),
      );
      if (response.statusCode != 200 || response.data == null) {
        return UpdateCheckResult.unknown(
          error: 'GitHub respondeu HTTP ${response.statusCode}.',
        );
      }

      final decoded = jsonDecode(response.data!);
      if (decoded is! Map<String, dynamic>) {
        return UpdateCheckResult.unknown(error: 'JSON de release inválido.');
      }

      final tag = (decoded['tag_name'] as String?)?.trim() ?? '';
      final releaseVersion = versionFromTag(tag);
      if (releaseVersion == null) {
        return UpdateCheckResult.unknown(error: 'Release sem versão na tag.');
      }

      final isNewer = compareVersions(releaseVersion, current) > 0;
      final apk = _findApk(decoded);
      final result = UpdateCheckResult(
        hasUpdate: isNewer,
        currentVersion: current,
        currentBuild: currentBuild,
        latestVersion: releaseVersion,
        releaseTag: tag,
        releaseName: (decoded['name'] as String?) ?? tag,
        releaseUrl: (decoded['html_url'] as String?) ?? '',
        releaseNotes: (decoded['body'] as String?) ?? '',
        publishedAt: decoded['published_at'] as String?,
        apkUrl: apk?.url,
        apkSize: apk?.size,
      );

      _cached = result;
      _cachedAt = now;
      final state = await loadState();
      await saveState(
        state.copyWith(
          lastCheckMs: now.millisecondsSinceEpoch,
          lastKnownVersion: releaseVersion,
        ),
      );
      return result;
    } catch (e) {
      debugPrint('[UpdateService] Falha ao verificar atualização: $e');
      return UpdateCheckResult.unknown(error: e.toString());
    }
  }

  /// Baixa o APK com retry e gravação atômica.
  Future<File> downloadLatestApk({
    UpdateCheckResult? result,
    void Function(int received, int total)? onProgress,
  }) async {
    final check = result ?? await checkForUpdate();
    final apkUrl = check.apkUrl;
    if (apkUrl == null || apkUrl.isEmpty) {
      throw StateError(
        'Release ${check.releaseTag.isEmpty ? '(sem tag)' : check.releaseTag} '
        'não possui o asset $apkAssetName.',
      );
    }

    final dir = await getApplicationDocumentsDirectory();
    final updatesDir = Directory('${dir.path}${Platform.pathSeparator}updates');
    await updatesDir.create(recursive: true);
    final apkFile = File('${updatesDir.path}${Platform.pathSeparator}$apkAssetName');
    final partial = File('${apkFile.path}.part');

    Object? lastError;
    for (var attempt = 1; attempt <= _maxDownloadAttempts; attempt++) {
      try {
        if (await partial.exists()) await partial.delete();
        await _dio.download(
          apkUrl,
          partial.path,
          onReceiveProgress: (received, total) {
            onProgress?.call(received, total);
          },
          options: Options(
            headers: const {'User-Agent': 'LoopGamer-App'},
            receiveTimeout: const Duration(minutes: 15),
            sendTimeout: const Duration(seconds: 30),
            validateStatus: (status) => status != null && status == 200,
          ),
        );
        final length = await partial.length();
        if (length < _minApkBytes) {
          throw StateError('APK baixado é pequeno demais ($length bytes).');
        }
        if (check.apkSize != null &&
            check.apkSize! > 0 &&
            length != check.apkSize) {
          throw StateError(
            'Tamanho divergente: baixado $length bytes, release ${check.apkSize} bytes.',
          );
        }
        if (await apkFile.exists()) await apkFile.delete();
        await partial.rename(apkFile.path);
        onProgress?.call(length, length);
        return apkFile;
      } catch (e) {
        lastError = e;
        debugPrint('[UpdateService] Download tentativa $attempt falhou: $e');
        if (attempt < _maxDownloadAttempts) {
          await Future<void>.delayed(Duration(seconds: attempt * 2));
        }
      }
    }
    if (await partial.exists()) {
      try {
        await partial.delete();
      } catch (_) {}
    }
    throw StateError('Falha ao baixar atualização: $lastError');
  }

  /// Abre o instalador nativo. No Android 8+, exige
  /// `REQUEST_INSTALL_PACKAGES` e a concessão de "instalar apps desconhecidos".
  Future<bool> installApk(File apkFile) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _installChannel.invokeMethod<bool>(
        'installApk',
        <String, Object?>{'path': apkFile.path},
      );
      if (result == true) return true;
    } on PlatformException catch (e) {
      debugPrint('[UpdateService] Instalador nativo falhou: ${e.code} ${e.message}');
    } catch (e) {
      debugPrint('[UpdateService] Instalador nativo falhou: $e');
    }
    // Fallback para builds que ainda não têm o canal nativo (ex.: 2.6.0).
    final opened = await OpenFilex.open(
      apkFile.path,
      type: 'application/vnd.android.package-archive',
    );
    return opened.type == ResultType.done;
  }

  /// `true` quando o sistema permite instalar APKs fora da Play Store.
  Future<bool> canRequestPackageInstalls() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _installChannel.invokeMethod<bool>(
            'canRequestPackageInstalls',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  /// Abre Settings > Instalar apps desconhecidos para este pacote.
  Future<bool> openInstallPermissionSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _installChannel.invokeMethod<bool>(
            'openInstallPermissionSettings',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> openReleasePage(String releaseUrl) async {
    if (releaseUrl.isEmpty) return false;
    final uri = Uri.tryParse(releaseUrl);
    if (uri == null) return false;
    // Evita dependência extra: o canal nativo já tem ACTION_VIEW disponível.
    try {
      return await _installChannel.invokeMethod<bool>(
            'openUrl',
            <String, Object?>{'url': uri.toString()},
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  static ({String? url, int? size})? _findApk(Map<String, dynamic> release) {
    final assets = release['assets'];
    if (assets is! List) return null;
    for (final asset in assets) {
      if (asset is Map<String, dynamic> && asset['name'] == apkAssetName) {
        final url = asset['browser_download_url'];
        final size = asset['size'];
        return (
          url: url is String ? url : null,
          size: size is int ? size : (size is num ? size.toInt() : null),
        );
      }
    }
    return null;
  }

  /// Extrai `2.7.1` de tags como `v2.7.1`, `release-2.7.1+foo`.
  static String? versionFromTag(String tag) {
    final match = RegExp(r'(\d+\.\d+(?:\.\d+)+)').firstMatch(tag);
    return match?.group(1);
  }

  /// Comparação semver simples: Retorna >0 quando [a] é mais novo que [b].
  static int compareVersions(String a, String b) {
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
  final String currentBuild;
  final String latestVersion;
  final String releaseTag;
  final String releaseName;
  final String releaseUrl;
  final String releaseNotes;
  final String? publishedAt;
  final String? apkUrl;
  final int? apkSize;
  final String? error;

  const UpdateCheckResult({
    required this.hasUpdate,
    required this.currentVersion,
    required this.currentBuild,
    required this.latestVersion,
    required this.releaseTag,
    required this.releaseName,
    required this.releaseUrl,
    this.releaseNotes = '',
    this.publishedAt,
    this.apkUrl,
    this.apkSize,
    this.error,
  });

  factory UpdateCheckResult.unknown({String? error}) => UpdateCheckResult(
        hasUpdate: false,
        currentVersion: '',
        currentBuild: '',
        latestVersion: '',
        releaseTag: '',
        releaseName: '',
        releaseUrl: '',
        error: error,
      );

  String get sizeLabel {
    final size = apkSize;
    if (size == null || size <= 0) return '';
    if (size >= 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / 1024).toStringAsFixed(0)} KB';
  }
}

class UpdateState {
  final int? lastCheckMs;
  final int? lastPromptMs;
  final String? dismissedVersion;
  final String? lastKnownVersion;

  const UpdateState({
    this.lastCheckMs,
    this.lastPromptMs,
    this.dismissedVersion,
    this.lastKnownVersion,
  });

  UpdateState copyWith({
    int? lastCheckMs,
    int? lastPromptMs,
    String? dismissedVersion,
    String? lastKnownVersion,
  }) {
    return UpdateState(
      lastCheckMs: lastCheckMs ?? this.lastCheckMs,
      lastPromptMs: lastPromptMs ?? this.lastPromptMs,
      dismissedVersion: dismissedVersion ?? this.dismissedVersion,
      lastKnownVersion: lastKnownVersion ?? this.lastKnownVersion,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'last_check_ms': lastCheckMs,
        'last_prompt_ms': lastPromptMs,
        'dismissed_version': dismissedVersion,
        'last_known_version': lastKnownVersion,
      };

  factory UpdateState.fromJson(Map<String, dynamic> json) => UpdateState(
        lastCheckMs: json['last_check_ms'] is int ? json['last_check_ms'] as int : null,
        lastPromptMs: json['last_prompt_ms'] is int ? json['last_prompt_ms'] as int : null,
        dismissedVersion: json['dismissed_version'] as String?,
        lastKnownVersion: json['last_known_version'] as String?,
      );
}
