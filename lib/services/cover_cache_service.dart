import 'dart:async';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/emulation_game.dart';

/// Presets de resolução para decodificação em memória de [LoopCoverImage].
enum LoopCoverImagePreset {
  /// Ícones pequenos e listas compactas (~128x184).
  thumbnail,

  /// Cartões padrão de catálogo e biblioteca (~320x460).
  card,

  /// Banners hero e backdrops amplos (~960x540).
  hero,

  /// Mantém resolução original sem downscale explícito.
  original,
}

/// Serviço de Cache Persistente em Disco e Pré-Carregamento Agressivo de Capas.
/// Garante que quem baixa o app tenha as capas carregadas instantaneamente do disco,
/// sem precisar esperar ou rolar a tela com lentidão.
class CoverCacheService {
  CoverCacheService._();
  static final CoverCacheService instance = CoverCacheService._();

  Directory? _cacheDir;
  Dio? _dio;

  final Map<String, Completer<File?>> _inFlightDownloads = {};
  final Set<String> _cachedUrlKeys = {};
  bool _isPrecacheRunning = false;
  int _lifecycleEpoch = 0;
  int _tempFileSequence = 0;

  Dio _createDio() => Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 8),
          receiveTimeout: const Duration(seconds: 12),
          responseType: ResponseType.bytes,
        ),
      );

  Dio get _dioClient => _dio ??= _createDio();

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
    } catch (e) {
      debugPrint('[CoverCacheService] Cache index scan failed: $e');
    }

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

    final cachedFast = getCachedFileFast(url);
    if (cachedFast != null) return cachedFast;

    final existing = _inFlightDownloads[url];
    if (existing != null) {
      return existing.future;
    }

    final opEpoch = _lifecycleEpoch;
    final completer = Completer<File?>();
    _inFlightDownloads[url] = completer;

    File? tempFile;
    try {
      final dir = await ensureCacheDirectory();
      if (opEpoch != _lifecycleEpoch) {
        if (!completer.isCompleted) completer.complete(null);
        return null;
      }

      final key = _hashUrl(url);
      final targetFile = File('${dir.path}/$key');

      if (await targetFile.exists() && await targetFile.length() > 100) {
        _cachedUrlKeys.add(key);
        if (!completer.isCompleted) completer.complete(targetFile);
        return targetFile;
      }

      tempFile = File(
        '${dir.path}/$key.tmp_${DateTime.now().microsecondsSinceEpoch}_${_tempFileSequence++}',
      );

      final response = await _dioClient.get<List<int>>(url);
      if (opEpoch != _lifecycleEpoch) {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
        if (!completer.isCompleted) completer.complete(null);
        return null;
      }

      final status = response.statusCode;
      if (status != null &&
          status >= 200 &&
          status < 300 &&
          response.data != null &&
          response.data!.isNotEmpty) {
        await tempFile.writeAsBytes(response.data!, flush: true);
        if (await tempFile.length() > 100) {
          if (await targetFile.exists()) {
            await targetFile.delete();
          }
          await tempFile.rename(targetFile.path);
          _cachedUrlKeys.add(key);
          if (!completer.isCompleted) completer.complete(targetFile);
          return targetFile;
        }
      }
      if (!completer.isCompleted) completer.complete(null);
    } on DioException catch (e) {
      if (e.type != DioExceptionType.cancel) {
        debugPrint(
          '[CoverCacheService] Cover download failed (${e.response?.statusCode}): $url',
        );
      }
      await _safeDeleteTemp(tempFile);
      if (!completer.isCompleted) completer.complete(null);
    } catch (e) {
      debugPrint('[CoverCacheService] Cover download error ($url): $e');
      await _safeDeleteTemp(tempFile);
      if (!completer.isCompleted) completer.complete(null);
    } finally {
      if (identical(_inFlightDownloads[url], completer)) {
        _inFlightDownloads.remove(url);
      }
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    return null;
  }

  Future<void> _safeDeleteTemp(File? tempFile) async {
    if (tempFile == null) return;
    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (e) {
      debugPrint('[CoverCacheService] Temp cleanup failed: $e');
    }
  }

  /// Pré-carrega de forma massiva e não bloqueante todas as capas do catálogo
  /// usando um pool concorrente de 3 downloads simultâneos em segundo plano,
  /// pausando entre lotes para priorizar as capas atualmente visíveis na tela.
  Future<void> precacheCatalog(List<EmulationGame> games) async {
    if (_isPrecacheRunning) return;
    _isPrecacheRunning = true;
    final opEpoch = _lifecycleEpoch;

    try {
      await ensureCacheDirectory();
      if (opEpoch != _lifecycleEpoch) return;

      final urlsToFetch = <String>[];
      for (final game in games) {
        final url = game.resolvedGridCoverUrl;
        if (url.isNotEmpty && getCachedFileFast(url) == null) {
          urlsToFetch.add(url);
        }
      }

      if (urlsToFetch.isEmpty) {
        return;
      }

      // Executa em lotes paralelos de 3 downloads por vez com pausas leves
      const int concurrency = 3;
      for (int i = 0; i < urlsToFetch.length; i += concurrency) {
        if (opEpoch != _lifecycleEpoch) break;
        final chunk = urlsToFetch.sublist(
          i,
          (i + concurrency > urlsToFetch.length)
              ? urlsToFetch.length
              : i + concurrency,
        );
        await Future.wait(
          chunk.map(downloadAndCache),
          eagerError: false,
        );
        if (opEpoch != _lifecycleEpoch) break;
        // Pausa leve para liberar banda para os itens atualmente visíveis na viewport
        await Future.delayed(const Duration(milliseconds: 60));
      }
    } catch (e) {
      debugPrint('[CoverCacheService] Precache aborted: $e');
    } finally {
      _isPrecacheRunning = false;
    }
  }

  /// Interrompe pré-carregamentos ativos, cancela downloads em voo e libera o client HTTP.
  void dispose() {
    _lifecycleEpoch++;
    _isPrecacheRunning = false;

    for (final completer in _inFlightDownloads.values) {
      if (!completer.isCompleted) {
        completer.complete(null);
      }
    }
    _inFlightDownloads.clear();

    final oldDio = _dio;
    _dio = null;
    oldDio?.close(force: true);
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
    this.cacheWidth,
    this.cacheHeight,
    this.preset,
  });

  final String url;
  final String fallbackAsset;
  final BoxFit fit;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final int? cacheWidth;
  final int? cacheHeight;
  final LoopCoverImagePreset? preset;

  /// Resolve `(cacheWidth, cacheHeight)` de acordo com dimensões explícitas,
  /// [preset], ou tamanho finito do widget para evitar borrão em heroes e excesso de RAM em miniaturas.
  ({int? cacheWidth, int? cacheHeight}) resolveCacheDimensions() {
    if (cacheWidth != null || cacheHeight != null) {
      return (
        cacheWidth: (cacheWidth != null && cacheWidth! > 0) ? cacheWidth : null,
        cacheHeight:
            (cacheHeight != null && cacheHeight! > 0) ? cacheHeight : null,
      );
    }

    switch (preset) {
      case LoopCoverImagePreset.thumbnail:
        return (cacheWidth: 128, cacheHeight: 184);
      case LoopCoverImagePreset.card:
        return (cacheWidth: 320, cacheHeight: 460);
      case LoopCoverImagePreset.hero:
        return (cacheWidth: 960, cacheHeight: 540);
      case LoopCoverImagePreset.original:
        return (cacheWidth: null, cacheHeight: null);
      case null:
        break;
    }

    final hasWidth = width != null && width!.isFinite && width! > 0;
    final hasHeight = height != null && height!.isFinite && height! > 0;

    if (hasWidth && hasHeight) {
      return (
        cacheWidth: (width! * 2).round().clamp(64, 1280),
        cacheHeight: (height! * 2).round().clamp(64, 1280),
      );
    }
    if (hasWidth) {
      return (
        cacheWidth: (width! * 2).round().clamp(64, 1280),
        cacheHeight: null,
      );
    }
    if (hasHeight) {
      return (
        cacheWidth: null,
        cacheHeight: (height! * 2).round().clamp(64, 1280),
      );
    }
    return (cacheWidth: 320, cacheHeight: 460);
  }

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
      _localFile = null;
      _checkCacheAndTriggerDownload();
    }
  }

  void _checkCacheAndTriggerDownload() {
    final targetUrl = widget.url;
    if (targetUrl.trim().isEmpty) {
      _localFile = null;
      return;
    }

    final cached = CoverCacheService.instance.getCachedFileFast(targetUrl);
    if (cached != null) {
      _localFile = cached;
      return;
    }

    if (targetUrl.startsWith('http')) {
      unawaited(
        CoverCacheService.instance.downloadAndCache(targetUrl).then((file) {
          if (!mounted || widget.url != targetUrl) return;
          if (file != null && _localFile == null) {
            setState(() {
              _localFile = file;
            });
          }
        }),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cacheDims = widget.resolveCacheDimensions();
    Widget content;

    if (_localFile != null) {
      // 1. Arquivo já persistido no disco local: 0ms de espera, offline imediato
      content = Image.file(
        _localFile!,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: cacheDims.cacheWidth,
        cacheHeight: cacheDims.cacheHeight,
        errorBuilder: (_, __, ___) => _buildFallback(cacheDims),
      );
    } else if (widget.url.startsWith('http')) {
      // 2. Primeira vez na tela: baixa e exibe instantaneamente da rede (visíveis primeiro!)
      content = Image.network(
        widget.url,
        fit: widget.fit,
        width: widget.width,
        height: widget.height,
        cacheWidth: cacheDims.cacheWidth,
        cacheHeight: cacheDims.cacheHeight,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (wasSynchronouslyLoaded || frame != null) {
            return child;
          }
          return _buildLoadingPlaceholder();
        },
        errorBuilder: (_, __, ___) => _buildFallback(cacheDims),
      );
    } else {
      content = _buildFallback(cacheDims);
    }

    if (widget.borderRadius != null) {
      return ClipRRect(
        borderRadius: widget.borderRadius!,
        child: content,
      );
    }

    return content;
  }

  Widget _buildFallback(({int? cacheWidth, int? cacheHeight}) cacheDims) {
    return Image.asset(
      widget.fallbackAsset,
      fit: widget.fit,
      width: widget.width,
      height: widget.height,
      cacheWidth: cacheDims.cacheWidth,
      cacheHeight: cacheDims.cacheHeight,
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      decoration: const BoxDecoration(
        color: Color(0xFF121216),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF18181D),
            Color(0xFF0B0B0D),
          ],
        ),
      ),
      child: Center(
        child: Container(
          width: 24,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Colors.white.withOpacity(0.10),
            ),
          ),
        ),
      ),
    );
  }
}
