import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../models/apkvision_port.dart';

/// Resultado de uma extração nativa.
class ArchiveExtractResult {
  const ArchiveExtractResult({
    required this.files,
    required this.bytes,
    required this.destDir,
    required this.cancelled,
    required this.sourceDeleted,
  });

  final int files;
  final int bytes;
  final String destDir;
  final bool cancelled;
  final bool sourceDeleted;

  bool get isEmpty => files == 0;
}

/// Extrai os pacotes de dados dos ports usando o descompactador nativo
/// (commons-compress): `.7z`, `.zip`, `.rar`, `.tar`, `.tar.gz`, `.tar.xz`.
///
/// `.iso`, `.rvz`, `.obb` e `.exe` não são arquivos compactados — para esses o
/// jogo lê o arquivo direto, sem extrair.
class ArchiveExtractService {
  ArchiveExtractService._();

  static const MethodChannel _channel =
      MethodChannel('org.loopgamer.libretro/methods');

  static const Set<String> extractableExtensions = {
    '7z',
    'zip',
    'rar',
    'tar',
    'gz',
    'tgz',
    'xz',
    'txz',
    'apks',
  };

  static bool canExtract(ApkVisionPortEntry entry) =>
      canExtractPath(entry.dataUrl ?? '');

  static bool canExtractPath(String path) {
    final lower = path.toLowerCase();
    if (lower.isEmpty) return false;
    final name = Uri.tryParse(lower)?.path ?? lower;
    for (final ext in extractableExtensions) {
      if (name.endsWith('.$ext')) return true;
    }
    return false;
  }

  /// Canal de progresso: emite a fração (0..1) e a entrada corrente.
  static final StreamController<ArchiveProgress> _progressController =
      StreamController<ArchiveProgress>.broadcast();

  static Stream<ArchiveProgress> get progress => _progressController.stream;

  static bool _handlerInstalled = false;

  static void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'archiveProgress') return null;
      final args = call.arguments;
      if (args is Map) {
        _progressController.add(
          ArchiveProgress(
            archivePath: args['path'] as String? ?? '',
            entry: args['entry'] as String? ?? '',
            files: (args['files'] as num?)?.toInt() ?? 0,
            bytes: (args['bytes'] as num?)?.toInt() ?? 0,
            totalBytes: (args['totalBytes'] as num?)?.toInt() ?? 0,
            fraction: (args['fraction'] as num?)?.toDouble() ?? 0,
          ),
        );
      }
      return null;
    });
  }

  /// Extrai [archive] para [destDir]. `deleteSource` apaga o pacote original
  /// ao terminar com sucesso — é o passo "extraiu, pode apagar o zip".
  static Future<ArchiveExtractResult> extract(
    File archive, {
    required Directory destDir,
    bool deleteSource = false,
  }) async {
    _installHandler();
    if (!await archive.exists()) {
      throw StateError('Arquivo não encontrado: ${archive.path}');
    }
    if (!canExtractPath(archive.path)) {
      throw StateError(
        'Formato não compactado (${_extensionOf(archive.path)}). '
        'Copie o arquivo para a pasta do jogo em vez de extrair.',
      );
    }
    if (!await destDir.exists()) {
      await destDir.create(recursive: true);
    }

    final res = await _channel.invokeMapMethod<String, dynamic>(
      'extractArchive',
      {
        'path': archive.path,
        'dest': destDir.path,
        'deleteSource': deleteSource,
      },
    );
    if (res == null) {
      throw StateError('O extraidor nativo não retornou resultado.');
    }
    return ArchiveExtractResult(
      files: (res['files'] as num?)?.toInt() ?? 0,
      bytes: (res['bytes'] as num?)?.toInt() ?? 0,
      destDir: res['dest'] as String? ?? destDir.path,
      cancelled: res['cancelled'] as bool? ?? false,
      sourceDeleted: res['sourceDeleted'] as bool? ?? false,
    );
  }

  static Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancelArchiveExtract');
    } catch (e) {
      debugPrint('[ArchiveExtractService] Falha ao cancelar: $e');
    }
  }

  /// Abre o gerenciador de arquivos na raiz do armazenamento interno.
  static Future<bool> openDocumentRoot() async {
    try {
      final ok = await _channel.invokeMethod<bool>('openDocumentRoot');
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } catch (e) {
      debugPrint('[ArchiveExtractService] Falha ao abrir arquivos: $e');
      return false;
    }
  }

  static String _extensionOf(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    return dot < 0 ? name : name.substring(dot + 1);
  }
}

class ArchiveProgress {
  const ArchiveProgress({
    required this.archivePath,
    required this.entry,
    required this.files,
    required this.bytes,
    required this.totalBytes,
    required this.fraction,
  });

  final String archivePath;
  final String entry;
  final int files;
  final int bytes;
  final int totalBytes;
  final double fraction;
}
