import 'package:flutter/material.dart';

class HydraTokens {
  HydraTokens._();

  // Superfícies Console-first (Preto Puro #000000 & Obsidian Neutro Preto/Branco)
  static const Color bgPureBlack = Color(0xFF000000);
  static const Color bgNearBlack = Color(0xFF0B0B0D);
  static const Color surfaceTopBar = Color(0xFF0B0B0D);
  static const Color surfaceCatalog = Color(0xFF121216);
  static const Color surfaceElevated1 = Color(0xFF18181D);
  static const Color surfaceElevated2 = Color(0xFF222228);

  // Destaque monocromático branco (#FFFFFF) sobre superfícies escuras
  static const Color primaryAurora = Color(0xFFFFFFFF);
  static const Color accentAmber = Color(0xFFE4E4E7);
  static const Color accentTeal = Color(0xFFFFFFFF);
  static const Color accentDanger = Color(0xFFEF4444);
  static const Color accentSuccess = Color(0xFFFFFFFF);

  /// Alias legado mantido por compatibilidade.
  @Deprecated('Use primaryAurora')
  static const Color secondaryTeal = primaryAurora;

  // Hierarquia Tipográfica (contraste WCAG >= 4.5:1 sobre #000000)
  static const Color textPrimary = Color(0xFFFAFAFA);
  static const Color textSecondary = Color(0xFFA1A1AA);
  static const Color textMuted = Color(0xFF71717A);

  // Bordas de 1px e Divisores
  static const Color borderSubtle8 = Color(0xFF27272A);
  static const Color borderSubtle10 = Color(0x33FFFFFF);

  static const LinearGradient heroBackgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF121216),
      Color(0xFF000000),
    ],
  );

  /// Forma padrão dos diálogos do app (bordas arredondadas + hairline sutil).
  static const RoundedRectangleBorder dialogShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(16)),
    side: BorderSide(color: borderSubtle10),
  );

  /// Layout largo (landscape) para telas utilitárias responsivas como Ajustes.
  static bool isWideLayout(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
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
