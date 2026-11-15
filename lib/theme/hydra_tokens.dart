import 'package:flutter/material.dart';

class HydraTokens {
  HydraTokens._();

  // Superfícies GameHub (Obsidian Carbon & Frosted Glass — sem estética artificial de IA)
  static const Color bgPureBlack = Color(0xFF0A090E);
  static const Color bgNearBlack = Color(0xFF13121A);
  static const Color surfaceCatalog = Color(0xFF181721);
  static const Color surfaceElevated1 = Color(0xFF211F2C);
  static const Color surfaceElevated2 = Color(0xFF2B2838);
  static const Color surfaceBento = Color(0xFF15141D);

  // Destaques e Acentos estilo GameHub (Branco Puro, Âmbar Dourado, Prata)
  static const Color primaryAurora = Color(0xFFF5F5FA);
  static const Color secondaryTeal = Color(0xFFF5A623);
  static const Color tertiaryOcean = Color(0xFF3B82F6);
  static const Color accentCyanBorder = Color(0xFFE2E2EC);
  static const Color accentBlue = Color(0xFF60A5FA);
  static const Color accentAmber = Color(0xFFF5A623);
  static const Color accentDanger = Color(0xFFEF4444);
  static const Color accentSuccess = Color(0xFF10B981);
  static const Color neonGlow = Color(0xFFF5F5FA);

  // Hierarquia Tipográfica GameHub
  static const Color textPrimary = Color(0xFFF7F7FB);
  static const Color textSecondary = Color(0xFF9C9AA8);
  static const Color textMuted = Color(0xFF646273);
  static const Color textTertiary70 = Color(0xB3F7F7FB);
  static const Color textTertiary50 = Color(0x809C9AA8);

  // Bordas de 1px e Divisores
  static const Color borderSubtle8 = Color(0x14FFFFFF);
  static const Color borderSubtle10 = Color(0x22FFFFFF);
  static const Color pillBg4 = Color(0x12FFFFFF);
  static const Color divider20 = Color(0x1FFFFFFF);

  static const LinearGradient heroBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF181622),
      Color(0xFF0A090E),
    ],
  );

  static const LinearGradient cardOverlayGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.45, 1.0],
    colors: [
      Color(0x000A090E),
      Color(0x770A090E),
      Color(0xF50A090E),
    ],
  );

  static const LinearGradient primaryAccentGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFFFFFFF), Color(0xFFD8D6E2)],
  );

  static const LinearGradient warmFeaturedGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFF5A623), Color(0xFFD97706)],
  );

  static const LinearGradient internalCardPillGradient = LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: [Color(0xFF1D1B27), Color(0xFF252331)],
  );

  static List<BoxShadow> neonBoxGlow({
    double opacity = 0.24,
    double blur = 18,
  }) {
    return [
      BoxShadow(
        color: const Color(0xFF000000).withOpacity(0.65),
        blurRadius: blur,
        offset: const Offset(0, 8),
      ),
    ];
  }
}

/// Superfície estruturada estilo GameHub com hairline sutil e suporte a clique e long-press
class HydraTexturedCard extends StatelessWidget {
  const HydraTexturedCard({
    super.key,
    required this.child,
    this.backgroundColor = HydraTokens.bgNearBlack,
    this.borderRadius = 14.0,
    this.highlightedBorder = false,
    this.showCornerRadialGlow = false,
    this.padding,
    this.onTap,
    this.onLongPress,
  });

  final Widget child;
  final Color backgroundColor;
  final double borderRadius;
  final bool highlightedBorder;
  final bool showCornerRadialGlow;
  final EdgeInsetsGeometry? padding;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: radius,
        border: Border.all(
          color: highlightedBorder
              ? HydraTokens.primaryAurora.withOpacity(0.85)
              : HydraTokens.borderSubtle8,
          width: highlightedBorder ? 1.5 : 1.0,
        ),
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: Padding(
              padding: padding ?? EdgeInsets.zero,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
