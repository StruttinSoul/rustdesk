import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test("phone root gets Studio over RustDesk's theme", () {
    for (final entry in [
      (MyTheme.lightTheme, MirpgStudioPalette.light),
      (MyTheme.darkTheme, MirpgStudioPalette.dark),
    ]) {
      final theme = apertureAppTheme(entry.$1, mobile: true);
      expect(theme.useMaterial3, isTrue);
      expect(theme.scaffoldBackgroundColor, entry.$2.background);
      expect(theme.colorScheme.primary, entry.$2.accent);
      expect(theme.extension<ColorThemeExtension>(), isNotNull);
      expect(theme.extension<TabbarTheme>(), isNotNull);
    }
  });

  test("desktop keeps RustDesk's theme untouched", () {
    expect(
        identical(apertureAppTheme(MyTheme.lightTheme, mobile: false),
            MyTheme.lightTheme),
        isTrue);
    expect(
        identical(apertureAppTheme(MyTheme.darkTheme, mobile: false),
            MyTheme.darkTheme),
        isTrue);
  });

  testWidgets('changing appearance re-themes a page at once', (tester) async {
    MirpgStudioPalette? seen;
    Widget app(ThemeMode mode) => MaterialApp(
          theme: apertureAppTheme(MyTheme.lightTheme, mobile: true),
          darkTheme: apertureAppTheme(MyTheme.darkTheme, mobile: true),
          themeMode: mode,
          home: Builder(builder: (c) {
            seen = MirpgStudioPalette.of(c);
            return const SizedBox();
          }),
        );

    await tester.pumpWidget(app(ThemeMode.dark));
    expect(seen, MirpgStudioPalette.dark);
    await tester.pumpWidget(app(ThemeMode.light));
    await tester.pumpAndSettle();
    expect(seen, MirpgStudioPalette.light);
  });
}
