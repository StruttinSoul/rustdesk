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

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('PowerShell'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(selected, 0);

    await tester.tap(find.text('System'));
    await tester.pump();
    expect(selected, 1);

    await tester.tap(find.text('Files'));
    await tester.pump();
    expect(selected, 2);

    await tester.tap(find.text('PowerShell'));
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
    expect(find.text('PowerShell'), findsOneWidget);
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

    expect(find.text('Devices'), findsOneWidget);
    expect(find.text('System'), findsNothing);
    expect(find.text('Files'), findsNothing);
    expect(find.text('PowerShell'), findsNothing);
    expect(find.text('Codex'), findsOneWidget);
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
