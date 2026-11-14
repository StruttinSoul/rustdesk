import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/session_quality_panel.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_session_continuity.dart';
import 'package:flutter_hbb/models/model.dart';

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
          ),
        );
      }),
    ));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
    expect(selected, 0);

    await tester.tap(find.text('Screens'));
    await tester.pump();
    expect(selected, 1);

    await tester.tap(find.text('Tools'));
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
        ),
      ),
    ));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
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
        ),
      ),
    ));

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
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
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Tools'), findsOneWidget);
  });

  testWidgets('Studio screen rows keep boot, open and game actions accessible',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 700);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var monitorOpens = 0;
    var emulatorBoots = 0;
    var gameLaunches = 0;

    for (final base in [ThemeData.light(), ThemeData.dark()]) {
      await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(base),
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
            child: Column(children: [
              TargetScreenRow(
                name: 'Monitor 1',
                type: 'Windows',
                stopped: false,
                live: true,
                onOpen: () => monitorOpens++,
              ),
              TargetScreenRow(
                name: 'BlueStacks App Player 3',
                type: 'Android 13',
                stopped: true,
                live: false,
                onOpen: () => emulatorBoots++,
                onLaunchGame: () => gameLaunches++,
              ),
            ]),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Monitor 1'), findsOneWidget);
      expect(find.text('BlueStacks App Player 3'), findsOneWidget);
      await tester.tap(find.byTooltip('Open'));
      await tester.tap(find.byTooltip('Boot'));
      await tester.tap(find.byTooltip('More BlueStacks App Player 3 actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Launch game'));
      await tester.pumpAndSettle();
    }
    expect(monitorOpens, 2);
    expect(emulatorBoots, 2);
    expect(gameLaunches, 2);
  });

  testWidgets('Studio Home emulator cards avoid overlap at high text scale',
      (tester) async {
    var boots = 0;
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
                child: TargetPreviewCard(
                  name: 'BlueStacks App Player 3',
                  type: 'Android 13',
                  stopped: true,
                  live: false,
                  onOpen: () => boots++,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Boot'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Boot').hitTestable(),
          findsOneWidget);
      await tester.tap(find.text('Boot'));
    }
    expect(boots, 2);
  });

  testWidgets('connected PC session menu exposes settings and explicit end',
      (tester) async {
    var quality = 0;
    var privacy = 0;
    var settings = 0;
    var endSession = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          ConnectedPcSessionMenu(
            onQualityConnection: () => quality++,
            onPrivacyControls: () => privacy++,
            onSettings: () => settings++,
            onEndSession: () => endSession++,
          ),
        ]),
      ),
    ));

    await tester.tap(find.byTooltip('Session menu'));
    await tester.pumpAndSettle();
    expect(find.text('Quality & connection'), findsOneWidget);
    expect(find.text('Privacy & host controls'), findsOneWidget);
    expect(find.text('App settings'), findsOneWidget);
    expect(find.text('End session'), findsOneWidget);

    await tester.tap(find.text('Quality & connection'));
    await tester.pumpAndSettle();
    expect(quality, 1);
    expect(privacy, 0);
    expect(settings, 0);
    expect(endSession, 0);

    await tester.tap(find.byTooltip('Session menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Privacy & host controls'));
    await tester.pumpAndSettle();
    expect(privacy, 1);
    expect(settings, 0);
    expect(endSession, 0);

    await tester.tap(find.byTooltip('Session menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('App settings'));
    await tester.pumpAndSettle();
    expect(settings, 1);
    expect(endSession, 0);

    await tester.tap(find.byTooltip('Session menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    expect(endSession, 1);
  });

  test('quality profiles map only to supported RustDesk presets', () {
    expect(mirpgQualityProfileValue(MirpgQualityProfile.auto), 'balanced');
    expect(mirpgQualityProfileValue(MirpgQualityProfile.sharpText), 'best');
    expect(mirpgQualityProfileValue(MirpgQualityProfile.smoothMotion), 'low');
    expect(
        mirpgQualityProfileFromEffective('custom'), MirpgQualityProfile.auto);
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

  testWidgets('stopped cards boot only after an explicit tap', (tester) async {
    var boots = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 360,
      height: 260,
      child: TargetPreviewCard(
          name: 'MapleStory',
          type: 'Android 13',
          stopped: true,
          live: false,
          onOpen: () => boots++),
    ))));
    expect(boots, 0);
    expect(find.textContaining('Live'), findsNothing);
    await tester.tap(find.text('Boot'));
    expect(boots, 1);
  });

  testWidgets('running target cards expose explicit Open and Resume actions',
      (tester) async {
    var desktopOpens = 0;
    var androidResumes = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(children: [
          Expanded(
            child: TargetPreviewCard(
              name: 'Desktop',
              type: 'Windows',
              stopped: false,
              live: true,
              onOpen: () => desktopOpens++,
            ),
          ),
          Expanded(
            child: TargetPreviewCard(
              name: 'MapleStory',
              type: 'Android 13',
              stopped: false,
              live: true,
              onOpen: () => androidResumes++,
            ),
          ),
        ]),
      ),
    ));

    expect(find.text('Open'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.tap(find.text('Resume'));
    expect(desktopOpens, 1);
    expect(androidResumes, 1);
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
          body: TargetSwitcherCards(cards: [
            TargetPreviewCard(
              name: 'Monitor 1',
              type: 'Windows',
              stopped: false,
              live: true,
              onOpen: () {},
            ),
            TargetPreviewCard(
              name: 'BlueStacks App Player 3',
              type: 'Android 13',
              stopped: false,
              live: true,
              onOpen: () {},
            ),
          ]),
        ),
      ));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Open'), findsOneWidget);
      expect(find.text('Resume'), findsOneWidget);
      expect(find.text('Tap to control'), findsNWidgets(2));
      for (final card in find.byType(TargetPreviewCard).evaluate()) {
        final rect = tester.getRect(find.byWidget(card.widget));
        expect(rect.bottom, lessThanOrEqualTo(size.height));
        expect(rect.right, lessThanOrEqualTo(size.width));
      }
    }
  });

  testWidgets('launch game is a separate emulator action', (tester) async {
    var boots = 0;
    var launches = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 360,
      height: 280,
      child: TargetPreviewCard(
        name: 'MapleStory',
        type: 'Android 13',
        stopped: true,
        live: false,
        onOpen: () => boots++,
        onLaunchGame: () => launches++,
      ),
    ))));

    await tester.tap(find.text('Launch game'));
    expect(launches, 1);
    expect(boots, 0);

    await tester.tap(find.text('Boot'));
    expect(boots, 1);
  });

  testWidgets('closed guest stays visible as a running emulator with Reconnect',
      (tester) async {
    var reconnects = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SizedBox(
      width: 360,
      height: 280,
      child: TargetPreviewCard(
        name: 'BlueStacks App Player 3',
        type: 'Android 13',
        stopped: false,
        live: false,
        instanceState: 'Running',
        streamDisconnected: true,
        error: 'Guest session is closed',
        onOpen: () => reconnects++,
      ),
    ))));
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Stream disconnected'), findsOneWidget);
    expect(find.text('Running · Stream disconnected'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Live'), findsNothing);
    await tester.tap(find.text('Reconnect'));
    expect(reconnects, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disconnected preview fits compact cards with large text',
      (tester) async {
    var reconnects = 0;
    var gameLaunches = 0;
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
                child: TargetPreviewCard(
                  name: 'BlueStacks App Player 3',
                  type: 'Android 13',
                  stopped: false,
                  live: false,
                  instanceState: 'Running',
                  streamDisconnected: true,
                  error: 'Guest session is closed',
                  onOpen: () => reconnects++,
                  onLaunchGame: () => gameLaunches++,
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'card size: $size');
      expect(find.byTooltip('Reconnect'), findsOneWidget);
      expect(find.byTooltip('Launch game'), findsOneWidget);
      await tester.tap(find.byTooltip('Reconnect'));
      await tester.tap(find.byTooltip('Launch game'));
      expect(reconnects, greaterThan(0));
      expect(gameLaunches, greaterThan(0));
    }
  });

  testWidgets(
      'preview failure remains usable in a compact chooser at large font size',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
      child: const Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 230,
            height: 145,
            child: TargetPreviewCard(
                name: 'MapleStory',
                type: 'Android 13',
                stopped: false,
                live: false,
                error:
                    'Enable ADB debugging in this emulator instance before connecting'),
          )),
    ))));
    expect(tester.takeException(), isNull);
    expect(find.text('Retry preview'), findsOneWidget);
  });
}
