import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../widgets/update_dialog.dart';
import 'update_service.dart';

/// Dispara a checagem de atualização no startup, independente da rota ativa.
///
/// O app antigo (2.6.0) fazia a checagem dentro de `PS5DashboardScreen`, que
/// nunca é montado — por isso nenhum aviso aparecia. Aqui a checagem vive no
/// `MaterialApp`, passa pelo [NavigatorState] e abre o diálogo por cima de
/// qualquer aba.
class UpdateCoordinator {
  UpdateCoordinator({required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;
  final UpdateService _service = UpdateService.instance;

  static const Duration _startupDelay = Duration(milliseconds: 900);
  static const Duration _recheckInterval = Duration(hours: 6);
  static const Duration _retryDelay = Duration(seconds: 15);

  bool _running = false;

  /// Chamado uma vez após o primeiro frame. [force] ignora o intervalo de 6h
  /// e a versão dispensada (usado pelo botão "Verificar agora" dos ajustes).
  Future<void> runStartupCheck({bool force = false}) async {
    if (_running) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    _running = true;
    try {
      await Future<void>.delayed(_startupDelay);
      final state = await _service.loadState();
      final now = DateTime.now();
      final lastCheck = state.lastCheckMs;
      if (!force &&
          lastCheck != null &&
          now.difference(
                DateTime.fromMillisecondsSinceEpoch(lastCheck),
              ) <
              _recheckInterval) {
        return;
      }

      var result = await _service.checkForUpdate(force: true);
      if (result.error != null) {
        await Future<void>.delayed(_retryDelay);
        result = await _service.checkForUpdate(force: true);
      }
      if (result.error != null || !result.hasUpdate) return;

      final refreshed = await _service.loadState();
      if (!force && refreshed.dismissedVersion == result.latestVersion) {
        return;
      }

      final context = navigatorKey.currentContext;
      if (context == null || !context.mounted) return;

      await showUpdateDialog(
        context: context,
        result: result,
        onDismissed: (version) async {
          final current = await _service.loadState();
          await _service.saveState(
            current.copyWith(dismissedVersion: version),
          );
        },
      );

      final after = await _service.loadState();
      await _service.saveState(
        after.copyWith(
          lastPromptMs: DateTime.now().millisecondsSinceEpoch,
          lastCheckMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    } catch (e) {
      debugPrint('[UpdateCoordinator] Falha: $e');
    } finally {
      _running = false;
    }
  }
}
