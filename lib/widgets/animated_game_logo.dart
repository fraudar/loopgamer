import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../models/emulation_game.dart';
import '../services/game_asset_service.dart';
import '../theme/ps5_hydra_theme.dart';
import 'animated_fade_slide.dart';

/// Exibe a logo oficial transparente do jogo (clear logo PNG) obtida via API
/// sem necessidade de chave (Steam CDN / GOG / Wikidata + Wikimedia Commons,
/// além de SteamGridDB/RAWG se configuradas).
///
/// - Altura fixa (padrão `40px`) e largura máxima (`80%` do container pai), com `BoxFit.contain`.
/// - `FadeTransition` de `300ms` ao carregar a imagem.
/// - Entrada escalonada (`40ms` por item) via `AnimatedFadeSlide` ao rolar listas.
/// - Fallback automático em `ReadexPro` 700 caso nenhuma logo seja encontrada.
class AnimatedGameLogo extends StatefulWidget {
  const AnimatedGameLogo({
    super.key,
    required this.game,
    this.assetService,
    this.height = 40.0,
    this.maxWidthFraction = 0.80,
    this.itemIndex = 0,
    this.staggerStep = PS5HydraTheme.staggerDelay,
    this.alignment = Alignment.centerLeft,
    this.fallbackStyle,
    this.maxLines = 2,
    this.enableStagger = true,
  });

  final EmulationGame game;
  final GameAssetService? assetService;
  final double height;
  final double maxWidthFraction;
  final int itemIndex;
  final Duration staggerStep;
  final Alignment alignment;
  final TextStyle? fallbackStyle;
  final int maxLines;
  final bool enableStagger;

  @override
  State<AnimatedGameLogo> createState() => _AnimatedGameLogoState();
}

class _AnimatedGameLogoState extends State<AnimatedGameLogo>
    with SingleTickerProviderStateMixin {
  late final AnimationController _logoFadeController;
  late final Animation<double> _logoFadeAnimation;
  String? _resolvedLogoUrl;
  bool _imageFailed = false;
  bool _hasStartedLogoFade = false;
  int _requestEpoch = 0;

  GameAssetService get _service =>
      widget.assetService ?? GameAssetService.instance;

  @override
  void initState() {
    super.initState();
    _logoFadeController = AnimationController(
      vsync: this,
      duration: PS5HydraTheme.animStandard, // 300ms
    );
    _logoFadeAnimation = CurvedAnimation(
      parent: _logoFadeController,
      curve: Curves.easeOut,
    );
    _resolveLogo();
  }

  @override
  void didUpdateWidget(covariant AnimatedGameLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.game.igdbId != widget.game.igdbId ||
        oldWidget.game.name != widget.game.name ||
        oldWidget.game.logoUrl != widget.game.logoUrl) {
      _imageFailed = false;
      _hasStartedLogoFade = false;
      _logoFadeController.reset();
      _resolveLogo();
    }
  }

  void _resolveLogo() {
    final epoch = ++_requestEpoch;
    final direct = widget.game.logoUrl?.trim();
    if (direct != null && direct.isNotEmpty) {
      _resolvedLogoUrl = direct;
      return;
    }

    final cached = _service.getCachedAssets(
      widget.game.name,
      platformSlug: widget.game.platformSlug,
    );
    if (cached != null) {
      _resolvedLogoUrl = cached.logoImageUrl;
      return;
    }

    _resolvedLogoUrl = null;
    unawaited(
      _service.fetchAssetsForGame(widget.game).then((assets) {
        if (!mounted || epoch != _requestEpoch) return;
        if (assets.hasLogo && assets.logoImageUrl != _resolvedLogoUrl) {
          setState(() {
            _resolvedLogoUrl = assets.logoImageUrl;
            _imageFailed = false;
            _hasStartedLogoFade = false;
          });
        }
      }),
    );
  }

  void _triggerLogoFadeIn() {
    if (_hasStartedLogoFade) return;
    _hasStartedLogoFade = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(_logoFadeController.forward());
      }
    });
  }

  @override
  void dispose() {
    _logoFadeController.dispose();
    super.dispose();
  }

  Widget _buildTextFallback() {
    final baseStyle = widget.fallbackStyle ??
        const TextStyle(
          fontFamily: 'ReadexPro',
          fontWeight: FontWeight.w700,
          fontSize: 15,
          height: 1.2,
          color: PS5HydraTheme.textPrimary,
        );

    return Align(
      alignment: widget.alignment,
      child: Text(
        widget.game.name,
        maxLines: widget.maxLines,
        overflow: TextOverflow.ellipsis,
        style: baseStyle,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final logoUrl = _resolvedLogoUrl;
    final Widget core = LayoutBuilder(
      builder: (context, constraints) {
        final hasFiniteWidth =
            constraints.hasBoundedWidth && constraints.maxWidth.isFinite;
        final double maxWidth = hasFiniteWidth
            ? (constraints.maxWidth * widget.maxWidthFraction)
                .clamp(48.0, constraints.maxWidth)
            : 260.0;

        if (_imageFailed ||
            logoUrl == null ||
            logoUrl.isEmpty ||
            !logoUrl.startsWith('http')) {
          return ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: maxWidth,
              minHeight: widget.height * 0.65,
            ),
            child: _buildTextFallback(),
          );
        }

        return Semantics(
          label: widget.game.name,
          image: true,
          child: SizedBox(
            height: widget.height,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxWidth,
                maxHeight: widget.height,
              ),
              child: Align(
                alignment: widget.alignment,
                child: CachedNetworkImage(
                  imageUrl: logoUrl,
                  cacheManager: SessionMemoryCacheManager.instance,
                  fit: BoxFit.contain,
                  height: widget.height,
                  alignment: widget.alignment,
                  fadeInDuration: Duration.zero,
                  fadeOutDuration: PS5HydraTheme.animFast,
                  imageBuilder: (context, imageProvider) {
                    _triggerLogoFadeIn();
                    return FadeTransition(
                      opacity: _logoFadeAnimation,
                      child: Image(
                        image: imageProvider,
                        height: widget.height,
                        fit: BoxFit.contain,
                        alignment: widget.alignment,
                      ),
                    );
                  },
                  placeholder: (_, __) => _buildTextFallback(),
                  errorWidget: (_, __, ___) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && !_imageFailed) {
                        setState(() => _imageFailed = true);
                      }
                    });
                    return _buildTextFallback();
                  },
                ),
              ),
            ),
          ),
        );
      },
    );

    if (!widget.enableStagger) {
      return core;
    }

    final int cappedIndex = widget.itemIndex.clamp(0, 10);
    return AnimatedFadeSlide(
      key: ValueKey<String>('logo_stagger_${widget.game.igdbId}'),
      duration: PS5HydraTheme.animStandard,
      delay: widget.staggerStep * cappedIndex,
      offsetY: 8.0,
      curve: Curves.easeOutCubic,
      child: core,
    );
  }
}
