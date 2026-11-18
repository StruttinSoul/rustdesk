import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

void main() {
  const live = EmulatorUiState(EmulatorUiWord.live, 'Live');
  const off = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');

  Future<void> open(WidgetTester tester, EmulatorActionSheet Function() make,
      {double scale = 1.0}) async {
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
                  body: Center(
                      child: TextButton(
                onPressed: () => showEmulatorActionSheet(context, make()),
                child: const Text('go'),
              )))),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
  }

  EmulatorActionSheet sheet({
    bool stopped = false,
    VoidCallback? onOpen,
    String? openBlocker,
    VoidCallback? onLaunchGame,
    VoidCallback? onStop,
    VoidCallback? onReboot,
    VoidCallback? onLabel,
    bool windowVisible = false,
    VoidCallback? onToggleWindow,
    bool shuttingDown = false,
  }) =>
      EmulatorActionSheet(
        title: 'Pie64',
        subtitle: 'Pie64 · BlueStacks · Android 9',
        state: stopped ? off : live,
        stopped: stopped,
        onOpen: onOpen,
        openBlocker: openBlocker,
        onLaunchGame: onLaunchGame,
        onStop: onStop,
        onReboot: onReboot,
        windowVisible: windowVisible,
        onToggleWindow: onToggleWindow,
        onLabel: onLabel ?? () {},
        shuttingDown: shuttingDown,
        tr: fakeTr,
      );

  ListTile tile(WidgetTester tester, String text) =>
      tester.widget<ListTile>(find.widgetWithText(ListTile, text));

  testWidgets('a running emulator whose window the PC can show offers it',
      (tester) async {
    var stops = 0;
    var toggles = 0;
    await open(
        tester,
        () => sheet(
              onOpen: () {},
              onStop: () => stops++,
              onToggleWindow: () => toggles++,
            ));
    expect(find.text('Show on PC'), findsOneWidget);
    expect(find.text('Hide on PC'), findsNothing);
    await tester.tap(find.text('Show on PC'));
    await tester.pumpAndSettle();
    expect(find.byType(EmulatorActionSheet), findsNothing);
    expect(toggles, 1);
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });

  testWidgets('a visible window offers Hide on PC; a stopped emulator neither',
      (tester) async {
    await open(tester,
        () => sheet(onOpen: () {}, windowVisible: true, onToggleWindow: () {}));
    expect(find.text('Hide on PC'), findsOneWidget);
    expect(find.text('Show on PC'), findsNothing);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await open(tester,
        () => sheet(stopped: true, onOpen: () {}, onToggleWindow: () {}));
    expect(find.text('Show on PC'), findsNothing);
    expect(find.text('Hide on PC'), findsNothing);
  });

  testWidgets('bluestacks sheet shows Open, Launch game, Stop and Label only',
      (tester) async {
    await open(tester,
        () => sheet(onOpen: () {}, onLaunchGame: () {}, onStop: () {}));
    for (final t in ['Open', 'Open and launch game', 'Stop', 'Label']) {
      expect(find.widgetWithText(ListTile, t), findsOneWidget, reason: t);
    }
    for (final t in ['Clone', 'Rename', 'Delete', 'Settings', 'Show on PC']) {
      expect(find.text(t), findsNothing, reason: t);
    }
  });

  testWidgets('view-only sheet disables Open with the reason but keeps Label',
      (tester) async {
    var labels = 0;
    await open(
        tester,
        () => sheet(
            openBlocker: "atlas hasn't granted control",
            onLabel: () => labels++));
    expect(tile(tester, 'Open').enabled, isFalse);
    expect(find.text("atlas hasn't granted control"), findsOneWidget);
    await tester.tap(find.text('Label'));
    await tester.pumpAndSettle();
    expect(labels, 1);
  });

  testWidgets('sheet is usable at 1.75 text scale', (tester) async {
    var stops = 0;
    await open(
        tester,
        () => sheet(
            onOpen: () {},
            onStop: () => stops++,
            onReboot: () {},
            onToggleWindow: () {}),
        scale: 1.75);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Stop'));
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });

  testWidgets('shutting down disables every row except Label', (tester) async {
    var labels = 0;
    var calls = 0;
    await open(
        tester,
        () => sheet(
              shuttingDown: true,
              onOpen: () => calls++,
              onLaunchGame: () => calls++,
              onLabel: () => labels++,
              onToggleWindow: () => calls++,
              onStop: () => calls++,
              onReboot: () => calls++,
            ));
    for (final row in [
      'Open',
      'Open and launch game',
      'Show on PC',
      'Stop',
      'Reboot',
    ]) {
      expect(tile(tester, row).enabled, isFalse, reason: row);
    }
    expect(tile(tester, 'Label').enabled, isTrue);
    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(calls, 0);
    await tester.tap(find.text('Label'));
    await tester.pumpAndSettle();
    expect(labels, 1);
  });
}
