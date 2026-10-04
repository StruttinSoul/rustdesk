import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';

void main() {
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

  testWidgets('connected PC session menu exposes settings and explicit end',
      (tester) async {
    var settings = 0;
    var endSession = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(actions: [
          ConnectedPcSessionMenu(
            onSettings: () => settings++,
            onEndSession: () => endSession++,
          ),
        ]),
      ),
    ));

    await tester.tap(find.byTooltip('Session menu'));
    await tester.pumpAndSettle();
    expect(find.text('App settings'), findsOneWidget);
    expect(find.text('End session'), findsOneWidget);

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
