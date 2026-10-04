import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_control_view.dart';

void main() {
  Future<void> show(WidgetTester tester,
      {bool control = true,
      void Function(int, Offset)? pointer,
      ValueChanged<int>? scroll,
      VoidCallback? ctrlAltDel}) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
            body: MonitorControlView(
          desktopSize: const Size(3840, 2160),
          canControl: control,
          onPointer: pointer ?? (_, __) {},
          onScroll: scroll ?? (_) {},
          onKeyboard: () {},
          onCtrlAltDel: ctrlAltDel,
        ))));
  }

  testWidgets('Windows opens fit-to-screen like AnyDesk', (tester) async {
    await show(tester);
    final surface =
        tester.getSize(find.byKey(const ValueKey('monitor-trackpad')));
    final desktop = tester.getSize(find.byType(RawImage));
    expect(desktop.width, closeTo(surface.width, 0.01));
    expect(desktop.height, lessThanOrEqualTo(surface.height));
    expect(find.byIcon(Icons.mouse_outlined), findsOneWidget);
    await tester.tap(find.byTooltip('Session menu'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('125%'), findsOneWidget);
    expect(tester.getSize(find.byType(RawImage)).width,
        greaterThan(desktop.width));
  });

  testWidgets(
      'AnyDesk trackpad swipe moves, tap clicks, and two fingers only change the view',
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
    final center = tester.getCenter(surface);
    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 1);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 2);
    await one.moveTo(center - const Offset(70, 0));
    await two.moveTo(center + const Offset(70, 0));
    await one.up();
    await two.up();
    await tester.pump();
    expect(events, isNot(contains(0)));
    expect(scroll, isEmpty);
    events.clear();
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));
    expect(events, [0, 1]);
  });

  testWidgets('AnyDesk hold is right click instead of left-button drag',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await tester.longPress(find.byKey(const ValueKey('monitor-trackpad')));
    await tester.pump();
    expect(events, [3]);
  });

  testWidgets(
      'AnyDesk three-finger swipe scrolls and three-finger tap middle-clicks',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    final center = tester.getCenter(surface);

    final one =
        await tester.startGesture(center - const Offset(40, 0), pointer: 11);
    final two = await tester.startGesture(center, pointer: 12);
    final three =
        await tester.startGesture(center + const Offset(40, 0), pointer: 13);
    await one.moveBy(const Offset(0, 60));
    await two.moveBy(const Offset(0, 60));
    await three.moveBy(const Offset(0, 60));
    await one.up();
    await two.up();
    await three.up();
    await tester.pump();
    expect(scroll, isNotEmpty);
    expect(events, isNot(contains(4)));

    scroll.clear();
    events.clear();
    final tapOne =
        await tester.startGesture(center - const Offset(30, 0), pointer: 21);
    final tapTwo = await tester.startGesture(center, pointer: 22);
    final tapThree =
        await tester.startGesture(center + const Offset(30, 0), pointer: 23);
    await tapOne.up();
    await tapTwo.up();
    await tapThree.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(scroll, isEmpty);
    expect(events, [4]);
  });

  testWidgets('session menu exposes Windows controls and secure attention',
      (tester) async {
    var ctrlAltDel = 0;
    await show(tester, ctrlAltDel: () => ctrlAltDel++);
    await tester.tap(find.byTooltip('Session menu'));
    await tester.pump();
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.byTooltip('Right click'), findsOneWidget);
    expect(find.byTooltip('Middle click'), findsOneWidget);
    await tester.tap(find.byTooltip('Ctrl+Alt+Del'));
    expect(ctrlAltDel, 1);
  });

  testWidgets(
      'view-only sessions can zoom but cannot send pointer or keyboard input',
      (tester) async {
    final events = <int>[];
    await show(tester,
        control: false, pointer: (action, _) => events.add(action));
    await tester.drag(
        find.byKey(const ValueKey('monitor-trackpad')), const Offset(80, 20));
    await tester.tap(find.byTooltip('Session menu'));
    await tester.pump();
    await tester.tap(find.byTooltip('Right click'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(events, isEmpty);
    final keyboard = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.keyboard_outlined));
    expect(keyboard.onPressed, isNull);
    await tester.tap(find.byTooltip('Fit screen'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('100%'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
