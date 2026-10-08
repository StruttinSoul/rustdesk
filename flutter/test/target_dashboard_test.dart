import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/session_quality_panel.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_session_continuity.dart';
import 'package:flutter_hbb/models/codex_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:uuid/uuid.dart';

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

  testWidgets('connected PC navigation exposes management tabs',
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
            codexAvailable: true,
            onDestinationSelected: (index) => setState(() => selected = index),
          ),
        );
      }),
    ));

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(selected, 0);

    await tester.tap(find.text('System'));
    await tester.pump();
    expect(selected, 1);

    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(selected, 2);

    await tester.tap(find.text('Shell'));
    await tester.pump();
    expect(selected, 3);

    await tester.tap(find.text('Codex'));
    await tester.pump();
    expect(selected, 4);
  });

  testWidgets('connected PC navigation keeps useful tabs without Codex',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ConnectedPcTabBar(
          currentIndex: 0,
          hostManagementAvailable: true,
          filesAvailable: true,
          powershellAvailable: true,
          codexAvailable: false,
          onDestinationSelected: (_) {},
        ),
      ),
    ));

    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
  });

  testWidgets('connected PC navigation omits unavailable management tabs',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        bottomNavigationBar: ConnectedPcTabBar(
          currentIndex: 0,
          hostManagementAvailable: false,
          filesAvailable: false,
          powershellAvailable: false,
          codexAvailable: true,
          onDestinationSelected: (_) {},
        ),
      ),
    ));

    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.text('Files'), findsNothing);
    expect(find.text('Shell'), findsNothing);
    expect(find.text('Codex'), findsOneWidget);
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
            codexAvailable: true,
            onDestinationSelected: (_) {},
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Shell'), findsOneWidget);
  });

  test('Codex overview prioritizes actionable and running work', () {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );
    model.threads = const [
      CodexThread(
        id: 'review',
        title: 'Review changes',
        project: 'MIRPG',
        originator: 'mobile',
        updatedAt: 30,
        state: 'completed',
      ),
      CodexThread(
        id: 'running',
        title: 'Implement remote controls',
        project: 'MIRPG',
        originator: 'mobile',
        updatedAt: 20,
        state: 'working',
      ),
      CodexThread(
        id: 'needs-you',
        title: 'Approval needed',
        project: 'MIRPG',
        originator: 'mobile',
        updatedAt: 10,
        state: 'waiting_for_approval',
      ),
      CodexThread(
        id: 'desktop-history',
        title: 'Old desktop task',
        project: 'MIRPG',
        originator: 'Codex Desktop',
        updatedAt: 40,
        state: 'resumable',
      ),
    ];

    final entries = codexOverviewEntries(model, limit: 3);
    expect(entries.map((entry) => entry.thread.id).toList(),
        ['needs-you', 'running', 'review']);
    expect(entries.map((entry) => entry.label).toList(),
        ['Needs you', 'Running', 'Review']);
  });

  testWidgets('Codex overview remains usable at 200 percent text',
      (tester) async {
    final entries = [
      const CodexOverviewEntry(
        thread: CodexThread(
          id: 'needs-you',
          title: 'Review a longer task title before continuing',
          project: 'MIRPG remote workspace',
          originator: 'mobile',
          updatedAt: 20,
          state: 'waiting_for_input',
        ),
        label: 'Needs you',
        icon: Icons.notification_important_outlined,
        tone: MirpgStatusTone.warning,
        priority: 0,
      ),
      const CodexOverviewEntry(
        thread: CodexThread(
          id: 'running',
          title: 'Continue remote-control implementation',
          project: 'MIRPG remote workspace',
          originator: 'mobile',
          updatedAt: 10,
          state: 'working',
        ),
        label: 'Running',
        icon: Icons.pending_outlined,
        tone: MirpgStatusTone.good,
        priority: 1,
      ),
    ];
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(
          size: Size(360, 800),
          textScaler: TextScaler.linear(2),
        ),
        child: Scaffold(
          body: Center(
            child: SizedBox(
              width: 328,
              height: 262,
              child: CodexOverviewCard(
                entries: entries,
                loading: false,
                error: '',
                onOpen: () {},
                onRefresh: () {},
              ),
            ),
          ),
        ),
      ),
    ));

    expect(tester.takeException(), isNull);
    expect(find.text('Ongoing work'), findsOneWidget);
    expect(find.text('Open Codex'), findsOneWidget);
    expect(find.text('Needs you'), findsOneWidget);
    expect(find.text('+1 more in Codex'), findsOneWidget);
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
