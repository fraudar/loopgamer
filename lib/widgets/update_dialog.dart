import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../theme/ps5_hydra_theme.dart';

/// Diálogo de atualização usado no startup e na opção manual dos ajustes.
///
/// Mostra as versões, as notas do release, o progresso do download e abre o
/// instalador do sistema. Se o Android exigir permissão de fontes desconhecidas,
/// oferece o atalho para Configurações sem perder o APK já baixado.
Future<void> showUpdateDialog({
  required BuildContext context,
  required UpdateCheckResult result,
  Future<void> Function(String version)? onDismissed,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => UpdateDialog(
      result: result,
      onDismissed: onDismissed,
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({
    super.key,
    required this.result,
    this.onDismissed,
  });

  final UpdateCheckResult result;
  final Future<void> Function(String version)? onDismissed;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _busy = false;
  bool _downloaded = false;
  bool _needsPermission = false;
  int _received = 0;
  int _total = 0;
  String? _error;
  File? _apkFile;

  double get _progress {
    if (_total <= 0) return 0;
    return (_received / _total).clamp(0.0, 1.0);
  }

  String get _progressLabel {
    if (_busy && _total <= 0) {
      return '${(_received / (1024 * 1024)).toStringAsFixed(1)} MB baixados';
    }
    if (_total > 0) {
      return '${(_received / (1024 * 1024)).toStringAsFixed(1)} / '
          '${(_total / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final notes = result.releaseNotes.trim();
    return AlertDialog(
      backgroundColor: PS5HydraTheme.obsidianGlass,
      title: const Text(
        'Atualização disponível',
        style: TextStyle(color: PS5HydraTheme.textPrimary),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'LoopGamer ${result.latestVersion} está disponível '
              '(instalado: ${result.currentVersion}).',
              style: const TextStyle(
                color: PS5HydraTheme.textPrimary,
                fontSize: 14,
              ),
            ),
            if (result.sizeLabel.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                'APK ${result.sizeLabel} • ${result.releaseTag}',
                style: const TextStyle(
                  color: PS5HydraTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 14),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: PS5HydraTheme.abyssalCard,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: PS5HydraTheme.borderSubtle),
                  ),
                  child: Text(
                    notes,
                    style: const TextStyle(
                      color: PS5HydraTheme.textSecondary,
                      fontSize: 11.5,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: 18),
              LinearProgressIndicator(
                value: _total > 0 ? _progress : null,
                minHeight: 4,
                color: PS5HydraTheme.auroraSpringMint,
                backgroundColor: PS5HydraTheme.auroraDeepTrench,
              ),
              const SizedBox(height: 6),
              Text(
                _progressLabel,
                style: const TextStyle(
                  color: PS5HydraTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: const TextStyle(
                  color: PS5HydraTheme.dangerRose,
                  fontSize: 12,
                ),
              ),
            ],
            if (_needsPermission) ...[
              const SizedBox(height: 12),
              const Text(
                'O Android pede permissão para instalar APKs fora da loja. '
                'Ative "instalar apps desconhecidos" para o LoopGamer e '
                'volte aqui: o download já está pronto.',
                style: TextStyle(
                  color: PS5HydraTheme.textSecondary,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : _dismiss,
          child: const Text('Depois'),
        ),
        if (_needsPermission)
          FilledButton(
            onPressed: () => unawaited(_openPermissionSettings()),
            child: const Text('Permissão'),
          )
        else if (!_downloaded)
          FilledButton(
            onPressed: _busy ? null : () => unawaited(_downloadAndInstall()),
            child: Text(_busy ? 'Baixando...' : 'Atualizar'),
          )
        else
          FilledButton(
            onPressed: () => unawaited(_installDownloaded()),
            child: const Text('Instalar'),
          ),
      ],
    );
  }

  Future<void> _dismiss() async {
    await widget.onDismissed?.call(widget.result.latestVersion);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _downloadAndInstall() async {
    setState(() {
      _busy = true;
      _error = null;
      _received = 0;
      _total = widget.result.apkSize ?? 0;
    });

    try {
      final apk = await UpdateService.instance.downloadLatestApk(
        result: widget.result,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _received = received;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _downloaded = true;
        _received = widget.result.apkSize ?? 0;
        _apkFile = apk;
      });
      await _installDownloaded();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Falha no download: $e';
      });
    }
  }

  Future<void> _installDownloaded() async {
    final apk = _apkFile;
    if (apk == null || !await apk.exists()) {
      if (mounted) {
        setState(() => _error = 'APK não encontrado. Baixe novamente.');
      }
      return;
    }

    final allowed = await UpdateService.instance.canRequestPackageInstalls();
    if (!allowed) {
      if (mounted) setState(() => _needsPermission = true);
      return;
    }
    final opened = await UpdateService.instance.installApk(apk);
    if (!mounted) return;
    if (!opened) {
      setState(() => _error = 'Não foi possível abrir o instalador do Android.');
    }
  }

  Future<void> _openPermissionSettings() async {
    final opened =
        await UpdateService.instance.openInstallPermissionSettings();
    if (!mounted) return;
    if (!opened) {
      setState(
        () => _error = 'Não foi possível abrir Configurações neste dispositivo.',
      );
    }
  }
}
