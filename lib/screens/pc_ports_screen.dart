import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../data/apkvision_offline_catalog.dart';
import '../data/pc_port_catalog.dart';
import '../models/apkvision_port.dart';
import '../models/pc_port.dart';
import '../services/apkvision_port_service.dart';
import '../services/archive_extract_service.dart';
import '../services/pc_port_service.dart';
import '../theme/ps5_hydra_theme.dart';
import '../widgets/port_install_guide_sheet.dart';

enum _PortSource { curated, apkVision }

enum _ArchiveFilter { all, sevenZ, zip, rar, iso, other, none }

/// Catálogo de ports de PC gratuitos/legalmente distribuíveis para Android.
/// Permite baixar o APK oficial direto no app e instalar via sistema.
class PcPortsScreen extends StatefulWidget {
  const PcPortsScreen({
    super.key,
    this.initialEntryId,
    this.initialApkVisionEntryId,
  });

  /// Quando informado, rola até o item correspondente no catálogo curado.
  final String? initialEntryId;

  /// Quando informado, abre a aba APKVision e rola até o item correspondente.
  final String? initialApkVisionEntryId;

  @override
  State<PcPortsScreen> createState() => _PcPortsScreenState();
}

class _PcPortsScreenState extends State<PcPortsScreen> {
  final Map<String, _PortRuntimeState> _states = {};
  final Map<String, GlobalKey> _itemKeys = {};
  final Map<String, _ApkVisionRuntimeState> _apkVisionStates = {};
  final Map<String, GlobalKey> _apkVisionKeys = {};
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  String _query = '';
  _PortSource _source = _PortSource.curated;
  _ArchiveFilter _archiveFilter = _ArchiveFilter.all;
  String? _portRootPath;

  @override
  void initState() {
    super.initState();
    if (widget.initialApkVisionEntryId != null) {
      _source = _PortSource.apkVision;
    }
    unawaited(_detectExistingDownloads());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final id = widget.initialApkVisionEntryId ?? widget.initialEntryId;
      if (id == null) return;
      final key = widget.initialApkVisionEntryId != null
          ? _apkVisionKeys[id]
          : _itemKeys[id];
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
    for (final entry in ApkVisionOfflineCatalog.entries) {
      try {
        final apk = entry.hasApk
            ? await ApkVisionPortService.findDownloadedApk(entry)
            : null;
        final data = await ApkVisionPortService.findDownloadedData(entry);
        final extracted = await ApkVisionPortService.hasExtractedData(entry);
        if (!mounted) return;
        final state = _apkVisionStateFor(entry.id);
        state.apkReady = apk != null;
        state.dataPath = data?.path;
        state.extracted = extracted;
        setState(() {});
      } catch (_) {
        // Arquivo inacessível não impede o download normal.
      }
    }
    try {
      final root = await ApkVisionPortService.root();
      if (!mounted) return;
      _portRootPath = root.path;
      setState(() {});
    } catch (_) {
      // Sem raiz resolvida, a UI mostra o caminho padrão mesmo assim.
    }
  }

  _PortRuntimeState _stateFor(String id) =>
      _states.putIfAbsent(id, () => _PortRuntimeState());

  GlobalKey _keyFor(String id) => _itemKeys.putIfAbsent(id, () => GlobalKey());

  _ApkVisionRuntimeState _apkVisionStateFor(String id) =>
      _apkVisionStates.putIfAbsent(id, () => _ApkVisionRuntimeState());

  GlobalKey _apkVisionKeyFor(String id) =>
      _apkVisionKeys.putIfAbsent(id, () => GlobalKey());

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

  List<ApkVisionPortEntry> get _visibleApkVisionEntries {
    final q = _query.trim().toLowerCase();
    return ApkVisionOfflineCatalog.entries.where((e) {
      if (_archiveFilter == _ArchiveFilter.sevenZ &&
          e.dataKind != ApkVisionArchiveKind.sevenZ) {
        return false;
      }
      if (_archiveFilter == _ArchiveFilter.zip &&
          e.dataKind != ApkVisionArchiveKind.zip) {
        return false;
      }
      if (_archiveFilter == _ArchiveFilter.rar &&
          e.dataKind != ApkVisionArchiveKind.rar) {
        return false;
      }
      if (_archiveFilter == _ArchiveFilter.iso &&
          e.dataKind != ApkVisionArchiveKind.iso &&
          e.dataKind != ApkVisionArchiveKind.rvz) {
        return false;
      }
      if (_archiveFilter == _ArchiveFilter.other &&
          (e.dataKind != ApkVisionArchiveKind.obb &&
              e.dataKind != ApkVisionArchiveKind.romfs &&
              e.dataKind != ApkVisionArchiveKind.tarXz &&
              e.dataKind != ApkVisionArchiveKind.exe)) {
        return false;
      }
      if (_archiveFilter == _ArchiveFilter.none && e.hasData) return false;
      if (q.isEmpty) return true;
      return e.title.toLowerCase().contains(q) ||
          e.category.toLowerCase().contains(q) ||
          e.version.toLowerCase().contains(q) ||
          e.dataLabel.toLowerCase().contains(q);
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

  Future<void> _downloadApkVisionApk(ApkVisionPortEntry entry) async {
    final state = _apkVisionStateFor(entry.id);
    if (state.busy) return;
    state
      ..busy = true
      ..error = null
      ..progress = 0
      ..phase = PcPortDownloadState.downloading;
    setState(() {});

    try {
      final existing = state.apkReady
          ? await ApkVisionPortService.findDownloadedApk(entry)
          : null;
      final file = existing ??
          await ApkVisionPortService.downloadApk(
        entry,
        onProgress: (received, total) {
          state.progress = total > 0 ? received / total : null;
          if (mounted) setState(() {});
        },
      );
      state.phase = PcPortDownloadState.installing;
      if (mounted) setState(() {});
      final installed = await ApkVisionPortService.installApk(file);
      if (installed) {
        state.apkReady = true;
      } else if (mounted) {
        state.error = 'Não foi possível abrir o instalador do Android.';
      }
    } catch (e) {
      debugPrint('[ApkVision] Falha ao baixar APK ${entry.id}: $e');
      state.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      state.busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _downloadApkVisionData(ApkVisionPortEntry entry) async {
    final state = _apkVisionStateFor(entry.id);
    if (state.dataBusy) return;
    state
      ..dataBusy = true
      ..error = null
      ..dataProgress = 0
      ..dataLabel = 'Preparando ${entry.dataLabel}…';
    setState(() {});

    try {
      final file = await ApkVisionPortService.downloadData(
        entry,
        onProgress: (received, total) {
          state.dataProgress =
              total > 0 ? (received / total).clamp(0, 1).toDouble() : null;
          if (mounted) setState(() {});
        },
      );
      state.dataPath = file.path;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Arquivo pronto: ${file.uri.pathSegments.last}'),
            duration: const Duration(seconds: 6),
          ),
        );
      }
    } catch (e) {
      debugPrint('[ApkVision] Falha ao baixar dados ${entry.id}: $e');
      state.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      state.dataBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _openApkVisionArchive(ApkVisionPortEntry entry) async {
    final state = _apkVisionStateFor(entry.id);
    File? file;
    if (state.dataPath != null) {
      final cached = File(state.dataPath!);
      if (await cached.exists()) file = cached;
    }
    file ??= await ApkVisionPortService.findDownloadedData(entry);
    if (file == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Baixe o pacote de dados antes de abrir.'),
          ),
        );
      }
      return;
    }
    final result = await ApkVisionPortService.openArchive(file);
    if (result.type == ResultType.done) return;
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Nenhum app abriu o arquivo. Instale um gerenciador de arquivos.',
          ),
        ),
      );
    }
  }

  /// Extrai o pacote `.7z`/`.zip`/`.rar`/`.tar.xz` para `.../<id>/game/`.
  Future<void> _extractApkVisionData(
    ApkVisionPortEntry entry, {
    bool deleteSource = false,
  }) async {
    final state = _apkVisionStateFor(entry.id);
    if (state.extractBusy) return;
    if (!ArchiveExtractService.canExtract(entry)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${entry.dataLabel} não é compactado. Copie o arquivo para a '
              'pasta do jogo — não precisa extrair.',
            ),
          ),
        );
      }
      return;
    }

    state
      ..extractBusy = true
      ..error = null
      ..extractProgress = 0
      ..extractEntry = 'Preparando…';
    setState(() {});

    final sub = ArchiveExtractService.progress.listen((p) {
      if (!mounted) return;
      // Só consome o progresso do arquivo desta entrada.
      if (state.dataPath != null && p.archivePath != state.dataPath) return;
      state.extractProgress = p.fraction;
      state.extractEntry = p.entry;
      setState(() {});
    });

    try {
      final result = await ApkVisionPortService.extractData(
        entry,
        deleteSource: deleteSource,
      );
      state.extracted = !result.isEmpty && !result.cancelled;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.sourceDeleted
                  ? '${result.files} arquivo(s) extraído(s). Pacote apagado.'
                  : '${result.files} arquivo(s) extraído(s) em ${result.destDir}',
            ),
            duration: const Duration(seconds: 5),
          ),
        );
      }
      if (state.extracted && mounted) {
        unawaited(_showPortGuide(entry));
      }
    } catch (e) {
      debugPrint('[ApkVision] Falha ao extrair ${entry.id}: $e');
      state.error = e.toString().replaceFirst('Bad state: ', '');
    } finally {
      await sub.cancel();
      state
        ..extractBusy = false
        ..extractEntry = null;
      if (mounted) setState(() {});
    }
  }

  Future<void> _showPortGuide(ApkVisionPortEntry entry) async {
    final state = _apkVisionStateFor(entry.id);
    final root = state.rootPath ?? _portRootPath ?? ApkVisionPortService.publicRootPath;
    final portPath = '$root/${entry.id}';
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111114),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) => PortInstallGuideSheet(
        entry: entry,
        portPath: portPath,
        extracted: state.extracted,
        onOpenFolder: () async {
          await ApkVisionPortService.openDocumentRoot();
        },
        onCopyPath: () async {
          await Clipboard.setData(ClipboardData(text: portPath));
          if (sheetContext.mounted) {
            ScaffoldMessenger.of(sheetContext).showSnackBar(
              const SnackBar(content: Text('Caminho copiado.')),
            );
          }
        },
      ),
    );
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
    final apkVisionEntries = _visibleApkVisionEntries;
    final isApkVision = _source == _PortSource.apkVision;
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
                  hintText: isApkVision
                      ? 'Buscar NieR, Silksong, 7z, ZIP...'
                      : 'Buscar port, jogo ou gênero…',
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
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PS5HydraTheme.space16,
              ),
              child: SegmentedButton<_PortSource>(
                segments: const [
                  ButtonSegment(
                    value: _PortSource.curated,
                    label: Text('Catálogo'),
                    icon: Icon(Icons.verified_rounded, size: 16),
                  ),
                  ButtonSegment(
                    value: _PortSource.apkVision,
                    label: Text('APKVision'),
                    icon: Icon(Icons.archive_outlined, size: 16),
                  ),
                ],
                selected: {_source},
                onSelectionChanged: (selection) {
                  setState(() => _source = selection.first);
                },
              ),
            ),
            if (isApkVision)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PS5HydraTheme.space16,
                  PS5HydraTheme.space8,
                  PS5HydraTheme.space16,
                  0,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    _archiveChip(_ArchiveFilter.all, 'Todos'),
                    _archiveChip(_ArchiveFilter.sevenZ, '7Z'),
                    _archiveChip(_ArchiveFilter.zip, 'ZIP'),
                    _archiveChip(_ArchiveFilter.rar, 'RAR'),
                    _archiveChip(_ArchiveFilter.iso, 'ISO'),
                    _archiveChip(_ArchiveFilter.other, 'OBB/EXE'),
                    _archiveChip(_ArchiveFilter.none, 'Só APK'),
                  ],
                ),
              ),
            Expanded(
              child: isApkVision
                  ? apkVisionEntries.isEmpty
                      ? const Center(
                          child: Text(
                            'Nenhum port APKVision para este filtro.',
                            style: TextStyle(
                              fontFamily: 'ReadexPro',
                              color: PS5HydraTheme.textSecondary,
                            ),
                          ),
                        )
                      : ListView.separated(
                          controller: _scrollController,
                          padding: const EdgeInsets.all(PS5HydraTheme.space16),
                          itemCount: apkVisionEntries.length,
                          separatorBuilder: (_, __) => const SizedBox(
                            height: PS5HydraTheme.space12,
                          ),
                          itemBuilder: (context, index) {
                            final entry = apkVisionEntries[index];
                            return _ApkVisionCard(
                              key: _apkVisionKeyFor(entry.id),
                              entry: entry,
                              state: _apkVisionStateFor(entry.id),
                              onDownloadApk: () =>
                                  _downloadApkVisionApk(entry),
                              onDownloadData: () =>
                                  _downloadApkVisionData(entry),
                              onExtract: () => _extractApkVisionData(entry),
                              onOpenArchive: () => _openApkVisionArchive(entry),
                              onShowGuide: () => _showPortGuide(entry),
                              onOpenExternal: (url) => _openExternal(url),
                            );
                          },
                        )
                  : entries.isEmpty
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

  Widget _archiveChip(_ArchiveFilter filter, String label) {
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontFamily: 'ReadexPro',
          fontSize: 11.5,
          color: _archiveFilter == filter ? Colors.black : PS5HydraTheme.textSecondary,
        ),
      ),
      selected: _archiveFilter == filter,
      onSelected: (_) => setState(() => _archiveFilter = filter),
      selectedColor: PS5HydraTheme.auroraSpringMint,
      backgroundColor: PS5HydraTheme.obsidianGlass,
      side: BorderSide(
        color: _archiveFilter == filter
            ? PS5HydraTheme.auroraSpringMint
            : PS5HydraTheme.borderSubtle,
      ),
      visualDensity: VisualDensity.compact,
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

class _ApkVisionRuntimeState {
  bool busy = false;
  double? progress;
  PcPortDownloadState phase = PcPortDownloadState.idle;
  bool apkReady = false;

  bool dataBusy = false;
  double? dataProgress;
  String? dataLabel;
  String? dataPath;

  bool extractBusy = false;
  double? extractProgress;
  String? extractEntry;
  bool extracted = false;
  String? rootPath;

  String? error;
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

class _ApkVisionCard extends StatelessWidget {
  const _ApkVisionCard({
    super.key,
    required this.entry,
    required this.state,
    required this.onDownloadApk,
    required this.onDownloadData,
    required this.onExtract,
    required this.onOpenArchive,
    required this.onShowGuide,
    required this.onOpenExternal,
  });

  final ApkVisionPortEntry entry;
  final _ApkVisionRuntimeState state;
  final VoidCallback onDownloadApk;
  final VoidCallback onDownloadData;
  final VoidCallback onExtract;
  final VoidCallback onOpenArchive;
  final VoidCallback onShowGuide;
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
                  color: const Color(0xFFFFB454).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.archive_outlined,
                  color: Color(0xFFFFB454),
                ),
              ),
              const SizedBox(width: PS5HydraTheme.space12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'ReadexPro',
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        color: PS5HydraTheme.textPrimary,
                      ),
                    ),
                    Text(
                      '${entry.version} · ${entry.category}',
                      style: PS5HydraTheme.metaMonoStyle.copyWith(
                        color: PS5HydraTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              _Badge(label: entry.dataLabel),
            ],
          ),
          const SizedBox(height: PS5HydraTheme.space12),
          Text(
            entry.note,
            style: const TextStyle(
              fontFamily: 'ReadexPro',
              fontSize: 12.5,
              height: 1.4,
              color: PS5HydraTheme.textSecondary,
            ),
          ),
          if (entry.hasData) ...[
            const SizedBox(height: PS5HydraTheme.space8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _InfoChip(
                  icon: Icons.folder_zip_rounded,
                  label: entry.dataFileName,
                ),
                if (state.dataPath != null)
                  const _InfoChip(
                    icon: Icons.check_circle_outline,
                    label: 'Arquivo pronto',
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
          _buildActions(),
        ],
      ),
    );
  }

  Widget _buildActions() {
    if (state.busy) {
      return _progressRow(
        value: state.progress,
        color: PS5HydraTheme.auroraSpringMint,
        label: state.phase == PcPortDownloadState.installing
            ? 'Abrindo instalador...'
            : 'Baixando APK... ${((state.progress ?? 0) * 100).toStringAsFixed(0)}%',
      );
    }
    if (state.dataBusy) {
      return _progressRow(
        value: state.dataProgress,
        color: const Color(0xFFFFB454),
        label: '${state.dataLabel ?? 'Baixando dados'} '
            '${((state.dataProgress ?? 0) * 100).toStringAsFixed(0)}%',
      );
    }
    if (state.extractBusy) {
      return _progressRow(
        value: state.extractProgress,
        color: PS5HydraTheme.auroraSpringMint,
        label: 'Extraindo ${((state.extractProgress ?? 0) * 100).toStringAsFixed(0)}%'
            '${state.extractEntry == null ? '' : ' · ${state.extractEntry}'}',
      );
    }

    final buttons = <Widget>[];
    if (entry.hasApk) {
      buttons.add(
        SizedBox(
          width: 180,
          child: FilledButton.icon(
            onPressed: onDownloadApk,
            icon: Icon(
              state.apkReady ? Icons.install_mobile_rounded : Icons.download_rounded,
              size: 17,
            ),
            label: Text(state.apkReady ? 'Instalar APK' : 'Baixar APK'),
            style: FilledButton.styleFrom(
              backgroundColor: PS5HydraTheme.auroraSpringMint,
              foregroundColor: Colors.black,
              textStyle: const TextStyle(
                fontFamily: 'ReadexPro',
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              ),
            ),
          ),
        ),
      );
    }
    if (entry.hasData) {
      buttons.add(
        SizedBox(
          width: 180,
          child: OutlinedButton.icon(
            onPressed: onDownloadData,
            icon: const Icon(Icons.archive_outlined, size: 16),
            label: Text(
              state.dataPath != null
                  ? 'Dados prontos'
                  : 'Baixar dados ${entry.dataLabel}',
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFFB454),
              side: const BorderSide(color: Color(0xFFFFB454)),
              textStyle: const TextStyle(
                fontFamily: 'ReadexPro',
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
      );
      if (state.dataPath != null) {
        buttons.add(
          OutlinedButton.icon(
            onPressed: onOpenArchive,
            icon: const Icon(Icons.folder_open_rounded, size: 16),
            label: const Text('Abrir'),
            style: OutlinedButton.styleFrom(
              foregroundColor: PS5HydraTheme.textPrimary,
              side: const BorderSide(color: PS5HydraTheme.borderSubtle),
            ),
          ),
        );
        if (ArchiveExtractService.canExtract(entry)) {
          buttons.add(
            FilledButton.icon(
              onPressed: onExtract,
              icon: Icon(
                state.extracted
                    ? Icons.check_circle_rounded
                    : Icons.unarchive_rounded,
                size: 16,
              ),
              label: Text(
                state.extracted ? 'Extraído' : 'Extrair ${entry.dataLabel}',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: state.extracted
                    ? PS5HydraTheme.obsidianGlass
                    : const Color(0xFFFFB454),
                foregroundColor: state.extracted
                    ? PS5HydraTheme.textPrimary
                    : Colors.black,
                side: state.extracted
                    ? const BorderSide(color: PS5HydraTheme.borderSubtle)
                    : BorderSide.none,
                textStyle: const TextStyle(
                  fontFamily: 'ReadexPro',
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }
      }
    }
    buttons.add(
      OutlinedButton.icon(
        onPressed: onShowGuide,
        icon: const Icon(Icons.help_outline_rounded, size: 16),
        label: const Text('Onde está / como instalar'),
        style: OutlinedButton.styleFrom(
          foregroundColor: PS5HydraTheme.textPrimary,
          side: const BorderSide(color: PS5HydraTheme.borderSubtle),
        ),
      ),
    );
    buttons.add(
      OutlinedButton.icon(
        onPressed: () => onOpenExternal(entry.pageUrl),
        icon: const Icon(Icons.open_in_new_rounded, size: 16),
        label: const Text('Página'),
        style: OutlinedButton.styleFrom(
          foregroundColor: PS5HydraTheme.textPrimary,
          side: const BorderSide(color: PS5HydraTheme.borderSubtle),
        ),
      ),
    );
    return Wrap(spacing: 8, runSpacing: 8, children: buttons);
  }

  Widget _progressRow({
    required double? value,
    required Color color,
    required String label,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2.4,
            value: value,
            color: color,
          ),
        ),
        const SizedBox(width: PS5HydraTheme.space12),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: PS5HydraTheme.metaMonoStyle.copyWith(
              color: PS5HydraTheme.textSecondary,
            ),
          ),
        ),
      ],
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
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 190),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: PS5HydraTheme.textSecondary,
              ),
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
