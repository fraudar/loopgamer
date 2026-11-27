import 'dart:io';
import 'dart:typed_data';

/// Origem da plataforma detectada — usada para rotular a detecção no diálogo
/// de importação, para o usuário saber o quão confiável é a escolha automática.
enum RomDetectionSource {
  /// Marcadores lidos dos bytes do arquivo (SYSTEM.CNF, magic de disco...).
  content,

  /// Serial Sony (SLUS-xxxxx) ou token de console no nome/caminho do arquivo.
  fileName,

  /// Extensão exclusiva de um console (`.gba`, `.nes`, `.wbfs`...).
  extension,

  /// Estimativa grosseira pelo tamanho do arquivo (apenas `.iso`/`.img`).
  size,
}

/// Resultado da detecção de plataforma de um arquivo ROM/ISO.
class RomDetection {
  const RomDetection({required this.slug, required this.source});

  /// Slug da plataforma (mesmos slugs de `kRommPlatforms`).
  final String slug;

  /// Como a plataforma foi detectada.
  final RomDetectionSource source;

  /// Rótulo em pt-BR exibido no diálogo de importação.
  String get sourceLabel => switch (source) {
        RomDetectionSource.content => 'conteúdo do arquivo',
        RomDetectionSource.fileName => 'nome do arquivo',
        RomDetectionSource.extension => 'extensão do arquivo',
        RomDetectionSource.size => 'tamanho do arquivo (estimativa)',
      };
}

/// Detecta a plataforma de uma ROM/ISO sem cair em fallback silencioso.
///
/// Extensões como `.iso`, `.chd`, `.cue`, `.bin` e `.img` são compartilhadas
/// por vários consoles. Antes deste detector o importador aplicava
/// `fallbackSlug: 'ps2'` para tudo, fazendo toda ISO importada rodar no core
/// errado (Play! para arquivos que eram PS1, por exemplo).
///
/// Ordem de prioridade em [detect]:
/// 1. conteúdo do arquivo (marcadores de disco);
/// 2. nome/caminho (seriais Sony e tokens de console);
/// 3. extensão exclusiva de um console;
/// 4. tamanho do arquivo (apenas `.iso`/`.img`, rotulado como estimativa);
/// 5. `null` — o usuário escolhe o console manualmente no diálogo.
class RomPlatformDetector {
  RomPlatformDetector._();

  /// Profundidade da varredura por strings do sistema (`SYSTEM.CNF`,
  /// `PSX.EXE`, diretório raiz...), que ficam no início da imagem.
  static const int _deepScanBytes = 8 * 1024 * 1024;

  /// Extensões ambíguas e não comprimidas cujo conteúdo vale a pena ler.
  static const Set<String> _sniffableExtensions = {
    '.iso',
    '.img',
    '.cue',
    '.bin',
    '.gcm',
  };

  /// Formatos comprimidos/empacotados: o cabeçalho não revela o console.
  static const Set<String> _opaqueExtensions = {
    '.chd',
    '.cso',
    '.pbp',
    '.rvz',
    '.gcz',
    '.isz',
    '.wbfs',
    '.zip',
    '.7z',
  };

  static final RegExp _serialPattern = RegExp(
    r'\b(SLUS|SLPS|SCUS|SCES|SLES)[\s._-]*([0-9][0-9._-]{3,})',
    caseSensitive: false,
  );

  static final RegExp _ps3SerialPattern = RegExp(
    r'\b(BLUS|BLES|BCUS|BCES|BLJM|BLJS|BCJS|BLAS|BCAS|NPUB|NPEB|NPJB|NPUA|NPEA)[\s._-]*([0-9]{4,})',
    caseSensitive: false,
  );

  static final RegExp _pspSerialPattern = RegExp(
    r'\b(ULUS|ULES|UCUS|UCES|ULJM|ULJS|NPUG|NPEG|NPUH)[\s._-]*([0-9]{4,})',
    caseSensitive: false,
  );

  static final RegExp _serialDigitsPattern = RegExp(r'\D');

  static final RegExp _bootAssignPattern = RegExp(r'BOOT\s*=');

  /// Detecta a plataforma de um arquivo ROM/ISO ou pasta de dump.
  ///
  /// [fileNameOrPath] pode ser só o nome; [filePath] é o arquivo/diretório real
  /// (usado para ler conteúdo e tamanho). Retorna `null` quando nenhuma pista é
  /// confiável — nesse caso o diálogo de importação exige que o usuário
  /// escolha o console manualmente.
  static Future<RomDetection?> detect(
    String fileNameOrPath, {
    String? filePath,
  }) async {
    final lower = fileNameOrPath.trim().toLowerCase();
    final ext = _extensionOf(lower);

    if (filePath != null) {
      if (await FileSystemEntity.isDirectory(filePath)) {
        final slug = await sniffContent(filePath);
        if (slug != null) {
          return RomDetection(slug: slug, source: RomDetectionSource.content);
        }
      } else if (_sniffableExtensions.contains(ext) ||
          ext == '.sfb' ||
          ext == '.sfo' ||
          ext == '.pkg') {
        final slug = await sniffContent(filePath);
        if (slug != null) {
          return RomDetection(slug: slug, source: RomDetectionSource.content);
        }
      }
    }

    final byName = fromFileName(fileNameOrPath) ??
        (filePath == null ? null : fromFileName(filePath));
    if (byName != null) {
      return RomDetection(slug: byName, source: RomDetectionSource.fileName);
    }

    final byExtension = fromExtension(lower);
    if (byExtension != null) {
      return RomDetection(
        slug: byExtension,
        source: RomDetectionSource.extension,
      );
    }

    if (filePath != null && (ext == '.iso' || ext == '.img')) {
      try {
        final bySize = fromSize(await File(filePath).length());
        if (bySize != null) {
          return RomDetection(slug: bySize, source: RomDetectionSource.size);
        }
      } catch (_) {
        // Sem tamanho legível não há palpite.
      }
    }

    return null;
  }

  /// Infere a plataforma apenas pela extensão do arquivo.
  ///
  /// Retorna `null` para extensões ambíguas (`.iso`, `.chd`, `.cue`, `.bin`,
  /// `.img`...) em vez de assumir um console — use [detect] para resolver.
  static String? fromExtension(String fileNameOrPath) {
    final lower = fileNameOrPath.trim().toLowerCase();
    if (lower.endsWith('.rvz') ||
        lower.endsWith('.gcz') ||
        lower.endsWith('.gcm')) {
      return 'gamecube';
    }
    if (lower.endsWith('.wbfs') || lower.endsWith('.wad')) {
      return 'wii';
    }
    if (lower.endsWith('.3ds') ||
        lower.endsWith('.cci') ||
        lower.endsWith('.cxi') ||
        lower.endsWith('.cia')) {
      return '3ds';
    }
    if (lower.endsWith('.nsp') ||
        lower.endsWith('.xci') ||
        lower.endsWith('.nsz') ||
        lower.endsWith('.xcz') ||
        lower.endsWith('.nro') ||
        lower.endsWith('.nca')) {
      return 'switch';
    }
    if (lower.endsWith('.cso') || lower.endsWith('.pbp')) {
      return 'psp';
    }
    if (lower.endsWith('.pkg') ||
        lower.endsWith('.sfb') ||
        lower.endsWith('.sfo')) {
      return 'ps3';
    }
    if (lower.endsWith('.nds')) return 'nds';
    if (lower.endsWith('.gba')) return 'gba';
    if (lower.endsWith('.gbc')) return 'gbc';
    if (lower.endsWith('.gb')) return 'gb';
    if (lower.endsWith('.sfc') || lower.endsWith('.smc')) return 'snes';
    if (lower.endsWith('.nes')) return 'nes';
    if (lower.endsWith('.z64') ||
        lower.endsWith('.n64') ||
        lower.endsWith('.v64')) {
      return 'n64';
    }
    if (lower.endsWith('.md') ||
        lower.endsWith('.gen') ||
        lower.endsWith('.smd')) {
      return 'md';
    }
    if (lower.endsWith('.gg')) return 'gamegear';
    if (lower.endsWith('.sms')) return 'mastersystem';
    if (lower.endsWith('.pce')) return 'pce';
    if (lower.endsWith('.cdi') || lower.endsWith('.gdi')) return 'dreamcast';
    return null;
  }

  /// Detecta a plataforma pelo nome (ou caminho) do arquivo.
  ///
  /// Seriais Sony: PS1 usa `0xxxx` (SLUS-00001) e PS2 usa `2xxxx`/`5xxxx`
  /// (SLUS-20159). Também reconhece tokens como `(PS2)`, `PSX`, `Wii` e
  /// pastas como `/PS2/` no caminho.
  static String? fromFileName(String fileNameOrPath) {
    final normalized = fileNameOrPath.trim().replaceAll('\\', '/').toLowerCase();
    if (normalized.contains('ps3_game/usrdir/eboot.bin') ||
        normalized.endsWith('/ps3_game') ||
        normalized.contains('/ps3_game/') ||
        normalized.endsWith('/usrdir/eboot.bin') ||
        normalized.endsWith('/ps3_disc.sfb') ||
        normalized == 'ps3_disc.sfb') {
      return 'ps3';
    }
    final serial = _slugFromSerial(normalized);
    if (serial != null) return serial;
    if (RegExp(r'playstation\s*3|\bps3\b').hasMatch(normalized)) return 'ps3';
    if (RegExp(r'playstation\s*2|\bps2\b').hasMatch(normalized)) return 'ps2';
    if (RegExp(r'playstation\s*(portable|pocket)|\bpsp\b')
        .hasMatch(normalized)) {
      return 'psp';
    }
    if (RegExp(r'playstation(\s*(1|one))?|\bpsx\b|\bps1\b')
        .hasMatch(normalized)) {
      return 'ps1';
    }
    if (RegExp(r'\bwii\b').hasMatch(normalized)) return 'wii';
    if (normalized.contains('gamecube')) return 'gamecube';
    if (normalized.contains('dreamcast')) return 'dreamcast';
    if (RegExp(r'\bsaturn\b').hasMatch(normalized)) return 'saturn';
    if (RegExp(r'\b3ds\b').hasMatch(normalized)) return '3ds';
    return null;
  }

  /// Estimativa grosseira de PS1/PS2/PS3 pelo tamanho (apenas `.iso`/`.img`).
  ///
  /// Réplica da heurística já usada em `IgdbSteamGridService`: PS1 cabe em
  /// CD (~700 MB) e PS2 em DVD (> 900 MB). Imagens GameCube/Wii/PSP/PS3 são
  /// resolvidas pelo conteúdo antes de chegar aqui; o resultado é sempre
  /// rotulado como estimativa no diálogo de importação.
  ///
  /// Acima de 10 GB nenhum disco de PS2 cabe (DVD dupla camada = 8.5 GB), então
  /// a única imagem plausível é PS3 — ISOs criptografadas de PS3 não expõem
  /// marcador no cabeçalho e antes caíam em `ps2`, abrindo no core errado.
  static String? fromSize(int bytes) {
    if (bytes <= 0) return null;
    if (bytes > 10 * 1024 * 1024 * 1024) return 'ps3';
    if (bytes > 900 * 1024 * 1024) return 'ps2';
    if (bytes >= 80 * 1024 * 1024) return 'ps1';
    return null;
  }

  /// Lê os primeiros bytes do arquivo (ou inspeciona diretório `PS3_GAME`) e
  /// procura marcadores de disco.
  ///
  /// Para `.cue`, segue o `FILE` apontado e inspeciona o `.bin` irmão.
  /// Retorna `null` quando o formato é opaco ou nenhum marcador aparece.
  static Future<String?> sniffContent(String filePath) async {
    if (filePath.trim().isEmpty) return null;
    try {
      if (await FileSystemEntity.isDirectory(filePath)) {
        return await _sniffPs3Directory(Directory(filePath));
      }

      final lower = filePath.toLowerCase();
      if (_opaqueExtensions.contains(_extensionOf(lower))) return null;

      var targetPath = filePath;
      if (lower.endsWith('.cue')) {
        final target = await _cueTargetFile(filePath);
        if (target == null) return null;
        targetPath = target;
      }
      final file = File(targetPath);
      if (!await file.exists()) return null;

      final normalized = targetPath.replaceAll('\\', '/').toLowerCase();
      final raf = await file.open();
      late final Uint8List bytes;
      try {
        bytes = await raf.read(_deepScanBytes);
      } finally {
        await raf.close();
      }

      // EBOOT.BIN de PS3 dentro de USRDIR / PS3_GAME
      if (normalized.endsWith('/eboot.bin') &&
          (normalized.contains('/ps3_game/usrdir/') ||
              normalized.contains('/usrdir/'))) {
        if (bytes.length >= 4 &&
            ((bytes[0] == 0x53 &&
                    bytes[1] == 0x43 &&
                    bytes[2] == 0x45 &&
                    bytes[3] == 0x00) ||
                (bytes[0] == 0x7F &&
                    bytes[1] == 0x45 &&
                    bytes[2] == 0x4C &&
                    bytes[3] == 0x46))) {
          return 'ps3';
        }
      }

      // PKG de PS3 (\x7FPKG)
      if (bytes.length >= 4 &&
          bytes[0] == 0x7F &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x4B &&
          bytes[3] == 0x47) {
        return 'ps3';
      }

      // PARAM.SFO (\0PSF)
      if (bytes.length >= 4 &&
          bytes[0] == 0x00 &&
          bytes[1] == 0x50 &&
          bytes[2] == 0x53 &&
          bytes[3] == 0x46) {
        final text = String.fromCharCodes(bytes);
        if (text.contains('PS3') || _ps3SerialPattern.hasMatch(text)) {
          return 'ps3';
        }
      }

      return _slugFromDiscBytes(bytes);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _sniffPs3Directory(Directory dir) async {
    if (!await dir.exists()) return null;
    final directCandidates = [
      File('${dir.path}/PS3_GAME/USRDIR/EBOOT.BIN'),
      File('${dir.path}/USRDIR/EBOOT.BIN'),
      File('${dir.path}/PS3_DISC.SFB'),
    ];
    for (final c in directCandidates) {
      if (await c.exists()) return 'ps3';
    }
    return null;
  }

  /// Resolve o primeiro `FILE` de um `.cue` para o binário irmão ao lado.
  static Future<String?> _cueTargetFile(String cuePath) async {
    final text = await File(cuePath).readAsString();
    final quoted = RegExp(
      r'^\s*FILE\s+"([^"]+)"',
      multiLine: true,
      caseSensitive: false,
    ).firstMatch(text);
    final bare = quoted ??
        RegExp(
          r'^\s*FILE\s+(\S+)\s+BINARY',
          multiLine: true,
          caseSensitive: false,
        ).firstMatch(text);
    final name = bare?.group(1)?.trim();
    if (name == null || name.isEmpty) return null;
    final target = File('${File(cuePath).parent.path}/$name');
    return await target.exists() ? target.path : null;
  }

  static String? _slugFromDiscBytes(Uint8List bytes) {
    if (bytes.length < 32) return null;
    final deep = String.fromCharCodes(bytes);

    if (deep.contains('PSP_GAME')) return 'psp';
    if (deep.contains('PS3_DISC.SFB') || deep.contains('PS3_GAME')) {
      return 'ps3';
    }
    // SYSTEM.CNF do PS2 usa `BOOT2 =` (o PS1 usa `BOOT =`).
    if (deep.contains('BOOT2')) return 'ps2';

    final serial = _slugFromSerial(deep);
    if (serial != null) return serial;

    // PS1: executável de boot (`PS-X EXE`) e SYSTEM.CNF com `BOOT =`.
    if (deep.contains('PS-X EXE')) return 'ps1';
    if (_bootAssignPattern.hasMatch(deep)) return 'ps1';

    if (deep.contains('SEGA SEGASATURN')) return 'saturn';
    if (deep.contains('SEGA SEGAKATANA')) return 'dreamcast';
    if (deep.contains('SEGA MEGA DRIVE') || deep.contains('SEGA GENESIS')) {
      return 'md';
    }

    // Magic de disco: Wii em 0x18 e GameCube em 0x1C (big endian).
    if (_u32At(bytes, 0x18) == 0x5D1C9EA3) return 'wii';
    if (_u32At(bytes, 0x1C) == 0xC2339F3D) return 'gamecube';

    return null;
  }

  static String? _slugFromSerial(String text) {
    if (_ps3SerialPattern.hasMatch(text)) return 'ps3';
    if (_pspSerialPattern.hasMatch(text)) return 'psp';
    final match = _serialPattern.firstMatch(text);
    if (match == null) return null;
    final digits =
        match.group(2)!.replaceAll(_serialDigitsPattern, '');
    if (digits.length < 4) return null;
    switch (digits[0]) {
      case '0':
        return 'ps1';
      case '2':
      case '5':
        return 'ps2';
      default:
        return null;
    }
  }

  static int _u32At(Uint8List bytes, int offset) {
    if (bytes.length < offset + 4) return -1;
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static String _extensionOf(String lowerPath) {
    var nameStart = lowerPath.lastIndexOf('/');
    final backslash = lowerPath.lastIndexOf(r'\');
    if (backslash > nameStart) nameStart = backslash;
    final name = nameStart >= 0 ? lowerPath.substring(nameStart + 1) : lowerPath;
    final dotIdx = name.lastIndexOf('.');
    return dotIdx > 0 ? name.substring(dotIdx) : '';
  }
}
