import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'mirpg_remote_theme.dart';

/// Text kept in the hidden field so the phone keyboard's Backspace always has
/// something to delete. Every edit is diffed against the previous value and
/// streamed to Windows straight away.
final String kMonitorSoftKeyboardSentinel = '1' * 256;

/// The change a phone keyboard made to the hidden field.
class MonitorSoftKeyboardEdit {
  const MonitorSoftKeyboardEdit(this.backspaces, this.text);

  /// Characters to delete on Windows before typing [text].
  final int backspaces;
  final String text;

  bool get isEmpty => backspaces == 0 && text.isEmpty;

  @override
  bool operator ==(Object other) =>
      other is MonitorSoftKeyboardEdit &&
      other.backspaces == backspaces &&
      other.text == text;

  @override
  int get hashCode => Object.hash(backspaces, text);

  @override
  String toString() => 'MonitorSoftKeyboardEdit($backspaces, "$text")';
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// Works out what was typed or deleted between two values of the hidden
/// field. Handles keyboards that replace a whole word (suggestions) as well as
/// plain appends and deletes.
MonitorSoftKeyboardEdit diffMonitorSoftKeyboardText(
    String before, String after) {
  final limit = math.min(before.length, after.length);
  var common = 0;
  while (common < limit &&
      before.codeUnitAt(common) == after.codeUnitAt(common)) {
    common++;
  }
  // Never split a surrogate pair (emoji and other astral characters).
  if (common > 0 && _isHighSurrogate(before.codeUnitAt(common - 1))) {
    common--;
  }
  return MonitorSoftKeyboardEdit(
      before.substring(common).runes.length, after.substring(common));
}

const List<PhysicalKeyboardKey> _letterKeys = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.keyA,
  PhysicalKeyboardKey.keyB,
  PhysicalKeyboardKey.keyC,
  PhysicalKeyboardKey.keyD,
  PhysicalKeyboardKey.keyE,
  PhysicalKeyboardKey.keyF,
  PhysicalKeyboardKey.keyG,
  PhysicalKeyboardKey.keyH,
  PhysicalKeyboardKey.keyI,
  PhysicalKeyboardKey.keyJ,
  PhysicalKeyboardKey.keyK,
  PhysicalKeyboardKey.keyL,
  PhysicalKeyboardKey.keyM,
  PhysicalKeyboardKey.keyN,
  PhysicalKeyboardKey.keyO,
  PhysicalKeyboardKey.keyP,
  PhysicalKeyboardKey.keyQ,
  PhysicalKeyboardKey.keyR,
  PhysicalKeyboardKey.keyS,
  PhysicalKeyboardKey.keyT,
  PhysicalKeyboardKey.keyU,
  PhysicalKeyboardKey.keyV,
  PhysicalKeyboardKey.keyW,
  PhysicalKeyboardKey.keyX,
  PhysicalKeyboardKey.keyY,
  PhysicalKeyboardKey.keyZ,
];

const List<PhysicalKeyboardKey> _digitKeys = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.digit0,
  PhysicalKeyboardKey.digit1,
  PhysicalKeyboardKey.digit2,
  PhysicalKeyboardKey.digit3,
  PhysicalKeyboardKey.digit4,
  PhysicalKeyboardKey.digit5,
  PhysicalKeyboardKey.digit6,
  PhysicalKeyboardKey.digit7,
  PhysicalKeyboardKey.digit8,
  PhysicalKeyboardKey.digit9,
];

const List<PhysicalKeyboardKey> _functionKeys = <PhysicalKeyboardKey>[
  PhysicalKeyboardKey.f1,
  PhysicalKeyboardKey.f2,
  PhysicalKeyboardKey.f3,
  PhysicalKeyboardKey.f4,
  PhysicalKeyboardKey.f5,
  PhysicalKeyboardKey.f6,
  PhysicalKeyboardKey.f7,
  PhysicalKeyboardKey.f8,
  PhysicalKeyboardKey.f9,
  PhysicalKeyboardKey.f10,
  PhysicalKeyboardKey.f11,
  PhysicalKeyboardKey.f12,
];

/// US-layout physical key for a character, used when a sticky modifier is
/// held so that, for example, Ctrl then "c" reaches Windows as Ctrl+C.
PhysicalKeyboardKey? monitorPhysicalKeyForCharacter(String character) {
  if (character.runes.length != 1) return null;
  final unit = character.toLowerCase().codeUnitAt(0);
  if (unit >= 0x61 && unit <= 0x7A) return _letterKeys[unit - 0x61];
  if (unit >= 0x30 && unit <= 0x39) return _digitKeys[unit - 0x30];
  return switch (character) {
    ' ' => PhysicalKeyboardKey.space,
    '\t' => PhysicalKeyboardKey.tab,
    '-' => PhysicalKeyboardKey.minus,
    '=' => PhysicalKeyboardKey.equal,
    '[' => PhysicalKeyboardKey.bracketLeft,
    ']' => PhysicalKeyboardKey.bracketRight,
    '\\' => PhysicalKeyboardKey.backslash,
    ';' => PhysicalKeyboardKey.semicolon,
    '\'' => PhysicalKeyboardKey.quote,
    ',' => PhysicalKeyboardKey.comma,
    '.' => PhysicalKeyboardKey.period,
    '/' => PhysicalKeyboardKey.slash,
    '`' => PhysicalKeyboardKey.backquote,
    _ => null,
  };
}

/// A preset chord shown on the keyboard bar.
class MonitorLiveShortcut {
  const MonitorLiveShortcut({
    required this.label,
    required this.modifiers,
    required this.key,
  });

  final String label;
  final List<PhysicalKeyboardKey> modifiers;
  final PhysicalKeyboardKey key;
}

enum MonitorStickyState { off, once, locked }

/// Live keyboard for the Windows view: the phone keyboard types straight into
/// Windows, and this bar adds the keys a phone keyboard lacks. Modifiers are
/// sticky: tap once for the next key, tap again to lock, tap a third time to
/// release.
class MonitorLiveKeyboardBar extends StatefulWidget {
  const MonitorLiveKeyboardBar({
    super.key,
    required this.enabled,
    required this.onText,
    required this.onKey,
    required this.onKeyState,
    required this.onClose,
    this.shortcuts = const <MonitorLiveShortcut>[],
    this.onCompose,
    this.focusDelay = const Duration(milliseconds: 150),
  });

  final bool enabled;
  final ValueChanged<String> onText;
  final ValueChanged<PhysicalKeyboardKey> onKey;
  final void Function(PhysicalKeyboardKey key, bool down) onKeyState;
  final VoidCallback onClose;
  final List<MonitorLiveShortcut> shortcuts;
  final VoidCallback? onCompose;
  final Duration focusDelay;

  @override
  State<MonitorLiveKeyboardBar> createState() => MonitorLiveKeyboardBarState();
}

class MonitorLiveKeyboardBarState extends State<MonitorLiveKeyboardBar>
    with WidgetsBindingObserver {
  static const List<PhysicalKeyboardKey> _modifierOrder =
      <PhysicalKeyboardKey>[
    PhysicalKeyboardKey.controlLeft,
    PhysicalKeyboardKey.altLeft,
    PhysicalKeyboardKey.shiftLeft,
    PhysicalKeyboardKey.metaLeft,
  ];

  static final Map<PhysicalKeyboardKey, String> _modifierLabels =
      <PhysicalKeyboardKey, String>{
    PhysicalKeyboardKey.controlLeft: 'Ctrl',
    PhysicalKeyboardKey.altLeft: 'Alt',
    PhysicalKeyboardKey.shiftLeft: 'Shift',
    PhysicalKeyboardKey.metaLeft: 'Win',
  };

  /// Hardware or IME key events that are sent as keys rather than text.
  static final Set<PhysicalKeyboardKey> _directKeys = <PhysicalKeyboardKey>{
    PhysicalKeyboardKey.arrowLeft,
    PhysicalKeyboardKey.arrowRight,
    PhysicalKeyboardKey.arrowUp,
    PhysicalKeyboardKey.arrowDown,
    PhysicalKeyboardKey.escape,
    PhysicalKeyboardKey.tab,
    PhysicalKeyboardKey.delete,
    PhysicalKeyboardKey.home,
    PhysicalKeyboardKey.end,
    PhysicalKeyboardKey.pageUp,
    PhysicalKeyboardKey.pageDown,
    PhysicalKeyboardKey.insert,
    PhysicalKeyboardKey.backspace,
    PhysicalKeyboardKey.enter,
    PhysicalKeyboardKey.numpadEnter,
    PhysicalKeyboardKey.f1,
    PhysicalKeyboardKey.f2,
    PhysicalKeyboardKey.f3,
    PhysicalKeyboardKey.f4,
    PhysicalKeyboardKey.f5,
    PhysicalKeyboardKey.f6,
    PhysicalKeyboardKey.f7,
    PhysicalKeyboardKey.f8,
    PhysicalKeyboardKey.f9,
    PhysicalKeyboardKey.f10,
    PhysicalKeyboardKey.f11,
    PhysicalKeyboardKey.f12,
  };

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'monitor-live-keyboard');
  final Map<PhysicalKeyboardKey, MonitorStickyState> _sticky =
      <PhysicalKeyboardKey, MonitorStickyState>{
    for (final key in _modifierOrder) key: MonitorStickyState.off,
  };
  String _last = kMonitorSoftKeyboardSentinel;
  bool _functionRow = false;
  Timer? _focusTimer;
  Timer? _repeatTimer;

  /// Current sticky state of a modifier, for tests and accessibility.
  MonitorStickyState stickyState(PhysicalKeyboardKey key) =>
      _sticky[key] ?? MonitorStickyState.off;

  @override
  void initState() {
    super.initState();
    _resetBuffer();
    WidgetsBinding.instance.addObserver(this);
    _focusTimer = Timer(widget.focusDelay, showPhoneKeyboard);
  }

  @override
  void didUpdateWidget(covariant MonitorLiveKeyboardBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.enabled && !widget.enabled) {
      _stopRepeat();
      _releaseAll(rebuild: false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _stopRepeat();
    _releaseAll(rebuild: false);
    _focus.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _stopRepeat();
      _releaseAll();
    }
  }

  /// Focuses the hidden field and asks Android to show the keyboard again
  /// (for example after the user dismissed it with the system Back gesture).
  void showPhoneKeyboard() {
    _focusTimer = null;
    if (!mounted) return;
    if (_focus.hasFocus) {
      unawaited(SystemChannels.textInput
          .invokeMethod<void>('TextInput.show')
          .catchError((Object _) {}));
    } else {
      _focus.requestFocus();
    }
  }

  void _resetBuffer() {
    _last = kMonitorSoftKeyboardSentinel;
    _controller.value = TextEditingValue(
      text: kMonitorSoftKeyboardSentinel,
      selection:
          TextSelection.collapsed(offset: kMonitorSoftKeyboardSentinel.length),
    );
  }

  void _onChanged(String value) {
    final edit = diffMonitorSoftKeyboardText(_last, value);
    _last = value;
    if (widget.enabled && !edit.isEmpty) _apply(edit);
    if (value.length < 32 ||
        value.length > kMonitorSoftKeyboardSentinel.length + 2048) {
      _resetBuffer();
    } else {
      final selection = _controller.selection;
      if (!selection.isCollapsed || selection.baseOffset != value.length) {
        _controller.selection = TextSelection.collapsed(offset: value.length);
      }
    }
  }

  bool get _anySticky =>
      _sticky.values.any((state) => state != MonitorStickyState.off);

  bool _isHeld(PhysicalKeyboardKey key) =>
      (_sticky[key] ?? MonitorStickyState.off) != MonitorStickyState.off;

  void _apply(MonitorSoftKeyboardEdit edit) {
    for (var i = 0; i < math.min(edit.backspaces, 256); i++) {
      _tapKey(PhysicalKeyboardKey.backspace);
    }
    if (edit.text.isEmpty) return;
    final pending = StringBuffer();
    void flush() {
      if (pending.isEmpty) return;
      widget.onText(pending.toString());
      pending.clear();
      _consumeOnce();
    }

    for (final rune in edit.text.runes) {
      final character = String.fromCharCode(rune);
      if (character == '\n' || character == '\r') {
        flush();
        _tapKey(PhysicalKeyboardKey.enter);
        continue;
      }
      if (_anySticky) {
        final key = monitorPhysicalKeyForCharacter(character);
        if (key != null) {
          flush();
          final upper = character != character.toLowerCase();
          _tapKey(key,
              modifiers: upper
                  ? const <PhysicalKeyboardKey>[PhysicalKeyboardKey.shiftLeft]
                  : const <PhysicalKeyboardKey>[]);
          continue;
        }
      }
      pending.write(character);
    }
    flush();
  }

  /// Taps [key], briefly holding any [modifiers] that are not already held.
  void _tapKey(PhysicalKeyboardKey key,
      {List<PhysicalKeyboardKey> modifiers = const <PhysicalKeyboardKey>[]}) {
    if (!widget.enabled) return;
    final transient =
        modifiers.where((modifier) => !_isHeld(modifier)).toList();
    for (final modifier in transient) {
      widget.onKeyState(modifier, true);
    }
    widget.onKey(key);
    for (final modifier in transient.reversed) {
      widget.onKeyState(modifier, false);
    }
    _consumeOnce();
  }

  void _cycleModifier(PhysicalKeyboardKey key) {
    if (!widget.enabled) return;
    final current = stickyState(key);
    final next = switch (current) {
      MonitorStickyState.off => MonitorStickyState.once,
      MonitorStickyState.once => MonitorStickyState.locked,
      MonitorStickyState.locked => MonitorStickyState.off,
    };
    setState(() => _sticky[key] = next);
    if (current == MonitorStickyState.off) widget.onKeyState(key, true);
    if (next == MonitorStickyState.off) widget.onKeyState(key, false);
  }

  void _consumeOnce() {
    final once = _modifierOrder
        .where((key) => _sticky[key] == MonitorStickyState.once)
        .toList();
    if (once.isEmpty) return;
    for (final key in once.reversed) {
      widget.onKeyState(key, false);
    }
    setState(() {
      for (final key in once) {
        _sticky[key] = MonitorStickyState.off;
      }
    });
  }

  void _releaseAll({bool rebuild = true}) {
    final held = _modifierOrder.where(_isHeld).toList();
    if (held.isEmpty) return;
    for (final key in held.reversed) {
      widget.onKeyState(key, false);
    }
    void clear() {
      for (final key in held) {
        _sticky[key] = MonitorStickyState.off;
      }
    }

    if (rebuild && mounted) {
      setState(clear);
    } else {
      clear();
    }
  }

  void _startRepeat(PhysicalKeyboardKey key) {
    _stopRepeat();
    _tapKey(key);
    _repeatTimer = Timer.periodic(
        const Duration(milliseconds: 80), (_) => _tapKey(key));
  }

  void _stopRepeat() {
    _repeatTimer?.cancel();
    _repeatTimer = null;
  }

  KeyEventResult _onHardwareKey(FocusNode node, KeyEvent event) {
    final key = event.physicalKey;
    if (_directKeys.contains(key)) {
      if (event is KeyDownEvent || event is KeyRepeatEvent) _tapKey(key);
      return KeyEventResult.handled;
    }
    // Let the text field turn it into text, but stop the session's own key
    // listener from sending the same key a second time.
    return KeyEventResult.skipRemainingHandlers;
  }

  Widget _key(String label, PhysicalKeyboardKey key,
          {String? tooltip, IconData? icon, bool repeat = false}) =>
      _MonitorKeyCap(
        tooltip: tooltip ?? label,
        label: label,
        icon: icon,
        enabled: widget.enabled,
        onTap: () => _tapKey(key),
        onHoldStart: repeat ? () => _startRepeat(key) : null,
        onHoldEnd: repeat ? _stopRepeat : null,
      );

  Widget _modifier(PhysicalKeyboardKey key) {
    final label = _modifierLabels[key]!;
    final state = stickyState(key);
    return _MonitorKeyCap(
      tooltip: label,
      label: label,
      enabled: widget.enabled,
      sticky: state,
      semanticsValue: switch (state) {
        MonitorStickyState.off => 'Released',
        MonitorStickyState.once => 'Held for the next key',
        MonitorStickyState.locked => 'Locked',
      },
      onTap: () => _cycleModifier(key),
    );
  }

  Widget _hiddenField() => IgnorePointer(
        child: Opacity(
          opacity: 0,
          child: Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onKeyEvent: _onHardwareKey,
            child: TextField(
              key: const ValueKey('monitor-live-keyboard-input'),
              controller: _controller,
              focusNode: _focus,
              onChanged: _onChanged,
              onTapOutside: (_) {},
              keyboardType: TextInputType.multiline,
              textInputAction: TextInputAction.newline,
              maxLines: null,
              autocorrect: false,
              enableIMEPersonalizedLearning: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              showCursor: false,
              enableInteractiveSelection: false,
              decoration: null,
              style: const TextStyle(fontSize: 1, color: Colors.transparent),
            ),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    // Most-used keys first: a phone in portrait shows about five at once.
    final keys = <Widget>[
      _modifier(PhysicalKeyboardKey.controlLeft),
      _modifier(PhysicalKeyboardKey.altLeft),
      _modifier(PhysicalKeyboardKey.shiftLeft),
      _key('Esc', PhysicalKeyboardKey.escape),
      _key('Tab', PhysicalKeyboardKey.tab),
      _key('Left', PhysicalKeyboardKey.arrowLeft,
          tooltip: 'Left arrow', icon: Icons.keyboard_arrow_left, repeat: true),
      _key('Up', PhysicalKeyboardKey.arrowUp,
          tooltip: 'Up arrow', icon: Icons.keyboard_arrow_up, repeat: true),
      _key('Down', PhysicalKeyboardKey.arrowDown,
          tooltip: 'Down arrow', icon: Icons.keyboard_arrow_down, repeat: true),
      _key('Right', PhysicalKeyboardKey.arrowRight,
          tooltip: 'Right arrow',
          icon: Icons.keyboard_arrow_right,
          repeat: true),
      _modifier(PhysicalKeyboardKey.metaLeft),
      _key('Del', PhysicalKeyboardKey.delete, tooltip: 'Delete', repeat: true),
      _key('Home', PhysicalKeyboardKey.home),
      _key('End', PhysicalKeyboardKey.end),
      _key('PgUp', PhysicalKeyboardKey.pageUp, tooltip: 'Page Up'),
      _key('PgDn', PhysicalKeyboardKey.pageDown, tooltip: 'Page Down'),
      _MonitorKeyCap(
        tooltip: _functionRow ? 'Hide function keys' : 'Function keys',
        label: 'Fn',
        enabled: true,
        sticky: _functionRow ? MonitorStickyState.once : MonitorStickyState.off,
        onTap: () => setState(() => _functionRow = !_functionRow),
      ),
      if (_functionRow)
        for (var i = 0; i < _functionKeys.length; i++)
          _key('F${i + 1}', _functionKeys[i]),
      for (final shortcut in widget.shortcuts)
        _MonitorKeyCap(
          tooltip: shortcut.label,
          label: shortcut.label,
          enabled: widget.enabled,
          onTap: () => _tapKey(shortcut.key, modifiers: shortcut.modifiers),
        ),
      _MonitorKeyCap(
        tooltip: 'Show phone keyboard',
        icon: Icons.keyboard_outlined,
        enabled: true,
        onTap: showPhoneKeyboard,
      ),
    ];
    return Material(
      key: const ValueKey('monitor-live-keyboard'),
      color: MirpgRemoteTheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          width: double.infinity,
          height: 56,
          child: Stack(children: [
            Positioned(left: 0, top: 0, width: 1, height: 1, child: _hiddenField()),
            Row(children: [
              Expanded(
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  children: keys,
                ),
              ),
              Container(width: 1, height: 32, color: Colors.white12),
              if (widget.onCompose != null)
                _MonitorKeyCap(
                  tooltip: 'Compose text',
                  icon: Icons.edit_note,
                  enabled: true,
                  onTap: widget.onCompose!,
                ),
              _MonitorKeyCap(
                tooltip: 'Close keyboard',
                icon: Icons.keyboard_hide_outlined,
                enabled: true,
                onTap: widget.onClose,
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}

class _MonitorKeyCap extends StatelessWidget {
  const _MonitorKeyCap({
    required this.tooltip,
    required this.enabled,
    required this.onTap,
    this.label,
    this.icon,
    this.sticky,
    this.semanticsValue,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final String tooltip;
  final String? label;
  final IconData? icon;
  final bool enabled;
  final MonitorStickyState? sticky;
  final String? semanticsValue;
  final VoidCallback onTap;
  final VoidCallback? onHoldStart;
  final VoidCallback? onHoldEnd;

  @override
  Widget build(BuildContext context) {
    final state = sticky ?? MonitorStickyState.off;
    final locked = state == MonitorStickyState.locked;
    final active = state != MonitorStickyState.off;
    final foreground = !enabled
        ? Colors.white38
        : locked
            ? MirpgRemoteTheme.background
            : active
                ? MirpgRemoteTheme.accent
                : MirpgRemoteTheme.textPrimary;
    final background = locked
        ? MirpgRemoteTheme.accent
        : active
            ? MirpgRemoteTheme.accent.withOpacity(0.16)
            : MirpgRemoteTheme.raised;
    final child = icon != null
        ? Icon(icon, size: 22, color: foreground)
        : Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label ?? tooltip,
                style: TextStyle(
                    color: foreground,
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500)),
            if (locked) ...[
              const SizedBox(width: 3),
              Icon(Icons.lock, size: 11, color: foreground),
            ],
          ]);
    return Tooltip(
      message: tooltip,
      triggerMode: TooltipTriggerMode.manual,
      child: Semantics(
        button: true,
        enabled: enabled,
        toggled: sticky == null ? null : active,
        value: semanticsValue,
        label: tooltip,
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: enabled ? onTap : null,
          onLongPressStart:
              enabled && onHoldStart != null ? (_) => onHoldStart!() : null,
          onLongPressEnd:
              enabled && onHoldEnd != null ? (_) => onHoldEnd!() : null,
          onLongPressCancel: enabled && onHoldEnd != null ? onHoldEnd : null,
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 44),
            margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                  color: active && !locked
                      ? MirpgRemoteTheme.accent
                      : Colors.transparent),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
