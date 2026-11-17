import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_action_sheet.dart';
import 'package:flutter_hbb/mobile/widgets/emulator_tile.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/session_quality_panel.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_session_continuity.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/models/model.dart';

import 'support/fake_translate.dart';

void main() {
  test('a monitor frame is usable only for the acknowledged preview request',
      () {
    expect(
        monitorFrameIsCurrent(
          previewRequest: 12,
          acknowledgedRequest: 12,
          frameRequest: 12,
        ),
        isTrue);
    expect(
        monitorFrameIsCurrent(
          previewRequest: 13,
          acknowledgedRequest: 13,
          frameRequest: 12,
        ),
        isFalse);
    expect(
        monitorFrameIsCurrent(
          previewRequest: 13,
          acknowledgedRequest: 12,
          frameRequest: 13,
        ),
        isFalse);
  });

  test('monitor input queued before an interruption is rejected', () {
    final epoch = MonitorInputEpoch();
    final queued = epoch.capture();
    expect(epoch.accepts(queued), isTrue);

    epoch.invalidate();
    expect(epoch.accepts(queued), isFalse);
    expect(epoch.accepts(epoch.capture()), isTrue);
  });

  test('connected workspace Back returns tabs to Overview without ending', () {
    var returnedToOverview = 0;
    var stayedConnected = 0;

    handleConnectedPcWorkspaceBack(
      atOverview: false,
      onReturnToOverview: () => returnedToOverview++,
      onStayConnected: () => stayedConnected++,
    );

    expect(returnedToOverview, 1);
    expect(stayedConnected, 0);
  });

  test('connected workspace Back at Overview stays connected', () {
    var returnedToOverview = 0;
    var stayedConnected = 0;

    handleConnectedPcWorkspaceBack(
      atOverview: true,
      onReturnToOverview: () => returnedToOverview++,
      onStayConnected: () => stayedConnected++,
    );

    expect(returnedToOverview, 0);
    expect(stayedConnected, 1);
  });

  testWidgets('Studio V4 navigation exposes three primary destinations',
      (tester) async {
    var selected = 0;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        return Scaffold(
          bottomNavigationBar: ConnectedPcTabBar(
            currentIndex: selected,
            hostManagementAvailable: true,
            filesAvailable: true,
            powershellAvailable: true,
            onDestinationSelected: (index) => setState(() => selected = index),
            tr: fakeTr,
          ),
        );
      }),
    ));

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('PC'), findsOneWidget);
    expect(selected, 0);

    await tester.tap(find.text('Screens'));
    await tester.pump();
    expect(selected, 1);

    await tester.tap(find.text('PC'));
    await tester.pump();
    expect(selected, 2);

  });

  testWidgets('connected PC navigation keeps useful tabs',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ConnectedPcTabBar(
          currentIndex: 0,
          hostManagementAvailable: true,
          filesAvailable: true,
          powershellAvailable: true,
          onDestinationSelected: (_) {},
          tr: fakeTr,
        ),
      ),
    ));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('PC'), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
  });

  testWidgets('primary navigation remains available without host tools',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ConnectedPcTabBar(
          currentIndex: 0,
          hostManagementAvailable: false,
          filesAvailable: false,
          powershellAvailable: false,
          onDestinationSelected: (_) {},
          tr: fakeTr,
        ),
      ),
    ));

    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('PC'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Shell'), findsNothing);
  });

  testWidgets('connected PC navigation fits compact width at 130 percent text',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: Scaffold(
          bottomNavigationBar: ConnectedPcTabBar(
            currentIndex: 0,
            hostManagementAvailable: true,
            filesAvailable: true,
            powershellAvailable: true,
            onDestinationSelected: (_) {},
            tr: fakeTr,
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('PC'), findsOneWidget);
  });

  testWidgets('Studio emulator rows keep boot, open and game actions accessible',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var emulatorStarts = 0;
    var gameLaunches = 0;
    const stopped = EmulatorUiState(EmulatorUiWord.stopped, 'Stopped');

    for (final base in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(base),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Builder(
              builder: (context) => Column(children: [
                EmulatorRow(
                  data: const EmulatorTileData(
                    id: 'bs3',
                    title: 'BlueStacks App Player 3',
                    state: stopped,
                  ),
                  onOpen: () => emulatorStarts++,
                  onMore: () => showEmulatorActionSheet(
                    context,
                    EmulatorActionSheet(
                      title: 'BlueStacks App Player 3',
                      subtitle: 'BlueStacks',
                      state: stopped,
                      stopped: true,
                      onOpen: () => emulatorStarts++,
                      onLaunchGame: () => gameLaunches++,
                      onLabel: () {},
                      tr: fakeTr,
                    ),
                  ),
                  tr: fakeTr,
                ),
              ]),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('BlueStacks App Player 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Start'));
      await tester.tap(find.byTooltip('More BlueStacks App Player 3 actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open and launch game'));
      await tester.pumpAndSettle();
    }
    expect(emulatorStarts, 2);
    expect(gameLaunches, 2);
  });

  testWidgets('Studio Home emulator cards avoid overlap at high text scale',
      (tester) async {
    var starts = 0;
    for (final base in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(base),
        home: Scaffold(
          body: Center(
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SizedBox(
                width: 134,
                height: 218,
                child: EmulatorTile(
                  data: const EmulatorTileData(
                    id: 'bs3',
                    title: 'BlueStacks App Player 3',
                    state: EmulatorUiState(EmulatorUiWord.stopped, 'Stopped'),
                  ),
                  onOpen: () => starts++,
                  tr: fakeTr,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Start'), findsOneWidget);
      expect(
          find
              .ancestor(
                  of: find.text('Start'),
                  matching: find.bySubtype<FilledButton>())
              .hitTestable(),
          findsOneWidget);
      await tester.tap(find.text('Start'));
    }
    expect(starts, 2);
  });

  test('quality profiles map only to supported RustDesk presets', () {
    expect(mirpgQualityProfileValue(MirpgQualityProfile.auto), 'balanced');
    expect(mirpgQualityProfileValue(MirpgQualityProfile.sharpText), 'best');
    expect(mirpgQualityProfileValue(MirpgQualityProfile.smoothMotion), 'low');
    expect(
        mirpgQualityProfileFromEffective('custom'), MirpgQualityProfile.auto);
  });

  test('quality profile descriptions do not name the app', () {
    for (final profile in MirpgQualityProfile.values) {
      expect(mirpgQualityProfileDescription(profile), isNot(contains('RustDesk')));
    }
    expect(mirpgQualityProfileDescription(MirpgQualityProfile.auto),
        'Uses Balanced quality for an adaptive everyday profile.');
  });

  test('slow warning requires a fresh measured delay', () {
    final now = DateTime(2026, 10, 4, 12);
    final data = QualityMonitorData()
      ..delay = '312'
      ..delayUpdatedAt = now.subtract(const Duration(seconds: 1));

    expect(qualityConnectionIsSlow(data, now), isTrue);

    data.delayUpdatedAt = now.subtract(const Duration(seconds: 8));
    expect(qualityConnectionIsSlow(data, now), isFalse);
  });

  testWidgets('session diagnostics show honest unavailable and stale states',
      (tester) async {
    final now = DateTime(2026, 10, 4, 12);
    final data = QualityMonitorData()
      ..delay = '45'
      ..delayUpdatedAt = now.subtract(const Duration(seconds: 8));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SessionQualityConnectionSheet(
          preferredProfile: MirpgQualityProfile.auto,
          effectiveQuality: 'balanced',
          applying: false,
          direct: false,
          data: data,
          now: now,
          onProfileChanged: (_) {},
        ),
      ),
    ));

    expect(find.textContaining('Relay'), findsWidgets);
    expect(find.text('45 ms · stale'), findsOneWidget);
    expect(find.text('Unavailable'), findsWidgets);
    expect(find.textContaining('prove a LAN route'), findsOneWidget);
  });

  testWidgets('compact status button fits 360 dp at 1.3 text scale',
      (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime(2026, 10, 4, 12);
    final data = QualityMonitorData()
      ..delay = '3'
      ..delayUpdatedAt = now.subtract(const Duration(seconds: 1));
    await tester.pumpWidget(MaterialApp(
      theme: MirpgRemoteTheme.build(ThemeData.dark()),
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(1.3),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 120,
              child: SessionStatusButton(
                compact: true,
                direct: true,
                data: data,
                now: now,
              ),
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Direct'), findsOneWidget);
    expect(find.byIcon(Icons.lan_outlined), findsNothing);
  });

  testWidgets('stopped tiles start only after an explicit tap', (tester) async {
    var starts = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 158,
      height: 290,
      child: EmulatorTile(
          data: const EmulatorTileData(
              id: 'maple',
              title: 'MapleStory',
              state: EmulatorUiState(EmulatorUiWord.stopped, 'Stopped')),
          onOpen: () => starts++,
          tr: fakeTr),
    ))));
    expect(starts, 0);
    expect(find.textContaining('Live'), findsNothing);
    await tester.tap(find.text('Start'));
    expect(starts, 1);
  });

  testWidgets('monitor cards expose Open', (tester) async {
    var opens = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TargetPreviewCard(
          name: 'Monitor 1',
          detail: '2560 × 1440',
          live: true,
          onOpen: () => opens++,
          tr: fakeTr,
        ),
      ),
    ));

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    await tester.tap(find.text('Open'));
    expect(opens, 1);
  });

  testWidgets(
      'switcher cards keep previews and actions visible in both rotations',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final size in [const Size(900, 360), const Size(360, 700)]) {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TargetSwitcherGrid(cards: [
            TargetPreviewCard(
              name: 'Monitor 1',
              live: true,
              onOpen: () {},
              tr: fakeTr,
            ),
            EmulatorTile(
              data: const EmulatorTileData(
                  id: 'bs3',
                  title: 'BlueStacks App Player 3',
                  state: EmulatorUiState(EmulatorUiWord.live, 'Live')),
              onOpen: () {},
              onMore: () {},
              tr: fakeTr,
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Live'), findsWidgets);
      expect(find.byTooltip('More BlueStacks App Player 3 actions'),
          findsOneWidget);
      for (final finder in [
        find.byType(TargetPreviewCard),
        find.byType(EmulatorTile)
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
    }
  });

  testWidgets('launch game is a separate emulator action', (tester) async {
    var opens = 0;
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showEmulatorActionSheet(
              context,
              EmulatorActionSheet(
                title: 'MapleStory',
                subtitle: 'BlueStacks',
                state: const EmulatorUiState(EmulatorUiWord.stopped, 'Stopped'),
                stopped: true,
                onOpen: () => opens++,
                onLaunchGame: () => launches++,
                onLabel: () {},
                tr: fakeTr,
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open and launch game'));
    await tester.pumpAndSettle();
    expect(launches, 1);
    expect(opens, 0);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    expect(opens, 1);
    expect(launches, 1);
  });

  testWidgets('closed guest stays visible as a problem tile with Reconnect',
      (tester) async {
    var reconnects = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 158,
      height: 290,
      child: EmulatorTile(
        data: const EmulatorTileData(
          id: 'bs3',
          title: 'BlueStacks App Player 3',
          state: EmulatorUiState(EmulatorUiWord.problem, 'Problem',
              causeKey: 'Stream stopped'),
        ),
        onOpen: () => reconnects++,
        tr: fakeTr,
      ),
    ))));
    expect(find.text('Problem'), findsOneWidget);
    expect(find.text('Stream stopped'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    await tester.tap(find.text('Reconnect'));
    expect(reconnects, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected preview fits compact cards with large text',
      (tester) async {
    var reconnects = 0;
    for (final size in [const Size(230, 145), const Size(360, 260)]) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.4)),
              child: SizedBox(
                width: size.width,
                height: size.height,
                child: EmulatorTile(
                  data: const EmulatorTileData(
                    id: 'bs3',
                    title: 'BlueStacks App Player 3',
                    state: EmulatorUiState(EmulatorUiWord.problem, 'Problem',
                        causeKey: 'Stream stopped',
                        pcMessage: 'Guest session is closed'),
                  ),
                  onOpen: () => reconnects++,
                  onMore: () {},
                  tr: fakeTr,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'card size: $size');
      expect(find.text('Reconnect'), findsOneWidget);
      expect(find.byTooltip('More BlueStacks App Player 3 actions'),
          findsOneWidget);
      await tester.tap(find.text('Reconnect'));
    }
    expect(reconnects, 2);
  });
}
