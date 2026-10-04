import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_control_view.dart';

void main() {
  Future<void> show(WidgetTester tester,
      {bool control = true,
      void Function(int, Offset)? pointer,
      ValueChanged<int>? scroll,
      VoidCallback? ctrlAltDel,
      VoidCallback? switchView,
      VoidCallback? dashboard}) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
            body: MonitorControlView(
          desktopSize: const Size(3840, 2160),
          canControl: control,
          onPointer: pointer ?? (_, __) {},
          onScroll: scroll ?? (_) {},
          onKeyboard: () {},
          onSwitchView: switchView,
          onDashboard: dashboard,
          onCtrlAltDel: ctrlAltDel,
        ))));
  }

  testWidgets('Windows opens fit-to-screen with TeamViewer-style toolbar',
      (tester) async {
    await show(tester);
    final surface =
        tester.getSize(find.byKey(const ValueKey('monitor-trackpad')));
    final desktop = tester.getSize(find.byType(RawImage));
    expect(desktop.width, closeTo(surface.width, 0.01));
    expect(desktop.height, lessThanOrEqualTo(surface.height));
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.byTooltip('Actions'), findsOneWidget);
    expect(find.byTooltip('Display'), findsOneWidget);
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('125%'), findsOneWidget);
    expect(tester.getSize(find.byType(RawImage)).width,
        greaterThan(desktop.width));
  });

  testWidgets('TeamViewer mouse mode swipe moves and tap clicks',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    await tester.drag(surface, const Offset(80, 20));
    expect(events, contains(2));
    expect(events, isNot(contains(0)));
    events.clear();
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));
    expect(events, [0, 1]);
  });

  testWidgets('TeamViewer mouse mode hold is right click', (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await tester.longPress(find.byKey(const ValueKey('monitor-trackpad')));
    await tester.pump();
    expect(events, [3]);
  });

  testWidgets('TeamViewer two-finger drag scrolls without clicking',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    final center = tester.getCenter(surface);

    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 11);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 12);
    for (var i = 0; i < 4; i++) {
      await one.moveBy(const Offset(0, 15));
      await two.moveBy(const Offset(0, 15));
    }
    await one.up();
    await two.up();
    await tester.pump();
    expect(scroll, isNotEmpty);
    expect(events, isEmpty);
  });

  testWidgets('TeamViewer pinch zooms the remote desktop', (tester) async {
    await show(tester);
    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    final before = tester.getSize(find.byType(RawImage)).width;
    final center = tester.getCenter(surface);
    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 31);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 32);
    await one.moveBy(const Offset(-20, 0));
    await two.moveBy(const Offset(20, 0));
    await one.moveBy(const Offset(-20, 0));
    await two.moveBy(const Offset(20, 0));
    await one.up();
    await two.up();
    await tester.pump();
    expect(tester.getSize(find.byType(RawImage)).width, greaterThan(before));
  });

  testWidgets('TeamViewer toolbar exposes actions and navigation',
      (tester) async {
    var ctrlAltDel = 0;
    var switches = 0;
    var dashboards = 0;
    await show(tester,
        ctrlAltDel: () => ctrlAltDel++,
        switchView: () => switches++,
        dashboard: () => dashboards++);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    expect(find.byTooltip('Right click'), findsOneWidget);
    expect(find.byTooltip('Middle click'), findsOneWidget);
    await tester.tap(find.byTooltip('Ctrl+Alt+Del'));
    expect(ctrlAltDel, 1);
    await tester.tap(find.byTooltip('Switch view'));
    await tester.tap(find.byTooltip('Dashboard'));
    expect(switches, 1);
    expect(dashboards, 1);
  });

  testWidgets(
      'view-only sessions can zoom but cannot send pointer or keyboard input',
      (tester) async {
    final events = <int>[];
    await show(tester,
        control: false, pointer: (action, _) => events.add(action));
    await tester.drag(
        find.byKey(const ValueKey('monitor-trackpad')), const Offset(80, 20));
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Right click'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(events, isEmpty);
    final keyboard = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.keyboard_outlined));
    expect(keyboard.onPressed, isNull);
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    await tester.tap(find.byTooltip('Fit screen'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
