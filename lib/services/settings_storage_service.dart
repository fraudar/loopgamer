import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import '../models/app_settings.dart';
import '../models/user_library_meta.dart';

class SettingsStorageService {
  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<Map<String, dynamic>?> _readJson(String name) async {
    try {
      final f = await _file(name);
      if (!await f.exists()) return null;
      final decoded = jsonDecode(await f.readAsString());
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Escrita atômica (arquivo temporário + rename) para não corromper JSON
  /// se o app for fechado no meio da gravação.
  Future<void> _writeJson(String name, Map<String, dynamic> data) async {
    try {
      final f = await _file(name);
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(data), flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // Configurações globais
  // ---------------------------------------------------------------------------
  Future<AppSettings> loadSettings() async {
    final m = await _readJson('app_settings.json');
    if (m == null) return const AppSettings();
    try {
      return AppSettings.fromJson(m);
    } catch (_) {
      return const AppSettings();
    }
  }

  Future<void> saveSettings(AppSettings settings) =>
      _writeJson('app_settings.json', settings.toJson());

  // ---------------------------------------------------------------------------
  // Perfis de configuração por jogo (layout, resolução, frame skip etc.)
  // ---------------------------------------------------------------------------
  Future<Map<int, AppSettings>> loadGameProfiles() async {
    final m = await _readJson('game_profiles.json');
    final out = <int, AppSettings>{};
    if (m == null) return out;
    m.forEach((k, v) {
      final id = int.tryParse(k);
      if (id != null && v is Map<String, dynamic>) {
        try {
          out[id] = AppSettings.fromJson(v);
        } catch (_) {}
      }
    });
    return out;
  }

  Future<void> saveGameProfiles(Map<int, AppSettings> profiles) => _writeJson(
        'game_profiles.json',
        {for (final e in profiles.entries) '${e.key}': e.value.toJson()},
      );

  // ---------------------------------------------------------------------------
  // Tempo jogado, recentes, favoritos e coleções
  // ---------------------------------------------------------------------------
  Future<UserLibraryMeta> loadUserMeta() async {
    final m = await _readJson('user_meta.json');
    if (m == null) return const UserLibraryMeta();
    try {
      return UserLibraryMeta.fromJson(m);
    } catch (_) {
      return const UserLibraryMeta();
    }
  }

  Future<void> saveUserMeta(UserLibraryMeta meta) =>
      _writeJson('user_meta.json', meta.toJson());
}
