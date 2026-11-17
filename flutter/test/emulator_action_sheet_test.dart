import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
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
    VoidCallback? onLabel,
    AvdCardActions? avd,
  }) =>
      EmulatorActionSheet(
        title: 'Maple_1',
        subtitle: 'Maple_1 · Android Emulator · Android 15',
        state: stopped ? off : live,
        stopped: stopped,
        onOpen: onOpen,
        openBlocker: openBlocker,
        onLaunchGame: onLaunchGame,
        onStop: onStop,
        onLabel: onLabel ?? () {},
        avd: avd,
        tr: fakeTr,
      );

  ListTile tile(WidgetTester tester, String text) =>
      tester.widget<ListTile>(find.widgetWithText(ListTile, text));

  testWidgets('running avd sheet offers Stop and a blocked Delete',
      (tester) async {
    var stops = 0;
    var toggles = 0;
    await open(
        tester,
        () => sheet(
              onOpen: () {},
              avd: AvdCardActions(
                running: true,
                blocker: 'Stop it first',
                onStop: () => stops++,
                onToggleWindow: () => toggles++,
                onClone: () {},
                onRename: () {},
                onDelete: () {},
              ),
            ));
    expect(find.text('Show on PC'), findsOneWidget);
    expect(find.text('Hide on PC'), findsNothing);
    expect(find.text('Stop it first'), findsNWidgets(3));
    expect(tile(tester, 'Stop').enabled, isTrue);
    expect(tile(tester, 'Delete').enabled, isFalse);
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

  testWidgets('stopped avd sheet can clone, rename and delete', (tester) async {
    final calls = <String>[];
    await open(
        tester,
        () => sheet(
              stopped: true,
              onOpen: () {},
              avd: AvdCardActions(
                onClone: () => calls.add('clone'),
                onRename: () => calls.add('rename'),
                onDelete: () => calls.add('delete'),
              ),
            ));
    for (final item in ['Clone', 'Rename', 'Delete']) {
      if (find.byType(EmulatorActionSheet).evaluate().isEmpty) {
        await tester.tap(find.text('go'));
        await tester.pumpAndSettle();
      }
      expect(find.text('Start'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      expect(find.text('Show on PC'), findsNothing);
      expect(find.text('Hide on PC'), findsNothing);
      await tester.tap(find.text(item));
      await tester.pumpAndSettle();
    }
    expect(calls, ['clone', 'rename', 'delete']);
  });

  testWidgets('visible window avd sheet offers Hide on PC', (tester) async {
    await open(
        tester,
        () => sheet(
              onOpen: () {},
              avd: AvdCardActions(
                  running: true, windowVisible: true, onToggleWindow: () {}),
            ));
    expect(find.text('Hide on PC'), findsOneWidget);
    expect(find.text('Show on PC'), findsNothing);
  });

  testWidgets('copying avd sheet blocks management and keeps Label',
      (tester) async {
    await open(
        tester,
        () => sheet(
              stopped: true,
              onOpen: () {},
              avd: AvdCardActions(
                cloningLabel: 'Cloning 42%',
                onClone: () {},
                onRename: () {},
                onDelete: () {},
              ),
            ));
    expect(find.text('Copy in progress'), findsNWidgets(3));
    expect(tile(tester, 'Clone').enabled, isFalse);
    expect(tile(tester, 'Label').enabled, isTrue);
  });

  testWidgets('bluestacks sheet shows Open, Launch game, Stop and Label only',
      (tester) async {
    await open(tester,
        () => sheet(onOpen: () {}, onLaunchGame: () {}, onStop: () {}));
    for (final t in ['Open', 'Open and launch game', 'Stop', 'Label']) {
      expect(find.widgetWithText(ListTile, t), findsOneWidget, reason: t);
    }
    for (final t in ['Clone', 'Rename', 'Delete', 'Show on PC']) {
      expect(find.text(t), findsNothing, reason: t);
    }
  });

  testWidgets('Delete is the last row and red', (tester) async {
    await open(
        tester,
        () => sheet(
            onOpen: () {},
            avd: AvdCardActions(
                onClone: () {}, onRename: () {}, onDelete: () {})));
    final last = find.byType(ListTile).last;
    final text = tester.widget<Text>(
        find.descendant(of: last, matching: find.text('Delete')));
    expect(text.style?.color, MirpgStudioPalette.dark.error);
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
            avd: AvdCardActions(
                running: true,
                onStop: () => stops++,
                onClone: () {},
                onRename: () {},
                onDelete: () {})),
        scale: 1.75);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Stop'));
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(stops, 1);
  });
}
