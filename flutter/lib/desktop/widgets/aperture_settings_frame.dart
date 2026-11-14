import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/aperture_brand.dart';

/// A presentation layer for the existing Windows settings pages and controls.
class ApertureSettingsFrame extends StatelessWidget {
  const ApertureSettingsFrame({
    super.key,
    required this.title,
    required this.navigation,
    required this.content,
  });

  final String title;
  final Widget navigation;
  final Widget content;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context);
    final dark = base.brightness == Brightness.dark;
    final background = dark ? const Color(0xFF101923) : const Color(0xFFF5F7FA);
    final surface = dark ? const Color(0xFF1C2938) : Colors.white;
    final raised = dark ? const Color(0xFF26374A) : const Color(0xFFF5F7FA);
    final foreground = dark ? const Color(0xFFF0F5FC) : const Color(0xFF192431);
    final secondary = dark ? const Color(0xFFBBC8D8) : const Color(0xFF5E6D7F);
    final accent = dark ? const Color(0xFFA4BCFF) : const Color(0xFF2855CC);
    final outline = dark ? const Color(0xFF36475B) : const Color(0xFFDCE3EA);
    // Filled controls use cobalt with white text in both themes; the light
    // periwinkle dark-mode accent is too pale behind white labels.
    final cobalt = dark ? const Color(0xFF3361D8) : const Color(0xFF2855CC);
    WidgetStateProperty<Color?> selectedFill() =>
        WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.disabled)) {
            return states.contains(WidgetState.selected)
                ? secondary.withOpacity(0.5)
                : null;
          }
          return states.contains(WidgetState.selected) ? cobalt : null;
        });
    final theme = base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        background: background,
        surface: surface,
        surfaceContainerHighest: raised,
        onSurface: foreground,
      ),
      textTheme:
          base.textTheme.apply(bodyColor: foreground, displayColor: foreground),
      iconTheme: base.iconTheme.copyWith(color: secondary),
      dividerColor: outline,
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: cobalt,
          foregroundColor: Colors.white,
          disabledBackgroundColor: raised,
          disabledForegroundColor: secondary,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      checkboxTheme: base.checkboxTheme.copyWith(
        fillColor: selectedFill(),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: BorderSide(color: secondary, width: 1.5),
      ),
      radioTheme: base.radioTheme.copyWith(
        fillColor: WidgetStateProperty.resolveWith((states) =>
            states.contains(WidgetState.selected)
                ? (states.contains(WidgetState.disabled)
                    ? secondary.withOpacity(0.5)
                    : cobalt)
                : secondary),
      ),
      cardTheme: base.cardTheme.copyWith(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      inputDecorationTheme: base.inputDecorationTheme.copyWith(
        filled: true,
        fillColor: raised,
        enabledBorder: OutlineInputBorder(
          borderSide: BorderSide(color: outline),
          borderRadius: BorderRadius.circular(8),
        ),
        focusedBorder: OutlineInputBorder(
          borderSide: BorderSide(color: accent),
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
    return Theme(
      data: theme,
      child: Container(
        width: double.infinity,
        height: double.infinity,
        color: background,
        child: LayoutBuilder(builder: (context, constraints) {
          return Row(children: [
            SizedBox(
              width: constraints.maxWidth < 760 ? 168 : 192,
              child: ColoredBox(
                color: surface,
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
                        child: Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const ApertureBrandMark(size: 28),
                            Text(ApertureBrand.name,
                                style: TextStyle(
                                    color: foreground,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Text(title,
                            style: TextStyle(
                                color: foreground,
                                fontSize: 20,
                                fontWeight: FontWeight.w600)),
                      ),
                      Expanded(
                          child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: navigation,
                      )),
                    ]),
              ),
            ),
            VerticalDivider(width: 1, color: outline),
            Expanded(
                child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: content,
            )),
          ]);
        }),
      ),
    );
  }
}

class ApertureSettingsItem extends StatelessWidget {
  const ApertureSettingsItem({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground =
        selected ? theme.colorScheme.primary : theme.colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: selected
              ? theme.colorScheme.primary.withOpacity(0.12)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(children: [
                  Icon(icon, size: 20, color: foreground),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(label,
                          style: TextStyle(
                              color: foreground,
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w400))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
