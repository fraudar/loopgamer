import 'dart:convert';

import 'package:flutter/material.dart';

enum RommPlatformCategory {
  all,
  nextGen3d,
  handhelds,
  classics,
  arcade,
  /// Ports Android instaláveis (APK + dados), curados e do APKVision.
  androidPorts,
}

extension RommPlatformCategoryX on RommPlatformCategory {
  String get label {
    switch (this) {
      case RommPlatformCategory.all:
        return 'Todos';
      case RommPlatformCategory.nextGen3d:
        return '3D & Next-Gen';
      case RommPlatformCategory.handhelds:
        return 'Portáteis';
      case RommPlatformCategory.classics:
        return 'Clássicos';
      case RommPlatformCategory.arcade:
        return 'Arcade';
      case RommPlatformCategory.androidPorts:
        return 'Ports Android';
    }
  }
}

class RommPlatformSpec {
  const RommPlatformSpec({
    required this.slug,
    required this.shortName,
    required this.fullName,
    required this.manufacturer,
    required this.releaseYear,
    required this.defaultExtension,
    required this.accentColor,
    this.retroApiSlug,
    this.romGripperType,
    this.category,
    this.coreNote,
  });

  final String slug;
  final String shortName;
  final String fullName;
  final String manufacturer;
  final int releaseYear;
  final String defaultExtension;
  final Color accentColor;
  final String? retroApiSlug;
  final String? romGripperType;
  final RommPlatformCategory? category;
  final String? coreNote;

  RommPlatformCategory get resolvedCategory {
    if (category != null) return category!;
    switch (slug) {
      case 'switch':
      case 'ps3':
      case 'ps2':
      case 'wii':
      case 'gamecube':
      case 'dreamcast':
      case 'ps1':
      case 'n64':
        return RommPlatformCategory.nextGen3d;
      case 'psp':
      case '3ds':
      case 'nds':
      case 'gba':
      case 'gbc':
      case 'gb':
      case 'gamegear':
        return RommPlatformCategory.handhelds;
      case 'neogeo':
      case 'cps1':
      case 'cps2':
      case 'mame':
        return RommPlatformCategory.arcade;
      default:
        return RommPlatformCategory.classics;
    }
  }
}

/// Plataformas integradas: RomM (romm.app), RetroAPI (retroapi.konsumer.workers.dev)
/// e ROM-Gripper (romgripper.github.io/ROM-Gripper/en/api).
const List<RommPlatformSpec> kRommPlatforms = [
  RommPlatformSpec(
    slug: 'todos',
    shortName: 'TODOS',
    fullName: 'Todas as Plataformas',
    manufacturer: 'Multi-Console',
    releaseYear: 1983,
    defaultExtension: 'ROM',
    accentColor: Color(0xFFFFFFFF),
  ),
  RommPlatformSpec(
    slug: 'psp',
    shortName: 'PSP',
    fullName: 'PlayStation Portable',
    manufacturer: 'Sony',
    releaseYear: 2004,
    defaultExtension: 'CHD',
    accentColor: Color(0xFF00D2B4),
    retroApiSlug: 'psp',
    romGripperType: 'psp',
  ),
  RommPlatformSpec(
    slug: 'ps1',
    shortName: 'PS1',
    fullName: 'Sony PlayStation',
    manufacturer: 'Sony',
    releaseYear: 1994,
    defaultExtension: 'CHD',
    accentColor: Color(0xFF38BDF8),
    retroApiSlug: 'psx',
    romGripperType: 'psx',
  ),
  RommPlatformSpec(
    slug: 'snes',
    shortName: 'SNES',
    fullName: 'Super Nintendo',
    manufacturer: 'Nintendo',
    releaseYear: 1990,
    defaultExtension: 'SFC',
    accentColor: Color(0xFFA78BFA),
    retroApiSlug: 'snes',
    romGripperType: 'snes',
  ),
  RommPlatformSpec(
    slug: 'gba',
    shortName: 'GBA',
    fullName: 'Game Boy Advance',
    manufacturer: 'Nintendo',
    releaseYear: 2001,
    defaultExtension: 'GBA',
    accentColor: Color(0xFF34D399),
    retroApiSlug: 'gba',
    romGripperType: 'gba',
  ),
  RommPlatformSpec(
    slug: 'nds',
    shortName: 'NDS',
    fullName: 'Nintendo DS',
    manufacturer: 'Nintendo',
    releaseYear: 2004,
    defaultExtension: 'NDS',
    accentColor: Color(0xFFF472B6),
    retroApiSlug: 'nds',
    romGripperType: 'nds',
  ),
  RommPlatformSpec(
    slug: 'n64',
    shortName: 'N64',
    fullName: 'Nintendo 64',
    manufacturer: 'Nintendo',
    releaseYear: 1996,
    defaultExtension: 'Z64',
    accentColor: Color(0xFFFBBF24),
    retroApiSlug: 'n64',
    romGripperType: 'n64',
  ),
  RommPlatformSpec(
    slug: 'md',
    shortName: 'MEGA DRIVE',
    fullName: 'Sega Mega Drive / Genesis',
    manufacturer: 'Sega',
    releaseYear: 1988,
    defaultExtension: 'MD',
    accentColor: Color(0xFF60A5FA),
    retroApiSlug: 'megadrive',
    romGripperType: 'genesis',
  ),
  RommPlatformSpec(
    slug: 'nes',
    shortName: 'NES',
    fullName: 'Nintendo Entertainment System',
    manufacturer: 'Nintendo',
    releaseYear: 1983,
    defaultExtension: 'NES',
    accentColor: Color(0xFFF87171),
    retroApiSlug: 'nes',
    romGripperType: 'nes',
  ),
  RommPlatformSpec(
    slug: 'gbc',
    shortName: 'GBC',
    fullName: 'Game Boy Color',
    manufacturer: 'Nintendo',
    releaseYear: 1998,
    defaultExtension: 'GBC',
    accentColor: Color(0xFF2DD4BF),
    retroApiSlug: 'gbc',
    romGripperType: 'gbc',
  ),
  RommPlatformSpec(
    slug: 'gamegear',
    shortName: 'GAME GEAR',
    fullName: 'Sega Game Gear',
    manufacturer: 'Sega',
    releaseYear: 1990,
    defaultExtension: 'GG',
    accentColor: Color(0xFF818CF8),
    retroApiSlug: 'gamegear',
    romGripperType: 'gamegear',
  ),
  RommPlatformSpec(
    slug: 'neogeo',
    shortName: 'NEO GEO',
    fullName: 'SNK Neo Geo',
    manufacturer: 'SNK',
    releaseYear: 1990,
    defaultExtension: 'ZIP',
    accentColor: Color(0xFFF59E0B),
    retroApiSlug: 'mame',
    romGripperType: 'neogeo',
  ),
  RommPlatformSpec(
    slug: 'cps1',
    shortName: 'CPS1 / CPS2',
    fullName: 'Capcom Play System',
    manufacturer: 'Capcom',
    releaseYear: 1988,
    defaultExtension: 'ZIP',
    accentColor: Color(0xFFFB7185),
    retroApiSlug: 'mame',
    romGripperType: 'cps1',
  ),
  RommPlatformSpec(
    slug: 'mame',
    shortName: 'ARCADE',
    fullName: 'MAME Multiple Arcade Machine',
    manufacturer: 'Arcade',
    releaseYear: 1980,
    defaultExtension: 'ZIP',
    accentColor: Color(0xFFC084FC),
    retroApiSlug: 'mame',
    romGripperType: 'mame',
  ),
  RommPlatformSpec(
    slug: 'dreamcast',
    shortName: 'DREAMCAST',
    fullName: 'Sega Dreamcast',
    manufacturer: 'Sega',
    releaseYear: 1998,
    defaultExtension: 'CHD',
    accentColor: Color(0xFFFB923C),
    retroApiSlug: 'dreamcast',
    category: RommPlatformCategory.nextGen3d,
  ),
  RommPlatformSpec(
    slug: 'ps2',
    shortName: 'PS2',
    fullName: 'Sony PlayStation 2',
    manufacturer: 'Sony',
    releaseYear: 2000,
    defaultExtension: 'ISO',
    accentColor: Color(0xFF60A5FA),
    retroApiSlug: 'ps2',
    category: RommPlatformCategory.nextGen3d,
    coreNote:
        'Core Play! ARM64 (HLE sem BIOS obrigatória) — melhor compatibilidade em títulos leves e médios.',
  ),
  RommPlatformSpec(
    slug: 'gamecube',
    shortName: 'GAMECUBE',
    fullName: 'Nintendo GameCube',
    manufacturer: 'Nintendo',
    releaseYear: 2001,
    defaultExtension: 'RVZ',
    accentColor: Color(0xFF818CF8),
    retroApiSlug: 'gamecube',
    category: RommPlatformCategory.nextGen3d,
    coreNote: 'Core Dolphin ARM64 — suporta ISO, GCM, GCZ e RVZ.',
  ),
  RommPlatformSpec(
    slug: 'wii',
    shortName: 'WII',
    fullName: 'Nintendo Wii',
    manufacturer: 'Nintendo',
    releaseYear: 2006,
    defaultExtension: 'WBFS',
    accentColor: Color(0xFF38BDF8),
    retroApiSlug: 'wii',
    category: RommPlatformCategory.nextGen3d,
    coreNote: 'Core Dolphin ARM64 — suporta WBFS, ISO, GCZ e RVZ.',
  ),
  RommPlatformSpec(
    slug: '3ds',
    shortName: '3DS',
    fullName: 'Nintendo 3DS',
    manufacturer: 'Nintendo',
    releaseYear: 2011,
    defaultExtension: '3DS',
    accentColor: Color(0xFFF43F5E),
    retroApiSlug: '3ds',
    category: RommPlatformCategory.handhelds,
    coreNote: 'Core Citra ARM64 — suporta ROMs .3ds, .cci e .cxi descriptografadas.',
  ),
  RommPlatformSpec(
    slug: 'ps3',
    shortName: 'PS3',
    fullName: 'Sony PlayStation 3',
    manufacturer: 'Sony',
    releaseYear: 2006,
    defaultExtension: 'ISO',
    accentColor: Color(0xFFA78BFA),
    retroApiSlug: 'ps3',
    category: RommPlatformCategory.nextGen3d,
    coreNote:
        'Experimental (RPCS3 ARM64): requer Vulkan e PS3UPDAT.PUP importado nas Configurações.',
  ),
  RommPlatformSpec(
    slug: 'saturn',
    shortName: 'SATURN',
    fullName: 'Sega Saturn',
    manufacturer: 'Sega',
    releaseYear: 1994,
    defaultExtension: 'CHD',
    accentColor: Color(0xFF2DD4BF),
    retroApiSlug: 'saturn',
    category: RommPlatformCategory.classics,
    coreNote: 'Core Yabause (HLE integrado) — suporta CHD e BIN/CUE.',
  ),
  RommPlatformSpec(
    slug: 'pce',
    shortName: 'PC ENGINE',
    fullName: 'NEC PC Engine / TurboGrafx-16',
    manufacturer: 'NEC',
    releaseYear: 1987,
    defaultExtension: 'PCE',
    accentColor: Color(0xFFF59E0B),
    retroApiSlug: 'pce',
    category: RommPlatformCategory.classics,
    coreNote: 'Core Beetle PCE Fast — suporta HuCard (.pce) e CD (.chd).',
  ),
  RommPlatformSpec(
    slug: 'gb',
    shortName: 'GAME BOY',
    fullName: 'Nintendo Game Boy',
    manufacturer: 'Nintendo',
    releaseYear: 1989,
    defaultExtension: 'GB',
    accentColor: Color(0xFF84CC16),
    retroApiSlug: 'gb',
    category: RommPlatformCategory.handhelds,
  ),
  RommPlatformSpec(
    slug: 'mastersystem',
    shortName: 'MASTER SYSTEM',
    fullName: 'Sega Master System',
    manufacturer: 'Sega',
    releaseYear: 1985,
    defaultExtension: 'SMS',
    accentColor: Color(0xFFF87171),
    retroApiSlug: 'mastersystem',
    category: RommPlatformCategory.classics,
  ),
  RommPlatformSpec(
    slug: 'android-port',
    shortName: 'PORTS ANDROID',
    fullName: 'Ports de PC para Android',
    manufacturer: 'APK / Comunidade',
    releaseYear: 2026,
    defaultExtension: 'APK',
    accentColor: Color(0xFFFFB454),
    category: RommPlatformCategory.androidPorts,
    coreNote:
        'Ports Android: baixe o APK e o pacote de dados, extraia quando necessário '
        'e use o guia "Onde está / como instalar" dentro de cada port.',
  ),
];

class EmulationGame {
  const EmulationGame({
    required this.igdbId,
    required this.name,
    required this.canonicalNoIntroName,
    required this.summary,
    required this.genres,
    required this.developer,
    required this.releaseYear,
    required this.rating,
    required this.platformName,
    required this.platformSlug,
    required this.directRomUrl,
    this.region = 'USA',
    this.crc32 = '',
    this.gridCoverUrl,
    this.heroBannerUrl,
    this.logoUrl,
    this.estimatedSizeBytes = 0,
    this.localRomPath,
    this.missingRomPath = false,
  });

  final int igdbId;
  final String name;
  final String canonicalNoIntroName;
  final String summary;
  final List<String> genres;
  final String developer;
  final int? releaseYear;
  final double? rating;
  final String platformName;
  final String platformSlug;
  final String directRomUrl;
  final String region;
  final String crc32;
  final String? gridCoverUrl;
  final String? heroBannerUrl;
  final String? logoUrl;
  final int estimatedSizeBytes;
  final String? localRomPath;

  /// Arquivo local ausente no momento da leitura do manifesto (SD removido,
  /// permissão transitória). A entrada é preservada com este flag em vez de
  /// ser descartada.
  final bool missingRomPath;

  factory EmulationGame.empty() => const EmulationGame(
        igdbId: 0,
        name: '',
        canonicalNoIntroName: '',
        summary: '',
        genres: [],
        developer: '',
        releaseYear: null,
        rating: null,
        platformName: '',
        platformSlug: '',
        directRomUrl: '',
      );

  /// Playlist oficial no CDN thumbnails.libretro.com
  String get libretroPlaylistName {
    final p = platformSlug.toLowerCase();
    if (p == 'gba' || p.contains('game boy advance')) {
      return 'Nintendo - Game Boy Advance';
    }
    if (p == 'gbc' || p.contains('game boy color')) {
      return 'Nintendo - Game Boy Color';
    }
    if (p == 'nes' || p.contains('entertainment system')) {
      if (!p.contains('super') && !p.contains('snes')) {
        return 'Nintendo - Nintendo Entertainment System';
      }
    }
    if (p == 'snes' || p.contains('super nintendo')) {
      return 'Nintendo - Super Nintendo Entertainment System';
    }
    if (p == 'n64' || p.contains('nintendo 64')) {
      return 'Nintendo - Nintendo 64';
    }
    if (p == 'nds' || p.contains('nintendo ds')) {
      return 'Nintendo - Nintendo DS';
    }
    if (p == 'md' || p.contains('mega drive') || p.contains('genesis')) {
      return 'Sega - Mega Drive - Genesis';
    }
    if (p == 'gamegear' || p.contains('game gear')) {
      return 'Sega - Game Gear';
    }
    if (p == 'dreamcast') {
      return 'Sega - Dreamcast';
    }
    if (p == 'neogeo') {
      return 'SNK - Neo Geo';
    }
    if (p == 'cps1' || p == 'cps2') {
      return 'FBNeo - Arcade Games';
    }
    if (p == 'mame' || p == 'arcade') {
      return 'MAME';
    }
    if (p == 'gamecube') {
      return 'Nintendo - GameCube';
    }
    if (p == 'wii') {
      return 'Nintendo - Wii';
    }
    if (p == '3ds') {
      return 'Nintendo - Nintendo 3DS';
    }
    if (p == 'ps2' || p.contains('playstation 2')) {
      return 'Sony - PlayStation 2';
    }
    if (p == 'ps3' || p.contains('playstation 3')) {
      return 'Sony - PlayStation 3';
    }
    if (p == 'switch' || p.contains('nintendo switch')) {
      return 'Nintendo - Nintendo Switch';
    }
    if (p == 'saturn') {
      return 'Sega - Saturn';
    }
    if (p == 'pce') {
      return 'NEC - PC Engine - TurboGrafx 16';
    }
    if (p == 'gb') {
      return 'Nintendo - Game Boy';
    }
    if (p == 'mastersystem') {
      return 'Sega - Master System - Mark III';
    }
    if (p == 'ps1' || p == 'psx' || p.contains('playstation')) {
      if (!p.contains('portable') && !p.contains('psp')) {
        return 'Sony - PlayStation';
      }
    }
    if (p == 'psp' || p.contains('playstation portable')) {
      return 'Sony - PlayStation Portable';
    }
    return 'Nintendo - Game Boy Advance';
  }

  String get _sanitizedThumbnailFile {
    final sanitized = canonicalNoIntroName.replaceAll(
      RegExp(r'[&\*/:`<>?\\|"]'),
      '_',
    );
    return '${Uri.encodeComponent(sanitized)}.png';
  }

  /// URL real de Capa Vertical
  String get resolvedGridCoverUrl =>
      gridCoverUrl ??
      'https://thumbnails.libretro.com/${Uri.encodeComponent(libretroPlaylistName)}/Named_Boxarts/$_sanitizedThumbnailFile';

  /// URL real de Banner Horizontal / Screenshot In-Game
  String get resolvedHeroBannerUrl =>
      heroBannerUrl ??
      'https://thumbnails.libretro.com/${Uri.encodeComponent(libretroPlaylistName)}/Named_Snaps/$_sanitizedThumbnailFile';

  /// URL real de Title Screen
  String get resolvedTitleScreenUrl =>
      'https://thumbnails.libretro.com/${Uri.encodeComponent(libretroPlaylistName)}/Named_Titles/$_sanitizedThumbnailFile';

  /// URL real de Logo Transparente
  String get resolvedLogoUrl =>
      logoUrl ??
      'https://thumbnails.libretro.com/${Uri.encodeComponent(libretroPlaylistName)}/Named_Logos/$_sanitizedThumbnailFile';

  /// Escolhe o binário interno do emulador silenciosamente conforme a plataforma
  String get libretroCoreSoName {
    final p = platformSlug.toLowerCase();
    if (p == 'gba' || p == 'gbc' || p == 'gb') {
      return 'mgba_libretro_android.so';
    }
    if (p == 'snes') {
      return 'snes9x_libretro_android.so';
    }
    if (p == 'nes') {
      return 'fceumm_libretro_android.so';
    }
    if (p == 'n64') {
      return 'mupen64plus_next_gles3_libretro_android.so';
    }
    if (p == 'md' ||
        p.contains('genesis') ||
        p == 'gamegear' ||
        p == 'mastersystem') {
      return 'genesis_plus_gx_libretro_android.so';
    }
    if (p == 'ps2' || p.contains('playstation 2')) {
      return 'play_libretro_android.so';
    }
    if (p == 'ps3' || p.contains('playstation 3')) {
      return 'rpcs3_libretro_android.so';
    }
    if (p == 'ps1' || p == 'psx') {
      return 'pcsx_rearmed_libretro_android.so';
    }
    if (p == 'psp') {
      return 'ppsspp_libretro_android.so';
    }
    if (p == 'nds') {
      return 'melonds_libretro_android.so';
    }
    if (p == '3ds') {
      return 'citra_libretro_android.so';
    }
    if (p == 'gamecube' || p == 'wii') {
      return 'dolphin_libretro_android.so';
    }
    if (p == 'saturn') {
      return 'yabause_libretro_android.so';
    }
    if (p == 'pce') {
      return 'mednafen_pce_fast_libretro_android.so';
    }
    if (p == 'neogeo' || p == 'cps1' || p == 'cps2' || p == 'mame') {
      return 'fbneo_libretro_android.so';
    }
    if (p == 'dreamcast') {
      return 'flycast_libretro_android.so';
    }
    return 'mgba_libretro_android.so';
  }

  static String? _romFormatFromPath(String? rawPath) {
    if (rawPath == null || rawPath.trim().isEmpty) return null;
    final lower = rawPath.split('?').first.split('#').first.trim().toLowerCase();
    if (lower.endsWith('.nsp')) return 'NSP';
    if (lower.endsWith('.xci')) return 'XCI';
    if (lower.endsWith('.nsz')) return 'NSZ';
    if (lower.endsWith('.xcz')) return 'XCZ';
    if (lower.endsWith('.nro')) return 'NRO';
    if (lower.endsWith('.nca')) return 'NCA';
    if (lower.endsWith('.rvz')) return 'RVZ';
    if (lower.endsWith('.wbfs')) return 'WBFS';
    if (lower.endsWith('.gcz')) return 'GCZ';
    if (lower.endsWith('.gcm')) return 'GCM';
    if (lower.endsWith('.3ds') ||
        lower.endsWith('.cci') ||
        lower.endsWith('.cxi')) {
      return '3DS';
    }
    if (lower.endsWith('.pkg')) return 'PKG';
    if (lower.endsWith('.pce')) return 'PCE';
    if (lower.endsWith('.sms')) return 'SMS';
    if (lower.endsWith('.chd')) return 'CHD';
    if (lower.endsWith('.cue')) return 'BIN/CUE';
    if (lower.endsWith('.m3u')) return 'DISC';
    if (lower.endsWith('.gdi')) return 'GDI';
    if (lower.endsWith('.cdi')) return 'CDI';
    if (lower.endsWith('.pbp')) return 'PBP';
    if (lower.endsWith('.iso') || lower.endsWith('.cso')) return 'ISO';
    if (lower.endsWith('.nds')) return 'NDS';
    if (lower.endsWith('.z64') ||
        lower.endsWith('.n64') ||
        lower.endsWith('.v64')) {
      return 'Z64';
    }
    if (lower.endsWith('.sfc') || lower.endsWith('.smc')) return 'SFC';
    if (lower.endsWith('.md') ||
        lower.endsWith('.gen') ||
        lower.endsWith('.smd')) {
      return 'MD';
    }
    if (lower.endsWith('.gg')) return 'GG';
    if (lower.endsWith('.nes')) return 'NES';
    if (lower.endsWith('.gbc')) return 'GBC';
    if (lower.endsWith('.gba')) return 'GBA';
    if (lower.endsWith('.gb')) return 'GB';
    if (lower.endsWith('.bin')) return 'BIN';
    if (lower.endsWith('.zip')) return 'ZIP';
    if (lower.endsWith('.7z')) return '7Z';
    return null;
  }

  String get romFormatLabel {
    final fromLocal = _romFormatFromPath(localRomPath);
    if (fromLocal != null) return fromLocal;
    final fromUrl = _romFormatFromPath(directRomUrl);
    if (fromUrl != null) return fromUrl;
    final p = platformSlug.toLowerCase();
    if (p == 'gamecube') return 'RVZ';
    if (p == 'wii') return 'WBFS';
    if (p == '3ds') return '3DS';
    if (p == 'ps2' || p == 'ps3') return 'ISO';
    if (p == 'switch') return 'NSP';
    if (p == 'psp' || p == 'ps1' || p == 'dreamcast' || p == 'saturn') {
      return 'CHD';
    }
    if (p == 'pce') return 'PCE';
    if (p == 'snes') return 'SFC';
    if (p == 'nds') return 'NDS';
    if (p == 'n64') return 'Z64';
    if (p == 'md') return 'MD';
    if (p == 'gamegear') return 'GG';
    if (p == 'mastersystem') return 'SMS';
    if (p == 'nes') return 'NES';
    if (p == 'gbc') return 'GBC';
    if (p == 'gb') return 'GB';
    if (p == 'neogeo' || p == 'cps1' || p == 'mame') return 'ZIP';
    return 'GBA';
  }

  String get fullConsoleName {
    final match = kRommPlatforms.where(
      (p) => p.slug.toLowerCase() == platformSlug.toLowerCase(),
    );
    if (match.isNotEmpty) return match.first.fullName;
    return platformName;
  }

  Color get platformAccentColor {
    final match = kRommPlatforms.where(
      (p) => p.slug.toLowerCase() == platformSlug.toLowerCase(),
    );
    if (match.isNotEmpty) return match.first.accentColor;
    return const Color(0xFFFFFFFF);
  }

  /// Gera um ID inteiro positivo determinístico (FNV-1a 32-bit, faixa > 100000)
  /// a partir de [key], evitando colisão com o catálogo estático (< 100000)
  /// e substituindo `.hashCode` de String (instável entre execuções em Dart).
  static int stableIdFromKey(String key) {
    const int fnvOffsetBasis = 0x811c9dc5;
    const int fnvPrime = 0x01000193;
    var hash = fnvOffsetBasis;
    for (final byte in utf8.encode(key)) {
      hash ^= byte;
      final lo = (hash & 0xFFFF) * fnvPrime;
      final hi = (((hash >>> 16) * fnvPrime) & 0xFFFF) << 16;
      hash = (lo + hi) & 0xFFFFFFFF;
    }
    return 100001 + (hash % 0x7FFE0000);
  }

  static const Map<String, String> _diacriticReplacements = {
    'á': 'a',
    'à': 'a',
    'â': 'a',
    'ã': 'a',
    'ä': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ê': 'e',
    'ë': 'e',
    'í': 'i',
    'ì': 'i',
    'î': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ô': 'o',
    'õ': 'o',
    'ö': 'o',
    'ú': 'u',
    'ù': 'u',
    'û': 'u',
    'ü': 'u',
    'ç': 'c',
    'ñ': 'n',
  };

  /// Normaliza títulos e consultas removendo pontuação e acentos para comparação consistente.
  static String normalizeSearchText(String input) {
    final lower = input.toLowerCase();
    final buffer = StringBuffer();
    for (final rune in lower.runes) {
      final ch = String.fromCharCode(rune);
      buffer.write(_diacriticReplacements[ch] ?? ch);
    }
    return buffer
        .toString()
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }

  bool get hasKnownSize => estimatedSizeBytes > 0;

  String get formattedSize {
    if (estimatedSizeBytes <= 0) return 'Tam. n/d';
    if (estimatedSizeBytes < 1024) return '< 1 KB';
    final mb = estimatedSizeBytes / (1024 * 1024);
    if (mb >= 1024) {
      return '${(mb / 1024).toStringAsFixed(2)} GB';
    }
    if (mb >= 1.0) {
      return '${mb.toStringAsFixed(1)} MB';
    }
    final kb = estimatedSizeBytes / 1024;
    return '${kb.toStringAsFixed(0)} KB';
  }

  EmulationGame copyWith({
    String? directRomUrl,
    String? region,
    String? crc32,
    String? gridCoverUrl,
    String? heroBannerUrl,
    String? logoUrl,
    int? estimatedSizeBytes,
    String? localRomPath,
    bool? missingRomPath,
  }) {
    return EmulationGame(
      igdbId: igdbId,
      name: name,
      canonicalNoIntroName: canonicalNoIntroName,
      summary: summary,
      genres: genres,
      developer: developer,
      releaseYear: releaseYear,
      rating: rating,
      platformName: platformName,
      platformSlug: platformSlug,
      directRomUrl: directRomUrl ?? this.directRomUrl,
      region: region ?? this.region,
      crc32: crc32 ?? this.crc32,
      gridCoverUrl: gridCoverUrl ?? this.gridCoverUrl,
      heroBannerUrl: heroBannerUrl ?? this.heroBannerUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      estimatedSizeBytes: estimatedSizeBytes ?? this.estimatedSizeBytes,
      localRomPath: localRomPath ?? this.localRomPath,
      missingRomPath: missingRomPath ?? this.missingRomPath,
    );
  }
}
