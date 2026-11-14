import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_live_keyboard.dart';

void main() {
  group('diffMonitorSoftKeyboardText', () {
    test('appends, deletes and replaces', () {
      expect(diffMonitorSoftKeyboardText('11ab', '11abc'),
          const MonitorSoftKeyboardEdit(0, 'c'));
      expect(diffMonitorSoftKeyboardText('11abc', '11a'),
          const MonitorSoftKeyboardEdit(2, ''));
      expect(diffMonitorSoftKeyboardText('11teh', '11the '),
          const MonitorSoftKeyboardEdit(2, 'he '));
      expect(diffMonitorSoftKeyboardText('11', '11'),
          const MonitorSoftKeyboardEdit(0, ''));
    });

    test('never splits an emoji', () {
      expect(diffMonitorSoftKeyboardText('11😀', '11'),
          const MonitorSoftKeyboardEdit(1, ''));
      expect(diffMonitorSoftKeyboardText('11😀', '11😁'),
          const MonitorSoftKeyboardEdit(1, '😁'));
    });
  });

  test('characters map to US physical keys for chords', () {
    expect(monitorPhysicalKeyForCharacter('c'), PhysicalKeyboardKey.keyC);
    expect(monitorPhysicalKeyForCharacter('C'), PhysicalKeyboardKey.keyC);
    expect(monitorPhysicalKeyForCharacter('7'), PhysicalKeyboardKey.digit7);
    expect(monitorPhysicalKeyForCharacter('/'), PhysicalKeyboardKey.slash);
    expect(monitorPhysicalKeyForCharacter('é'), isNull);
    expect(monitorPhysicalKeyForCharacter('ab'), isNull);
  });

  Future<GlobalKey<MonitorLiveKeyboardBarState>> show(WidgetTester tester,
      {List<String>? text,
      List<PhysicalKeyboardKey>? keys,
      List<String>? states,
      VoidCallback? onClose,
      bool enabled = true,
      List<MonitorLiveShortcut> shortcuts = const []}) async {
    final key = GlobalKey<MonitorLiveKeyboardBarState>();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: MonitorLiveKeyboardBar(
            key: key,
            enabled: enabled,
            onText: (value) => text?.add(value),
            onKey: (value) => keys?.add(value),
            onKeyState: (value, down) =>
                states?.add('${value.debugName}:$down'),
            onClose: onClose ?? () {},
            shortcuts: shortcuts,
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));
    return key;
  }

  final input = find.byKey(const ValueKey('monitor-live-keyboard-input'));

  testWidgets('typing streams text, Enter and Backspace', (tester) async {
    final text = <String>[];
    final keys = <PhysicalKeyboardKey>[];
    await show(tester, text: text, keys: keys);
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}ok\n');
    expect(text, ['ok']);
    expect(keys, [PhysicalKeyboardKey.enter]);
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}o');
    expect(keys.last, PhysicalKeyboardKey.backspace);
  });

  testWidgets('modifiers: tap for next key, tap again to lock, again to release',
      (tester) async {
    final keys = <PhysicalKeyboardKey>[];
    final states = <String>[];
    final bar = await show(tester, keys: keys, states: states);
    const ctrl = PhysicalKeyboardKey.controlLeft;

    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    expect(bar.currentState!.stickyState(ctrl), MonitorStickyState.once);
    await tester.tap(find.byTooltip('Esc'));
    await tester.pump();
    expect(keys, [PhysicalKeyboardKey.escape]);
    expect(states, ['Control Left:true', 'Control Left:false']);
    expect(bar.currentState!.stickyState(ctrl), MonitorStickyState.off);

    states.clear();
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    expect(bar.currentState!.stickyState(ctrl), MonitorStickyState.locked);
    await tester.tap(find.byTooltip('Tab'));
    await tester.tap(find.byTooltip('Tab'));
    await tester.pump();
    expect(states, ['Control Left:true']);
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    expect(states, ['Control Left:true', 'Control Left:false']);
    expect(bar.currentState!.stickyState(ctrl), MonitorStickyState.off);
  });

  testWidgets('a held modifier turns typed letters into chords',
      (tester) async {
    final text = <String>[];
    final keys = <PhysicalKeyboardKey>[];
    final states = <String>[];
    await show(tester, text: text, keys: keys, states: states);
    await tester.tap(find.byTooltip('Ctrl'));
    await tester.pump();
    await tester.enterText(input, '${kMonitorSoftKeyboardSentinel}S');
    expect(text, isEmpty);
    expect(keys, [PhysicalKeyboardKey.keyS]);
    expect(states, [
      'Control Left:true',
      'Shift Left:true',
      'Shift Left:false',
      'Control Left:false',
    ]);
  });

  testWidgets('arrows repeat while held', (tester) async {
    final keys = <PhysicalKeyboardKey>[];
    await show(tester, keys: keys);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byTooltip('Left arrow')));
    await tester.pump(const Duration(milliseconds: 520));
    await tester.pump(const Duration(milliseconds: 250));
    await gesture.up();
    await tester.pump();
    final count = keys.length;
    expect(count, greaterThanOrEqualTo(3));
    expect(keys.toSet(), {PhysicalKeyboardKey.arrowLeft});
    await tester.pump(const Duration(milliseconds: 300));
    expect(keys.length, count);
  });

  testWidgets('function keys and shortcut presets', (tester) async {
    final keys = <PhysicalKeyboardKey>[];
    final states = <String>[];
    await show(tester, keys: keys, states: states, shortcuts: const [
      MonitorLiveShortcut(
          label: 'Ctrl+V',
          modifiers: [PhysicalKeyboardKey.controlLeft],
          key: PhysicalKeyboardKey.keyV),
    ]);
    expect(find.byTooltip('F5'), findsNothing);
    final keyRow = find
        .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
        .first;
    await tester.scrollUntilVisible(find.byTooltip('Function keys'), 200,
        scrollable: keyRow);
    await tester.tap(find.byTooltip('Function keys'));
    await tester.pump();
    await tester.scrollUntilVisible(find.byTooltip('F5'), 200,
        scrollable: keyRow);
    await tester.tap(find.byTooltip('F5'));
    expect(keys, [PhysicalKeyboardKey.f5]);
    await tester.scrollUntilVisible(find.byTooltip('Ctrl+V'), 200,
        scrollable: keyRow);
    await tester.tap(find.byTooltip('Ctrl+V'));
    expect(keys.last, PhysicalKeyboardKey.keyV);
    expect(states, ['Control Left:true', 'Control Left:false']);
  });

  testWidgets('held modifiers are released when input is disabled or closed',
      (tester) async {
    final states = <String>[];
    await show(tester, states: states);
    await tester.tap(find.byTooltip('Alt'));
    await tester.pump();
    await show(tester, states: states, enabled: false);
    expect(states, ['Alt Left:true', 'Alt Left:false']);
  });
}
