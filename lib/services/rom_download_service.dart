import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:io' as io show ZLibCodec;
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive_io.dart';
// ignore: implementation_imports
import 'package:archive/src/lzma/lzma_decoder.dart';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/emulation_game.dart';
import 'emulator_service.dart';
import 'library_storage_service.dart';
import 'rom_platform_detector.dart';

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
    this.warningMessage,
    this.crcVerified,
    this.isQueued = false,
    this.queuePosition = 0,
  });

  final RomActionState state;
  final double progress;
  final String? localPath;
  final String? errorMessage;
  final String? speedLabel;
  final int downloadedBytes;
  final int totalBytes;
  final String? warningMessage;
  final bool? crcVerified;
  final bool isQueued;
  final int queuePosition;

  RomDownloadStatus copyWith({
    RomActionState? state,
    double? progress,
    String? localPath,
    String? errorMessage,
    String? speedLabel,
    int? downloadedBytes,
    int? totalBytes,
    String? warningMessage,
    bool? crcVerified,
    bool? isQueued,
    int? queuePosition,
  }) {
    return RomDownloadStatus(
      state: state ?? this.state,
      progress: progress ?? this.progress,
      localPath: localPath ?? this.localPath,
      errorMessage: errorMessage ?? this.errorMessage,
      speedLabel: speedLabel ?? this.speedLabel,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      warningMessage: warningMessage ?? this.warningMessage,
      crcVerified: crcVerified ?? this.crcVerified,
      isQueued: isQueued ?? this.isQueued,
      queuePosition: queuePosition ?? this.queuePosition,
    );
  }

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

class AppStorageBreakdown {
  const AppStorageBreakdown({
    this.readyRomsBytes = 0,
    this.partialDownloadsBytes = 0,
    this.systemAndCoresBytes = 0,
    this.savesAndCoversBytes = 0,
    this.savesBytes = 0,
    this.coversBytes = 0,
    this.tempCacheBytes = 0,
    this.ps3FirmwareBytes = 0,
    this.orphanPartCount = 0,
  });

  final int readyRomsBytes;
  final int partialDownloadsBytes;
  final int systemAndCoresBytes;
  final int savesAndCoversBytes;
  final int savesBytes;
  final int coversBytes;
  final int tempCacheBytes;
  final int ps3FirmwareBytes;
  final int orphanPartCount;

  int get totalAppBytes =>
      readyRomsBytes +
      partialDownloadsBytes +
      systemAndCoresBytes +
      savesAndCoversBytes +
      tempCacheBytes +
      ps3FirmwareBytes;
}

class RomDownloadEvent {
  const RomDownloadEvent({
    required this.game,
    required this.status,
  });

  final EmulationGame game;
  final RomDownloadStatus status;
}

class Ps3DumpValidationResult {
  const Ps3DumpValidationResult({
    required this.isValid,
    this.resolvedRomPath,
    this.errorMessage,
    this.gameTitle,
    this.titleId,
    this.dumpFormat,
  });

  final bool isValid;
  final String? resolvedRomPath;
  final String? errorMessage;
  final String? gameTitle;
  final String? titleId;
  final String? dumpFormat;
}

class _NonRetryableDownloadException implements Exception {
  const _NonRetryableDownloadException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Sinaliza que o download paralelo não é viável para este arquivo/servidor e
/// que o fluxo deve continuar pelo download de stream único (que possui retry
/// e retome próprios).
class _ParallelUnavailableException implements Exception {
  const _ParallelUnavailableException();
}

class _QueuedDownloadEntry {
  _QueuedDownloadEntry({
    required this.game,
    required this.cancelToken,
    required this.slotCompleter,
    required this.notify,
    required this.progress,
    required this.downloadedBytes,
    required this.totalBytes,
  });

  final EmulationGame game;
  final CancelToken cancelToken;
  final Completer<bool> slotCompleter;
  final void Function(RomDownloadStatus status) notify;
  final double progress;
  final int downloadedBytes;
  final int totalBytes;
}

class RomDownloadService {
  RomDownloadService({Dio? dio})
      : _ownsDio = dio == null,
        _dio = dio ??
            Dio(
              BaseOptions(
                followRedirects: true,
                maxRedirects: 8,
                connectTimeout: const Duration(seconds: 25),
                receiveTimeout: defaultReceiveTimeout,
                headers: const {
                  'User-Agent':
                      'Mozilla/5.0 (Linux; Android 14; LoopGamer) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Mobile Safari/537.36',
                  'Accept': '*/*',
                  'Connection': 'keep-alive',
                },
              ),
            );

  static const Duration defaultReceiveTimeout = Duration(seconds: 90);
  static const int maxRetryAttempts = 6;
  static const int maxConcurrentDownloads = 2;

  /// Limiares do download multi-conexão (HTTP Range em paralelo).
  ///
  /// Abaixo de [minParallelTotalBytes] o ganho não compensa o custo extra de
  /// conexões; cada conexão recebe no mínimo [minParallelChunkBytes].
  /// Mutáveis apenas para os testes ajustarem o limiar sem gerar arquivos
  /// gigantes em memória.
  @visibleForTesting
  static int maxParallelChunks = 4;

  @visibleForTesting
  static int minParallelChunkBytes = 8 * 1024 * 1024;

  @visibleForTesting
  static int minParallelTotalBytes = 32 * 1024 * 1024;

  static const List<int> _retryBackoffSeconds = [2, 4, 8, 15, 25];

  final bool _ownsDio;
  final Dio _dio;
  final Map<int, CancelToken> _cancelTokens = {};
  final Map<int, int> _operationSeq = {};
  final Map<int, EmulationGame> _activeGames = {};
  final Map<int, RomDownloadStatus> _activeStatuses = {};
  final Map<int, bool> _pauseRequested = {};
  final Map<int, EmulationGame> _networkInterruptedGames = {};
  final Set<Completer<void>> _networkResumeWaiters = {};
  bool _restoredPendingDownloadsFromDisk = false;
  final Queue<_QueuedDownloadEntry> _pendingQueue =
      Queue<_QueuedDownloadEntry>();
  int _activeDownloadsCount = 0;
  bool _notificationPermissionRequested = false;
  DateTime? _lastNotificationSyncAt;
  int _completedNotificationCount = 0;
  int _failedNotificationCount = 0;
  final StreamController<RomDownloadEvent> _eventsController =
      StreamController<RomDownloadEvent>.broadcast();
  bool _isDisposed = false;
  Future<void> _pendingManifestWrite = Future.value();

  /// S serializa read-modify-write do manifesto para não perder entradas
  /// quando vários downloads são enfileirados no mesmo tick.
  Future<void> _serializeManifestWrite(Future<void> Function() action) {
    final previous = _pendingManifestWrite;
    final gate = Completer<void>();
    _pendingManifestWrite = gate.future;
    return previous.whenComplete(() async {
      try {
        await action();
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    });
  }

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
    '.sfb',
    '.sfo',
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
    428:
        'https://archive.org/download/retrocollection-1g1r-nintendo-snes/Games/Chrono%20Trigger%20%28USA%29.sfc',
    // Game Boy Advance (GBA)
    1515:
        'https://archive.org/download/pokemon-emerald-version-usa-europe_202605/Pokemon%20-%20Emerald%20Version%20%28USA%2C%20Europe%29.gba',
    1126:
        'https://archive.org/download/retrocollection-1g1r-nintendo-gba-games/Castlevania%20-%20Aria%20of%20Sorrow%20%28USA%29.gba',
    // Sony PlayStation (PS1)
    1120:
        'https://archive.org/download/2024-sony-playstation-usa-hearto-1g1r-collection/2024-sony-playstation-usa-hearto-1g1r-collection/Sony%20-%20Playstation%20-%20USA/Castlevania%20-%20Symphony%20of%20the%20Night%20%28USA%29.zip',
    1184:
        'https://archive.org/download/ps1lollo/Crash%20Bandicoot%202%20-%20Cortex%20Strikes%20Back%20%28Europe%29%20%28En%2CFr%2CDe%2CEs%2CIt%29.chd',
    // NeoGeo MVS (FBNeo)
    55101:
        'https://archive.org/download/neo-geo-mvs-romset/mslug.zip',
    55102:
        'https://archive.org/download/neo-geo-mvs-romset/mslug3.zip',
    55103:
        'https://archive.org/download/neo-geo-mvs-romset/kof98.zip',
    55104:
        'https://archive.org/download/neo-geo-mvs-romset/garou.zip',
    // Capcom CPS1 / CPS2 (FBNeo 1.0.0.03 Parent non-merged)
    55201:
        'https://archive.org/download/fbneo-parent/fbneo_1_0_0_3_Parent/Parent%20games/cps2/sfa3.zip',
    55202:
        'https://archive.org/download/fbneo-parent/fbneo_1_0_0_3_Parent/Parent%20games/cps1/dino.zip',
    55301:
        'https://archive.org/download/fbneo-parent/fbneo_1_0_0_3_Parent/Parent%20games/cps2/mvsc.zip',
  };

  /// Conjunto oficial de romsets parent CPS1 do FBNeo v1.0.0.03.
  static const Set<String> _fbneoCps1Parents = {
    '1941',
    '3wonders',
    'captcomm',
    'cawing',
    'dino',
    'dynwar',
    'ffight',
    'forgottn',
    'ghouls',
    'knights',
    'kod',
    'mbombrd',
    'megaman',
    'mercs',
    'msword',
    'mtwins',
    'nemo',
    'pang3',
    'pnickj',
    'punisher',
    'sf2',
    'sf2ce',
    'sf2hf',
    'slammast',
    'strider',
    'unsquad',
    'varth',
    'willow',
    'wof',
  };

  /// Conjunto oficial de romsets parent CPS2 do FBNeo v1.0.0.03.
  static const Set<String> _fbneoCps2Parents = {
    '1944',
    '19xx',
    'armwar',
    'avsp',
    'batcir',
    'csclub',
    'cybots',
    'ddsom',
    'ddtod',
    'dimahoo',
    'dstlk',
    'ecofghtr',
    'gigawing',
    'hsf2',
    'megaman2',
    'mmatrix',
    'mpang',
    'msh',
    'mshvsf',
    'mvsc',
    'nwarr',
    'progear',
    'pzloop2',
    'ringdest',
    'sfa',
    'sfa2',
    'sfa3',
    'sfz2al',
    'sgemf',
    'spf2t',
    'ssf2',
    'ssf2t',
    'vhunt2',
    'vsav',
    'vsav2',
    'xmcota',
    'xmvsf',
  };

  /// Mapa de prefixos/clones comuns do RetroAPI/MAME para seus parents FBNeo.
  static const Map<String, String> _fbneoCloneToParent = {
    'sfa3u': 'sfa3',
    'sfa3ur1': 'sfa3',
    'sfa3b': 'sfa3',
    'sfa3h': 'sfa3',
    'sfa3hr1': 'sfa3',
    'sfa3r1': 'sfa3',
    'sfz3j': 'sfa3',
    'sfz3jr1': 'sfa3',
    'sfz3a': 'sfa3',
    'sfa2u': 'sfa2',
    'sfa2ur1': 'sfa2',
    'sfz2j': 'sfa2',
    'sfau': 'sfa',
    'sfaur1': 'sfa',
    'sfzj': 'sfa',
    'sfz2alj': 'sfz2al',
    'mvscu': 'mvsc',
    'mvscur1': 'mvsc',
    'mvscj': 'mvsc',
    'mvscjr1': 'mvsc',
    'mvsca': 'mvsc',
    'mvscar1': 'mvsc',
    'mvsch': 'mvsc',
    'mvscb': 'mvsc',
    'mvscr1': 'mvsc',
    'mvscjsing': 'mvsc',
    'xmvsfu': 'xmvsf',
    'xmvsfur1': 'xmvsf',
    'xmvsfj': 'xmvsf',
    'xmvsfa': 'xmvsf',
    'xmvsfh': 'xmvsf',
    'xmvsfb': 'xmvsf',
    'xmvsfr1': 'xmvsf',
    'xmcotau': 'xmcota',
    'xmcotaj': 'xmcota',
    'xmcotaa': 'xmcota',
    'xmcotah': 'xmcota',
    'mshu': 'msh',
    'mshj': 'msh',
    'msha': 'msh',
    'mshh': 'msh',
    'mshb': 'msh',
    'mshvsfu': 'mshvsf',
    'mshvsfj': 'mshvsf',
    'vsavu': 'vsav',
    'vsavj': 'vsav',
    'vsava': 'vsav',
    'vsavh': 'vsav',
    'vsav2d': 'vsav2',
    'dstlku': 'dstlk',
    'dstlkj': 'dstlk',
    'dstlka': 'dstlk',
    'vampj': 'dstlk',
    'ssf2tu': 'ssf2t',
    'ssf2tur1': 'ssf2t',
    'ssf2ta': 'ssf2t',
    'ssf2xj': 'ssf2t',
    'ssf2u': 'ssf2',
    'ssf2j': 'ssf2',
    'dinou': 'dino',
    'dinoj': 'dino',
    'dinoh': 'dino',
    'captcommu': 'captcomm',
    'captcomu': 'captcomm',
    'captcommj': 'captcomm',
    'captcomj': 'captcomm',
    'captcommr1': 'captcomm',
    'ffightu': 'ffight',
    'ffightu1': 'ffight',
    'ffightua': 'ffight',
    'ffightub': 'ffight',
    'ffightj': 'ffight',
    'ffightj1': 'ffight',
    'ffightj2': 'ffight',
    'ffightj3': 'ffight',
    'ffighta': 'ffight',
    'punisheru': 'punisher',
    'punishru': 'punisher',
    'punisherj': 'punisher',
    'punishrj': 'punisher',
    'punisherh': 'punisher',
    'sf2ceu': 'sf2ce',
    'sf2ceua': 'sf2ce',
    'sf2ceub': 'sf2ce',
    'sf2ceuc': 'sf2ce',
    'sf2cej': 'sf2ce',
    'sf2cea': 'sf2ce',
    'sf2u': 'sf2',
    'sf2ua': 'sf2',
    'sf2ub': 'sf2',
    'sf2j': 'sf2',
    'sf2hfu': 'sf2hf',
    'sf2hfj': 'sf2hf',
    'knightsu': 'knights',
    'knightsj': 'knights',
    'kodu': 'kod',
    'kodj': 'kod',
    'wofu': 'wof',
    'wofj': 'wof',
    'wofa': 'wof',
    'avspu': 'avsp',
    'avspj': 'avsp',
    'avspa': 'avsp',
    'ddsomu': 'ddsom',
    'ddsomj': 'ddsom',
    'ddsoma': 'ddsom',
    'ddtodu': 'ddtod',
    'ddtodj': 'ddtod',
    'ddtoda': 'ddtod',
    'batcirj': 'batcir',
    'batcira': 'batcir',
    'cybotsu': 'cybots',
    'cybotsj': 'cybots',
    'armwaru': 'armwar',
    'armwarj': 'armwar',
    'progearj': 'progear',
    'progeara': 'progear',
    'gigawingu': 'gigawing',
    'gigawingj': 'gigawing',
    'strideru': 'strider',
    'striderj': 'strider',
    'ghoulsu': 'ghouls',
    'ghoulsj': 'ghouls',
    '19xxu': '19xx',
    '19xxj': '19xx',
    '1944u': '1944',
    '1944j': '1944',
    '1941u': '1941',
    '1941j': '1941',
    'willowu': 'willow',
    'willowj': 'willow',
  };

  /// Resolve um stem/arquivo de ROM arcade (`sfa3ur1.zip`, `sfa3`, etc.) para o
  /// parent canônico do FBNeo (`parentStem`) e sua placa (`cps1` ou `cps2`), quando aplicável.
  static ({String parentStem, String platformSlug})? resolveCanonicalFbneoParent(
    String rawStemOrFile, {
    String? gameTitle,
  }) {
    var clean = rawStemOrFile.trim().toLowerCase();
    final slash = clean.lastIndexOf('/');
    if (slash >= 0) clean = clean.substring(slash + 1);
    clean = clean.replaceAll(RegExp(r'\.(zip|7z|key)$'), '').trim();

    if (clean.isNotEmpty) {
      if (_fbneoCps2Parents.contains(clean)) {
        return (parentStem: clean, platformSlug: 'cps2');
      }
      if (_fbneoCps1Parents.contains(clean)) {
        return (parentStem: clean, platformSlug: 'cps1');
      }
      final mapped = _fbneoCloneToParent[clean];
      if (mapped != null) {
        final slug = _fbneoCps2Parents.contains(mapped) ? 'cps2' : 'cps1';
        return (parentStem: mapped, platformSlug: slug);
      }
      // Match por prefixo de parent quando o clone segue padrão `<parent><suffix>`
      for (final p in _fbneoCps2Parents) {
        if (clean.startsWith(p) &&
            clean.length > p.length &&
            RegExp(r'^[a-z0-9]{1,5}$').hasMatch(clean.substring(p.length))) {
          return (parentStem: p, platformSlug: 'cps2');
        }
      }
      for (final p in _fbneoCps1Parents) {
        if (clean.startsWith(p) &&
            clean.length > p.length &&
            RegExp(r'^[a-z0-9]{1,5}$').hasMatch(clean.substring(p.length))) {
          return (parentStem: p, platformSlug: 'cps1');
        }
      }
    }

    if (gameTitle != null && gameTitle.trim().isNotEmpty) {
      final t = EmulationGame.normalizeSearchText(gameTitle);
      if (t.contains('street fighter alpha 3')) {
        return (parentStem: 'sfa3', platformSlug: 'cps2');
      }
      if (t.contains('street fighter alpha 2')) {
        return (parentStem: 'sfa2', platformSlug: 'cps2');
      }
      if (t.contains('marvel vs capcom')) {
        return (parentStem: 'mvsc', platformSlug: 'cps2');
      }
      if (t.contains('x men vs street fighter')) {
        return (parentStem: 'xmvsf', platformSlug: 'cps2');
      }
      if (t.contains('cadillacs and dinosaurs')) {
        return (parentStem: 'dino', platformSlug: 'cps1');
      }
      if (t.contains('captain commando')) {
        return (parentStem: 'captcomm', platformSlug: 'cps1');
      }
      if (t.contains('final fight')) {
        return (parentStem: 'ffight', platformSlug: 'cps1');
      }
      if (t.contains('the punisher')) {
        return (parentStem: 'punisher', platformSlug: 'cps1');
      }
    }
    return null;
  }

  /// Tamanho mínimo razoável (bytes) para rejeitar scans de manual, patches, updates e demos pequenas.
  static int minBytesForPlatform(String platformSlug) {
    switch (platformSlug.toLowerCase()) {
      case 'ps2':
      case 'ps3':
      case 'gamecube':
      case 'wii':
        return 16 * 1024 * 1024; // 16 MB
      case 'ps1':
      case 'psx':
      case 'psp':
      case 'dreamcast':
      case 'saturn':
        return 8 * 1024 * 1024; // 8 MB
      case '3ds':
        return 4 * 1024 * 1024; // 4 MB
      case 'n64':
        return 1024 * 1024; // 1 MB
      case 'nds':
        return 512 * 1024; // 512 KB
      case 'gba':
        return 128 * 1024; // 128 KB
      case 'snes':
      case 'md':
      case 'genesis':
      case 'neogeo':
      case 'cps1':
      case 'cps2':
      case 'mame':
        return 64 * 1024; // 64 KB
      default:
        return 8 * 1024; // 8 KB (NES/GB/GBC/GG/SMS/PCE)
    }
  }

  static List<String> allowedExtensionsForPlatform(String platformSlug) {
    switch (platformSlug.toLowerCase()) {
      case 'gba':
        return const ['.gba', '.zip'];
      case 'gbc':
        return const ['.gbc', '.zip'];
      case 'gb':
        return const ['.gb', '.zip'];
      case 'snes':
        return const ['.sfc', '.smc', '.zip'];
      case 'nes':
        return const ['.nes', '.zip'];
      case 'nds':
        return const ['.nds', '.zip'];
      case 'n64':
        return const ['.z64', '.n64', '.v64', '.zip'];
      case 'md':
      case 'genesis':
        return const ['.md', '.gen', '.smd', '.bin', '.zip'];
      case 'gamegear':
        return const ['.gg', '.zip'];
      case 'mastersystem':
        return const ['.sms', '.zip'];
      case 'pce':
        return const ['.pce', '.zip'];
      case 'ps1':
      case 'psx':
        return const ['.chd', '.pbp', '.iso', '.zip'];
      case 'psp':
        return const ['.chd', '.iso', '.cso', '.pbp', '.zip'];
      case 'ps2':
        return const ['.chd', '.iso', '.cso', '.zip'];
      case 'ps3':
        return const ['.iso', '.pkg', '.bin', '.zip', '.7z'];
      case 'gamecube':
        return const ['.rvz', '.iso', '.gcz', '.gcm', '.zip'];
      case 'wii':
        return const ['.rvz', '.wbfs', '.iso', '.gcz', '.zip'];
      case '3ds':
        return const ['.3ds', '.cci', '.cxi', '.zip'];
      case 'dreamcast':
      case 'saturn':
        return const ['.chd', '.zip'];
      case 'neogeo':
      case 'cps1':
      case 'cps2':
      case 'mame':
        return const ['.zip', '.7z'];
      default:
        return _romInnerExtensions.toList();
    }
  }

  /// Indica se o título/identificador representa demo, update, DLC, trilha sonora
  /// ou build de outra plataforma (Android/PC) que não é o jogo completo de console.
  static bool isNonFullGameRelease(
    String candidate, {
    String gameTitle = '',
    bool rejectBetaAndProto = true,
  }) {
    final lower = candidate.toLowerCase();
    final base = lower.split('/').last;
    final titleLower = gameTitle.toLowerCase();

    final nonGameReleasePattern = RegExp(
      rejectBetaAndProto
          ? r'(?:^|[^a-z0-9])(demo|trial|kiosk|taikenban|preview|sample|proto|prototype|beta|updates?|dlc|map\s*pack|costume\s*pack|season\s*pass|soundtrack|ost|android|windows|win32|pc\s*version|pc\s*port|macos|linux|romset|fullset|1g1r)(?:$|[^a-z0-9])'
          : r'(?:^|[^a-z0-9])(demo|trial|kiosk|taikenban|updates?|dlc|map\s*pack|costume\s*pack|season\s*pass|soundtrack|ost|android|windows|win32|pc\s*version|pc\s*port|macos|linux)(?:$|[^a-z0-9])',
    );
    final match = nonGameReleasePattern.firstMatch(lower);
    if (match != null) {
      final token = match.group(1) ?? '';
      if (token.isNotEmpty && !titleLower.contains(token)) {
        return true;
      }
    }

    // Updates / DLC PS3 em PKG (ex: UP0101-NPUB31372_00-...-A0101-V0100-PE.pkg)
    if (RegExp(r'^up\d{4}-[a-z0-9_-]+-pe\.pkg$').hasMatch(base) ||
        RegExp(r'-a01\d{2}-v0\d{2,}').hasMatch(base)) {
      return true;
    }

    // Pacotes Android por reverse-DNS (ex: jp.konami.epjCastlevania2)
    if (RegExp(r'^(?:com|jp|net|org)\.[a-z0-9_]+\.[a-z0-9_]+').hasMatch(base) ||
        RegExp(r'^(?:com|jp|net|org)\.[a-z0-9_]+\.[a-z0-9_]+')
            .hasMatch(lower.trim())) {
      return true;
    }

    return false;
  }

  static bool isJunkArchiveEntry(String fileName, {String gameTitle = ''}) {
    final lower = fileName.toLowerCase();
    final base = lower.split('/').last;
    if (base.startsWith('.')) return true;
    const junkSuffixes = [
      '_jp2.zip',
      '_images.zip',
      '_files.xml',
      '_meta.xml',
      '_meta.sqlite',
      '.pdf',
      '.txt',
      '.nfo',
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.mp3',
      '.flac',
      '.wav',
      '.ogg',
      '.sbi',
      '.xml',
      '.sqlite',
      '.torrent',
      '.md5',
      '.sha1',
      '.sfv',
      '.ips',
      '.bps',
      '.xdelta',
      '.apk',
      '.exe',
      '.msi',
      '.dmg',
      '.bat',
      '.sh',
    ];
    for (final s in junkSuffixes) {
      if (lower.endsWith(s)) return true;
    }
    final titleLower = gameTitle.toLowerCase();
    const junkKeywords = [
      'manual',
      'booklet',
      'soundtrack',
      'boxart',
      'box scan',
      'modpack',
      'trainer',
      'guide',
      'walkthrough',
      'magazine',
      'wallpaper',
      'artbook',
    ];
    for (final kw in junkKeywords) {
      if (lower.contains(kw) && !titleLower.contains(kw)) {
        return true;
      }
    }
    if (isNonFullGameRelease(
      fileName,
      gameTitle: gameTitle,
      rejectBetaAndProto: false,
    )) {
      return true;
    }
    return false;
  }

  static List<String>? _strictInnerExtensionsForPlatform(String? platformSlug) {
    final slug = platformSlug?.trim().toLowerCase();
    if (slug == null || slug.isEmpty) return null;
    switch (slug) {
      case 'wii':
        return const ['.rvz', '.wbfs', '.iso', '.gcz', '.gcm'];
      case 'gamecube':
        return const ['.rvz', '.iso', '.gcz', '.gcm'];
      case 'psp':
        return const ['.cso', '.chd', '.pbp', '.iso'];
      case 'ps2':
        return const ['.chd', '.iso', '.cso', '.cue', '.bin'];
      case 'ps1':
      case 'psx':
        return const ['.m3u', '.cue', '.chd', '.pbp', '.iso', '.bin', '.img'];
      case 'dreamcast':
        return const ['.chd', '.gdi', '.cdi', '.iso', '.cue', '.bin'];
      case 'saturn':
        return const ['.chd', '.cue', '.iso', '.bin'];
      case 'pce':
        return const ['.pce', '.chd', '.cue', '.iso', '.bin'];
      case '3ds':
        return const ['.3ds', '.cci', '.cxi'];
      case 'gba':
        return const ['.gba'];
      case 'gbc':
        return const ['.gbc'];
      case 'gb':
        return const ['.gb'];
      case 'snes':
        return const ['.sfc', '.smc'];
      case 'nes':
        return const ['.nes'];
      case 'nds':
        return const ['.nds'];
      case 'n64':
        return const ['.z64', '.n64', '.v64'];
      case 'md':
      case 'genesis':
        return const ['.md', '.gen', '.smd', '.bin'];
      case 'gamegear':
        return const ['.gg'];
      case 'mastersystem':
        return const ['.sms'];
      case 'switch':
        return const ['.nsp', '.xci', '.nsz', '.xcz', '.nro'];
      default:
        return null;
    }
  }

  static bool looksLikePcOrXboxExecutable(String filePath) {
    final lower = filePath.replaceAll('\\', '/').toLowerCase();
    final base = lower.split('/').last;
    return lower.endsWith('.exe') ||
        lower.endsWith('.msi') ||
        base == 'default.xbe' ||
        base == 'steam_api.dll' ||
        base == 'steam_api64.dll' ||
        base.startsWith('unityplayer.dll');
  }

  static String? pickPreferredExtractedRom(
    List<String> filePaths, {
    String? platformSlug,
  }) {
    final slugLower = platformSlug?.trim().toLowerCase();
    final containsPcExe = filePaths.any(looksLikePcOrXboxExecutable);

    if (slugLower == 'ps3') {
      String? ps3GameEboot;
      String? usrdirEboot;
      String? plainEboot;
      String? ps3Iso;
      String? ps3Pkg;
      for (final p in filePaths) {
        final norm = p.replaceAll('\\', '/').toLowerCase();
        if (norm.contains('__macosx')) continue;
        if (norm.endsWith('/ps3_game/usrdir/eboot.bin') ||
            norm == 'ps3_game/usrdir/eboot.bin') {
          ps3GameEboot ??= p;
        } else if (norm.endsWith('/usrdir/eboot.bin') ||
            norm == 'usrdir/eboot.bin') {
          usrdirEboot ??= p;
        } else if (norm.endsWith('/eboot.bin') || norm == 'eboot.bin') {
          plainEboot ??= p;
        } else if (norm.endsWith('.iso')) {
          ps3Iso ??= p;
        } else if (norm.endsWith('.pkg')) {
          ps3Pkg ??= p;
        }
      }
      final ps3Best =
          ps3GameEboot ?? usrdirEboot ?? plainEboot ?? ps3Iso ?? ps3Pkg;
      if (ps3Best != null) return ps3Best;
      // Pacotes de PC (.exe) frequentemente têm arquivos .bin internos (ex.: ALIVE.BIN).
      if (containsPcExe) return null;
      return null;
    }

    const priority = [
      '.m3u',
      '.cue',
      '.chd',
      '.pbp',
      '.iso',
      '.cso',
      '.gba',
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
      '.gbc',
      '.gb',
      '.rvz',
      '.wbfs',
      '.gcz',
      '.gcm',
      '.3ds',
      '.cci',
      '.cxi',
      '.pkg',
      '.bin',
    ];
    final strictAllowed = _strictInnerExtensionsForPlatform(slugLower);
    final allowedList = strictAllowed ?? priority;
    final validFiles = filePaths.where((p) {
      final lower = p.toLowerCase();
      if (lower.contains('__macosx') || lower.endsWith('.sbi')) return false;
      // Se o arquivo contém executável PC/Xbox (.exe/.xbe), nunca aceitar .bin solto como ROM
      if (containsPcExe && lower.endsWith('.bin')) return false;
      return allowedList.any(lower.endsWith);
    }).toList();
    if (validFiles.isEmpty) return null;

    validFiles.sort((a, b) {
      final al = a.toLowerCase();
      final bl = b.toLowerCase();
      int rank(String p) {
        final idx = allowedList.indexWhere(p.endsWith);
        return idx < 0 ? allowedList.length : idx;
      }

      final r = rank(al).compareTo(rank(bl));
      if (r != 0) return r;
      final aTrack1 = al.contains('track 1') || al.contains('track 01');
      final bTrack1 = bl.contains('track 1') || bl.contains('track 01');
      if (aTrack1 != bTrack1) return aTrack1 ? -1 : 1;
      return a.compareTo(b);
    });
    return validFiles.first;
  }

  Future<Directory> _romsDirectory() async {
    final baseDir = await getApplicationSupportDirectory();
    final romDir = Directory('${baseDir.path}/roms');
    if (!await romDir.exists()) {
      await romDir.create(recursive: true);
    }
    return romDir;
  }

  /// Verifica se a ROM já existe no armazenamento local sem apagar `.zip` válidos importados.
  /// Quando [knownLocalPath] aponta para uma ISO/ROM externa vinculada diretamente,
  /// valida o arquivo no local original sem exigir cópia dentro de `roms/`.
  /// Apenas ignora `.part` e limpa stubs inválidos (< 1 KB).
  Future<String?> resolveExistingRomPath(
    int igdbId, {
    String? knownLocalPath,
  }) async {
    const int minStubBytes = 1024;
    if (knownLocalPath != null && knownLocalPath.trim().isNotEmpty) {
      final candidatePath = knownLocalPath.trim();
      try {
        final candidate = File(candidatePath);
        if (await candidate.exists()) {
          final lower = candidatePath.toLowerCase();
          final isCueOrM3u = lower.endsWith('.cue') || lower.endsWith('.m3u');
          final len = await candidate.length();
          if (len >= minStubBytes || isCueOrM3u) {
            return candidatePath;
          }
        }
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Falha ao validar caminho conhecido ($igdbId): $e',
        );
      }
    }
    try {
      final dir = await _romsDirectory();
      final gameDir = Directory('${dir.path}/game_$igdbId');
      if (await gameDir.exists()) {
        final entities = await gameDir.list(recursive: true).toList();
        final filePaths = <String>[];
        for (final entity in entities) {
          if (entity is File &&
              !_isPartFileName(_basename(entity.path).toLowerCase())) {
            filePaths.add(entity.path);
          }
        }
        debugPrint(
          '[Resolve#$igdbId] candidatos=${filePaths.length}: '
          '${filePaths.map((p) => p.replaceAll('${dir.path}/', '')).take(20).join(" | ")}',
        );
        final picked = pickPreferredExtractedRom(filePaths);
        debugPrint('[Resolve#$igdbId] escolhido=$picked');
        if (picked != null) {
          final pickedFile = File(picked);
          final pickedLen = await pickedFile.length();
          final lower = picked.toLowerCase();
          final isCueOrM3u = lower.endsWith('.cue') || lower.endsWith('.m3u');
          if (pickedLen >= minStubBytes || isCueOrM3u) {
            return picked;
          }
        }
      }

      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (await arcadeDir.exists()) {
        final arcadeFiles = await arcadeDir.list().toList();
        for (final entity in arcadeFiles) {
          if (entity is File &&
              !_isPartFileName(_basename(entity.path).toLowerCase())) {
            final baseName = entity.path
                .split(Platform.pathSeparator)
                .last
                .toLowerCase();
            if (baseName == 'neogeo.zip' ||
                baseName == 'qsound.zip' ||
                baseName == 'qsound_hle.zip') {
              continue;
            }
            final len = await entity.length();
            if (len >= minStubBytes) {
              return entity.path;
            }
            try {
              await entity.delete();
            } catch (e) {
              debugPrint(
                '[RomDownloadService] Falha ao remover stub arcade: $e',
              );
            }
          }
        }
      }

      final files = await dir.list().toList();
      for (final entity in files) {
        if (entity is File &&
            entity.path.contains('rom_${igdbId}_') &&
            !_isPartFileName(_basename(entity.path).toLowerCase())) {
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('_jp2.zip')) {
            continue;
          }
          final len = await entity.length();
          if (len < minStubBytes) {
            try {
              await entity.delete();
            } catch (e) {
              debugPrint('[RomDownloadService] Falha ao remover stub ROM: $e');
            }
            continue;
          }
          return entity.path;
        }
      }
    } catch (e) {
      debugPrint(
        '[RomDownloadService] Erro ao resolver ROM existente ($igdbId): $e',
      );
    }
    return null;
  }

  /// Resolve em lote os caminhos das ROMs existentes em uma única varredura
  /// da pasta `roms/`, evitando dezenas de chamadas concorrentes de I/O durante buscas.
  Future<Map<int, String>> resolveExistingRomPathsBatch(
    Iterable<int> igdbIds,
  ) async {
    final targetIds = igdbIds.toSet();
    final result = <int, String>{};
    if (targetIds.isEmpty) return result;
    const int minStubBytes = 1024;

    // 1. Aproveita entradas já resolvidas em memória
    for (final id in targetIds) {
      final st = _activeStatuses[id];
      if (st?.state == RomActionState.readyToPlay &&
          st?.localPath != null &&
          st!.localPath!.trim().isNotEmpty) {
        result[id] = st.localPath!;
      }
    }
    if (result.length == targetIds.length) return result;

    try {
      final dir = await _romsDirectory();
      final entities = await dir.list(followLinks: false).toList();
      final romFilePrefix = RegExp(r'^rom_(-?\d+)_');
      final arcadeDirPrefix = RegExp(r'^arcade_(-?\d+)$');

      for (final entity in entities) {
        final name = _basename(entity.path);
        final lowerName = name.toLowerCase();
        if (entity is Directory) {
          final gm = _gameFolderRegex.firstMatch(name);
          if (gm != null) {
            final id = int.tryParse(gm.group(1)!);
            if (id != null &&
                targetIds.contains(id) &&
                !result.containsKey(id)) {
              final resolved = await resolveExistingRomPath(id);
              if (resolved != null) result[id] = resolved;
            }
            continue;
          }
          final am = arcadeDirPrefix.firstMatch(name);
          if (am != null) {
            final id = int.tryParse(am.group(1)!);
            if (id != null &&
                targetIds.contains(id) &&
                !result.containsKey(id)) {
              final resolved = await resolveExistingRomPath(id);
              if (resolved != null) result[id] = resolved;
            }
            continue;
          }
        } else if (entity is File &&
            !_isPartFileName(lowerName) &&
            !lowerName.endsWith('_jp2.zip')) {
          final rm = romFilePrefix.firstMatch(name);
          if (rm != null) {
            final id = int.tryParse(rm.group(1)!);
            if (id != null &&
                targetIds.contains(id) &&
                !result.containsKey(id)) {
              final len = await entity.length();
              if (len >= minStubBytes) {
                result[id] = entity.path;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[RomDownloadService] Falha em resolveExistingRomPathsBatch: $e');
    }
    return result;
  }

  /// Retorna o caminho do arquivo de download parcial (.part) se existir.
  Future<File?> _resolvePartFile(int igdbId) async {
    final dir = await _romsDirectory();
    final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
    if (await arcadeDir.exists()) {
      final arcadeFiles = await arcadeDir.list().toList();
      for (final entity in arcadeFiles) {
        if (entity is File && _isPartFileName(_basename(entity.path).toLowerCase())) {
          return entity;
        }
      }
    }
    final files = await dir.list().toList();
    for (final entity in files) {
      if (entity is File &&
          entity.path.contains('rom_${igdbId}_') &&
          _isPartFileName(_basename(entity.path).toLowerCase())) {
        return entity;
      }
    }
    return null;
  }

  static String _basename(String filePath) {
    final cleaned = filePath.replaceAll(RegExp(r'[/\\]+$'), '');
    if (cleaned.isEmpty) return filePath;
    final parts = cleaned.split(RegExp(r'[/\\]'));
    return parts.isEmpty ? cleaned : parts.last;
  }

  static Future<String> _uniquePathKey(FileSystemEntity entity) async {
    try {
      return await entity.resolveSymbolicLinks();
    } catch (_) {
      return entity.absolute.path.replaceAll('\\', '/');
    }
  }

  static final RegExp _gameFolderRegex = RegExp(r'^game_(-?\d+)$');
  static final RegExp _compressedExtRegex =
      RegExp(r'\.(zip|7z|rar)$', caseSensitive: false);

  static bool _isCompressedArchiveName(String lowerName) =>
      _compressedExtRegex.hasMatch(lowerName);

  static bool _isValidExtractedRomFileName(String lowerName, int byteLength) {
    if (byteLength <= 0) return false;
    if (_isPartFileName(lowerName) ||
        lowerName.contains('.tmp_') ||
        lowerName.endsWith('.tmp') ||
        _isCompressedArchiveName(lowerName)) {
      return false;
    }
    return !lowerName.endsWith('.cue') &&
        !lowerName.endsWith('.m3u') &&
        !lowerName.endsWith('.sbi') &&
        !lowerName.endsWith('.txt') &&
        !lowerName.endsWith('.nfo');
  }

  static int? _extractGameIdFromPath(String filePath) {
    final normalized = filePath.replaceAll('\\', '/');
    final dirMatch =
        RegExp(r'(?:^|/)(?:arcade|game)_(-?\d+)/').firstMatch(normalized);
    if (dirMatch != null) {
      return int.tryParse(dirMatch.group(1) ?? '');
    }
    final romMatch = RegExp(r'(?:^|/)rom_(-?\d+)_').firstMatch(normalized);
    if (romMatch != null) {
      return int.tryParse(romMatch.group(1) ?? '');
    }
    return null;
  }

  bool _isGameDownloadActiveOrPaused(int igdbId) {
    final status = _activeStatuses[igdbId];
    if (status?.state == RomActionState.downloading ||
        status?.state == RomActionState.paused) {
      return true;
    }
    if (_cancelTokens.containsKey(igdbId) ||
        _pauseRequested[igdbId] == true ||
        _pendingQueue.any((e) => e.game.igdbId == igdbId)) {
      return true;
    }
    return false;
  }

  bool _isActiveOrPausedPartFile(String filePath) {
    final igdbId = _extractGameIdFromPath(filePath);
    if (igdbId == null) return false;
    return _isGameDownloadActiveOrPaused(igdbId);
  }

  Future<Set<int>> _findExtractedGameIdsWithValidRom(Directory romsDir) async {
    final result = <int>{};
    try {
      if (!await romsDir.exists()) return result;
      await for (final entry in romsDir.list(followLinks: false)) {
        if (entry is! Directory) continue;
        final match = _gameFolderRegex.firstMatch(_basename(entry.path));
        if (match == null) continue;
        final igdbId = int.tryParse(match.group(1) ?? '');
        if (igdbId == null) continue;
        try {
          await for (final sub
              in entry.list(recursive: true, followLinks: false)) {
            if (sub is! File) continue;
            final baseLower = _basename(sub.path).toLowerCase();
            final len = await sub.length();
            if (_isValidExtractedRomFileName(baseLower, len)) {
              result.add(igdbId);
              break;
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
    return result;
  }

  bool _isDuplicateArchiveForExtractedGame({
    required String filePath,
    required String romsDirPath,
    required String baseLower,
    required Set<int> extractedGameIds,
  }) {
    if (extractedGameIds.isEmpty) return false;
    if (baseLower == 'neogeo.zip' || !_isCompressedArchiveName(baseLower)) {
      return false;
    }
    final normRoms = romsDirPath.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final normFile = filePath.replaceAll('\\', '/');
    if (!normFile.startsWith('$normRoms/')) return false;
    final rel = normFile.substring(normRoms.length + 1);

    int? igdbId;
    if (!rel.contains('/')) {
      final m = RegExp(r'^rom_(-?\d+)_').firstMatch(baseLower);
      if (m != null) {
        igdbId = int.tryParse(m.group(1) ?? '');
      }
    } else {
      final firstSegment = rel.split('/').first;
      final m = _gameFolderRegex.firstMatch(firstSegment);
      if (m != null) {
        igdbId = int.tryParse(m.group(1) ?? '');
      }
    }
    if (igdbId == null || !extractedGameIds.contains(igdbId)) return false;
    return !_isGameDownloadActiveOrPaused(igdbId);
  }

  Future<Directory?> _safeDir(Future<Directory> Function() getter) async {
    try {
      return await getter();
    } catch (_) {
      return null;
    }
  }

  Future<int> _sumDirUnique(
    Directory dir,
    Set<String> countedKeys, {
    bool Function(File file, String baseLower)? where,
  }) async {
    int total = 0;
    try {
      if (!await dir.exists()) return 0;
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final baseLower = _basename(entity.path).toLowerCase();
        if (where != null && !where(entity, baseLower)) continue;
        final key = await _uniquePathKey(entity);
        if (!countedKeys.add(key)) continue;
        try {
          total += await entity.length();
        } catch (_) {}
      }
    } catch (_) {}
    return total;
  }

  Future<int> _sumFileUnique(File file, Set<String> countedKeys) async {
    try {
      if (!await file.exists()) return 0;
      final key = await _uniquePathKey(file);
      if (!countedKeys.add(key)) return 0;
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  /// Calcula espaço total ocupado pelas ROMs baixadas.
  Future<int> getDownloadedRomsTotalBytes() async {
    try {
      final dir = await _romsDirectory();
      final files = await dir.list(recursive: true).toList();
      int total = 0;
      for (final entity in files) {
        if (entity is File &&
            !_isPartFileName(_basename(entity.path).toLowerCase()) &&
            _basename(entity.path).toLowerCase() != 'neogeo.zip') {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Future<bool> _hasPs3FirmwareInstalled(Directory supportDir) async {
    try {
      for (final candidate in [
        File('${supportDir.path}/PS3UPDAT.PUP'),
        File('${supportDir.path}/rpcs3/PS3UPDAT.PUP'),
        File('${supportDir.path}/rpcs3/firmware/PS3UPDAT.PUP'),
      ]) {
        if (await candidate.exists() && await candidate.length() > 0) {
          return true;
        }
      }
      final fwDir = Directory('${supportDir.path}/rpcs3/firmware');
      if (await fwDir.exists()) {
        await for (final entity in fwDir.list(followLinks: false)) {
          if (entity is File && entity.path.toLowerCase().endsWith('.pup')) {
            return true;
          }
        }
      }
      final devFlashSys = Directory('${supportDir.path}/rpcs3/dev_flash/sys');
      if (await devFlashSys.exists()) {
        await for (final _ in devFlashSys.list(followLinks: false)) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<bool> _hasPs3SaveFiles(Directory rpcs3Dir) async {
    final homeDir = Directory('${rpcs3Dir.path}/dev_hdd0/home');
    try {
      if (!await homeDir.exists()) return false;
      await for (final entity
          in homeDir.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        final normalized = entity.path.replaceAll('\\', '/').toLowerCase();
        if (normalized.contains('/savedata/')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Nome de arquivo de download parcial: `*.part` e os metadados de retomada `*.part.pmeta`.
  static bool _isPartFileName(String base) =>
      base.endsWith('.part') || base.endsWith('.part.pmeta');

  bool _isTempLikeFileName(String baseLower) {
    return baseLower.contains('.tmp_') ||
        baseLower.endsWith('.tmp') ||
        _isPartFileName(baseLower) ||
        baseLower.endsWith('.log') ||
        baseLower.endsWith('.cache');
  }

  /// Calcula o detalhamento real do espaço em disco usado pelo aplicativo.
  Future<AppStorageBreakdown> getAppStorageBreakdown() async {
    final supportDir = await _safeDir(getApplicationSupportDirectory);
    if (supportDir == null) return const AppStorageBreakdown();
    final docsDir = await _safeDir(getApplicationDocumentsDirectory);
    final tempDir = await _safeDir(getTemporaryDirectory);
    final cacheDir = await _safeDir(getApplicationCacheDirectory);

    final countedKeys = <String>{};
    int readyRomsBytes = 0;
    int partialDownloadsBytes = 0;
    int systemAndCoresBytes = 0;
    int savesBytes = 0;
    int coversBytes = 0;
    int tempCacheBytes = 0;
    int ps3FirmwareBytes = 0;
    int orphanPartCount = 0;

    // 1. ROMs e downloads parciais (.part)
    final romsDir = Directory('${supportDir.path}/roms');
    try {
      if (await romsDir.exists()) {
        final extractedGameIds =
            await _findExtractedGameIdsWithValidRom(romsDir);
        await for (final entity
            in romsDir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final key = await _uniquePathKey(entity);
          if (!countedKeys.add(key)) continue;
          final len = await entity.length();
          final base = _basename(entity.path).toLowerCase();
          if (_isPartFileName(base)) {
            partialDownloadsBytes += len;
            if (!_isActiveOrPausedPartFile(entity.path)) {
              orphanPartCount++;
            }
          } else if (base.contains('.tmp_') ||
              base.endsWith('.tmp') ||
              _isDuplicateArchiveForExtractedGame(
                filePath: entity.path,
                romsDirPath: romsDir.path,
                baseLower: base,
                extractedGameIds: extractedGameIds,
              )) {
            tempCacheBytes += len;
          } else if (base == 'neogeo.zip') {
            systemAndCoresBytes += len;
          } else {
            readyRomsBytes += len;
          }
        }
      }
    } catch (_) {}

    // 2. Firmware PS3 (PS3UPDAT.PUP + rpcs3/) separando cache JIT/HDD1/resíduos órfãos
    final rpcs3Dir = Directory('${supportDir.path}/rpcs3');
    final hasPs3Firmware = await _hasPs3FirmwareInstalled(supportDir);
    ps3FirmwareBytes += await _sumFileUnique(
      File('${supportDir.path}/PS3UPDAT.PUP'),
      countedKeys,
    );
    try {
      await for (final entity in supportDir.list(followLinks: false)) {
        if (entity is File &&
            _basename(entity.path).toLowerCase().endsWith('.pup')) {
          ps3FirmwareBytes += await _sumFileUnique(entity, countedKeys);
        }
      }
    } catch (_) {}
    try {
      if (await rpcs3Dir.exists()) {
        await for (final entity
            in rpcs3Dir.list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          final key = await _uniquePathKey(entity);
          if (!countedKeys.add(key)) continue;
          final len = await entity.length();
          final rel = entity.path
              .substring(rpcs3Dir.path.length)
              .replaceAll('\\', '/')
              .toLowerCase();
          final isSave =
              rel.startsWith('/dev_hdd0/home/') && rel.contains('/savedata/');
          final isCache = rel.startsWith('/cache/') ||
              rel.startsWith('/dev_hdd1/') ||
              rel.startsWith('/tmp/') ||
              rel.startsWith('/dev_hdd0/tmp/') ||
              rel.startsWith('/logs/') ||
              rel.endsWith('.log') ||
              rel.endsWith('.gz') ||
              rel.contains('.tmp_');
          final isPup = rel.endsWith('.pup');
          if (isSave) {
            savesBytes += len;
          } else if (isPup) {
            ps3FirmwareBytes += len;
          } else if (isCache || !hasPs3Firmware) {
            tempCacheBytes += len;
          } else {
            ps3FirmwareBytes += len;
          }
        }
      }
    } catch (_) {}

    // 3. Sobras .tmp_* / .part em diretórios de suporte
    tempCacheBytes += await _sumFileUnique(
      File('${supportDir.path}/dolphin_sys.zip.part'),
      countedKeys,
    );
    tempCacheBytes += await _sumFileUnique(
      File('${supportDir.path}/fbneo/neogeo.zip.part'),
      countedKeys,
    );
    for (final subName in const [
      'libretro_cores',
      'gpu_drivers',
      'covers',
      'saves',
      'fbneo',
    ]) {
      tempCacheBytes += await _sumDirUnique(
        Directory('${supportDir.path}/$subName'),
        countedKeys,
        where: (_, baseLower) =>
            baseLower.contains('.tmp_') ||
            baseLower.contains('.part_') ||
            _isPartFileName(baseLower),
      );
    }

    // 4. Núcleos, arquivos de sistema e drivers GPU
    for (final sysSub in const [
      'libretro_cores',
      'dolphin-emu',
      'PPSSPP',
      'gpu_drivers',
      'fbneo',
    ]) {
      systemAndCoresBytes += await _sumDirUnique(
        Directory('${supportDir.path}/$sysSub'),
        countedKeys,
      );
    }
    systemAndCoresBytes += await _sumFileUnique(
      File('${supportDir.path}/neogeo.zip'),
      countedKeys,
    );

    // 5. Saves, save states e capas
    savesBytes += await _sumDirUnique(
      Directory('${supportDir.path}/saves'),
      countedKeys,
    );
    coversBytes += await _sumDirUnique(
      Directory('${supportDir.path}/covers'),
      countedKeys,
    );
    if (docsDir != null) {
      final coverCacheDir = Directory('${docsDir.path}/loop_covers_cache');
      tempCacheBytes += await _sumDirUnique(
        coverCacheDir,
        countedKeys,
        where: (_, baseLower) => baseLower.contains('.tmp_'),
      );
      coversBytes += await _sumDirUnique(coverCacheDir, countedKeys);
    }
    for (final manifestName in const [
      'library_manifest.json',
      'library_manifest.json.corrupt.bak',
      'app_settings.json',
      'app_settings.json.corrupt.bak',
      'game_profiles.json',
      'game_profiles.json.corrupt.bak',
      'user_meta.json',
      'user_meta.json.corrupt.bak',
    ]) {
      systemAndCoresBytes += await _sumFileUnique(
        File('${supportDir.path}/$manifestName'),
        countedKeys,
      );
    }

    // 6. Temporários de supportDir raiz
    try {
      await for (final entity in supportDir.list(followLinks: false)) {
        if (entity is! File) continue;
        final base = _basename(entity.path).toLowerCase();
        if (base.contains('.tmp_') ||
            _isPartFileName(base) ||
            base.contains('.part_')) {
          tempCacheBytes += await _sumFileUnique(entity, countedKeys);
        }
      }
    } catch (_) {}

    // 7. Cache e diretórios temporários (tempDir / cacheDir)
    final visitedCacheRoots = <String>{};
    for (final dir in [tempDir, cacheDir]) {
      if (dir == null) continue;
      final dirKey = await _uniquePathKey(dir);
      if (!visitedCacheRoots.add(dirKey)) continue;

      final sharesSupportRoot = dir.path == supportDir.path ||
          (docsDir != null && dir.path == docsDir.path);
      if (!sharesSupportRoot) {
        tempCacheBytes += await _sumDirUnique(dir, countedKeys);
      } else {
        tempCacheBytes += await _sumDirUnique(
          Directory('${dir.path}/file_picker'),
          countedKeys,
        );
        tempCacheBytes += await _sumDirUnique(
          Directory('${dir.path}/adrenotools_tmp'),
          countedKeys,
        );
        try {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if ((base.endsWith('.zip') && base != 'neogeo.zip') ||
                _isPartFileName(base) ||
                base.contains('.tmp_')) {
              tempCacheBytes += await _sumFileUnique(entity, countedKeys);
            }
          }
        } catch (_) {}
      }
    }

    // 8. Varredura abrangente de quaisquer outros diretórios/arquivos não contabilizados
    // (ex.: caches do Play!, WebView, shaders/logs em supportDir, docsDir e dados Android)
    final extraSummary = <String>[];
    void recordExtra(String label, int bytes) {
      if (bytes >= 1024 * 1024) {
        extraSummary.add('$label=${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB');
      }
    }

    try {
      await for (final entity in supportDir.list(followLinks: false)) {
        if (entity is Link) continue;
        final name = _basename(entity.path);
        final nameLower = name.toLowerCase();
        if (entity is File) {
          final added = await _sumFileUnique(entity, countedKeys);
          if (added > 0) {
            if (_isTempLikeFileName(nameLower)) {
              tempCacheBytes += added;
            } else {
              systemAndCoresBytes += added;
            }
            recordExtra('sup:$name', added);
          }
        } else if (entity is Directory) {
          final isCacheDir = nameLower == 'cache' ||
              nameLower == 'tmp' ||
              nameLower == 'logs' ||
              nameLower == 'temp' ||
              nameLower == 'shader_cache';
          int tempAdded = 0;
          int sysAdded = 0;
          await for (final child
              in entity.list(recursive: true, followLinks: false)) {
            if (child is! File) continue;
            final key = await _uniquePathKey(child);
            if (!countedKeys.add(key)) continue;
            final len = await child.length();
            final baseLower = _basename(child.path).toLowerCase();
            if (isCacheDir || _isTempLikeFileName(baseLower)) {
              tempCacheBytes += len;
              tempAdded += len;
            } else {
              systemAndCoresBytes += len;
              sysAdded += len;
            }
          }
          recordExtra('sup/$name', tempAdded + sysAdded);
        }
      }
    } catch (_) {}

    if (docsDir != null && docsDir.path != supportDir.path) {
      try {
        await for (final entity in docsDir.list(followLinks: false)) {
          if (entity is Link) continue;
          final name = _basename(entity.path);
          final nameLower = name.toLowerCase();
          if (entity is File) {
            final added = await _sumFileUnique(entity, countedKeys);
            if (added > 0) {
              if (_isTempLikeFileName(nameLower)) {
                tempCacheBytes += added;
              } else {
                systemAndCoresBytes += added;
              }
              recordExtra('doc:$name', added);
            }
          } else if (entity is Directory) {
            int addedDir = 0;
            await for (final child
                in entity.list(recursive: true, followLinks: false)) {
              if (child is! File) continue;
              final key = await _uniquePathKey(child);
              if (!countedKeys.add(key)) continue;
              final len = await child.length();
              final baseLower = _basename(child.path).toLowerCase();
              if (nameLower.contains('cache') ||
                  _isTempLikeFileName(baseLower)) {
                tempCacheBytes += len;
              } else {
                systemAndCoresBytes += len;
              }
              addedDir += len;
            }
            recordExtra('doc/$name', addedDir);
          }
        }
      } catch (_) {}
    }

    if (Platform.isAndroid) {
      try {
        final appRootDir = supportDir.parent;
        await for (final entity in appRootDir.list(followLinks: false)) {
          if (entity is Link || entity is! Directory) continue;
          final name = _basename(entity.path);
          final nameLower = name.toLowerCase();
          if (nameLower == 'lib') continue;
          final dirKey = await _uniquePathKey(entity);
          if (dirKey == await _uniquePathKey(supportDir)) continue;
          if (docsDir != null && dirKey == await _uniquePathKey(docsDir)) {
            continue;
          }
          if (visitedCacheRoots.contains(dirKey)) continue;
          final isCacheSibling = nameLower == 'code_cache' ||
              nameLower == 'cache' ||
              nameLower == 'app_webview' ||
              nameLower == 'no_backup';
          final added = await _sumDirUnique(entity, countedKeys);
          if (added > 0) {
            if (isCacheSibling) {
              tempCacheBytes += added;
            } else {
              systemAndCoresBytes += added;
            }
            recordExtra('data/$name', added);
          }
        }
      } catch (_) {}
    }

    final savesAndCoversBytes = savesBytes + coversBytes;
    debugPrint(
      '[StorageBreakdown] roms=${(readyRomsBytes / 1048576).toStringAsFixed(1)}MB '
      'part=${(partialDownloadsBytes / 1048576).toStringAsFixed(1)}MB '
      'ps3Fw=${(ps3FirmwareBytes / 1048576).toStringAsFixed(1)}MB '
      'sys=${(systemAndCoresBytes / 1048576).toStringAsFixed(1)}MB '
      'saves=${(savesAndCoversBytes / 1048576).toStringAsFixed(1)}MB '
      '(savesOnly=${(savesBytes / 1048576).toStringAsFixed(1)}MB '
      'covers=${(coversBytes / 1048576).toStringAsFixed(1)}MB) '
      'cache=${(tempCacheBytes / 1048576).toStringAsFixed(1)}MB'
      '${extraSummary.isNotEmpty ? ' extras=${extraSummary.join(',')}' : ''}',
    );

    return AppStorageBreakdown(
      readyRomsBytes: readyRomsBytes,
      partialDownloadsBytes: partialDownloadsBytes,
      systemAndCoresBytes: systemAndCoresBytes,
      savesAndCoversBytes: savesAndCoversBytes,
      savesBytes: savesBytes,
      coversBytes: coversBytes,
      tempCacheBytes: tempCacheBytes,
      ps3FirmwareBytes: ps3FirmwareBytes,
      orphanPartCount: orphanPartCount,
    );
  }

  /// Remove arquivos `.part` órfãos (de downloads não ativos/pausados) e sobras de cache/temp.
  Future<int> cleanOrphanPartAndCacheFiles() async {
    int freedBytes = 0;
    final supportDir = await _safeDir(getApplicationSupportDirectory);
    final docsDir = await _safeDir(getApplicationDocumentsDirectory);
    final tempDir = await _safeDir(getTemporaryDirectory);
    final cacheDir = await _safeDir(getApplicationCacheDirectory);

    Future<void> deleteFileMeasuring(File file) async {
      try {
        if (!await file.exists()) return;
        final len = await file.length();
        await file.delete();
        freedBytes += len;
      } catch (e) {
        debugPrint('[RomDownloadService] Falha ao remover ${file.path}: $e');
      }
    }

    Future<void> deleteDirMeasuring(Directory dir) async {
      try {
        if (!await dir.exists()) return;
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              freedBytes += await entity.length();
            } catch (_) {}
          }
        }
        await dir.delete(recursive: true);
      } catch (e) {
        debugPrint('[RomDownloadService] Falha ao remover pasta ${dir.path}: $e');
      }
    }

    if (supportDir != null) {
      // 1. .part órfãos, .tmp_* e compactados duplicados ao lado de ROM já extraída em roms/
      final romsDir = Directory('${supportDir.path}/roms');
      try {
        if (await romsDir.exists()) {
          final extractedGameIds =
              await _findExtractedGameIdsWithValidRom(romsDir);
          final entities = await romsDir
              .list(recursive: true, followLinks: false)
              .toList();
          for (final entity in entities) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if (_isPartFileName(base)) {
              if (!_isActiveOrPausedPartFile(entity.path)) {
                await deleteFileMeasuring(entity);
              }
            } else if (base.contains('.tmp_') || base.endsWith('.tmp')) {
              await deleteFileMeasuring(entity);
            } else if (_isDuplicateArchiveForExtractedGame(
              filePath: entity.path,
              romsDirPath: romsDir.path,
              baseLower: base,
              extractedGameIds: extractedGameIds,
            )) {
              await deleteFileMeasuring(entity);
            }
          }
          // Remove pastas game_* / arcade_* vazias após remoção de órfãos
          await for (final entity in romsDir.list(followLinks: false)) {
            if (entity is Directory) {
              final name = _basename(entity.path);
              if (name.startsWith('game_') || name.startsWith('arcade_')) {
                try {
                  if (await entity.list().isEmpty) {
                    await entity.delete();
                  }
                } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}

      // 2. Leftovers .tmp_* e .part_* no supportDir e subpastas
      await deleteFileMeasuring(File('${supportDir.path}/dolphin_sys.zip.part'));
      await deleteFileMeasuring(
        File('${supportDir.path}/fbneo/neogeo.zip.part'),
      );

      try {
        await for (final entity in supportDir.list(followLinks: false)) {
          if (entity is! File) continue;
          final base = _basename(entity.path).toLowerCase();
          if (base.contains('.tmp_') ||
              base.contains('.part_') ||
              _isPartFileName(base)) {
            await deleteFileMeasuring(entity);
          }
        }
      } catch (_) {}

      for (final subName in const [
        'libretro_cores',
        'gpu_drivers',
        'covers',
        'saves',
      ]) {
        final subDir = Directory('${supportDir.path}/$subName');
        try {
          if (!await subDir.exists()) continue;
          await for (final entity
              in subDir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if (base.contains('.tmp_') ||
                base.contains('.part_') ||
                _isPartFileName(base)) {
              await deleteFileMeasuring(entity);
            }
          }
        } catch (_) {}
      }

      // 2b. Limpeza de caches do RPCS3 (cache JIT/shaders, dev_hdd1, tmp, logs)
      // e resíduos órfãos deixados quando o firmware PS3 já foi removido.
      final rpcs3Dir = Directory('${supportDir.path}/rpcs3');
      if (await rpcs3Dir.exists()) {
        for (final relCache in const [
          'cache',
          'dev_hdd1',
          'tmp',
          'dev_hdd0/tmp',
          'logs',
        ]) {
          await deleteDirMeasuring(Directory('${rpcs3Dir.path}/$relCache'));
        }
        try {
          await for (final entity in rpcs3Dir.list(followLinks: false)) {
            if (entity is File) {
              final base = _basename(entity.path).toLowerCase();
              if (_isTempLikeFileName(base) || base.endsWith('.gz')) {
                await deleteFileMeasuring(entity);
              }
            }
          }
        } catch (_) {}

        if (!await _hasPs3FirmwareInstalled(supportDir)) {
          for (final relOrphan in const [
            'firmware',
            'dev_flash',
            'dev_flash2',
            'dev_flash3',
            'dev_hdd0/game',
            'config',
            'Icons',
            'captures',
          ]) {
            await deleteDirMeasuring(Directory('${rpcs3Dir.path}/$relOrphan'));
          }
          if (!await _hasPs3SaveFiles(rpcs3Dir)) {
            await deleteDirMeasuring(rpcs3Dir);
          }
        }
      }

      // 2c. Pastas/arquivos temporários e logs residuais em supportDir
      for (final tempSub in const ['logs', 'cache', 'tmp', 'temp', 'shader_cache']) {
        await deleteDirMeasuring(Directory('${supportDir.path}/$tempSub'));
      }
      try {
        await for (final entity in supportDir.list(followLinks: false)) {
          if (entity is File) {
            final base = _basename(entity.path).toLowerCase();
            if (_isTempLikeFileName(base)) {
              await deleteFileMeasuring(entity);
            }
          }
        }
      } catch (_) {}
    }

    if (docsDir != null) {
      final coverCacheDir = Directory('${docsDir.path}/loop_covers_cache');
      try {
        if (await coverCacheDir.exists()) {
          await for (final entity
              in coverCacheDir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if (base.contains('.tmp_')) {
              await deleteFileMeasuring(entity);
            }
          }
        }
      } catch (_) {}
    }

    // 3. file_picker/, adrenotools_tmp/ e zips temporários em tempDir / cacheDir
    final cleanedRoots = <String>{};
    for (final dir in [tempDir, cacheDir]) {
      if (dir == null) continue;
      final dirKey = await _uniquePathKey(dir);
      if (!cleanedRoots.add(dirKey)) continue;

      await deleteDirMeasuring(Directory('${dir.path}/file_picker'));
      await deleteDirMeasuring(Directory('${dir.path}/adrenotools_tmp'));

      final sharesAppData = (supportDir != null && dir.path == supportDir.path) ||
          (docsDir != null && dir.path == docsDir.path);
      try {
        if (!await dir.exists()) continue;
        if (!sharesAppData) {
          await for (final entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if (base.endsWith('.zip') ||
                _isPartFileName(base) ||
                base.contains('.part_') ||
                base.contains('.tmp_')) {
              await deleteFileMeasuring(entity);
            }
          }
        } else {
          await for (final entity in dir.list(followLinks: false)) {
            if (entity is! File) continue;
            final base = _basename(entity.path).toLowerCase();
            if ((base.endsWith('.zip') && base != 'neogeo.zip') ||
                _isPartFileName(base) ||
                base.contains('.part_') ||
                base.contains('.tmp_')) {
              await deleteFileMeasuring(entity);
            }
          }
        }
      } catch (_) {}
    }

    return freedBytes;
  }

  /// Remove saves locais (save states / memory cards / `savedata` do PS3) e/ou
  /// cache de capas de jogos sem apagar ROMs baixadas, núcleos ou configurações.
  Future<int> cleanSavesAndCovers({
    bool deleteSaves = true,
    bool deleteCovers = true,
  }) async {
    int freedBytes = 0;
    final supportDir = await _safeDir(getApplicationSupportDirectory);
    final docsDir = await _safeDir(getApplicationDocumentsDirectory);

    Future<int> measureAndDeleteDirContents(
      Directory dir, {
      bool recreate = false,
    }) async {
      int bytes = 0;
      try {
        if (!await dir.exists()) return 0;
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            try {
              bytes += await entity.length();
            } catch (_) {}
          }
        }
        await dir.delete(recursive: true);
        if (recreate) {
          await dir.create(recursive: true);
        }
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Falha ao limpar ${dir.path}: $e',
        );
      }
      return bytes;
    }

    if (deleteCovers) {
      if (supportDir != null) {
        freedBytes += await measureAndDeleteDirContents(
          Directory('${supportDir.path}/covers'),
        );
      }
      if (docsDir != null) {
        freedBytes += await measureAndDeleteDirContents(
          Directory('${docsDir.path}/loop_covers_cache'),
        );
      }
    }

    if (deleteSaves && supportDir != null) {
      freedBytes += await measureAndDeleteDirContents(
        Directory('${supportDir.path}/saves'),
        recreate: true,
      );
      final homeDir = Directory('${supportDir.path}/rpcs3/dev_hdd0/home');
      try {
        if (await homeDir.exists()) {
          await for (final profile in homeDir.list(followLinks: false)) {
            if (profile is! Directory) continue;
            freedBytes += await measureAndDeleteDirContents(
              Directory('${profile.path}/savedata'),
            );
          }
        }
      } catch (_) {}
    }

    return freedBytes;
  }

  bool _isPathInsideDirectory(String filePath, Directory parentDir) {
    String normalize(String p) {
      var s = p.replaceAll('\\', '/');
      while (s.length > 1 && s.endsWith('/')) {
        s = s.substring(0, s.length - 1);
      }
      return s;
    }

    final candidates = <String>{normalize(File(filePath).absolute.path)};
    try {
      candidates.add(normalize(File(filePath).resolveSymbolicLinksSync()));
    } catch (_) {}

    final roots = <String>{normalize(parentDir.absolute.path)};
    try {
      roots.add(normalize(parentDir.resolveSymbolicLinksSync()));
    } catch (_) {}

    for (final c in candidates) {
      for (final r in roots) {
        if (c == r || c.startsWith('$r/')) {
          return true;
        }
      }
    }
    return false;
  }

  /// Remove o arquivo ROM baixado do disco para liberar espaço.
  /// Arquivos externos vinculados diretamente (fora da pasta `roms/` do app)
  /// nunca são excluídos ao remover o jogo da Biblioteca.
  Future<void> deleteRomFilesForGame(int igdbId, {String? localPath}) async {
    cancelDownload(igdbId);
    _activeStatuses.remove(igdbId);
    _activeGames.remove(igdbId);
    _pauseRequested.remove(igdbId);

    try {
      final dir = await _romsDirectory();
      if (localPath != null && localPath.trim().isNotEmpty) {
        if (_isPathInsideDirectory(localPath, dir)) {
          final f = File(localPath);
          if (await f.exists()) {
            try {
              await f.delete();
            } catch (e) {
              debugPrint(
                '[RomDownloadService] Falha ao remover $localPath: $e',
              );
            }
          }
        } else {
          debugPrint(
            '[RomDownloadService] Mantendo ISO/ROM externa intacta fora de roms/: $localPath',
          );
        }
      }

      final gameDir = Directory('${dir.path}/game_$igdbId');
      if (await gameDir.exists()) {
        await gameDir.delete(recursive: true);
      }
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
    } catch (e) {
      debugPrint(
        '[RomDownloadService] Falha ao remover arquivos da ROM ($igdbId): $e',
      );
    }
  }

  void _emit(
    EmulationGame game,
    RomDownloadStatus status, {
    bool syncNotification = true,
    bool forceNotification = false,
  }) {
    if (_isDisposed) return;
    _activeGames[game.igdbId] = game;
    _activeStatuses[game.igdbId] = status;
    if (!_eventsController.isClosed) {
      _eventsController.add(RomDownloadEvent(game: game, status: status));
    }
    if (syncNotification) {
      _syncDownloadNotification(force: forceNotification);
    }
  }

  void _syncDownloadNotification({bool force = false}) {
    if (_isDisposed) return;
    final now = DateTime.now();
    if (!force && _lastNotificationSyncAt != null) {
      if (now.difference(_lastNotificationSyncAt!).inMilliseconds < 500) {
        return;
      }
    }
    _lastNotificationSyncAt = now;

    final activeEntries = <MapEntry<int, RomDownloadStatus>>[];
    int queuedCount = 0;
    for (final entry in _activeStatuses.entries) {
      if (entry.value.state == RomActionState.downloading) {
        if (entry.value.isQueued) {
          queuedCount++;
        } else {
          activeEntries.add(entry);
        }
      }
    }
    if (_pendingQueue.length > queuedCount) {
      queuedCount = _pendingQueue.where((e) => !e.cancelToken.isCancelled).length;
    }

    final activeCount = activeEntries.length;
    int progressPercent = 0;
    bool indeterminate = false;
    String title = '';
    String detail = '';

    if (activeCount > 0) {
      int sumDownloaded = 0;
      int sumTotal = 0;
      double sumProgress = 0;
      bool allHaveTotals = true;
      for (final e in activeEntries) {
        if (e.value.totalBytes > 0) {
          sumDownloaded += e.value.downloadedBytes;
          sumTotal += e.value.totalBytes;
        } else {
          allHaveTotals = false;
        }
        sumProgress += e.value.progress.clamp(0.0, 1.0);
      }
      if (allHaveTotals && sumTotal > 0) {
        progressPercent = ((sumDownloaded / sumTotal) * 100).round().clamp(0, 100);
      } else {
        progressPercent = ((sumProgress / activeCount) * 100).round().clamp(0, 100);
      }
      indeterminate = activeEntries.every(
        (e) => e.value.totalBytes <= 0 && e.value.progress <= 0.02,
      );

      final firstEntry = activeEntries.first;
      final firstGame = _activeGames[firstEntry.key];
      title = activeCount == 1
          ? (firstGame?.name ?? 'Baixando ROM')
          : '$activeCount downloads ativos';
      final speed = firstEntry.value.speedLabel ?? '';
      if (queuedCount > 0) {
        detail = speed.isNotEmpty
            ? '$speed • $queuedCount na fila'
            : '$queuedCount na fila';
      } else {
        detail = speed;
      }
    } else if (queuedCount > 0) {
      indeterminate = true;
      title = 'Na fila ($queuedCount)';
      detail = 'Aguardando slot de download';
    } else if (_completedNotificationCount > 0 || _failedNotificationCount > 0) {
      progressPercent = 100;
      title = _failedNotificationCount > 0
          ? 'Downloads finalizados ($_completedNotificationCount ok, $_failedNotificationCount falhas)'
          : 'Downloads concluídos ($_completedNotificationCount)';
      detail = '';
    }

    unawaited(
      EmulatorService.syncDownloadNotification(
        activeCount: activeCount,
        queuedCount: queuedCount,
        completedCount: _completedNotificationCount,
        failedCount: _failedNotificationCount,
        progressPercent: progressPercent,
        indeterminate: indeterminate,
        title: title,
        detail: detail,
      ),
    );
  }

  void _refreshQueuePositions() {
    int pos = 1;
    for (final entry in _pendingQueue) {
      if (entry.cancelToken.isCancelled) continue;
      entry.notify(
        RomDownloadStatus(
          state: RomActionState.downloading,
          progress: entry.progress,
          downloadedBytes: entry.downloadedBytes,
          totalBytes: entry.totalBytes,
          speedLabel: 'Na fila (#$pos)...',
          isQueued: true,
          queuePosition: pos,
        ),
      );
      pos++;
    }
    _syncDownloadNotification(force: true);
  }

  bool _removeQueuedEntryById(int igdbId) {
    bool removed = false;
    _pendingQueue.removeWhere((entry) {
      if (entry.game.igdbId == igdbId) {
        if (!entry.slotCompleter.isCompleted) {
          entry.slotCompleter.complete(false);
        }
        removed = true;
        return true;
      }
      return false;
    });
    return removed;
  }

  bool _removeQueuedEntryByToken(CancelToken token) {
    bool removed = false;
    _pendingQueue.removeWhere((entry) {
      if (identical(entry.cancelToken, token)) {
        if (!entry.slotCompleter.isCompleted) {
          entry.slotCompleter.complete(false);
        }
        removed = true;
        return true;
      }
      return false;
    });
    return removed;
  }

  void _releaseDownloadSlot() {
    if (_activeDownloadsCount > 0) {
      _activeDownloadsCount--;
    }
    while (_pendingQueue.isNotEmpty) {
      final next = _pendingQueue.removeFirst();
      if (!next.cancelToken.isCancelled &&
          !next.slotCompleter.isCompleted &&
          identical(_cancelTokens[next.game.igdbId], next.cancelToken)) {
        _activeDownloadsCount++;
        next.slotCompleter.complete(true);
        break;
      }
      if (!next.slotCompleter.isCompleted) {
        next.slotCompleter.complete(false);
      }
    }
    _refreshQueuePositions();
  }

  Future<File> _activeDownloadsFile() async {
    final baseDir = await getApplicationSupportDirectory();
    return File('${baseDir.path}/active_downloads.json');
  }

  Future<void> _persistPendingDownloadEntry(EmulationGame game) async {
    if (_isDisposed) return;
    await _serializeManifestWrite(() async {
      try {
        final file = await _activeDownloadsFile();
        final Map<String, dynamic> entries = {};
        if (await file.exists()) {
          try {
            final decoded = jsonDecode(await file.readAsString());
            if (decoded is Map) {
              for (final e in decoded.entries) {
                entries[e.key.toString()] = e.value;
              }
            }
          } catch (_) {}
        }
        entries['${game.igdbId}'] = {
          'igdbId': game.igdbId,
          'name': game.name,
          'canonicalNoIntroName': game.canonicalNoIntroName,
          'summary': game.summary,
          'genres': game.genres,
          'developer': game.developer,
          'releaseYear': game.releaseYear,
          'rating': game.rating,
          'platformName': game.platformName,
          'platformSlug': game.platformSlug,
          'directRomUrl': game.directRomUrl,
          'region': game.region,
          'crc32': game.crc32,
          'gridCoverUrl': game.gridCoverUrl,
          'heroBannerUrl': game.heroBannerUrl,
          'logoUrl': game.logoUrl,
          'estimatedSizeBytes': game.estimatedSizeBytes,
        };
        if (!await file.parent.exists()) {
          await file.parent.create(recursive: true);
        }
        await _writeActiveDownloadsAtomic(file, entries);
      } catch (_) {}
    });
  }

  Future<void> _writeActiveDownloadsAtomic(
    File file,
    Map<String, dynamic> entries,
  ) async {
    final tmp = File('${file.path}.tmp');
    try {
      await tmp.writeAsString(jsonEncode(entries), flush: true);
      if (await file.exists()) await file.delete();
      await tmp.rename(file.path);
    } catch (_) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<void> _removePendingDownloadEntry(int igdbId) async {
    if (_isDisposed) return;
    await _serializeManifestWrite(() async {
      try {
        final file = await _activeDownloadsFile();
        if (!await file.exists()) return;
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is! Map) return;
        final key = '$igdbId';
        if (!decoded.containsKey(key)) return;
        final updated = Map<String, dynamic>.from(decoded)..remove(key);
        if (updated.isEmpty) {
          await file.delete();
        } else {
          await _writeActiveDownloadsAtomic(file, updated);
        }
      } catch (_) {}
    });
  }

  /// Acorda downloads aguardando rede e retoma automaticamente downloads
  /// interrompidos por perda de conexão ou reinício ao retornar para o app.
  Future<void> onAppOrNetworkResumed() async {
    if (_isDisposed) return;

    // 1. Acorda qualquer retry que estava esperando conexão voltar
    final waiters = List<Completer<void>>.from(_networkResumeWaiters);
    _networkResumeWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.complete();
      }
    }

    final net = await EmulatorService.fetchNetworkStatus();
    if (!net.connected || _isDisposed) return;

    // 2. Restaura do disco downloads pendentes de execuções anteriores
    if (!_restoredPendingDownloadsFromDisk) {
      _restoredPendingDownloadsFromDisk = true;
      try {
        final file = await _activeDownloadsFile();
        if (await file.exists()) {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is Map) {
            for (final raw in decoded.values) {
              if (raw is! Map) continue;
              final map = Map<String, dynamic>.from(raw);
              final id = (map['igdbId'] as num?)?.toInt();
              final name = map['name'] as String?;
              final slug = map['platformSlug'] as String?;
              final platformName = map['platformName'] as String?;
              final directUrl = map['directRomUrl'] as String?;
              if (id == null ||
                  name == null ||
                  slug == null ||
                  platformName == null ||
                  directUrl == null ||
                  directUrl.isEmpty) {
                continue;
              }
              if (_pauseRequested[id] == true ||
                  _activeStatuses[id]?.state == RomActionState.paused) {
                continue;
              }
              final part = await _resolvePartFile(id);
              if (part == null || !await part.exists()) {
                unawaited(_removePendingDownloadEntry(id));
                continue;
              }
              final restoredGame = EmulationGame(
                igdbId: id,
                name: name,
                canonicalNoIntroName:
                    (map['canonicalNoIntroName'] as String?) ?? name,
                summary: (map['summary'] as String?) ?? '',
                genres: (map['genres'] as List<dynamic>?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    const <String>[],
                developer: (map['developer'] as String?) ?? '',
                releaseYear: (map['releaseYear'] as num?)?.toInt(),
                rating: (map['rating'] as num?)?.toDouble(),
                platformName: platformName,
                platformSlug: slug,
                directRomUrl: directUrl,
                region: (map['region'] as String?) ?? 'USA',
                crc32: (map['crc32'] as String?) ?? '',
                gridCoverUrl: map['gridCoverUrl'] as String?,
                heroBannerUrl: map['heroBannerUrl'] as String?,
                logoUrl: map['logoUrl'] as String?,
                estimatedSizeBytes:
                    (map['estimatedSizeBytes'] as num?)?.toInt() ?? 0,
              );
              _networkInterruptedGames.putIfAbsent(id, () => restoredGame);
            }
          }
        }
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Falha ao restaurar active_downloads.json: $e',
        );
      }
    }

    // 3. Retoma todos os downloads interrompidos pela rede
    final toResume = _networkInterruptedGames.values.toList();
    for (final game in toResume) {
      if (_isDisposed) return;
      if (_pauseRequested[game.igdbId] == true) continue;
      final existingStatus = _activeStatuses[game.igdbId]?.state;
      if (existingStatus == RomActionState.downloading ||
          existingStatus == RomActionState.readyToPlay) {
        _networkInterruptedGames.remove(game.igdbId);
        continue;
      }
      _networkInterruptedGames.remove(game.igdbId);
      unawaited(startBackgroundDownload(game: game));
    }
  }

  /// Inicia ou continua download em segundo plano com suporte a fila, pausa e HTTP Range
  Future<String?> startBackgroundDownload({
    required EmulationGame game,
    void Function(RomDownloadStatus status)? onStatus,
  }) async {
    if (_isDisposed) return null;

    final existingToken = _cancelTokens[game.igdbId];
    final curStatus = _activeStatuses[game.igdbId];
    if (curStatus?.state == RomActionState.downloading &&
        existingToken != null &&
        !existingToken.isCancelled) {
      return null;
    }

    if (game.directRomUrl.startsWith('external://')) {
      const st = RomDownloadStatus(
        state: RomActionState.notDownloaded,
        errorMessage:
            'Use "Importar ISO / ROM" na Biblioteca ou configure seu servidor RomM nos Ajustes.',
      );
      _emit(game, st, forceNotification: true);
      onStatus?.call(st);
      return null;
    }

    if (_activeDownloadsCount == 0 && _pendingQueue.isEmpty) {
      _completedNotificationCount = 0;
      _failedNotificationCount = 0;
    }
    if (!_notificationPermissionRequested) {
      _notificationPermissionRequested = true;
      unawaited(EmulatorService.requestNotificationPermission());
    }

    final cancelToken = CancelToken();
    _cancelTokens[game.igdbId] = cancelToken;
    final opSeq = (_operationSeq[game.igdbId] ?? 0) + 1;
    _operationSeq[game.igdbId] = opSeq;
    _pauseRequested[game.igdbId] = false;
    _networkInterruptedGames.remove(game.igdbId);
    unawaited(_persistPendingDownloadEntry(game));

    bool isCurrentOperation() =>
        !_isDisposed && identical(_cancelTokens[game.igdbId], cancelToken);

    void notify(
      RomDownloadStatus st, {
      bool syncNotification = true,
      bool forceNotification = false,
    }) {
      if (!isCurrentOperation()) return;
      _emit(
        game,
        st,
        syncNotification: syncNotification,
        forceNotification: forceNotification,
      );
      onStatus?.call(st);
    }

    bool acquiredSlot = false;
    try {
      if (_activeDownloadsCount < maxConcurrentDownloads) {
        _activeDownloadsCount++;
        acquiredSlot = true;
      } else {
        final slotCompleter = Completer<bool>();
        final queueEntry = _QueuedDownloadEntry(
          game: game,
          cancelToken: cancelToken,
          slotCompleter: slotCompleter,
          notify: (st) => notify(st, syncNotification: false),
          progress: curStatus?.progress ?? 0.0,
          downloadedBytes: curStatus?.downloadedBytes ?? 0,
          totalBytes: curStatus?.totalBytes ?? game.estimatedSizeBytes,
        );
        _pendingQueue.addLast(queueEntry);
        _refreshQueuePositions();

        unawaited(
          cancelToken.whenCancel.then((_) {
            final removed = _removeQueuedEntryByToken(cancelToken);
            if (!slotCompleter.isCompleted) {
              slotCompleter.complete(false);
            }
            if (removed) {
              _refreshQueuePositions();
            }
          }),
        );

        acquiredSlot = await slotCompleter.future;
        if (!acquiredSlot || cancelToken.isCancelled || !isCurrentOperation()) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: game.directRomUrl),
            reason: cancelToken.cancelError?.error,
          );
        }
      }

      notify(
        RomDownloadStatus(
          state: RomActionState.downloading,
          progress: curStatus?.progress ?? 0.01,
          downloadedBytes: curStatus?.downloadedBytes ?? 0,
          totalBytes: curStatus?.totalBytes ?? game.estimatedSizeBytes,
          speedLabel: 'Conectando...',
          isQueued: false,
          queuePosition: 0,
        ),
        forceNotification: true,
      );

      final result = await _executeResilientDownload(
        game: game,
        cancelToken: cancelToken,
        isCurrentOperation: isCurrentOperation,
        notify: (st) => notify(
          st,
          forceNotification: st.speedLabel == 'Extraindo ROM...',
        ),
      );

      if (result != null && isCurrentOperation()) {
        _networkInterruptedGames.remove(game.igdbId);
        unawaited(_removePendingDownloadEntry(game.igdbId));
        _completedNotificationCount++;
        final ready = RomDownloadStatus(
          state: RomActionState.readyToPlay,
          progress: 1.0,
          localPath: result.path,
          downloadedBytes: result.totalBytes,
          totalBytes: result.totalBytes,
          crcVerified: result.crcVerified,
          warningMessage: result.warningMessage,
        );
        notify(ready, forceNotification: true);
        return result.path;
      }
      return null;
    } catch (e) {
      if (!isCurrentOperation()) {
        return null;
      }

      if (_pauseRequested[game.igdbId] == true ||
          (e is DioException &&
              e.type == DioExceptionType.cancel &&
              cancelToken.cancelError?.error == 'PAUSED_BY_USER')) {
        _networkInterruptedGames.remove(game.igdbId);
        unawaited(_removePendingDownloadEntry(game.igdbId));
        final partFile = await _resolvePartFile(game.igdbId);
        if (!isCurrentOperation()) return null;
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
            isQueued: false,
            queuePosition: 0,
          ),
          forceNotification: true,
        );
        return null;
      }

      if (e is DioException && e.type == DioExceptionType.cancel) {
        return null;
      }

      if (e is _NonRetryableDownloadException) {
        _networkInterruptedGames.remove(game.igdbId);
        unawaited(_removePendingDownloadEntry(game.igdbId));
        unawaited(_cleanPartFiles(game.igdbId, expectedSeq: opSeq));
        _failedNotificationCount++;
        notify(
          RomDownloadStatus(
            state: RomActionState.notDownloaded,
            errorMessage: _friendlyErrorMessage(e),
            isQueued: false,
            queuePosition: 0,
          ),
          forceNotification: true,
        );
        return null;
      }

      // Falha transitória de rede / desconexão: mantém `.part` e registra para
      // retomada automática assim que a conexão voltar ou o usuário retornar ao app.
      _networkInterruptedGames[game.igdbId] = game;
      final partFile = await _resolvePartFile(game.igdbId);
      if (!isCurrentOperation()) return null;
      final downloaded =
          (partFile != null && await partFile.exists()) ? await partFile.length() : 0;
      final total = game.estimatedSizeBytes > 0
          ? game.estimatedSizeBytes
          : (downloaded > 0 ? downloaded * 2 : 0);
      final progress =
          total > 0 ? (downloaded / total).clamp(0.01, 0.99) : 0.0;
      _failedNotificationCount++;
      notify(
        RomDownloadStatus(
          state: RomActionState.paused,
          progress: progress,
          downloadedBytes: downloaded,
          totalBytes: total,
          speedLabel: 'Aguardando conexão...',
          errorMessage: _friendlyErrorMessage(e),
          isQueued: false,
          queuePosition: 0,
        ),
        forceNotification: true,
      );
      return null;
    } finally {
      if (identical(_cancelTokens[game.igdbId], cancelToken)) {
        _cancelTokens.remove(game.igdbId);
      }
      if (acquiredSlot) {
        _releaseDownloadSlot();
      } else {
        _syncDownloadNotification(force: true);
      }
    }
  }

  /// Pausa um download ativo preservando o arquivo `.part` para continuação posterior.
  void pauseDownload(int igdbId) {
    _pauseRequested[igdbId] = true;
    _networkInterruptedGames.remove(igdbId);
    unawaited(_removePendingDownloadEntry(igdbId));
    final removedFromQueue = _removeQueuedEntryById(igdbId);
    final token = _cancelTokens[igdbId];
    if (token != null && !token.isCancelled) {
      token.cancel('PAUSED_BY_USER');
    }
    if (removedFromQueue) {
      _refreshQueuePositions();
    }
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
          isQueued: false,
          queuePosition: 0,
        ),
        forceNotification: true,
      );
    }
  }

  /// Cancela e exclui arquivos parciais
  void cancelDownload(int igdbId) {
    _pauseRequested.remove(igdbId);
    _networkInterruptedGames.remove(igdbId);
    unawaited(_removePendingDownloadEntry(igdbId));
    final cancelSeq = (_operationSeq[igdbId] ?? 0) + 1;
    _operationSeq[igdbId] = cancelSeq;
    final removedFromQueue = _removeQueuedEntryById(igdbId);
    final token = _cancelTokens.remove(igdbId);
    if (token != null && !token.isCancelled) {
      token.cancel('CANCELLED_BY_USER');
    }
    if (removedFromQueue) {
      _refreshQueuePositions();
    }
    final game = _activeGames[igdbId];
    if (game != null) {
      _emit(
        game,
        const RomDownloadStatus(
          state: RomActionState.notDownloaded,
          errorMessage: 'Download cancelado.',
          isQueued: false,
          queuePosition: 0,
        ),
        forceNotification: true,
      );
    }
    unawaited(_cleanPartFiles(igdbId, expectedSeq: cancelSeq));
  }

  Future<void> _cleanPartFiles(int igdbId, {int? expectedSeq}) async {
    try {
      final dir = await _romsDirectory();
      if (expectedSeq != null && _operationSeq[igdbId] != expectedSeq) return;

      final arcadeDir = Directory('${dir.path}/arcade_$igdbId');
      if (await arcadeDir.exists()) {
        final arcadeFiles = await arcadeDir.list().toList();
        for (final f in arcadeFiles) {
          if (expectedSeq != null && _operationSeq[igdbId] != expectedSeq) {
            return;
          }
          if (f is File && _isPartFileName(_basename(f.path).toLowerCase())) {
            await f.delete();
          }
        }
      }
      final files = await dir.list().toList();
      for (final f in files) {
        if (expectedSeq != null && _operationSeq[igdbId] != expectedSeq) return;
        if (f is File &&
            f.path.contains('rom_${igdbId}_') &&
            _isPartFileName(_basename(f.path).toLowerCase())) {
          await f.delete();
        }
      }
    } catch (e) {
      debugPrint('[RomDownloadService] Falha ao limpar .part ($igdbId): $e');
    }
  }

  String _friendlyErrorMessage(Object error) {
    if (error is _NonRetryableDownloadException) return error.message;
    if (error is StateError) return error.message;
    if (error is DioException) return _friendlyDioMessage(error);
    return 'Falha no download: erro inesperado ao acessar o servidor.';
  }

  String _friendlyDioMessage(DioException e) {
    final code = e.response?.statusCode;
    switch (code) {
      case 401:
        return 'Autenticação necessária (HTTP 401). Verifique o token RomM.';
      case 403:
        return 'Acesso negado pelo servidor (HTTP 403). Este mirror restringiu o download.';
      case 404:
        return 'ROM não encontrada no servidor (HTTP 404). Tente outro mirror ou arquivo local.';
      case 416:
        return 'Faixa de bytes inválida no servidor (HTTP 416). Reinicie o download.';
      case 429:
        return 'Muitas requisições ao servidor (HTTP 429). Aguarde instantes e tente novamente.';
      default:
        if (code != null && code >= 500) {
          return 'Servidor temporariamente indisponível (HTTP $code). Tente novamente em instantes.';
        }
        if (code != null) {
          return 'Falha no servidor (HTTP $code) ao baixar a ROM.';
        }
    }

    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.transformTimeout:
        return 'Tempo esgotado na conexão com o servidor. Verifique sua internet e tente novamente.';
      case DioExceptionType.connectionError:
        return 'Não foi possível conectar ao servidor. Verifique sua rede ou endereço RomM.';
      case DioExceptionType.badCertificate:
        return 'Certificado SSL/TLS inválido no servidor.';
      case DioExceptionType.cancel:
        return 'Download interrompido.';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return 'Falha de rede durante a transferência da ROM. Tente novamente.';
    }
  }

  Future<void> _delayWithCancel(
    Duration duration,
    CancelToken cancelToken,
  ) async {
    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken.cancelError?.error,
      );
    }
    await Future.any<void>([
      Future<void>.delayed(duration),
      cancelToken.whenCancel.then((_) {}),
    ]);
    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken.cancelError?.error,
      );
    }
  }

  bool _isValidCrc32Hex(String raw) {
    final clean = raw.trim().toUpperCase();
    return RegExp(r'^[0-9A-F]{8}$').hasMatch(clean) && clean != '00000000';
  }

  Future<void> _delayWithCancelOrResume(
    Duration duration,
    CancelToken cancelToken,
  ) async {
    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken.cancelError?.error,
      );
    }
    final resumeCompleter = Completer<void>();
    _networkResumeWaiters.add(resumeCompleter);
    try {
      await Future.any<void>([
        Future<void>.delayed(duration),
        cancelToken.whenCancel.then((_) {}),
        resumeCompleter.future,
      ]);
    } finally {
      _networkResumeWaiters.remove(resumeCompleter);
    }
    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: ''),
        reason: cancelToken.cancelError?.error,
      );
    }
  }

  Future<void> _waitForRetryWithNetworkCheck({
    required int attempt,
    required bool checkNetwork,
    required CancelToken cancelToken,
    required bool Function() isCurrentOperation,
    required int currentBytes,
    required int expectedTotalBytes,
    required void Function(RomDownloadStatus status) notify,
  }) async {
    final delaySeconds = _retryBackoffSeconds[
        (attempt - 1).clamp(0, _retryBackoffSeconds.length - 1)];
    final delay = Duration(seconds: delaySeconds);
    final progress = expectedTotalBytes > 0
        ? (currentBytes / expectedTotalBytes).clamp(0.01, 0.99)
        : 0.05;

    if (checkNetwork) {
      // Enquanto o aparelho estiver realmente sem rede, aguarda sem gastar
      // tentativas de retry e acorda na hora quando a rede/app retornar.
      for (int waitRound = 0; waitRound < 120; waitRound++) {
        if (cancelToken.isCancelled || !isCurrentOperation() || _isDisposed) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: ''),
            reason: cancelToken.cancelError?.error,
          );
        }
        final net = await EmulatorService.fetchNetworkStatus();
        if (net.connected) break;
        notify(
          RomDownloadStatus(
            state: RomActionState.downloading,
            progress: progress,
            downloadedBytes: currentBytes,
            totalBytes: expectedTotalBytes,
            speedLabel: 'Aguardando conexão...',
          ),
        );
        await _delayWithCancelOrResume(const Duration(seconds: 4), cancelToken);
      }
    }

    notify(
      RomDownloadStatus(
        state: RomActionState.downloading,
        progress: progress,
        downloadedBytes: currentBytes,
        totalBytes: expectedTotalBytes,
        speedLabel: 'Reconectando (${attempt + 1}/$maxRetryAttempts)...',
      ),
    );
    await _delayWithCancel(delay, cancelToken);
  }

  /// Sonda o servidor com `Range: bytes=0-0` e devolve o tamanho total do
  /// arquivo quando o servidor aceita Range. Retorna `null` quando o download
  /// paralelo não é viável (servidor ignora Range, erro ou timeout).
  Future<int?> _probeRangeTotalBytes(
    String url,
    CancelToken cancelToken,
  ) async {
    final probeCancel = CancelToken();
    final Response<ResponseBody> response;
    try {
      response = await _dio.get<ResponseBody>(
        url,
        cancelToken: probeCancel,
        options: Options(
          responseType: ResponseType.stream,
          headers: const {'Range': 'bytes=0-0'},
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (s) => s != null && s >= 200 && s < 300,
        ),
      );
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel && cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: cancelToken.cancelError?.error,
        );
      }
      return null;
    } catch (_) {
      return null;
    }

    if (cancelToken.isCancelled) {
      throw DioException.requestCancelled(
        requestOptions: RequestOptions(path: url),
        reason: cancelToken.cancelError?.error,
      );
    }

    if ((response.statusCode ?? 0) != 206) {
      // Servidor devolveu 200: ignorou o Range e enviaria o arquivo inteiro.
      // Aborta a resposta para não segurar a conexão aberta.
      try {
        probeCancel.cancel();
      } catch (_) {
        // Cancelar uma requisição já concluída é apenas higiene de conexão.
      }
      return null;
    }

    final contentRange = response.headers.value('content-range') ?? '';
    final match = RegExp(r'bytes\s+\d+-\d+\/(\d+)').firstMatch(contentRange);
    final total = match == null ? 0 : int.tryParse(match.group(1)!) ?? 0;
    try {
      // Corpo de `bytes=0-0` tem 1 byte; drenar libera a conexão sem cancelar.
      await response.data?.stream.drain<void>();
    } catch (_) {
      // O corpo da sonda não afeta o tamanho já extraído dos cabeçalhos.
    }
    return total > 0 ? total : null;
  }

  /// Baixa [url] para [partFile] usando várias conexões HTTP Range em paralelo.
  ///
  /// Retorna `true` quando o arquivo foi concluído integralmente. Retorna
  /// `false` quando o servidor não aceita Range, o arquivo é pequeno demais ou
  /// alguma falha interna ocorreu — nesses casos o `.part` é recortado apenas ao
  /// prefixo contíguo já escrito, para que o download de stream único assuma de
  /// onde parou. Cancelamentos do usuário são propagados.
  Future<bool> _tryDownloadWithParallelChunks({
    required String url,
    required File partFile,
    required EmulationGame game,
    required CancelToken cancelToken,
    required bool Function() isCurrentOperation,
    required void Function(RomDownloadStatus status) notify,
    required int minExpectedBytes,
  }) async {
    void ensureNotCancelled() {
      if (cancelToken.isCancelled || !isCurrentOperation()) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: url),
          reason: cancelToken.cancelError?.error,
        );
      }
    }

    ensureNotCancelled();

    // O tamanho já conhecido do catálogo evita uma sonda extra: se o arquivo é
    // pequeno demais, nem vale tentar abrir conexões paralelas.
    final knownSize = game.estimatedSizeBytes;
    if (knownSize > 0 && knownSize < minParallelTotalBytes) {
      return false;
    }

    final totalBytes = await _probeRangeTotalBytes(url, cancelToken);
    if (totalBytes == null ||
        totalBytes < minParallelTotalBytes ||
        totalBytes < minExpectedBytes) {
      return false;
    }

    var chunkCount = (totalBytes / minParallelChunkBytes).ceil();
    if (chunkCount < 2) chunkCount = 2;
    if (chunkCount > maxParallelChunks) chunkCount = maxParallelChunks;

    final bounds = List<(int, int)>.generate(
      chunkCount,
      (i) => (
        (totalBytes * i) ~/ chunkCount,
        (totalBytes * (i + 1)) ~/ chunkCount,
      ),
    );

    final metaFile = File('${partFile.path}.pmeta');
    var chunkDone = List<int>.filled(chunkCount, 0);
    var restoredFromMeta = false;

    if (await metaFile.exists()) {
      try {
        final decoded = jsonDecode(await metaFile.readAsString());
        final partLength =
            await partFile.exists() ? await partFile.length() : -1;
        if (decoded is Map<String, dynamic> &&
            decoded['url'] == url &&
            decoded['total'] == totalBytes &&
            decoded['chunks'] is List &&
            (decoded['chunks'] as List).length == chunkCount &&
            partLength >= totalBytes) {
          final restored = List<int>.from(
            (decoded['chunks'] as List).map((e) => (e as num?)?.toInt() ?? 0),
          );
          var valid = true;
          for (var i = 0; i < chunkCount && valid; i++) {
            final size = bounds[i].$2 - bounds[i].$1;
            if (restored[i] < 0 || restored[i] > size) valid = false;
          }
          if (valid) {
            chunkDone = restored;
            restoredFromMeta = true;
          }
        }
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Metadados de download paralelo ignorados: $e',
        );
      }
    }

    if (!restoredFromMeta) {
      var existingLength =
          await partFile.exists() ? await partFile.length() : 0;
      if (existingLength >= totalBytes) {
        // Metadados inválidos + .part no tamanho total = arquivo pré-alocado
        // com buracos. Nenhum byte pode ser considerado concluído.
        try {
          if (await partFile.exists()) await partFile.delete();
        } catch (e) {
          debugPrint('[RomDownloadService] Falha ao limpar .part: $e');
        }
        existingLength = 0;
      }
      if (existingLength > 0) {
        // Bytes escritos sequencialmente pelo stream único pertencem ao início
        // da partição e podem ser aproveitados como retome do paralelo.
        for (var i = 0; i < chunkCount; i++) {
          final start = bounds[i].$1;
          final end = bounds[i].$2;
          if (existingLength >= end) {
            chunkDone[i] = end - start;
          } else if (existingLength > start) {
            chunkDone[i] = existingLength - start;
          }
        }
      }
    }

    void writeMeta() {
      try {
        metaFile.writeAsStringSync(
          jsonEncode({'url': url, 'total': totalBytes, 'chunks': chunkDone}),
        );
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Falha ao gravar metadados do download paralelo: $e',
        );
      }
    }

    // Gravado antes de pré-alocar o arquivo: se o app morrer entre as duas
    // operações, o próximo início exige `.part` já no tamanho total antes de
    // confiar nos metadados, evitando aceitar bytes zerados como concluídos.
    writeMeta();

    // `writeOnly` não trunca (diferente de `write`) e, ao contrário de `append`,
    // respeita `setPositionSync` — essencial com chunks paralelos.
    final raf = partFile.openSync(mode: FileMode.writeOnly);
    final chunkCancel = CancelToken();
    var abort = false;
    Object? failure;
    var lastUiUpdate = DateTime.now();
    var lastMetaWrite = DateTime.now();
    final speedSamples = <(DateTime, int)>[];

    int totalDone() {
      var sum = 0;
      for (final value in chunkDone) {
        sum += value;
      }
      return sum;
    }

    void reportProgress() {
      final now = DateTime.now();
      if (now.difference(lastUiUpdate).inMilliseconds < 250) return;
      lastUiUpdate = now;
      final done = totalDone();
      speedSamples.add((now, done));
      speedSamples.removeWhere(
        (sample) => now.difference(sample.$1).inMilliseconds > 1500,
      );
      var bytesPerSec = 0.0;
      if (speedSamples.length > 1) {
        final oldest = speedSamples.first;
        final windowMs = now.difference(oldest.$1).inMilliseconds.clamp(100, 2000);
        bytesPerSec = ((done - oldest.$2) * 1000.0) / windowMs;
      }
      notify(
        RomDownloadStatus(
          state: RomActionState.downloading,
          progress:
              totalBytes > 0 ? (done / totalBytes).clamp(0.01, 0.99) : 0.5,
          downloadedBytes: done,
          totalBytes: totalBytes,
          speedLabel: _formatSpeed(bytesPerSec),
        ),
      );
      if (now.difference(lastMetaWrite).inMilliseconds >= 2000) {
        lastMetaWrite = now;
        writeMeta();
      }
    }

    // Repasse do cancelamento do usuário para o token usado nas conexões
    // paralelas, garantindo que uma requisição em voo seja abortada na hora.
    unawaited(
      cancelToken.whenCancel.then((_) {
        if (!chunkCancel.isCancelled) chunkCancel.cancel();
      }),
    );

    var completed = false;
    var fellBack = false;
    try {
      try {
        raf.truncateSync(totalBytes);
      } catch (e) {
        fellBack = true;
        debugPrint(
          '[RomDownloadService] Falha ao pré-alocar .part de ${game.name} ($e); usando stream único.',
        );
        return false;
      }

      Future<void> runChunk(int index) async {
        final start = bounds[index].$1;
        final end = bounds[index].$2;
        var attempt = 1;
        try {
          while (true) {
            if (abort) return;
            ensureNotCancelled();
            final from = start + chunkDone[index];
            if (from >= end) {
              reportProgress();
              return;
            }

            try {
              final response = await _dio.get<ResponseBody>(
                url,
                cancelToken: chunkCancel,
                options: Options(
                  responseType: ResponseType.stream,
                  headers: {'Range': 'bytes=$from-${end - 1}'},
                  receiveTimeout: defaultReceiveTimeout,
                  validateStatus: (s) => s != null && s >= 200 && s < 300,
                ),
              );
              if (response.statusCode != 206) {
                throw const _ParallelUnavailableException();
              }
              final stream = response.data?.stream;
              if (stream == null) {
                throw const _ParallelUnavailableException();
              }

              var writeOffset = from;
              var received = 0;
              final expected = end - from;
              await for (final data in stream) {
                if (abort) return;
                ensureNotCancelled();
                if (data.isEmpty) continue;
                // Escrita síncrona em offset: como o Dart é single-thread, não
                // há entrelaçamento entre os chunks que compartilham o arquivo.
                raf.setPositionSync(writeOffset);
                raf.writeFromSync(data);
                writeOffset += data.length;
                received += data.length;
                chunkDone[index] = (from - start) + received;
                reportProgress();
              }
              if (received < expected) {
                throw StateError(
                  'Chunk $index do download paralelo terminou cedo '
                  '($received de $expected bytes).',
                );
              }
              chunkDone[index] = expected;
              reportProgress();
              return;
            } on _ParallelUnavailableException {
              rethrow;
            } catch (e) {
              if (cancelToken.isCancelled || !isCurrentOperation()) rethrow;
              if (abort) return;
              if (attempt >= maxRetryAttempts) rethrow;
              attempt++;
              debugPrint(
                '[RomDownloadService] Chunk $index do download paralelo de '
                '${game.name}: tentativa $attempt/$maxRetryAttempts falhou ($e).',
              );
              final delaySeconds = _retryBackoffSeconds[(attempt - 1)
                  .clamp(0, _retryBackoffSeconds.length - 1)];
              await _delayWithCancel(Duration(seconds: delaySeconds), chunkCancel);
            }
          }
        } catch (e) {
          failure ??= e;
          abort = true;
          if (!chunkCancel.isCancelled) chunkCancel.cancel();
        }
      }

      await Future.wait<void>([
        for (var i = 0; i < chunkCount; i++) runChunk(i),
      ]);

      if (failure != null) throw failure!;
      if (totalDone() < totalBytes) {
        throw const _ParallelUnavailableException();
      }
      completed = true;
      return true;
    } on _ParallelUnavailableException {
      fellBack = true;
      return false;
    } on DioException catch (e) {
      if (cancelToken.isCancelled || !isCurrentOperation()) rethrow;
      fellBack = true;
      debugPrint(
        '[RomDownloadService] Download paralelo de ${game.name} interrompido (${e.type}); usando stream único.',
      );
      return false;
    } catch (e) {
      fellBack = true;
      debugPrint(
        '[RomDownloadService] Download paralelo de ${game.name} falhou ($e); usando stream único.',
      );
      return false;
    } finally {
      if (completed) {
        try {
          if (metaFile.existsSync()) metaFile.deleteSync();
        } catch (e) {
          debugPrint('[RomDownloadService] Falha ao remover metadados: $e');
        }
      } else if (fellBack) {
        // Descarta apenas o que não é prefixo contíguo válido, preservando o
        // retome do stream único.
        try {
          raf.truncateSync(chunkDone[0]);
        } catch (e) {
          debugPrint('[RomDownloadService] Falha ao recortar .part: $e');
        }
        try {
          if (metaFile.existsSync()) metaFile.deleteSync();
        } catch (e) {
          debugPrint('[RomDownloadService] Falha ao remover metadados: $e');
        }
      }
      try {
        raf.closeSync();
      } catch (e) {
        debugPrint('[RomDownloadService] Falha ao fechar .part: $e');
      }
    }
  }

  /// Plataformas cujo conteúdo traz marcadores de disco confiáveis.
  ///
  /// Só elas entram na validação: cartuchos e formatos comprimidos (`.zip`,
  /// `.chd`, `.cso`...) não têm magic próprio e retornariam falsos positivos.
  static const Set<String> _discPlatformsWithContentMarkers = {
    'ps1',
    'ps2',
    'ps3',
    'psp',
    'gamecube',
    'wii',
    'dreamcast',
    'saturn',
  };

  /// Rejeita a ROM quando os bytes provam que ela é de outro console.
  ///
  /// Sem isso um resultado mal etiquetado do Archive.org (ex.: um `.iso` de
  /// PlayStation dentro de um item de "PC Engine", ou um ISO de PSP classificado
  /// como PS1 pelo tamanho) chega ao player e falha no core errado.
  /// Formatos sem marcadores ou quando o conteúdo bate, simplesmente segue.
  Future<void> _assertRomPlatformMatchesContent({
    required String resolvedPath,
    required EmulationGame game,
  }) async {
    final expected = game.platformSlug.toLowerCase();
    if (_isArcadePlatform(expected)) return;

    String? detected;
    try {
      detected = await RomPlatformDetector.sniffContent(resolvedPath);
    } catch (e) {
      debugPrint(
        '[RomDownloadService] Falha ao ler marcadores de ${game.name}: $e',
      );
      return;
    }
    if (detected == null || detected == expected) return;
    if (!_discPlatformsWithContentMarkers.contains(detected)) return;

    // GameCube e Wii são imagens do mesmo ecossistema Dolphin; não é erro.
    const dolphinFamily = {'wii', 'gamecube'};
    if (dolphinFamily.contains(expected) && dolphinFamily.contains(detected)) {
      return;
    }

    final spec = kRommPlatforms.cast<RommPlatformSpec?>().firstWhere(
      (p) => p!.slug == detected,
      orElse: () => null,
    );
    final detectedName = spec?.fullName ?? detected.toUpperCase();

    try {
      final mismatchFile = File(resolvedPath);
      if (await mismatchFile.exists()) {
        await mismatchFile.delete();
      }
    } catch (e) {
      debugPrint(
        '[RomDownloadService] Falha ao remover ROM com plataforma errada: $e',
      );
    }

    throw _NonRetryableDownloadException(
      'O arquivo baixado é de outro console: o catálogo pedia '
      '${game.platformName}, mas o conteúdo real é de $detectedName. '
      'Nada foi salvo — tente outra versão do jogo.',
    );
  }

  /// Executa o download real com HTTP Range, retry exponencial e verificação de CRC32.
  Future<({String path, int totalBytes, bool? crcVerified, String? warningMessage})?>
      _executeResilientDownload({
    required EmulationGame game,
    required CancelToken cancelToken,
    required bool Function() isCurrentOperation,
    required void Function(RomDownloadStatus status) notify,
  }) async {
    String? verifiedUrl = _verifiedDirectUrls[game.igdbId];
    String targetUrl = verifiedUrl ?? game.directRomUrl.trim();
    if (verifiedUrl == null &&
        (targetUrl.startsWith('retroapi://') || !targetUrl.startsWith('http'))) {
      final mirror = await _findUnlockedArchiveMirror(
        game: game,
        cancelToken: cancelToken,
      );
      if (mirror != null) {
        targetUrl = mirror;
      }
    }

    if (!targetUrl.startsWith('http')) {
      throw _NonRetryableDownloadException(
        'Nenhum mirror público válido encontrado para ${game.name} (${game.platformName}). Use Arquivo Local ou RomM.',
      );
    }

    final dir = await _romsDirectory();
    final isArcade = _isArcadePlatform(game.platformSlug);
    final minExpectedBytes = minBytesForPlatform(game.platformSlug);

    Future<({String path, int totalBytes, bool? crcVerified, String? warningMessage})>
        downloadUrlToPath(String url) async {
      String realExt = '';
      final urlPath = Uri.parse(url).path.toLowerCase();
      for (final ext in _romInnerExtensions) {
        if (urlPath.endsWith(ext)) {
          realExt = ext;
          break;
        }
      }
      if (realExt.isEmpty) {
        realExt = _defaultExtensionForPlatform(game.platformSlug, url);
      }

      String finalDestinationPath;
      if (isArcade) {
        final arcadeDir = Directory('${dir.path}/arcade_${game.igdbId}');
        if (!await arcadeDir.exists()) {
          await arcadeDir.create(recursive: true);
        }
        final canonicalName = _canonicalArcadeFileName(
          preferredSource: game.directRomUrl,
          fallbackUrl: url,
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
      final lowerDest = finalDestinationPath.toLowerCase();
      final existingArchiveFile = File(finalDestinationPath);
      bool reusedCompleteArchive = false;
      if (!isArcade &&
          (lowerDest.endsWith('.zip') || lowerDest.endsWith('.7z')) &&
          !await partFile.exists() &&
          await existingArchiveFile.exists() &&
          await existingArchiveFile.length() >= minExpectedBytes) {
        reusedCompleteArchive = await _hasValidArchiveHeader(
          existingArchiveFile,
          is7z: lowerDest.endsWith('.7z'),
        );
      }

      // Acelera o download abrindo várias conexões Range em paralelo. Falhou ou
      // não aplicável? Segue o fluxo de stream único de sempre, que continua do
      // byte em que o .paralelo parou.
      var parallelCompleted = reusedCompleteArchive;
      if (!parallelCompleted) {
        try {
          parallelCompleted = await _tryDownloadWithParallelChunks(
            url: url,
            partFile: partFile,
            game: game,
            cancelToken: cancelToken,
            isCurrentOperation: isCurrentOperation,
            notify: notify,
            minExpectedBytes: minExpectedBytes,
          );
        } on _ParallelUnavailableException {
          parallelCompleted = false;
        } on DioException catch (e) {
          if (cancelToken.isCancelled || !isCurrentOperation()) rethrow;
          parallelCompleted = false;
          debugPrint(
            '[RomDownloadService] Download paralelo abortado (${e.type}); seguindo em stream único.',
          );
        } catch (e) {
          parallelCompleted = false;
          debugPrint(
            '[RomDownloadService] Download paralelo indisponível ($e); seguindo em stream único.',
          );
        }
      }

      int attempt = 1;
      bool rangeResetDone = false;

      while (!parallelCompleted) {
        if (cancelToken.isCancelled || !isCurrentOperation()) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: url),
            reason: cancelToken.cancelError?.error,
          );
        }

        int existingBytes = 0;
        if (await partFile.exists()) {
          existingBytes = await partFile.length();
        }

        final rollingWindow = <_SpeedSample>[];
        int currentBytes = existingBytes;
        int expectedTotalBytes = game.estimatedSizeBytes > existingBytes
            ? game.estimatedSizeBytes
            : existingBytes;

        final headers = <String, String>{};
        if (existingBytes > 0) {
          headers['Range'] = 'bytes=$existingBytes-';
        }

        try {
          final response = await _dio.get<ResponseBody>(
            url,
            cancelToken: cancelToken,
            options: Options(
              responseType: ResponseType.stream,
              receiveTimeout: defaultReceiveTimeout,
              headers: headers,
              validateStatus: (s) => s != null && s >= 200 && s < 300,
            ),
          );

          final contentType =
              (response.headers.value('content-type') ?? '').toLowerCase();
          if (contentType.contains('text/html')) {
            throw const _NonRetryableDownloadException(
              'Mirror retornou página HTML em vez de ROM.',
            );
          }

          final statusCode = response.statusCode ?? 200;
          final isRangeAccepted = statusCode == 206;
          if (!isRangeAccepted) {
            currentBytes = 0;
          }

          if (isRangeAccepted) {
            final contentRange = response.headers.value('content-range');
            final match = contentRange == null
                ? null
                : RegExp(r'bytes\s+(\d+)-').firstMatch(contentRange);
            final rangeStart = match == null ? -1 : int.tryParse(match.group(1)!) ?? -1;
            if (rangeStart != existingBytes) {
              throw StateError(
                'Servidor ignorou Range: esperado $existingBytes, recebido $rangeStart.',
              );
            }
          }

          final contentLengthHeader = response.headers.value('content-length');
          var hasReliableTotal = false;
          if (contentLengthHeader != null) {
            final cl = int.tryParse(contentLengthHeader) ?? 0;
            if (cl > 0) {
              expectedTotalBytes = isRangeAccepted ? existingBytes + cl : cl;
              hasReliableTotal = true;
              if (!isRangeAccepted && cl < minExpectedBytes) {
                throw _NonRetryableDownloadException(
                  'Arquivo no servidor é pequeno demais (${(cl / 1024).toStringAsFixed(0)} KB) para ${game.platformName}. Provável manual/patch.',
                );
              }
            }
          }

          final stream = response.data?.stream;
          if (stream == null) {
            throw DioException(
              requestOptions: response.requestOptions,
              type: DioExceptionType.unknown,
              message: 'Resposta de stream vazia.',
            );
          }

          final sink = partFile.openWrite(
            mode: isRangeAccepted ? FileMode.append : FileMode.write,
          );
          DateTime lastUiUpdate = DateTime.now();

          try {
            await for (final chunk in stream) {
              if (cancelToken.isCancelled || !isCurrentOperation()) {
                throw DioException.requestCancelled(
                  requestOptions: response.requestOptions,
                  reason: cancelToken.cancelError?.error,
                );
              }
              sink.add(chunk);
              currentBytes += chunk.length;

              final now = DateTime.now();
              rollingWindow.add(_SpeedSample(now, chunk.length));
              rollingWindow.removeWhere(
                (s) => now.difference(s.time).inMilliseconds > 1500,
              );

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
          } finally {
            try {
              await sink.close();
            } catch (e) {
              debugPrint('[RomDownloadService] Falha ao fechar sink: $e');
            }
          }

          if (hasReliableTotal && expectedTotalBytes > 0) {
            final actualLength = await partFile.length();
            if (actualLength != expectedTotalBytes) {
              throw StateError(
                'Download truncado: $actualLength de $expectedTotalBytes bytes.',
              );
            }
          }

          break;
        } on DioException catch (e) {
          if (e.type == DioExceptionType.cancel || cancelToken.isCancelled) {
            rethrow;
          }

          final code = e.response?.statusCode;
          if (code == 416) {
            if (!rangeResetDone && await partFile.exists()) {
              rangeResetDone = true;
              debugPrint(
                '[RomDownloadService] HTTP 416 Range inválido para ${game.name}; resetando .part e tentando do zero.',
              );
              try {
                await partFile.delete();
              } catch (delErr) {
                debugPrint(
                  '[RomDownloadService] Falha ao limpar .part após HTTP 416: $delErr',
                );
              }
              continue;
            }
            throw _NonRetryableDownloadException(_friendlyDioMessage(e));
          }

          if (code == 401 || code == 403 || code == 404) {
            throw _NonRetryableDownloadException(_friendlyDioMessage(e));
          }

          final isRetryable = code == null ||
              code == 408 ||
              code == 429 ||
              (code >= 500 && code < 600);

          if (isRetryable && attempt < maxRetryAttempts) {
            debugPrint(
              '[RomDownloadService] Tentativa $attempt/$maxRetryAttempts falhou (${code ?? e.type}); tentando novamente.',
            );
            await _waitForRetryWithNetworkCheck(
              attempt: attempt,
              checkNetwork: code == null,
              cancelToken: cancelToken,
              isCurrentOperation: isCurrentOperation,
              currentBytes: currentBytes,
              expectedTotalBytes: expectedTotalBytes,
              notify: notify,
            );
            attempt++;
            continue;
          }

          throw StateError(_friendlyDioMessage(e));
        } on SocketException catch (e) {
          if (cancelToken.isCancelled || !isCurrentOperation()) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: cancelToken.cancelError?.error,
            );
          }
          if (attempt < maxRetryAttempts) {
            debugPrint(
              '[RomDownloadService] SocketException na tentativa $attempt/$maxRetryAttempts: $e',
            );
            await _waitForRetryWithNetworkCheck(
              attempt: attempt,
              checkNetwork: true,
              cancelToken: cancelToken,
              isCurrentOperation: isCurrentOperation,
              currentBytes: currentBytes,
              expectedTotalBytes: expectedTotalBytes,
              notify: notify,
            );
            attempt++;
            continue;
          }
          throw StateError(
            'Falha de rede durante a transferência da ROM. Tente novamente.',
          );
        } on HttpException catch (e) {
          if (cancelToken.isCancelled || !isCurrentOperation()) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: cancelToken.cancelError?.error,
            );
          }
          if (attempt < maxRetryAttempts) {
            debugPrint(
              '[RomDownloadService] HttpException na tentativa $attempt/$maxRetryAttempts: $e',
            );
            await _waitForRetryWithNetworkCheck(
              attempt: attempt,
              checkNetwork: true,
              cancelToken: cancelToken,
              isCurrentOperation: isCurrentOperation,
              currentBytes: currentBytes,
              expectedTotalBytes: expectedTotalBytes,
              notify: notify,
            );
            attempt++;
            continue;
          }
          throw StateError(
            'Falha de rede durante a transferência da ROM. Tente novamente.',
          );
        } on TimeoutException catch (e) {
          if (cancelToken.isCancelled || !isCurrentOperation()) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: cancelToken.cancelError?.error,
            );
          }
          if (attempt < maxRetryAttempts) {
            debugPrint(
              '[RomDownloadService] TimeoutException na tentativa $attempt/$maxRetryAttempts: $e',
            );
            await _waitForRetryWithNetworkCheck(
              attempt: attempt,
              checkNetwork: true,
              cancelToken: cancelToken,
              isCurrentOperation: isCurrentOperation,
              currentBytes: currentBytes,
              expectedTotalBytes: expectedTotalBytes,
              notify: notify,
            );
            attempt++;
            continue;
          }
          throw StateError(
            'Tempo esgotado na conexão com o servidor. Verifique sua internet e tente novamente.',
          );
        } on HandshakeException catch (e) {
          if (cancelToken.isCancelled || !isCurrentOperation()) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: url),
              reason: cancelToken.cancelError?.error,
            );
          }
          if (attempt < maxRetryAttempts) {
            debugPrint(
              '[RomDownloadService] HandshakeException na tentativa $attempt/$maxRetryAttempts: $e',
            );
            await _waitForRetryWithNetworkCheck(
              attempt: attempt,
              checkNetwork: true,
              cancelToken: cancelToken,
              isCurrentOperation: isCurrentOperation,
              currentBytes: currentBytes,
              expectedTotalBytes: expectedTotalBytes,
              notify: notify,
            );
            attempt++;
            continue;
          }
          throw StateError(
            'Falha de rede durante a transferência da ROM. Tente novamente.',
          );
        }
      }

      final File finalFile;
      final int downloadedLen;
      if (reusedCompleteArchive) {
        finalFile = existingArchiveFile;
        downloadedLen = await finalFile.length();
      } else {
        if (!await partFile.exists()) {
          throw const _NonRetryableDownloadException(
            'Arquivo baixado corrompido ou incompleto.',
          );
        }
        downloadedLen = await partFile.length();
        if (downloadedLen < minExpectedBytes) {
          await partFile.delete();
          throw _NonRetryableDownloadException(
            'Arquivo baixado inválido/pequeno demais (${(downloadedLen / 1024).toStringAsFixed(0)} KB) para ${game.platformName}.',
          );
        }
        finalFile = await partFile.rename(finalDestinationPath);
      }

      final expectedCrc = game.crc32.trim().toUpperCase();
      final checkCrc = _isValidCrc32Hex(expectedCrc);
      bool? crcVerified;
      String? warningMessage;
      String? zipCrc;

      if (checkCrc &&
          !isArcade &&
          (lowerDest.endsWith('.zip') || lowerDest.endsWith('.7z'))) {
        zipCrc = await LibraryStorageService.computeFileCrc32Hex(finalFile.path);
        if (zipCrc == expectedCrc) {
          crcVerified = true;
        }
      }

      String resolvedPath = finalFile.path;
      if (!isArcade &&
          (lowerDest.endsWith('.zip') || lowerDest.endsWith('.7z'))) {
        notify(
          RomDownloadStatus(
            state: RomActionState.downloading,
            progress: 0.99,
            downloadedBytes: downloadedLen,
            totalBytes: downloadedLen,
            speedLabel: 'Extraindo ROM...',
          ),
        );
        String? extracted;
        try {
          extracted = await extractAndPickRomFromArchive(
            archivePath: finalFile.path,
            extractDir: Directory('${dir.path}/game_${game.igdbId}'),
            platformSlug: game.platformSlug,
            deleteSourceOnSuccess: true,
            onProgress: (p, statusLabel) {
              notify(
                RomDownloadStatus(
                  state: RomActionState.downloading,
                  progress: (0.95 + p * 0.05).clamp(0.95, 0.995),
                  downloadedBytes: downloadedLen,
                  totalBytes: downloadedLen,
                  speedLabel: statusLabel,
                ),
              );
            },
          );
        } catch (extractErr) {
          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          throw _NonRetryableDownloadException(
            'Falha ao extrair ${game.name}: $extractErr',
          );
        }
        if (extracted == null) {
          if (await finalFile.exists()) {
            await finalFile.delete();
          }
          throw _NonRetryableDownloadException(
            'O pacote baixado não continha uma ROM válida de ${game.platformName}.',
          );
        }
        resolvedPath = extracted;
      }

      await _assertRomPlatformMatchesContent(
        resolvedPath: resolvedPath,
        game: game,
      );

      if (checkCrc && crcVerified != true) {
        final actualCrc =
            await LibraryStorageService.computeFileCrc32Hex(resolvedPath);
        if (actualCrc == expectedCrc) {
          crcVerified = true;
        } else {
          crcVerified = false;
          warningMessage =
              'CRC32 divergente do catálogo (esperado $expectedCrc, obtido $actualCrc).';
          debugPrint(
            '[RomDownloadService] Aviso CRC32 mismatch para "${game.name}": esperado=$expectedCrc, obtido=$actualCrc${zipCrc != null ? " (zip=$zipCrc)" : ""}.',
          );
        }
      }

      final installedBytes =
          await LibraryStorageService.resolveInstalledRomSizeBytes(
        resolvedPath,
        fallbackBytes: downloadedLen,
      );

      return (
        path: resolvedPath,
        totalBytes: installedBytes,
        crcVerified: crcVerified,
        warningMessage: warningMessage,
      );
    }

    try {
      return await downloadUrlToPath(targetUrl);
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) rethrow;
      if (verifiedUrl != null &&
          !cancelToken.isCancelled &&
          isCurrentOperation()) {
        final fallbackMirror = await _findUnlockedArchiveMirror(
          game: game,
          cancelToken: cancelToken,
        );
        if (fallbackMirror != null && fallbackMirror != targetUrl) {
          return await downloadUrlToPath(fallbackMirror);
        }
      }
      rethrow;
    }
  }

  String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '0 KB/s';
    if (bytesPerSec >= 1024 * 1024) {
      return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
    }
    return '${(bytesPerSec / 1024).toStringAsFixed(0)} KB/s';
  }

  static String _encodeArchivePath(String name) =>
      name.split('/').map(Uri.encodeComponent).join('/');

  /// Seleciona o melhor arquivo Archive.org para a plataforma, retornando nome,
  /// tamanho em bytes e CRC32, exigindo tamanho mínimo, extensão compatível
  /// e aderência ao título do jogo.
  static ({String name, int sizeBytes, String crc32})? pickBestArchiveFileEntry({
    required List<Map<String, dynamic>> files,
    required String platformSlug,
    required String gameTitle,
    String canonicalName = '',
    bool requireTitleMatch = true,
    bool requireNonZeroSize = false,
    bool allowRawBinFallback = false,
    bool rejectBetaAndProto = false,
    bool Function(String fileName, int sizeBytes)? extraFileFilter,
  }) {
    final baseAllowedExts = allowedExtensionsForPlatform(platformSlug);
    final allowedExts = allowRawBinFallback && !baseAllowedExts.contains('.bin')
        ? <String>[...baseAllowedExts, '.bin']
        : baseAllowedExts;
    final minBytes = minBytesForPlatform(platformSlug);
    final searchTarget = canonicalName.isNotEmpty ? canonicalName : gameTitle;
    final cleanTarget = EmulationGame.normalizeSearchText(
      searchTarget.replaceAll(RegExp(r'\([^)]*\)'), ' '),
    );
    final tokens = cleanTarget
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final numericTokens =
        tokens.where((t) => RegExp(r'^[0-9]+$').hasMatch(t)).toList();
    final wordTokens = tokens.where((t) => t.length >= 3).toList();
    final compactTarget = cleanTarget.replaceAll(' ', '');

    ({String name, int sizeBytes, String crc32})? bestEntry;
    int bestScore = -999999;

    for (final f in files) {
      final name = (f['name'] as String?) ?? '';
      if (name.isEmpty) continue;
      final isPrivate = f['private'] == 'true' || f['private'] == true;
      if (isPrivate) continue;
      if (isJunkArchiveEntry(name, gameTitle: gameTitle)) continue;
      if (rejectBetaAndProto &&
          isNonFullGameRelease(name, gameTitle: gameTitle)) {
        continue;
      }

      final lower = name.toLowerCase();
      final extIdx = allowedExts.indexWhere(lower.endsWith);
      if (extIdx < 0) continue;

      final sizeVal = int.tryParse('${f['size'] ?? ''}') ?? 0;
      if (requireNonZeroSize && sizeVal <= 0) continue;
      if (sizeVal > 0 && sizeVal < minBytes) continue;
      if (extraFileFilter != null && !extraFileFilter(name, sizeVal)) {
        continue;
      }

      final baseNoParens = EmulationGame.normalizeSearchText(
        lower
            .split('/')
            .last
            .replaceAll(RegExp(r'\.[^.]+$'), '')
            .replaceAll(RegExp(r'\([^)]*\)'), ' ')
            .replaceAll(RegExp(r'\[[^\]]*\]'), ' '),
      );
      final compactFile = baseNoParens.replaceAll(' ', '');

      if (requireTitleMatch) {
        bool matched = false;
        if (compactTarget.length >= 6 &&
            (compactFile == compactTarget ||
                compactFile.contains(compactTarget))) {
          matched = true;
        } else if (wordTokens.isNotEmpty) {
          final hitWords = wordTokens.where(baseNoParens.contains).length;
          final requiredHits = wordTokens.length <= 2 ? wordTokens.length : 2;
          final numbersOk = numericTokens.every(baseNoParens.contains);
          if (hitWords >= requiredHits && numbersOk) {
            matched = true;
          }
        }
        if (!matched) continue;
      }

      int score = (allowedExts.length - extIdx) * 100;
      if (compactFile == compactTarget) score += 250;
      if (wordTokens.isNotEmpty &&
          wordTokens.every(baseNoParens.contains) &&
          numericTokens.every(baseNoParens.contains)) {
        score += 120;
      }
      if (lower.contains('(usa)') || lower.contains('(world)')) {
        score += 120;
      } else if (lower.contains('(europe)')) {
        score += 90;
      } else if (lower.contains('(japan)') &&
          !searchTarget.toLowerCase().contains('japan')) {
        score -= 220;
      }
      if (lower.contains('[t-') ||
          lower.contains('hack') ||
          lower.contains('beta')) {
        score -= 180;
      }
      if (sizeVal == 0) {
        score -= 30;
      } else {
        score += (sizeVal / (100 * 1024 * 1024)).clamp(0, 20).round();
      }

      if (score > bestScore) {
        bestScore = score;
        bestEntry = (
          name: name,
          sizeBytes: sizeVal,
          crc32: ((f['crc32'] as String?) ?? '').toUpperCase(),
        );
      }
    }
    return bestEntry;
  }

  /// Seleciona o melhor arquivo Archive.org para a plataforma, exigindo tamanho mínimo,
  /// extensão compatível e aderência ao nome do jogo (evita manuais `_jp2.zip`, patches e faixas soltas).
  static String? pickBestArchiveFile({
    required List<Map<String, dynamic>> files,
    required String platformSlug,
    required String gameTitle,
    String canonicalName = '',
    bool requireTitleMatch = true,
  }) =>
      pickBestArchiveFileEntry(
        files: files,
        platformSlug: platformSlug,
        gameTitle: gameTitle,
        canonicalName: canonicalName,
        requireTitleMatch: requireTitleMatch,
      )?.name;

  /// Valida um dump de PS3 (pasta `PS3_GAME/USRDIR/EBOOT.BIN`, ISO descriptografada ou `.pkg`).
  ///
  /// Executa a verificação binária em [Isolate.run] para não travar a interface.
  static Future<Ps3DumpValidationResult> validatePs3DumpContent(
    String path,
  ) {
    return Isolate.run(() => _validatePs3DumpSync(path));
  }

  static Ps3DumpValidationResult _validatePs3DumpSync(String path) {
    try {
      final cleanPath = path.trim();
      if (cleanPath.isEmpty) {
        return const Ps3DumpValidationResult(
          isValid: false,
          errorMessage: 'Caminho do dump de PS3 inválido.',
        );
      }

      const ps3DumpTip =
          'Para gerar um dump válido a partir dos seus discos, use o próprio PS3 com CFW ou HEN e ferramentas como ManaGunZ, multiMAN ou IRISMAN — elas já criam ISO descriptografada ou pasta prontas para o RPCS3.';

      bool hasValidEbootMagic(File file) {
        if (!file.existsSync()) return false;
        final len = file.lengthSync();
        if (len < 16) return false;
        final raf = file.openSync(mode: FileMode.read);
        try {
          final hdr = raf.readSync(4);
          if (hdr.length < 4) return false;
          final isSelf = hdr[0] == 0x53 &&
              hdr[1] == 0x43 &&
              hdr[2] == 0x45 &&
              hdr[3] == 0x00; // SCE\0
          final isElf = hdr[0] == 0x7F &&
              hdr[1] == 0x45 &&
              hdr[2] == 0x4C &&
              hdr[3] == 0x46; // \x7FELF
          return isSelf || isElf;
        } finally {
          raf.closeSync();
        }
      }

      File? findEbootInDirectory(Directory root, {int maxDepth = 3}) {
        final directCandidates = [
          File('${root.path}/PS3_GAME/USRDIR/EBOOT.BIN'),
          File('${root.path}/USRDIR/EBOOT.BIN'),
          File('${root.path}/EBOOT.BIN'),
        ];
        for (final c in directCandidates) {
          if (c.existsSync()) return c;
        }
        if (maxDepth <= 0) return null;
        try {
          for (final entity in root.listSync(followLinks: false)) {
            if (entity is Directory) {
              final found = findEbootInDirectory(entity, maxDepth: maxDepth - 1);
              if (found != null) return found;
            }
          }
        } catch (_) {}
        return null;
      }

      ({String? title, String? titleId}) parseParamSfo(File sfoFile) {
        if (!sfoFile.existsSync()) return (title: null, titleId: null);
        try {
          final bytes = sfoFile.readAsBytesSync();
          if (bytes.length < 20 ||
              bytes[0] != 0x00 ||
              bytes[1] != 0x50 ||
              bytes[2] != 0x53 ||
              bytes[3] != 0x46) {
            return (title: null, titleId: null);
          }
          final bd = ByteData.sublistView(bytes);
          final keyTableOffset = bd.getUint32(8, Endian.little);
          final dataTableOffset = bd.getUint32(12, Endian.little);
          final count = bd.getUint32(16, Endian.little);
          String? title;
          String? titleId;
          for (var i = 0; i < count && 20 + i * 16 + 16 <= bytes.length; i++) {
            final base = 20 + i * 16;
            final keyOffset = bd.getUint16(base, Endian.little);
            final dataFmt = bd.getUint16(base + 2, Endian.little);
            final dataLen = bd.getUint32(base + 4, Endian.little);
            final dataOffset = bd.getUint32(base + 12, Endian.little);
            final kStart = keyTableOffset + keyOffset;
            if (kStart >= bytes.length) continue;
            var kEnd = kStart;
            while (kEnd < bytes.length && bytes[kEnd] != 0) {
              kEnd++;
            }
            final key = utf8.decode(bytes.sublist(kStart, kEnd), allowMalformed: true);
            if (dataFmt == 0x0204 &&
                dataTableOffset + dataOffset + dataLen <= bytes.length) {
              final rawVal = bytes.sublist(
                dataTableOffset + dataOffset,
                dataTableOffset + dataOffset + dataLen,
              );
              final zeroIdx = rawVal.indexOf(0);
              final sliced = zeroIdx >= 0 ? rawVal.sublist(0, zeroIdx) : rawVal;
              final val = utf8.decode(sliced, allowMalformed: true).trim();
              if (key == 'TITLE' && val.isNotEmpty) title = val;
              if (key == 'TITLE_ID' && val.isNotEmpty) titleId = val;
            }
          }
          return (title: title, titleId: titleId);
        } catch (_) {
          return (title: null, titleId: null);
        }
      }

      if (FileSystemEntity.isDirectorySync(cleanPath)) {
        final dir = Directory(cleanPath);
        final eboot = findEbootInDirectory(dir);
        if (eboot == null) {
          return const Ps3DumpValidationResult(
            isValid: false,
            errorMessage:
                'Pasta inválida: não foi encontrado "PS3_GAME/USRDIR/EBOOT.BIN". $ps3DumpTip',
          );
        }
        if (!hasValidEbootMagic(eboot)) {
          return const Ps3DumpValidationResult(
            isValid: false,
            errorMessage:
                'O arquivo PS3_GAME/USRDIR/EBOOT.BIN encontrado está corrompido ou criptografado (não possui cabeçalho SELF/ELF válido). $ps3DumpTip',
          );
        }
        final ps3GameDir = eboot.parent.parent;
        final sfo = parseParamSfo(File('${ps3GameDir.path}/PARAM.SFO'));
        return Ps3DumpValidationResult(
          isValid: true,
          resolvedRomPath: eboot.path,
          gameTitle: sfo.title,
          titleId: sfo.titleId,
          dumpFormat: 'folder',
        );
      }

      final file = File(cleanPath);
      if (!file.existsSync()) {
        return const Ps3DumpValidationResult(
          isValid: false,
          errorMessage: 'Arquivo de dump de PS3 não encontrado no dispositivo.',
        );
      }

      final lower = cleanPath.replaceAll('\\', '/').toLowerCase();
      final baseName = lower.split('/').last;

      // Caso o usuário selecione EBOOT.BIN, PS3_DISC.SFB ou PARAM.SFO dentro de PS3_GAME
      if (baseName == 'eboot.bin' ||
          baseName == 'ps3_disc.sfb' ||
          baseName == 'param.sfo') {
        Directory searchRoot = file.parent;
        if (lower.endsWith('/usrdir/eboot.bin')) {
          searchRoot = file.parent.parent;
        }
        if (baseName == 'param.sfo' &&
            searchRoot.path.replaceAll('\\', '/').toLowerCase().endsWith('/ps3_game')) {
          searchRoot = searchRoot;
        }
        final eboot = baseName == 'eboot.bin'
            ? file
            : findEbootInDirectory(searchRoot, maxDepth: 2);
        if (eboot == null) {
          return const Ps3DumpValidationResult(
            isValid: false,
            errorMessage:
                'Estrutura PS3_GAME/USRDIR/EBOOT.BIN incompleta na pasta selecionada. $ps3DumpTip',
          );
        }
        if (!hasValidEbootMagic(eboot)) {
          return const Ps3DumpValidationResult(
            isValid: false,
            errorMessage:
                'EBOOT.BIN inválido ou criptografado (cabeçalho esperado: SCE\\0 ou ELF). $ps3DumpTip',
          );
        }
        final ps3GameDir = eboot.parent.parent;
        final sfo = parseParamSfo(File('${ps3GameDir.path}/PARAM.SFO'));
        return Ps3DumpValidationResult(
          isValid: true,
          resolvedRomPath: eboot.path,
          gameTitle: sfo.title,
          titleId: sfo.titleId,
          dumpFormat: 'folder',
        );
      }

      if (lower.endsWith('.pkg')) {
        final raf = file.openSync(mode: FileMode.read);
        try {
          final hdr = raf.readSync(4);
          final isPkg = hdr.length >= 4 &&
              hdr[0] == 0x7F &&
              hdr[1] == 0x50 &&
              hdr[2] == 0x4B &&
              hdr[3] == 0x47;
          if (!isPkg) {
            return const Ps3DumpValidationResult(
              isValid: false,
              errorMessage:
                  'Arquivo .pkg de PS3 inválido (assinatura \\x7FPKG ausente).',
            );
          }
          return Ps3DumpValidationResult(
            isValid: true,
            resolvedRomPath: file.path,
            dumpFormat: 'pkg',
          );
        } finally {
          raf.closeSync();
        }
      }

      if (lower.endsWith('.iso') || lower.endsWith('.img')) {
        final totalLen = file.lengthSync();
        if (totalLen < 64 * 1024) {
          return const Ps3DumpValidationResult(
            isValid: false,
            errorMessage: 'A ISO de PS3 está incompleta ou pequena demais.',
          );
        }
        final raf = file.openSync(mode: FileMode.read);
        try {
          final scanLen = totalLen < 16 * 1024 * 1024 ? totalLen : 16 * 1024 * 1024;
          final scanBytes = raf.readSync(scanLen);
          final textScan = String.fromCharCodes(scanBytes);
          final hasPs3Marker = textScan.contains('PS3_DISC.SFB') ||
              textScan.contains('PS3_GAME') ||
              textScan.contains('PLAYSTATION3') ||
              textScan.contains('PS3VOLUME');
          if (!hasPs3Marker) {
            return const Ps3DumpValidationResult(
              isValid: false,
              errorMessage:
                  'Esta imagem ISO não possui estrutura de disco PS3 (PS3_DISC.SFB / PS3_GAME). $ps3DumpTip',
            );
          }

          // Localiza o registro ISO9660 do arquivo EBOOT.BIN dentro dos primeiros 16 MB
          int? ebootLba;
          int? ebootSize;
          final patterns = <List<int>>[
            ascii.encode('EBOOT.BIN;1'),
            ascii.encode('EBOOT.BIN'),
          ];
          for (final pat in patterns) {
            for (var i = 33; i <= scanBytes.length - pat.length; i++) {
              var match = true;
              for (var j = 0; j < pat.length; j++) {
                if (scanBytes[i + j] != pat[j]) {
                  match = false;
                  break;
                }
              }
              if (!match) continue;
              // Em um directory record ISO9660:
              // recStart + 32 = file identifier length
              // recStart + 33 = file identifier
              // recStart + 2..5 = Extent LBA (uint32 LE)
              // recStart + 10..13 = Data Length (uint32 LE)
              final nameLen = scanBytes[i - 1];
              if (nameLen == pat.length ||
                  (nameLen >= 9 && nameLen <= 15 && scanBytes[i - 1] >= pat.length)) {
                final recStart = i - 33;
                if (recStart >= 0 && recStart + 33 + nameLen <= scanBytes.length) {
                  final bd = ByteData.sublistView(scanBytes);
                  final lba = bd.getUint32(recStart + 2, Endian.little);
                  final size = bd.getUint32(recStart + 10, Endian.little);
                  if (lba > 0 && lba * 2048 < totalLen && size > 0) {
                    ebootLba = lba;
                    ebootSize = size;
                    break;
                  }
                }
              }
            }
            if (ebootLba != null) break;
          }

          if (ebootLba == null || ebootSize == null || ebootLba <= 0) {
            return const Ps3DumpValidationResult(
              isValid: false,
              errorMessage:
                  'Não foi possível localizar EBOOT.BIN nesta ISO de PS3. $ps3DumpTip',
            );
          }
          final offset = ebootLba * 2048;
          if (offset + 4 > totalLen) {
            return const Ps3DumpValidationResult(
              isValid: false,
              errorMessage:
                  'EBOOT.BIN fora dos limites da ISO de PS3. $ps3DumpTip',
            );
          }
          raf.setPositionSync(offset);
          final hdr = raf.readSync(4);
          final isDecryptedSelf = hdr.length >= 4 &&
              ((hdr[0] == 0x53 &&
                      hdr[1] == 0x43 &&
                      hdr[2] == 0x45 &&
                      hdr[3] == 0x00) ||
                  (hdr[0] == 0x7F &&
                      hdr[1] == 0x45 &&
                      hdr[2] == 0x4C &&
                      hdr[3] == 0x46));
          if (!isDecryptedSelf) {
            return const Ps3DumpValidationResult(
              isValid: false,
              errorMessage:
                  'Esta ISO de PS3 está criptografada (Redump bruto) e não pode rodar no RPCS3. $ps3DumpTip',
            );
          }

          return Ps3DumpValidationResult(
            isValid: true,
            resolvedRomPath: file.path,
            dumpFormat: 'iso',
          );
        } finally {
          raf.closeSync();
        }
      }

      return const Ps3DumpValidationResult(
        isValid: false,
        errorMessage:
            'Formato não reconhecido para dump de PS3. Envie a pasta do jogo (PS3_GAME/USRDIR/EBOOT.BIN), ISO já descriptografada ou arquivo .zip / .7z.',
      );
    } catch (e) {
      return Ps3DumpValidationResult(
        isValid: false,
        errorMessage: 'Erro ao validar dump de PS3: $e',
      );
    }
  }

  /// Extrai um arquivo `.zip` ou `.7z` em [Isolate] dedicado reportando progresso real
  /// e retorna o caminho da ROM principal válida para [platformSlug], ou `null`.
  static Future<String?> extractAndPickRomFromArchive({
    required String archivePath,
    required Directory extractDir,
    required String platformSlug,
    void Function(double progress, String statusLabel)? onProgress,
    bool deleteSourceOnSuccess = false,
  }) async {
    try {
      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      await extractDir.create(recursive: true);

      onProgress?.call(0.02, 'Preparando extração...');

      final receivePort = ReceivePort();
      final lowerArchive = archivePath.toLowerCase();
      final is7z = lowerArchive.endsWith('.7z');
      final completer = Completer<List<String>>();

      late final StreamSubscription<dynamic> sub;
      sub = receivePort.listen((message) {
        if (message is Map) {
          final type = message['type'];
          if (type == 'progress') {
            final p = (message['progress'] as num?)?.toDouble() ?? 0.0;
            final entryName = (message['entryName'] as String?) ?? '';
            final pct = (p * 100).clamp(0, 100).toStringAsFixed(0);
            final label = entryName.isNotEmpty
                ? 'Extraindo $entryName ($pct%)...'
                : 'Extraindo pacote ($pct%)...';
            onProgress?.call(p.clamp(0.0, 0.96), label);
          } else if (type == 'done') {
            final files = (message['files'] as List<dynamic>? ?? const [])
                .map((e) => e.toString())
                .toList();
            if (!completer.isCompleted) completer.complete(files);
          } else if (type == 'error') {
            final err = (message['message'] as String?) ??
                'Falha desconhecida na extração.';
            if (!completer.isCompleted) {
              completer.completeError(StateError(err));
            }
          }
        }
      });

      final extractPath = extractDir.path;
      await Isolate.spawn<_ArchiveIsolateArgs>(
        _extractArchiveWorkerEntry,
        _ArchiveIsolateArgs(
          sendPort: receivePort.sendPort,
          archivePath: archivePath,
          extractPath: extractPath,
          is7z: is7z,
          platformSlug: platformSlug,
        ),
      );

      final extractedPaths = await completer.future;
      await sub.cancel();
      receivePort.close();

      onProgress?.call(0.97, 'Validando conteúdo extraído...');

      int largestDataBytes = 0;
      for (final filePath in extractedPaths) {
        final f = File(filePath);
        if (!await f.exists()) continue;
        final lower = filePath.toLowerCase();
        if (!lower.endsWith('.cue') &&
            !lower.endsWith('.m3u') &&
            !lower.endsWith('.sbi')) {
          final len = await f.length();
          if (len > largestDataBytes) largestDataBytes = len;
        }
      }

      var picked = pickPreferredExtractedRom(
        extractedPaths,
        platformSlug: platformSlug,
      );

      // Para PS3 em .zip/.7z, confere se o dump extraído é realmente válido
      if (platformSlug.toLowerCase() == 'ps3') {
        final ps3Validation = await validatePs3DumpContent(
          picked ?? extractDir.path,
        );
        if (!ps3Validation.isValid) {
          if (await extractDir.exists()) {
            await extractDir.delete(recursive: true);
          }
          throw StateError(
            ps3Validation.errorMessage ??
                'O pacote não contém um dump válido de PS3.',
          );
        }
        picked = ps3Validation.resolvedRomPath ?? picked;
      }

      if (picked != null &&
          (platformSlug.toLowerCase() == 'ps3' ||
              largestDataBytes >= minBytesForPlatform(platformSlug))) {
        if (deleteSourceOnSuccess) {
          final arcFile = File(archivePath);
          if (await arcFile.exists()) {
            await arcFile.delete();
          }
        }
        final pickedIsZip = picked.toLowerCase().endsWith('.zip');
        for (final p in extractedPaths) {
          if (p == picked) continue;
          final entity = File(p);
          final baseLower = _basename(p).toLowerCase();
          final isTemp =
              baseLower.endsWith('.tmp') || baseLower.contains('.tmp_');
          final isResidualArchive =
              !pickedIsZip && _isCompressedArchiveName(baseLower);
          if (isTemp || (isResidualArchive && baseLower != 'neogeo.zip')) {
            try {
              if (await entity.exists()) {
                await entity.delete();
              }
            } catch (_) {}
          }
        }
        if (!pickedIsZip) {
          final gameMatch =
              _gameFolderRegex.firstMatch(_basename(extractDir.path));
          final gameId = gameMatch?.group(1);
          if (gameId != null) {
            try {
              final siblingPrefix = 'rom_${gameId}_';
              final parentDir = extractDir.parent;
              if (await parentDir.exists()) {
                await for (final sibling
                    in parentDir.list(followLinks: false)) {
                  if (sibling is! File || sibling.path == picked) continue;
                  final baseLower = _basename(sibling.path).toLowerCase();
                  if (baseLower.startsWith(siblingPrefix) &&
                      _isCompressedArchiveName(baseLower) &&
                      baseLower != 'neogeo.zip') {
                    await sibling.delete();
                  }
                }
              }
            } catch (_) {}
          }
        }
        onProgress?.call(1.0, 'Conteúdo validado!');
        return picked;
      }

      if (await extractDir.exists()) {
        await extractDir.delete(recursive: true);
      }
      return null;
    } catch (e) {
      debugPrint(
        '[RomDownloadService] Falha ao extrair arquivo $archivePath: $e',
      );
      try {
        if (await extractDir.exists()) {
          await extractDir.delete(recursive: true);
        }
      } catch (cleanupErr) {
        debugPrint(
          '[RomDownloadService] Falha ao remover pasta de extração $extractDir: $cleanupErr',
        );
      }
      if (e is StateError) rethrow;
      return null;
    }
  }

  /// Extrai um arquivo `.zip` em streaming para [extractDir] preservando `.cue`/`.bin`
  /// e retorna o caminho da ROM principal válida para [platformSlug], ou `null`.
  static Future<String?> extractAndPickRomFromZip({
    required String zipPath,
    required Directory extractDir,
    required String platformSlug,
    void Function(double progress, String statusLabel)? onProgress,
  }) =>
      extractAndPickRomFromArchive(
        archivePath: zipPath,
        extractDir: extractDir,
        platformSlug: platformSlug,
        onProgress: onProgress,
        deleteSourceOnSuccess: true,
      );

  Future<String?> _findUnlockedArchiveMirror({
    required EmulationGame game,
    required CancelToken cancelToken,
  }) async {
    String? expectedArchiveFile;
    final rawDirect = game.directRomUrl.trim();
    if (rawDirect.isNotEmpty) {
      final clean = rawDirect.split('?').first.split('#').first;
      final last = Uri.decodeComponent(clean.split('/').last).toLowerCase();
      if (last.endsWith('.zip') || last.endsWith('.7z')) {
        expectedArchiveFile = last;
      }
    }

    final isArcade = _isArcadePlatform(game.platformSlug);
    String? canonicalFbneoZip;
    if (isArcade) {
      final canonical = resolveCanonicalFbneoParent(
        expectedArchiveFile ?? '',
        gameTitle: game.name,
      );
      if (canonical != null) {
        canonicalFbneoZip = '${canonical.parentStem}.zip';
      }
    }

    // 1. Tenta acervo curado por plataforma (1G1R / ps1lollo / Hearto / NeoGeo / FBNeo)
    final collections = _collectionsForPlatform(game.platformSlug);
    String? fallbackCollectionUrl;
    for (final collection in collections) {
      if (cancelToken.isCancelled) {
        throw DioException.requestCancelled(
          requestOptions: RequestOptions(path: 'https://archive.org/metadata/$collection'),
          reason: cancelToken.cancelError?.error,
        );
      }
      try {
        final metaRes = await _dio
            .get<Map<String, dynamic>>(
              'https://archive.org/metadata/$collection',
              cancelToken: cancelToken,
              options: Options(receiveTimeout: defaultReceiveTimeout),
            )
            .timeout(const Duration(seconds: 10));

        final files = ((metaRes.data?['files'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();

        // Em arcade FBNeo, prioriza o romset parent non-merged completo antes do clone.
        final candidateTargets = <String>[
          if (canonicalFbneoZip != null) canonicalFbneoZip,
          if (expectedArchiveFile != null &&
              expectedArchiveFile != canonicalFbneoZip)
            expectedArchiveFile,
        ];
        for (final targetLower in candidateTargets) {
          final targetStem = targetLower.replaceAll(RegExp(r'\.(zip|7z)$'), '');
          for (final f in files) {
            final name = (f['name'] as String?) ?? '';
            final lower = name.toLowerCase();
            final isPrivate = f['private'] == 'true' || f['private'] == true;
            if (isPrivate) continue;
            if (lower == targetLower ||
                lower.endsWith('/$targetLower') ||
                lower == '$targetStem.zip' ||
                lower == '$targetStem.7z' ||
                lower.endsWith('/$targetStem.7z')) {
              return 'https://archive.org/download/$collection/${_encodeArchivePath(name)}';
            }
          }
        }

        final matched = pickBestArchiveFile(
          files: files,
          platformSlug: game.platformSlug,
          gameTitle: game.name,
          canonicalName: game.canonicalNoIntroName,
          requireTitleMatch: true,
        );
        if (matched != null) {
          final url =
              'https://archive.org/download/$collection/${_encodeArchivePath(matched)}';
          final lowerMatched = matched.toLowerCase();
          final looksLikeRegionalOrHack = lowerMatched.contains('[t-') ||
              (lowerMatched.contains('(japan)') &&
                  !game.canonicalNoIntroName.toLowerCase().contains('japan'));
          if (!looksLikeRegionalOrHack) {
            return url;
          }
          fallbackCollectionUrl ??= url;
        }
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        debugPrint(
          '[RomDownloadService] Archive collection HTTP error ($collection): ${e.response?.statusCode}',
        );
      } catch (e) {
        debugPrint(
          '[RomDownloadService] Archive collection lookup error ($collection): $e',
        );
      }
    }
    if (fallbackCollectionUrl != null) {
      return fallbackCollectionUrl;
    }

    final effectiveExpectedArchive = canonicalFbneoZip ?? expectedArchiveFile;
    final expectedStem = effectiveExpectedArchive?.replaceAll(
      RegExp(r'\.(zip|7z)$'),
      '',
    );

    // 2. Busca dinâmica inteligente no Archive.org com validação de tamanho/extensão
    try {
      final platLower = game.platformSlug.trim().toLowerCase();
      final searchQueries = isArcade
          ? <String>[
              if (expectedStem != null && expectedStem.isNotEmpty) expectedStem,
              if (game.canonicalNoIntroName.isNotEmpty)
                game.canonicalNoIntroName,
              game.name,
            ]
          : <String>[
              if (game.platformName.trim().isNotEmpty)
                '${game.name} ${game.platformName}',
              if (game.canonicalNoIntroName.isNotEmpty &&
                  game.canonicalNoIntroName != game.name)
                game.canonicalNoIntroName,
              game.name,
            ];

      final nonArcadePlatformPattern = RegExp(
        r'\b(dreamcast|playstation|psx|ps1|ps2|ps3|psp|gamecube|wii|3ds|nds|gba|snes|nes|n64|switch|xbox|dos|windows|pc\s*port|mugen)\b',
        caseSensitive: false,
      );
      final pcOrOtherStorePattern = RegExp(
        r'\b(mugen|clean\s*steam\s*files|csf|xbox|pc\s*version|repack|fitgirl|dodi|codex|skidrow|plaza|gog\s*games|ost|soundtrack|ios\s*ipa)\b',
        caseSensitive: false,
      );

      for (final query in searchQueries) {
        if (cancelToken.isCancelled) {
          throw DioException.requestCancelled(
            requestOptions: RequestOptions(path: 'https://archive.org/advancedsearch.php'),
            reason: cancelToken.cancelError?.error,
          );
        }
        final clean = query
            .replaceAll(RegExp(r'\([^)]*\)'), '')
            .replaceAll(RegExp(r'[^a-zA-Z0-9 ]'), ' ')
            .trim();
        if (clean.isEmpty) continue;

        final res = await _dio
            .get<Map<String, dynamic>>(
              'https://archive.org/advancedsearch.php',
              cancelToken: cancelToken,
              options: Options(receiveTimeout: defaultReceiveTimeout),
              queryParameters: {
                'q':
                    'title:("$clean") AND mediatype:(software) AND NOT access-restricted-item:true',
                'fl[]': ['identifier', 'title'],
                'rows': '10',
                'page': '1',
                'output': 'json',
              },
            )
            .timeout(const Duration(seconds: 10));

        final docs = (res.data?['response'] as Map<String, dynamic>?)?['docs']
                as List<dynamic>? ??
            const [];
        final docsTyped = docs.whereType<Map<String, dynamic>>().toList();

        for (final doc in docsTyped) {
          if (cancelToken.isCancelled) {
            throw DioException.requestCancelled(
              requestOptions: RequestOptions(path: 'https://archive.org/metadata'),
              reason: cancelToken.cancelError?.error,
            );
          }
          final identifier = doc['identifier'] as String?;
          final docTitle = (doc['title'] as String?) ?? '';
          if (identifier == null || identifier.isEmpty) continue;
          if (isJunkArchiveEntry(docTitle, gameTitle: game.name) ||
              isJunkArchiveEntry(identifier, gameTitle: game.name)) {
            continue;
          }
          if (pcOrOtherStorePattern.hasMatch(docTitle) ||
              pcOrOtherStorePattern.hasMatch(identifier)) {
            continue;
          }
          if (isArcade &&
              (nonArcadePlatformPattern.hasMatch(docTitle) ||
                  nonArcadePlatformPattern.hasMatch(identifier))) {
            continue;
          }
          if (!isArcade &&
              (platLower == 'ps3' || platLower == 'wii' || platLower == 'ps2') &&
              (docTitle.toLowerCase().contains('windows') ||
                  docTitle.toLowerCase().contains('pc games'))) {
            continue;
          }
          try {
            final metaRes = await _dio
                .get<Map<String, dynamic>>(
                  'https://archive.org/metadata/$identifier',
                  cancelToken: cancelToken,
                  options: Options(receiveTimeout: defaultReceiveTimeout),
                )
                .timeout(const Duration(seconds: 7));

            final isRestricted =
                metaRes.data?['metadata']?['access-restricted-item'] == 'true';
            if (isRestricted) continue;

            final files =
                ((metaRes.data?['files'] as List<dynamic>?) ?? const [])
                    .whereType<Map<String, dynamic>>()
                    .toList();

            if (isArcade && effectiveExpectedArchive != null) {
              final targetLower = effectiveExpectedArchive;
              final targetStem = expectedStem ?? '';
              final minArcadeBytes = minBytesForPlatform(game.platformSlug);
              for (final f in files) {
                final name = (f['name'] as String?) ?? '';
                if (name.isEmpty) continue;
                final isPrivate = f['private'] == 'true' || f['private'] == true;
                if (isPrivate) continue;
                if (isJunkArchiveEntry(name, gameTitle: game.name)) continue;
                final sizeVal = int.tryParse('${f['size'] ?? ''}') ?? 0;
                if (sizeVal > 0 && sizeVal < minArcadeBytes) continue;
                final lower = name.toLowerCase();
                if (lower == targetLower ||
                    lower.endsWith('/$targetLower') ||
                    (targetStem.isNotEmpty &&
                        (lower == '$targetStem.zip' ||
                            lower == '$targetStem.7z' ||
                            lower.endsWith('/$targetStem.zip') ||
                            lower.endsWith('/$targetStem.7z')))) {
                  return 'https://archive.org/download/$identifier/${_encodeArchivePath(name)}';
                }
              }
            }

            final best = pickBestArchiveFileEntry(
              files: files,
              platformSlug: game.platformSlug,
              gameTitle: game.name,
              canonicalName: game.canonicalNoIntroName,
              requireTitleMatch: isArcade,
              requireNonZeroSize: true,
              rejectBetaAndProto: true,
              extraFileFilter: isArcade
                  ? (fileName, _) {
                      final lower = fileName.toLowerCase();
                      if (!lower.endsWith('.zip') && !lower.endsWith('.7z')) {
                        return false;
                      }
                      return !nonArcadePlatformPattern.hasMatch(lower);
                    }
                  : null,
            )?.name;
            if (best != null) {
              return 'https://archive.org/download/$identifier/${_encodeArchivePath(best)}';
            }
          } on DioException catch (e) {
            if (e.type == DioExceptionType.cancel) rethrow;
            debugPrint(
              '[RomDownloadService] Archive mirror metadata error ($identifier): ${e.response?.statusCode}',
            );
          } catch (e) {
            debugPrint(
              '[RomDownloadService] Archive mirror parse error ($identifier): $e',
            );
          }
        }
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      debugPrint(
        '[RomDownloadService] Archive mirror search HTTP error: ${e.response?.statusCode}',
      );
    } catch (e) {
      debugPrint('[RomDownloadService] Archive mirror search error: $e');
    }
    return null;
  }

  /// Resolve o tamanho real em bytes de uma ROM remota quando o catálogo
  /// não trouxe `size` (ex.: `Tam. n/d` no Wii/GameCube/PS3).
  Future<int> resolveRealRomSizeBytes(EmulationGame game) async {
    if (game.estimatedSizeBytes > 0) return game.estimatedSizeBytes;
    if (game.directRomUrl.startsWith('external://')) return 0;

    final token = CancelToken();
    try {
      var targetUrl = _verifiedDirectUrls[game.igdbId] ?? game.directRomUrl.trim();
      if (!targetUrl.startsWith('http')) {
        final mirror = await _findUnlockedArchiveMirror(
          game: game,
          cancelToken: token,
        );
        if (mirror != null) targetUrl = mirror;
      }
      if (!targetUrl.startsWith('http')) return 0;

      // Consulta metadata do Archive.org diretamente se for URL download/
      final uri = Uri.tryParse(targetUrl);
      if (uri != null &&
          uri.host.endsWith('archive.org') &&
          uri.pathSegments.length >= 3 &&
          uri.pathSegments.first == 'download') {
        final ident = uri.pathSegments[1];
        final relPath =
            uri.pathSegments.sublist(2).map(Uri.decodeComponent).join('/');
        try {
          final metaRes = await _dio
              .get<Map<String, dynamic>>(
                'https://archive.org/metadata/$ident',
                cancelToken: token,
                options: Options(receiveTimeout: const Duration(seconds: 8)),
              )
              .timeout(const Duration(seconds: 8));
          final files =
              (metaRes.data?['files'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>();
          for (final f in files) {
            final fname = (f['name'] as String?) ?? '';
            if (fname == relPath || fname.toLowerCase() == relPath.toLowerCase()) {
              final sz = int.tryParse('${f['size'] ?? ''}') ?? 0;
              if (sz > 0) return sz;
            }
          }
        } catch (_) {}
      }

      final headRes = await _dio
          .head<void>(
            targetUrl,
            cancelToken: token,
            options: Options(
              followRedirects: true,
              validateStatus: (s) => s != null && s >= 200 && s < 400,
              receiveTimeout: const Duration(seconds: 8),
            ),
          )
          .timeout(const Duration(seconds: 8));
      final cl = int.tryParse(headRes.headers.value('content-length') ?? '') ?? 0;
      if (cl > 0) return cl;
    } catch (_) {}
    return 0;
  }

  static List<String> collectionsForPlatform(String platformSlug) {
    switch (platformSlug.toLowerCase()) {
      case 'ps1':
      case 'psx':
        return const [
          'ps1lollo',
          '2024-sony-playstation-usa-hearto-1g1r-collection',
        ];
      case 'psp':
        return const [
          'psp-rom-89741837940134',
        ];
      case 'ps2':
        return const [
          'playstation2_essentials',
        ];
      case 'gamecube':
        return const [
          'GameCube_rvz-english',
        ];
      case 'wii':
        return const [
          'Wii_ISO',
        ];
      case '3ds':
        return const [
          '20260424-140852',
        ];
      case 'dreamcast':
        return const [
          'DreamcastCHD2020_0-O',
          'DreamcastCHD2020_P-Z',
          'Sega_Dreamcast-Top',
        ];
      case 'saturn':
        return const [
          'SSCHD-Arquivista',
        ];
      case 'pce':
        return const [
          'turbografx-16-romset-us',
        ];
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
        return const ['neo-geo-mvs-romset', 'fbneo-parent', 'svcpcb.7z'];
      case 'cps1':
      case 'cps2':
        return const ['fbneo-parent', 'finalburn-neo-fbneo_20260810'];
      case 'mame':
        return const [
          'fbneo-parent',
          'finalburn-neo-fbneo_20260810',
          'svcpcb.7z',
        ];
      default:
        return const [];
    }
  }

  List<String> _collectionsForPlatform(String platformSlug) =>
      collectionsForPlatform(platformSlug);

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
    String? extractFile(String candidate) {
      final raw = candidate.trim();
      if (raw.isEmpty) return null;
      final clean = raw.split('?').first.split('#').first;
      final slashIdx = clean.lastIndexOf('/');
      final last = slashIdx >= 0 ? clean.substring(slashIdx + 1) : clean;
      final decoded = Uri.decodeComponent(last);
      final lower = decoded.toLowerCase();
      if (lower.endsWith('.zip') || lower.endsWith('.7z')) {
        final safe = decoded.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
        if (safe.isNotEmpty) return safe;
      }
      return null;
    }

    // Se a URL real resolvida já entrega um romset parent canônico do FBNeo
    // (ex.: `fbneo-parent/.../sfa3.zip`), nunca sobrescrevê-la com o nome de clone.
    final fallbackFile = extractFile(fallbackUrl);
    final preferredFile = extractFile(preferredSource);
    if (fallbackFile != null) {
      final fbResolved = resolveCanonicalFbneoParent(fallbackFile);
      final fbStem =
          fallbackFile.replaceAll(RegExp(r'\.(zip|7z)$', caseSensitive: false), '').toLowerCase();
      if (fbResolved != null && fbResolved.parentStem == fbStem) {
        return fallbackFile;
      }
    }
    if (preferredFile != null) {
      final resolvedPref = resolveCanonicalFbneoParent(preferredFile);
      if (resolvedPref != null) {
        final ext = preferredFile.toLowerCase().endsWith('.7z') ? '.7z' : '.zip';
        return '${resolvedPref.parentStem}$ext';
      }
      return preferredFile;
    }
    if (fallbackFile != null) {
      return fallbackFile;
    }
    return 'romset$fallbackExt';
  }

  static Future<bool> _hasValidArchiveHeader(
    File file, {
    required bool is7z,
  }) async {
    try {
      final len = await file.length();
      if (len < 32) return false;
      final raf = file.openSync(mode: FileMode.read);
      try {
        final hdr = raf.readSync(6);
        if (hdr.length < 4) return false;
        if (is7z) {
          return hdr.length >= 6 &&
              hdr[0] == 0x37 &&
              hdr[1] == 0x7A &&
              hdr[2] == 0xBC &&
              hdr[3] == 0xAF &&
              hdr[4] == 0x27 &&
              hdr[5] == 0x1C;
        }
        return hdr[0] == 0x50 && hdr[1] == 0x4B;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// Extrai arquivos `.zip`/`.7z` completos deixados em `roms/` após falha de
  /// extração anterior (ex.: OOM corrigido) e limpa pastas/pacotes de PC (`.exe`).
  Future<
      ({
        List<({int igdbId, EmulationGame? game, String localPath, int sizeBytes})>
            recovered,
        List<int> cleanedInvalidIds,
      })> recoverOrCleanUnextractedArchives({
    Map<int, EmulationGame> catalogById = const {},
  }) async {
    final recovered =
        <({int igdbId, EmulationGame? game, String localPath, int sizeBytes})>[];
    final cleanedInvalidIds = <int>[];
    try {
      final dir = await _romsDirectory();
      final pendingEntries = await dir.list(followLinks: false).toList();

      // 1. Remove pastas de jogos extraídas erroneamente contendo .exe de PC
      for (final entity in pendingEntries) {
        if (entity is! Directory) continue;
        final base = _basename(entity.path);
        final match = _gameFolderRegex.firstMatch(base);
        if (match == null) continue;
        final igdbId = int.tryParse(match.group(1) ?? '');
        if (igdbId == null || _cancelTokens.containsKey(igdbId)) continue;

        try {
          var hasPcExe = false;
          final allFiles = <String>[];
          await for (final child
              in entity.list(recursive: true, followLinks: false)) {
            if (child is File) {
              allFiles.add(child.path);
              if (looksLikePcOrXboxExecutable(child.path)) {
                hasPcExe = true;
              }
            }
          }
          if (hasPcExe) {
            final game = catalogById[igdbId];
            final valid = pickPreferredExtractedRom(
              allFiles,
              platformSlug: game?.platformSlug,
            );
            if (valid == null) {
              await entity.delete(recursive: true);
              cleanedInvalidIds.add(igdbId);
              debugPrint(
                '[RomDownloadService] Pasta PC inválida removida: ${entity.path}',
              );
            }
          }
        } catch (_) {}
      }

      // 2. Recupera arquivos rom_<id>_*.(zip|7z) completos pendentes de extração
      final archiveRegex =
          RegExp(r'^rom_(-?\d+)_(.+)\.(zip|7z)$', caseSensitive: false);
      for (final entity in pendingEntries) {
        if (entity is! File) continue;
        final base = _basename(entity.path);
        if (_isPartFileName(base.toLowerCase())) continue;
        final match = archiveRegex.firstMatch(base);
        if (match == null) continue;
        final igdbId = int.tryParse(match.group(1) ?? '');
        if (igdbId == null || _cancelTokens.containsKey(igdbId)) continue;

        final rawTitleStem = (match.group(2) ?? '').replaceAll('_', ' ').trim();
        var game = catalogById[igdbId];
        var platformSlug = game?.platformSlug ?? '';
        if (platformSlug.isEmpty) {
          final lowerStem = rawTitleStem.toLowerCase();
          if (lowerStem.contains('wii')) {
            platformSlug = 'wii';
          } else if (lowerStem.contains('gamecube')) {
            platformSlug = 'gamecube';
          } else if (lowerStem.contains('ps3')) {
            platformSlug = 'ps3';
          } else if (lowerStem.contains('ps2')) {
            platformSlug = 'ps2';
          } else if (lowerStem.contains('psp')) {
            platformSlug = 'psp';
          } else if (lowerStem.contains('3ds')) {
            platformSlug = '3ds';
          }
        }
        if (platformSlug.isEmpty || _isArcadePlatform(platformSlug)) {
          continue;
        }

        final minBytes = minBytesForPlatform(platformSlug);
        final fileLen = await entity.length();
        if (fileLen < minBytes) continue;

        final extractDir = Directory('${dir.path}/game_$igdbId');
        try {
          debugPrint(
            '[RomDownloadService] Tentando recuperar extração pendente: ${entity.path} ($platformSlug)',
          );
          final picked = await extractAndPickRomFromArchive(
            archivePath: entity.path,
            extractDir: extractDir,
            platformSlug: platformSlug,
            deleteSourceOnSuccess: true,
          );
          if (picked != null) {
            final sizeBytes =
                await LibraryStorageService.resolveInstalledRomSizeBytes(
              picked,
              fallbackBytes: fileLen,
            );
            recovered.add((
              igdbId: igdbId,
              game: game,
              localPath: picked,
              sizeBytes: sizeBytes,
            ));
            debugPrint(
              '[RomDownloadService] ROM recuperada com sucesso: $picked',
            );
          } else {
            await entity.delete();
            cleanedInvalidIds.add(igdbId);
          }
        } catch (e) {
          debugPrint(
            '[RomDownloadService] Arquivo pendente inválido removido (${entity.path}): $e',
          );
          try {
            if (await entity.exists()) await entity.delete();
          } catch (_) {}
          try {
            if (await extractDir.exists()) {
              await extractDir.delete(recursive: true);
            }
          } catch (_) {}
          cleanedInvalidIds.add(igdbId);
        }
      }
    } catch (e) {
      debugPrint('[RomDownloadService] Erro na recuperação de pacotes: $e');
    }
    return (recovered: recovered, cleanedInvalidIds: cleanedInvalidIds);
  }

  /// Extensões extras aceitas na importação direta de arquivo externo.
  ///
  /// [allowedExtensionsForPlatform] é focada em downloads (escolhe o melhor
  /// arquivo dentro de um `.zip`) e não cobre formatos comuns de ISO local
  /// como `.cue`, `.bin`, `.img`, `.gdi` e `.cdi`.
  static const Map<String, List<String>> _extraImportExtensions = {
    'ps1': ['.cue', '.bin', '.img'],
    'psx': ['.cue', '.bin', '.img'],
    'ps2': ['.cue', '.bin', '.img'],
    'psp': ['.cue', '.bin', '.img'],
    'ps3': ['.img', '.sfb', '.sfo', '.7z'],
    'saturn': ['.cue', '.bin', '.iso', '.img'],
    'dreamcast': ['.gdi', '.cdi', '.iso', '.img'],
    'gamecube': ['.img'],
    'wii': ['.img'],
    '3ds': ['.cia'],
    'pce': ['.chd', '.cue', '.bin', '.iso', '.img'],
  };

  /// Lista completa de extensões compatíveis com [platformSlug] ao importar
  /// um arquivo externo (lista base + extras).
  static List<String> importExtensionsForPlatform(String platformSlug) {
    final lower = platformSlug.toLowerCase();
    final base = allowedExtensionsForPlatform(lower);
    final extra = _extraImportExtensions[lower] ?? const <String>[];
    return <String>{...base, ...extra}.toList(growable: false);
  }

  /// Verifica se a extensão de [fileNameOrPath] faz sentido para
  /// [platformSlug], evitando vincular um `.gba` como PS2 (ou o inverso).
  ///
  /// Arquivos sem extensão reconhecida não são bloqueados.
  static bool isImportExtensionCompatible(
    String platformSlug,
    String fileNameOrPath,
  ) {
    final lower = fileNameOrPath.trim().toLowerCase();
    var nameStart = lower.lastIndexOf('/');
    final backslash = lower.lastIndexOf(r'\');
    if (backslash > nameStart) nameStart = backslash;
    final name = nameStart >= 0 ? lower.substring(nameStart + 1) : lower;
    final dotIdx = name.lastIndexOf('.');
    if (dotIdx <= 0) return true;
    return importExtensionsForPlatform(platformSlug).contains(name.substring(dotIdx));
  }

  /// Vincula diretamente um arquivo ROM/ISO ou pasta de dump externa (`PS3_GAME`)
  /// a partir de [sourcePath] sem copiar ou duplicar arquivos desnecessariamente.
  ///
  /// Pacotes `.zip` e `.7z` de consoles (não arcade) são extraídos em um [Isolate]
  /// com progresso via [onProgress] mantendo o arquivo original intacto, e dumps
  /// de PS3 passam por validação de integridade (ISO descriptografada,
  /// `PS3_GAME/USRDIR/EBOOT.BIN` ou `.pkg`).
  Future<({String localPath, int totalBytes})?> importExternalRomFile({
    required int igdbId,
    required String sourcePath,
    required String platformSlug,
    void Function(double progress, String statusLabel)? onProgress,
  }) async {
    final isDir = await FileSystemEntity.isDirectory(sourcePath);
    final sourceFile = File(sourcePath);
    if (!isDir && !await sourceFile.exists()) return null;

    var usedFilePickerCacheCopy = false;
    try {
      final dir = await _romsDirectory();
      final lowerPlatform = platformSlug.toLowerCase();
      final rawName = _basename(sourcePath);
      final lowerName = rawName.toLowerCase();
      late final String targetPath;

      if (isDir) {
        if (lowerPlatform == 'ps3') {
          onProgress?.call(0.5, 'Validando pasta PS3_GAME/USRDIR/EBOOT.BIN...');
          final validation = await validatePs3DumpContent(sourcePath);
          if (!validation.isValid || validation.resolvedRomPath == null) {
            throw StateError(
              validation.errorMessage ??
                  'A pasta selecionada não contém PS3_GAME/USRDIR/EBOOT.BIN válido.',
            );
          }
          targetPath = validation.resolvedRomPath!;
        } else {
          final entities =
              await Directory(sourcePath).list(recursive: true).toList();
          final candidates = entities.whereType<File>().map((f) => f.path).toList();
          final picked = pickPreferredExtractedRom(
            candidates,
            platformSlug: platformSlug,
          );
          if (picked == null) return null;
          targetPath = picked;
        }
      } else if (!_isArcadePlatform(platformSlug) &&
          (lowerName.endsWith('.zip') || lowerName.endsWith('.7z'))) {
        final gameDir = Directory('${dir.path}/game_$igdbId');
        final extracted = await extractAndPickRomFromArchive(
          archivePath: sourcePath,
          extractDir: gameDir,
          platformSlug: platformSlug,
          onProgress: onProgress,
          deleteSourceOnSuccess: false,
        );
        if (extracted != null) {
          targetPath = extracted;
          usedFilePickerCacheCopy = sourcePath
              .replaceAll('\\', '/')
              .contains('/file_picker/');
        } else {
          try {
            if (await gameDir.exists()) {
              await gameDir.delete(recursive: true);
            }
          } catch (_) {}
          if (lowerPlatform == 'ps3') {
            throw StateError(
              'O pacote selecionado não contém uma ISO descriptografada ou pasta PS3_GAME/USRDIR/EBOOT.BIN válida.',
            );
          }
          targetPath = sourceFile.path;
        }
      } else if (lowerPlatform == 'ps3') {
        onProgress?.call(0.4, 'Verificando dump de PS3...');
        final validation = await validatePs3DumpContent(sourceFile.path);
        if (!validation.isValid || validation.resolvedRomPath == null) {
          throw StateError(
            validation.errorMessage ??
                'Dump de PS3 inválido ou criptografado.',
          );
        }
        targetPath = validation.resolvedRomPath!;
      } else {
        // Execução direta no local original (ISO, CHD, CSO, PBP, RVZ, CUE+BIN,
        // ROMs soltas e conjuntos arcade ZIP/7z) sem copiar nem duplicar dados.
        targetPath = sourceFile.path;
      }

      onProgress?.call(1.0, 'Concluído!');
      final totalBytes =
          await LibraryStorageService.resolveInstalledRomSizeBytes(targetPath);
      return (localPath: targetPath, totalBytes: totalBytes);
    } finally {
      if (usedFilePickerCacheCopy) {
        await EmulatorService.cleanFilePickerTempCache(pickedPath: sourcePath);
      }
    }
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

    try {
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
    } finally {
      await EmulatorService.cleanFilePickerTempCache(pickedPath: pickedPath);
    }
  }

  /// Libera o stream controller de eventos e o cliente HTTP quando próprio.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    final waiters = List<Completer<void>>.from(_networkResumeWaiters);
    _networkResumeWaiters.clear();
    for (final w in waiters) {
      if (!w.isCompleted) {
        w.complete();
      }
    }
    while (_pendingQueue.isNotEmpty) {
      final entry = _pendingQueue.removeFirst();
      if (!entry.slotCompleter.isCompleted) {
        entry.slotCompleter.complete(false);
      }
    }
    for (final token in _cancelTokens.values) {
      if (!token.isCancelled) {
        token.cancel('SERVICE_DISPOSED');
      }
    }
    _cancelTokens.clear();
    _networkInterruptedGames.clear();
    if (!_eventsController.isClosed) {
      unawaited(_eventsController.close());
    }
    if (_ownsDio) {
      _dio.close(force: true);
    }
  }
}

class _SpeedSample {
  const _SpeedSample(this.time, this.bytes);
  final DateTime time;
  final int bytes;
}

class _ArchiveIsolateArgs {
  const _ArchiveIsolateArgs({
    required this.sendPort,
    required this.archivePath,
    required this.extractPath,
    required this.is7z,
    this.platformSlug = '',
  });

  final SendPort sendPort;
  final String archivePath;
  final String extractPath;
  final bool is7z;
  final String platformSlug;
}

Future<void> _extractArchiveWorkerEntry(_ArchiveIsolateArgs args) async {
  try {
    final extractedFiles = <String>[];
    if (args.is7z) {
      try {
        SevenZipArchiveExtractor.extractToDisk(
          archivePath: args.archivePath,
          extractPath: args.extractPath,
          onProgress: (p, entry) {
            args.sendPort.send({
              'type': 'progress',
              'progress': p,
              'entryName': entry,
            });
          },
          outFiles: extractedFiles,
        );
      } catch (pureErr) {
        // Fallback para binário nativo 7z/7za se disponível no ambiente
        var cliOk = false;
        for (final cmd in const ['7z', '7za']) {
          try {
            final res = Process.runSync(
              cmd,
              ['x', args.archivePath, '-o${args.extractPath}', '-y'],
            );
            if (res.exitCode == 0) {
              cliOk = true;
              extractedFiles.clear();
              for (final e
                  in Directory(args.extractPath).listSync(recursive: true)) {
                if (e is File) extractedFiles.add(e.path);
              }
              break;
            }
          } catch (_) {}
        }
        if (!cliOk) {
          rethrow;
        }
        debugPrint('[7z] Extraído via CLI após fallback: $pureErr');
      }
    } else {
      await StreamingZipArchiveExtractor.extractToDisk(
        zipPath: args.archivePath,
        extractPath: args.extractPath,
        platformSlug: args.platformSlug,
        onProgress: (p, entry) {
          args.sendPort.send({
            'type': 'progress',
            'progress': p,
            'entryName': entry,
          });
        },
        outFiles: extractedFiles,
      );
    }
    args.sendPort.send({
      'type': 'done',
      'files': extractedFiles,
    });
  } catch (e) {
    args.sendPort.send({
      'type': 'error',
      'message': '$e',
    });
  }
}

class _ZipCdEntry {
  const _ZipCdEntry({
    required this.name,
    required this.method,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
    required this.isDir,
  });

  final String name;
  final int method;
  final int compressedSize;
  final int uncompressedSize;
  final int localHeaderOffset;
  final bool isDir;
}

/// Extrator `.zip` em streaming puro (suporta Zip64, arquivos > 4 GB sem usar RAM
/// e nomes CP437/Latin-1 não-UTF8) executável dentro de um [Isolate].
class StreamingZipArchiveExtractor {
  static String _decodeEntryName(Uint8List bytes, int flags) {
    final utf8Flag = (flags & 0x0800) != 0;
    if (utf8Flag) {
      return utf8.decode(bytes, allowMalformed: true);
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return latin1.decode(bytes);
    }
  }

  static Future<void> extractToDisk({
    required String zipPath,
    required String extractPath,
    String platformSlug = '',
    required void Function(double progress, String entryName) onProgress,
    required List<String> outFiles,
  }) async {
    final file = File(zipPath);
    if (!file.existsSync()) {
      throw StateError('Arquivo .zip não encontrado.');
    }

    final rootDir = Directory(extractPath);
    if (!rootDir.existsSync()) rootDir.createSync(recursive: true);
    final canonicalRoot = rootDir.resolveSymbolicLinksSync();
    final rootPrefix = canonicalRoot.endsWith(Platform.pathSeparator)
        ? canonicalRoot
        : '$canonicalRoot${Platform.pathSeparator}';

    final entries = <_ZipCdEntry>[];
    final raf = file.openSync(mode: FileMode.read);
    try {
      final fileLen = raf.lengthSync();
      if (fileLen < 22) {
        throw StateError('Arquivo .zip inválido ou truncado (< 22 bytes).');
      }

      // 1. Localiza o EOCD (0x06054b50) nos últimos 65 KB do arquivo
      final tailReadLen = fileLen < 65557 ? fileLen : 65557;
      final tailStart = fileLen - tailReadLen;
      raf.setPositionSync(tailStart);
      final tail = raf.readSync(tailReadLen);

      var eocdRel = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 &&
            tail[i + 1] == 0x4B &&
            tail[i + 2] == 0x05 &&
            tail[i + 3] == 0x06) {
          final commentLen = tail[i + 20] | (tail[i + 21] << 8);
          if (i + 22 + commentLen == tail.length) {
            eocdRel = i;
            break;
          }
          if (eocdRel < 0) eocdRel = i;
        }
      }
      if (eocdRel < 0) {
        throw StateError('Cabeçalho End of Central Directory ausente no .zip.');
      }

      final tailBd = ByteData.sublistView(tail);
      var cdSize = tailBd.getUint32(eocdRel + 12, Endian.little);
      var cdOffset = tailBd.getUint32(eocdRel + 16, Endian.little);
      final eocdAbs = tailStart + eocdRel;

      // Suporte Zip64 para arquivos/entradas > 4 GB
      if ((cdOffset == 0xFFFFFFFF || cdSize == 0xFFFFFFFF) && eocdAbs >= 20) {
        raf.setPositionSync(eocdAbs - 20);
        final loc = raf.readSync(20);
        if (loc.length == 20 &&
            loc[0] == 0x50 &&
            loc[1] == 0x4B &&
            loc[2] == 0x06 &&
            loc[3] == 0x07) {
          final zip64EocdOffset =
              ByteData.sublistView(loc).getUint64(8, Endian.little);
          if (zip64EocdOffset >= 0 && zip64EocdOffset + 56 <= fileLen) {
            raf.setPositionSync(zip64EocdOffset);
            final z64 = raf.readSync(56);
            if (z64.length == 56 &&
                z64[0] == 0x50 &&
                z64[1] == 0x4B &&
                z64[2] == 0x06 &&
                z64[3] == 0x06) {
              final z64Bd = ByteData.sublistView(z64);
              cdSize = z64Bd.getUint64(40, Endian.little);
              cdOffset = z64Bd.getUint64(48, Endian.little);
            }
          }
        }
      }

      if (cdSize <= 0 || cdOffset < 0 || cdOffset + cdSize > fileLen) {
        throw StateError('Central Directory do .zip fora dos limites do arquivo.');
      }

      raf.setPositionSync(cdOffset);
      final cdBytes = raf.readSync(cdSize);
      final cdBd = ByteData.sublistView(cdBytes);
      var pos = 0;

      while (pos + 46 <= cdBytes.length) {
        if (cdBytes[pos] != 0x50 ||
            cdBytes[pos + 1] != 0x4B ||
            cdBytes[pos + 2] != 0x01 ||
            cdBytes[pos + 3] != 0x02) {
          break;
        }
        final flags = cdBd.getUint16(pos + 8, Endian.little);
        final method = cdBd.getUint16(pos + 10, Endian.little);
        var compSize = cdBd.getUint32(pos + 20, Endian.little);
        var uncompSize = cdBd.getUint32(pos + 24, Endian.little);
        final fnameLen = cdBd.getUint16(pos + 28, Endian.little);
        final extraLen = cdBd.getUint16(pos + 30, Endian.little);
        final commentLen = cdBd.getUint16(pos + 32, Endian.little);
        var localOffset = cdBd.getUint32(pos + 42, Endian.little);

        final nameStart = pos + 46;
        final nameEnd = nameStart + fnameLen;
        if (nameEnd > cdBytes.length) break;

        final rawName = _decodeEntryName(
          Uint8List.sublistView(cdBytes, nameStart, nameEnd),
          flags,
        );

        final extraStart = nameEnd;
        final extraEnd = (extraStart + extraLen).clamp(0, cdBytes.length);
        var ep = extraStart;
        while (ep + 4 <= extraEnd) {
          final eid = cdBd.getUint16(ep, Endian.little);
          final esize = cdBd.getUint16(ep + 2, Endian.little);
          if (ep + 4 + esize > extraEnd) break;
          if (eid == 0x0001) {
            var zOff = ep + 4;
            if (uncompSize == 0xFFFFFFFF && zOff + 8 <= ep + 4 + esize) {
              uncompSize = cdBd.getUint64(zOff, Endian.little);
              zOff += 8;
            }
            if (compSize == 0xFFFFFFFF && zOff + 8 <= ep + 4 + esize) {
              compSize = cdBd.getUint64(zOff, Endian.little);
              zOff += 8;
            }
            if (localOffset == 0xFFFFFFFF && zOff + 8 <= ep + 4 + esize) {
              localOffset = cdBd.getUint64(zOff, Endian.little);
            }
          }
          ep += 4 + esize;
        }

        pos = nameEnd + extraLen + commentLen;
        final normName = rawName.replaceAll('\\', '/');
        if (normName.isEmpty ||
            normName.contains('..') ||
            normName.startsWith('/')) {
          continue;
        }
        entries.add(
          _ZipCdEntry(
            name: normName,
            method: method,
            compressedSize: compSize,
            uncompressedSize: uncompSize,
            localHeaderOffset: localOffset,
            isDir: normName.endsWith('/'),
          ),
        );
      }

      // Valida antes de gastar disco caso o pacote seja build de PC/Windows (.exe)
      final slugLower = platformSlug.trim().toLowerCase();
      if (slugLower.isNotEmpty) {
        final fileNames =
            entries.where((e) => !e.isDir).map((e) => e.name).toList();
        final hasPcExe =
            fileNames.any(RomDownloadService.looksLikePcOrXboxExecutable);
        final preferred = RomDownloadService.pickPreferredExtractedRom(
          fileNames,
          platformSlug: slugLower,
        );
        if (hasPcExe && preferred == null) {
          throw StateError(
            'O pacote é um jogo de PC/Windows (.exe) ou Xbox e não uma ROM de $platformSlug.',
          );
        }
      }

      var totalBytes = 0;
      for (final e in entries) {
        if (!e.isDir && e.uncompressedSize > 0) {
          totalBytes += e.uncompressedSize;
        }
      }
      var extractedBytes = 0;
      var lastReportMs = 0;

      for (final entry in entries) {
        final outPath = '$extractPath/${entry.name}';
        if (entry.isDir) {
          Directory(outPath).createSync(recursive: true);
          continue;
        }
        final outFile = File(outPath);
        outFile.parent.createSync(recursive: true);
        final canonicalParent = outFile.parent.resolveSymbolicLinksSync();
        if (canonicalParent != canonicalRoot &&
            !canonicalParent.startsWith(rootPrefix)) {
          continue;
        }

        if (entry.localHeaderOffset + 30 > fileLen) continue;
        raf.setPositionSync(entry.localHeaderOffset);
        final lfh = raf.readSync(30);
        if (lfh.length < 30 ||
            lfh[0] != 0x50 ||
            lfh[1] != 0x4B ||
            lfh[2] != 0x03 ||
            lfh[3] != 0x04) {
          throw StateError('Cabeçalho local corrompido para ${entry.name}.');
        }
        final lfhBd = ByteData.sublistView(lfh);
        final lfhNameLen = lfhBd.getUint16(26, Endian.little);
        final lfhExtraLen = lfhBd.getUint16(28, Endian.little);
        final dataStart = entry.localHeaderOffset + 30 + lfhNameLen + lfhExtraLen;
        final dataEnd = dataStart + entry.compressedSize;
        if (dataEnd > fileLen) {
          throw StateError('Entrada ${entry.name} excede o tamanho do arquivo.');
        }

        if (entry.compressedSize == 0) {
          outFile.writeAsBytesSync(const <int>[]);
        } else {
          if (entry.method != 0 && entry.method != 8) {
            throw StateError(
              'Método ZIP não suportado (${entry.method}) em ${entry.name}.',
            );
          }
          final Stream<List<int>> sourceStream = entry.method == 8
              ? file
                  .openRead(dataStart, dataEnd)
                  .transform(io.ZLibCodec(raw: true).decoder)
              : file.openRead(dataStart, dataEnd);

          final sink = outFile.openWrite();
          try {
            await for (final chunk in sourceStream) {
              sink.add(chunk);
              extractedBytes += chunk.length;
              final nowMs = DateTime.now().millisecondsSinceEpoch;
              if (nowMs - lastReportMs >= 80) {
                lastReportMs = nowMs;
                final p = totalBytes > 0 ? (extractedBytes / totalBytes) : 0.5;
                onProgress(p.clamp(0.0, 1.0), entry.name.split('/').last);
              }
            }
            await sink.flush();
          } finally {
            await sink.close();
          }
        }

        outFiles.add(outFile.path);
        final finalP = totalBytes > 0 ? (extractedBytes / totalBytes) : 1.0;
        onProgress(finalP.clamp(0.0, 1.0), entry.name.split('/').last);
      }
    } finally {
      raf.closeSync();
    }
  }
}

/// Extrator `.7z` em Dart puro (suporta Copy, LZMA, LZMA2, Deflate, BZip2,
/// EncodedHeader, sólidos e filtros BCJ x86/PowerPC/ARM) executável em [Isolate].
class SevenZipArchiveExtractor {
  static const List<int> _kSignature = [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C];

  static void extractToDisk({
    required String archivePath,
    required String extractPath,
    required void Function(double progress, String entryName) onProgress,
    required List<String> outFiles,
  }) {
    final file = File(archivePath);
    if (!file.existsSync()) {
      throw StateError('Arquivo .7z não encontrado.');
    }
    final raf = file.openSync(mode: FileMode.read);
    try {
      final fileLen = raf.lengthSync();
      if (fileLen < 32) {
        throw StateError('Arquivo .7z corrompido (cabeçalho menor que 32 bytes).');
      }
      final sigHdr = raf.readSync(32);
      for (var i = 0; i < 6; i++) {
        if (sigHdr[i] != _kSignature[i]) {
          throw StateError('Arquivo inválido: assinatura 7z ausente.');
        }
      }
      final bd = ByteData.sublistView(sigHdr);
      final nextHeaderOffset = bd.getUint64(12, Endian.little);
      final nextHeaderSize = bd.getUint64(20, Endian.little);
      final headerPos = 32 + nextHeaderOffset;
      if (nextHeaderSize == 0 || headerPos + nextHeaderSize > fileLen) {
        throw StateError('Cabeçalho .7z fora dos limites do arquivo.');
      }

      raf.setPositionSync(headerPos);
      var headerBytes = raf.readSync(nextHeaderSize);
      var hr = _SzByteReader(headerBytes);
      final firstId = hr.readByte();
      if (firstId == 0x17) {
        // EncodedHeader: descompacta o próprio cabeçalho antes de parsear Header (0x01)
        final hdrStreams = _readStreamsInfo(hr);
        if (hdrStreams.folders.isEmpty) {
          throw StateError('Cabeçalho codificado .7z vazio.');
        }
        headerBytes = _decodeFolder(
          raf: raf,
          packPos: 32 + hdrStreams.packPos,
          packSizes: hdrStreams.packSizes,
          folder: hdrStreams.folders.first,
          packStartIdx: 0,
        );
        hr = _SzByteReader(headerBytes);
        final innerId = hr.readByte();
        if (innerId != 0x01) {
          throw StateError('Cabeçalho .7z interno inesperado ($innerId).');
        }
      } else if (firstId != 0x01) {
        throw StateError('Marcador de cabeçalho .7z inválido ($firstId).');
      }

      final parsed = _readMainHeader(hr);
      final rootDir = Directory(extractPath);
      if (!rootDir.existsSync()) rootDir.createSync(recursive: true);
      final canonicalRoot = rootDir.resolveSymbolicLinksSync();
      final rootPrefix = canonicalRoot.endsWith(Platform.pathSeparator)
          ? canonicalRoot
          : '$canonicalRoot${Platform.pathSeparator}';

      // Mapeia os streams não vazios (SubStreams) para arquivos não vazios
      final nonEmptyFiles = <_SzFileEntry>[];
      var totalUnpackBytes = 0;
      for (final entry in parsed.files) {
        if (!entry.hasStream) {
          if (!entry.isAnti && entry.name.isNotEmpty) {
            final cleanRel = _sanitizeRelPath(entry.name);
            if (cleanRel != null) {
              final target = '$extractPath/$cleanRel';
              if (entry.isDirectory) {
                Directory(target).createSync(recursive: true);
              } else {
                final f = File(target);
                f.parent.createSync(recursive: true);
                f.writeAsBytesSync(const <int>[]);
                outFiles.add(f.path);
              }
            }
          }
        } else {
          nonEmptyFiles.add(entry);
        }
      }

      final streams = parsed.mainStreams;
      if (streams == null || streams.folders.isEmpty) return;

      for (final folder in streams.folders) {
        for (final sz in folder.subStreamSizes) {
          totalUnpackBytes += sz;
        }
      }
      if (totalUnpackBytes == 0) totalUnpackBytes = 1;

      var packCursor = 0;
      var fileCursor = 0;
      var extractedBytes = 0;

      for (final folder in streams.folders) {
        final folderData = _decodeFolder(
          raf: raf,
          packPos: 32 + streams.packPos,
          packSizes: streams.packSizes,
          folder: folder,
          packStartIdx: packCursor,
        );
        packCursor += folder.numPackedStreams;

        var offset = 0;
        for (final subSize in folder.subStreamSizes) {
          if (fileCursor >= nonEmptyFiles.length) break;
          final entry = nonEmptyFiles[fileCursor++];
          final sliceEnd = (offset + subSize).clamp(0, folderData.length);
          final chunk = Uint8List.sublistView(folderData, offset, sliceEnd);
          offset = sliceEnd;

          final cleanRel = _sanitizeRelPath(entry.name);
          if (cleanRel != null) {
            final outFile = File('$extractPath/$cleanRel');
            outFile.parent.createSync(recursive: true);
            final canonicalParent = outFile.parent.resolveSymbolicLinksSync();
            if (canonicalParent == canonicalRoot ||
                canonicalParent.startsWith(rootPrefix)) {
              outFile.writeAsBytesSync(chunk, flush: true);
              outFiles.add(outFile.path);
            }
          }
          extractedBytes += subSize;
          onProgress(
            (extractedBytes / totalUnpackBytes).clamp(0.0, 1.0),
            entry.name.split('/').last,
          );
        }
      }
    } finally {
      raf.closeSync();
    }
  }

  static String? _sanitizeRelPath(String rawName) {
    final norm = rawName.replaceAll('\\', '/').trim();
    if (norm.isEmpty || norm.startsWith('/') || norm.contains('..')) {
      return null;
    }
    return norm;
  }

  static ({_SzStreamsInfo? mainStreams, List<_SzFileEntry> files}) _readMainHeader(
    _SzByteReader r,
  ) {
    _SzStreamsInfo? mainStreams;
    var files = <_SzFileEntry>[];
    while (r.hasMore) {
      final id = r.readByte();
      if (id == 0x00) break;
      switch (id) {
        case 0x02: // ArchiveProperties
          while (true) {
            final pid = r.readByte();
            if (pid == 0x00) break;
            final pSize = r.readNumber();
            r.skip(pSize);
          }
          break;
        case 0x03: // AdditionalStreamsInfo
          _readStreamsInfo(r);
          break;
        case 0x04: // MainStreamsInfo
          mainStreams = _readStreamsInfo(r);
          break;
        case 0x05: // FilesInfo
          files = _readFilesInfo(r);
          break;
        default:
          throw StateError('Propriedade .7z desconhecida no cabeçalho ($id).');
      }
    }
    return (mainStreams: mainStreams, files: files);
  }

  static _SzStreamsInfo _readStreamsInfo(_SzByteReader r) {
    var packPos = 0;
    final packSizes = <int>[];
    final folders = <_SzFolder>[];

    while (r.hasMore) {
      final id = r.readByte();
      if (id == 0x00) break;
      switch (id) {
        case 0x06: // PackInfo
          packPos = r.readNumber();
          final numPackStreams = r.readNumber();
          while (true) {
            final pid = r.readByte();
            if (pid == 0x00) break;
            if (pid == 0x09) {
              for (var i = 0; i < numPackStreams; i++) {
                packSizes.add(r.readNumber());
              }
            } else if (pid == 0x0A) {
              _skipCrcDigests(r, numPackStreams);
            } else {
              throw StateError('PackInfo inválido ($pid).');
            }
          }
          break;
        case 0x07: // UnpackInfo
          while (true) {
            final pid = r.readByte();
            if (pid == 0x00) break;
            if (pid == 0x0B) {
              final numFolders = r.readNumber();
              final external = r.readByte();
              if (external != 0) {
                throw StateError('External UnpackInfo não suportado em .7z.');
              }
              for (var i = 0; i < numFolders; i++) {
                folders.add(_readFolder(r));
              }
            } else if (pid == 0x0C) {
              for (final f in folders) {
                final sizes = <int>[];
                for (var s = 0; s < f.totalOutStreams; s++) {
                  sizes.add(r.readNumber());
                }
                f.unpackSizes = sizes;
              }
            } else if (pid == 0x0A) {
              _skipCrcDigests(r, folders.length);
            } else {
              throw StateError('UnpackInfo inválido ($pid).');
            }
          }
          break;
        case 0x08: // SubStreamsInfo
          final numSubStreams = List<int>.filled(folders.length, 1);
          final explicitSizes = <List<int>>[
            for (var i = 0; i < folders.length; i++) <int>[],
          ];
          while (true) {
            final pid = r.readByte();
            if (pid == 0x00) break;
            if (pid == 0x0D) {
              for (var i = 0; i < folders.length; i++) {
                numSubStreams[i] = r.readNumber();
              }
            } else if (pid == 0x09) {
              for (var i = 0; i < folders.length; i++) {
                final count = numSubStreams[i];
                for (var j = 0; j < count - 1; j++) {
                  explicitSizes[i].add(r.readNumber());
                }
              }
            } else if (pid == 0x0A) {
              var crcCount = 0;
              for (var i = 0; i < folders.length; i++) {
                if (numSubStreams[i] != 1) crcCount += numSubStreams[i];
              }
              _skipCrcDigests(r, crcCount);
            } else {
              throw StateError('SubStreamsInfo inválido ($pid).');
            }
          }
          for (var i = 0; i < folders.length; i++) {
            final totalSize = folders[i].finalUnpackSize;
            final count = numSubStreams[i];
            if (count == 1) {
              folders[i].subStreamSizes = [totalSize];
            } else {
              var sum = 0;
              for (final s in explicitSizes[i]) {
                sum += s;
              }
              folders[i].subStreamSizes = [
                ...explicitSizes[i],
                (totalSize - sum).clamp(0, totalSize),
              ];
            }
          }
          break;
        default:
          throw StateError('StreamsInfo .7z inválido ($id).');
      }
    }

    for (final f in folders) {
      if (f.subStreamSizes.isEmpty) {
        f.subStreamSizes = [f.finalUnpackSize];
      }
    }
    return _SzStreamsInfo(
      packPos: packPos,
      packSizes: packSizes,
      folders: folders,
    );
  }

  static _SzFolder _readFolder(_SzByteReader r) {
    final numCoders = r.readNumber();
    final coders = <_SzCoder>[];
    var totalIn = 0;
    var totalOut = 0;

    for (var i = 0; i < numCoders; i++) {
      final flags = r.readByte();
      final idSize = flags & 0x0F;
      final isComplex = (flags & 0x10) != 0;
      final hasAttrs = (flags & 0x20) != 0;
      final codecId = r.readBytes(idSize);
      var numIn = 1;
      var numOut = 1;
      if (isComplex) {
        numIn = r.readNumber();
        numOut = r.readNumber();
      }
      Uint8List attrs = Uint8List(0);
      if (hasAttrs) {
        final attrLen = r.readNumber();
        attrs = r.readBytes(attrLen);
      }
      coders.add(_SzCoder(
        codecId: codecId,
        numInStreams: numIn,
        numOutStreams: numOut,
        properties: attrs,
      ));
      totalIn += numIn;
      totalOut += numOut;
    }

    final numBindPairs = totalOut - 1;
    final bindInIndices = <int>{};
    final bindPairs = <(int, int)>[];
    for (var i = 0; i < numBindPairs; i++) {
      final inIdx = r.readNumber();
      final outIdx = r.readNumber();
      bindInIndices.add(inIdx);
      bindPairs.add((inIdx, outIdx));
    }

    final numPacked = totalIn - numBindPairs;
    final packedIndices = <int>[];
    if (numPacked == 1) {
      var found = 0;
      for (var i = 0; i < totalIn; i++) {
        if (!bindInIndices.contains(i)) {
          found = i;
          break;
        }
      }
      packedIndices.add(found);
    } else {
      for (var i = 0; i < numPacked; i++) {
        packedIndices.add(r.readNumber());
      }
    }

    return _SzFolder(
      coders: coders,
      totalInStreams: totalIn,
      totalOutStreams: totalOut,
      bindPairs: bindPairs,
      packedIndices: packedIndices,
    );
  }

  static void _skipCrcDigests(_SzByteReader r, int count) {
    final allDefined = r.readByte();
    var definedCount = count;
    if (allDefined == 0) {
      final maskBytes = (count + 7) >> 3;
      final mask = r.readBytes(maskBytes);
      definedCount = 0;
      for (var i = 0; i < count; i++) {
        if ((mask[i >> 3] & (0x80 >> (i & 7))) != 0) definedCount++;
      }
    }
    r.skip(definedCount * 4);
  }

  static List<_SzFileEntry> _readFilesInfo(_SzByteReader r) {
    final numFiles = r.readNumber();
    final emptyStreams = List<bool>.filled(numFiles, false);
    var emptyFiles = <bool>[];
    var antiFiles = <bool>[];
    var names = List<String>.filled(numFiles, '');
    final dirAttribs = List<bool>.filled(numFiles, false);

    while (r.hasMore) {
      final propType = r.readByte();
      if (propType == 0x00) break;
      final propSize = r.readNumber();
      final propBytes = r.readBytes(propSize);
      final pr = _SzByteReader(propBytes);

      switch (propType) {
        case 0x0E: // kEmptyStream
          for (var i = 0; i < numFiles; i++) {
            emptyStreams[i] =
                (propBytes[i >> 3] & (0x80 >> (i & 7))) != 0;
          }
          break;
        case 0x0F: // kEmptyFile
          final emptyCount = emptyStreams.where((e) => e).length;
          emptyFiles = List<bool>.generate(
            emptyCount,
            (i) => (propBytes[i >> 3] & (0x80 >> (i & 7))) != 0,
          );
          break;
        case 0x10: // kAnti
          final emptyCount = emptyStreams.where((e) => e).length;
          antiFiles = List<bool>.generate(
            emptyCount,
            (i) => (propBytes[i >> 3] & (0x80 >> (i & 7))) != 0,
          );
          break;
        case 0x11: // kName
          final external = pr.readByte();
          if (external != 0) {
            throw StateError('Nomes externos .7z não suportados.');
          }
          final units = <int>[];
          var fileIdx = 0;
          while (pr.hasMore && fileIdx < numFiles) {
            final lo = pr.readByte();
            final hi = pr.hasMore ? pr.readByte() : 0;
            final codeUnit = lo | (hi << 8);
            if (codeUnit == 0) {
              names[fileIdx++] = String.fromCharCodes(units);
              units.clear();
            } else {
              units.add(codeUnit);
            }
          }
          break;
        case 0x14: // kWinAttrib
          final allDef = pr.readByte();
          final maskBytes = allDef == 0 ? ((numFiles + 7) >> 3) : 0;
          final mask = maskBytes > 0 ? pr.readBytes(maskBytes) : Uint8List(0);
          for (var i = 0; i < numFiles; i++) {
            final def = allDef != 0 ||
                (mask[i >> 3] & (0x80 >> (i & 7))) != 0;
            if (def && pr.hasMore) {
              final attr = pr.readByte() |
                  (pr.readByte() << 8) |
                  (pr.readByte() << 16) |
                  (pr.readByte() << 24);
              dirAttribs[i] = (attr & 0x10) != 0;
            }
          }
          break;
        default:
          break;
      }
    }

    final result = <_SzFileEntry>[];
    var emptyIdx = 0;
    for (var i = 0; i < numFiles; i++) {
      final isEmptyStream = emptyStreams[i];
      var isEmptyFile = false;
      var isAnti = false;
      if (isEmptyStream) {
        if (emptyIdx < emptyFiles.length) isEmptyFile = emptyFiles[emptyIdx];
        if (emptyIdx < antiFiles.length) isAnti = antiFiles[emptyIdx];
        emptyIdx++;
      }
      final isDir =
          dirAttribs[i] || (isEmptyStream && !isEmptyFile && !isAnti);
      result.add(_SzFileEntry(
        name: names[i],
        hasStream: !isEmptyStream,
        isDirectory: isDir,
        isAnti: isAnti,
      ));
    }
    return result;
  }

  static Uint8List _decodeFolder({
    required RandomAccessFile raf,
    required int packPos,
    required List<int> packSizes,
    required _SzFolder folder,
    required int packStartIdx,
  }) {
    var offset = packPos;
    for (var i = 0; i < packStartIdx && i < packSizes.length; i++) {
      offset += packSizes[i];
    }

    final inStreams = <int, Uint8List>{};
    for (var p = 0; p < folder.packedIndices.length; p++) {
      final packIdx = packStartIdx + p;
      final size = packIdx < packSizes.length ? packSizes[packIdx] : 0;
      raf.setPositionSync(offset);
      inStreams[folder.packedIndices[p]] = raf.readSync(size);
      offset += size;
    }

    // Caso mais comum: pipeline de 1 coder ou coders encadeados pelos bindPairs
    final outStreams = <int, Uint8List>{};
    var remainingCoders = List<int>.generate(folder.coders.length, (i) => i);

    final outOffsets = <int>[];
    final inOffsets = <int>[];
    var accIn = 0;
    var accOut = 0;
    for (final c in folder.coders) {
      inOffsets.add(accIn);
      outOffsets.add(accOut);
      accIn += c.numInStreams;
      accOut += c.numOutStreams;
    }

    while (remainingCoders.isNotEmpty) {
      var progressed = false;
      for (final cIdx in List<int>.from(remainingCoders)) {
        final coder = folder.coders[cIdx];
        final firstIn = inOffsets[cIdx];
        final firstOut = outOffsets[cIdx];

        // Resolve todas as entradas do coder (direto do arquivo ou via bindPair)
        final coderInputs = <Uint8List>[];
        var ready = true;
        for (var k = 0; k < coder.numInStreams; k++) {
          final streamIdx = firstIn + k;
          if (inStreams.containsKey(streamIdx)) {
            coderInputs.add(inStreams[streamIdx]!);
          } else {
            final bound = folder.bindPairs
                .where((bp) => bp.$1 == streamIdx)
                .map((bp) => bp.$2)
                .firstOrNull;
            if (bound != null && outStreams.containsKey(bound)) {
              coderInputs.add(outStreams[bound]!);
            } else {
              ready = false;
              break;
            }
          }
        }
        if (!ready) continue;

        final outSize = firstOut < folder.unpackSizes.length
            ? folder.unpackSizes[firstOut]
            : folder.finalUnpackSize;
        outStreams[firstOut] = _runCoder(
          codecId: coder.codecId,
          properties: coder.properties,
          input: coderInputs.first,
          outSize: outSize,
        );
        remainingCoders.remove(cIdx);
        progressed = true;
      }
      if (!progressed) {
        throw StateError('Pipeline de codecs .7z inválido.');
      }
    }

    // O stream de saída final é o que não está ligado como saída em nenhum bindPair
    final boundOuts = folder.bindPairs.map((bp) => bp.$2).toSet();
    for (var i = 0; i < folder.totalOutStreams; i++) {
      if (!boundOuts.contains(i) && outStreams.containsKey(i)) {
        return outStreams[i]!;
      }
    }
    return outStreams.values.last;
  }

  static Uint8List _runCoder({
    required Uint8List codecId,
    required Uint8List properties,
    required Uint8List input,
    required int outSize,
  }) {
    bool isCodec(List<int> target) {
      if (codecId.length != target.length) return false;
      for (var i = 0; i < target.length; i++) {
        if (codecId[i] != target[i]) return false;
      }
      return true;
    }

    // Copy [0x00]
    if (isCodec(const [0x00])) {
      return input;
    }

    // LZMA [0x03, 0x01, 0x01]
    if (isCodec(const [0x03, 0x01, 0x01])) {
      if (properties.length < 5) {
        throw StateError('Propriedades LZMA ausentes no .7z.');
      }
      var props = properties[0];
      final pb = props ~/ 45;
      props -= pb * 45;
      final lp = props ~/ 9;
      final lc = props - lp * 9;
      final decoder = LzmaDecoder();
      decoder.reset(
        positionBits: pb,
        literalPositionBits: lp,
        literalContextBits: lc,
        resetDictionary: true,
      );
      return decoder.decode(InputStream(input), outSize);
    }

    // LZMA2 [0x21]
    if (isCodec(const [0x21])) {
      return _decodeLzma2(input);
    }

    // Deflate [0x04, 0x01, 0x08]
    if (isCodec(const [0x04, 0x01, 0x08])) {
      final decoded = Inflate(input).getBytes();
      return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
    }

    // BZip2 [0x04, 0x02, 0x02]
    if (isCodec(const [0x04, 0x02, 0x02])) {
      final decoded = BZip2Decoder().decodeBytes(input);
      return decoded is Uint8List ? decoded : Uint8List.fromList(decoded);
    }

    // BCJ x86 [0x03, 0x03, 0x01, 0x03]
    if (isCodec(const [0x03, 0x03, 0x01, 0x03])) {
      return _decodeBcjX86(Uint8List.fromList(input));
    }

    // BCJ PowerPC [0x03, 0x03, 0x02, 0x05]
    if (isCodec(const [0x03, 0x03, 0x02, 0x05])) {
      return _decodeBcjPpc(Uint8List.fromList(input));
    }

    // BCJ ARM [0x03, 0x03, 0x05, 0x01]
    if (isCodec(const [0x03, 0x03, 0x05, 0x01])) {
      return _decodeBcjArm(Uint8List.fromList(input));
    }

    final hexId = codecId.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    throw StateError('Codec .7z não suportado: 0x$hexId');
  }

  static Uint8List _decodeLzma2(Uint8List input) {
    final stream = InputStream(input);
    final decoder = LzmaDecoder();
    final out = BytesBuilder(copy: false);

    while (!stream.isEOS) {
      final control = stream.readByte();
      if (control & 0x80 == 0) {
        if (control == 0) {
          decoder.reset(resetDictionary: true);
          break;
        } else if (control == 1) {
          decoder.reset(resetDictionary: true);
          final len = ((stream.readByte() << 8) | stream.readByte()) + 1;
          out.add(decoder.decodeUncompressed(stream.readBytes(len), len));
        } else if (control == 2) {
          final len = ((stream.readByte() << 8) | stream.readByte()) + 1;
          out.add(decoder.decodeUncompressed(stream.readBytes(len), len));
        } else {
          throw StateError('Código de controle LZMA2 desconhecido ($control).');
        }
      } else {
        final reset = (control >> 5) & 0x3;
        final unpackLen =
            (((control & 0x1F) << 16) |
                    (stream.readByte() << 8) |
                    stream.readByte()) +
                1;
        final packLen = ((stream.readByte() << 8) | stream.readByte()) + 1;
        int? lc;
        int? lp;
        int? pb;
        if (reset >= 2) {
          var props = stream.readByte();
          pb = props ~/ 45;
          props -= pb * 45;
          lp = props ~/ 9;
          lc = props - lp * 9;
        }
        if (reset > 0) {
          decoder.reset(
            literalContextBits: lc,
            literalPositionBits: lp,
            positionBits: pb,
            resetDictionary: reset == 3,
          );
        }
        out.add(decoder.decode(stream.readBytes(packLen), unpackLen));
      }
    }
    return out.takeBytes();
  }

  static Uint8List _decodeBcjX86(Uint8List buf) {
    if (buf.length < 5) return buf;
    var pos = 0;
    var prevMask = 0;
    while (pos <= buf.length - 5) {
      final b = buf[pos];
      if (b != 0xE8 && b != 0xE9) {
        pos++;
        prevMask = (prevMask << 1) & 0xFF;
        continue;
      }
      if ((prevMask & 0x07) == 0) {
        final src = (buf[pos + 1]) |
            (buf[pos + 2] << 8) |
            (buf[pos + 3] << 16) |
            (buf[pos + 4] << 24);
        final top = buf[pos + 4];
        if (top == 0x00 || top == 0xFF) {
          final dest = (src - (pos + 5)) & 0xFFFFFFFF;
          buf[pos + 1] = dest & 0xFF;
          buf[pos + 2] = (dest >> 8) & 0xFF;
          buf[pos + 3] = (dest >> 16) & 0xFF;
          buf[pos + 4] = ((dest >> 24) & 0x01) == 0x01 ? 0xFF : 0x00;
          pos += 5;
          prevMask = 0;
          continue;
        }
      }
      pos++;
      prevMask = (prevMask << 1) & 0xFF;
    }
    return buf;
  }

  static Uint8List _decodeBcjPpc(Uint8List buf) {
    for (var i = 0; i + 4 <= buf.length; i += 4) {
      if ((buf[i] >> 2) == 0x12 && (buf[i + 3] & 0x03) == 0x01) {
        var src = ((buf[i] & 0x03) << 24) |
            (buf[i + 1] << 16) |
            (buf[i + 2] << 8) |
            (buf[i + 3] & 0xFC);
        var dest = src - i;
        buf[i] = 0x48 | ((dest >> 24) & 0x03);
        buf[i + 1] = (dest >> 16) & 0xFF;
        buf[i + 2] = (dest >> 8) & 0xFF;
        buf[i + 3] = (buf[i + 3] & 0x03) | (dest & 0xFC);
      }
    }
    return buf;
  }

  static Uint8List _decodeBcjArm(Uint8List buf) {
    for (var i = 0; i + 4 <= buf.length; i += 4) {
      if (buf[i + 3] == 0xEB) {
        var src = (buf[i] | (buf[i + 1] << 8) | (buf[i + 2] << 16)) << 2;
        var dest = (src - (i + 8)) >> 2;
        buf[i] = dest & 0xFF;
        buf[i + 1] = (dest >> 8) & 0xFF;
        buf[i + 2] = (dest >> 16) & 0xFF;
      }
    }
    return buf;
  }
}

class _SzByteReader {
  _SzByteReader(this._bytes);
  final Uint8List _bytes;
  int _pos = 0;

  bool get hasMore => _pos < _bytes.length;

  int readByte() {
    if (_pos >= _bytes.length) {
      throw StateError('Fim inesperado ao ler cabeçalho .7z.');
    }
    return _bytes[_pos++];
  }

  Uint8List readBytes(int count) {
    if (count <= 0) return Uint8List(0);
    if (_pos + count > _bytes.length) {
      throw StateError('Leitura além dos limites do cabeçalho .7z.');
    }
    final slice = Uint8List.sublistView(_bytes, _pos, _pos + count);
    _pos += count;
    return slice;
  }

  void skip(int count) {
    _pos = (_pos + count).clamp(0, _bytes.length);
  }

  int readNumber() {
    final first = readByte();
    var mask = 0x80;
    var value = 0;
    for (var i = 0; i < 8; i++) {
      if ((first & mask) == 0) {
        final high = first & (mask - 1);
        value |= high << (8 * i);
        return value;
      }
      value |= readByte() << (8 * i);
      mask >>= 1;
    }
    return value;
  }
}

class _SzCoder {
  const _SzCoder({
    required this.codecId,
    required this.numInStreams,
    required this.numOutStreams,
    required this.properties,
  });

  final Uint8List codecId;
  final int numInStreams;
  final int numOutStreams;
  final Uint8List properties;
}

class _SzFolder {
  _SzFolder({
    required this.coders,
    required this.totalInStreams,
    required this.totalOutStreams,
    required this.bindPairs,
    required this.packedIndices,
  });

  final List<_SzCoder> coders;
  final int totalInStreams;
  final int totalOutStreams;
  final List<(int, int)> bindPairs;
  final List<int> packedIndices;
  List<int> unpackSizes = const [];
  List<int> subStreamSizes = const [];

  int get numPackedStreams => packedIndices.length;

  int get finalUnpackSize {
    if (unpackSizes.isEmpty) return 0;
    final boundOuts = bindPairs.map((bp) => bp.$2).toSet();
    for (var i = 0; i < unpackSizes.length; i++) {
      if (!boundOuts.contains(i)) return unpackSizes[i];
    }
    return unpackSizes.last;
  }
}

class _SzStreamsInfo {
  const _SzStreamsInfo({
    required this.packPos,
    required this.packSizes,
    required this.folders,
  });

  final int packPos;
  final List<int> packSizes;
  final List<_SzFolder> folders;
}

class _SzFileEntry {
  const _SzFileEntry({
    required this.name,
    required this.hasStream,
    required this.isDirectory,
    required this.isAnti,
  });

  final String name;
  final bool hasStream;
  final bool isDirectory;
  final bool isAnti;
}
