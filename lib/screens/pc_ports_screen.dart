import 'package:flutter/material.dart';

import '../data/pc_port_catalog.dart';
import '../models/pc_port.dart';
import '../services/pc_port_service.dart';
import '../theme/ps5_hydra_theme.dart';

/// Catálogo de ports de PC gratuitos/legalmente distribuíveis para Android.
/// Permite baixar o APK oficial direto no app e instalar via sistema.
class PcPortsScreen extends StatefulWidget {
  const PcPortsScreen({super.key, this.initialEntryId});

  /// Quando informado, rola até o item correspondente.
  final String? initialEntryId;

  @override
  State<PcPortsScreen> createState() => _PcPortsScreenState();
}

class _PcPortsScreenState extends State<PcPortsScreen> {
  final Map<String, _PortRuntimeState> _states = {};
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    if (widget.initialEntryId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final index = PcPortCatalog.entries
            .indexWhere((e) => e.id == widget.initialEntryId);
        if (index > 0 && _scrollController.hasClients) {
          _scrollController.animateTo(
            index * 220.0,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  _PortRuntimeState _stateFor(String id) =>
      _states.putIfAbsent(id, () => _PortRuntimeState());

  Future<void> _downloadAndInstall(PcPortEntry entry) async {
    final state = _stateFor(entry.id);
    if (state.busy) return;
    state
      ..busy = true
      ..error = null
      ..progress = 0
      ..phase = PcPortDownloadState.resolving;
    setState(() {});

    try {
      final file = await PcPortService.downloadApk(
        entry,
        onProgress: (received, total) {
          state.phase = PcPortDownloadState.downloading;
          state.progress = total > 0 ? received / total : null;
          if (mounted) setState(() {});
        },
      );
      state.phase = PcPortDownloadState.installing;
      if (mounted) setState(() {});

      final installed = await PcPortService.installApk(file);
      if (!installed && mounted) {
        state.error = 'Não foi possível abrir o instalador do Android.';
      }
    } catch (e) {
      debugPrint('[PcPorts] Falha ao baixar ${entry.id}: $e');
      state.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      state.busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openExternal(PcPortEntry entry) async {
    final url = entry.externalUrl;
    if (url == null) return;
    final ok = await PcPortService.openExternal(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Ports de PC',
          style: TextStyle(
            fontFamily: 'ReadexPro',
            fontWeight: FontWeight.w700,
            color: PS5HydraTheme.textPrimary,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView.separated(
          controller: _scrollController,
          padding: const EdgeInsets.all(PS5HydraTheme.space16),
          itemCount: PcPortCatalog.entries.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: PS5HydraTheme.space12),
          itemBuilder: (context, index) {
            final entry = PcPortCatalog.entries[index];
            return _PortCard(
              entry: entry,
              state: _stateFor(entry.id),
              onDownload: () => _downloadAndInstall(entry),
              onOpenExternal: () => _openExternal(entry),
            );
          },
        ),
      ),
    );
  }
}

class _PortRuntimeState {
  bool busy = false;
  String? error;
  double? progress; // 0..1, null = indeterminado
  PcPortDownloadState phase = PcPortDownloadState.idle;
}

class _PortCard extends StatelessWidget {
  const _PortCard({
    required this.entry,
    required this.state,
    required this.onDownload,
    required this.onOpenExternal,
  });

  final PcPortEntry entry;
  final _PortRuntimeState state;
  final VoidCallback onDownload;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final isGithub = entry.source == PcPortSource.githubRelease;
    final isDirect = entry.source == PcPortSource.directApk;

    return Container(
      padding: const EdgeInsets.all(PS5HydraTheme.space16),
      decoration: BoxDecoration(
        color: PS5HydraTheme.obsidianGlass,
        borderRadius: BorderRadius.circular(PS5HydraTheme.radiusCard),
        border: Border.all(color: PS5HydraTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: PS5HydraTheme.auroraSpringMint.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.sports_esports_rounded,
                  color: PS5HydraTheme.auroraSpringMint,
                ),
              ),
              const SizedBox(width: PS5HydraTheme.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: PS5HydraTheme.textPrimary,
                      ),
                    ),
                    Text(
                      '${entry.developer} · ${entry.genre}',
                      style: PS5HydraTheme.metaMonoStyle.copyWith(
                        color: PS5HydraTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: PS5HydraTheme.auroraSpringMint.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: PS5HydraTheme.auroraSpringMint.withOpacity(0.4),
                  ),
                ),
                child: Text(
                  entry.license,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: PS5HydraTheme.auroraSpringMint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: PS5HydraTheme.space12),
          Text(
            entry.description,
            style: const TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 12.5,
              height: 1.4,
              color: PS5HydraTheme.textSecondary,
            ),
          ),
          if (entry.archNote != null) ...[
            const SizedBox(height: PS5HydraTheme.space8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 14,
                  color: PS5HydraTheme.auroraSpringMint,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    entry.archNote!,
                    style: const TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      color: PS5HydraTheme.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ],
          if (state.error != null) ...[
            const SizedBox(height: PS5HydraTheme.space8),
            Text(
              state.error!,
              style: const TextStyle(
                fontSize: 11,
                color: Colors.redAccent,
              ),
            ),
          ],
          const SizedBox(height: PS5HydraTheme.space12),
          _buildAction(context, isGithub, isDirect),
        ],
      ),
    );
  }

  Widget _buildAction(BuildContext context, bool isGithub, bool isDirect) {
    if (state.busy) {
      final determinate = state.progress != null;
      return Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              value: determinate ? state.progress : null,
              color: PS5HydraTheme.auroraSpringMint,
            ),
          ),
          const SizedBox(width: PS5HydraTheme.space12),
          Expanded(
            child: Text(
              state.phase == PcPortDownloadState.resolving
                  ? 'Resolvendo APK oficial...'
                  : state.phase == PcPortDownloadState.installing
                      ? 'Abrindo instalador...'
                      : 'Baixando APK... ${((state.progress ?? 0) * 100).toStringAsFixed(0)}%',
              style: PS5HydraTheme.metaMonoStyle.copyWith(
                color: PS5HydraTheme.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    if (isGithub || isDirect) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onDownload,
          icon: const Icon(Icons.download_rounded, size: 18),
          label: const Text('Baixar e instalar APK'),
          style: FilledButton.styleFrom(
            backgroundColor: PS5HydraTheme.auroraSpringMint,
            foregroundColor: Colors.black,
            textStyle: const TextStyle(
              fontFamily: 'ReadexPro',
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: onOpenExternal,
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: Text(entry.externalLabel ?? 'Abrir link oficial'),
        style: OutlinedButton.styleFrom(
          foregroundColor: PS5HydraTheme.auroraSpringMint,
          side: const BorderSide(color: PS5HydraTheme.auroraSpringMint),
          textStyle: const TextStyle(
            fontFamily: 'ReadexPro',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
