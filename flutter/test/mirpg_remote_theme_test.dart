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

  test('MIRPG remote theme uses the fixed graphite and mint palette', () {
    final theme = MirpgRemoteTheme.build(ThemeData.light());

    expect(theme.useMaterial3, isTrue);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, MirpgRemoteTheme.background);
    expect(theme.colorScheme.surface, MirpgRemoteTheme.surface);
    expect(theme.colorScheme.primary, MirpgRemoteTheme.accent);
    expect(theme.cardTheme.color, MirpgRemoteTheme.raised);
    expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
    expect(theme.navigationBarTheme.backgroundColor, MirpgRemoteTheme.surface);
    expect(theme.navigationBarTheme.height, 72);
    expect(theme.navigationBarTheme.indicatorColor,
        MirpgRemoteTheme.accent.withOpacity(0.14));
    expect(theme.appBarTheme.centerTitle, isFalse);
    expect(theme.appBarTheme.toolbarHeight, 64);
    expect(theme.dividerColor, MirpgRemoteTheme.divider);
    expect(theme.inputDecorationTheme.filled, isTrue);
    expect(theme.inputDecorationTheme.fillColor, MirpgRemoteTheme.surface);
    expect(theme.bottomSheetTheme.backgroundColor, MirpgRemoteTheme.raised);
    expect(theme.textTheme.bodyLarge?.color, MirpgRemoteTheme.textPrimary);
    expect(theme.textTheme.bodyMedium?.color, MirpgRemoteTheme.textPrimary);
    expect(theme.textTheme.bodySmall?.color, MirpgRemoteTheme.textSecondary);
    expect(theme.textTheme.titleLarge?.fontSize, 24);
    expect(theme.textTheme.titleMedium?.fontSize, 18);
    expect(theme.textTheme.bodyMedium?.fontSize, 16);
    expect(theme.textTheme.bodySmall?.fontSize, 14);
    expect(theme.textTheme.labelSmall?.fontSize, 12);
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
