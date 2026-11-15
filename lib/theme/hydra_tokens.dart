import 'package:flutter/material.dart';

class HydraTokens {
  HydraTokens._();

  // Superfícies GameHub (Obsidian Carbon & Frosted Glass — sem estética artificial de IA)
  static const Color bgPureBlack = Color(0xFF0A090E);
  static const Color bgNearBlack = Color(0xFF13121A);
  static const Color surfaceTopBar = Color(0xFF15141C);
  static const Color surfaceCatalog = Color(0xFF181721);
  static const Color surfaceElevated1 = Color(0xFF211F2C);
  static const Color surfaceElevated2 = Color(0xFF2B2838);

  // Destaques e Acentos estilo GameHub (Branco Puro, Âmbar Dourado, Teal Real)
  static const Color primaryAurora = Color(0xFFF5F5FA);
  static const Color accentAmber = Color(0xFFF5A623);
  static const Color accentTeal = Color(0xFF2DD4BF);
  static const Color accentDanger = Color(0xFFEF4444);
  static const Color accentSuccess = Color(0xFF10B981);

  /// Alias legado que apontava para âmbar com nome errado; mantido por compatibilidade.
  @Deprecated('Use accentAmber')
  static const Color secondaryTeal = accentAmber;

  // Hierarquia Tipográfica GameHub (contraste WCAG >= 4.5:1 sobre bgNearBlack)
  static const Color textPrimary = Color(0xFFF7F7FB);
  static const Color textSecondary = Color(0xFF9C9AA8);
  static const Color textMuted = Color(0xFF9391A6);

  // Bordas de 1px e Divisores
  static const Color borderSubtle8 = Color(0x14FFFFFF);
  static const Color borderSubtle10 = Color(0x22FFFFFF);

  // Nota: tokens mortos nunca referenciados (surfaceBento, tertiaryOcean, accentCyanBorder,
  // accentBlue, neonGlow, textTertiary70, textTertiary50, pillBg4, divider20,
  // cardOverlayGradient, primaryAccentGradient, warmFeaturedGradient, internalCardPillGradient)
  // foram removidos para manter o sistema de design enxuto.

  static const LinearGradient heroBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF181622),
      Color(0xFF0A090E),
    ],
  );

  /// Forma padrão dos diálogos do app (bordas arredondadas + hairline sutil).
  static const RoundedRectangleBorder dialogShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(16)),
    side: BorderSide(color: borderSubtle10),
  );

  /// Breakpoint unificado para layout amplo em landscape/tablet (>= 600dp e paisagem).
  static bool isWideLayout(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width >= 600 && size.width > size.height;
  }

  /// Sombra/glow parametrizada respeitando [opacity], [blur] e [color].
  static List<BoxShadow> neonBoxGlow({
    double opacity = 0.24,
    double blur = 18,
    Color color = primaryAurora,
  }) {
    final safeOpacity = opacity.clamp(0.0, 1.0);
    return [
      BoxShadow(
        color: color.withOpacity(safeOpacity),
        blurRadius: blur,
        offset: const Offset(0, 4),
      ),
    ];
  }

  /// Tema escuro completo mantendo a identidade GameHub/Obsidian e usando
  /// apenas pesos declarados no pubspec.yaml (ReadexPro 600/700 e Rubik 400-700).
  static ThemeData buildAppTheme() {
    const colorScheme = ColorScheme.dark(
      primary: primaryAurora,
      onPrimary: bgPureBlack,
      secondary: accentAmber,
      onSecondary: bgPureBlack,
      tertiary: accentTeal,
      onTertiary: bgPureBlack,
      surface: bgNearBlack,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      error: accentDanger,
      onError: textPrimary,
      outline: borderSubtle10,
      outlineVariant: borderSubtle8,
    );

    const textTheme = TextTheme(
      displayLarge: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 32,
        color: textPrimary,
      ),
      displayMedium: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 28,
        color: textPrimary,
      ),
      displaySmall: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 24,
        color: textPrimary,
      ),
      headlineLarge: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 22,
        color: textPrimary,
      ),
      headlineMedium: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 20,
        color: textPrimary,
      ),
      headlineSmall: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w600,
        fontSize: 18,
        color: textPrimary,
      ),
      titleLarge: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 17,
        color: textPrimary,
      ),
      titleMedium: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w600,
        fontSize: 15,
        color: textPrimary,
      ),
      titleSmall: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w600,
        fontSize: 13.5,
        color: textPrimary,
      ),
      bodyLarge: TextStyle(
        fontFamily: 'Rubik',
        fontWeight: FontWeight.w400,
        fontSize: 15,
        color: textPrimary,
      ),
      bodyMedium: TextStyle(
        fontFamily: 'Rubik',
        fontWeight: FontWeight.w400,
        fontSize: 13.5,
        color: textSecondary,
      ),
      bodySmall: TextStyle(
        fontFamily: 'Rubik',
        fontWeight: FontWeight.w400,
        fontSize: 12,
        color: textMuted,
      ),
      labelLarge: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w700,
        fontSize: 13,
        color: textPrimary,
      ),
      labelMedium: TextStyle(
        fontFamily: 'ReadexPro',
        fontWeight: FontWeight.w600,
        fontSize: 11.5,
        color: textSecondary,
      ),
      labelSmall: TextStyle(
        fontFamily: 'Rubik',
        fontWeight: FontWeight.w500,
        fontSize: 10.5,
        color: textMuted,
      ),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: bgPureBlack,
      canvasColor: bgPureBlack,
      fontFamily: 'Rubik',
      textTheme: textTheme,
      dividerTheme: const DividerThemeData(
        color: borderSubtle8,
        thickness: 1,
      ),
      dialogTheme: const DialogTheme(
        backgroundColor: bgNearBlack,
        shape: dialogShape,
        titleTextStyle: TextStyle(
          fontFamily: 'ReadexPro',
          fontWeight: FontWeight.w700,
          fontSize: 16,
          color: textPrimary,
        ),
        contentTextStyle: TextStyle(
          fontFamily: 'Rubik',
          fontWeight: FontWeight.w400,
          fontSize: 13,
          color: textSecondary,
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceElevated1,
        contentTextStyle: TextStyle(
          fontFamily: 'Rubik',
          fontWeight: FontWeight.w400,
          fontSize: 13,
          color: textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceElevated2,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderSubtle10),
        ),
        textStyle: const TextStyle(
          fontFamily: 'Rubik',
          fontWeight: FontWeight.w400,
          fontSize: 12,
          color: textPrimary,
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surfaceCatalog,
        labelStyle: TextStyle(
          fontFamily: 'Rubik',
          fontWeight: FontWeight.w400,
          color: textSecondary,
        ),
        hintStyle: TextStyle(
          fontFamily: 'Rubik',
          fontWeight: FontWeight.w400,
          color: textMuted,
        ),
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: borderSubtle10),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: primaryAurora, width: 1.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return textMuted;
          }
          if (states.contains(WidgetState.selected)) {
            return bgPureBlack;
          }
          return textSecondary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return surfaceElevated1;
          }
          if (states.contains(WidgetState.selected)) {
            return primaryAurora;
          }
          return surfaceElevated2;
        }),
      ),
    );
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
