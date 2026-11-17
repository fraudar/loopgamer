import 'package:flutter/material.dart';

/// Tokens oficiais do Design System (`DESIGN.md`) em paleta monocromática Preto & Branco OLED.
/// Mantém compatibilidade total com `HydraTokens`.
class PS5HydraTheme {
  PS5HydraTheme._();

  // ===========================================================================
  // Paleta principal (Preto Puro #000000 + Superfícies Obsidian + Acento Branco #FFFFFF)
  // ===========================================================================
  static const Color pitchBlack = Color(0xFF000000);
  static const Color obsidianGlass = Color(0xFF0B0B0D);
  static const Color abyssalCard = Color(0xFF121216);
  static const Color auroraSpringMint = Color(0xFFFFFFFF);
  static const Color auroraSeafoamMist = Color(0xFFF4F4F5);
  static const Color auroraCyanTeal = Color(0xFFE4E4E7);
  static const Color auroraOceanCerulean = Color(0xFF3F3F46);
  static const Color auroraDeepTrench = Color(0xFF18181B);
  static const Color textPrimary = Color(0xFFFAFAFA);
  static const Color textSecondary = Color(0xFFA1A1AA);
  static const Color textOnAurora = Color(0xFF000000);
  static const Color borderSubtle = Color(0xFF27272A);
  static const Color dangerRose = Color(0xFFF24C5C);

  // ===========================================================================
  // Tokens de layout & superfícies (UI-REDESIGN.md Seção 5)
  // ===========================================================================
  static const double skyDepthPortrait = 0.36;
  static const double skyDepthLandscape = 0.56;
  static const double waffleCellPortrait = 28.0;
  static const double waffleCellLandscape = 36.0;
  static const double radiusCard = 20.0;
  static const double radiusChip = 10.0;

  // Escala única de espaçamento: 4 / 8 / 12 / 16 / 24 / 32
  static const double space4 = 4.0;
  static const double space8 = 8.0;
  static const double space12 = 12.0;
  static const double space16 = 16.0;
  static const double space24 = 24.0;
  static const double space32 = 32.0;

  // Curvas e durações padronizadas (150ms a 400ms)
  static const Duration animFast = Duration(milliseconds: 200);
  static const Duration animMedium = Duration(milliseconds: 250);
  static const Duration animStandard = Duration(milliseconds: 300);
  static const Duration animEntrance = Duration(milliseconds: 400);
  static const Duration staggerDelay = Duration(milliseconds: 40);

  /// Scrim de legibilidade cobrindo os 45% inferiores sobre a aurora.
  static const LinearGradient scrimBottom = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.55, 1.0],
    colors: [
      Color(0x00000000),
      Color(0xA8000000),
      Color(0xE0000000),
    ],
  );

  /// Glow branco discreto para tile em foco no estilo Console OLED.
  static List<BoxShadow> get glowFocus => [
        BoxShadow(
          color: auroraSpringMint.withOpacity(0.28),
          blurRadius: 16,
          spreadRadius: 0,
        ),
      ];

  /// Superfície de vidro `obsidianGlass` 92% + hairline `borderSubtle` + raio 20.
  static BoxDecoration surfaceGlass({
    double radius = radiusCard,
    double alpha = 0.92,
    bool highlighted = false,
  }) {
    return BoxDecoration(
      color: obsidianGlass.withOpacity(alpha),
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(
        color: highlighted
            ? auroraSpringMint.withOpacity(0.65)
            : borderSubtle,
        width: 1.0,
      ),
    );
  }

  /// Regra de decisão de layout por orientação + shortSide (UI-REDESIGN.md Seção 0).
  static bool useCompactLayout(BoxConstraints constraints) {
    final bool isPortrait = constraints.maxHeight > constraints.maxWidth;
    final bool isPhone = constraints.smallest.shortestSide < 600;
    return isPortrait || isPhone;
  }

  /// Tipografia `ReadexPro`, `Rubik` e `JetBrainsMono`.
  static const TextStyle displayTitleStyle = TextStyle(
    fontFamily: 'ReadexPro',
    fontWeight: FontWeight.w700,
    fontSize: 28,
    height: 1.15,
    letterSpacing: -0.7,
    color: textPrimary,
  );

  static const TextStyle bodySynopsisStyle = TextStyle(
    fontFamily: 'Rubik',
    fontWeight: FontWeight.w400,
    fontSize: 14,
    height: 1.45,
    color: textSecondary,
  );

  static const TextStyle metaMonoStyle = TextStyle(
    fontFamily: 'JetBrainsMono',
    fontWeight: FontWeight.w700,
    fontSize: 11,
    letterSpacing: 0.2,
    fontFeatures: [FontFeature.tabularFigures()],
    color: textSecondary,
  );

  /// Divisor vertical de 1px para Meta Row.
  static Widget metaDivider() {
    return Container(
      width: 1,
      height: 12,
      margin: const EdgeInsets.symmetric(horizontal: space8),
      color: borderSubtle,
    );
  }
}
