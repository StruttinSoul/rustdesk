import 'package:flutter/services.dart';

/// Sends one named key to the remote PC (`bind.sessionInputKey`).
typedef MonitorNamedKeySink = void Function(String name,
    {required bool down,
    required bool press,
    required bool alt,
    required bool ctrl,
    required bool shift,
    required bool command});

final Map<PhysicalKeyboardKey, String> _namedKeys =
    <PhysicalKeyboardKey, String>{
  PhysicalKeyboardKey.escape: 'VK_ESCAPE',
  PhysicalKeyboardKey.tab: 'VK_TAB',
  PhysicalKeyboardKey.enter: 'VK_RETURN',
  PhysicalKeyboardKey.numpadEnter: 'VK_RETURN',
  PhysicalKeyboardKey.backspace: 'VK_BACK',
  PhysicalKeyboardKey.delete: 'VK_DELETE',
  PhysicalKeyboardKey.insert: 'VK_INSERT',
  PhysicalKeyboardKey.home: 'VK_HOME',
  PhysicalKeyboardKey.end: 'VK_END',
  PhysicalKeyboardKey.pageUp: 'VK_PRIOR',
  PhysicalKeyboardKey.pageDown: 'VK_NEXT',
  PhysicalKeyboardKey.arrowLeft: 'VK_LEFT',
  PhysicalKeyboardKey.arrowUp: 'VK_UP',
  PhysicalKeyboardKey.arrowRight: 'VK_RIGHT',
  PhysicalKeyboardKey.arrowDown: 'VK_DOWN',
  PhysicalKeyboardKey.space: 'VK_SPACE',
  PhysicalKeyboardKey.f1: 'VK_F1',
  PhysicalKeyboardKey.f2: 'VK_F2',
  PhysicalKeyboardKey.f3: 'VK_F3',
  PhysicalKeyboardKey.f4: 'VK_F4',
  PhysicalKeyboardKey.f5: 'VK_F5',
  PhysicalKeyboardKey.f6: 'VK_F6',
  PhysicalKeyboardKey.f7: 'VK_F7',
  PhysicalKeyboardKey.f8: 'VK_F8',
  PhysicalKeyboardKey.f9: 'VK_F9',
  PhysicalKeyboardKey.f10: 'VK_F10',
  PhysicalKeyboardKey.f11: 'VK_F11',
  PhysicalKeyboardKey.f12: 'VK_F12',
  PhysicalKeyboardKey.controlLeft: 'VK_CONTROL',
  PhysicalKeyboardKey.controlRight: 'VK_CONTROL',
  PhysicalKeyboardKey.altLeft: 'VK_MENU',
  PhysicalKeyboardKey.altRight: 'VK_MENU',
  PhysicalKeyboardKey.shiftLeft: 'VK_SHIFT',
  PhysicalKeyboardKey.shiftRight: 'VK_SHIFT',
  PhysicalKeyboardKey.metaLeft: 'Meta',
  PhysicalKeyboardKey.metaRight: 'Meta',
};

const List<PhysicalKeyboardKey> _letters = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.keyA, PhysicalKeyboardKey.keyB, PhysicalKeyboardKey.keyC,
  PhysicalKeyboardKey.keyD, PhysicalKeyboardKey.keyE, PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG, PhysicalKeyboardKey.keyH, PhysicalKeyboardKey.keyI,
  PhysicalKeyboardKey.keyJ, PhysicalKeyboardKey.keyK, PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.keyM, PhysicalKeyboardKey.keyN, PhysicalKeyboardKey.keyO,
  PhysicalKeyboardKey.keyP, PhysicalKeyboardKey.keyQ, PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyS, PhysicalKeyboardKey.keyT, PhysicalKeyboardKey.keyU,
  PhysicalKeyboardKey.keyV, PhysicalKeyboardKey.keyW, PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyY, PhysicalKeyboardKey.keyZ, //
];

const List<PhysicalKeyboardKey> _digits = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.digit0, PhysicalKeyboardKey.digit1,
  PhysicalKeyboardKey.digit2, PhysicalKeyboardKey.digit3,
  PhysicalKeyboardKey.digit4, PhysicalKeyboardKey.digit5,
  PhysicalKeyboardKey.digit6, PhysicalKeyboardKey.digit7,
  PhysicalKeyboardKey.digit8, PhysicalKeyboardKey.digit9, //
];

/// The name the remote input path knows [key] by, or null if it has none.
String? monitorKeyName(PhysicalKeyboardKey key) {
  final named = _namedKeys[key];
  if (named != null) return named;
  final letter = _letters.indexOf(key);
  if (letter >= 0) return String.fromCharCode(0x61 + letter);
  final digit = _digits.indexOf(key);
  if (digit >= 0) return '$digit';
  return null;
}

/// Sends the phone's remote keyboard to Windows as named keys, with any held
/// Ctrl/Alt/Shift/Win carried on every event so the PC never drops them.
class MonitorKeySender {
  MonitorKeySender(this._sink);

  final MonitorNamedKeySink _sink;
  final List<PhysicalKeyboardKey> _held = <PhysicalKeyboardKey>[];

  bool get hasHeld => _held.isNotEmpty;

  bool _holds(String name) => _held.any((key) => monitorKeyName(key) == name);

  void _send(String name, {required bool down, required bool press}) => _sink(
        name,
        down: down,
        press: press,
        alt: _holds('VK_MENU'),
        ctrl: _holds('VK_CONTROL'),
        shift: _holds('VK_SHIFT'),
        command: _holds('Meta'),
      );

  /// Presses and releases [key] with whatever is currently held.
  void tap(PhysicalKeyboardKey key) {
    final name = monitorKeyName(key);
    if (name == null) return;
    _send(name, down: false, press: true);
  }

  /// Holds ([down]) or releases [key]; repeated downs or ups are ignored.
  void setState(PhysicalKeyboardKey key, bool down) {
    final name = monitorKeyName(key);
    if (name == null) return;
    if (down) {
      if (_held.contains(key)) return;
      _held.add(key);
    } else if (!_held.remove(key)) {
      return;
    }
    _send(name, down: down, press: false);
  }

  /// Releases every held key, most recent first.
  void releaseAll() {
    for (final key in _held.reversed.toList()) {
      setState(key, false);
    }
  }
}
