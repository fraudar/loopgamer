import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/ps5_hydra_theme.dart';

/// Transição reutilizável de entrada com fade + deslizamento vertical suave
/// (duração padrão 300ms, `Curves.easeOut`, deslize de 10px para cima).
class AnimatedFadeSlide extends StatefulWidget {
  const AnimatedFadeSlide({
    super.key,
    required this.child,
    this.duration = PS5HydraTheme.animStandard,
    this.delay = Duration.zero,
    this.offsetY = 10.0,
    this.curve = Curves.easeOut,
  });

  final Widget child;
  final Duration duration;
  final Duration delay;
  final double offsetY;
  final Curve curve;

  @override
  State<AnimatedFadeSlide> createState() => _AnimatedFadeSlideState();
}

class _AnimatedFadeSlideState extends State<AnimatedFadeSlide>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _translateY;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    final curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    _opacity = Tween<double>(begin: 0.0, end: 1.0).animate(curved);
    _translateY = Tween<double>(begin: widget.offsetY, end: 0.0).animate(curved);

    if (widget.delay <= Duration.zero) {
      unawaited(_controller.forward());
    } else {
      _delayTimer = Timer(widget.delay, () {
        if (mounted) {
          unawaited(_controller.forward());
        }
      });
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: AnimatedBuilder(
        animation: _translateY,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, _translateY.value),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// Wrapper de [AnimatedSwitcher] padrão PS5 para troca de título, Clear Logo
/// e sinopse: `FadeTransition` + `SlideTransition` (`10px` para cima),
/// duração `300ms` e curva `Curves.easeOut`.
class AnimatedHeroFadeSlideSwitcher extends StatelessWidget {
  const AnimatedHeroFadeSlideSwitcher({
    super.key,
    required this.child,
    this.duration = PS5HydraTheme.animStandard,
    this.curve = Curves.easeOut,
    this.slideFractionY = 0.10,
    this.alignment = Alignment.topLeft,
  });

  final Widget child;
  final Duration duration;
  final Curve curve;
  final double slideFractionY;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: curve,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: alignment,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      transitionBuilder: (child, animation) {
        final curved = CurvedAnimation(parent: animation, curve: curve);
        final slideAnim = Tween<Offset>(
          begin: Offset(0, slideFractionY),
          end: Offset.zero,
        ).animate(curved);
        return FadeTransition(
          opacity: curved,
          child: SlideTransition(
            position: slideAnim,
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
