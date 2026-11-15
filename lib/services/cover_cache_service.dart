import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';
import '../models/emulation_game.dart';
import '../theme/hydra_tokens.dart';

/// Serviço de Cache Persistente em Disco e Pré-Carregamento Agressivo de Capas.
/// Garante que quem baixa o app tenha as capas carregadas instantaneamente do disco,
/// sem precisar esperar ou rolar a tela com lentidão.
class CoverCacheService {
  CoverCacheService._();
  static final CoverCacheService instance = CoverCacheService._();

  Directory? _cacheDir;
  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 12),
      responseType: ResponseType.bytes,
    ),
  );

  final Map<String, Completer<File?>> _inFlightDownloads = {};
  final Set<String> _cachedUrlKeys = {};
  bool _isPrecacheRunning = false;

  /// Inicializa o diretório local permanente de capas
  Future<Directory> ensureCacheDirectory() async {
    if (_cacheDir != null && await _cacheDir!.exists()) {
      return _cacheDir!;
    }
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/loop_covers_cache');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _cacheDir = dir;

    // Popula o conjunto em memória dos arquivos já existentes para lookup síncrono instantâneo
    try {
      await for (final entity in dir.list()) {
        if (entity is File && entity.path.endsWith('.img')) {
          final filename = entity.path.split(Platform.pathSeparator).last;
          _cachedUrlKeys.add(filename);
        }
      }
    } catch (_) {}

    return _cacheDir!;
  }

  String _hashUrl(String url) {
    int hash = 0x811c9dc5;
    for (int i = 0; i < url.length; i++) {
      hash ^= url.codeUnitAt(i);
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return '${hash.toRadixString(16)}.img';
  }

  /// Retorna o arquivo de cache em disco se ele já existir, ou null
  File? getCachedFileFast(String? url) {
    if (url == null || url.trim().isEmpty) return null;
    final key = _hashUrl(url);
    if (_cachedUrlKeys.contains(key) && _cacheDir != null) {
      final file = File('${_cacheDir!.path}/$key');
      if (file.existsSync() && file.lengthSync() > 100) {
        return file;
      }
    }
    return null;
  }

  /// Baixa a capa para o disco de forma persistente
  Future<File?> downloadAndCache(String url) async {
    if (url.trim().isEmpty) return null;
    final dir = await ensureCacheDirectory();
    final key = _hashUrl(url);
    final targetFile = File('${dir.path}/$key');

    if (await targetFile.exists() && await targetFile.length() > 100) {
      _cachedUrlKeys.add(key);
      return targetFile;
    }

    if (_inFlightDownloads.containsKey(url)) {
      return _inFlightDownloads[url]!.future;
    }

    final completer = Completer<File?>();
    _inFlightDownloads[url] = completer;
    final tempFile = File(
      '${dir.path}/$key.tmp_${DateTime.now().microsecondsSinceEpoch}',
    );

    try {
      final response = await _dio.get<List<int>>(url);
      if (response.statusCode == 200 &&
          response.data != null &&
          response.data!.isNotEmpty) {
        await tempFile.writeAsBytes(response.data!, flush: true);
        if (await tempFile.length() > 100) {
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          await tempFile.rename(targetFile.path);
          _cachedUrlKeys.add(key);
          completer.complete(targetFile);
          return targetFile;
        }
      }
      completer.complete(null);
    } catch (_) {
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      completer.complete(null);
    } finally {
      _inFlightDownloads.remove(url);
    }
    return null;
  }

  /// Pré-carrega de forma massiva e não bloqueante todas as capas do catálogo
  /// usando um pool concorrente de 3 downloads simultâneos em segundo plano,
  /// pausando entre lotes para priorizar as capas atualmente visíveis na tela.
  Future<void> precacheCatalog(List<EmulationGame> games) async {
    if (_isPrecacheRunning) return;
    _isPrecacheRunning = true;

    try {
      await ensureCacheDirectory();

      final urlsToFetch = <String>[];
      for (final game in games) {
        final url = game.resolvedGridCoverUrl;
        if (url.isNotEmpty && getCachedFileFast(url) == null) {
          urlsToFetch.add(url);
        }
      }

      if (urlsToFetch.isEmpty) {
        _isPrecacheRunning = false;
        return;
      }

      // Executa em lotes paralelos de 3 downloads por vez com pausas leves
      const int concurrency = 3;
      for (int i = 0; i < urlsToFetch.length; i += concurrency) {
        final chunk = urlsToFetch.sublist(
          i,
          (i + concurrency > urlsToFetch.length)
              ? urlsToFetch.length
              : i + concurrency,
        );
        await Future.wait(
          chunk.map((u) => downloadAndCache(u)),
          eagerError: false,
        );
        // Pausa leve para liberar banda para os itens atualmente visíveis na viewport
        await Future.delayed(const Duration(milliseconds: 60));
      }
    } catch (_) {
    } finally {
      _isPrecacheRunning = false;
    }
  }
}

/// Widget de Capa Otimizado:
/// 1. Se estiver no disco local: renderiza instantaneamente via `Image.file` com downscale na memória.
/// 2. Se não estiver: exibe placeholder elegante, inicia download para o disco e faz transição suave.
class LoopCoverImage extends StatefulWidget {
  const LoopCoverImage({
    super.key,
    required this.url,
    this.fallbackAsset = 'assets/images/hydra_hero_bg.png',
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.borderRadius,
    this.platformSlug,
    this.gameTitle,
  });

  final String url;
  final String fallbackAsset;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final String? platformSlug;
  final String? gameTitle;

  @override
  State<LoopCoverImage> createState() => _LoopCoverImageState();
}

class _LoopCoverImageState extends State<LoopCoverImage> {
  File? _localFile;

  @override
  void initState() {
    super.initState();
    _checkCacheAndTriggerDownload();
  }

  @override
  void didUpdateWidget(covariant LoopCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _checkCacheAndTriggerDownload();
    }
  }

  void _checkCacheAndTriggerDownload() {
    final cached = CoverCacheService.instance.getCachedFileFast(widget.url);
    if (cached != null) {
      _localFile = cached;
      return;
    }

    if (widget.url.startsWith('http')) {
      CoverCacheService.instance.downloadAndCache(widget.url).then((file) {
        if (!mounted) return;
        if (file != null && _localFile == null) {
          setState(() {
            _localFile = file;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget content;

    if (_localFile != null) {
      // 1. Arquivo já persistido no disco local: 0ms de espera, offline imediato
      content = Image.file(
        _localFile!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: 320,
        cacheHeight: 460,
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    } else if (widget.url.startsWith('http')) {
      // 2. Primeira vez na tela: baixa e exibe instantaneamente da rede (visíveis primeiro!)
      content = Image.network(
        widget.url,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: 320,
        cacheHeight: 460,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return _buildLoadingPlaceholder();
        },
        errorBuilder: (_, __, ___) => _buildFallback(),
      );
    } else {
      content = _buildFallback();
    }

    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: content,
      );
    }

    return content;
  }

  Widget _buildFallback() {
    return Image.asset(
      widget.fallbackAsset,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: 320,
      cacheHeight: 460,
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: HydraTokens.surfaceElevated1,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withOpacity(0.08),
            Colors.black.withOpacity(0.65),
          ],
        ),
      ),
      child: Center(
        child: PhosphorIcon(
          PhosphorIcons.gameController(PhosphorIconsStyle.bold),
          size: 22,
          color: Colors.white.withOpacity(0.35),
        ),
      ),
    );
  }
}
