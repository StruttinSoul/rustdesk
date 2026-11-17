import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_tile.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'support/fake_translate.dart';

const _live = EmulatorUiState(EmulatorUiWord.live, 'Live');
const _off = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');
const _stopping = EmulatorUiState(EmulatorUiWord.stopping, 'Stopping');

/// Shows [data] as the Play tab does: the more button opens the action
/// sheet, and an emulator that is stopping cannot be opened.
Widget _entry(
  EmulatorTileData data, {
  required bool compact,
  VoidCallback? onOpen,
  VoidCallback? onStop,
}) =>
    Builder(
      builder: (context) {
        final stopped = data.state.word == EmulatorUiWord.stopped;
        final stopping = data.state.word == EmulatorUiWord.stopping;
        final open = data.state.canOpen ? onOpen : null;
        void more() => showEmulatorActionSheet(
              context,
              EmulatorActionSheet(
                title: data.title,
                subtitle: data.title,
                state: data.state,
                stopped: stopped,
                onOpen: open,
                onStop: onStop,
                onLabel: () {},
                shuttingDown: stopping,
                tr: fakeTr,
              ),
            );
        return SizedBox(
          width: compact ? 172 : 360,
          height: compact ? 218 : 120,
          child: compact
              ? EmulatorTile(data: data, onOpen: open, onMore: more, tr: fakeTr)
              : EmulatorRow(data: data, onOpen: open, onMore: more, tr: fakeTr),
        );
      },
    );

Widget _app(Widget body, {double scale = 1}) => MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!),
      home: Scaffold(body: Center(child: body)),
    );

void main() {
  for (final compact in [false, true]) {
    testWidgets(
        'running Android ${compact ? 'compact tile' : 'row'} shuts down only from its menu',
        (tester) async {
      var shutdowns = 0;
      var opens = 0;
      await tester.pumpWidget(_app(_entry(
        const EmulatorTileData(id: 'p1', title: 'Player 1', state: _live),
        compact: compact,
        onOpen: () => opens++,
        onStop: () => shutdowns++,
      )));
      expect(shutdowns, 0);
      await tester.tap(find.byTooltip('More Player 1 actions'));
      await tester.pumpAndSettle();
      expect(shutdowns, 0);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      expect(shutdowns, 1);
      expect(opens, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('stopped targets do not offer shutdown', (tester) async {
    await tester.pumpWidget(_app(_entry(
      const EmulatorTileData(id: 'bs', title: 'Target', state: _off),
      compact: true,
      onOpen: () {},
      onStop: () => fail('Shutdown must not be available'),
    )));
    await tester.tap(find.byTooltip('More Target actions'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Start'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Stop'), findsNothing);

    // A PC monitor has no emulator actions at all.
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
                width: 172,
                height: 218,
                child: TargetPreviewCard(
                    name: 'Target', live: false, tr: fakeTr)))));
    expect(find.byTooltip('More Target actions'), findsNothing);
  });

  for (final compact in [false, true]) {
    testWidgets(
        'shutdown pending blocks reopening and repeated shutdown (${compact ? 'tile' : 'row'})',
        (tester) async {
      var actions = 0;
      await tester.pumpWidget(_app(_entry(
        const EmulatorTileData(id: 'p1', title: 'Player 1', state: _stopping),
        compact: compact,
        onOpen: () => actions++,
        onStop: () => actions++,
      )));
      expect(find.text('Stopping'), findsWidgets);
      await tester.tap(find.byType(compact ? EmulatorTile : EmulatorRow));
      expect(actions, 0);
      // The sheet still opens (for the label), but Open and Stop are off.
      await tester.tap(find.byTooltip('More Player 1 actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'Open'));
      await tester.pumpAndSettle();
      expect(actions, 0);
      expect(tester.takeException(), isNull);
    });
  }

  for (final confirmed in [false, true]) {
    testWidgets('shutdown confirmation ${confirmed ? 'accepts' : 'cancels'} the named instance', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () async { result = await showEmulatorShutdownConfirmation(context, 'Player 1', tr: fakeTr); },
        child: const Text('Ask'))))));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('Stop Player 1?'), findsOneWidget);
      expect(find.text('Apps running in it will close.'), findsOneWidget);
      await tester.tap(find.text(confirmed ? 'Stop' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, confirmed);
    });
  }

  testWidgets('the action sheet remains usable with large text',
      (tester) async {
    var calls = 0;
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(
        _entry(
          const EmulatorTileData(
              id: 'p1', title: 'Player 1 with a long name', state: _live),
          compact: true,
          onOpen: () {},
          onStop: () => calls++,
        ),
        scale: 1.75));
    await tester.tap(find.byTooltip('More Player 1 with a long name actions'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Stop'));
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });
}
