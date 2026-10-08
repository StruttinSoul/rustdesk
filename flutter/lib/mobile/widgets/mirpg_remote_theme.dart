import 'package:flutter/material.dart';

/// Visual authority for the MIRPG Remote Android client.
///
/// Keep these values aligned with the supplied MIRPG Remote visual kit. The
/// mobile client should prefer theme values and the shared widgets below over
/// page-local colors and radii.
abstract final class MirpgRemoteTheme {
  static const background = Color(0xFF101416);
  static const surface = Color(0xFF191F22);
  static const raised = Color(0xFF242C30);
  static const textPrimary = Color(0xFFF1F4F5);
  static const textSecondary = Color(0xFFAEBAC0);
  static const accent = Color(0xFF70D8C1);
  static const outline = Color(0xFF3E494E);
  static const divider = Color(0xFF303A3E);
  static const error = Color(0xFFFFB4AB);
  static const warning = Color(0xFFEAC98B);

  static const double pageMargin = 16;
  static const double rhythm = 8;
  static const double controlRadius = 12;
  static const double surfaceRadius = 16;
  static const double sheetRadius = 24;
  static const double minTouchTarget = 48;

  static ThemeData build(ThemeData base) {
    final scheme = const ColorScheme.dark(
      primary: accent,
      secondary: accent,
      tertiary: warning,
      surface: surface,
      surfaceDim: background,
      surfaceBright: raised,
      surfaceContainerLowest: background,
      surfaceContainerLow: surface,
      surfaceContainer: surface,
      surfaceContainerHigh: raised,
      surfaceContainerHighest: raised,
      onPrimary: background,
      onSecondary: background,
      onSurface: textPrimary,
      onSurfaceVariant: textSecondary,
      error: error,
      onError: Color(0xFF690005),
      outline: outline,
      outlineVariant: divider,
    );
    final sourceText = base.textTheme;
    final textTheme = sourceText.copyWith(
      displayLarge: sourceText.displayLarge?.copyWith(color: textPrimary),
      displayMedium: sourceText.displayMedium?.copyWith(color: textPrimary),
      displaySmall: sourceText.displaySmall?.copyWith(color: textPrimary),
      headlineLarge: sourceText.headlineLarge?.copyWith(
        color: textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      headlineMedium: sourceText.headlineMedium?.copyWith(
        color: textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w600,
      ),
      headlineSmall: sourceText.headlineSmall?.copyWith(
        color: textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      titleLarge: sourceText.titleLarge?.copyWith(
        color: textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.2,
      ),
      titleMedium: sourceText.titleMedium?.copyWith(
        color: textPrimary,
        fontSize: 18,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: sourceText.titleSmall?.copyWith(
        color: textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: sourceText.bodyLarge?.copyWith(
        color: textPrimary,
        fontSize: 16,
      ),
      bodyMedium: sourceText.bodyMedium?.copyWith(
        color: textPrimary,
        fontSize: 16,
      ),
      bodySmall: sourceText.bodySmall?.copyWith(
        color: textSecondary,
        fontSize: 14,
      ),
      labelLarge: sourceText.labelLarge?.copyWith(
        color: textPrimary,
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      labelMedium: sourceText.labelMedium?.copyWith(
        color: textSecondary,
        fontSize: 14,
      ),
      labelSmall: sourceText.labelSmall?.copyWith(
        color: textSecondary,
        fontSize: 12,
      ),
    );

    final controlShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(controlRadius),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      // Preserve RustDesk's custom theme extensions (notably TabbarTheme and
      // ColorThemeExtension). PeerTabPage and other shared widgets read these
      // through MyTheme and expect them to remain available under this nested
      // mobile theme.
      extensions: base.extensions.values,
      platform: base.platform,
      visualDensity: base.visualDensity,
      materialTapTargetSize: base.materialTapTargetSize,
      pageTransitionsTheme: base.pageTransitionsTheme,
      splashFactory: base.splashFactory,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      cardColor: raised,
      canvasColor: background,
      splashColor: accent.withOpacity(0.08),
      highlightColor: accent.withOpacity(0.05),
      focusColor: accent.withOpacity(0.10),
      hoverColor: accent.withOpacity(0.06),
      disabledColor: textSecondary.withOpacity(0.38),
      dividerColor: divider,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        foregroundColor: textPrimary,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: 64,
        titleSpacing: pageMargin,
        iconTheme: const IconThemeData(color: textPrimary, size: 24),
        actionsIconTheme: const IconThemeData(color: textPrimary, size: 24),
        titleTextStyle: textTheme.titleLarge,
      ),
      cardTheme: CardTheme(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(surfaceRadius),
          side: const BorderSide(color: outline),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        height: 72,
        backgroundColor: surface,
        indicatorColor: accent.withOpacity(0.14),
        elevation: 0,
        surfaceTintColor: Colors.transparent,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) => IconThemeData(
              color: states.contains(WidgetState.selected)
                  ? accent
                  : textSecondary,
              size: 24,
            )),
        labelTextStyle: WidgetStateProperty.resolveWith((states) => TextStyle(
              color: states.contains(WidgetState.selected)
                  ? textPrimary
                  : textSecondary,
              fontSize: 14,
              fontWeight: states.contains(WidgetState.selected)
                  ? FontWeight.w600
                  : FontWeight.w500,
            )),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          foregroundColor: textPrimary,
          side: const BorderSide(color: outline),
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(0, minTouchTarget),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          foregroundColor: textPrimary,
          backgroundColor: raised,
          elevation: 0,
          side: const BorderSide(color: outline),
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(minTouchTarget, minTouchTarget),
          foregroundColor: accent,
          shape: controlShape,
          textStyle: textTheme.labelLarge,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(minTouchTarget, minTouchTarget),
          foregroundColor: textPrimary,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(controlRadius),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: textTheme.bodyMedium?.copyWith(color: textSecondary),
        labelStyle: textTheme.bodyMedium?.copyWith(color: textSecondary),
        floatingLabelStyle: textTheme.bodySmall?.copyWith(color: accent),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: outline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: accent, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          borderSide: const BorderSide(color: error, width: 1.5),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: surface,
        selectedColor: accent.withOpacity(0.14),
        disabledColor: surface,
        side: const BorderSide(color: outline),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
        ),
        labelStyle: textTheme.labelMedium,
        secondaryLabelStyle: textTheme.labelMedium?.copyWith(color: accent),
        padding: const EdgeInsets.symmetric(horizontal: 8),
      ),
      listTileTheme: const ListTileThemeData(
        textColor: textPrimary,
        iconColor: textSecondary,
        selectedColor: accent,
        selectedTileColor: Color(0x1870D8C1),
        minVerticalPadding: 10,
        contentPadding: EdgeInsets.symmetric(horizontal: pageMargin),
      ),
      dividerTheme: const DividerThemeData(
        color: divider,
        thickness: 1,
        space: 1,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: raised,
        modalBackgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: outline,
        shape: RoundedRectangleBorder(
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(sheetRadius)),
        ),
      ),
      dialogTheme: DialogTheme(
        backgroundColor: raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(surfaceRadius),
          side: const BorderSide(color: outline),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: raised,
        surfaceTintColor: Colors.transparent,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          side: const BorderSide(color: outline),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: raised,
        contentTextStyle: textTheme.bodyMedium,
        actionTextColor: accent,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(controlRadius),
          side: const BorderSide(color: outline),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(color: accent),
    );
  }
}

class MirpgSurface extends StatelessWidget {
  const MirpgSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.color = MirpgRemoteTheme.surface,
    this.borderColor = MirpgRemoteTheme.divider,
    this.radius = MirpgRemoteTheme.surfaceRadius,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color color;
  final Color borderColor;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: borderColor),
        ),
        child: Padding(padding: padding, child: child),
      );
}

class MirpgSectionHeader extends StatelessWidget {
  const MirpgSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
                ],
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
        ],
      );
}

class MirpgStatusChip extends StatelessWidget {
  const MirpgStatusChip({
    super.key,
    required this.label,
    this.icon,
    this.tone = MirpgStatusTone.neutral,
  });

  final String label;
  final IconData? icon;
  final MirpgStatusTone tone;

  Color _foreground() => switch (tone) {
        MirpgStatusTone.good => MirpgRemoteTheme.accent,
        MirpgStatusTone.warning => MirpgRemoteTheme.warning,
        MirpgStatusTone.error => MirpgRemoteTheme.error,
        MirpgStatusTone.neutral => MirpgRemoteTheme.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final foreground = _foreground();
    return Container(
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: foreground.withOpacity(0.08),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withOpacity(0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: foreground),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

enum MirpgStatusTone { neutral, good, warning, error }
