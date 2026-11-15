/// Metadados pessoais da biblioteca: tempo jogado, jogados recentemente,
/// favoritos e coleções personalizadas.
class PlaytimeRecord {
  const PlaytimeRecord({
    this.totalSeconds = 0,
    this.lastPlayed,
    this.sessions = 0,
  });

  final int totalSeconds;
  final DateTime? lastPlayed;
  final int sessions;

  PlaytimeRecord addSession(int seconds, DateTime when) => PlaytimeRecord(
        totalSeconds: totalSeconds + seconds.clamp(0, 24 * 3600),
        lastPlayed: when,
        sessions: sessions + 1,
      );

  Map<String, dynamic> toJson() => {
        'totalSeconds': totalSeconds,
        'lastPlayed': lastPlayed?.toIso8601String(),
        'sessions': sessions,
      };

  factory PlaytimeRecord.fromJson(Map<String, dynamic> m) => PlaytimeRecord(
        totalSeconds: (m['totalSeconds'] as num?)?.toInt() ?? 0,
        lastPlayed: DateTime.tryParse((m['lastPlayed'] as String?) ?? ''),
        sessions: (m['sessions'] as num?)?.toInt() ?? 0,
      );
}

/// Formata segundos como "2h 15m", "12m" ou "< 1m".
String formatPlaytime(int seconds) {
  if (seconds < 60) return seconds <= 0 ? '0m' : '< 1m';
  final h = seconds ~/ 3600;
  final m = (seconds % 3600) ~/ 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Formata "hoje", "ontem", "há 3 dias", ou a data.
String formatLastPlayed(DateTime? when, {DateTime? now}) {
  if (when == null) return 'Nunca jogado';
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final day = DateTime(when.year, when.month, when.day);
  final diff = today.difference(day).inDays;
  if (diff <= 0) return 'Hoje';
  if (diff == 1) return 'Ontem';
  if (diff < 7) return 'Há $diff dias';
  return '${when.day.toString().padLeft(2, '0')}/${when.month.toString().padLeft(2, '0')}/${when.year}';
}

class UserLibraryMeta {
  const UserLibraryMeta({
    this.favorites = const {},
    this.collections = const {},
    this.playtime = const {},
  });

  final Set<int> favorites;

  /// Nome da coleção -> ids dos jogos (ordem de inserção preservada)
  final Map<String, List<int>> collections;
  final Map<int, PlaytimeRecord> playtime;

  bool isFavorite(int id) => favorites.contains(id);

  PlaytimeRecord playtimeOf(int id) => playtime[id] ?? const PlaytimeRecord();

  /// Ids ordenados do jogado mais recentemente para o mais antigo.
  List<int> recentlyPlayedIds({int? limit}) {
    final entries = playtime.entries
        .where((e) => e.value.lastPlayed != null)
        .toList()
      ..sort((a, b) => b.value.lastPlayed!.compareTo(a.value.lastPlayed!));
    if (limit != null && limit > 0) {
      return entries.take(limit).map((e) => e.key).toList();
    }
    return entries.map((e) => e.key).toList();
  }

  List<String> collectionsContaining(int id) => collections.entries
      .where((e) => e.value.contains(id))
      .map((e) => e.key)
      .toList();

  UserLibraryMeta toggleFavorite(int id) {
    final next = Set<int>.from(favorites);
    if (!next.remove(id)) next.add(id);
    return UserLibraryMeta(
      favorites: next,
      collections: collections,
      playtime: playtime,
    );
  }

  UserLibraryMeta createCollection(String name) {
    final clean = name.trim();
    if (clean.isEmpty || collections.containsKey(clean)) return this;
    return UserLibraryMeta(
      favorites: favorites,
      collections: {...collections, clean: const []},
      playtime: playtime,
    );
  }

  UserLibraryMeta deleteCollection(String name) {
    final next = Map<String, List<int>>.from(collections)..remove(name);
    return UserLibraryMeta(
      favorites: favorites,
      collections: next,
      playtime: playtime,
    );
  }

  UserLibraryMeta renameCollection(String oldName, String newName) {
    final clean = newName.trim();
    if (clean.isEmpty ||
        !collections.containsKey(oldName) ||
        collections.containsKey(clean)) {
      return this;
    }
    final next = <String, List<int>>{};
    collections.forEach((k, v) => next[k == oldName ? clean : k] = v);
    return UserLibraryMeta(
      favorites: favorites,
      collections: next,
      playtime: playtime,
    );
  }

  UserLibraryMeta setInCollection(String name, int id, bool include) {
    final current = List<int>.from(collections[name] ?? const []);
    if (include && !current.contains(id)) current.add(id);
    if (!include) current.remove(id);
    return UserLibraryMeta(
      favorites: favorites,
      collections: {...collections, name: current},
      playtime: playtime,
    );
  }

  UserLibraryMeta recordSession(int id, int seconds, DateTime when) {
    return UserLibraryMeta(
      favorites: favorites,
      collections: collections,
      playtime: {...playtime, id: playtimeOf(id).addSession(seconds, when)},
    );
  }

  /// Ao remover o jogo da biblioteca, limpa favoritos/coleções mas mantém o
  /// histórico de tempo jogado (caso a pessoa baixe de novo).
  UserLibraryMeta forgetGame(int id) {
    final favs = Set<int>.from(favorites)..remove(id);
    final cols = <String, List<int>>{
      for (final e in collections.entries)
        e.key: e.value.where((x) => x != id).toList(),
    };
    return UserLibraryMeta(
      favorites: favs,
      collections: cols,
      playtime: playtime,
    );
  }

  Map<String, dynamic> toJson() => {
        'favorites': favorites.toList(),
        'collections': collections,
        'playtime': {
          for (final e in playtime.entries) '${e.key}': e.value.toJson(),
        },
      };

  factory UserLibraryMeta.fromJson(Map<String, dynamic> m) {
    final favs = ((m['favorites'] as List?) ?? const [])
        .whereType<num>()
        .map((e) => e.toInt())
        .toSet();
    final cols = <String, List<int>>{};
    final rawCols = m['collections'];
    if (rawCols is Map) {
      rawCols.forEach((k, v) {
        if (k is String && v is List) {
          cols[k] = v.whereType<num>().map((e) => e.toInt()).toList();
        }
      });
    }
    final pt = <int, PlaytimeRecord>{};
    final rawPt = m['playtime'];
    if (rawPt is Map) {
      rawPt.forEach((k, v) {
        final id = int.tryParse('$k');
        if (id != null && v is Map<String, dynamic>) {
          pt[id] = PlaytimeRecord.fromJson(v);
        }
      });
    }
    return UserLibraryMeta(favorites: favs, collections: cols, playtime: pt);
  }
}
