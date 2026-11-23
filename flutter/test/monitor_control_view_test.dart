import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_control_view.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_live_keyboard.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';

import 'support/fake_translate.dart';

void main() {
  Future<void> show(WidgetTester tester,
      {bool control = true,
      void Function(int, Offset)? pointer,
      ValueChanged<int>? scroll,
      ValueChanged<Offset>? smoothScroll,
      MonitorControlPreferences preferences = const MonitorControlPreferences(),
      ValueChanged<MonitorControlPreferences>? onPreferencesChanged,
      VoidCallback? ctrlAltDel,
      VoidCallback? restartTaskbar,
      VoidCallback? switchView,
      VoidCallback? dashboard,
      VoidCallback? keyboard,
      ValueChanged<String>? text,
      ValueChanged<PhysicalKeyboardKey>? key,
      void Function(PhysicalKeyboardKey, bool)? keyState,
      ValueChanged<bool>? softKeyboard,
      String? frameStatus,
      Size desktopSize = const Size(3840, 2160),
      VoidCallback? clipboard,
      VoidCallback? windows,
      VoidCallback? quality,
      bool localViewOnly = false,
      ThemeData? theme}) async {
    await tester.pumpWidget(MaterialApp(
        theme: theme ?? ThemeData(splashFactory: NoSplash.splashFactory),
        home: Scaffold(
            resizeToAvoidBottomInset: false,
            body: MonitorControlView(
              tr: fakeTr,
              desktopSize: desktopSize,
              localViewOnly: localViewOnly,
              onClipboard: clipboard,
              onWindows: windows,
              onSessionStatus: quality,
              canControl: control,
              preferences: preferences,
              onPreferencesChanged: onPreferencesChanged,
              onPointer: pointer ?? (_, __) {},
              onScroll: scroll ?? (_) {},
              onSmoothScroll: smoothScroll,
              onKeyboard: keyboard ?? () {},
              onTextInput: text,
              onKeyTap: key,
              onKeyState: keyState,
              onSoftKeyboard: softKeyboard,
              onSwitchView: switchView,
              onDashboard: dashboard,
              frameStatus: frameStatus,
              onCtrlAltDel: ctrlAltDel,
              onRestartTaskbar: restartTaskbar,
            ))));
  }

  final surface = find.byKey(const ValueKey('monitor-surface'));
  final frame = find.byKey(const ValueKey('monitor-frame'));

  Future<void> openControls(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Controls'));
    await tester.pump();
  }

  /// Desktop pixel shown at a global screen position.
  Offset desktopAt(WidgetTester tester, Offset global) {
    final rect = tester.getRect(frame);
    return Offset((global.dx - rect.left) / rect.width * 3840,
        (global.dy - rect.top) / rect.height * 2160);
  }

  for (final size in [const Size(798, 384), const Size(384, 832)]) {
    testWidgets('Fit uses the available screen at $size with controls visible',
        (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      var switches = 0;
      await show(tester, switchView: () => switches++, dashboard: () {});
      final frameRect = tester.getRect(frame);
      if (size.width > size.height) {
        expect(frameRect.height, closeTo(size.height, 0.01));
      } else {
        expect(frameRect.width, closeTo(size.width, 0.01));
      }
      for (final tooltip in const [
        'Fit view',
        'Readable view',
        'Keyboard',
        'Controls',
        'Switch view',
        'Exit',
      ]) {
        final control = find.byTooltip(tooltip);
        expect(control.hitTestable(), findsOneWidget, reason: tooltip);
        final button = find.ancestor(
            of: control,
            matching: find.byWidgetPredicate(
                (widget) => widget is IconButton || widget is PopupMenuButton));
        final rect =
            tester.getRect(button.evaluate().isEmpty ? control : button.first);
        expect(rect.width, greaterThanOrEqualTo(48), reason: tooltip);
        expect(rect.height, greaterThanOrEqualTo(48), reason: tooltip);
        expect(rect.overlaps(frameRect), isFalse, reason: tooltip);
      }
      await tester.tap(find.byTooltip('Switch view'));
      expect(switches, 1);
      expect(find.byKey(const ValueKey('monitor-top-bar')), findsNothing);
      if (size.width < size.height) {
        expect(tester.getCenter(find.byTooltip('Exit')).dx,
            lessThan(tester.getCenter(find.byTooltip('Fit view')).dx));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('the picture gains the old top bar height', (tester) async {
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester,
        // Tall enough that the height, not the width, limits the picture.
        desktopSize: const Size(1080, 2400),
        dashboard: () {},
        switchView: () {});
    final toolbar =
        tester.getSize(find.byKey(const ValueKey('monitor-toolbar')));
    expect(tester.getSize(frame).height, closeTo(832 - toolbar.height, 0.5));
  });

  testWidgets('session actions live in the Controls panel', (tester) async {
    var clipboards = 0, windows = 0, qualities = 0;
    await show(tester,
        clipboard: () => clipboards++,
        windows: () => windows++,
        quality: () => qualities++);
    final panel = find.byKey(const ValueKey('monitor-controls-panel'));
    await openControls(tester);
    await tester.tap(find.byTooltip('Clipboard'));
    await tester.pump();
    expect(clipboards, 1);
    expect(panel, findsNothing);
    await openControls(tester);
    await tester.tap(find.byTooltip('Windows'));
    await tester.pump();
    expect(windows, 1);
    expect(panel, findsNothing);
    await openControls(tester);
    await tester.tap(find.byTooltip('Quality and connection'));
    await tester.pump();
    expect(qualities, 1);
    expect(panel, findsNothing);
    expect(find.byTooltip('Session controls'), findsNothing);
  });

  testWidgets('Controls omit session actions the page does not offer',
      (tester) async {
    await show(tester);
    await openControls(tester);
    expect(find.byTooltip('Clipboard'), findsNothing);
    expect(find.byTooltip('Windows'), findsNothing);
    expect(find.byTooltip('Quality and connection'), findsNothing);
    expect(find.byTooltip('Hide toolbar'), findsOneWidget);
  });

  testWidgets('Controls header shows resolution and view', (tester) async {
    await show(tester);
    await openControls(tester);
    expect(
        find.descendant(
            of: find.byKey(const ValueKey('monitor-panel-header')),
            matching: find.text('3840 × 2160 · Fit')),
        findsOneWidget);
  });

  testWidgets('Hide toolbar from Controls, then show it again', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await openControls(tester);
    await tester.tap(find.byTooltip('Hide toolbar'));
    await tester.pump();
    expect(changes.last.toolbarVisible, isFalse);
    expect(find.byTooltip('Keyboard'), findsNothing);
    expect(find.byKey(const ValueKey('monitor-controls-panel')), findsNothing);
    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pump();
    expect(changes.last.toolbarVisible, isTrue);
    expect(find.byTooltip('Keyboard'), findsOneWidget);
  });

  testWidgets('view only stays visible without the top bar', (tester) async {
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final chip = find.byKey(const ValueKey('monitor-view-only-chip'));
    await show(tester, localViewOnly: true);
    expect(chip, findsOneWidget);
    expect(find.descendant(of: chip, matching: find.text('View only')),
        findsOneWidget);
    expect(
        tester.getRect(chip).overlaps(
            tester.getRect(find.byKey(const ValueKey('monitor-toolbar')))),
        isFalse);
    await show(tester);
    expect(chip, findsNothing);
  });

  testWidgets('chrome over the picture stays dark in a light app',
      (tester) async {
    await show(tester, theme: MirpgRemoteTheme.build(ThemeData.light()));
    final toolbar = find.byKey(const ValueKey('monitor-toolbar'));
    expect(tester.widget<Material>(toolbar).color,
        MirpgStudioPalette.dark.background);
    await openControls(tester);
    expect(
        tester
            .widget<Material>(
                find.byKey(const ValueKey('monitor-controls-panel')))
            .color,
        MirpgStudioPalette.dark.surface);
  });

  testWidgets('stale video is visibly marked while controls stay disabled',
      (tester) async {
    await show(tester,
        control: false, frameStatus: 'Last frame · waiting for fresh video');
    expect(find.text('Last frame · waiting for fresh video'), findsOneWidget);
    final keyboardButton = find.descendant(
        of: find.byTooltip('Keyboard'), matching: find.byType(InkWell));
    expect(tester.widget<InkWell>(keyboardButton).onTap, isNull);
  });

  testWidgets('remote chrome fits a 360dp phone and keeps full touch targets',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await show(tester);
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final tooltip in const [
      'Fit view',
      'Readable view',
      'Keyboard',
      'Controls',
      'Switch view',
    ]) {
      final size = tester.getSize(find.byTooltip(tooltip));
      expect(size.width, greaterThanOrEqualTo(48), reason: tooltip);
      expect(size.height, greaterThanOrEqualTo(48), reason: tooltip);
    }
  });

  test('monitor preferences round trip and ignore retired mouse settings', () {
    const preferences = MonitorControlPreferences(
      preferredView: MonitorViewPreference.readable,
      toolbarDock: MonitorToolbarDock.left,
      toolbarVisible: false,
      thumbwheelVisible: true,
      orientation: MonitorOrientationPreference.portrait,
    );
    expect(
        MonitorControlPreferences.fromJson(preferences.toJson()), preferences);
    expect(
        MonitorControlPreferences.fromJson({
          'inputMode': 'mouse',
          'precision': true,
          'precisionGain': 0.2,
          'cursorOffset': true,
          'mouseButtons': true,
        }),
        const MonitorControlPreferences());
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

  testWidgets('there is no on-screen pointer to steer', (tester) async {
    await show(tester);
    expect(find.byIcon(Icons.north_west), findsNothing);
    expect(find.byTooltip('Input mode: Mouse'), findsNothing);
    expect(find.byTooltip('Precision mode'), findsNothing);
  });

  testWidgets('tap clicks exactly where the finger touches', (tester) async {
    final events = <int>[];
    final points = <Offset>[];
    await show(tester, pointer: (action, point) {
      events.add(action);
      points.add(point);
    });
    final target = tester.getRect(frame).topLeft + const Offset(200, 100);
    await tester.tapAt(target);
    await tester.pump();
    expect(events, [2, 0, 1]);
    final expected = desktopAt(tester, target);
    expect(points.first.dx, closeTo(expected.dx, 6));
    expect(points.first.dy, closeTo(expected.dy, 6));
    expect(points.toSet().length, 1);
  });

  testWidgets('a quick second tap reuses the first position to double-click',
      (tester) async {
    final moves = <Offset>[];
    final events = <int>[];
    await show(tester, pointer: (action, point) {
      events.add(action);
      if (action == 2) moves.add(point);
    });
    final center = tester.getCenter(surface);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tapAt(center + const Offset(6, 4));
    await tester.pump();
    expect(events, [2, 0, 1, 2, 0, 1]);
    expect(moves[1], moves[0]);
  });

  testWidgets('taps in the black bars around the desktop are ignored',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(384, 832));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final surfaceRect = tester.getRect(surface);
    final frameRect = tester.getRect(frame);
    expect(frameRect.top, greaterThan(surfaceRect.top + 20));
    await tester.tapAt(surfaceRect.topLeft + const Offset(40, 8));
    await tester.pump();
    expect(events, isEmpty);
  });

  testWidgets('one-finger drag moves the zoomed view without remote input',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    await tester.tap(find.byTooltip('Readable view'));
    await tester.pump();
    final before = tester.getTopLeft(frame);
    await tester.drag(surface, const Offset(120, 60));
    await tester.pump();
    expect(tester.getTopLeft(frame), isNot(before));
    expect(tester.getTopLeft(frame).dx, greaterThan(before.dx));
    expect(events, isEmpty);
    expect(scroll, isEmpty);
  });

  testWidgets('touch, hold, then drag holds the left button until lift',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 600));
    expect(events, isEmpty);
    expect(find.text('Drag to hold the button · lift to right-click'),
        findsOneWidget);
    await gesture.moveBy(const Offset(40, 0));
    await gesture.moveBy(const Offset(40, 10));
    await tester.pump();
    expect(find.text('Dragging'), findsOneWidget);
    await gesture.up();
    await tester.pump();
    expect(events.first, 2);
    expect(events.where((e) => e == 0).length, 1);
    expect(events.where((e) => e == 1).length, 1);
    expect(events.last, 1);
    expect(events, isNot(contains(3)));
    expect(find.text('Dragging'), findsNothing);
  });

  testWidgets('touch, hold, then lift right-clicks at the finger',
      (tester) async {
    final events = <int>[];
    final points = <Offset>[];
    await show(tester, pointer: (action, point) {
      events.add(action);
      points.add(point);
    });
    final target = tester.getRect(frame).topLeft + const Offset(300, 120);
    final gesture = await tester.startGesture(target);
    await tester.pump(const Duration(milliseconds: 600));
    expect(events, isEmpty);
    await gesture.up();
    await tester.pump();
    expect(events, [2, 3]);
    final expected = desktopAt(tester, target);
    expect(points.first.dx, closeTo(expected.dx, 6));
    expect(points.first.dy, closeTo(expected.dy, 6));
  });

  testWidgets('two-finger tap right-clicks without a left click',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final center = tester.getCenter(surface);
    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 11);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 12);
    await one.up();
    await two.up();
    await tester.pump();
    expect(events, contains(3));
    expect(events, isNot(contains(0)));
    expect(events, isNot(contains(1)));
  });

  Future<void> twoFingerDrag(WidgetTester tester, Offset step,
      {int steps = 4}) async {
    final center = tester.getCenter(surface);
    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 21);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 22);
    for (var i = 0; i < steps; i++) {
      await one.moveBy(step);
      await two.moveBy(step);
    }
    await one.up();
    await two.up();
    await tester.pump();
  }

  testWidgets('two-finger drag at Fit scrolls Windows without clicking',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    await twoFingerDrag(tester, const Offset(0, 15));
    expect(scroll, isNotEmpty);
    expect(scroll.every((steps) => steps > 0), isTrue);
    expect(events, isEmpty);
  });

  testWidgets('Windows hosts get smooth pixel scrolling', (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    final smooth = <Offset>[];
    await show(tester,
        pointer: (action, _) => events.add(action),
        scroll: scroll.add,
        smoothScroll: smooth.add);
    await twoFingerDrag(tester, const Offset(0, -15));
    await tester.pump(const Duration(seconds: 2));
    expect(smooth, isNotEmpty);
    expect(smooth.every((units) => units.dy < 0 && units.dx == 0), isTrue);
    expect(scroll, isEmpty);
    expect(events, isEmpty);
  });

  testWidgets('two-finger drag scrolls Windows even when zoomed in',
      (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        pointer: (action, _) => events.add(action), scroll: scroll.add);
    await tester.tap(find.byTooltip('Readable view'));
    await tester.pump();
    final before = tester.getTopLeft(frame);
    await twoFingerDrag(tester, const Offset(0, 20));
    expect(scroll, isNotEmpty);
    expect(tester.getTopLeft(frame), before);
    expect(events, isEmpty);
  });

  testWidgets('pinch zooms the view around the fingers', (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final before = tester.getSize(frame).width;
    final center = tester.getCenter(surface);
    final one =
        await tester.startGesture(center - const Offset(30, 0), pointer: 31);
    final two =
        await tester.startGesture(center + const Offset(30, 0), pointer: 32);
    for (var i = 0; i < 3; i++) {
      await one.moveBy(const Offset(-20, 0));
      await two.moveBy(const Offset(20, 0));
    }
    await one.up();
    await two.up();
    await tester.pump();
    expect(tester.getSize(frame).width, greaterThan(before));
    expect(events, isEmpty);
    expect(find.byKey(const ValueKey('monitor-minimap')), findsNothing);
  });

  testWidgets('Readable preset enlarges Windows without a minimap',
      (tester) async {
    await show(tester);
    final before = tester.getSize(frame).width;
    await tester.tap(find.byTooltip('Readable view'));
    await tester.pump();
    expect(tester.getSize(frame).width, greaterThan(before));
    expect(find.byKey(const ValueKey('monitor-minimap')), findsNothing);
  });

  testWidgets('thumbwheel scrolls without clicking', (tester) async {
    final events = <int>[];
    final scroll = <int>[];
    await show(tester,
        preferences: const MonitorControlPreferences(thumbwheelVisible: true),
        pointer: (action, _) => events.add(action),
        scroll: scroll.add);
    await tester.drag(
        find.byKey(const ValueKey('monitor-thumbwheel')), const Offset(0, 60));
    await tester.pump();
    expect(scroll, isNotEmpty);
    expect(events, isEmpty);
  });

  testWidgets('Controls lists labelled actions and runs Ctrl+Alt+Del',
      (tester) async {
    var ctrlAltDel = 0;
    var dashboards = 0;
    await show(tester,
        ctrlAltDel: () => ctrlAltDel++, dashboard: () => dashboards++);
    await openControls(tester);
    for (final tooltip in const [
      'Right click',
      'Middle click',
      'Zoom in',
      'Zoom out',
      'Orientation: Auto',
      'Show thumbwheel',
      'View only',
      'Dock controls left',
      'Gestures',
      'Reset controls',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget, reason: tooltip);
    }
    expect(find.text('Right-click next tap'), findsOneWidget);
    await tester.tap(find.byTooltip('Ctrl+Alt+Del'));
    expect(ctrlAltDel, 1);
    await tester.tap(find.byTooltip('Exit'));
    expect(dashboards, 1);
  });

  testWidgets('Controls restarts the PC taskbar', (tester) async {
    var restarts = 0;
    await show(tester, restartTaskbar: () => restarts++);
    await openControls(tester);
    await tester.tap(find.byTooltip('Restart taskbar'));
    expect(restarts, 1);
  });

  testWidgets('Restart taskbar is hidden when the PC does not offer it',
      (tester) async {
    await show(tester);
    await openControls(tester);
    expect(find.byTooltip('Restart taskbar'), findsNothing);
  });

  testWidgets('Restart taskbar is unavailable without control', (tester) async {
    var restarts = 0;
    await show(tester, control: false, restartTaskbar: () => restarts++);
    await openControls(tester);
    await tester.tap(find.byTooltip('Restart taskbar'), warnIfMissed: false);
    expect(restarts, 0);
  });

  testWidgets('Right click arms the next tap', (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await openControls(tester);
    await tester.tap(find.byTooltip('Right click'));
    await tester.pump();
    expect(find.byKey(const ValueKey('monitor-controls-panel')), findsNothing);
    expect(find.text('Next tap right-clicks'), findsOneWidget);
    await tester.tapAt(tester.getCenter(surface));
    await tester.pump();
    expect(events, [2, 3]);
    expect(find.text('Next tap right-clicks'), findsNothing);
  });

  testWidgets('zoom buttons report the local zoom level', (tester) async {
    await show(tester);
    await openControls(tester);
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    expect(find.text('1.25× Fit'), findsWidgets);
  });

  testWidgets('toolbar can dock left and right', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await openControls(tester);
    await tester.tap(find.byTooltip('Dock controls left'));
    await tester.pump();
    expect(changes.last.toolbarDock, MonitorToolbarDock.left);
    expect(find.byTooltip('Dock controls right'), findsOneWidget);
  });

  testWidgets('orientation preference is reported from Controls',
      (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester, onPreferencesChanged: changes.add);
    await openControls(tester);
    await tester.tap(find.byTooltip('Orientation: Auto'));
    await tester.pump();
    expect(changes.last.orientation, MonitorOrientationPreference.portrait);
  });

  testWidgets('rotation releases a held drag', (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    await openControls(tester);
    final surfaceRect = tester.getRect(surface);
    final gesture = await tester.startGesture(
        surfaceRect.topLeft + Offset(surfaceRect.width / 2, 60),
        pointer: 51);
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(events, contains(0));
    await tester.tap(find.byTooltip('Orientation: Auto'));
    await tester.pump();
    expect(events.last, 1);
    final count = events.length;
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    await tester.pump();
    expect(events.length, count);
  });

  testWidgets('a held drag releases when control becomes unavailable',
      (tester) async {
    final events = <int>[];
    await show(tester, pointer: (action, _) => events.add(action));
    final gesture = await tester.startGesture(tester.getCenter(surface));
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    expect(events, contains(0));
    await show(tester,
        control: false, pointer: (action, _) => events.add(action));
    expect(events.last, 1);
    await gesture.up();
    await tester.pump();
    expect(events.where((e) => e == 1).length, 1);
  });

  testWidgets('reset controls restores the persisted defaults', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester,
        preferences: const MonitorControlPreferences(
            thumbwheelVisible: true, toolbarDock: MonitorToolbarDock.left),
        onPreferencesChanged: changes.add);
    await openControls(tester);
    await tester.tap(find.byTooltip('Reset controls'));
    await tester.pump();
    expect(changes.last, const MonitorControlPreferences());
  });

  testWidgets('gesture guide explains direct touch', (tester) async {
    await show(tester);
    await openControls(tester);
    await tester.tap(find.byTooltip('Gestures'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Touch Windows directly'), findsOneWidget);
    expect(find.text('Touch and hold'), findsOneWidget);
    expect(find.text('Two fingers'), findsOneWidget);
  });

  testWidgets('hidden toolbar can be shown again', (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester,
        preferences: const MonitorControlPreferences(toolbarVisible: false),
        onPreferencesChanged: changes.add);
    expect(find.byTooltip('Keyboard'), findsNothing);
    await tester.tap(find.byTooltip('Show toolbar'));
    await tester.pump();
    expect(find.byTooltip('Keyboard'), findsOneWidget);
    expect(changes.last.toolbarVisible, isTrue);
  });

  testWidgets('Keyboard falls back to the compose sheet without live input',
      (tester) async {
    var composes = 0;
    await show(tester, keyboard: () => composes++);
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump();
    expect(composes, 1);
    expect(find.byKey(const ValueKey('monitor-live-keyboard')), findsNothing);
  });

  group('typing keeps the PC visible', () {
    test('pan keeps a low tap above the keyboard', () {
      expect(
          monitorKeyboardPanDy(
              offsetDy: 0, scale: 1, tapDesktopY: 500, visibleHeight: 300),
          300 - 24 - 500);
    });

    test('pan leaves a visible tap alone', () {
      expect(
          monitorKeyboardPanDy(
              offsetDy: 0, scale: 1, tapDesktopY: 100, visibleHeight: 300),
          0);
    });

    test('pan brings a tap above the top back down', () {
      expect(
          monitorKeyboardPanDy(
              offsetDy: -400, scale: 1, tapDesktopY: 100, visibleHeight: 300),
          24 - 100);
    });

    const portrait = Size(384, 832);
    final bar = find.byType(MonitorLiveKeyboardBar);
    final topBar = find.byKey(const ValueKey('monitor-toolbar'));

    Future<List<Offset>> openTyping(WidgetTester tester,
        {double inset = 300}) async {
      await tester.binding.setSurfaceSize(portrait);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(tester.view.resetViewInsets);
      final points = <Offset>[];
      await show(tester,
          pointer: (_, point) => points.add(point),
          text: (_) {},
          key: (_) {},
          keyState: (_, __) {});
      await tester.tap(find.byTooltip('Keyboard'));
      await tester.pump(const Duration(milliseconds: 200));
      tester.view.viewInsets =
          FakeViewPadding(bottom: inset * tester.view.devicePixelRatio);
      await tester.pump();
      await tester.pump();
      return points;
    }

    double screenY(WidgetTester tester, Offset desktop) {
      final rect = tester.getRect(frame);
      return rect.top + desktop.dy / 2160 * rect.height;
    }

    testWidgets('typing hides the toolbar and keeps the picture size',
        (tester) async {
      await tester.binding.setSurfaceSize(portrait);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await show(tester, text: (_) {}, key: (_) {}, keyState: (_, __) {});
      expect(topBar, findsOneWidget);
      final before = tester.getSize(frame);
      await openTyping(tester);
      expect(topBar, findsNothing);
      expect(tester.getSize(frame), before);
    });

    testWidgets('key strip sits on the phone keyboard', (tester) async {
      await openTyping(tester);
      expect(tester.getRect(bar).bottom, portrait.height - 300);
    });

    testWidgets('tap near the bottom scrolls above the keyboard',
        (tester) async {
      final points = await openTyping(tester);
      final rect = tester.getRect(frame);
      final lowest = math.min(rect.bottom, tester.getRect(bar).top) - 4;
      await tester.tapAt(Offset(rect.center.dx, lowest));
      await tester.pump(const Duration(milliseconds: 400));
      expect(points, isNotEmpty);
      expect(screenY(tester, points.last),
          lessThanOrEqualTo(tester.getRect(bar).top - 23));
    });

    testWidgets('keyboard height change re-pans without rescaling',
        (tester) async {
      final points = await openTyping(tester);
      final size = tester.getSize(frame);
      final rect = tester.getRect(frame);
      final lowest = math.min(rect.bottom, tester.getRect(bar).top) - 4;
      await tester.tapAt(Offset(rect.center.dx, lowest));
      await tester.pump(const Duration(milliseconds: 400));
      tester.view.viewInsets =
          FakeViewPadding(bottom: 200 * tester.view.devicePixelRatio);
      await tester.pump();
      await tester.pump();
      expect(tester.getSize(frame), size);
      expect(screenY(tester, points.last), lessThan(tester.getRect(bar).top));
    });

    testWidgets('closing the keyboard restores the toolbar', (tester) async {
      await openTyping(tester);
      await tester.tap(find.byTooltip('Close keyboard'));
      await tester.pump();
      expect(topBar, findsOneWidget);
    });
  });

  testWidgets('live keyboard types straight into Windows', (tester) async {
    final typed = <String>[];
    final keys = <PhysicalKeyboardKey>[];
    final states = <String>[];
    final soft = <bool>[];
    var composes = 0;
    await show(tester,
        keyboard: () => composes++,
        text: typed.add,
        key: keys.add,
        keyState: (key, down) => states.add('${key.debugName}:$down'),
        softKeyboard: soft.add);
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(soft, [true]);
    expect(find.byKey(const ValueKey('monitor-live-keyboard')), findsOneWidget);
    expect(find.byTooltip('Readable view'), findsNothing);

    final input = find.byKey(const ValueKey('monitor-live-keyboard-input'));
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}hi');
    expect(typed, ['hi']);
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}h');
    expect(keys, [PhysicalKeyboardKey.backspace]);

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}hc');
    expect(keys.last, PhysicalKeyboardKey.keyC);
    expect(typed, ['hi']);
    expect(states, ['Control Left:true', 'Control Left:false']);

    await tester.tap(find.byTooltip('Close keyboard'));
    await tester.pump();
    expect(composes, 0);
    expect(soft, [true, false]);
    expect(find.byKey(const ValueKey('monitor-live-keyboard')), findsNothing);
    expect(find.byTooltip('Readable view'), findsOneWidget);
  });

  testWidgets('live keyboard has no compose button', (tester) async {
    await show(tester, text: (_) {}, key: (_) {}, keyState: (_, __) {});
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byTooltip('Compose text'), findsNothing);
  });

  testWidgets('Shortcuts opens shortcut presets and saves edits',
      (tester) async {
    final changes = <MonitorControlPreferences>[];
    await show(tester,
        text: (_) {},
        key: (_) {},
        keyState: (_, __) {},
        onPreferencesChanged: changes.add);
    await tester.tap(find.byTooltip('Keyboard'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.tap(find.byTooltip('Shortcuts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Shortcut presets'), findsOneWidget);
    await tester.tap(find.byTooltip('Move Ctrl+C up'));
    await tester.pump();
    expect(changes.last.shortcuts.first.id, 'copy');
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
