import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_tile.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/play_tab.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

RemoteEmulator g(int i, String state) =>
    RemoteEmulator(id: 'avd:E$i', name: 'E$i', provider: 'avd', state: state);

const live = EmulatorUiState(EmulatorUiWord.live, 'Live');
const stopped = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');
const starting = EmulatorUiState(EmulatorUiWord.starting, 'Starting');
const copying = EmulatorUiState(EmulatorUiWord.copying, 'Copying {42}%');

EmulatorTileData t(String name, EmulatorUiState state) =>
    EmulatorTileData(id: 'avd:$name', title: name, state: state);

void main() {
  group('playTabPreviewIds', () {
    test('four running emulators all get previews in grid order', () {
      expect(
          playTabPreviewIds([for (var i = 0; i < 4; i++) g(i, 'running')],
              firstVisibleIndex: 0),
          ['avd:E0', 'avd:E1', 'avd:E2', 'avd:E3']);
    });
    test('stopped, stopping, copying and shutting-down emulators never take a slot',
        () {
      final guests = [
        g(0, 'stopped'),
        g(1, 'running'),
        g(2, 'cloning'),
        g(3, 'stopping'),
        g(4, 'running')
      ];
      expect(
          playTabPreviewIds(guests,
              firstVisibleIndex: 0, shuttingDown: (id) => id == 'avd:E4'),
          ['avd:E1']);
    });
    test('with more than four running the ones nearest the viewport top win',
        () {
      final six = [for (var i = 0; i < 6; i++) g(i, 'running')];
      expect(playTabPreviewIds(six, firstVisibleIndex: 2),
          ['avd:E2', 'avd:E3', 'avd:E4', 'avd:E5']);
      expect(playTabPreviewIds(six, firstVisibleIndex: 4),
          ['avd:E4', 'avd:E5', 'avd:E3', 'avd:E2']);
    });
    test('the open emulator does not take a preview slot', () {
      final five = [for (var i = 0; i < 5; i++) g(i, 'running')];
      expect(playTabPreviewIds(five, firstVisibleIndex: 0, activeId: 'avd:E1'),
          ['avd:E0', 'avd:E2', 'avd:E3', 'avd:E4']);
    });
  });

  group('start requests (Review Focus 1)', () {
    final t0 = DateTime(2026, 11, 17, 12);

    EmulatorUiState shown(Map<String, DateTime> requests, RemoteEmulator e,
            DateTime now) =>
        emulatorUiState(e,
            flags: EmulatorUiFlags(
                startRequested: startRequestPending(requests, e.id, now)));

    test('a started emulator reads Starting after leaving the startup screen',
        () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'stopped'), t0);
      // The phone is back on the grid; the next list has not arrived yet, or
      // still says stopped.
      final now = t0.add(const Duration(seconds: 5));
      pruneStartRequests(requests, [g(0, 'stopped')], now);
      expect(shown(requests, g(0, 'stopped'), now).word,
          EmulatorUiWord.starting);
    });
    test('the request ends once the PC lists the emulator as not stopped', () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'stopped'), t0);
      pruneStartRequests(requests, [g(0, 'booting')], t0);
      expect(requests, isEmpty);
      // A later failed start shows Stopped again, not a stale Starting.
      expect(shown(requests, g(0, 'stopped'), t0).word, EmulatorUiWord.stopped);
    });
    test('the request expires after the 120 s start timeout', () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'stopped'), t0);
      final late = t0.add(const Duration(seconds: 120));
      expect(startRequestPending(requests, 'avd:E0', late), isFalse);
      pruneStartRequests(requests, [g(0, 'stopped')], late);
      expect(requests, isEmpty);
    });
    test('opening a running emulator is not a start request', () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'running'), t0);
      expect(requests, isEmpty);
    });
    test('an emulator no longer listed drops its request', () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'stopped'), t0);
      pruneStartRequests(requests, const [], t0);
      expect(requests, isEmpty);
    });
  });

  group('running as far as the phone knows (start one, go back, start the next)',
      () {
    final t0 = DateTime(2026, 11, 17, 12);

    bool running(
      RemoteEmulator e, {
      Map<String, DateTime> requests = const {},
      Map<String, DateTime> seen = const {},
      DateTime? listRequestedAt,
      DateTime? now,
    }) =>
        emulatorRunningAsKnown(e,
            startRequests: requests,
            seenLive: seen,
            listRequestedAt: listRequestedAt,
            now: now ?? t0);

    test('a stopped emulator never seen live is not running', () {
      expect(running(g(0, 'stopped')), isFalse);
      expect(running(g(0, 'stopped'), listRequestedAt: t0), isFalse);
    });
    test('an emulator this phone streamed is running though the list says '
        'stopped', () {
      final seen = <String, DateTime>{};
      // The list the cache came from was asked for before the game went live.
      final listAt = t0.subtract(const Duration(seconds: 30));
      noteSeenLive(seen, 'avd:E0', t0);
      // Long after the 120 s start request would have expired.
      final later = t0.add(const Duration(minutes: 10));
      expect(
          running(g(0, 'stopped'),
              seen: seen, listRequestedAt: listAt, now: later),
          isTrue);
      expect(seenLiveSinceList(seen, 'avd:E0', listAt), isTrue);
      expect(seenLiveSinceList(seen, 'avd:E0', null), isTrue);
      expect(seenLiveSinceList(seen, 'avd:E1', listAt), isFalse);
    });
    test('a list asked for after the sighting that says stopped wins', () {
      final seen = <String, DateTime>{};
      noteSeenLive(seen, 'avd:E0', t0);
      final listAt = t0.add(const Duration(seconds: 5));
      expect(running(g(0, 'stopped'), seen: seen, listRequestedAt: listAt),
          isFalse);
      expect(seenLiveSinceList(seen, 'avd:E0', listAt), isFalse);
      // Seen live again after that list: running again.
      noteSeenLive(seen, 'avd:E0', t0.add(const Duration(seconds: 9)));
      expect(running(g(0, 'stopped'), seen: seen, listRequestedAt: listAt),
          isTrue);
    });
    test('a start request within the hold is running, after it is not', () {
      final requests = <String, DateTime>{};
      noteStartRequest(requests, g(0, 'stopped'), t0);
      expect(
          running(g(0, 'stopped'),
              requests: requests, now: t0.add(const Duration(seconds: 119))),
          isTrue);
      expect(
          running(g(0, 'stopped'),
              requests: requests, now: t0.add(const Duration(seconds: 120))),
          isFalse);
    });
    test('the PC\'s own state counts when it is not stopped', () {
      for (final state in ['running', 'ready', 'booting', 'stopping']) {
        expect(running(g(0, state)), isTrue, reason: state);
      }
      expect(running(g(0, 'cloning')), isFalse);
    });
  });

  group('PlayTabBody', () {
    late int refreshes;
    late int retries;
    late int news;
    late int screens;
    late List<String> opens;
    late List<String> mores;

    setUp(() {
      refreshes = retries = news = screens = 0;
      opens = [];
      mores = [];
    });

    Future<void> pump(
      WidgetTester tester, {
      List<EmulatorTileData> tiles = const [],
      bool firstLoad = false,
      String listError = '',
      int monitorCount = 0,
      bool withNew = true,
      double scale = 1.0,
    }) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(ThemeData.dark()),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!),
        home: Scaffold(
          body: PlayTabBody(
            tiles: tiles,
            hostName: 'atlas',
            firstLoad: firstLoad,
            listError: listError,
            monitorCount: monitorCount,
            onRefresh: () async => refreshes++,
            onRetryList: () => retries++,
            onOpen: opens.add,
            onMore: mores.add,
            onOpenScreens: () => screens++,
            onNew: withNew ? () => news++ : null,
            tr: fakeTr,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('first load shows four skeleton tiles and no spinner',
        (tester) async {
      await pump(tester, firstLoad: true);
      expect(find.byKey(const ValueKey('play-skeleton')), findsNWidgets(4));
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('running'), findsNothing);
    });

    testWidgets('empty list offers New emulator and names the PC',
        (tester) async {
      await pump(tester);
      expect(find.text('No emulators on atlas yet'), findsOneWidget);
      expect(find.text('BlueStacks instances appear here when BlueStacks is installed.'),
          findsOneWidget);
      await tester.tap(find.text('New emulator'));
      expect(news, 1);

      await pump(tester, withNew: false);
      expect(find.text('No emulators on atlas yet'), findsOneWidget);
      expect(find.text('New emulator'), findsNothing);
    });

    testWidgets('list error is an inline card with Try again', (tester) async {
      await pump(tester,
          listError: 'The PC did not return its emulator list.');
      expect(find.text("Couldn't get the emulator list from atlas"),
          findsOneWidget);
      expect(find.text('The PC did not return its emulator list.'),
          findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(retries, 1);
    });

    testWidgets('tiles keep the given order and header counts running',
        (tester) async {
      await pump(tester, tiles: [
        t('A', live),
        t('B', stopped),
        t('C', starting),
        t('D', live),
      ]);
      expect(find.text('Emulators · 3/4 running'), findsOneWidget);
      expect(tester.getTopLeft(find.text('A')).dy,
          lessThan(tester.getTopLeft(find.text('C')).dy));
      expect(tester.getTopLeft(find.text('A')).dx,
          lessThan(tester.getTopLeft(find.text('B')).dx));
    });

    testWidgets('copying tile is not openable from the grid', (tester) async {
      await pump(tester, tiles: [t('A', live), t('B', copying)]);
      await tester.tap(find.text('B'));
      await tester.pump();
      expect(opens, isEmpty);
      await tester.tap(find.text('A'));
      await tester.pump();
      expect(opens, ['avd:A']);
    });

    testWidgets('the more button and long-press open actions for that tile',
        (tester) async {
      await pump(tester, tiles: [t('A', live), t('B', stopped)]);
      await tester.tap(find.byTooltip('More B actions'));
      await tester.longPress(find.text('A'));
      expect(mores, ['avd:B', 'avd:A']);
    });

    testWidgets('a placeholder tile is not openable and has no actions',
        (tester) async {
      await pump(tester, tiles: [
        t('A', live),
        const EmulatorTileData(
            id: 'avd:New', title: 'New', state: starting, placeholder: true),
      ]);
      expect(find.text('Setting up…'), findsOneWidget);
      await tester.tap(find.text('New'));
      await tester.longPress(find.text('New'));
      expect(opens, isEmpty);
      expect(mores, isEmpty);
    });

    testWidgets('a start-requested stopped emulator reads Starting on its tile',
        (tester) async {
      final requests = <String, DateTime>{};
      final now = DateTime(2026, 11, 17, 12);
      noteStartRequest(requests, g(0, 'stopped'), now);
      final state = emulatorUiState(g(0, 'stopped'),
          flags: EmulatorUiFlags(
              startRequested: startRequestPending(requests, 'avd:E0', now)));
      await pump(tester, tiles: [t('E0', state)]);
      expect(find.text('Starting'), findsOneWidget);
      expect(find.text('Stopped'), findsNothing);
      expect(find.text('Start'), findsNothing);
    });

    testWidgets('PC screens row opens the Screens tab', (tester) async {
      await pump(tester, tiles: [t('A', live)], monitorCount: 3);
      expect(find.text('PC screens'), findsOneWidget);
      await tester.tap(find.text('Monitor 1 · 2 · 3'));
      expect(screens, 1);

      await pump(tester, tiles: [t('A', live)], monitorCount: 0);
      expect(find.text('PC screens'), findsNothing);
    });

    testWidgets('pull to refresh calls onRefresh', (tester) async {
      await pump(tester, tiles: [t('A', live)]);
      await tester.fling(
          find.byType(CustomScrollView), const Offset(0, 400), 1000);
      await tester.pumpAndSettle();
      expect(refreshes, 1);
    });

    testWidgets('grid fits four tiles with long names at 1.3 text scale',
        (tester) async {
      const long = 'Maple_Story_Main_Account_With_A_Very_Long_Name';
      await pump(
        tester,
        scale: 1.3,
        monitorCount: 2,
        tiles: [
          for (final s in [live, stopped, starting, copying])
            EmulatorTileData(
                id: 'avd:$long${s.label}',
                title: '$long ${s.label}',
                secondary: long,
                state: s),
        ],
      );
      expect(tester.takeException(), isNull);
      expect(find.byType(EmulatorTile), findsNWidgets(4));
    });

    testWidgets('the last row clears the floating New button', (tester) async {
      await pump(tester, tiles: [for (final n in 'ABCDEF'.split('')) t(n, live)]);
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
      await tester.pump();
      final lastBottom = tester.getBottomLeft(find.byType(EmulatorTile).last).dy;
      expect(800 - lastBottom, greaterThanOrEqualTo(88));
    });
  });
}
