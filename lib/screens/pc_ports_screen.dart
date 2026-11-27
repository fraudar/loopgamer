import 'dart:async';

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
  final Map<String, GlobalKey> _itemKeys = {};
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _query = '';

  @override
  void initState() {
    super.initState();
    unawaited(_detectExistingDownloads());
    if (widget.initialEntryId != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final key = _itemKeys[widget.initialEntryId];
        final target = key?.currentContext;
        if (target != null) {
          Scrollable.ensureVisible(
            target,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOut,
            alignment: 0.05,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _detectExistingDownloads() async {
    for (final entry in PcPortCatalog.entries) {
      if (!entry.hasDirectDownload && entry.extraAssetPrefixes.isEmpty) {
        continue;
      }
      try {
        final apk = entry.hasDirectDownload
            ? await PcPortService.findDownloadedApk(entry)
            : null;
        final data = await PcPortService.findDownloadedData(entry);
        if (!mounted) return;
        final state = _stateFor(entry.id);
        state.apkReady = apk != null;
        state.dataDonePath = data?.path;
        setState(() {});
      } catch (_) {
        // Arquivo inacessível não impede o download normal.
      }
    }
  }

  _PortRuntimeState _stateFor(String id) =>
      _states.putIfAbsent(id, () => _PortRuntimeState());

  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, () => GlobalKey());

  List<PcPortEntry> get _visibleEntries {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return PcPortCatalog.entries;
    return PcPortCatalog.entries.where((e) {
      return e.title.toLowerCase().contains(q) ||
          e.developer.toLowerCase().contains(q) ||
          e.genre.toLowerCase().contains(q) ||
          e.description.toLowerCase().contains(q);
    }).toList(growable: false);
  }

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
      final existing = state.apkReady
          ? await PcPortService.findDownloadedApk(entry)
          : null;
      final file = existing ??
          await PcPortService.downloadApk(
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
      if (installed) {
        state.apkReady = true;
      } else if (mounted) {
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

  Future<void> _downloadData(PcPortEntry entry) async {
    final state = _stateFor(entry.id);
    if (state.dataBusy) return;
    state
      ..dataBusy = true
      ..error = null
      ..dataProgress = 0
      ..dataLabel = 'Preparando pacotes…';
    setState(() {});

    try {
      final dir = await PcPortService.downloadExtraAssets(
        entry,
        onProgress: (index, count, name, progress) {
          state.dataLabel = '$name (${index + 1}/$count)';
          state.dataProgress = progress;
          if (mounted) setState(() {});
        },
      );
      state.dataDonePath = dir.path;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Pacotes de dados em ${dir.path}'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      debugPrint('[PcPorts] Falha ao baixar dados de ${entry.id}: $e');
      state.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      state.dataBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openExternal(String url) async {
    final ok = await PcPortService.openExternal(url);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Não foi possível abrir o link.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final entries = _visibleEntries;
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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PS5HydraTheme.space16,
                PS5HydraTheme.space8,
                PS5HydraTheme.space16,
                PS5HydraTheme.space8,
              ),
              child: TextField(
                controller: _searchController,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(
                  fontFamily: 'ReadexPro',
                  fontSize: 14,
                  color: PS5HydraTheme.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'Buscar port, jogo ou gênero…',
                  hintStyle: TextStyle(
                    fontFamily: 'ReadexPro',
                    fontSize: 13.5,
                    color: PS5HydraTheme.textSecondary.withOpacity(0.8),
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: PS5HydraTheme.textSecondary,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close_rounded, size: 18),
                          color: PS5HydraTheme.textSecondary,
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        ),
                  filled: true,
                  fillColor: PS5HydraTheme.obsidianGlass,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: PS5HydraTheme.borderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: PS5HydraTheme.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(
                      color: PS5HydraTheme.auroraSpringMint,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: entries.isEmpty
                  ? const Center(
                      child: Text(
                        'Nenhum port encontrado.',
                        style: TextStyle(
                          fontFamily: 'ReadexPro',
                          color: PS5HydraTheme.textSecondary,
                        ),
                      ),
                    )
                  : ListView.separated(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(PS5HydraTheme.space16),
                      itemCount: entries.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: PS5HydraTheme.space12),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return _PortCard(
                          key: _keyFor(entry.id),
                          entry: entry,
                          state: _stateFor(entry.id),
                          onDownload: () => _downloadAndInstall(entry),
                          onDownloadData: () => _downloadData(entry),
                          onOpenExternal: (url) => _openExternal(url),
                        );
                      },
                    ),
            ),
          ],
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

  bool apkReady = false;

  bool dataBusy = false;
  double? dataProgress;
  String? dataLabel;
  String? dataDonePath;
}

class _PortCard extends StatelessWidget {
  const _PortCard({
    super.key,
    required this.entry,
    required this.state,
    required this.onDownload,
    required this.onDownloadData,
    required this.onOpenExternal,
  });

  final PcPortEntry entry;
  final _PortRuntimeState state;
  final VoidCallback onDownload;
  final VoidCallback onDownloadData;
  final ValueChanged<String> onOpenExternal;

  @override
  Widget build(BuildContext context) {
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
              _Badge(label: entry.license),
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
          if (entry.minRamMb > 0) ...[
            const SizedBox(height: PS5HydraTheme.space8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _InfoChip(
                  icon: Icons.memory_rounded,
                  label: '${(entry.minRamMb / 1024).toStringAsFixed(1)} GB RAM',
                ),
                if (entry.source == PcPortSource.githubRelease)
                  const _InfoChip(
                    icon: Icons.verified_rounded,
                    label: 'Release oficial do projeto',
                  ),
              ],
            ),
          ],
          if (entry.requiresGameFiles != null) ...[
            const SizedBox(height: PS5HydraTheme.space8),
            _WarningBox(text: entry.requiresGameFiles!),
          ],
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
              style: const TextStyle(fontSize: 11, color: Colors.redAccent),
            ),
          ],
          const SizedBox(height: PS5HydraTheme.space12),
          _buildAction(),
        ],
      ),
    );
  }

  Widget _buildAction() {
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
                      : 'Baixando APK... '
                          '${((state.progress ?? 0) * 100).toStringAsFixed(0)}%',
              style: PS5HydraTheme.metaMonoStyle.copyWith(
                color: PS5HydraTheme.textSecondary,
              ),
            ),
          ),
        ],
      );
    }

    final releasesUrl = entry.releasesPageUrl;
    final widgets = <Widget>[];

    if (entry.hasDirectDownload) {
      widgets.add(
        Expanded(
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
        ),
      );
    } else if (entry.externalUrl != null) {
      widgets.add(
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () => onOpenExternal(entry.externalUrl!),
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
        ),
      );
    }

    if (releasesUrl != null) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(width: PS5HydraTheme.space8));
      }
      widgets.add(
        OutlinedButton(
          onPressed: () => onOpenExternal(releasesUrl),
          style: OutlinedButton.styleFrom(
            foregroundColor: PS5HydraTheme.textPrimary,
            side: const BorderSide(color: PS5HydraTheme.borderSubtle),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          child: const Text(
            'Arquivos',
            style: TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }

    final actionRow = widgets.isEmpty
        ? const SizedBox.shrink()
        : Row(children: widgets);

    if (entry.extraAssetPrefixes.isEmpty) return actionRow;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        actionRow,
        const SizedBox(height: PS5HydraTheme.space8),
        _buildDataRow(),
      ],
    );
  }

  Widget _buildDataRow() {
    if (state.dataBusy) {
      return Row(
        children: [
          SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.2,
              value: state.dataProgress,
              color: const Color(0xFFFFB454),
            ),
          ),
          const SizedBox(width: PS5HydraTheme.space8),
          Expanded(
            child: Text(
              state.dataLabel ?? 'Baixando pacotes de dados…',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: PS5HydraTheme.metaMonoStyle.copyWith(
                fontSize: 10,
                color: PS5HydraTheme.textSecondary,
              ),
            ),
          ),
          if (state.dataProgress != null)
            Text(
              '${(state.dataProgress! * 100).toStringAsFixed(0)}%',
              style: PS5HydraTheme.metaMonoStyle.copyWith(
                fontSize: 10,
                color: PS5HydraTheme.textSecondary,
              ),
            ),
        ],
      );
    }

    return OutlinedButton.icon(
      onPressed: onDownloadData,
      icon: const Icon(Icons.inventory_2_outlined, size: 16),
      label: Text(
        state.dataDonePath != null
            ? 'Pacotes de dados prontos (${state.dataDonePath!.split('/').last})'
            : 'Baixar pacotes de dados',
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFFFB454),
        side: const BorderSide(color: Color(0xFFFFB454)),
        textStyle: const TextStyle(
          fontFamily: 'ReadexPro',
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: PS5HydraTheme.auroraSpringMint.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: PS5HydraTheme.auroraSpringMint.withOpacity(0.4),
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: PS5HydraTheme.auroraSpringMint,
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: PS5HydraTheme.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: PS5HydraTheme.textSecondary),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: PS5HydraTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _WarningBox extends StatelessWidget {
  const _WarningBox({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB454).withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFB454).withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.folder_open,
            size: 15,
            color: Color(0xFFFFB454),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.35,
                color: PS5HydraTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
