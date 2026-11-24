import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import '../models/emulation_game.dart';
import 'library_storage_service.dart';
import 'rom_download_service.dart';

/// Serviço de captura contínua de logs/erros em memória e disco, permitindo
/// gerar e salvar relatórios completos de diagnóstico pelos Ajustes.
class DiagnosticLogService {
  DiagnosticLogService._();

  static final DiagnosticLogService instance = DiagnosticLogService._();

  static const int _maxRingEntries = 600;
  static const int _maxDiskLogBytes = 256 * 1024;
  static const String _diskLogFileName = 'loopgamer_errors.log';

  final ListQueue<String> _ringBuffer = ListQueue<String>(_maxRingEntries);
  bool _hooksInstalled = false;
  bool _isRecording = false;
  Future<void> _diskWriteChain = Future<void>.value();

  List<String> get recentEntries => List.unmodifiable(_ringBuffer);

  void installGlobalHooks() {
    if (_hooksInstalled) return;
    _hooksInstalled = true;

    final previousDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.isNotEmpty) {
        final lower = message.toLowerCase();
        final level = (lower.contains('erro') ||
                lower.contains('falha') ||
                lower.contains('exception') ||
                lower.contains('out of memory') ||
                lower.contains('bad state'))
            ? 'ERROR'
            : lower.contains('aviso') || lower.contains('warn')
                ? 'WARN'
                : 'INFO';
        record(message, level: level, persistIfImportant: true);
      }
      previousDebugPrint(message, wrapWidth: wrapWidth);
    };

    final previousFlutterError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record(
        'FlutterError: ${details.exceptionAsString()}\n${details.stack ?? ''}',
        level: 'ERROR',
        persistIfImportant: true,
      );
      if (previousFlutterError != null) {
        previousFlutterError(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    final previousPlatformError = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record(
        'PlatformError: $error\n$stack',
        level: 'ERROR',
        persistIfImportant: true,
      );
      if (previousPlatformError != null) {
        return previousPlatformError(error, stack);
      }
      return false;
    };
  }

  void record(
    String message, {
    String level = 'INFO',
    bool persistIfImportant = false,
  }) {
    if (_isRecording) return;
    _isRecording = true;
    try {
      final now = DateTime.now().toIso8601String();
      final line = '[$now][$level] $message';
      if (_ringBuffer.length >= _maxRingEntries) {
        _ringBuffer.removeFirst();
      }
      _ringBuffer.addLast(line);

      if (persistIfImportant &&
          (level == 'ERROR' || level == 'WARN') &&
          !Platform.environment.containsKey('FLUTTER_TEST')) {
        _queueAppendDiskLog(line);
      }
    } finally {
      _isRecording = false;
    }
  }

  void _queueAppendDiskLog(String line) {
    _diskWriteChain = _diskWriteChain.then((_) async {
      try {
        final supportDir = await getApplicationSupportDirectory();
        final logFile = File('${supportDir.path}/$_diskLogFileName');
        if (await logFile.exists() && await logFile.length() > _maxDiskLogBytes) {
          final tail = await logFile.readAsString();
          final keep = tail.length > (_maxDiskLogBytes ~/ 2)
              ? tail.substring(tail.length - (_maxDiskLogBytes ~/ 2))
              : tail;
          await logFile.writeAsString(keep, flush: false);
        }
        await logFile.writeAsString(
          '$line\n',
          mode: FileMode.append,
          flush: false,
        );
      } catch (_) {}
    });
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    final mb = bytes / (1024 * 1024);
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(2)} GB';
  }

  Future<int> _measureEntity(FileSystemEntity entity) async {
    try {
      if (entity is File) {
        return await entity.length();
      }
      if (entity is Directory) {
        var sum = 0;
        await for (final child in entity.list(recursive: true, followLinks: false)) {
          if (child is File) {
            sum += await child.length();
          }
        }
        return sum;
      }
    } catch (_) {}
    return 0;
  }

  Future<String> generateReport({
    required AppStorageBreakdown storage,
    List<EmulationGame>? libraryGames,
    RomDownloadService? downloadService,
  }) async {
    await _diskWriteChain;
    final sb = StringBuffer();
    sb.writeln('=== RELATÓRIO DE ERROS & DIAGNÓSTICO - LOOPGAMER ===');
    sb.writeln('Gerado em: ${DateTime.now().toIso8601String()}');

    try {
      final info = await PackageInfo.fromPlatform();
      sb.writeln('App: ${info.appName} v${info.version} (+${info.buildNumber})');
      sb.writeln('Pacote: ${info.packageName}');
    } catch (_) {
      sb.writeln('App: LoopGamer');
    }

    sb.writeln(
      'Sistema: ${Platform.operatingSystem} ${Platform.operatingSystemVersion} (${Platform.numberOfProcessors} cores)',
    );
    sb.writeln();

    sb.writeln('--- ARMAZENAMENTO ---');
    sb.writeln('ROMs instaladas: ${_formatBytes(storage.readyRomsBytes)}');
    sb.writeln(
      'Downloads parciais (.part · ${storage.orphanPartCount}): ${_formatBytes(storage.partialDownloadsBytes)}',
    );
    sb.writeln(
      'Sistema/Cores/Drivers: ${_formatBytes(storage.systemAndCoresBytes)}',
    );
    sb.writeln('Firmware PS3: ${_formatBytes(storage.ps3FirmwareBytes)}');
    sb.writeln(
      'Saves (${_formatBytes(storage.savesBytes)}) + Capas (${_formatBytes(storage.coversBytes)})',
    );
    sb.writeln('Cache temporário: ${_formatBytes(storage.tempCacheBytes)}');
    sb.writeln('Total do App: ${_formatBytes(storage.totalAppBytes)}');
    sb.writeln();

    final statuses = downloadService?.activeStatuses ?? const {};
    sb.writeln('--- DOWNLOADS ATIVOS / ERROS NA SESSÃO (${statuses.length}) ---');
    if (statuses.isEmpty) {
      sb.writeln('(nenhum status ativo registrado)');
    } else {
      for (final entry in statuses.entries) {
        final st = entry.value;
        sb.writeln(
          '• #${entry.key}: state=${st.state.name} progress=${(st.progress * 100).toStringAsFixed(1)}% '
          'bytes=${_formatBytes(st.downloadedBytes)}/${_formatBytes(st.totalBytes)}'
          '${st.speedLabel != null ? " [${st.speedLabel}]" : ""}'
          '${st.errorMessage != null ? " ERRO: ${st.errorMessage}" : ""}'
          '${st.warningMessage != null ? " AVISO: ${st.warningMessage}" : ""}',
        );
      }
    }
    sb.writeln();

    final loadedLibrary =
        libraryGames ?? await LibraryStorageService().loadPersistedLibrary();
    sb.writeln('--- BIBLIOTECA INSTALADA (${loadedLibrary.length}) ---');
    for (final g in loadedLibrary) {
      final path = g.localRomPath ?? '';
      var exists = false;
      if (path.isNotEmpty) {
        exists = await File(path).exists() || await Directory(path).exists();
      }
      sb.writeln(
        '• #${g.igdbId} "${g.name}" (${g.platformSlug}) '
        'size=${g.formattedSize} exists=$exists path=$path',
      );
    }
    sb.writeln();

    try {
      final supportDir = await getApplicationSupportDirectory();
      final romsDir = Directory('${supportDir.path}/roms');
      sb.writeln('--- ARQUIVOS EM ${romsDir.path} ---');
      if (await romsDir.exists()) {
        final entities = await romsDir.list(followLinks: false).toList();
        entities.sort(
          (a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
        );
        for (final entity in entities) {
          final size = await _measureEntity(entity);
          final kind = entity is Directory
              ? 'DIR '
              : entity is File
                  ? 'FILE'
                  : 'LINK';
          final name = entity.path.replaceAll('\\', '/').split('/').last;
          sb.writeln('• [$kind] $name (${_formatBytes(size)})');
        }
      } else {
        sb.writeln('(pasta roms ainda não existe)');
      }
      sb.writeln();

      final logFile = File('${supportDir.path}/$_diskLogFileName');
      if (await logFile.exists()) {
        sb.writeln('--- HISTÓRICO DE ERROS PERSISTIDOS ($_diskLogFileName) ---');
        final content = await logFile.readAsString();
        final lines = content.split('\n');
        final tail = lines.length > 200 ? lines.sublist(lines.length - 200) : lines;
        for (final l in tail) {
          if (l.trim().isNotEmpty) sb.writeln(l);
        }
        sb.writeln();
      }
    } catch (e) {
      sb.writeln('Erro ao inspecionar diretório de suporte: $e');
    }

    sb.writeln('--- LOGS RECENTES DA SESSÃO (${_ringBuffer.length}) ---');
    for (final line in _ringBuffer) {
      sb.writeln(line);
    }
    return sb.toString();
  }

  Future<({File file, String reportText})> saveReportToDisk({
    required AppStorageBreakdown storage,
    List<EmulationGame>? libraryGames,
    RomDownloadService? downloadService,
  }) async {
    final reportText = await generateReport(
      storage: storage,
      libraryGames: libraryGames,
      downloadService: downloadService,
    );

    final now = DateTime.now();
    final stamp =
        '${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final fileName = 'loopgamer_relatorio_erros_$stamp.txt';

    final candidates = <Directory>[];
    if (Platform.isAndroid && !Platform.environment.containsKey('FLUTTER_TEST')) {
      candidates.add(Directory('/storage/emulated/0/Download'));
      try {
        final ext = await getExternalStorageDirectory();
        if (ext != null) candidates.add(ext);
      } catch (_) {}
    }
    try {
      candidates.add(await getApplicationDocumentsDirectory());
    } catch (_) {}
    try {
      candidates.add(await getApplicationSupportDirectory());
    } catch (_) {}

    File? savedFile;
    Object? lastError;
    for (final dir in candidates) {
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        final target = File('${dir.path}/$fileName');
        await target.writeAsString(reportText, flush: true);
        savedFile = target;
        break;
      } catch (e) {
        lastError = e;
      }
    }

    if (savedFile == null) {
      throw StateError(
        'Não foi possível gravar o relatório de erros: $lastError',
      );
    }

    record('Relatório de diagnóstico salvo em ${savedFile.path}');
    return (file: savedFile, reportText: reportText);
  }
}
