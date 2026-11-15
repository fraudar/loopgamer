import 'dart:async';
import 'dart:io';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/emulation_game.dart';

enum RomActionState {
  notDownloaded,
  downloading,
  paused,
  readyToPlay,
}

class RomDownloadStatus {
  const RomDownloadStatus({
    this.state = RomActionState.notDownloaded,
    this.progress = 0.0,
    this.localPath,
    this.errorMessage,
    this.speedLabel,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
  });

  final RomActionState state;
  final double progress;
  final String? localPath;
  final String? errorMessage;
  final String? speedLabel;
  final int downloadedBytes;
  final int totalBytes;

  String get buttonLabel {
    switch (state) {
      case RomActionState.notDownloaded:
        return 'Baixar Jogo';
      case RomActionState.downloading:
        final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
        return speedLabel != null && speedLabel!.isNotEmpty
            ? 'Pausar ($pct% • $speedLabel)'
            : 'Pausar ($pct%)';
      case RomActionState.paused:
        final pct = (progress * 100).clamp(0, 100).toStringAsFixed(0);
        return 'Continuar ($pct%)';
      case RomActionState.readyToPlay:
        return 'Jogar Agora';
    }
  }
}

class RomDownloadEvent {
  const RomDownloadEvent({
    required this.game,
    required this.status,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
}

class RomDownloadService {
  RomDownloadService({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                followRedirects: true,
                maxRedirects: 8,
                connectTimeout: const Duration(seconds: 25),
                receiveTimeout: null,
                headers: const {
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14; LoopGamer) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Mobile Safari/537.36',
                  'Accept': '*/*',
                  'Connection': 'keep-alive',
                },
              ),
            );

  final Dio _dio;
  final Map<int, CancelToken> _cancelTokens = {};
  final Map<int, EmulationGame> _activeGames = {};
  final Map<int, RomDownloadStatus> _activeStatuses = {};
  final Map<int, bool> _pauseRequested = {};
  final StreamController<RomDownloadEvent> _eventsController =
      StreamController<RomDownloadEvent>.broadcast();

  /// Stream global de eventos de download em segundo plano
  Stream<RomDownloadEvent> get downloadEvents => _eventsController.stream;

  Map<int, RomDownloadStatus> get activeStatuses =>
      Map.unmodifiable(_activeStatuses);

  static const Set<String> _romInnerExtensions = {
    '.gba',
    '.gbc',
    '.gb',
    '.sfc',
    '.smc',
    '.nes',
    '.nds',
    '.z64',
    '.n64',
    '.v64',
    '.md',
    '.gen',
    '.smd',
    '.gg',
    '.sms',
    '.pce',
    '.rvz',
    '.gcz',
    '.wbfs',
    '.gcm',
    '.3ds',
    '.cci',
    '.cxi',
    '.pkg',
    '.isz',
    '.nsp',
    '.xci',
    '.nsz',
    '.xcz',
    '.nro',
    '.nca',
    '.iso',
    '.chd',
    '.cso',
    '.pbp',
    '.bin',
    '.zip',
    '.7z',
  };

  /// Mirrors diretos verificados de alta velocidade do Archive.org para os principais títulos
  static const Map<int, String> _verifiedDirectUrls = {
    // Sony PSP
    19560:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Ghost%20of%20Sparta%20%28USA%29%20%28PSN%29.iso',
    549:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Chains%20of%20Olympus%20%28USA%29%20%28PSN%29.iso',
    1265: 'https://archive.org/download/tekken-6_202309/Tekken%206.iso',
    899:
        'https://archive.org/download/grand-theft-auto-vice-city-stories-europe-psp_202603_ver2/Grand%20Theft%20Auto%20-%20Vice%20City%20Stories%20%28Europe%29.iso',
    // Super Nintendo (SNES)
    1068:
        'https://archive.org/download/super-mario-world-usa_202505/Super%20Mario%20World%20%28USA%29.sfc',
    1180:
        'https://archive.org/download/chrono-trigger-usa-en-fr_202508/Chrono%20Trigger%20%28USA%29%20%28En%2CFr%29.sfc',
    // Game Boy Advance (GBA)
    1329:
        'https://archive.org/download/pokemon-emerald-version-usa-europe_202605/Pokemon%20-%20Emerald%20Version%20%28USA%2C%20Europe%29.gba',
    // Sony PlayStation (PS1)
    1016:
        'https://archive.org/download/castlevania-symphony-of-the-night-usa_202601/Castlevania%20Symphony%20Of%20The%20Night%20%28USA%29.chd',
    // NeoGeo MVS (FBNeo)
    55101:
        'https://archive.org/download/neo-geo-mvs-romset/mslug.zip',
    55102:
        'https://archive.org/download/neo-geo-mvs-romset/mslug3.zip',
    55103:
        'https://archive.org/download/neo-geo-mvs-romset/kof98.zip',
    55104:
        'https://archive.org/download/neo-geo-mvs-romset/garou.zip',
  };

  Future<Directory> _romsDirectory() async {
    final baseDir = await getApplicationSupportDirectory();
    final romDir = Directory('${baseDir.path}/roms');
    if (!await romDir.exists()) {
      await romDir.create(recursive: true);
    }
    return romDir;
  }

  /// Verifica se a ROM já foi baixada/extraída no armazenamento local.
  Future<String?> resolveExistingRomPath(int igdbId) async {
    try {
      final dir = await _romsDirectory();
      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (await arcadeDir.exists()) {
        final arcadeFiles = await arcadeDir.list().toList();
        for (final entity in arcadeFiles) {
          if (entity is File &&
              !entity.path.endsWith('.part') &&
              !entity.path.toLowerCase().endsWith('/neogeo.zip')) {
            final len = await entity.length();
            if (len >= 32 * 1024) {
              return entity.path;
            } else {
              try {
                await entity.delete();
              } catch (_) {}
            }
          }
        }
      }
      final files = await dir.list().toList();
      for (final entity in files) {
        if (entity is File &&
            entity.path.contains('rom_${igdbId}_') &&
            !entity.path.endsWith('.part')) {
          final len = await entity.length();
          // Arquivos com menos de 32KB são resíduos de falha de download anterior: remove e força novo download
          if (len >= 32 * 1024) {
            return entity.path;
          } else {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}
    return null;
  }

  /// Retorna o caminho do arquivo de download parcial (.part) se existir.
  Future<File?> _resolvePartFile(int igdbId) async {
    final dir = await _romsDirectory();
    final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
    if (await arcadeDir.exists()) {
      final arcadeFiles = await arcadeDir.list().toList();
      for (final entity in arcadeFiles) {
        if (entity is File && entity.path.endsWith('.part')) {
          return entity;
        }
      }
    }
    final files = await dir.list().toList();
    for (final entity in files) {
      if (entity is File &&
          entity.path.contains('rom_${igdbId}_') &&
          entity.path.endsWith('.part')) {
        return entity;
      }
    }
    return null;
  }

  /// Calcula espaço total ocupado pelas ROMs baixadas.
  Future<int> getDownloadedRomsTotalBytes() async {
    try {
      final dir = await _romsDirectory();
      final files = await dir.list(recursive: true).toList();
      int total = 0;
      for (final entity in files) {
        if (entity is File &&
            !entity.path.endsWith('.part') &&
            !entity.path.toLowerCase().endsWith('/neogeo.zip')) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Remove o arquivo ROM baixado do disco para liberar espaço.
  Future<void> deleteRomFilesForGame(int igdbId, {String? localPath}) async {
    cancelDownload(igdbId);
    _activeStatuses.remove(igdbId);
    _activeGames.remove(igdbId);
    _pauseRequested.remove(igdbId);

    if (localPath != null) {
      final f = File(localPath);
      if (await f.exists()) {
        try {
          await f.delete();
        } catch (_) {}
      }
    }

    try {
      final dir = await _romsDirectory();
      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (await arcadeDir.exists()) {
        await arcadeDir.delete(recursive: true);
      }
      final files = await dir.list().toList();
      for (final entity in files) {
        if (entity is File && entity.path.contains('rom_${igdbId}_')) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  void _emit(EmulationGame game, RomDownloadStatus status) {
    _activeGames[game.igdbId] = game;
    _activeStatuses[game.igdbId] = status;
    if (!_eventsController.isClosed) {
      _eventsController.add(RomDownloadEvent(game: game, status: status));
    }
  }

  /// Inicia ou continua download em segundo plano com suporte a pausa e HTTP Range
  Future<String?> startBackgroundDownload({
    required EmulationGame game,
    void Function(RomDownloadStatus status)? onStatus,
  }) async {
    final curStatus = _activeStatuses[game.igdbId];
    if (curStatus?.state == RomActionState.downloading) {
      return null;
    }

    if (game.directRomUrl.startsWith('external://')) {
      const st = RomDownloadStatus(
        state: RomActionState.notDownloaded,
        errorMessage:
            'Use "Arquivo Local" (.nsp/.xci/.nsz/.nro) ou configure seu servidor RomM nos Ajustes.',
      );
      _emit(game, st);
      onStatus?.call(st);
      return null;
    }

    _pauseRequested[game.igdbId] = false;

    void notify(RomDownloadStatus st) {
      _emit(game, st);
      onStatus?.call(st);
    }

    notify(
      RomDownloadStatus(
        state: RomActionState.downloading,
        progress: curStatus?.progress ?? 0.01,
        downloadedBytes: curStatus?.downloadedBytes ?? 0,
        totalBytes: curStatus?.totalBytes ?? game.estimatedSizeBytes,
        speedLabel: 'Conectando...',
      ),
    );

    try {
      final savedPath = await _executeResilientDownload(
        game: game,
        notify: notify,
      );

      if (savedPath != null) {
        final ready = RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: savedPath,
        );
        notify(ready);
        return savedPath;
      }
      return null;
    } catch (e) {
      if (_pauseRequested[game.igdbId] == true) {
        final partFile = await _resolvePartFile(game.igdbId);
        final downloaded =
            (partFile != null && await partFile.exists()) ? await partFile.length() : 0;
        final total = game.estimatedSizeBytes > 0
            ? game.estimatedSizeBytes
            : (downloaded * 2);
        final p = total > 0 ? (downloaded / total).clamp(0.0, 0.99) : 0.0;
        notify(
          RomDownloadStatus(
            state: RomActionState.paused,
            progress: p,
            downloadedBytes: downloaded,
            totalBytes: total,
            speedLabel: 'Pausado',
          ),
        );
        return null;
      }

      notify(
        const RomDownloadStatus(
          state: RomActionState.notDownloaded,
          errorMessage: 'Falha no download: Servidor offline ou ROM protegida.',
        ),
      );
      return null;
    }
  }

  /// Pausa um download ativo preservando o arquivo .part para continuação posterior
  void pauseDownload(int igdbId) {
    _pauseRequested[igdbId] = true;
    _cancelTokens[igdbId]?.cancel('PAUSED_BY_USER');
    _cancelTokens.remove(igdbId);
    final game = _activeGames[igdbId];
    final cur = _activeStatuses[igdbId];
    if (game != null && cur != null) {
      _emit(
        game,
        RomDownloadStatus(
          state: RomActionState.paused,
          progress: cur.progress,
          downloadedBytes: cur.downloadedBytes,
          totalBytes: cur.totalBytes,
          speedLabel: 'Pausado',
        ),
      );
    }
  }

  /// Cancela e exclui arquivos parciais
  void cancelDownload(int igdbId) {
    _pauseRequested.remove(igdbId);
    _cancelTokens[igdbId]?.cancel('CANCELLED_BY_USER');
    _cancelTokens.remove(igdbId);
    final game = _activeGames[igdbId];
    if (game != null) {
      _emit(
        game,
        const RomDownloadStatus(
          state: RomActionState.notDownloaded,
          errorMessage: 'Download cancelado.',
        ),
      );
    }
    _cleanPartFiles(igdbId);
  }

  Future<void> _cleanPartFiles(int igdbId) async {
    try {
      final dir = await _romsDirectory();
      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (await arcadeDir.exists()) {
        final arcadeFiles = await arcadeDir.list().toList();
        for (final f in arcadeFiles) {
          if (f is File && f.path.endsWith('.part')) {
            await f.delete();
          }
        }
      }
      final files = await dir.list().toList();
      for (final f in files) {
        if (f is File &&
            f.path.contains('rom_${igdbId}_') &&
            f.path.endsWith('.part')) {
          await f.delete();
        }
      }
    } catch (_) {}
  }

  /// Executa o download real com HTTP Range e medição de bytes/segundo
  Future<String?> _executeResilientDownload({
    required EmulationGame game,
    required void Function(RomDownloadStatus status) notify,
  }) async {
    final cancelToken = CancelToken();
    _cancelTokens[game.igdbId] = cancelToken;

    // 1. Resolução prioritária de URL funcional:
    //    Primeiro checa directUrls verificadas (PSP e clássicos), depois directRomUrl, depois Archive.org
    String targetUrl = game.directRomUrl.trim();
    if (_verifiedDirectUrls.containsKey(game.igdbId)) {
      targetUrl = _verifiedDirectUrls[game.igdbId]!;
    } else if (targetUrl.startsWith('retroapi://') || !targetUrl.startsWith('http')) {
      final mirror = await _findUnlockedArchiveMirror(
        game: game,
        cancelToken: cancelToken,
      );
      if (mirror != null) {
        targetUrl = mirror;
      }
    }

    if (!targetUrl.startsWith('http')) {
      throw StateError('Nenhum mirror disponível para esta ROM.');
    }

    // 2. Extrai extensão real da URL final do arquivo para evitar conflito de formato
    String realExt = '';
    final urlPath = Uri.parse(targetUrl).path.toLowerCase();
    for (final ext in _romInnerExtensions) {
      if (urlPath.endsWith(ext)) {
        realExt = ext;
        break;
      }
    }
    if (realExt.isEmpty) {
      realExt = _defaultExtensionForPlatform(game.platformSlug, targetUrl);
    }

    final dir = await _romsDirectory();
    final isArcade = _isArcadePlatform(game.platformSlug);
    String finalDestinationPath;
    if (isArcade) {
      final arcadeDir = Directory('${dir.path}/arcade_${game.igdbId}');
      if (!await arcadeDir.exists()) {
        await arcadeDir.create(recursive: true);
      }
      final canonicalName = _canonicalArcadeFileName(
        preferredSource: game.directRomUrl,
        fallbackUrl: targetUrl,
        fallbackExt: realExt,
      );
      finalDestinationPath = '${arcadeDir.path}/$canonicalName';
    } else {
      final safeFileName =
          game.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      finalDestinationPath =
          '${dir.path}/rom_${game.igdbId}_$safeFileName$realExt';
    }
    final partFilePath = '$finalDestinationPath.part';
    final partFile = File(partFilePath);

    int existingBytes = 0;
    if (await partFile.exists()) {
      existingBytes = await partFile.length();
    }

    // Janela deslizante de medição de velocidade real de transferência (bytes/s)
    final rollingWindow = <_SpeedSample>[];
    int currentBytes = existingBytes;
    int expectedTotalBytes = game.estimatedSizeBytes > existingBytes
        ? game.estimatedSizeBytes
        : existingBytes;

    try {
      final headers = <String, String>{};
      if (existingBytes > 0) {
        headers['Range'] = 'bytes=$existingBytes-';
      }

      final response = await _dio.get<ResponseBody>(
        targetUrl,
        cancelToken: cancelToken,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
          validateStatus: (s) => (s != null && (s >= 200 && s < 300)),
        ),
      );

      final statusCode = response.statusCode ?? 200;
      final isRangeAccepted = statusCode == 206;

      final contentLengthHeader = response.headers.value('content-length');
      if (contentLengthHeader != null) {
        final cl = int.tryParse(contentLengthHeader) ?? 0;
        if (cl > 0) {
          expectedTotalBytes = isRangeAccepted ? existingBytes + cl : cl;
        }
      }

      final sink = partFile.openWrite(
        mode: isRangeAccepted ? FileMode.append : FileMode.write,
      );

      final stream = response.data?.stream;
      if (stream == null) {
        await sink.close();
        throw StateError('Resposta de stream vazia.');
      }

      DateTime lastUiUpdate = DateTime.now();

      await for (final chunk in stream) {
        sink.add(chunk);
        currentBytes += chunk.length;

        final now = DateTime.now();
        rollingWindow.add(_SpeedSample(now, chunk.length));
        // Remove amostras mais antigas que 1.5s
        rollingWindow.removeWhere(
            (s) => now.difference(s.time).inMilliseconds > 1500);

        if (now.difference(lastUiUpdate).inMilliseconds >= 250) {
          lastUiUpdate = now;
          final totalWindowBytes =
              rollingWindow.fold<int>(0, (acc, s) => acc + s.bytes);
          final windowDurationMs = rollingWindow.isEmpty
              ? 1000
              : now
                  .difference(rollingWindow.first.time)
                  .inMilliseconds
                  .clamp(100, 2000);
          final bytesPerSec =
              (totalWindowBytes * 1000.0) / windowDurationMs;

          final speedLabel = _formatSpeed(bytesPerSec);
          final progress = expectedTotalBytes > 0
              ? (currentBytes / expectedTotalBytes).clamp(0.01, 0.99)
              : 0.5;

          notify(
            RomDownloadStatus(
              state: RomActionState.downloading,
              progress: progress,
              downloadedBytes: currentBytes,
              totalBytes: expectedTotalBytes,
              speedLabel: speedLabel,
            ),
          );
        }
      }

      await sink.flush();
      await sink.close();

      // Download concluído com sucesso: renomeia .part para o nome final
      if (await partFile.exists() && await partFile.length() > 512) {
        final finalFile = await partFile.rename(finalDestinationPath);
        if (!isArcade && finalDestinationPath.toLowerCase().endsWith('.zip')) {
          final extracted = await _extractRomFromZipIfPossible(
            igdbId: game.igdbId,
            zipPath: finalFile.path,
            romsDir: dir,
          );
          if (extracted != null) return extracted;
        }
        return finalFile.path;
      }
      throw StateError('Arquivo baixado corrompido ou incompleto.');
    } finally {
      _cancelTokens.remove(game.igdbId);
    }
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '0 KB/s';
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }

  Future<String?> _findUnlockedArchiveMirror({
    required EmulationGame game,
    required CancelToken cancelToken,
  }) async {
    String? expectedArchiveFile;
    final rawDirect = game.directRomUrl.trim();
    if (rawDirect.isNotEmpty) {
      final clean = rawDirect.split('?').first.split('#').first;
      final last = clean.split('/').last.toLowerCase();
      if (last.endsWith('.zip') || last.endsWith('.7z')) {
        expectedArchiveFile = last;
      }
    }

    // 1. Tenta acervo curado por plataforma (1G1R / NeoGeo MVS / FBNeo)
    final collections = _collectionsForPlatform(game.platformSlug);
    for (final collection in collections) {
      try {
        final metaRes = await _dio
            .get<Map<String, dynamic>>(
              'https://archive.org/metadata/$collection',
              cancelToken: cancelToken,
            )
            .timeout(const Duration(seconds: 8));

        final files = (metaRes.data?['files'] as List<dynamic>?) ?? const [];
        if (expectedArchiveFile != null) {
          final targetLower = expectedArchiveFile;
          final targetStem = targetLower.replaceAll(RegExp(r'\.(zip|7z)$'), '');
          for (final f in files.whereType<Map<String, dynamic>>()) {
            final name = (f['name'] as String?) ?? '';
            final lower = name.toLowerCase();
            final isPrivate = f['private'] == 'true' || f['private'] == true;
            if (isPrivate) continue;
            if (lower == targetLower ||
                lower.endsWith('/$targetLower') ||
                lower == '$targetStem.zip' ||
                lower == '$targetStem.7z' ||
                lower.endsWith('/$targetStem.7z')) {
              return 'https://archive.org/download/$collection/${name.split('/').map(Uri.encodeComponent).join('/')}';
            }
          }
        }

        final searchName = game.canonicalNoIntroName.isNotEmpty
            ? game.canonicalNoIntroName
            : game.name;
        final cleanSearch =
            searchName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
        final prefix =
            cleanSearch.substring(0, cleanSearch.length.clamp(0, 10));

        for (final f in files.whereType<Map<String, dynamic>>()) {
          final name = (f['name'] as String?) ?? '';
          final lower = name.toLowerCase();
          final isPrivate = f['private'] == 'true' || f['private'] == true;
          if (isPrivate) continue;

          final cleanFileName = lower.replaceAll(RegExp(r'[^a-z0-9]'), '');
          if (prefix.isNotEmpty && cleanFileName.contains(prefix)) {
            if (_romInnerExtensions.any(lower.endsWith)) {
              return 'https://archive.org/download/$collection/${name.split('/').map(Uri.encodeComponent).join('/')}';
            }
          }
        }
      } catch (_) {}
    }

    // Evita baixar arquivos aleatórios incompatíveis (ex.: PC/Dreamcast) em romsets arcade
    if (_isArcadePlatform(game.platformSlug)) {
      return null;
    }

    // 2. Busca dinâmica inteligente no Archive.org
    try {
      final searchQueries = [
        if (game.canonicalNoIntroName.isNotEmpty) game.canonicalNoIntroName,
        '${game.name} ${game.platformName}',
        game.name,
      ];

      for (final query in searchQueries) {
        final clean = query
            .replaceAll(RegExp(r'\([^)]*\)'), '')
            .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ')
            .trim();
        if (clean.isEmpty) continue;

        final res = await _dio
            .get<Map<String, dynamic>>(
              'https://archive.org/advancedsearch.php',
              cancelToken: cancelToken,
              queryParameters: {
                'q':
                    'title:("$clean") AND mediatype:(software) AND NOT access-restricted-item:true',
                'fl[]': ['identifier'],
                'rows': '5',
                'page': '1',
                'output': 'json',
              },
            )
            .timeout(const Duration(seconds: 10));

        final docs = (res.data?['response'] as Map<String, dynamic>?)?['docs']
                as List<dynamic>? ??
            const [];
        final identifiers = docs
            .whereType<Map<String, dynamic>>()
            .map((d) => d['identifier'] as String?)
            .whereType<String>()
            .toList();

        for (final identifier in identifiers) {
          try {
            final metaRes = await _dio
                .get<Map<String, dynamic>>(
                  'https://archive.org/metadata/$identifier',
                  cancelToken: cancelToken,
                )
                .timeout(const Duration(seconds: 6));

            final isRestricted =
                metaRes.data?['metadata']?['access-restricted-item'] == 'true';
            if (isRestricted) continue;

            final files =
                (metaRes.data?['files'] as List<dynamic>?) ?? const [];
            for (final f in files.whereType<Map<String, dynamic>>()) {
              final name = (f['name'] as String?) ?? '';
              final lower = name.toLowerCase();
              final isPrivate = f['private'] == 'true' || f['private'] == true;
              if (isPrivate) continue;
              if (_romInnerExtensions.any(lower.endsWith)) {
                return 'https://archive.org/download/$identifier/${Uri.encodeComponent(name)}';
              }
            }
          } catch (_) {}
        }
      }
    } catch (_) {}
    return null;
  }

  List<String> _collectionsForPlatform(String platformSlug) {
    switch (platformSlug.toLowerCase()) {
      case 'gba':
        return const [
          'retrocollection-1g1r-nintendo-gba-games',
          'retrocollection-1g1r-nintendo-gba-other',
        ];
      case 'snes':
        return const ['retrocollection-1g1r-nintendo-snes'];
      case 'nes':
        return const ['retrocollection-1g1r-nintendo-nes'];
      case 'n64':
        return const ['retrocollection-1g1r-nintendo-n64-games'];
      case 'nds':
        return const [
          'retrocollection-1g1r-nintendo-nds-games-1',
          'retrocollection-1g1r-nintendo-nds-games-2',
        ];
      case 'gbc':
        return const ['retrocollection-1g1r-nintendo-gbc'];
      case 'gb':
        return const ['retrocollection-1g1r-nintendo-gb'];
      case 'md':
      case 'genesis':
        return const ['retrocollection-1g1r-sega-genesis'];
      case 'gamegear':
        return const ['retrocollection-1g1r-sega-game-gear'];
      case 'mastersystem':
        return const ['retrocollection-1g1r-sega-master-system'];
      case 'neogeo':
        return const ['neo-geo-mvs-romset', 'svcpcb.7z'];
      case 'cps1':
      case 'cps2':
      case 'mame':
        return const ['svcpcb.7z'];
      default:
        return const [];
    }
  }

  String _defaultExtensionForPlatform(String platformSlug, String url) {
    final lowerUrl = url.toLowerCase();
    for (final ext in _romInnerExtensions) {
      if (lowerUrl.endsWith(ext)) return ext;
    }
    switch (platformSlug.toLowerCase()) {
      case 'gamecube':
        return '.rvz';
      case 'wii':
        return '.wbfs';
      case '3ds':
        return '.3ds';
      case 'ps2':
      case 'ps3':
        return '.iso';
      case 'switch':
        return '.nsp';
      case 'snes':
        return '.sfc';
      case 'nes':
        return '.nes';
      case 'n64':
        return '.z64';
      case 'nds':
        return '.nds';
      case 'md':
      case 'genesis':
        return '.md';
      case 'gamegear':
        return '.gg';
      case 'mastersystem':
        return '.sms';
      case 'pce':
        return '.pce';
      case 'gbc':
        return '.gbc';
      case 'gb':
        return '.gb';
      case 'ps1':
      case 'psx':
      case 'psp':
      case 'dreamcast':
      case 'saturn':
        return '.chd';
      case 'neogeo':
      case 'cps1':
      case 'cps2':
      case 'mame':
        return '.zip';
      default:
        return '.gba';
    }
  }

  bool _isArcadePlatform(String platformSlug) {
    switch (platformSlug.toLowerCase()) {
      case 'neogeo':
      case 'cps1':
      case 'cps2':
      case 'mame':
        return true;
      default:
        return false;
    }
  }

  String _canonicalArcadeFileName({
    required String preferredSource,
    required String fallbackUrl,
    required String fallbackExt,
  }) {
    for (final candidate in [preferredSource, fallbackUrl]) {
      final raw = candidate.trim();
      if (raw.isEmpty) continue;
      final clean = raw.split('?').first.split('#').first;
      final slashIdx = clean.lastIndexOf('/');
      final last = slashIdx >= 0 ? clean.substring(slashIdx + 1) : clean;
      final decoded = Uri.decodeComponent(last);
      final lower = decoded.toLowerCase();
      if (lower.endsWith('.zip') || lower.endsWith('.7z')) {
        final safe = decoded.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        if (safe.isNotEmpty) return safe;
      }
    }
    return 'romset$fallbackExt';
  }

  Future<String?> _extractRomFromZipIfPossible({
    required int igdbId,
    required String zipPath,
    required Directory romsDir,
  }) async {
    try {
      final zipFile = File(zipPath);
      final bytes = await zipFile.readAsBytes();
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final entry in archive) {
        if (!entry.isFile) continue;
        final lower = entry.name.toLowerCase();
        final matchesRom = _romInnerExtensions.any(lower.endsWith);
        if (matchesRom) {
          final safeInnerName =
              entry.name.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
          final outPath = '${romsDir.path}/rom_${igdbId}_$safeInnerName';
          final data = entry.content as List<int>;
          await File(outPath).writeAsBytes(data, flush: true);
          await zipFile.delete();
          return outPath;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Permite importar uma ROM do armazenamento local via file_picker.
  Future<String?> importRomFromDevice(
    int igdbId, {
    String? platformSlug,
    String? preferredZipName,
  }) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
    );

    final pickedPath = result?.files.single.path;
    if (pickedPath == null) return null;

    final sourceFile = File(pickedPath);
    if (!await sourceFile.exists()) return null;

    final dir = await _romsDirectory();
    final safeName = result!.files.single.name
        .replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (platformSlug != null && _isArcadePlatform(platformSlug)) {
      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (!await arcadeDir.exists()) {
        await arcadeDir.create(recursive: true);
      }
      final lowerPicked = safeName.toLowerCase();
      final looksLikeShortSet =
          RegExp(r'^[a-z0-9_]{1,12}\.(zip|7z)$').hasMatch(lowerPicked);
      final targetName = (!looksLikeShortSet &&
              preferredZipName != null &&
              preferredZipName.trim().isNotEmpty)
          ? _canonicalArcadeFileName(
              preferredSource: preferredZipName,
              fallbackUrl: safeName,
              fallbackExt: '.zip',
            )
          : safeName;
      final targetPath = '${arcadeDir.path}/$targetName';
      await sourceFile.copy(targetPath);
      return targetPath;
    }
    final targetPath = '${dir.path}/rom_${igdbId}_$safeName';
    await sourceFile.copy(targetPath);
    return targetPath;
  }
}

class _SpeedSample {
  const _SpeedSample(this.time, this.bytes);
  final DateTime time;
  final int bytes;
}
