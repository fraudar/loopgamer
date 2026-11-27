import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/pc_port.dart';

enum PcPortDownloadState { idle, resolving, downloading, downloadingData, installing, done, error }

/// Asset de um release do GitHub.
class PcPortAsset {
  const PcPortAsset({required this.name, required this.size, required this.url});

  final String name;
  final int size;
  final String url;
}

/// Resolve e baixa APKs de ports de PC a partir do catálogo [PcPortCatalog].
class PcPortService {
  PcPortService._();

  /// Piso de sanidade para um APK real — evita instalar página de erro HTML
  /// salva com extensão `.apk` (CDN de release devolve 200 com corpo curto).
  static const int _minApkBytes = 512 * 1024;

  /// Tamanho mínimo para aceitar um pacote de dados como válido.
  static const int _minDataAssetBytes = 1024;

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

  /// Lista os assets do release mais recente de [entry].
  static Future<List<PcPortAsset>> listReleaseAssets(
    PcPortEntry entry,
  ) async {
    final repo = entry.githubRepo;
    if (repo == null) {
      throw StateError('Item ${entry.id} não possui repositório GitHub.');
    }
    final response = await _dio.get<String>(
      'https://api.github.com/repos/$repo/releases/latest',
    );
    if (response.statusCode != 200 || response.data == null) {
      throw StateError(
        'Falha ao consultar releases de $repo (HTTP ${response.statusCode}).',
      );
    }
    final json = jsonDecode(response.data!) as Map<String, dynamic>;
    final assets = json['assets'];
    if (assets is! List) {
      throw StateError('Release de $repo não possui assets.');
    }
    final result = <PcPortAsset>[];
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = asset['name'] as String? ?? '';
      final url = asset['browser_download_url'] as String? ?? '';
      if (name.isEmpty || url.isEmpty) continue;
      result.add(
        PcPortAsset(
          name: name,
          size: (asset['size'] as num?)?.toInt() ?? 0,
          url: url,
        ),
      );
    }
    return result;
  }

  /// Resolve a URL do APK de um item [PcPortSource.githubRelease] consultando
  /// o release mais recente do repositório no GitHub.
  ///
  /// Quando o release publica vários APKs, prefere `arm64-v8a`, depois
  /// `universal`, depois o primeiro que casar com prefixo/sufixo.
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

    final prefix = entry.apkAssetPrefix ?? '';
    final suffix = entry.apkAssetSuffix ?? '.apk';
    final assets = await listReleaseAssets(entry);
    final apks = assets
        .where((a) => a.name.startsWith(prefix) && a.name.endsWith(suffix))
        .toList(growable: false);

    if (apks.isEmpty) {
      throw StateError(
        'Nenhum APK compatível encontrado no release de ${entry.githubRepo} '
        '(prefixo "$prefix", sufixo "$suffix").',
      );
    }

    for (final token in const ['arm64-v8a', 'arm64', 'universal']) {
      for (final apk in apks) {
        if (apk.name.toLowerCase().contains(token)) return apk.url;
      }
    }
    return apks.first.url;
  }

  /// Pasta onde ficam APKs baixados e pacotes de dados extras.
  static Future<Directory> _portsRoot() async {
    final dir = await getApplicationDocumentsDirectory();
    final root = Directory('${dir.path}/pc_ports');
    if (!await root.exists()) await root.create(recursive: true);
    return root;
  }

  /// Baixa um arquivo com retomada por `Range` para o `.part` ao lado.
  ///
  /// Trata o caso em que o servidor ignora o `Range` e devolve `200` (aí o
  /// `.part` é truncado antes de escrever, senão o arquivo sairia corrompido).
  static Future<int> _downloadTo(
    File partial,
    String url, {
    void Function(int received, int total)? onProgress,
  }) async {
    var existing = await partial.exists() ? await partial.length() : 0;

    for (var attempt = 0; attempt < 2; attempt++) {
      final headers = <String, String>{'User-Agent': 'LoopGamer-App'};
      if (existing > 0) headers['Range'] = 'bytes=$existing-';

      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          receiveTimeout: const Duration(minutes: 30),
          validateStatus: (_) => true,
        ),
      );

      final status = response.statusCode ?? 0;
      if (status == 416 && attempt == 0 && existing > 0) {
        // `.part` maior que o arquivo remoto: descarta e tenta do zero.
        await partial.delete();
        existing = 0;
        continue;
      }
      if (status < 200 || status >= 300) {
        throw StateError('Servidor devolveu HTTP $status para $url');
      }

      final resumed = status == 206;
      if (!resumed) existing = 0;

      final contentLength =
          int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      final total = resumed && contentLength > 0 ? existing + contentLength
          : contentLength;

      final sink = partial.openWrite(
        mode: resumed ? FileMode.append : FileMode.write,
      );
      var received = existing;
      try {
        onProgress?.call(received, total);
        await for (final chunk in response.data!.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      final written = await partial.length();
      if (total > 0 && written != total) {
        // Mantém o `.part` para a próxima tentativa retomar.
        throw StateError(
          'Download incompleto: $written de $total bytes.',
        );
      }
      return written;
    }
    throw StateError('Falha ao baixar $url após retry.');
  }

  /// Baixa uma URL arbitrária para [partial] com retomada por `Range`.
  /// Usado pelos ports APKVision, cujos URLs não vêm da API do GitHub.
  static Future<int> downloadRawFile(
    File partial,
    String url, {
    void Function(int received, int total)? onProgress,
  }) {
    return _downloadTo(partial, url, onProgress: onProgress);
  }

  /// Baixa o APK e retorna o [File] pronto para instalação.
  static Future<File> downloadApk(
    PcPortEntry entry, {
    void Function(int received, int total)? onProgress,
  }) async {
    final apkUrl = await resolveApkUrl(entry);
    final root = await _portsRoot();
    final apkFile = File('${root.path}/${entry.id}.apk');
    final partial = File('${apkFile.path}.part');

    final length = await _downloadTo(partial, apkUrl, onProgress: onProgress);
    if (length < _minApkBytes) {
      await partial.delete();
      throw StateError('APK baixado é pequeno demais ($length bytes).');
    }
    if (await apkFile.exists()) await apkFile.delete();
    await partial.rename(apkFile.path);
    return apkFile;
  }

  /// Procura os assets em todos os releases recentes (o release mais novo de
  /// alguns ports publica só o APK; os pacotes de dados ficam em versões
  /// anteriores). Retorna todos os assets que casam com qualquer prefixo,
  /// deduplicados pelo nome, preservando a ordem dos releases.
  static Future<List<PcPortAsset>> _findAssetsAcrossReleases(
    String repo,
    List<String> prefixes,
  ) async {
    final response = await _dio.get<String>(
      'https://api.github.com/repos/$repo/releases?per_page=10',
    );
    if (response.statusCode != 200 || response.data == null) {
      throw StateError(
        'Falha ao consultar releases de $repo (HTTP ${response.statusCode}).',
      );
    }
    final json = jsonDecode(response.data!);
    if (json is! List) {
      throw StateError('Release de $repo não possui assets.');
    }
    final found = <String, PcPortAsset>{};
    for (final release in json) {
      if (release is! Map<String, dynamic>) continue;
      final assets = release['assets'];
      if (assets is! List) continue;
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String? ?? '';
        if (name.isEmpty || url.isEmpty) continue;
        if (!entryPrefixesMatch(prefixes, name)) continue;
        found.putIfAbsent(
          name,
          () => PcPortAsset(
            name: name,
            size: (asset['size'] as num?)?.toInt() ?? 0,
            url: url,
          ),
        );
      }
    }
    return found.values.toList(growable: false);
  }

  /// Nomes de asset vêm da API remota; nunca viram caminho direto.
  static String safeAssetName(String name) {
    final base = name.split(RegExp(r'[\\/]')).last;
    final clean = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    if (clean.isEmpty || clean == '.' || clean == '..') {
      throw StateError('Nome de asset inválido: $name');
    }
    return clean;
  }

  static bool entryPrefixesMatch(List<String> prefixes, String name) {
    for (final prefix in prefixes) {
      if (name.startsWith(prefix)) return true;
    }
    return false;
  }

  /// Baixa os pacotes de dados declarados em [PcPortEntry.extraAssetPrefixes]
  /// para `<docs>/pc_ports/<id>_data/`, preservando o nome original.
  ///
  /// Retorna a pasta de destino. Arquivos já completos são pulados, então
  /// chamar de novo retoma de onde parou sem re-baixar gigabytes.
  static Future<Directory> downloadExtraAssets(
    PcPortEntry entry, {
    void Function(int index, int count, String name, double? progress)?
        onProgress,
  }) async {
    if (entry.extraAssetPrefixes.isEmpty) {
      throw StateError('Item ${entry.id} não declara pacotes de dados extras.');
    }
    final root = await _portsRoot();
    final targetDir = Directory('${root.path}/${entry.id}_data');
    if (!await targetDir.exists()) await targetDir.create(recursive: true);

    final assets = await _findAssetsAcrossReleases(
      entry.githubRepo!,
      entry.extraAssetPrefixes,
    );
    final wanted = assets
        .where(
          (a) => entry.extraAssetPrefixes.any(a.name.startsWith),
        )
        .toList(growable: false);
    if (wanted.isEmpty) {
      throw StateError(
        'Release de ${entry.githubRepo} não publica os pacotes de dados '
        'esperados (${entry.extraAssetPrefixes.join(', ')}).',
      );
    }

    for (var i = 0; i < wanted.length; i++) {
      final asset = wanted[i];
      final outFile = File('${targetDir.path}/${safeAssetName(asset.name)}');
      final partial = File('${outFile.path}.part');

      final doneBytes = await outFile.exists() ? await outFile.length() : 0;
      final partialBytes = await partial.exists() ? await partial.length() : 0;
      final haveBytes = doneBytes > partialBytes ? doneBytes : partialBytes;

      if (asset.size > 0 && haveBytes >= asset.size) {
        if (doneBytes < asset.size && partialBytes >= asset.size) {
          await partial.rename(outFile.path);
        }
        onProgress?.call(i, wanted.length, asset.name, 1);
        continue;
      }
      if (doneBytes > 0 && (asset.size == 0 || doneBytes < asset.size)) {
        // Download anterior incompleto sem `.part`: reinicia este arquivo.
        await outFile.delete();
      }

      await _downloadTo(
        partial,
        asset.url,
        onProgress: (received, total) => onProgress?.call(
          i,
          wanted.length,
          asset.name,
          total > 0 ? (received / total).clamp(0, 1).toDouble() : null,
        ),
      );

      final length = await partial.length();
      if (length < _minDataAssetBytes ||
          (asset.size > 0 && length < asset.size)) {
        throw StateError(
          'Pacote ${asset.name} incompleto ($length de ${asset.size} bytes). '
          'Tente novamente para retomar.',
        );
      }
      if (await outFile.exists()) await outFile.delete();
      await partial.rename(outFile.path);
      onProgress?.call(i, wanted.length, asset.name, 1);
    }
    return targetDir;
  }

  /// Retorna o APK já baixado para [entry], ou `null` se não existir/estiver
  /// incompleto. Usado para oferecer "Instalar" em vez de re-baixar.
  static Future<File?> findDownloadedApk(PcPortEntry entry) async {
    final root = await _portsRoot();
    final file = File('${root.path}/${entry.id}.apk');
    if (!await file.exists()) return null;
    if (await file.length() < _minApkBytes) return null;
    return file;
  }

  /// Retorna a pasta de dados já baixada quando todos os pacotes declarados
  /// estão presentes e completos; caso contrário `null`.
  static Future<Directory?> findDownloadedData(PcPortEntry entry) async {
    if (entry.extraAssetPrefixes.isEmpty) return null;
    final root = await _portsRoot();
    final dir = Directory('${root.path}/${entry.id}_data');
    if (!await dir.exists()) return null;
    await for (final entity in dir.list()) {
      if (entity is File &&
          entry.extraAssetPrefixes.any(
            (prefix) => entity.uri.pathSegments.last.startsWith(prefix),
          )) {
        if (await entity.length() >= _minDataAssetBytes) return dir;
      }
    }
    return null;
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
