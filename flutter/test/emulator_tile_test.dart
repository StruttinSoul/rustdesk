import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_tile.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

const live = EmulatorUiState(EmulatorUiWord.live, 'Live');
const stopped = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');
const stopping = EmulatorUiState(EmulatorUiWord.stopping, 'Stopping');
const problem =
    EmulatorUiState(EmulatorUiWord.problem, 'Problem', causeKey: 'Stream stopped');

Future<void> pumpIn(WidgetTester tester, Widget child,
    {Size size = const Size(360, 800), ThemeData? theme}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: theme ?? MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(body: Center(child: child)),
  ));
}

Widget tile(EmulatorTileData d,
        {VoidCallback? onOpen,
        VoidCallback? onMore,
        double w = 158,
        double h = 290}) =>
    SizedBox(
        width: w,
        height: h,
        child: EmulatorTile(data: d, onOpen: onOpen, onMore: onMore, tr: fakeTr));

void main() {
  test('every word has one fixed tone', () {
    expect({for (final w in EmulatorUiWord.values) w: emulatorStateTone(w)}, {
      EmulatorUiWord.live: MirpgStatusTone.good,
      EmulatorUiWord.starting: MirpgStatusTone.warning,
      EmulatorUiWord.stopped: MirpgStatusTone.neutral,
      EmulatorUiWord.stopping: MirpgStatusTone.neutral,
      EmulatorUiWord.copying: MirpgStatusTone.neutral,
      EmulatorUiWord.problem: MirpgStatusTone.error
    });
  });

  testWidgets('stopped tile starts only from an explicit tap', (tester) async {
    var opens = 0;
    await pumpIn(
        tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: stopped),
            onOpen: () => opens++));
    expect(opens, 0);
    await tester.tap(find.text('Start'));
    expect(opens, 1);
    expect(find.text('Live'), findsNothing);
  });

  testWidgets('Start is a compact button that keeps a 48 dp hit area',
      (tester) async {
    await pumpIn(tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: stopped)));
    final button = find.byWidgetPredicate((w) => w is FilledButton);
    final visual =
        find.descendant(of: button, matching: find.byType(InkWell)).first;
    expect(tester.getSize(visual).height, 36);
    expect(tester.getSize(button).height, 48);
    // The padded hit area: a tap 6 dp above the visual top still starts it.
    var opens = 0;
    await pumpIn(
        tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: stopped),
            onOpen: () => opens++));
    final rect = tester.getRect(find
        .descendant(of: button, matching: find.byType(InkWell))
        .first);
    await tester.tapAt(Offset(rect.center.dx, rect.top - 5));
    expect(opens, 1);
    expect(
        DefaultTextStyle.of(tester.element(find.text('Start'))).style.fontSize,
        14);
    final icon = tester.widget<Icon>(
        find.descendant(of: button, matching: find.byType(Icon)));
    expect(icon.size, 18);
  });

  testWidgets('tile name is titleSmall and the state chip is compact',
      (tester) async {
    await pumpIn(
        tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: stopped),
            onMore: () {}));
    expect(tester.widget<Text>(find.text('Main')).style?.fontSize, 14);
    expect(tester.widget<Text>(find.text('Stopped')).style?.fontSize, 12);
    expect(tester.getSize(find.byType(MirpgStatusChip)).height,
        lessThanOrEqualTo(28));
    final more = find.widgetWithIcon(IconButton, Icons.more_vert);
    expect(tester.getSize(more).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(more).width, greaterThanOrEqualTo(48));
    final icon = tester.widget<Icon>(
        find.descendant(of: more, matching: find.byType(Icon)));
    expect(icon.size, 20);
  });

  testWidgets('stopped tile shows why its copy failed', (tester) async {
    const failure = 'Copy to Phone_3 failed: not enough space';
    await pumpIn(
        tester,
        tile(const EmulatorTileData(
            id: 'a',
            title: 'Main',
            state: EmulatorUiState(EmulatorUiWord.stopped, 'Stopped',
                pcMessage: failure))));
    expect(tester.takeException(), isNull);
    expect(find.text(failure), findsOneWidget);
    await pumpIn(tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: stopped)));
    expect(find.text(failure), findsNothing);
  });

  testWidgets('tile shows a two-line name without truncation at phone grid width',
      (tester) async {
    const title = 'BlueStacks App Player 3';
    await pumpIn(tester,
        tile(const EmulatorTileData(id: 'a', title: title, state: live)));
    final text = tester.widget<Text>(find.text(title));
    expect(text.data, title);
    expect(text.maxLines, 2);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('labelled tile shows the label and the emulator name',
      (tester) async {
    await pumpIn(
        tester,
        tile(const EmulatorTileData(
            id: 'a', title: 'Main', secondary: 'Maple_1', state: live)));
    expect(find.text('Main'), findsOneWidget);
    expect(find.text('Maple_1'), findsOneWidget);
  });

  testWidgets('problem tile shows its cause and Reconnect', (tester) async {
    var opens = 0;
    await pumpIn(
        tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: problem),
            onOpen: () => opens++));
    expect(find.text('Stream stopped'), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    expect(opens, 1);

    await pumpIn(
        tester,
        tile(const EmulatorTileData(
            id: 'a',
            title: 'Main',
            state: EmulatorUiState(EmulatorUiWord.problem, 'Problem',
                causeKey: 'Stream stopped', pcMessage: 'Boot timed out'))));
    expect(find.text('Boot timed out'), findsOneWidget);
    expect(find.text('Stream stopped'), findsNothing);
  });

  testWidgets('copying tile shows the percentage and no Start', (tester) async {
    await pumpIn(
        tester,
        tile(const EmulatorTileData(
            id: 'a',
            title: 'Main',
            state: EmulatorUiState(EmulatorUiWord.copying, 'Copying {42}%'))));
    expect(find.text('Copying 42%'), findsOneWidget);
    expect(find.text('Start'), findsNothing);
    expect(
        tester
            .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
            .value,
        0.42);
  });

  testWidgets('PC flag only when the window is shown', (tester) async {
    await pumpIn(tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: live)));
    expect(find.text('PC'), findsNothing);
    await pumpIn(
        tester,
        tile(const EmulatorTileData(
            id: 'a', title: 'Main', state: live, windowVisible: true)));
    expect(find.text('PC'), findsOneWidget);
  });

  testWidgets('long-press and the more button both ask for the action sheet',
      (tester) async {
    var more = 0;
    await pumpIn(
        tester,
        tile(const EmulatorTileData(id: 'a', title: 'Main', state: live),
            onMore: () => more++));
    await tester.longPress(find.byType(EmulatorTile));
    await tester.tap(find.byTooltip('More Main actions'));
    expect(more, 2);
  });

  testWidgets('without actions the tile has no more button and keeps its layout',
      (tester) async {
    const data = EmulatorTileData(id: 'a', title: 'Main', state: live);
    double nameWidth() => tester
        .renderObject<RenderBox>(find.text('Main'))
        .constraints
        .maxWidth;
    await pumpIn(tester, tile(data, onMore: () {}));
    expect(find.byTooltip('More Main actions'), findsOneWidget);
    final withMore = nameWidth();
    await pumpIn(tester, tile(data));
    expect(find.byTooltip('More Main actions'), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(nameWidth(), withMore);
  });

  testWidgets('without actions the row has no more button and keeps its layout',
      (tester) async {
    const data = EmulatorTileData(id: 'a', title: 'Main', state: live);
    Widget row({VoidCallback? onMore}) => SizedBox(
        width: 360,
        child: EmulatorRow(
            data: data, onOpen: () {}, onMore: onMore, tr: fakeTr));
    double nameWidth() => tester
        .renderObject<RenderBox>(find.text('Main'))
        .constraints
        .maxWidth;
    await pumpIn(tester, row(onMore: () {}));
    expect(find.byTooltip('More Main actions'), findsOneWidget);
    final withMore = nameWidth();
    await pumpIn(tester, row());
    expect(find.byTooltip('More Main actions'), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(nameWidth(), withMore);
    expect(find.byTooltip('Open'), findsOneWidget);
  });

  testWidgets('placeholder tile has no actions', (tester) async {
    var opens = 0;
    await pumpIn(
        tester,
        tile(
            const EmulatorTileData(
                id: 'a', title: 'New', state: stopped, placeholder: true),
            onOpen: () => opens++));
    expect(find.text('Setting up…'), findsOneWidget);
    expect(
        find.byWidgetPredicate(
            (w) => w is IconButton && (w.tooltip ?? '').endsWith('actions')),
        findsNothing);
    await tester.tap(find.byType(EmulatorTile));
    expect(opens, 0);
  });

  for (final base in [ThemeData.light(), ThemeData.dark()]) {
    testWidgets('tiles fit at 1.3 text scale in ${base.brightness.name}',
        (tester) async {
      const states = [
        live,
        stopped,
        problem,
        EmulatorUiState(EmulatorUiWord.copying, 'Copying {42}%')
      ];
      await pumpIn(
          tester,
          MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: SizedBox(
              width: 360,
              height: 800,
              child: GridView(
                padding: const EdgeInsets.all(8),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    mainAxisExtent: 158 * 4 / 3 + 1.3 * 64),
                children: [
                  for (final s in states)
                    EmulatorTile(
                        data: EmulatorTileData(
                            id: s.label,
                            title: 'BlueStacks App Player 3',
                            secondary: 'Maple_1',
                            state: s),
                        tr: fakeTr)
                ],
              ),
            ),
          ),
          theme: MirpgRemoteTheme.build(base));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('row offers the same primary action as the tile', (tester) async {
    for (final (state, tip) in [
      (stopped, 'Start'),
      (problem, 'Reconnect'),
      (live, 'Open')
    ]) {
      var opens = 0;
      await pumpIn(
          tester,
          EmulatorRow(
              data: EmulatorTileData(id: 'a', title: 'Main', state: state),
              onOpen: () => opens++,
              tr: fakeTr));
      await tester.tap(find.byTooltip(tip));
      expect(opens, 1, reason: tip);
    }
    await pumpIn(
        tester,
        EmulatorRow(
            data:
                const EmulatorTileData(id: 'a', title: 'Main', state: stopping),
            tr: fakeTr));
    for (final tip in ['Start', 'Reconnect', 'Open']) {
      expect(find.byTooltip(tip), findsNothing);
    }
  });
}
