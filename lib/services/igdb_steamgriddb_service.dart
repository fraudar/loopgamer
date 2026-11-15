// ============================================================================
// LoopGamer — Motor de Catálogo Multi-Fonte:
// 1. RetroAPI (https://retroapi.konsumer.workers.dev/api/:platform/:field/:values)
// 2. ROM-Gripper Taxonomy & Intent API (https://romgripper.github.io/ROM-Gripper/en/api)
// 3. Cliente REST API RomM (https://docs.romm.app/latest/ — /api/platforms, /api/roms)
// 4. Descoberta ao vivo no Internet Archive + Libretro Official Thumbnails CDN
// ============================================================================

import 'dart:io';
import 'package:dio/dio.dart';
import '../models/emulation_game.dart';

class IgdbSteamGridService {
  IgdbSteamGridService({
    Dio? dio,
    this.igdbClientId = const String.fromEnvironment('IGDB_CLIENT_ID'),
    this.igdbClientSecret = const String.fromEnvironment('IGDB_CLIENT_SECRET'),
    this.steamGridDbApiKey = const String.fromEnvironment('SGDB_API_KEY'),
  }) : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 14),
              ),
            );

  final Dio _dio;
  final String igdbClientId;
  final String igdbClientSecret;
  final String steamGridDbApiKey;

  String? _cachedIgdbAccessToken;
  DateTime? _tokenExpiry;

  /// Cache em memória das respostas da RetroAPI (retroapi.konsumer.workers.dev)
  static final Map<String, List<EmulationGame>> _retroApiCache = {};

  static const Set<String> _validRomExtensions = {
    '.gba',
    '.gbc',
    '.gb',
    '.sfc',
    '.smc',
    '.nes',
    '.nds',
    '.3ds',
    '.cci',
    '.cxi',
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
    '.wbfs',
    '.gcz',
    '.gcm',
    '.pkg',
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
  };

  int cachedRetroApiCount(String platformSlug) =>
      _retroApiCache[platformSlug.toLowerCase()]?.length ?? 0;

  bool hasMoreRetroApiGames(String platformSlug, int currentLoadedForPlatform) {
    final slug = platformSlug.toLowerCase();
    if (slug == 'todos') return false;
    final total = _retroApiCache[slug]?.length;
    if (total == null) return _retroApiEndpointForPlatform(slug) != null;
    return currentLoadedForPlatform < total;
  }

  /// Consulta a API pública `https://retroapi.konsumer.workers.dev/api/:platform/:field/:values`
  /// que indexa mais de 722.000 ROMs oficiais do Libretro Database em 145 plataformas.
  Future<List<EmulationGame>> fetchFromRetroApiPlatform(
    String platformSlug, {
    int maxPerPlatform = 36,
    int offset = 0,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return const [];
    }
    final slug = platformSlug.toLowerCase();
    if (slug == 'todos') return const [];
    if (_retroApiCache.containsKey(slug)) {
      final cached = _retroApiCache[slug]!;
      if (offset >= cached.length) return const [];
      return cached.skip(offset).take(maxPerPlatform).toList();
    }

    final querySpec = _retroApiEndpointForPlatform(slug);
    if (querySpec == null) return const [];

    try {
      final res = await _dio.get<dynamic>(querySpec.url);
      final data = res.data;
      if (data is! List) return const [];

      final List<EmulationGame> parsed = [];
      final Set<String> seenBaseTitles = {};
      const int maxCachePerPlatform = 240;

      for (final group in data) {
        if (group is! List) continue;
        for (final raw in group.whereType<Map<String, dynamic>>()) {
          final rawName = (raw['name'] as String?)?.trim() ?? '';
          if (rawName.isEmpty) continue;

          final lowerName = rawName.toLowerCase();
          if (lowerName.contains('(beta') ||
              lowerName.contains('(proto') ||
              lowerName.contains('(demo') ||
              lowerName.contains('(sample') ||
              lowerName.contains('(pirate') ||
              lowerName.contains('[b]')) {
            continue;
          }

          // Prioriza lançamentos USA / World / Europe para capas e idioma
          final isPreferredRegion = rawName.contains('(USA') ||
              rawName.contains('(World') ||
              rawName.contains('(Europe') ||
              !rawName.contains('(');
          if (!isPreferredRegion && parsed.length > 16) continue;

          final cleanDisplayTitle = rawName
              .replaceAll(RegExp(r'\s*\([^)]*\)'), '')
              .replaceAll(' - ', ': ')
              .trim();
          if (cleanDisplayTitle.isEmpty) continue;

          final dedupeKey = '${slug}_${cleanDisplayTitle.toLowerCase()}';
          if (!seenBaseTitles.add(dedupeKey)) continue;

          final romName = (raw['rom_name'] as String?) ?? '$rawName.rom';
          final sizeBytes = (raw['size'] as num?)?.toInt() ?? 4194304;
          final crc = ((raw['crc'] as String?) ?? '').toUpperCase();
          final developer = (raw['developer'] as String?) ??
              (raw['publisher'] as String?) ??
              querySpec.defaultDeveloper;
          final rawGenre = (raw['genre'] as String?)?.trim();
          final genre =
              (rawGenre != null && rawGenre.isNotEmpty) ? rawGenre : 'Retro';
          final releaseYear = (raw['releaseyear'] as num?)?.toInt();
          final rawDesc = (raw['description'] as String?)?.trim();
          final region = rawName.contains('(USA')
              ? 'USA'
              : rawName.contains('(Europe')
                  ? 'EUR'
                  : 'WORLD';

          final idSeed = '${slug}_$rawName'.hashCode.abs() % 800000 + 100000;

          parsed.add(
            EmulationGame(
              igdbId: idSeed,
              name: cleanDisplayTitle,
              canonicalNoIntroName: rawName,
              summary: (rawDesc != null && rawDesc.length > 12)
                  ? rawDesc
                  : 'Título clássico de ${querySpec.platformDisplay} desenvolvido por $developer${releaseYear != null ? " ($releaseYear)" : ""}. Catálogo integrado via RetroAPI & ROM-Gripper.',
              genres: [genre, querySpec.platformLabel],
              developer: developer,
              releaseYear: releaseYear,
              rating: 89,
              platformName: querySpec.platformLabel,
              platformSlug: slug,
              region: region,
              crc32: crc,
              estimatedSizeBytes: sizeBytes,
              directRomUrl:
                  'retroapi://$slug/${Uri.encodeComponent(romName)}',
            ),
          );

          if (parsed.length >= maxCachePerPlatform) break;
        }
        if (parsed.length >= maxCachePerPlatform) break;
      }

      _retroApiCache[slug] = parsed;
      if (offset >= parsed.length) return const [];
      return parsed.skip(offset).take(maxPerPlatform).toList();
    } catch (_) {
      return const [];
    }
  }

  ({
    String url,
    String platformLabel,
    String platformDisplay,
    String defaultDeveloper,
  })? _retroApiEndpointForPlatform(String slug) {
    switch (slug) {
      case 'psp':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/psp/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'PSP',
          platformDisplay: 'PlayStation Portable',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'ps1':
      case 'psx':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/psx/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'PS1',
          platformDisplay: 'Sony PlayStation',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'snes':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/snes/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'SNES',
          platformDisplay: 'Super Nintendo',
          defaultDeveloper: 'Nintendo',
        );
      case 'gba':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gba/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GBA',
          platformDisplay: 'Game Boy Advance',
          defaultDeveloper: 'Nintendo',
        );
      case 'nds':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/nds/developer/Nintendo,Capcom,Konami,Sega,Atlus,Square%20Enix,HAL%20Laboratory',
          platformLabel: 'NDS',
          platformDisplay: 'Nintendo DS',
          defaultDeveloper: 'Nintendo',
        );
      case 'n64':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/n64/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'N64',
          platformDisplay: 'Nintendo 64',
          defaultDeveloper: 'Nintendo',
        );
      case 'md':
      case 'genesis':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/megadrive/genre/Action,Adventure,RPG,Fighting,Racing,Platform,Shooter',
          platformLabel: 'MEGA DRIVE',
          platformDisplay: 'Sega Mega Drive',
          defaultDeveloper: 'Sega',
        );
      case 'nes':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/nes/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'NES',
          platformDisplay: 'Nintendo Entertainment System',
          defaultDeveloper: 'Nintendo',
        );
      case 'gbc':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gbc/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GBC',
          platformDisplay: 'Game Boy Color',
          defaultDeveloper: 'Nintendo',
        );
      case 'gamegear':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gamegear/genre/Action,Adventure,RPG,Fighting,Racing,Platform',
          platformLabel: 'GAME GEAR',
          platformDisplay: 'Sega Game Gear',
          defaultDeveloper: 'Sega',
        );
      case 'neogeo':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/SNK',
          platformLabel: 'NEO GEO',
          platformDisplay: 'SNK Neo Geo',
          defaultDeveloper: 'SNK',
        );
      case 'cps1':
      case 'cps2':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/Capcom',
          platformLabel: 'CPS1 / CPS2',
          platformDisplay: 'Capcom Play System',
          defaultDeveloper: 'Capcom',
        );
      case 'mame':
      case 'arcade':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mame/developer/Konami,Namco,Sega,Taito,Irem',
          platformLabel: 'ARCADE',
          platformDisplay: 'MAME Arcade',
          defaultDeveloper: 'Arcade',
        );
      case 'dreamcast':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/dreamcast/developer/Sonic%20Team,Capcom,Namco,SEGA,Treasure,SNK',
          platformLabel: 'DREAMCAST',
          platformDisplay: 'Sega Dreamcast',
          defaultDeveloper: 'Sega',
        );
      case 'ps2':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/ps2/releaseyear/2000,2001,2002,2003,2004,2005,2006',
          platformLabel: 'PS2',
          platformDisplay: 'Sony PlayStation 2',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'gamecube':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gamecube/releaseyear/2001,2002,2003,2004,2005,2006',
          platformLabel: 'GAMECUBE',
          platformDisplay: 'Nintendo GameCube',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case 'wii':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/wii/releaseyear/2006,2007,2008,2009,2010,2011',
          platformLabel: 'WII',
          platformDisplay: 'Nintendo Wii',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case '3ds':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/3ds/releaseyear/2011,2012,2013,2014,2015,2016,2017',
          platformLabel: '3DS',
          platformDisplay: 'Nintendo 3DS',
          defaultDeveloper: 'Nintendo / Third-Party',
        );
      case 'ps3':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/ps3/releaseyear/2006,2007,2008,2009,2010,2011,2012',
          platformLabel: 'PS3',
          platformDisplay: 'Sony PlayStation 3',
          defaultDeveloper: 'Sony / Third-Party',
        );
      case 'saturn':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/saturn/genre/Action,Adventure,RPG,Fighting,Racing,Platform,Shooter',
          platformLabel: 'SATURN',
          platformDisplay: 'Sega Saturn',
          defaultDeveloper: 'Sega / Third-Party',
        );
      case 'pce':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/pce/genre/Action,Adventure,RPG,Fighting,Racing,Platform,Shooter',
          platformLabel: 'PC ENGINE',
          platformDisplay: 'NEC PC Engine',
          defaultDeveloper: 'NEC / Hudson Soft',
        );
      case 'gb':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/gb/genre/Action,Adventure,RPG,Fighting,Platform,Puzzle',
          platformLabel: 'GAME BOY',
          platformDisplay: 'Nintendo Game Boy',
          defaultDeveloper: 'Nintendo',
        );
      case 'mastersystem':
        return (
          url:
              'https://retroapi.konsumer.workers.dev/api/mastersystem/genre/Action,Adventure,RPG,Platform,Shooter',
          platformLabel: 'MASTER SYSTEM',
          platformDisplay: 'Sega Master System',
          defaultDeveloper: 'Sega',
        );
      default:
        return null;
    }
  }

  /// Sincroniza jogos de uma instância RomM real (https://docs.romm.app/latest/)
  /// usando o endpoint oficial `GET {baseUrl}/api/roms`
  Future<List<EmulationGame>> fetchFromRommServer({
    required String serverUrl,
    String apiToken = '',
    String? platformSlug,
    String? searchTerm,
  }) async {
    final cleanBase = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (cleanBase.isEmpty) return const [];

    try {
      final headers = <String, String>{
        'Accept': 'application/json',
        if (apiToken.trim().isNotEmpty)
          'Authorization': apiToken.trim().startsWith('Basic ') ||
                  apiToken.trim().startsWith('Bearer ')
              ? apiToken.trim()
              : 'Bearer ${apiToken.trim()}',
      };

      final queryParams = <String, dynamic>{
        'limit': 150,
        if (searchTerm != null && searchTerm.trim().isNotEmpty)
          'search_term': searchTerm.trim(),
      };

      final res = await _dio.get<dynamic>(
        '$cleanBase/api/roms',
        queryParameters: queryParams,
        options: Options(headers: headers),
      );

      final rawItems = res.data is Map<String, dynamic>
          ? ((res.data as Map<String, dynamic>)['items'] as List<dynamic>? ??
              const [])
          : (res.data is List<dynamic> ? res.data as List<dynamic> : const []);

      final List<EmulationGame> rommGames = [];
      for (final raw in rawItems.whereType<Map<String, dynamic>>()) {
        final id = (raw['id'] as num?)?.toInt() ?? raw.hashCode.abs();
        final name = (raw['name'] as String?) ??
            (raw['fs_name_no_ext'] as String?) ??
            'ROM #$id';
        final fsName = (raw['fs_name'] as String?) ?? '$name.rom';
        final fsNameNoExt = (raw['fs_name_no_ext'] as String?) ?? name;
        final pSlugRaw =
            ((raw['platform_slug'] ?? raw['p_slug'] ?? 'gba') as String)
                .toLowerCase();
        final mapped = _normalizeRommPlatform(pSlugRaw);
        if (platformSlug != null &&
            platformSlug != 'todos' &&
            mapped.slug != platformSlug.toLowerCase()) {
          continue;
        }

        final sizeBytes = (raw['fs_size_bytes'] as num?)?.toInt() ?? 0;
        final crc =
            ((raw['crc_hash'] ?? raw['md5_hash'] ?? '') as String).toUpperCase();
        final summary = (raw['summary'] as String?)?.trim().isNotEmpty == true
            ? (raw['summary'] as String)
            : 'Jogo sincronizado da sua biblioteca RomM (${mapped.name}).';
        final coverUrl = (raw['url_cover'] as String?) ??
            (raw['path_cover_large'] != null
                ? '$cleanBase/${raw['path_cover_large']}'
                : null);

        final directDownloadUrl =
            '$cleanBase/api/roms/$id/content/${Uri.encodeComponent(fsName)}';

        rommGames.add(
          EmulationGame(
            igdbId: (raw['igdb_id'] as num?)?.toInt() ?? (900000 + id),
            name: name,
            canonicalNoIntroName: fsNameNoExt,
            summary: summary,
            genres: ((raw['genres'] as List<dynamic>?)
                    ?.map((e) => e.toString())
                    .toList()) ??
                const ['Retro'],
            developer: ((raw['companies'] as List<dynamic>?)?.isNotEmpty == true)
                ? raw['companies'].first.toString()
                : 'RomM Library',
            releaseYear: (raw['first_release_date'] as num?) != null
                ? DateTime.fromMillisecondsSinceEpoch(
                        (raw['first_release_date'] as num).toInt() * 1000)
                    .year
                : null,
            rating: (raw['average_rating'] as num?)?.toDouble() ?? 88,
            platformName: mapped.name,
            platformSlug: mapped.slug,
            directRomUrl: directDownloadUrl,
            crc32: crc.length > 8 ? crc.substring(0, 8) : crc,
            gridCoverUrl: coverUrl,
            estimatedSizeBytes: sizeBytes,
          ),
        );
      }
      return rommGames;
    } catch (_) {
      return const [];
    }
  }

  ({String name, String slug}) _normalizeRommPlatform(String rawSlug) {
    final s = rawSlug.toLowerCase();
    if (s.contains('switch') || s == 'nsw') {
      return (name: 'SWITCH', slug: 'switch');
    }
    if (s.contains('psp') || s.contains('playstation-portable')) {
      return (name: 'PSP', slug: 'psp');
    }
    if (s == 'ps3' || s.contains('playstation-3') || s.contains('ps3')) {
      return (name: 'PS3', slug: 'ps3');
    }
    if (s == 'ps2' || s.contains('playstation-2') || s.contains('ps2')) {
      return (name: 'PS2', slug: 'ps2');
    }
    if (s == 'psx' || s == 'ps1' || s == 'playstation') {
      return (name: 'PS1', slug: 'ps1');
    }
    if (s.contains('gamecube') || s == 'gc' || s == 'ngc') {
      return (name: 'GAMECUBE', slug: 'gamecube');
    }
    if (s == 'wii' || s.contains('nintendo-wii')) {
      return (name: 'WII', slug: 'wii');
    }
    if (s.contains('3ds') || s.contains('n3ds')) {
      return (name: '3DS', slug: '3ds');
    }
    if (s.contains('snes') || s.contains('sfam')) {
      return (name: 'SNES', slug: 'snes');
    }
    if (s == 'nes' || s == 'famicom') {
      return (name: 'NES', slug: 'nes');
    }
    if (s.contains('n64') || s.contains('nintendo-64')) {
      return (name: 'N64', slug: 'n64');
    }
    if (s.contains('nds') || s.contains('nintendo-ds')) {
      return (name: 'NDS', slug: 'nds');
    }
    if (s.contains('saturn')) {
      return (name: 'SATURN', slug: 'saturn');
    }
    if (s.contains('pce') ||
        s.contains('pc-engine') ||
        s.contains('turbografx') ||
        s.contains('tg16')) {
      return (name: 'PC ENGINE', slug: 'pce');
    }
    if (s.contains('mastersystem') ||
        s.contains('master-system') ||
        s == 'sms') {
      return (name: 'MASTER SYSTEM', slug: 'mastersystem');
    }
    if (s.contains('genesis') || s.contains('megadrive') || s == 'md') {
      return (name: 'MEGA DRIVE', slug: 'md');
    }
    if (s.contains('gamegear') || s.contains('game-gear') || s == 'gg') {
      return (name: 'GAME GEAR', slug: 'gamegear');
    }
    if (s.contains('neogeo') || s.contains('neo-geo')) {
      return (name: 'NEO GEO', slug: 'neogeo');
    }
    if (s.contains('cps1') || s.contains('cps2') || s.contains('cps')) {
      return (name: 'CPS1 / CPS2', slug: 'cps1');
    }
    if (s.contains('mame') || s.contains('arcade') || s.contains('fbneo')) {
      return (name: 'ARCADE', slug: 'mame');
    }
    if (s.contains('dreamcast') || s == 'dc') {
      return (name: 'DREAMCAST', slug: 'dreamcast');
    }
    if (s.contains('gbc') || s.contains('game-boy-color')) {
      return (name: 'GBC', slug: 'gbc');
    }
    if (s == 'gb' || s == 'game-boy' || s == 'gameboy') {
      return (name: 'GAME BOY', slug: 'gb');
    }
    return (name: 'GBA', slug: 'gba');
  }

  Future<String> _getIgdbBearerToken() async {
    if (_cachedIgdbAccessToken != null &&
        _tokenExpiry != null &&
        DateTime.now().isBefore(_tokenExpiry!)) {
      return _cachedIgdbAccessToken!;
    }

    final response = await _dio.post<Map<String, dynamic>>(
      'https://id.twitch.tv/oauth2/token',
      queryParameters: {
        'client_id': igdbClientId,
        'client_secret': igdbClientSecret,
        'grant_type': 'client_credentials',
      },
    );

    final data = response.data!;
    _cachedIgdbAccessToken = data['access_token'] as String;
    final expiresIn = (data['expires_in'] as num?)?.toInt() ?? 3600;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn - 60));
    return _cachedIgdbAccessToken!;
  }

  /// Busca jogos combinando RomM Server, Catálogo Integrado Multi-Console,
  /// RetroAPI (`retroapi.konsumer.workers.dev`) e Internet Archive.
  Future<List<EmulationGame>> searchGames(
    String query, {
    String? platformFilter,
    String rommServerUrl = '',
    String rommApiToken = '',
  }) async {
    final sanitized = query.replaceAll('"', '').trim();
    final List<EmulationGame> results = [];

    // 1. Servidor RomM próprio (se configurado)
    if (rommServerUrl.trim().isNotEmpty) {
      final fromRomm = await fetchFromRommServer(
        serverUrl: rommServerUrl,
        apiToken: rommApiToken,
        platformSlug: platformFilter,
        searchTerm: sanitized,
      );
      results.addAll(fromRomm);
    }

    // 2. Catálogo local + cache da RetroAPI
    final q = sanitized.toLowerCase();
    final allCached = <EmulationGame>[
      ...kVerifiedRealGamesCatalog,
      for (final list in _retroApiCache.values) ...list,
    ];

    for (final g in allCached) {
      final matchesPlatform = platformFilter == null ||
          platformFilter.toUpperCase() == 'TODOS' ||
          g.platformName.toUpperCase() == platformFilter.toUpperCase() ||
          g.platformSlug.toUpperCase() == platformFilter.toUpperCase();
      if (!matchesPlatform) continue;
      if (q.isNotEmpty) {
        final matchesQuery = g.name.toLowerCase().contains(q) ||
            g.developer.toLowerCase().contains(q) ||
            g.platformName.toLowerCase().contains(q) ||
            g.fullConsoleName.toLowerCase().contains(q) ||
            g.genres.any((genre) => genre.toLowerCase().contains(q));
        if (!matchesQuery) continue;
      }
      if (!results.any(
        (r) =>
            r.name.toLowerCase() == g.name.toLowerCase() &&
            r.platformSlug == g.platformSlug,
      )) {
        results.add(g);
      }
    }

    // 3. Se uma plataforma específica estiver selecionada, busca mais jogos na RetroAPI ao vivo
    if (platformFilter != null &&
        platformFilter.toLowerCase() != 'todos' &&
        !_retroApiCache.containsKey(platformFilter.toLowerCase())) {
      final retroPlatformGames = await fetchFromRetroApiPlatform(
        platformFilter.toLowerCase(),
        maxPerPlatform: 48,
      );
      for (final g in retroPlatformGames) {
        if (q.isEmpty ||
            g.name.toLowerCase().contains(q) ||
            g.developer.toLowerCase().contains(q)) {
          if (!results.any(
            (r) =>
                r.name.toLowerCase() == g.name.toLowerCase() &&
                r.platformSlug == g.platformSlug,
          )) {
            results.add(g);
          }
        }
      }
    }

    // 4. Se houver termo de busca, consulta também o Internet Archive desbloqueado
    if (sanitized.isNotEmpty) {
      if (igdbClientId.isNotEmpty && igdbClientSecret.isNotEmpty) {
        try {
          await _getIgdbBearerToken();
        } catch (_) {}
      }
      final archiveMatches = await _searchArchiveOrgRoms(
        sanitized,
        platformFilter: platformFilter,
      );
      for (final m in archiveMatches) {
        if (!results.any((r) => r.name.toLowerCase() == m.name.toLowerCase())) {
          results.add(m);
        }
      }
    }

    return Future.wait(results.map(enrichWithSteamGridDbArt));
  }

  String? _archiveSearchHint(String? platformFilter) {
    final p = platformFilter?.toLowerCase() ?? '';
    if (p.isEmpty || p == 'todos') return null;
    switch (p) {
      case 'ps2':
        return '(ps2 OR "playstation 2")';
      case 'ps3':
        return '(ps3 OR "playstation 3")';
      case 'gamecube':
        return '(gamecube OR ngc)';
      case 'wii':
        return '(wii OR nintendo)';
      case '3ds':
        return '(3ds OR "nintendo 3ds")';
      case 'saturn':
        return 'saturn';
      case 'pce':
        return '("pc engine" OR turbografx)';
      case 'gb':
        return '("game boy" OR gameboy)';
      case 'mastersystem':
        return '"master system"';
      case 'md':
        return '(genesis OR "mega drive")';
      case 'gamegear':
        return '"game gear"';
      case 'switch':
        return '(switch OR nsp OR nro)';
      default:
        return p;
    }
  }

  /// Consulta a API pública do Internet Archive priorizando itens desbloqueados
  Future<List<EmulationGame>> _searchArchiveOrgRoms(
    String query, {
    String? platformFilter,
  }) async {
    try {
      final hint = _archiveSearchHint(platformFilter);
      final qStr = hint == null
          ? 'title:("$query") AND mediatype:(software) AND NOT access-restricted-item:true'
          : 'title:("$query") AND ($hint) AND mediatype:(software) AND NOT access-restricted-item:true';

      Future<List<dynamic>> queryDocs(String searchQuery) async {
        final res = await _dio.get<Map<String, dynamic>>(
          'https://archive.org/advancedsearch.php',
          queryParameters: {
            'q': searchQuery,
            'fl[]': ['identifier', 'title', 'description', 'year'],
            'rows': '12',
            'page': '1',
            'output': 'json',
          },
        );
        return (res.data?['response'] as Map<String, dynamic>?)?['docs']
                as List<dynamic>? ??
            const [];
      }

      var docs = await queryDocs(qStr);
      if (docs.isEmpty && hint != null) {
        docs = await queryDocs(
          'title:("$query") AND mediatype:(software) AND NOT access-restricted-item:true',
        );
      }

      final docMaps = docs.whereType<Map<String, dynamic>>().take(10).toList();
      final metaResponses = await Future.wait(
        docMaps.map((doc) async {
          final id = doc['identifier'] as String?;
          if (id == null) return null;
          try {
            final metaRes = await _dio.get<Map<String, dynamic>>(
              'https://archive.org/metadata/$id',
            );
            return (doc: doc, id: id, data: metaRes.data);
          } catch (_) {
            return null;
          }
        }),
      );

      final List<EmulationGame> found = [];
      for (final entry in metaResponses) {
        if (entry == null) continue;
        final files = (entry.data?['files'] as List<dynamic>?) ?? const [];

        for (final f in files.whereType<Map<String, dynamic>>()) {
          final fileName = (f['name'] as String?) ?? '';
          final lower = fileName.toLowerCase();
          final hasRomExt = _validRomExtensions.any(lower.endsWith);
          if (!hasRomExt) continue;

          final plat = _detectPlatformFromFileName(lower, entry.id);
          if (platformFilter != null &&
              platformFilter.toUpperCase() != 'TODOS' &&
              plat.name.toUpperCase() != platformFilter.toUpperCase() &&
              plat.slug.toUpperCase() != platformFilter.toUpperCase()) {
            continue;
          }

          final sizeBytes = int.tryParse('${f['size'] ?? '0'}') ?? 0;
          final crc = (f['crc32'] as String?)?.toUpperCase() ?? '';
          final directUrl =
              'https://archive.org/download/${entry.id}/${Uri.encodeComponent(fileName)}';

          final cleanTitle = (entry.doc['title'] as String?) ??
              fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), '');

          found.add(
            EmulationGame(
              igdbId: entry.id.hashCode.abs(),
              name: cleanTitle,
              canonicalNoIntroName:
                  fileName.replaceAll(RegExp(r'\.[a-zA-Z0-9]+$'), ''),
              summary: (entry.doc['description']?.toString()) ??
                  'Edição preservada compatível com o catálogo (${plat.name}).',
              genres: const ['Retro', 'Console'],
              developer: 'Lançamento Original',
              releaseYear: int.tryParse('${entry.doc['year'] ?? ''}'),
              rating: 88,
              platformName: plat.name,
              platformSlug: plat.slug,
              directRomUrl: directUrl,
              crc32: crc,
              estimatedSizeBytes: sizeBytes,
            ),
          );
          break;
        }
      }
      return found;
    } catch (_) {
      return const [];
    }
  }

  ({String name, String slug}) _detectPlatformFromFileName(
    String lowerFile,
    String identifier,
  ) {
    final combined = '$lowerFile $identifier'.toLowerCase();
    if (lowerFile.endsWith('.nsp') ||
        lowerFile.endsWith('.xci') ||
        lowerFile.endsWith('.nsz') ||
        lowerFile.endsWith('.xcz') ||
        lowerFile.endsWith('.nro') ||
        lowerFile.endsWith('.nca') ||
        combined.contains('nintendo switch') ||
        RegExp(r'\bswitch\b').hasMatch(combined)) {
      return (name: 'SWITCH', slug: 'switch');
    }
    if (lowerFile.endsWith('.gbc') || combined.contains('game boy color')) {
      return (name: 'GBC', slug: 'gbc');
    }
    if (lowerFile.endsWith('.gba') || RegExp(r'\bgba\b').hasMatch(combined)) {
      return (name: 'GBA', slug: 'gba');
    }
    if (lowerFile.endsWith('.gb') ||
        (RegExp(r'\bgame[\s_-]?boy\b').hasMatch(combined) &&
            !combined.contains('advance') &&
            !combined.contains('color'))) {
      return (name: 'GAME BOY', slug: 'gb');
    }
    if (lowerFile.endsWith('.sms') ||
        combined.contains('master system') ||
        combined.contains('mastersystem')) {
      return (name: 'MASTER SYSTEM', slug: 'mastersystem');
    }
    if (lowerFile.endsWith('.gg') || combined.contains('game gear')) {
      return (name: 'GAME GEAR', slug: 'gamegear');
    }
    if (lowerFile.endsWith('.3ds') ||
        lowerFile.endsWith('.cci') ||
        lowerFile.endsWith('.cxi') ||
        combined.contains('nintendo 3ds') ||
        RegExp(r'\b3ds\b').hasMatch(combined)) {
      return (name: '3DS', slug: '3ds');
    }
    if (lowerFile.endsWith('.rvz') ||
        lowerFile.endsWith('.gcz') ||
        lowerFile.endsWith('.gcm') ||
        combined.contains('gamecube')) {
      return (name: 'GAMECUBE', slug: 'gamecube');
    }
    if (lowerFile.endsWith('.wbfs') || RegExp(r'\bwii\b').hasMatch(combined)) {
      return (name: 'WII', slug: 'wii');
    }
    if (lowerFile.endsWith('.pce') ||
        combined.contains('pc engine') ||
        combined.contains('turbografx')) {
      return (name: 'PC ENGINE', slug: 'pce');
    }
    if (combined.contains('saturn')) {
      return (name: 'SATURN', slug: 'saturn');
    }
    if (lowerFile.endsWith('.pkg') ||
        combined.contains('ps3') ||
        combined.contains('playstation 3')) {
      return (name: 'PS3', slug: 'ps3');
    }
    if (combined.contains('ps2') || combined.contains('playstation 2')) {
      return (name: 'PS2', slug: 'ps2');
    }
    if (lowerFile.endsWith('.sfc') ||
        lowerFile.endsWith('.smc') ||
        combined.contains('snes')) {
      return (name: 'SNES', slug: 'snes');
    }
    if (lowerFile.endsWith('.nes') || RegExp(r'\bnes\b').hasMatch(combined)) {
      return (name: 'NES', slug: 'nes');
    }
    if (lowerFile.endsWith('.z64') ||
        lowerFile.endsWith('.n64') ||
        lowerFile.endsWith('.v64') ||
        combined.contains('n64')) {
      return (name: 'N64', slug: 'n64');
    }
    if (lowerFile.endsWith('.md') ||
        lowerFile.endsWith('.gen') ||
        lowerFile.endsWith('.smd') ||
        combined.contains('genesis') ||
        combined.contains('mega drive')) {
      return (name: 'MEGA DRIVE', slug: 'md');
    }
    if (lowerFile.endsWith('.nds') || RegExp(r'\bnds\b').hasMatch(combined)) {
      return (name: 'NDS', slug: 'nds');
    }
    if (combined.contains('psp') ||
        lowerFile.endsWith('.cso') ||
        lowerFile.endsWith('.pbp')) {
      return (name: 'PSP', slug: 'psp');
    }
    if (combined.contains('dreamcast')) {
      return (name: 'DREAMCAST', slug: 'dreamcast');
    }
    if (combined.contains('psx') ||
        combined.contains('ps1') ||
        lowerFile.endsWith('.chd')) {
      return (name: 'PS1', slug: 'ps1');
    }
    return (name: 'GBA', slug: 'gba');
  }

  Future<EmulationGame> enrichWithSteamGridDbArt(EmulationGame game) async {
    if (steamGridDbApiKey.isEmpty) return game;

    try {
      final headers = {'Authorization': 'Bearer $steamGridDbApiKey'};
      final encodedName = Uri.encodeComponent(game.name);

      final searchRes = await _dio.get<Map<String, dynamic>>(
        'https://www.steamgriddb.com/api/v2/search/autocomplete/$encodedName',
        options: Options(headers: headers),
      );

      final searchData = searchRes.data?['data'] as List<dynamic>?;
      if (searchData == null || searchData.isEmpty) return game;

      final sgdbGameId =
          (searchData.first as Map<String, dynamic>)['id'] as int;

      final results = await Future.wait([
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/grids/game/$sgdbGameId?dimensions=600x900',
          options: Options(headers: headers),
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/heroes/game/$sgdbGameId',
          options: Options(headers: headers),
        ),
        _dio.get<Map<String, dynamic>>(
          'https://www.steamgriddb.com/api/v2/logos/game/$sgdbGameId',
          options: Options(headers: headers),
        ),
      ]);

      String? firstUrl(Response<Map<String, dynamic>> res) {
        final list = res.data?['data'] as List<dynamic>?;
        if (list == null || list.isEmpty) return null;
        return (list.first as Map<String, dynamic>)['url'] as String?;
      }

      return game.copyWith(
        gridCoverUrl: firstUrl(results[0]),
        heroBannerUrl: firstUrl(results[1]),
        logoUrl: firstUrl(results[2]),
      );
    } catch (_) {
      return game;
    }
  }

  /// Carrega o catálogo completo combinando:
  /// 1. Servidor RomM (se configurado)
  /// 2. Catálogo integrado de 84 jogos em 14 plataformas
  /// 3. Dezenas de jogos adicionais de cada plataforma via RetroAPI (`retroapi.konsumer.workers.dev`)
  Future<List<EmulationGame>> fetchRealCatalog({
    String rommServerUrl = '',
    String rommApiToken = '',
  }) async {
    final List<EmulationGame> combined = [];
    if (rommServerUrl.trim().isNotEmpty) {
      final remote = await fetchFromRommServer(
        serverUrl: rommServerUrl,
        apiToken: rommApiToken,
      );
      combined.addAll(remote);
    }

    for (final g in kVerifiedRealGamesCatalog) {
      if (!combined.any(
        (c) =>
            c.name.toLowerCase() == g.name.toLowerCase() &&
            c.platformSlug == g.platformSlug,
      )) {
        combined.add(g);
      }
    }

    // Busca em paralelo lotes reais da RetroAPI para multiplicar o catálogo em todas as plataformas
    const targetPlatforms = [
      'psp',
      'ps1',
      'ps2',
      'gamecube',
      'wii',
      '3ds',
      'ps3',
      'snes',
      'gba',
      'nds',
      'n64',
      'md',
      'saturn',
      'pce',
      'nes',
      'gbc',
      'gb',
      'gamegear',
      'mastersystem',
      'neogeo',
      'cps1',
      'mame',
      'dreamcast',
    ];

    final retroBatches = await Future.wait(
      targetPlatforms.map(
        (slug) => fetchFromRetroApiPlatform(slug, maxPerPlatform: 16),
      ),
    );

    for (final batch in retroBatches) {
      for (final g in batch) {
        if (!combined.any(
          (c) =>
              c.name.toLowerCase() == g.name.toLowerCase() &&
              c.platformSlug == g.platformSlug,
        )) {
          combined.add(g);
        }
      }
    }

    return Future.wait(combined.map(enrichWithSteamGridDbArt));
  }
}

/// Catálogo base instantâneo cobrindo todas as plataformas do RomM, RetroAPI e ROM-Gripper:
/// PSP, PS1, SNES, GBA, NDS, N64, Mega Drive, NES, GBC, Game Gear, Neo Geo, CPS1/CPS2, Arcade (MAME) e Dreamcast.
const List<EmulationGame> kVerifiedRealGamesCatalog = [
  // ==========================================================================
  // SONY PLAYSTATION PORTABLE (PSP)
  // ==========================================================================
  EmulationGame(
    igdbId: 19560,
    name: 'God of War: Ghost of Sparta',
    canonicalNoIntroName: 'God of War - Ghost of Sparta (USA) (En,Fr,Es)',
    summary:
        'A jornada implacável de Kratos até a cidade submersa de Atlântida e o domínio da Morte para resgatar seu irmão Deimos.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Ready at Dawn / Santa Monica',
    releaseYear: 2010,
    rating: 91,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1195376640,
    directRomUrl:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Ghost%20of%20Sparta%20%28USA%29%20%28PSN%29.iso',
  ),
  EmulationGame(
    igdbId: 549,
    name: 'God of War: Chains of Olympus',
    canonicalNoIntroName: 'God of War - Chains of Olympus (USA)',
    summary:
        'Antes de sua revolta contra o Olimpo, Kratos enfrenta o exército persa e desce ao Mundo Inferior quando Hélios desaparece do céu.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Ready at Dawn',
    releaseYear: 2008,
    rating: 89,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1153433600,
    directRomUrl:
        'https://archive.org/download/god-of-war-ghost-of-sparta-usa-psn/God%20of%20War%20-%20Chains%20of%20Olympus%20%28USA%29%20%28PSN%29.iso',
  ),
  EmulationGame(
    igdbId: 1219,
    name: 'Monster Hunter Freedom Unite',
    canonicalNoIntroName: 'Monster Hunter Freedom Unite (USA)',
    summary:
        'Centenas de horas de caçadas estratégicas contra wyverns colossais, forja de armaduras Rank G e companheiros Felyne.',
    genres: ['Action RPG', 'Caça'],
    developer: 'Capcom',
    releaseYear: 2008,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 882900992,
    directRomUrl: 'retroapi://psp/Monster_Hunter_Freedom_Unite.chd',
  ),
  EmulationGame(
    igdbId: 9927,
    name: 'Shin Megami Tensei: Persona 3 Portable',
    canonicalNoIntroName: 'Shin Megami Tensei - Persona 3 Portable (USA)',
    summary:
        'Viva o cotidiano escolar durante o dia e explore a torre sombria de Tartarus na Hora Negra com dois protagonistas jogáveis.',
    genres: ['JRPG', 'Social Sim'],
    developer: 'Atlus',
    releaseYear: 2010,
    rating: 92,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 954204160,
    directRomUrl: 'retroapi://psp/Persona_3_Portable.chd',
  ),
  EmulationGame(
    igdbId: 433,
    name: 'Crisis Core: Final Fantasy VII',
    canonicalNoIntroName: 'Crisis Core - Final Fantasy VII (USA)',
    summary:
        'Acompanhe a ascensão de Zack Fair na SOLDIER, sua amizade com Cloud e os segredos por trás do Projeto Jenova e Sephiroth.',
    genres: ['Action RPG'],
    developer: 'Square Enix',
    releaseYear: 2008,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1090519040,
    directRomUrl: 'retroapi://psp/Crisis_Core_Final_Fantasy_VII.chd',
  ),
  EmulationGame(
    igdbId: 730,
    name: 'Grand Theft Auto: Vice City Stories',
    canonicalNoIntroName: 'Grand Theft Auto - Vice City Stories (USA) (v1.03)',
    summary:
        'Domine o império do crime na Vice City de 1984 com construção de negócios, combate naval e trilha sonora icônica dos anos 80.',
    genres: ['Mundo Aberto', 'Ação'],
    developer: 'Rockstar Leeds',
    releaseYear: 2006,
    rating: 88,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 985661440,
    directRomUrl:
        'https://archive.org/download/grand-theft-auto-vice-city-stories-europe-psp_202603_ver2/Grand%20Theft%20Auto%20-%20Vice%20City%20Stories%20%28Europe%29.iso',
  ),
  EmulationGame(
    igdbId: 729,
    name: 'Grand Theft Auto: Liberty City Stories',
    canonicalNoIntroName:
        'Grand Theft Auto - Liberty City Stories (USA) (En,Fr,De,Es,It) (v3.00)',
    summary:
        'Toni Cipriani retorna a Liberty City em 1998 para retomar o controle da família Leone em meio à guerra entre máfias.',
    genres: ['Mundo Aberto', 'Ação'],
    developer: 'Rockstar Leeds',
    releaseYear: 2005,
    rating: 87,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 744488960,
    directRomUrl: 'retroapi://psp/GTA_Liberty_City_Stories.chd',
  ),
  EmulationGame(
    igdbId: 1265,
    name: 'Tekken 6',
    canonicalNoIntroName: 'Tekken 6 (USA) (En,Fr,De,Es,It,Ru)',
    summary:
        'O sexto Torneio do Punho de Ferro traz 40 lutadores, sistema Rage, arenas destrutíveis e combate técnico a 60 quadros por segundo.',
    genres: ['Luta', 'Arcade'],
    developer: 'Bandai Namco',
    releaseYear: 2009,
    rating: 88,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 692060160,
    directRomUrl: 'https://archive.org/download/tekken-6_202309/Tekken%206.iso',
  ),
  EmulationGame(
    igdbId: 382,
    name: 'Metal Gear Solid: Peace Walker',
    canonicalNoIntroName: 'Metal Gear Solid - Peace Walker (USA)',
    summary:
        'Big Boss lidera os Militaires Sans Frontières na Costa Rica de 1974, expandindo a Mother Base e enfrentando armas autônomas de IA.',
    genres: ['Stealth', 'Ação Tática'],
    developer: 'Kojima Productions',
    releaseYear: 2010,
    rating: 93,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1289748480,
    directRomUrl: 'retroapi://psp/Metal_Gear_Solid_Peace_Walker.chd',
  ),
  EmulationGame(
    igdbId: 1211,
    name: 'Kingdom Hearts: Birth by Sleep',
    canonicalNoIntroName: 'Kingdom Hearts - Birth by Sleep (USA)',
    summary:
        'Três mestres da Keyblade — Terra, Ventus e Aqua — cruzam mundos encantados para desvendar as origens de Mestre Xehanort.',
    genres: ['Action RPG'],
    developer: 'Square Enix',
    releaseYear: 2010,
    rating: 90,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 1321205760,
    directRomUrl: 'retroapi://psp/Kingdom_Hearts_Birth_by_Sleep.chd',
  ),
  EmulationGame(
    igdbId: 2491,
    name: 'Daxter',
    canonicalNoIntroName: 'Daxter (USA)',
    summary:
        'Enquanto Jak está preso em Haven City, Daxter assume o protagonismo como exterminador de insetos metálicos em plataformas acrobáticas.',
    genres: ['Plataforma 3D', 'Aventura'],
    developer: 'Ready at Dawn',
    releaseYear: 2006,
    rating: 86,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 723517440,
    directRomUrl: 'retroapi://psp/Daxter.chd',
  ),
  EmulationGame(
    igdbId: 3101,
    name: 'Midnight Club 3: DUB Edition',
    canonicalNoIntroName: 'Midnight Club 3 - DUB Edition (USA)',
    summary:
        'Corridas urbanas noturnas em alta velocidade pelas ruas de San Diego, Atlanta e Detroit com personalização completa.',
    genres: ['Corrida', 'Arcade'],
    developer: 'Rockstar San Diego',
    releaseYear: 2005,
    rating: 87,
    platformName: 'PSP',
    platformSlug: 'psp',
    region: 'USA',
    estimatedSizeBytes: 964689920,
    directRomUrl: 'retroapi://psp/Midnight_Club_3_DUB_Edition.chd',
  ),

  // ==========================================================================
  // SONY PLAYSTATION (PS1 / PSX)
  // ==========================================================================
  EmulationGame(
    igdbId: 1120,
    name: 'Castlevania: Symphony of the Night',
    canonicalNoIntroName: 'Castlevania - Symphony of the Night (USA)',
    summary:
        'Alucard desperta de seu sono eterno para explorar o castelo invertido de Drácula, combinando elementos de RPG, relíquias e magias ocultas.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 1997,
    rating: 95,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 376438784,
    directRomUrl: 'retroapi://ps1/Castlevania_Symphony_of_the_Night.chd',
  ),
  EmulationGame(
    igdbId: 375,
    name: 'Metal Gear Solid',
    canonicalNoIntroName: 'Metal Gear Solid (USA) (Disc 1) (Rev 1)',
    summary:
        'Solid Snake infiltra-se na ilha de Shadow Moses no Alasca para neutralizar a unidade renegada FOXHOUND e o tanque bípede nuclear REX.',
    genres: ['Stealth', 'Ação Cinematográfica'],
    developer: 'Konami',
    releaseYear: 1998,
    rating: 96,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 498073600,
    directRomUrl: 'retroapi://ps1/Metal_Gear_Solid.chd',
  ),
  EmulationGame(
    igdbId: 427,
    name: 'Final Fantasy VII',
    canonicalNoIntroName: 'Final Fantasy VII (USA) (Disc 1)',
    summary:
        'Cloud Strife e o grupo eco-rebelde AVALANCHE enfrentam a megacorporação Shinra e a ameaça planetária de Sephiroth.',
    genres: ['JRPG', 'Aventura'],
    developer: 'Square',
    releaseYear: 1997,
    rating: 95,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 461373440,
    directRomUrl: 'retroapi://ps1/Final_Fantasy_VII.chd',
  ),
  EmulationGame(
    igdbId: 966,
    name: 'Resident Evil 2',
    canonicalNoIntroName: 'Resident Evil 2 (USA) (Disc 1)',
    summary:
        'Leon S. Kennedy e Claire Redfield lutam para escapar de uma Raccoon City devastada pelo T-Virus da Umbrella Corporation.',
    genres: ['Survival Horror'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 412090368,
    directRomUrl: 'retroapi://ps1/Resident_Evil_2.chd',
  ),
  EmulationGame(
    igdbId: 481,
    name: 'Silent Hill',
    canonicalNoIntroName: 'Silent Hill (USA)',
    summary:
        'Harry Mason procura sua filha adotiva Cheryl pelas ruas cobertas de neblina e cinzas da misteriosa cidade de Silent Hill.',
    genres: ['Survival Horror', 'Terror Psicológico'],
    developer: 'Konami (Team Silent)',
    releaseYear: 1999,
    rating: 91,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 318767104,
    directRomUrl: 'retroapi://ps1/Silent_Hill.chd',
  ),
  EmulationGame(
    igdbId: 1263,
    name: 'Tekken 3',
    canonicalNoIntroName: 'Tekken 3 (USA)',
    summary:
        'A estreia de Jin Kazama, Eddy Gordo e Hwoarang com movimentação lateral fluida, modo Tekken Force e trilha sonora lendária.',
    genres: ['Luta 3D', 'Arcade'],
    developer: 'Namco',
    releaseYear: 1998,
    rating: 94,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 429916160,
    directRomUrl: 'retroapi://ps1/Tekken_3.chd',
  ),
  EmulationGame(
    igdbId: 1185,
    name: 'Crash Bandicoot: Warped',
    canonicalNoIntroName: 'Crash Bandicoot - Warped (USA)',
    summary:
        'Crash e Coco viajam através do Tornado do Tempo desde a Muralha da China até o futuro para impedir os planos de Cortex e Uka Uka.',
    genres: ['Plataforma 3D'],
    developer: 'Naughty Dog',
    releaseYear: 1998,
    rating: 91,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 188743680,
    directRomUrl: 'retroapi://ps1/Crash_Bandicoot_Warped.chd',
  ),
  EmulationGame(
    igdbId: 1192,
    name: 'Crash Team Racing',
    canonicalNoIntroName: 'Crash Team Racing (USA)',
    summary:
        'Corridas de kart frenéticas com sistema de turbo por derrapagem tripla, modo Aventura completo e batalhas em arena contra Nitros Oxide.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Naughty Dog',
    releaseYear: 1999,
    rating: 92,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 272629760,
    directRomUrl: 'retroapi://ps1/Crash_Team_Racing.chd',
  ),
  EmulationGame(
    igdbId: 1380,
    name: 'Gran Turismo 2',
    canonicalNoIntroName: 'Gran Turismo 2 (USA) (Simulation Mode) (Rev 1)',
    summary:
        'Mais de 650 automóveis licenciados, provas de rali, carteiras de habilitação e ajuste fino de suspensão e câmbio.',
    genres: ['Simulador de Corrida'],
    developer: 'Polyphony Digital',
    releaseYear: 1999,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 440401920,
    directRomUrl: 'retroapi://ps1/Gran_Turismo_2.chd',
  ),
  EmulationGame(
    igdbId: 430,
    name: 'Chrono Cross',
    canonicalNoIntroName: 'Chrono Cross (USA) (Disc 1)',
    summary:
        'Serge atravessa duas dimensões paralelas no arquipélago de El Nido com mais de 40 aliados recrutáveis e trilha de Yasunori Mitsuda.',
    genres: ['JRPG'],
    developer: 'Square',
    releaseYear: 2000,
    rating: 93,
    platformName: 'PS1',
    platformSlug: 'ps1',
    region: 'USA',
    estimatedSizeBytes: 419430400,
    directRomUrl: 'retroapi://ps1/Chrono_Cross.chd',
  ),

  // ==========================================================================
  // SUPER NINTENDO (SNES)
  // ==========================================================================
  EmulationGame(
    igdbId: 428,
    name: 'Chrono Trigger',
    canonicalNoIntroName: 'Chrono Trigger (USA)',
    summary:
        'Crono, Marle, Lucca, Frog e Robo viajam desde a Pré-História até o ano 2300 d.C. para impedir que Lavos destrua o planeta.',
    genres: ['JRPG', 'Viagem no Tempo'],
    developer: 'Square',
    releaseYear: 1995,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2998272,
    directRomUrl: 'retroapi://snes/Chrono_Trigger.sfc',
  ),
  EmulationGame(
    igdbId: 1029,
    name: 'The Legend of Zelda: A Link to the Past',
    canonicalNoIntroName: 'Legend of Zelda, The - A Link to the Past (USA)',
    summary:
        'Cruze os portais entre o Mundo da Luz e o Mundo das Trevas em Hyrule, empunhe a Master Sword e liberte as Sete Donzelas.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 1991,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 702464,
    directRomUrl: 'retroapi://snes/Zelda_A_Link_to_the_Past.sfc',
  ),
  EmulationGame(
    igdbId: 1070,
    name: 'Super Metroid',
    canonicalNoIntroName: 'Super Metroid (Japan, USA) (En,Ja)',
    summary:
        'Samus Aran desce às profundezas interconectadas do planeta Zebes em uma obra-prima de atmosfera, exploração não linear e combate sci-fi.',
    genres: ['Metroidvania', 'Sci-Fi'],
    developer: 'Nintendo R&D1',
    releaseYear: 1994,
    rating: 96,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 1716224,
    directRomUrl: 'retroapi://snes/Super_Metroid.sfc',
  ),
  EmulationGame(
    igdbId: 1068,
    name: 'Super Mario World',
    canonicalNoIntroName: 'Super Mario World (USA)',
    summary:
        'A estreia de Yoshi na Dinosaur Land com 96 saídas secretas, Palácios dos Blocos, Capa Voadora e a fortaleza de Bowser.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo EAD',
    releaseYear: 1990,
    rating: 97,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 348160,
    directRomUrl: 'retroapi://snes/Super_Mario_World.sfc',
  ),
  EmulationGame(
    igdbId: 1090,
    name: 'Donkey Kong Country 2: Diddy\'s Kong Quest',
    canonicalNoIntroName:
        'Donkey Kong Country 2 - Diddy\'s Kong Quest (USA) (En,Fr) (Rev 1)',
    summary:
        'Diddy e Dixie Kong invadem a Ilha dos Crocodilos para resgatar Donkey Kong ao som da inesquecível trilha sonora de David Wise.',
    genres: ['Plataforma 2D', 'Aventura'],
    developer: 'Rare',
    releaseYear: 1995,
    rating: 94,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2621440,
    directRomUrl: 'retroapi://snes/Donkey_Kong_Country_2.sfc',
  ),
  EmulationGame(
    igdbId: 1711,
    name: 'Mega Man X',
    canonicalNoIntroName: 'Mega Man X (USA) (Rev 1)',
    summary:
        'O caçador de Mavericks X e seu aliado Zero enfrentam a rebelião liderada por Sigma, adquirindo cápsulas de armadura e armas especiais.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Capcom',
    releaseYear: 1993,
    rating: 93,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 1126400,
    directRomUrl: 'retroapi://snes/Mega_Man_X.sfc',
  ),
  EmulationGame(
    igdbId: 426,
    name: 'Final Fantasy III (VI)',
    canonicalNoIntroName: 'Final Fantasy III (USA) (Rev 1)',
    summary:
        'Terra Branford e os Returners desafiam o Império Gestahliano e a loucura apocalíptica de Kefka em um mundo movido a Magitek.',
    genres: ['JRPG'],
    developer: 'Square',
    releaseYear: 1994,
    rating: 95,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2293760,
    directRomUrl: 'retroapi://snes/Final_Fantasy_III.sfc',
  ),
  EmulationGame(
    igdbId: 1072,
    name: 'Super Mario RPG: Legend of the Seven Stars',
    canonicalNoIntroName: 'Super Mario RPG - Legend of the Seven Stars (USA)',
    summary:
        'Mario, Bowser, Peach, Mallow e Geno unem forças em combates por turnos cronometrados para restaurar a Star Road contra Smithy.',
    genres: ['JRPG', 'Aventura'],
    developer: 'Square / Nintendo',
    releaseYear: 1996,
    rating: 92,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2883584,
    directRomUrl: 'retroapi://snes/Super_Mario_RPG.sfc',
  ),
  EmulationGame(
    igdbId: 1074,
    name: 'EarthBound',
    canonicalNoIntroName: 'EarthBound (USA)',
    summary:
        'Ness e seus amigos percorrem cidades modernas, desertos e dimensões surreais usando poderes PSI contra o invasor cósmico Giygas.',
    genres: ['JRPG', 'Cult Classic'],
    developer: 'Ape / HAL Laboratory',
    releaseYear: 1995,
    rating: 93,
    platformName: 'SNES',
    platformSlug: 'snes',
    region: 'USA',
    estimatedSizeBytes: 2162688,
    directRomUrl: 'retroapi://snes/EarthBound.sfc',
  ),

  // ==========================================================================
  // GAME BOY ADVANCE (GBA)
  // ==========================================================================
  EmulationGame(
    igdbId: 1515,
    name: 'Pokémon Emerald Version',
    canonicalNoIntroName: 'Pokemon - Emerald Version (USA, Europe)',
    summary:
        'A edição definitiva da região de Hoenn: detenha o despertar de Groudon e Kyogre com a ajuda de Rayquaza e domine a Battle Frontier.',
    genres: ['RPG', 'Coleção de Monstros'],
    developer: 'Game Freak',
    releaseYear: 2005,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 6606028,
    directRomUrl: 'retroapi://gba/Pokemon_Emerald.gba',
  ),
  EmulationGame(
    igdbId: 1559,
    name: 'Pokémon FireRed Version',
    canonicalNoIntroName: 'Pokemon - FireRed Version (USA, Europe) (Rev 1)',
    summary:
        'Retorne à região de Kanto totalmente recriada no GBA, derrote a Equipe Rocket, explore as Sevii Islands e conquiste a Liga Índigo.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2004,
    rating: 90,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5452595,
    directRomUrl: 'retroapi://gba/Pokemon_FireRed.gba',
  ),
  EmulationGame(
    igdbId: 1557,
    name: 'Metroid Fusion',
    canonicalNoIntroName: 'Metroid Fusion (USA)',
    summary:
        'Infectada pelo parasita X e salva por uma vacina de DNA Metroid, Samus investiga os setores biológicos da estação espacial BSL.',
    genres: ['Metroidvania', 'Ação'],
    developer: 'Nintendo R&D1',
    releaseYear: 2002,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 4613734,
    directRomUrl: 'retroapi://gba/Metroid_Fusion.gba',
  ),
  EmulationGame(
    igdbId: 1558,
    name: 'Metroid: Zero Mission',
    canonicalNoIntroName: 'Metroid - Zero Mission (USA)',
    summary:
        'Reimaginação veloz da primeira missão de Samus em Zebes, incluindo o capítulo inédito de infiltração furtiva na nave-mãe Space Pirate.',
    genres: ['Metroidvania', 'Ação'],
    developer: 'Nintendo R&D1',
    releaseYear: 2004,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 4404019,
    directRomUrl: 'retroapi://gba/Metroid_Zero_Mission.gba',
  ),
  EmulationGame(
    igdbId: 1037,
    name: 'The Legend of Zelda: The Minish Cap',
    canonicalNoIntroName: 'Legend of Zelda, The - The Minish Cap (USA)',
    summary:
        'Com o gorro falante Ezlo, Link encolhe ao tamanho do povo Minish para forjar a Espada Quádrupla e derrotar o feiticeiro Vaati.',
    genres: ['Action Adventure'],
    developer: 'Capcom / Flagship',
    releaseYear: 2004,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 8178892,
    directRomUrl: 'retroapi://gba/Zelda_The_Minish_Cap.gba',
  ),
  EmulationGame(
    igdbId: 1126,
    name: 'Castlevania: Aria of Sorrow',
    canonicalNoIntroName: 'Castlevania - Aria of Sorrow (USA)',
    summary:
        'Em 2035, Soma Cruz é transportado para um castelo selado dentro de um eclipse solar e descobre o poder de dominar as almas dos monstros.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 2003,
    rating: 93,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5138022,
    directRomUrl: 'retroapi://gba/Castlevania_Aria_of_Sorrow.gba',
  ),
  EmulationGame(
    igdbId: 1442,
    name: 'Golden Sun',
    canonicalNoIntroName: 'Golden Sun (USA, Europe)',
    summary:
        'Isaac e os Adeptos de Vale partem pelo continente de Weyard combinando criaturas elementais Djinn e magias de Psynergy.',
    genres: ['JRPG'],
    developer: 'Camelot Software Planning',
    releaseYear: 2001,
    rating: 91,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 5872025,
    directRomUrl: 'retroapi://gba/Golden_Sun.gba',
  ),
  EmulationGame(
    igdbId: 1460,
    name: 'Fire Emblem',
    canonicalNoIntroName: 'Fire Emblem (USA, Australia)',
    summary:
        'Comande os exércitos de Lyndis, Eliwood e Hector em batalhas táticas por turnos onde cada decisão no campo de batalha é permanente.',
    genres: ['RPG Tático', 'Estratégia'],
    developer: 'Intelligent Systems',
    releaseYear: 2003,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 7654604,
    directRomUrl: 'retroapi://gba/Fire_Emblem.gba',
  ),
  EmulationGame(
    igdbId: 1628,
    name: 'Advance Wars',
    canonicalNoIntroName: 'Advance Wars (USA) (Rev 1)',
    summary:
        'Lidere os Comandantes da nação Orange Star em combates estratégicos de infantaria, blindados, força aérea e marinha.',
    genres: ['Estratégia por Turnos'],
    developer: 'Intelligent Systems',
    releaseYear: 2001,
    rating: 92,
    platformName: 'GBA',
    platformSlug: 'gba',
    region: 'USA',
    estimatedSizeBytes: 2831155,
    directRomUrl: 'retroapi://gba/Advance_Wars.gba',
  ),

  // ==========================================================================
  // NINTENDO DS (NDS)
  // ==========================================================================
  EmulationGame(
    igdbId: 1512,
    name: 'Pokémon Platinum Version',
    canonicalNoIntroName: 'Pokemon - Platinum Version (USA)',
    summary:
        'Desafie os planos de Cyrus e da Equipe Galáctica, atravesse as leis da física no Distortion World de Giratina e conquiste Sinnoh.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2008,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 51380224,
    directRomUrl: 'retroapi://nds/Pokemon_Platinum.nds',
  ),
  EmulationGame(
    igdbId: 1518,
    name: 'Pokémon HeartGold Version',
    canonicalNoIntroName: 'Pokemon - HeartGold Version (USA)',
    summary:
        'Percorra as duas regiões completas de Johto e Kanto com seu Pokémon caminhando ao seu lado, conquiste 16 insígnias e enfrente Red no Mt. Silver.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2009,
    rating: 94,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 60817408,
    directRomUrl: 'retroapi://nds/Pokemon_HeartGold.nds',
  ),
  EmulationGame(
    igdbId: 1522,
    name: 'Pokémon Black Version',
    canonicalNoIntroName:
        'Pokemon - Black Version (USA, Europe) (NDSi Enhanced)',
    summary:
        'Explore a metrópole de Unova com batalhas animadas em tempo real, estações do ano dinâmicas e o embate ideológico contra N e a Equipe Plasma.',
    genres: ['RPG'],
    developer: 'Game Freak',
    releaseYear: 2011,
    rating: 90,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 109051904,
    directRomUrl: 'retroapi://nds/Pokemon_Black.nds',
  ),
  EmulationGame(
    igdbId: 2348,
    name: 'Mario Kart DS',
    canonicalNoIntroName: 'Mario Kart DS (USA) (En,Fr,De,Es,It)',
    summary:
        '32 pistas clássicas e inéditas, modo Missões contra chefes, personalização de emblemas e derrapagens técnicas em alta velocidade.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Nintendo EAD',
    releaseYear: 2005,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 18874368,
    directRomUrl: 'retroapi://nds/Mario_Kart_DS.nds',
  ),
  EmulationGame(
    igdbId: 1081,
    name: 'New Super Mario Bros.',
    canonicalNoIntroName: 'New Super Mario Bros. (USA)',
    summary:
        'Plataforma 2.5D vibrante com novos power-ups como Mega Cogumelo, Casco Azul e Mini Cogumelo através de oito mundos repletos de passagens ocultas.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo EAD',
    releaseYear: 2006,
    rating: 89,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 16777216,
    directRomUrl: 'retroapi://nds/New_Super_Mario_Bros.nds',
  ),
  EmulationGame(
    igdbId: 1129,
    name: 'Castlevania: Dawn of Sorrow',
    canonicalNoIntroName: 'Castlevania - Dawn of Sorrow (USA)',
    summary:
        'Continuação direta de Aria of Sorrow: Soma Cruz enfrenta uma seita que tenta criar um novo Lorde das Trevas, usando selos mágicos e síntese de armas.',
    genres: ['Metroidvania', 'Action RPG'],
    developer: 'Konami',
    releaseYear: 2005,
    rating: 91,
    platformName: 'NDS',
    platformSlug: 'nds',
    region: 'USA',
    estimatedSizeBytes: 31457280,
    directRomUrl: 'retroapi://nds/Castlevania_Dawn_of_Sorrow.nds',
  ),

  // ==========================================================================
  // NINTENDO 64 (N64)
  // ==========================================================================
  EmulationGame(
    igdbId: 1030,
    name: 'The Legend of Zelda: Ocarina of Time',
    canonicalNoIntroName: 'Legend of Zelda, The - Ocarina of Time (USA)',
    summary:
        'Viaje sete anos no tempo entre a infância e a idade adulta de Link, domine melodias sagradas na Ocarina e impeça o reinado de Ganondorf.',
    genres: ['Action Adventure', 'Fantasia'],
    developer: 'Nintendo EAD',
    releaseYear: 1998,
    rating: 99,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 26214400,
    directRomUrl: 'retroapi://n64/Zelda_Ocarina_of_Time.z64',
  ),
  EmulationGame(
    igdbId: 10740,
    name: 'Super Mario 64',
    canonicalNoIntroName: 'Super Mario 64 (USA)',
    summary:
        'Salte para dentro dos quadros encantados do Castelo da Princesa Peach e colete 120 Power Stars no marco fundador dos jogos de plataforma 3D.',
    genres: ['Plataforma 3D'],
    developer: 'Nintendo EAD',
    releaseYear: 1996,
    rating: 97,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 6291456,
    directRomUrl: 'retroapi://n64/Super_Mario_64.z64',
  ),
  EmulationGame(
    igdbId: 1031,
    name: 'The Legend of Zelda: Majora\'s Mask',
    canonicalNoIntroName: 'Legend of Zelda, The - Majora\'s Mask (USA)',
    summary:
        'Três dias antes que a Lua colida contra a terra de Termina: use máscaras de transformação e volte no tempo para salvar seus habitantes.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 2000,
    rating: 95,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 27262976,
    directRomUrl: 'retroapi://n64/Zelda_Majoras_Mask.z64',
  ),
  EmulationGame(
    igdbId: 2342,
    name: 'Mario Kart 64',
    canonicalNoIntroName: 'Mario Kart 64 (USA)',
    summary:
        'Disputas lendárias na Rainbow Road, Bowser\'s Castle e Koopa Troopa Beach com quatro copas completas e modo Batalha em arenas 3D.',
    genres: ['Corrida de Kart', 'Arcade'],
    developer: 'Nintendo EAD',
    releaseYear: 1997,
    rating: 91,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 8388608,
    directRomUrl: 'retroapi://n64/Mario_Kart_64.z64',
  ),
  EmulationGame(
    igdbId: 1626,
    name: 'Super Smash Bros.',
    canonicalNoIntroName: 'Super Smash Bros. (USA)',
    summary:
        'Os maiores heróis da Nintendo — Mario, Link, Samus, Pikachu, Fox e Kirby — colidem em arenas dinâmicas onde o objetivo é arremessar o rival para fora.',
    genres: ['Luta em Plataforma'],
    developer: 'HAL Laboratory',
    releaseYear: 1999,
    rating: 90,
    platformName: 'N64',
    platformSlug: 'n64',
    region: 'USA',
    estimatedSizeBytes: 12582912,
    directRomUrl: 'retroapi://n64/Super_Smash_Bros.z64',
  ),

  // ==========================================================================
  // SEGA MEGA DRIVE / GENESIS (MD)
  // ==========================================================================
  EmulationGame(
    igdbId: 3192,
    name: 'Sonic the Hedgehog 2',
    canonicalNoIntroName: 'Sonic The Hedgehog 2 (World) (Rev A)',
    summary:
        'Sonic e Miles "Tails" Prower aceleram por Emerald Hill, Chemical Plant e Casino Night para coletar as 7 Esmeraldas do Caos e derrotar o Death Egg.',
    genres: ['Plataforma 2D', 'Velocidade'],
    developer: 'Sega Technical Institute',
    releaseYear: 1992,
    rating: 93,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'WORLD',
    estimatedSizeBytes: 786432,
    directRomUrl: 'retroapi://md/Sonic_The_Hedgehog_2.md',
  ),
  EmulationGame(
    igdbId: 1891,
    name: 'Streets of Rage 2',
    canonicalNoIntroName: 'Streets of Rage 2 (USA)',
    summary:
        'Axel, Blaze, Max e Skate limpam as ruas dominadas pelo sindicato de Mr. X no ápice do gênero beat \'em up com trilha eletrônica de Yuzo Koshiro.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Sega / Ancient',
    releaseYear: 1992,
    rating: 94,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 1572864,
    directRomUrl: 'retroapi://md/Streets_of_Rage_2.md',
  ),
  EmulationGame(
    igdbId: 4412,
    name: 'Gunstar Heroes',
    canonicalNoIntroName: 'Gunstar Heroes (USA)',
    summary:
        'Run-and-gun explosivo da Treasure com combinação livre de quatro tipos de tiro, chefes articulados multi-estágio e ação ininterrupta.',
    genres: ['Run and Gun', 'Ação'],
    developer: 'Treasure',
    releaseYear: 1993,
    rating: 92,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 819200,
    directRomUrl: 'retroapi://md/Gunstar_Heroes.md',
  ),
  EmulationGame(
    igdbId: 1122,
    name: 'Castlevania: Bloodlines',
    canonicalNoIntroName: 'Castlevania - Bloodlines (USA)',
    summary:
        'John Morris e Eric Lecarde percorrem a Europa de 1917 — das ruínas da Grécia à Torre de Pisa — para impedir a ressurreição da Condessa Bartley.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Konami',
    releaseYear: 1994,
    rating: 89,
    platformName: 'MEGA DRIVE',
    platformSlug: 'md',
    region: 'USA',
    estimatedSizeBytes: 720896,
    directRomUrl: 'retroapi://md/Castlevania_Bloodlines.md',
  ),

  // ==========================================================================
  // NINTENDO ENTERTAINMENT SYSTEM (NES) & GAME BOY COLOR (GBC)
  // ==========================================================================
  EmulationGame(
    igdbId: 1067,
    name: 'Super Mario Bros. 3',
    canonicalNoIntroName: 'Super Mario Bros. 3 (USA) (Rev 1)',
    summary:
        'Oito mundos temáticos, mapas interativos, Super Folha Guaxinim, Traje de Sapo e navios voadores dos sete Koopalings.',
    genres: ['Plataforma 2D'],
    developer: 'Nintendo R&D4',
    releaseYear: 1990,
    rating: 97,
    platformName: 'NES',
    platformSlug: 'nes',
    region: 'USA',
    estimatedSizeBytes: 245760,
    directRomUrl: 'retroapi://nes/Super_Mario_Bros_3.nes',
  ),
  EmulationGame(
    igdbId: 1702,
    name: 'Mega Man 2',
    canonicalNoIntroName: 'Mega Man 2 (USA)',
    summary:
        'Derrote Metal Man, Air Man, Quick Man e os oito Robot Masters de Dr. Wily, absorvendo suas armas em qualquer ordem.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Capcom',
    releaseYear: 1988,
    rating: 93,
    platformName: 'NES',
    platformSlug: 'nes',
    region: 'USA',
    estimatedSizeBytes: 147456,
    directRomUrl: 'retroapi://nes/Mega_Man_2.nes',
  ),
  EmulationGame(
    igdbId: 1514,
    name: 'Pokémon Crystal Version',
    canonicalNoIntroName: 'Pokemon - Crystal Version (USA, Europe) (Rev 1)',
    summary:
        'O clássico de Johto no Game Boy Color com sprites animados em batalha, ciclo de dia e noite em tempo real e a caçada ao lendário Suicune.',
    genres: ['RPG', 'Aventura'],
    developer: 'Game Freak',
    releaseYear: 2001,
    rating: 91,
    platformName: 'GBC',
    platformSlug: 'gbc',
    region: 'USA',
    estimatedSizeBytes: 1048576,
    directRomUrl: 'retroapi://gbc/Pokemon_Crystal.gbc',
  ),
  EmulationGame(
    igdbId: 1034,
    name: 'The Legend of Zelda: Link\'s Awakening DX',
    canonicalNoIntroName:
        'Legend of Zelda, The - Link\'s Awakening DX (USA, Europe) (Rev 2) (SGB Enhanced) (GB Compatible)',
    summary:
        'Náufrago na misteriosa Ilha Koholint, Link precisa reunir os oito Instrumentos das Sereias para despertar o Peixe do Vento.',
    genres: ['Action Adventure'],
    developer: 'Nintendo EAD',
    releaseYear: 1998,
    rating: 93,
    platformName: 'GBC',
    platformSlug: 'gbc',
    region: 'USA',
    estimatedSizeBytes: 655360,
    directRomUrl: 'retroapi://gbc/Zelda_Links_Awakening_DX.gbc',
  ),

  // ==========================================================================
  // SEGA GAME GEAR (ROM-Gripper & RetroAPI)
  // ==========================================================================
  EmulationGame(
    igdbId: 45101,
    name: 'Sonic Chaos',
    canonicalNoIntroName: 'Sonic Chaos (USA, Europe, Brazil) (En)',
    summary:
        'Sonic e Tails enfrentam Dr. Robotnik na South Island em 8 bits coloridos com Rocket Shoes e Super Peel-Out.',
    genres: ['Plataforma 2D'],
    developer: 'Aspect / Sega',
    releaseYear: 1993,
    rating: 86,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gamegear/Sonic_Chaos.gg',
  ),
  EmulationGame(
    igdbId: 45102,
    name: 'Sonic Blast',
    canonicalNoIntroName: 'Sonic Blast (World)',
    summary:
        'Sonic e Knuckles unem forças em gráficos pré-renderizados no Game Gear para recuperar os fragmentos das Esmeraldas.',
    genres: ['Plataforma 2D'],
    developer: 'Aspect / Sega',
    releaseYear: 1996,
    rating: 84,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'WORLD',
    estimatedSizeBytes: 1048576,
    directRomUrl: 'retroapi://gamegear/Sonic_Blast.gg',
  ),
  EmulationGame(
    igdbId: 45103,
    name: 'Shinobi II: The Silent Fury',
    canonicalNoIntroName: 'GG Shinobi II, The - The Silent Fury (World)',
    summary:
        'Joe Musashi lidera cinco ninjas elementais com habilidades distintas para recuperar os cristais roubados pelo Black Ninja.',
    genres: ['Ação', 'Ninja'],
    developer: 'Sega',
    releaseYear: 1992,
    rating: 89,
    platformName: 'GAME GEAR',
    platformSlug: 'gamegear',
    region: 'WORLD',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gamegear/GG_Shinobi_II.gg',
  ),

  // ==========================================================================
  // SNK NEO GEO (ROM-Gripper & RetroAPI)
  // ==========================================================================
  EmulationGame(
    igdbId: 55101,
    name: 'Metal Slug: Super Vehicle-001',
    canonicalNoIntroName: 'Metal Slug - Super Vehicle-001',
    summary:
        'Marco Rossi e Tarma Roving avançam pelas linhas inimigas do General Morden em pixel art lendária da SNK.',
    genres: ['Run and Gun', 'Arcade'],
    developer: 'Nazca / SNK',
    releaseYear: 1996,
    rating: 94,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 14680064,
    directRomUrl: 'retroapi://neogeo/mslug.zip',
  ),
  EmulationGame(
    igdbId: 55102,
    name: 'Metal Slug 3',
    canonicalNoIntroName: 'Metal Slug 3',
    summary:
        'Rotas ramificadas submarinas, aéreas e espaciais, dezenas de veículos Slug e o ápice da animação 2D da era Neo Geo MVS.',
    genres: ['Run and Gun', 'Arcade'],
    developer: 'SNK',
    releaseYear: 2000,
    rating: 96,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 38797312,
    directRomUrl: 'retroapi://neogeo/mslug3.zip',
  ),
  EmulationGame(
    igdbId: 55103,
    name: 'The King of Fighters \'98',
    canonicalNoIntroName:
        'The King of Fighters \'98 - The Slugfest / King of Fighters \'98 - dream match never ends',
    summary:
        'O Dream Match definitivo da franquia KOF reunindo 38 lutadores em trios nos sistemas Advanced e Extra.',
    genres: ['Luta 2D', 'Arcade'],
    developer: 'SNK',
    releaseYear: 1998,
    rating: 95,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 29360128,
    directRomUrl: 'retroapi://neogeo/kof98.zip',
  ),
  EmulationGame(
    igdbId: 55104,
    name: 'Garou: Mark of the Wolves',
    canonicalNoIntroName: 'Garou - Mark of the Wolves',
    summary:
        'Rock Howard e Terry Bogard disputam o torneio King of Fighters: Maximum Mayhem com mecânicas T.O.P. e Just Defend.',
    genres: ['Luta 2D', 'Arcade'],
    developer: 'SNK',
    releaseYear: 1999,
    rating: 95,
    platformName: 'NEO GEO',
    platformSlug: 'neogeo',
    region: 'WORLD',
    estimatedSizeBytes: 41943040,
    directRomUrl: 'retroapi://neogeo/garou.zip',
  ),

  // ==========================================================================
  // CAPCOM PLAY SYSTEM — CPS1 / CPS2 & ARCADE MAME
  // ==========================================================================
  EmulationGame(
    igdbId: 65101,
    name: 'Street Fighter Alpha 3',
    canonicalNoIntroName: 'Street Fighter Alpha 3',
    summary:
        'Escolha entre os estilos A-ISM, V-ISM e X-ISM com 28 lutadores na placa arcade CPS2 da Capcom.',
    genres: ['Luta 2D', 'CPS2'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 94,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'USA',
    estimatedSizeBytes: 22020096,
    directRomUrl: 'retroapi://cps1/sfa3.zip',
  ),
  EmulationGame(
    igdbId: 65102,
    name: 'Marvel vs. Capcom: Clash of Super Heroes',
    canonicalNoIntroName: 'Marvel vs. Capcom - Clash of Super Heroes',
    summary:
        'Combates em duplas explosivos entre Ryu, Mega Man, Jin, Spider-Man, Wolverine e Venom na CPS2.',
    genres: ['Luta 2D', 'Crossover'],
    developer: 'Capcom',
    releaseYear: 1998,
    rating: 93,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'USA',
    estimatedSizeBytes: 24117248,
    directRomUrl: 'retroapi://cps1/mvsc.zip',
  ),
  EmulationGame(
    igdbId: 65103,
    name: 'Cadillacs and Dinosaurs',
    canonicalNoIntroName: 'Cadillacs and Dinosaurs',
    summary:
        'Jack Tenrec, Hannah Dundee, Mustapha Cairo e Mess O\'Bradovich enfrentam caçadores ilegais em um futuro pós-apocalíptico.',
    genres: ['Beat \'em up', 'CPS1'],
    developer: 'Capcom',
    releaseYear: 1993,
    rating: 93,
    platformName: 'CPS1 / CPS2',
    platformSlug: 'cps1',
    region: 'WORLD',
    estimatedSizeBytes: 6291456,
    directRomUrl: 'retroapi://cps1/dino.zip',
  ),
  EmulationGame(
    igdbId: 75101,
    name: 'Teenage Mutant Ninja Turtles: Turtles in Time',
    canonicalNoIntroName: 'Teenage Mutant Ninja Turtles - Turtles in Time',
    summary:
        'Leonardo, Michelangelo, Donatello e Raphael viajam através da história para recuperar a Estátua da Liberdade de Krang e Shredder.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Konami',
    releaseYear: 1991,
    rating: 92,
    platformName: 'ARCADE',
    platformSlug: 'mame',
    region: 'USA',
    estimatedSizeBytes: 5242880,
    directRomUrl: 'retroapi://mame/tmnt2.zip',
  ),
  EmulationGame(
    igdbId: 75102,
    name: 'The Simpsons Arcade Game',
    canonicalNoIntroName: 'The Simpsons',
    summary:
        'Homer, Marge, Bart e Lisa enfrentam os capangas de Mr. Burns pelas ruas de Springfield para resgatar Maggie.',
    genres: ['Beat \'em up', 'Arcade'],
    developer: 'Konami',
    releaseYear: 1991,
    rating: 90,
    platformName: 'ARCADE',
    platformSlug: 'mame',
    region: 'USA',
    estimatedSizeBytes: 4194304,
    directRomUrl: 'retroapi://mame/simpsons.zip',
  ),

  // ==========================================================================
  // SEGA DREAMCAST
  // ==========================================================================
  EmulationGame(
    igdbId: 85101,
    name: 'Sonic Adventure',
    canonicalNoIntroName: 'Sonic Adventure (USA) (En,Ja,Fr,De,Es)',
    summary:
        'Sonic, Tails, Knuckles, Amy, Big e E-102 Gamma exploram Station Square e Mystic Ruins contra a criatura ancestral Chaos.',
    genres: ['Plataforma 3D', 'Ação'],
    developer: 'Sonic Team / Sega',
    releaseYear: 1999,
    rating: 90,
    platformName: 'DREAMCAST',
    platformSlug: 'dreamcast',
    region: 'USA',
    estimatedSizeBytes: 712710096,
    directRomUrl: 'retroapi://dreamcast/Sonic_Adventure.chd',
  ),
  EmulationGame(
    igdbId: 85102,
    name: 'SoulCalibur',
    canonicalNoIntroName: 'SoulCalibur (USA)',
    summary:
        'Combates com armas em 8 direções a 60 FPS no Dreamcast em torno da espada amaldiçoada Soul Edge.',
    genres: ['Luta 3D', 'Arcade'],
    developer: 'Namco',
    releaseYear: 1999,
    rating: 98,
    platformName: 'DREAMCAST',
    platformSlug: 'dreamcast',
    region: 'USA',
    estimatedSizeBytes: 650117120,
    directRomUrl: 'retroapi://dreamcast/SoulCalibur.chd',
  ),

  // ==========================================================================
  // SONY PLAYSTATION 2 (PS2)
  // ==========================================================================
  EmulationGame(
    igdbId: 91101,
    name: 'Shadow of the Colossus',
    canonicalNoIntroName: 'Shadow of the Colossus (USA) (En,Fr,Es)',
    summary:
        'Escale 16 colossos gigantes em uma terra proibida para trazer uma vida de volta.',
    genres: ['Aventura', 'Ação'],
    developer: 'Team Ico / Sony',
    releaseYear: 2005,
    rating: 95,
    platformName: 'PS2',
    platformSlug: 'ps2',
    region: 'USA',
    estimatedSizeBytes: 2450000000,
    directRomUrl: 'retroapi://ps2/Shadow_of_the_Colossus.iso',
  ),
  EmulationGame(
    igdbId: 91102,
    name: 'God of War II',
    canonicalNoIntroName: 'God of War II (USA)',
    summary:
        'Kratos parte em busca das Irmãs do Destino em uma jornada épica pelo Olimpo.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Santa Monica Studio',
    releaseYear: 2007,
    rating: 93,
    platformName: 'PS2',
    platformSlug: 'ps2',
    region: 'USA',
    estimatedSizeBytes: 4200000000,
    directRomUrl: 'retroapi://ps2/God_of_War_II.iso',
  ),

  // ==========================================================================
  // NINTENDO GAMECUBE
  // ==========================================================================
  EmulationGame(
    igdbId: 92101,
    name: 'The Legend of Zelda: The Wind Waker',
    canonicalNoIntroName: 'Legend of Zelda, The - The Wind Waker (USA)',
    summary:
        'Navegue pelo Grande Mar com estilo cel-shaded atemporal e masmorras memoráveis.',
    genres: ['Aventura', 'Ação'],
    developer: 'Nintendo EAD',
    releaseYear: 2003,
    rating: 96,
    platformName: 'GAMECUBE',
    platformSlug: 'gamecube',
    region: 'USA',
    estimatedSizeBytes: 1180000000,
    directRomUrl: 'retroapi://gamecube/Wind_Waker.rvz',
  ),
  EmulationGame(
    igdbId: 92102,
    name: 'Metroid Prime',
    canonicalNoIntroName: 'Metroid Prime (USA)',
    summary:
        'Explore o planeta Tallon IV em primeira pessoa com Samus Aran em gráficos de ponta.',
    genres: ['Ação', 'Aventura'],
    developer: 'Retro Studios',
    releaseYear: 2002,
    rating: 97,
    platformName: 'GAMECUBE',
    platformSlug: 'gamecube',
    region: 'USA',
    estimatedSizeBytes: 1250000000,
    directRomUrl: 'retroapi://gamecube/Metroid_Prime.rvz',
  ),

  // ==========================================================================
  // NINTENDO WII
  // ==========================================================================
  EmulationGame(
    igdbId: 93101,
    name: 'Super Mario Galaxy',
    canonicalNoIntroName: 'Super Mario Galaxy (USA)',
    summary:
        'Salte por planetoides com gravidade própria em uma das obras-primas 3D da Nintendo.',
    genres: ['Plataforma 3D', 'Aventura'],
    developer: 'Nintendo EAD Tokyo',
    releaseYear: 2007,
    rating: 97,
    platformName: 'WII',
    platformSlug: 'wii',
    region: 'USA',
    estimatedSizeBytes: 3450000000,
    directRomUrl: 'retroapi://wii/Super_Mario_Galaxy.wbfs',
  ),
  EmulationGame(
    igdbId: 93102,
    name: 'Donkey Kong Country Returns',
    canonicalNoIntroName: 'Donkey Kong Country Returns (USA) (En,Fr,Es)',
    summary:
        'Donkey e Diddy Kong retomam suas bananas em fases 2.5D desafiadoras da Retro Studios.',
    genres: ['Plataforma', 'Ação'],
    developer: 'Retro Studios',
    releaseYear: 2010,
    rating: 89,
    platformName: 'WII',
    platformSlug: 'wii',
    region: 'USA',
    estimatedSizeBytes: 3200000000,
    directRomUrl: 'retroapi://wii/DKCR.wbfs',
  ),

  // ==========================================================================
  // NINTENDO 3DS
  // ==========================================================================
  EmulationGame(
    igdbId: 94101,
    name: 'The Legend of Zelda: A Link Between Worlds',
    canonicalNoIntroName:
        'Legend of Zelda, The - A Link Between Worlds (USA) (En,Fr,Es)',
    summary:
        'Alterne entre Hyrule e Lorule transformando-se em pintura nas paredes em 60 FPS.',
    genres: ['Aventura', 'RPG'],
    developer: 'Nintendo EAD',
    releaseYear: 2013,
    rating: 94,
    platformName: '3DS',
    platformSlug: '3ds',
    region: 'USA',
    estimatedSizeBytes: 680000000,
    directRomUrl: 'retroapi://3ds/A_Link_Between_Worlds.3ds',
  ),
  EmulationGame(
    igdbId: 94102,
    name: 'Mario Kart 7',
    canonicalNoIntroName: 'Mario Kart 7 (USA) (En,Fr,Es)',
    summary:
        'Corridas de kart com planadores, percursos submarinos e karts personalizáveis no 3DS.',
    genres: ['Corrida', 'Arcade'],
    developer: 'Nintendo EAD / Retro Studios',
    releaseYear: 2011,
    rating: 88,
    platformName: '3DS',
    platformSlug: '3ds',
    region: 'USA',
    estimatedSizeBytes: 640000000,
    directRomUrl: 'retroapi://3ds/Mario_Kart_7.3ds',
  ),

  // ==========================================================================
  // SONY PLAYSTATION 3 (PS3 EXPERIMENTAL — RPCS3 VULKAN + PS3UPDAT.PUP)
  // ==========================================================================
  EmulationGame(
    igdbId: 95101,
    name: 'Demon\'s Souls',
    canonicalNoIntroName: 'Demon\'s Souls (USA)',
    summary:
        'RPG de ação sombrio em Boletaria. Requer Vulkan + firmware PS3UPDAT.PUP importado nas Configurações.',
    genres: ['RPG', 'Ação'],
    developer: 'FromSoftware',
    releaseYear: 2009,
    rating: 91,
    platformName: 'PS3',
    platformSlug: 'ps3',
    region: 'USA',
    estimatedSizeBytes: 6200000000,
    directRomUrl: 'retroapi://ps3/Demons_Souls.iso',
  ),
  EmulationGame(
    igdbId: 95102,
    name: 'God of War III',
    canonicalNoIntroName: 'God of War III (USA)',
    summary:
        'O clímax da vingança de Kratos no Monte Olimpo. Core experimental via RPCS3 ARM64.',
    genres: ['Hack and Slash', 'Ação'],
    developer: 'Santa Monica Studio',
    releaseYear: 2010,
    rating: 93,
    platformName: 'PS3',
    platformSlug: 'ps3',
    region: 'USA',
    estimatedSizeBytes: 8500000000,
    directRomUrl: 'retroapi://ps3/God_of_War_III.iso',
  ),

  // ==========================================================================
  // SEGA SATURN
  // ==========================================================================
  EmulationGame(
    igdbId: 96101,
    name: 'NiGHTS into Dreams...',
    canonicalNoIntroName: 'NiGHTS into Dreams... (USA)',
    summary:
        'Voe pelos sonhos de Nightopia em uma criação clássica da Sonic Team para Sega Saturn.',
    genres: ['Ação', 'Plataforma'],
    developer: 'Sonic Team / Sega',
    releaseYear: 1996,
    rating: 90,
    platformName: 'SATURN',
    platformSlug: 'saturn',
    region: 'USA',
    estimatedSizeBytes: 420000000,
    directRomUrl: 'retroapi://saturn/NiGHTS_into_Dreams.chd',
  ),
  EmulationGame(
    igdbId: 96102,
    name: 'Panzer Dragoon II Zwei',
    canonicalNoIntroName: 'Panzer Dragoon II Zwei (USA)',
    summary:
        'Rail shooter atmosférico montado em dragão com múltiplos caminhos e evolução.',
    genres: ['Shooter', 'Ação'],
    developer: 'Team Andromeda / Sega',
    releaseYear: 1996,
    rating: 91,
    platformName: 'SATURN',
    platformSlug: 'saturn',
    region: 'USA',
    estimatedSizeBytes: 480000000,
    directRomUrl: 'retroapi://saturn/Panzer_Dragoon_II_Zwei.chd',
  ),

  // ==========================================================================
  // NEC PC ENGINE / TURBOGRAFX-16
  // ==========================================================================
  EmulationGame(
    igdbId: 97101,
    name: 'Bonk\'s Adventure',
    canonicalNoIntroName: 'Bonk\'s Adventure (USA)',
    summary:
        'Plataforma clássica com o mascote cabeçudo da NEC enfrentando dinossauros pré-históricos.',
    genres: ['Plataforma', 'Ação'],
    developer: 'Red Company / Hudson Soft',
    releaseYear: 1990,
    rating: 87,
    platformName: 'PC ENGINE',
    platformSlug: 'pce',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://pce/Bonks_Adventure.pce',
  ),
  EmulationGame(
    igdbId: 97102,
    name: 'Blazing Lazers',
    canonicalNoIntroName: 'Blazing Lazers (USA)',
    summary:
        'Um dos melhores shoot \'em ups verticais de 16-bit desenvolvido pela Compile.',
    genres: ['Shooter', 'Arcade'],
    developer: 'Compile / Hudson Soft',
    releaseYear: 1989,
    rating: 89,
    platformName: 'PC ENGINE',
    platformSlug: 'pce',
    region: 'USA',
    estimatedSizeBytes: 393216,
    directRomUrl: 'retroapi://pce/Blazing_Lazers.pce',
  ),

  // ==========================================================================
  // NINTENDO GAME BOY
  // ==========================================================================
  EmulationGame(
    igdbId: 98101,
    name: 'Super Mario Land 2: 6 Golden Coins',
    canonicalNoIntroName: 'Super Mario Land 2 - 6 Golden Coins (USA, Europe)',
    summary:
        'Estréia de Wario como rival de Mario em seis zonas temáticas no Game Boy clássico.',
    genres: ['Plataforma', 'Aventura'],
    developer: 'Nintendo R&D1',
    releaseYear: 1992,
    rating: 90,
    platformName: 'GAME BOY',
    platformSlug: 'gb',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gb/Super_Mario_Land_2.gb',
  ),
  EmulationGame(
    igdbId: 98102,
    name: 'The Legend of Zelda: Link\'s Awakening',
    canonicalNoIntroName: 'Legend of Zelda, The - Link\'s Awakening (USA, Europe)',
    summary:
        'Desperte o Peixe dos Ventos na misteriosa Ilha Koholint neste clássico atemporal.',
    genres: ['Aventura', 'RPG'],
    developer: 'Nintendo EAD',
    releaseYear: 1993,
    rating: 94,
    platformName: 'GAME BOY',
    platformSlug: 'gb',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://gb/Links_Awakening.gb',
  ),

  // ==========================================================================
  // SEGA MASTER SYSTEM
  // ==========================================================================
  EmulationGame(
    igdbId: 99101,
    name: 'Alex Kidd in Miracle World',
    canonicalNoIntroName: 'Alex Kidd in Miracle World (USA, Europe)',
    summary:
        'Aventura clássica de 8-bit que marcou geração no Brasil e no mundo com Master System.',
    genres: ['Plataforma', 'Aventura'],
    developer: 'Sega',
    releaseYear: 1986,
    rating: 88,
    platformName: 'MASTER SYSTEM',
    platformSlug: 'mastersystem',
    region: 'USA',
    estimatedSizeBytes: 262144,
    directRomUrl: 'retroapi://mastersystem/Alex_Kidd_in_Miracle_World.sms',
  ),
  EmulationGame(
    igdbId: 99102,
    name: 'Phantasy Star',
    canonicalNoIntroName: 'Phantasy Star (USA, Europe)',
    summary:
        'RPG espacial pioneiro com masmorras 3D em primeira pessoa e trilha memorável.',
    genres: ['RPG', 'Aventura'],
    developer: 'Sega',
    releaseYear: 1987,
    rating: 92,
    platformName: 'MASTER SYSTEM',
    platformSlug: 'mastersystem',
    region: 'USA',
    estimatedSizeBytes: 524288,
    directRomUrl: 'retroapi://mastersystem/Phantasy_Star.sms',
  ),

  // ==========================================================================
  // NINTENDO SWITCH (PONTE DE LANÇAMENTO PARA EDEN — NCE + TURNIP)
  // ==========================================================================
  EmulationGame(
    igdbId: 99501,
    name: 'Hollow Knight: Silksong',
    canonicalNoIntroName: 'Hollow Knight - Silksong',
    summary:
        'A sequência protagonizada por Hornet em um reino de seda e canções. Importe sua ROM (.nsp/.xci/.nsz) local ou via RomM para abrir direto no Eden com NCE e Turnip.',
    genres: ['Metroidvania', 'Ação', 'Aventura'],
    developer: 'Team Cherry',
    releaseYear: 2025,
    rating: 95,
    platformName: 'SWITCH',
    platformSlug: 'switch',
    region: 'WORLD',
    estimatedSizeBytes: 4200000000,
    gridCoverUrl:
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1030300/library_600x900.jpg',
    directRomUrl: 'external://switch/Hollow_Knight_Silksong.nsp',
  ),
  EmulationGame(
    igdbId: 99502,
    name: 'Hollow Knight',
    canonicalNoIntroName: 'Hollow Knight',
    summary:
        'Explore as cavernas interconectadas de Hallownest. Abra sua ROM Switch (.nsp/.xci) direto pelo LoopGamer usando o motor Eden ARM64.',
    genres: ['Metroidvania', 'Ação', 'Plataforma'],
    developer: 'Team Cherry',
    releaseYear: 2018,
    rating: 94,
    platformName: 'SWITCH',
    platformSlug: 'switch',
    region: 'WORLD',
    estimatedSizeBytes: 3600000000,
    gridCoverUrl:
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/367520/library_600x900.jpg',
    directRomUrl: 'external://switch/Hollow_Knight.nsp',
  ),
  EmulationGame(
    igdbId: 99503,
    name: 'Celeste',
    canonicalNoIntroName: 'Celeste',
    summary:
        'Escale a montanha Celeste em centenas de desafios precisos de plataforma 2D. Compatível via ponte Eden.',
    genres: ['Plataforma', 'Aventura'],
    developer: 'Maddy Makes Games',
    releaseYear: 2018,
    rating: 94,
    platformName: 'SWITCH',
    platformSlug: 'switch',
    region: 'WORLD',
    estimatedSizeBytes: 1200000000,
    gridCoverUrl:
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/504230/library_600x900.jpg',
    directRomUrl: 'external://switch/Celeste.nsp',
  ),
  EmulationGame(
    igdbId: 99504,
    name: 'Cuphead',
    canonicalNoIntroName: 'Cuphead',
    summary:
        'Ação e chefes clássicos desenhados à mão no estilo animação dos anos 1930 a 60 FPS no Eden.',
    genres: ['Shooter', 'Plataforma', 'Ação'],
    developer: 'Studio MDHR',
    releaseYear: 2019,
    rating: 91,
    platformName: 'SWITCH',
    platformSlug: 'switch',
    region: 'WORLD',
    estimatedSizeBytes: 3400000000,
    gridCoverUrl:
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/268910/library_600x900.jpg',
    directRomUrl: 'external://switch/Cuphead.nsp',
  ),
  EmulationGame(
    igdbId: 99505,
    name: 'Hades',
    canonicalNoIntroName: 'Hades',
    summary:
        'Roguelike frenético da Supergiant Games nos domínios do submundo grego. Lance sua ROM Switch direto no Eden.',
    genres: ['Ação', 'RPG'],
    developer: 'Supergiant Games',
    releaseYear: 2020,
    rating: 93,
    platformName: 'SWITCH',
    platformSlug: 'switch',
    region: 'WORLD',
    estimatedSizeBytes: 5700000000,
    gridCoverUrl:
        'https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/1145360/library_600x900.jpg',
    directRomUrl: 'external://switch/Hades.nsp',
  ),
];
