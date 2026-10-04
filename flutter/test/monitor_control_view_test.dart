import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_control_view.dart';

void main() {
  Future<void> show(WidgetTester tester,
      {bool control = true,
      void Function(int, Offset)? pointer,
      ValueChanged<int>? scroll,
      MonitorControlPreferences preferences = const MonitorControlPreferences(),
      ValueChanged<MonitorControlPreferences>? onPreferencesChanged,
      VoidCallback? ctrlAltDel,
      VoidCallback? switchView,
      VoidCallback? dashboard}) async {
    await tester.pumpWidget(MaterialApp(
        theme: ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
            body: MonitorControlView(
          desktopSize: const Size(3840, 2160),
          canControl: control,
          preferences: preferences,
          onPreferencesChanged: onPreferencesChanged,
          onPointer: pointer ?? (_, __) {},
          onScroll: scroll ?? (_) {},
          onKeyboard: () {},
          onSwitchView: switchView,
          onDashboard: dashboard,
          onCtrlAltDel: ctrlAltDel,
        ))));
  }

  test('monitor preferences round trip safely', () {
    const preferences = MonitorControlPreferences(
      preferredView: MonitorViewPreference.readable,
      precision: true,
      precisionGain: 0.2,
      toolbarDock: MonitorToolbarDock.left,
      toolbarVisible: false,
      thumbwheelVisible: true,
      mouseButtonsVisible: true,
      mouseButtonsPosition: Offset(0.25, 0.65),
      cursorOffset: true,
      orientation: MonitorOrientationPreference.portrait,
    );

    expect(
        MonitorControlPreferences.fromJson(preferences.toJson()), preferences);
    expect(
        monitorUsesLandscape(
            MonitorOrientationPreference.auto, const Size(2560, 1440)),
        isTrue);
    expect(
        monitorUsesLandscape(
            MonitorOrientationPreference.portrait, const Size(2560, 1440)),
        isFalse);
  });

  test('custom shortcut presets round trip with monitor preferences', () {
    final preferences = MonitorControlPreferences(
      shortcuts: [
        kDefaultMonitorShortcuts[1].copyWith(
          modifiers: const ['ctrl', 'alt'],
        ),
        kDefaultMonitorShortcuts[0],
      ],
    );

    final restored = MonitorControlPreferences.fromJson(preferences.toJson());
    expect(restored.shortcuts.map((item) => item.id).toList(),
        ['copy', 'alt-tab']);
    expect(restored.shortcuts.first.label, 'Ctrl+Alt+C');
  });

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

  testWidgets('thumbwheel scrolls without moving or clicking the pointer',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        preferences: const MonitorControlPreferences(thumbwheelVisible: true),
        pointer: (action, _) => events.add(action),
        scroll: scroll.add);

    final wheel = find.byKey(const ValueKey('monitor-thumbwheel'));
    expect(wheel, findsOneWidget);
    await tester.drag(wheel, const Offset(0, 80));
    await tester.pump();

    expect(scroll, isNotEmpty);
    expect(events, isEmpty);
  });

  testWidgets('floating mouse buttons move and send explicit button events',
      (tester) async {
    final events = <int>[];
    final changes = <MonitorControlPreferences>[];
    await show(tester,
        preferences: const MonitorControlPreferences(mouseButtonsVisible: true),
        onPreferencesChanged: changes.add,
        pointer: (action, _) => events.add(action));

    final controls = find.byKey(const ValueKey('monitor-mouse-buttons'));
    final before = tester.getTopLeft(controls);
    await tester.drag(find.byKey(const ValueKey('monitor-mouse-buttons-drag')),
        const Offset(-100, -80));
    await tester.pump();
    final after = tester.getTopLeft(controls);
    expect(after, isNot(before));
    expect(changes, isNotEmpty);

    await tester.tap(find.byTooltip('Remote right mouse button'));
    await tester.pump();
    expect(events, containsAllInOrder([5, 6]));
  });

  testWidgets('orientation preference is reported from the display controls',
      (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await tester.tap(find.byTooltip('Display'));
    await tester.pump();
    await tester.tap(find.byTooltip('Orientation: Auto'));
    await tester.pump();

    expect(changes.last.orientation, MonitorOrientationPreference.portrait);
  });

  testWidgets('cursor offset maps taps above the finger and stays in bounds',
      (tester) async {
    final events = <(int, Offset)>[];
    await show(tester,
        preferences: const MonitorControlPreferences(cursorOffset: true),
        pointer: (action, point) => events.add((action, point)));

    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    final center = tester.getCenter(surface);
    await tester.tapAt(center);
    await tester.pump();

    expect(events.map((event) => event.$1), containsAllInOrder([2, 0, 1]));
    final click = events.last.$2;
    expect(click.dx, closeTo(1920, 2));
    expect(click.dy, lessThan(1080));
    expect(click.dx, inInclusiveRange(0, 3839));
    expect(click.dy, inInclusiveRange(0, 2159));
  });

  testWidgets('cursor offset toggle is persisted through control preferences',
      (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Cursor offset'));
    await tester.pump();

    expect(changes.last.cursorOffset, isTrue);
    expect(find.text('Cursor offset'), findsOneWidget);
  });

  testWidgets('precision gain is adjustable and persisted', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Precision speed'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.value, closeTo(0.35, 0.001));
    slider.onChanged!(0.2);
    await tester.pump();

    expect(changes.last.precisionGain, closeTo(0.2, 0.001));
    expect(find.text('Pointer gain 20%'), findsOneWidget);
  });

  testWidgets('reset controls restores the persisted defaults', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester,
        preferences: const MonitorControlPreferences(
          preferredView: MonitorViewPreference.readable,
          precision: true,
          precisionGain: 0.2,
          toolbarDock: MonitorToolbarDock.left,
          thumbwheelVisible: true,
          mouseButtonsVisible: true,
          cursorOffset: true,
          orientation: MonitorOrientationPreference.portrait,
        ),
        onPreferencesChanged: changes.add);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Reset controls'));
    await tester.pump();

    expect(changes.last, const MonitorControlPreferences());
    expect(find.text('Cursor offset'), findsNothing);
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

  testWidgets('double tap still sends a balanced double click', (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final surface = find.byKey(const ValueKey('monitor-trackpad'));

    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(surface);
    await tester.pump(const Duration(milliseconds: 350));

    expect(events, [0, 1, 0, 1]);
  });

  testWidgets('double tap hold drags and releases when the finger lifts',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final surface = find.byKey(const ValueKey('monitor-trackpad'));
    final center = tester.getCenter(surface);

    final first = await tester.startGesture(center, pointer: 41);
    await first.up();
    await tester.pump(const Duration(milliseconds: 80));
    final second = await tester.startGesture(center, pointer: 42);
    await tester.pump(const Duration(milliseconds: 400));

    expect(events, [0, 1, 0]);
    expect(find.text('Dragging'), findsOneWidget);
    await second.moveBy(const Offset(60, 10));
    await tester.pump();
    expect(events, contains(2));
    expect(events, isNot(contains(3)));

    await second.up();
    await tester.pump();
    expect(events.last, 1);
    expect(find.text('Dragging'), findsNothing);
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

  testWidgets('gesture guide identifies Windows pointer mode and held drag',
      (tester) async {
    await show(tester);
    await tester.tap(find.byTooltip('Actions'));
    await tester.pump();
    await tester.tap(find.byTooltip('Gestures'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Windows Pointer'), findsOneWidget);
    expect(find.textContaining('Double tap and hold'), findsOneWidget);
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

  testWidgets('Keys mode exposes function keys F1 through F12', (tester) async {
    final keys = <PhysicalKeyboardKey>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          onText: (_) {},
          onKey: keys.add,
        ),
      ),
    ));

    await tester.tap(find.text('Keys'));
    await tester.pump();
    for (var i = 1; i <= 12; i++) {
      expect(find.text('F$i'), findsOneWidget);
    }
    await tester.tap(find.text('F12'));
    await tester.pump();
    expect(keys, [PhysicalKeyboardKey.f12]);
  });

  testWidgets('Text draft restores locally until explicit Send',
      (tester) async {
    final drafts = <String>[];
    final sent = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          initialText: 'unfinished note',
          onDraftChanged: drafts.add,
          onText: sent.add,
          onKey: (_) {},
        ),
      ),
    ));

    expect(find.text('unfinished note'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'still local');
    await tester.pump();
    expect(drafts.last, 'still local');
    expect(sent, isEmpty);

    await tester.tap(find.byTooltip('Send text'));
    await tester.pump();
    expect(sent, ['still local']);
    expect(drafts.last, '');
  });

  testWidgets('phone clipboard is previewed locally before Send',
      (tester) async {
    final drafts = <String>[];
    final sent = <String>[];
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return {'text': 'clipboard text'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          onDraftChanged: drafts.add,
          onText: sent.add,
          onKey: (_) {},
        ),
      ),
    ));

    await tester.tap(find.byTooltip('Paste phone clipboard'));
    await tester.pump();
    expect(find.text('clipboard text'), findsOneWidget);
    expect(drafts.last, 'clipboard text');
    expect(sent, isEmpty);
  });

  testWidgets('shortcut presets can be reordered edited and reset',
      (tester) async {
    final changes = <List<MonitorShortcutPreset>>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonitorKeyboardPanel(
          onText: (_) {},
          onKey: (_) {},
          onShortcutsChanged: (value) => changes.add(List.of(value)),
        ),
      ),
    ));

    await tester.tap(find.text('Keys'));
    await tester.pump();
    await tester.tap(find.byTooltip('Customize shortcuts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.tap(find.byTooltip('Move Ctrl+C up'));
    await tester.pump();
    expect(changes.last.first.id, 'copy');

    await tester.tap(find.byTooltip('Edit Ctrl+C'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.widgetWithText(FilterChip, 'Alt'));
    await tester.pump();
    await tester.tap(find.text('Save shortcut'));
    await tester.pump();
    expect(changes.last.first.label, 'Ctrl+Alt+C');

    await tester.tap(find.text('Reset shortcuts'));
    await tester.pump();
    expect(changes.last.map((item) => item.id).toList(),
        kDefaultMonitorShortcuts.map((item) => item.id).toList());
  });
}
