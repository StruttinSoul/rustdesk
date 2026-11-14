import 'package:flutter/services.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_key_sender.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Call = (String, bool, bool, bool, bool, bool, bool);

void main() {
  late List<_Call> calls;
  late MonitorKeySender sender;

  setUp(() {
    calls = <_Call>[];
    sender = MonitorKeySender((name,
            {required down,
            required press,
            required alt,
            required ctrl,
            required shift,
            required command}) =>
        calls.add((name, down, press, alt, ctrl, shift, command)));
  });

  test('maps strip keys to named keys', () {
    expect(monitorKeyName(PhysicalKeyboardKey.escape), 'VK_ESCAPE');
    expect(monitorKeyName(PhysicalKeyboardKey.arrowLeft), 'VK_LEFT');
    expect(monitorKeyName(PhysicalKeyboardKey.pageDown), 'VK_NEXT');
    expect(monitorKeyName(PhysicalKeyboardKey.metaLeft), 'Meta');
    expect(monitorKeyName(PhysicalKeyboardKey.keyC), 'c');
    expect(monitorKeyName(PhysicalKeyboardKey.digit7), '7');
    expect(monitorKeyName(PhysicalKeyboardKey.f5), 'VK_F5');
    expect(monitorKeyName(PhysicalKeyboardKey.audioVolumeUp), isNull);
  });

  test('maps symbol keys to their characters', () {
    expect(monitorKeyName(PhysicalKeyboardKey.minus), '-');
    expect(monitorKeyName(PhysicalKeyboardKey.equal), '=');
    expect(monitorKeyName(PhysicalKeyboardKey.bracketLeft), '[');
    expect(monitorKeyName(PhysicalKeyboardKey.bracketRight), ']');
    expect(monitorKeyName(PhysicalKeyboardKey.backslash), r'\');
    expect(monitorKeyName(PhysicalKeyboardKey.semicolon), ';');
    expect(monitorKeyName(PhysicalKeyboardKey.quote), "'");
    expect(monitorKeyName(PhysicalKeyboardKey.comma), ',');
    expect(monitorKeyName(PhysicalKeyboardKey.period), '.');
    expect(monitorKeyName(PhysicalKeyboardKey.slash), '/');
    expect(monitorKeyName(PhysicalKeyboardKey.backquote), '`');
  });

  test('Ctrl and minus sends minus with ctrl', () {
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    sender.tap(PhysicalKeyboardKey.minus);
    expect(calls.last, ('-', false, true, false, true, false, false));
  });

  test('Shift alone types the shifted character', () {
    sender.setState(PhysicalKeyboardKey.shiftLeft, true);
    sender.tap(PhysicalKeyboardKey.keyA);
    sender.tap(PhysicalKeyboardKey.digit1);
    sender.tap(PhysicalKeyboardKey.slash);
    expect(calls.skip(1).map((call) => (call.$1, call.$6)).toList(),
        [('A', true), ('!', true), ('?', true)]);
  });

  test('Ctrl then C sends c with ctrl', () {
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    sender.tap(PhysicalKeyboardKey.keyC);
    expect(calls, [
      ('VK_CONTROL', true, false, false, true, false, false),
      ('c', false, true, false, true, false, false),
    ]);
  });

  test('Ctrl and Shift both apply', () {
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    sender.setState(PhysicalKeyboardKey.shiftLeft, true);
    sender.tap(PhysicalKeyboardKey.keyT);
    expect(calls.last, ('t', false, true, false, true, true, false));
  });

  test('Win alone is a down then up', () {
    sender.setState(PhysicalKeyboardKey.metaLeft, true);
    sender.setState(PhysicalKeyboardKey.metaLeft, false);
    expect(calls, [
      ('Meta', true, false, false, false, false, true),
      ('Meta', false, false, false, false, false, false),
    ]);
  });

  test('Backspace and Enter are named', () {
    sender.tap(PhysicalKeyboardKey.backspace);
    sender.tap(PhysicalKeyboardKey.enter);
    expect(calls, [
      ('VK_BACK', false, true, false, false, false, false),
      ('VK_RETURN', false, true, false, false, false, false),
    ]);
  });

  test('releaseAll lifts every held key', () {
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    sender.setState(PhysicalKeyboardKey.altLeft, true);
    calls.clear();
    sender.releaseAll();
    expect(calls.map((call) => (call.$1, call.$2)).toList(),
        [('VK_MENU', false), ('VK_CONTROL', false)]);
    expect(sender.hasHeld, isFalse);
  });

  test('duplicate down is ignored', () {
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    sender.setState(PhysicalKeyboardKey.controlLeft, true);
    expect(calls, hasLength(1));
  });

  test('unknown keys are ignored', () {
    sender.tap(PhysicalKeyboardKey.audioVolumeUp);
    sender.setState(PhysicalKeyboardKey.audioVolumeUp, true);
    expect(calls, isEmpty);
    expect(sender.hasHeld, isFalse);
  });
}
