import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';

void main() {
  test('MIRPG remote theme preserves host theme extensions', () {
    const marker = _MarkerTheme('kept');
    final base = ThemeData.light().copyWith(
      extensions: const <ThemeExtension<dynamic>>[marker],
    );

    final theme = MirpgRemoteTheme.build(base);

    expect(theme.extension<_MarkerTheme>(), same(marker));
  });

  test('Studio V4 honors both appearance modes and their semantic colors', () {
    for (final brightness in Brightness.values) {
      final palette = brightness == Brightness.dark
          ? MirpgStudioPalette.dark
          : MirpgStudioPalette.light;
      final base = brightness == Brightness.dark
          ? ThemeData.dark()
          : ThemeData.light();
      final theme = MirpgRemoteTheme.build(base);

      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, brightness);
      expect(theme.scaffoldBackgroundColor, palette.background);
      expect(theme.colorScheme.surface, palette.surface);
      expect(theme.colorScheme.primary, palette.accent);
      expect(theme.colorScheme.onSurface, palette.textPrimary);
      expect(theme.cardTheme.color, palette.raised);
      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
      expect(theme.navigationBarTheme.backgroundColor, palette.surface);
      expect(theme.navigationBarTheme.height, 64);
      expect(theme.navigationBarTheme.indicatorColor,
          palette.accent.withOpacity(0.14));
      expect(theme.appBarTheme.centerTitle, isFalse);
      expect(theme.appBarTheme.toolbarHeight, 56);
      expect(theme.dividerColor, palette.divider);
      expect(theme.inputDecorationTheme.filled, isTrue);
      expect(theme.inputDecorationTheme.fillColor, palette.surface);
      expect(theme.bottomSheetTheme.backgroundColor, palette.raised);
      expect(theme.textTheme.bodyLarge?.color, palette.textPrimary);
      expect(theme.textTheme.bodyMedium?.color, palette.textPrimary);
      expect(theme.textTheme.bodySmall?.color, palette.textSecondary);
      expect(theme.textTheme.titleLarge?.fontSize, 20);
      expect(theme.textTheme.titleMedium?.fontSize, 16);
      expect(theme.textTheme.bodyMedium?.fontSize, 14);
      expect(theme.textTheme.bodySmall?.fontSize, 12);
      expect(theme.textTheme.titleSmall?.fontSize, 14);
      expect(theme.textTheme.labelMedium?.fontSize, 12);
      expect(theme.textTheme.bodyLarge?.fontSize, 15);
      expect(theme.floatingActionButtonTheme.extendedSizeConstraints?.minHeight,
          40);
      expect(theme.textTheme.labelSmall?.fontSize, 12);
    }
  });

  testWidgets('Studio surfaces resolve colors from the inherited theme',
      (tester) async {
    for (final brightness in Brightness.values) {
      final base = brightness == Brightness.dark
          ? ThemeData.dark()
          : ThemeData.light();
      final palette = brightness == Brightness.dark
          ? MirpgStudioPalette.dark
          : MirpgStudioPalette.light;
      await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(base),
        home: const Scaffold(body: MirpgSurface(child: Text('Studio'))),
      ));
      await tester.pumpAndSettle();
      final surface = tester.widget<DecoratedBox>(find.descendant(
        of: find.byType(MirpgSurface),
        matching: find.byType(DecoratedBox),
      ).first);
      final decoration = surface.decoration as BoxDecoration;
      expect(decoration.color, palette.surface);
      expect(MirpgStudioPalette.of(tester.element(find.text('Studio'))), palette);
    }
  });

  testWidgets('MIRPG controls keep a 48dp minimum touch target',
      (tester) async {
    final theme = MirpgRemoteTheme.build(ThemeData.light());

    await tester.pumpWidget(MaterialApp(
      theme: theme,
      home: const Scaffold(
        body: Column(
          children: [
            FilledButton(onPressed: null, child: Text('Primary')),
            OutlinedButton(onPressed: null, child: Text('Secondary')),
            IconButton(onPressed: null, icon: Icon(Icons.more_horiz)),
          ],
        ),
      ),
    ));

    expect(tester.getSize(find.byType(FilledButton)).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byType(OutlinedButton)).height,
        greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byType(IconButton)).height,
        greaterThanOrEqualTo(48));
  });

  testWidgets('status chips truncate long emulator labels in narrow overlays',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: MirpgRemoteTheme.build(ThemeData.light()),
      home: Scaffold(
        body: Center(
          child: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: const SizedBox(
              width: 190,
              child: MirpgStatusChip(
                label: 'BlueStacks App Player 3 · Waiting for live frame',
                icon: Icons.hourglass_top_rounded,
              ),
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(MirpgStatusChip)).width,
        lessThanOrEqualTo(190));
  });
}

@immutable
class _MarkerTheme extends ThemeExtension<_MarkerTheme> {
  const _MarkerTheme(this.value);

  final String value;

  @override
  _MarkerTheme copyWith({String? value}) => _MarkerTheme(value ?? this.value);

  @override
  _MarkerTheme lerp(covariant _MarkerTheme? other, double t) =>
      other == null || t < 0.5 ? this : other;
}
