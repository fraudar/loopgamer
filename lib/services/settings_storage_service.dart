import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../models/app_settings.dart';
import '../models/user_library_meta.dart';

class SettingsStorageService {
  static final Map<String, Future<void>> _fileLocks = {};
  static int _tmpCounter = 0;

  Future<T> _synchronizedFor<T>(String name, Future<T> Function() action) {
    final prev = _fileLocks[name] ?? Future<void>.value();
    final completer = Completer<T>();
    final next = prev.then((_) async {
      try {
        final result = await action();
        completer.complete(result);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    _fileLocks[name] = next;
    return completer.future;
  }

  Future<File> _file(String name) async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$name');
  }

  Future<void> _backupCorruptFile(File f) async {
    try {
      if (await f.exists()) {
        await f.copy('${f.path}.corrupt.bak');
      }
    } catch (e) {
      debugPrint(
        '[SettingsStorageService] Falha ao criar backup .corrupt.bak de ${f.path}: $e',
      );
    }
  }

  Future<Map<String, dynamic>?> _readJsonUnlocked(String name) async {
    final f = await _file(name);
    if (!await f.exists()) return null;
    try {
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) {
        await _backupCorruptFile(f);
        debugPrint('[SettingsStorageService] Arquivo $name vazio; backup salvo.');
        return null;
      }
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      await _backupCorruptFile(f);
      debugPrint(
        '[SettingsStorageService] Raiz de $name não é um objeto JSON; backup salvo.',
      );
      return null;
    } catch (e) {
      await _backupCorruptFile(f);
      debugPrint('[SettingsStorageService] JSON inválido em $name: $e');
      return null;
    }
  }

  /// Escrita atômica serializada por arquivo com `.tmp` único por operação + rename.
  /// Preserva backup `.corrupt.bak` caso o arquivo pré-existente esteja corrompido.
  Future<void> _writeJson(String name, Map<String, dynamic> data) {
    return _synchronizedFor(name, () async {
      final f = await _file(name);
      if (!await f.parent.exists()) {
        await f.parent.create(recursive: true);
      }

      if (await f.exists()) {
        try {
          final existing = jsonDecode(await f.readAsString());
          if (existing is! Map<String, dynamic>) {
            await _backupCorruptFile(f);
          }
        } catch (e) {
          debugPrint(
            '[SettingsStorageService] Backup de $name corrompido antes de sobrescrever: $e',
          );
          await _backupCorruptFile(f);
        }
      }

      final seq = ++_tmpCounter;
      final tmp = File(
        '${f.path}.tmp_${DateTime.now().microsecondsSinceEpoch}_$seq',
      );
      try {
        await tmp.writeAsString(jsonEncode(data), flush: true);
        await tmp.rename(f.path);
      } catch (e) {
        debugPrint('[SettingsStorageService] Erro ao gravar $name: $e');
        try {
          if (await tmp.exists()) {
            await tmp.delete();
          }
        } catch (cleanupErr) {
          debugPrint('[SettingsStorageService] Falha ao remover tmp: $cleanupErr');
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Configurações globais
  // ---------------------------------------------------------------------------
  Future<AppSettings> loadSettings() {
    return _synchronizedFor('app_settings.json', () async {
      final m = await _readJsonUnlocked('app_settings.json');
      if (m == null) return const AppSettings();
      try {
        return AppSettings.fromJson(m);
      } catch (e) {
        debugPrint(
          '[SettingsStorageService] Erro ao desserializar app_settings.json: $e',
        );
        await _backupCorruptFile(await _file('app_settings.json'));
        return const AppSettings();
      }
    });
  }

  Future<void> saveSettings(AppSettings settings) =>
      _writeJson('app_settings.json', settings.toJson());

  // ---------------------------------------------------------------------------
  // Perfis de configuração por jogo (layout, resolução, frame skip etc.)
  // ---------------------------------------------------------------------------
  Future<Map<int, AppSettings>> loadGameProfiles() {
    return _synchronizedFor('game_profiles.json', () async {
      final m = await _readJsonUnlocked('game_profiles.json');
      final out = <int, AppSettings>{};
      if (m == null) return out;
      m.forEach((k, v) {
        final id = int.tryParse(k);
        if (id != null && v is Map) {
          try {
            out[id] = AppSettings.fromJson(Map<String, dynamic>.from(v));
          } catch (e) {
            debugPrint(
              '[SettingsStorageService] Perfil de jogo corrompido para id=$k: $e',
            );
          }
        }
      });
      return out;
    });
  }

  Future<void> saveGameProfiles(Map<int, AppSettings> profiles) => _writeJson(
        'game_profiles.json',
        {for (final e in profiles.entries) '${e.key}': e.value.toJson()},
      );

  // ---------------------------------------------------------------------------
  // Tempo jogado, recentes, favoritos e coleções
  // ---------------------------------------------------------------------------
  Future<UserLibraryMeta> loadUserMeta() {
    return _synchronizedFor('user_meta.json', () async {
      final m = await _readJsonUnlocked('user_meta.json');
      if (m == null) return const UserLibraryMeta();
      try {
        return UserLibraryMeta.fromJson(m);
      } catch (e) {
        debugPrint(
          '[SettingsStorageService] Erro ao desserializar user_meta.json: $e',
        );
        await _backupCorruptFile(await _file('user_meta.json'));
        return const UserLibraryMeta();
      }
    });
  }

  Future<void> saveUserMeta(UserLibraryMeta meta) =>
      _writeJson('user_meta.json', meta.toJson());
}
