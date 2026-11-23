import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settings_ui/settings_ui.dart';

import 'support/visual_capture.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// Pumps [child] under the phone root theme at 360x640, in [brightness] and
/// at [textScale], inside a RepaintBoundary.
Future<void> _pump(WidgetTester tester, Widget child,
    {required Brightness brightness, required double textScale}) async {
  tester.view.physicalSize = const Size(360, 640);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: apertureAppTheme(MyTheme.lightTheme, mobile: true),
    darkTheme: apertureAppTheme(MyTheme.darkTheme, mobile: true),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    // The boundary sits above the Navigator so dialogs, sheets and menus
    // (which live in its overlay) are part of the captured image.
    builder: (context, app) => RepaintBoundary(
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: app!,
      ),
    ),
    home: child,
  ));
  await tester.pumpAndSettle();
}

/// The nearest Material around [inner], i.e. the surface it is drawn on.
Material _surfaceOf(WidgetTester tester, Finder inner) => tester.widget<Material>(
    find.ancestor(of: inner, matching: find.byType(Material)).first);

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.3]) {
      final label = '${brightness.name}${scale == 1.0 ? '' : '-x1.3'}';
      final palette = brightness == Brightness.dark
          ? MirpgStudioPalette.dark
          : MirpgStudioPalette.light;

      testWidgets(
          'inherited dialog uses the Studio surface and readable text ($label)',
          (tester) async {
        await _pump(
          tester,
          Scaffold(
            body: Center(
              child: CustomAlertDialog(
                title: const Text('Password Required'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  const TextField(
                    obscureText: true,
                    decoration: InputDecoration(labelText: 'Password'),
                  ),
                  CheckboxListTile(
                    value: true,
                    onChanged: (_) {},
                    title: const Text('Remember password'),
                  ),
                ]),
                actions: [
                  TextButton(onPressed: () {}, child: const Text('Cancel')),
                  TextButton(onPressed: () {}, child: const Text('OK')),
                ],
              ),
            ),
          ),
          brightness: brightness,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);

        final dialog = find.byType(AlertDialog);
        final surface = tester.widget<Material>(
            find.descendant(of: dialog, matching: find.byType(Material)).first);
        expect(surface.color, palette.raised);

        final titleColor =
            DefaultTextStyle.of(tester.element(find.text('Password Required')))
                .style
                .color!;
        expect(contrast(titleColor, palette.raised), greaterThanOrEqualTo(4.5));
        final button = Theme.of(tester.element(dialog))
            .textButtonTheme
            .style!
            .foregroundColor!
            .resolve({})!;
        expect(contrast(button, palette.raised), greaterThanOrEqualTo(3.0));

        await tester.enterText(find.byType(TextField), 'secret');
        await tester.pump();
        expect(
            tester.widget<EditableText>(find.byType(EditableText)).obscureText,
            isTrue);

        await captureSurface(
            tester, find.byType(RepaintBoundary).first, 'dialog-$label');
      });

      testWidgets('inherited settings list stays usable ($label)',
          (tester) async {
        final toggled = <bool>[];
        var taps = 0;
        await _pump(
          tester,
          Scaffold(
            body: SettingsList(sections: [
              SettingsSection(title: const Text('Network'), tiles: [
                SettingsTile.switchTile(
                  initialValue: true,
                  onToggle: (v) => toggled.add(v),
                  title: const Text('Use WebSocket'),
                ),
                SettingsTile(
                  title: const Text('Language'),
                  onPressed: (_) => taps++,
                ),
              ]),
            ]),
          ),
          brightness: brightness,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);

        await tester.tap(find.byType(Switch));
        await tester.pump();
        expect(toggled, [false]);
        await tester.tap(find.text('Language'));
        await tester.pump();
        expect(taps, 1);

        await captureSurface(
            tester, find.byType(RepaintBoundary).first, 'settings-$label');
      });

      testWidgets('snack bars, sheets and menus use Studio shapes ($label)',
          (tester) async {
        await _pump(
          tester,
          Scaffold(
            appBar: AppBar(actions: [
              PopupMenuButton<int>(
                itemBuilder: (_) =>
                    [const PopupMenuItem(value: 1, child: Text('Menu item'))],
              ),
            ]),
            body: Builder(
              builder: (context) => Column(children: [
                TextButton(
                  onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Saved'))),
                  child: const Text('snack'),
                ),
                TextButton(
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => const SizedBox(
                        height: 120, child: Center(child: Text('Sheet body'))),
                  ),
                  child: const Text('sheet'),
                ),
              ]),
            ),
          ),
          brightness: brightness,
          textScale: scale,
        );

        await tester.tap(find.text('snack'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(_surfaceOf(tester, find.text('Saved')).color, palette.raised);
        await captureSurface(
            tester, find.byType(RepaintBoundary).first, 'snackbar-$label');
        ScaffoldMessenger.of(tester.element(find.byType(Scaffold)))
            .hideCurrentSnackBar();
        await tester.pumpAndSettle();

        await tester.tap(find.text('sheet'));
        await tester.pumpAndSettle();
        expect(
            _surfaceOf(tester, find.text('Sheet body')).color, palette.raised);
        await captureSurface(
            tester, find.byType(RepaintBoundary).first, 'sheet-$label');
        Navigator.of(tester.element(find.text('Sheet body'))).pop();
        await tester.pumpAndSettle();

        await tester.tap(find.byType(PopupMenuButton<int>));
        await tester.pumpAndSettle();
        expect(_surfaceOf(tester, find.text('Menu item')).color, palette.raised);
        expect(tester.takeException(), isNull);
        await captureSurface(
            tester, find.byType(RepaintBoundary).first, 'popup-$label');
      });
    }
  }
}
