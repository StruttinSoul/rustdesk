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
    final desktop = tester.getSize(find.byKey(const ValueKey('monitor-frame')));
    expect(desktop.width, closeTo(surface.width, 0.01));
    expect(desktop.height, lessThanOrEqualTo(surface.height));
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(find.byTooltip('Actions'), findsOneWidget);
    expect(find.byTooltip('Display'), findsOneWidget);
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    expect(find.text('Fit'), findsOneWidget);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('1.25× Fit'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('monitor-frame'))).width,
        greaterThan(desktop.width));
  });

  testWidgets('Readable preset enlarges Windows and exposes a minimap',
      (tester) async {
    await show(tester);
    final surface =
        tester.getSize(find.byKey(const ValueKey('monitor-trackpad')));

    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    await tester.tap(find.byTooltip('Readable'));
    await tester.pump();

    expect(find.byKey(const ValueKey('monitor-minimap')), findsOneWidget);
    expect(find.text('Readable'), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey('monitor-frame'))).width,
        greaterThan(surface.width));
  });

  testWidgets('minimap navigation pans locally without remote input',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    await tester.tap(find.byTooltip('Readable'));
    await tester.pump();

    final frame = find.byKey(const ValueKey('monitor-frame'));
    final before = tester.getTopLeft(frame);
    final minimap = find.byKey(const ValueKey('monitor-minimap'));
    await tester.tapAt(tester.getTopLeft(minimap) + const Offset(12, 12));
    await tester.pump();

    expect(events, isEmpty);
    expect(tester.getTopLeft(frame), isNot(before));
  });

  testWidgets('Pan moves the viewport without moving the remote pointer',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    await tester.tap(find.byTooltip('Readable'));
    await tester.pump();
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Pan'));
    await tester.pump();

    final frame = find.byKey(const ValueKey('monitor-frame'));
    final before = tester.getTopLeft(frame);
    await tester.drag(
        find.byKey(const ValueKey('monitor-trackpad')), const Offset(90, 0));
    await tester.pump();

    expect(events, isEmpty);
    expect(tester.getTopLeft(frame), isNot(before));
  });

  testWidgets('Precision reduces relative pointer gain', (tester) async {
    final moves = <Offset>[];
    await show(tester, pointer: (action, point) {
      if (action == 2) moves.add(point);
    });
    final surface = find.byKey(const ValueKey('monitor-trackpad'));

    await tester.drag(surface, const Offset(80, 0));
    final normalEnd = moves.last.dx;
    final normalDelta = normalEnd - 1920;
    moves.clear();

    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Precision'));
    await tester.pump();
    await tester.drag(surface, const Offset(80, 0));
    final precisionDelta = moves.last.dx - normalEnd;

    expect(precisionDelta.abs(), lessThan(normalDelta.abs() * 0.6));
  });

  testWidgets('drag lock remains releasable with the toolbar hidden',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Drag lock'));
    await tester.pump();
    expect(events, [0]);
    expect(find.text('Drag locked'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pump();
    expect(find.text('Drag locked'), findsOneWidget);
    await tester.tap(find.text('Release'));
    await tester.pump();
    expect(events, [0, 1]);
  });

  testWidgets('drag lock releases when monitor control becomes unavailable',
      (tester) async {
    final events = <int>[];
    var control = true;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return Scaffold(
          body: MonitorControlView(
            desktopSize: const Size(3840, 2160),
            canControl: control,
            onPointer: (action, _) => events.add(action),
            onScroll: (_) {},
            onKeyboard: () {},
          ),
        );
      }),
    ));

    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Drag lock'));
    await tester.pump();
    expect(events, [0]);

    update(() => control = false);
    await tester.pump();
    expect(events, [0, 1]);
    expect(find.text('Drag locked'), findsNothing);
  });

  testWidgets('toolbar can dock left and right', (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    expect(find.byTooltip('Dock controls left'), findsOneWidget);
    await tester.tap(find.byTooltip('Dock controls left'));
    await tester.pump();
    expect(find.byTooltip('Dock controls right'), findsOneWidget);
  });

  testWidgets(
      'local view only blocks monitor input without changing host access',
      (tester) async {
    final events = <int>[];
    var localViewOnly = false;
    late StateSetter update;
    await tester.pumpWidget(MaterialApp(
      home: StatefulBuilder(builder: (context, setState) {
        update = setState;
        return Scaffold(
          body: MonitorControlView(
            desktopSize: const Size(3840, 2160),
            canControl: true,
            localViewOnly: localViewOnly,
            onLocalViewOnlyChanged: (value) {
              update(() => localViewOnly = value);
            },
            onPointer: (action, _) => events.add(action),
            onScroll: (_) {},
            onKeyboard: () {},
          ),
        );
      }),
    ));

    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('View only'));
    await tester.pump();
    expect(localViewOnly, isTrue);

    await tester.tap(find.byKey(const ValueKey('monitor-trackpad')));
    await tester.pump();
    expect(events, isEmpty);
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
    final before =
        tester.getSize(find.byKey(const ValueKey('monitor-frame'))).width;
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
    expect(tester.getSize(find.byKey(const ValueKey('monitor-frame'))).width,
        greaterThan(before));
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
    expect(find.text('Fit'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Text input stays local until Send is explicitly tapped',
      (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          onText: sent.add,
          onKey: (_) {},
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'line one\nline two');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(sent, isEmpty);

    await tester.tap(find.byTooltip('Send text'));
    await tester.pump();
    expect(sent, ['line one\nline two']);
  });

  testWidgets('sticky modifiers release when switching from Keys to Text',
      (tester) async {
    final states = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          onText: (_) {},
          onKey: (_) {},
          onKeyState: (key, down) =>
              states.add('${key.debugName}:${down ? 'down' : 'up'}'),
        ),
      ),
    ));

    await tester.tap(find.text('Keys'));
    await tester.pump();
    await tester.tap(find.text('Ctrl'));
    await tester.pump();
    expect(states, contains('Control Left:down'));

    await tester.tap(find.text('Ctrl+C'));
    await tester.pump();
    expect(states, ['Control Left:down']);

    await tester.tap(find.text('Text'));
    await tester.pump();
    expect(states, contains('Control Left:up'));
  });
}
