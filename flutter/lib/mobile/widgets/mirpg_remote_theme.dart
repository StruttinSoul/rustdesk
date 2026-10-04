import 'package:flutter/material.dart';

abstract final class MirpgRemoteTheme {
  static const background = Color(0xFF101416);
  static const surface = Color(0xFF191F22);
  static const raised = Color(0xFF242C30);
  static const textPrimary = Color(0xFFF1F4F5);
  static const textSecondary = Color(0xFFAEBAC0);
  static const accent = Color(0xFF70D8C1);

  static ThemeData build(ThemeData base) {
    final textTheme = base.textTheme
        .apply(bodyColor: textPrimary, displayColor: textPrimary)
        .copyWith(bodySmall: base.textTheme.bodySmall?.copyWith(color: textSecondary));

    return base.copyWith(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      cardColor: raised,
      canvasColor: background,
      colorScheme: const ColorScheme.dark(
        primary: accent,
        secondary: accent,
        surface: surface,
        onPrimary: background,
        onSecondary: background,
        onSurface: textPrimary,
        error: Color(0xFFFFB4AB),
        onError: Color(0xFF690005),
      ),
      cardTheme: const CardTheme(
        color: raised,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(14)),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surface,
        indicatorColor: accent.withOpacity(0.18),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      textTheme: textTheme,
      dividerColor: const Color(0xFF344046),
    );
  }
}
