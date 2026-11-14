import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mirpg_remote_theme.dart';
import 'monitor_live_keyboard.dart';

enum MonitorViewPreference { fit, readable }

enum MonitorOrientationPreference { auto, portrait, landscape }

enum MonitorToolbarDock { left, right }

const List<String> _monitorShortcutModifierOrder = <String>[
  'ctrl',
  'alt',
  'shift',
  'win'
];

const Map<String, String> _monitorShortcutKeyLabels = <String, String>{
  'tab': 'Tab',
  'c': 'C',
  'v': 'V',
  'z': 'Z',
  'escape': 'Esc',
  'enter': 'Enter',
  'space': 'Space',
  'backspace': 'Backspace',
  'delete': 'Delete',
  'home': 'Home',
  'end': 'End',
  'pageUp': 'Page Up',
  'pageDown': 'Page Down',
  'f1': 'F1',
  'f2': 'F2',
  'f3': 'F3',
  'f4': 'F4',
  'f5': 'F5',
  'f6': 'F6',
  'f7': 'F7',
  'f8': 'F8',
  'f9': 'F9',
  'f10': 'F10',
  'f11': 'F11',
  'f12': 'F12',
};

String _monitorShortcutModifierLabel(String modifier) => switch (modifier) {
      'ctrl' => 'Ctrl',
      'alt' => 'Alt',
      'shift' => 'Shift',
      'win' => 'Win',
      _ => modifier,
    };

PhysicalKeyboardKey? _monitorShortcutModifierKey(String modifier) =>
    switch (modifier) {
      'ctrl' => PhysicalKeyboardKey.controlLeft,
      'alt' => PhysicalKeyboardKey.altLeft,
      'shift' => PhysicalKeyboardKey.shiftLeft,
      'win' => PhysicalKeyboardKey.metaLeft,
      _ => null,
    };

PhysicalKeyboardKey? _monitorShortcutPhysicalKey(String key) => switch (key) {
      'tab' => PhysicalKeyboardKey.tab,
      'c' => PhysicalKeyboardKey.keyC,
      'v' => PhysicalKeyboardKey.keyV,
      'z' => PhysicalKeyboardKey.keyZ,
      'escape' => PhysicalKeyboardKey.escape,
      'enter' => PhysicalKeyboardKey.enter,
      'space' => PhysicalKeyboardKey.space,
      'backspace' => PhysicalKeyboardKey.backspace,
      'delete' => PhysicalKeyboardKey.delete,
      'home' => PhysicalKeyboardKey.home,
      'end' => PhysicalKeyboardKey.end,
      'pageUp' => PhysicalKeyboardKey.pageUp,
      'pageDown' => PhysicalKeyboardKey.pageDown,
      'f1' => PhysicalKeyboardKey.f1,
      'f2' => PhysicalKeyboardKey.f2,
      'f3' => PhysicalKeyboardKey.f3,
      'f4' => PhysicalKeyboardKey.f4,
      'f5' => PhysicalKeyboardKey.f5,
      'f6' => PhysicalKeyboardKey.f6,
      'f7' => PhysicalKeyboardKey.f7,
      'f8' => PhysicalKeyboardKey.f8,
      'f9' => PhysicalKeyboardKey.f9,
      'f10' => PhysicalKeyboardKey.f10,
      'f11' => PhysicalKeyboardKey.f11,
      'f12' => PhysicalKeyboardKey.f12,
      _ => null,
    };

class MonitorShortcutPreset {
  const MonitorShortcutPreset({
    required this.id,
    required this.modifiers,
    required this.key,
  });

  final String id;
  final List<String> modifiers;
  final String key;

  String get label => [
        ...modifiers.map(_monitorShortcutModifierLabel),
        _monitorShortcutKeyLabels[key] ?? key,
      ].join('+');

  MonitorShortcutPreset copyWith({List<String>? modifiers, String? key}) =>
      MonitorShortcutPreset(
        id: id,
        modifiers: modifiers ?? this.modifiers,
        key: key ?? this.key,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'modifiers': modifiers,
        'key': key,
      };

  static MonitorShortcutPreset? tryFromJson(dynamic raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final id = json['id'];
    final key = json['key'];
    if (id is! String ||
        id.isEmpty ||
        key is! String ||
        !_monitorShortcutKeyLabels.containsKey(key)) {
      return null;
    }
    final modifiers = <String>[];
    final rawModifiers = json['modifiers'];
    if (rawModifiers is List) {
      for (final modifier in rawModifiers) {
        if (modifier is String &&
            _monitorShortcutModifierOrder.contains(modifier) &&
            !modifiers.contains(modifier)) {
          modifiers.add(modifier);
        }
      }
    }
    return MonitorShortcutPreset(
        id: id, modifiers: List.unmodifiable(modifiers), key: key);
  }

  @override
  bool operator ==(Object other) =>
      other is MonitorShortcutPreset &&
      id == other.id &&
      key == other.key &&
      _stringListsEqual(modifiers, other.modifiers);

  @override
  int get hashCode => Object.hash(id, key, Object.hashAll(modifiers));
}

const List<MonitorShortcutPreset> kDefaultMonitorShortcuts =
    <MonitorShortcutPreset>[
  MonitorShortcutPreset(id: 'alt-tab', modifiers: ['alt'], key: 'tab'),
  MonitorShortcutPreset(id: 'copy', modifiers: ['ctrl'], key: 'c'),
  MonitorShortcutPreset(id: 'paste', modifiers: ['ctrl'], key: 'v'),
  MonitorShortcutPreset(id: 'undo', modifiers: ['ctrl'], key: 'z'),
  MonitorShortcutPreset(
      id: 'task-manager', modifiers: ['ctrl', 'shift'], key: 'escape'),
];

bool _stringListsEqual(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _shortcutListsEqual(
    List<MonitorShortcutPreset> a, List<MonitorShortcutPreset> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

class MonitorControlPreferences {
  const MonitorControlPreferences({
    this.preferredView = MonitorViewPreference.fit,
    this.toolbarDock = MonitorToolbarDock.right,
    this.toolbarVisible = true,
    this.thumbwheelVisible = false,
    this.shortcuts = kDefaultMonitorShortcuts,
    this.orientation = MonitorOrientationPreference.auto,
  });

  final MonitorViewPreference preferredView;
  final MonitorToolbarDock toolbarDock;
  final bool toolbarVisible;

  /// Show an on-screen scroll wheel as well as two-finger scrolling.
  final bool thumbwheelVisible;
  final List<MonitorShortcutPreset> shortcuts;
  final MonitorOrientationPreference orientation;

  MonitorControlPreferences copyWith({
    MonitorViewPreference? preferredView,
    MonitorToolbarDock? toolbarDock,
    bool? toolbarVisible,
    bool? thumbwheelVisible,
    List<MonitorShortcutPreset>? shortcuts,
    MonitorOrientationPreference? orientation,
  }) =>
      MonitorControlPreferences(
        preferredView: preferredView ?? this.preferredView,
        toolbarDock: toolbarDock ?? this.toolbarDock,
        toolbarVisible: toolbarVisible ?? this.toolbarVisible,
        thumbwheelVisible: thumbwheelVisible ?? this.thumbwheelVisible,
        shortcuts: shortcuts ?? this.shortcuts,
        orientation: orientation ?? this.orientation,
      );

  Map<String, dynamic> toJson() => {
        'view': preferredView.name,
        'dock': toolbarDock.name,
        'toolbar': toolbarVisible,
        'thumbwheel': thumbwheelVisible,
        'shortcuts': shortcuts.map((shortcut) => shortcut.toJson()).toList(),
        'orientation': orientation.name,
      };

  /// Settings saved by older builds (mouse mode, precision, cursor offset,
  /// floating mouse buttons) are ignored.
  factory MonitorControlPreferences.fromJson(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(Iterable<T> values, dynamic raw, T fallback) =>
        values.cast<T?>().firstWhere((value) => value?.name == raw,
            orElse: () => fallback) ??
        fallback;

    List<MonitorShortcutPreset> shortcuts(dynamic value) {
      if (value is! List) return kDefaultMonitorShortcuts;
      final parsed = <MonitorShortcutPreset>[];
      final ids = <String>{};
      for (final raw in value) {
        final shortcut = MonitorShortcutPreset.tryFromJson(raw);
        if (shortcut != null && ids.add(shortcut.id)) parsed.add(shortcut);
      }
      return parsed.isEmpty
          ? kDefaultMonitorShortcuts
          : List.unmodifiable(parsed);
    }

    return MonitorControlPreferences(
      preferredView: enumValue(MonitorViewPreference.values, json['view'],
          MonitorViewPreference.fit),
      toolbarDock: enumValue(
          MonitorToolbarDock.values, json['dock'], MonitorToolbarDock.right),
      toolbarVisible: json['toolbar'] != false,
      thumbwheelVisible: json['thumbwheel'] == true,
      shortcuts: shortcuts(json['shortcuts']),
      orientation: enumValue(MonitorOrientationPreference.values,
          json['orientation'], MonitorOrientationPreference.auto),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MonitorControlPreferences &&
      preferredView == other.preferredView &&
      toolbarDock == other.toolbarDock &&
      toolbarVisible == other.toolbarVisible &&
      thumbwheelVisible == other.thumbwheelVisible &&
      _shortcutListsEqual(shortcuts, other.shortcuts) &&
      orientation == other.orientation;

  @override
  int get hashCode => Object.hash(preferredView, toolbarDock, toolbarVisible,
      thumbwheelVisible, Object.hashAll(shortcuts), orientation);
}

bool monitorUsesLandscape(
    MonitorOrientationPreference preference, Size desktopSize) {
  switch (preference) {
    case MonitorOrientationPreference.portrait:
      return false;
    case MonitorOrientationPreference.landscape:
      return true;
    case MonitorOrientationPreference.auto:
      return desktopSize.width > desktopSize.height;
  }
}

/// The phone's view of a Windows monitor. There is no on-screen pointer:
/// Windows is clicked exactly where you touch, like a touchscreen.
///
/// * Tap to click; tap twice to double-click.
/// * Drag with one finger to move the zoomed view around.
/// * Touch and hold, then drag, to hold the left button (select, move
///   windows). Touch and hold, then lift, to right-click.
/// * Tap with two fingers to right-click.
/// * Pinch to zoom the local view; the view follows your fingers.
/// * Drag with two fingers to scroll Windows.
class MonitorControlView extends StatefulWidget {
  const MonitorControlView(
      {super.key,
      required this.desktopSize,
      this.image,
      required this.canControl,
      this.preferences = const MonitorControlPreferences(),
      this.onPreferencesChanged,
      this.localViewOnly = false,
      this.onLocalViewOnlyChanged,
      required this.onPointer,
      required this.onScroll,
      this.onSmoothScroll,
      required this.onKeyboard,
      this.onTextInput,
      this.onKeyTap,
      this.onKeyState,
      this.onSoftKeyboard,
      this.onClipboard,
      this.onWindows,
      this.onSwitchView,
      this.onDashboard,
      this.onSessionStatus,
      this.focusRect,
      this.focusRevision = 0,
      this.frameStatus,
      this.onCtrlAltDel,
      this.onRestartTaskbar});
  final Size desktopSize;
  final ui.Image? image;
  final bool canControl;
  final MonitorControlPreferences preferences;
  final ValueChanged<MonitorControlPreferences>? onPreferencesChanged;
  final bool localViewOnly;
  final ValueChanged<bool>? onLocalViewOnlyChanged;

  /// Pointer actions in desktop pixels: 0 left down, 1 left up, 2 move,
  /// 3 right click, 4 middle click, 5 right down, 6 right up.
  final void Function(int action, Offset point) onPointer;

  /// Whole wheel notches; positive follows a finger moving down.
  final void Function(int steps) onScroll;

  /// Smooth wheel units (120 per notch) that follow the fingers. When null,
  /// scrolling falls back to whole notches through [onScroll].
  final ValueChanged<Offset>? onSmoothScroll;

  /// Opens the compose sheet: type a block of text, then Send.
  final VoidCallback onKeyboard;

  /// Live typing. When all three are provided, Keyboard opens the phone
  /// keyboard and types straight into Windows; otherwise it opens
  /// [onKeyboard].
  final ValueChanged<String>? onTextInput;
  final ValueChanged<PhysicalKeyboardKey>? onKeyTap;
  final void Function(PhysicalKeyboardKey key, bool down)? onKeyState;

  /// Called when the live keyboard opens (true) or closes (false).
  final ValueChanged<bool>? onSoftKeyboard;
  final VoidCallback? onClipboard;
  final VoidCallback? onWindows;
  final VoidCallback? onSwitchView;
  final VoidCallback? onDashboard;
  final VoidCallback? onSessionStatus;
  final Rect? focusRect;
  final int focusRevision;
  final String? frameStatus;
  final VoidCallback? onCtrlAltDel;

  /// Restarts Windows Explorer on the PC; null hides the control.
  final VoidCallback? onRestartTaskbar;

  @override
  State<MonitorControlView> createState() => _MonitorControlViewState();
}

/// New vertical offset of the remote picture so the last tap ([tapDesktopY],
/// in desktop pixels) stays within [margin] of the visible area above the
/// phone keyboard ([visibleHeight]). Unchanged when the tap is already visible.
double monitorKeyboardPanDy({
  required double offsetDy,
  required double scale,
  required double tapDesktopY,
  required double visibleHeight,
  double margin = 24,
}) {
  final y = offsetDy + tapDesktopY * scale;
  if (y > visibleHeight - margin) {
    return visibleHeight - margin - tapDesktopY * scale;
  }
  if (y < margin) return margin - tapDesktopY * scale;
  return offsetDy;
}

/// Shows the shortcut preset editor; [onChanged] gets every change.
Future<void> showMonitorShortcutSettings(BuildContext context,
        {required List<MonitorShortcutPreset> shortcuts,
        required ValueChanged<List<MonitorShortcutPreset>> onChanged}) =>
    _MonitorShortcutEditor(shortcuts, onChanged).show(context);

class _MonitorShortcutEditor {
  _MonitorShortcutEditor(List<MonitorShortcutPreset> shortcuts, this._onChanged)
      : _shortcuts = List.of(shortcuts);

  final List<MonitorShortcutPreset> _shortcuts;
  final ValueChanged<List<MonitorShortcutPreset>> _onChanged;

  void _emit() => _onChanged(List.unmodifiable(_shortcuts));

  void _moveShortcut(int index, int delta, StateSetter refreshSheet) {
    final next = index + delta;
    if (next < 0 || next >= _shortcuts.length) return;
    final shortcut = _shortcuts.removeAt(index);
    _shortcuts.insert(next, shortcut);
    refreshSheet(() {});
    _emit();
  }

  void _editShortcut(
      BuildContext sheetContext, int index, StateSetter refreshSheet) {
    final preset = _shortcuts[index];
    var key = preset.key;
    final modifiers = preset.modifiers.toSet();
    showDialog<void>(
        context: sheetContext,
        builder: (dialogContext) => StatefulBuilder(
              builder: (dialogContext, refreshDialog) => AlertDialog(
                title: Text('Edit ${preset.label}'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Modifiers',
                            style:
                                Theme.of(dialogContext).textTheme.labelLarge)),
                    const SizedBox(height: 8),
                    Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _monitorShortcutModifierOrder
                            .map((modifier) => FilterChip(
                                  label: Text(
                                      _monitorShortcutModifierLabel(modifier)),
                                  selected: modifiers.contains(modifier),
                                  onSelected: (selected) => refreshDialog(() {
                                    if (selected) {
                                      modifiers.add(modifier);
                                    } else {
                                      modifiers.remove(modifier);
                                    }
                                  }),
                                ))
                            .toList()),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      value: key,
                      decoration: const InputDecoration(labelText: 'Key'),
                      items: _monitorShortcutKeyLabels.entries
                          .map((entry) => DropdownMenuItem<String>(
                              value: entry.key, child: Text(entry.value)))
                          .toList(),
                      onChanged: (value) {
                        if (value != null) refreshDialog(() => key = value);
                      },
                    ),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.of(dialogContext).pop(),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () {
                        final orderedModifiers = _monitorShortcutModifierOrder
                            .where(modifiers.contains)
                            .toList(growable: false);
                        _shortcuts[index] = preset.copyWith(
                            modifiers: orderedModifiers, key: key);
                        refreshSheet(() {});
                        _emit();
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('Save shortcut')),
                ],
              ),
            ));
  }

  Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => StatefulBuilder(
              builder: (sheetContext, refreshSheet) => SizedBox(
                height: math.min(
                    MediaQuery.of(sheetContext).size.height * 0.78, 560),
                child: Column(children: [
                  ListTile(
                    title: const Text('Shortcut presets'),
                    subtitle: const Text(
                        'Edit the chord or move presets into your preferred order.'),
                    trailing: IconButton(
                        tooltip: 'Close shortcut settings',
                        onPressed: () => Navigator.of(sheetContext).pop(),
                        icon: const Icon(Icons.close)),
                  ),
                  Expanded(
                    child: ListView.builder(
                      itemCount: _shortcuts.length,
                      itemBuilder: (_, index) {
                        final preset = _shortcuts[index];
                        return ListTile(
                          key: ValueKey('monitor-shortcut-${preset.id}'),
                          title: Text(preset.label),
                          trailing:
                              Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                tooltip: 'Move ${preset.label} up',
                                onPressed: index == 0
                                    ? null
                                    : () =>
                                        _moveShortcut(index, -1, refreshSheet),
                                icon: const Icon(Icons.arrow_upward)),
                            IconButton(
                                tooltip: 'Move ${preset.label} down',
                                onPressed: index == _shortcuts.length - 1
                                    ? null
                                    : () =>
                                        _moveShortcut(index, 1, refreshSheet),
                                icon: const Icon(Icons.arrow_downward)),
                            IconButton(
                                tooltip: 'Edit ${preset.label}',
                                onPressed: () => _editShortcut(
                                    sheetContext, index, refreshSheet),
                                icon: const Icon(Icons.edit_outlined)),
                          ]),
                        );
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () {
                          _shortcuts
                            ..clear()
                            ..addAll(kDefaultMonitorShortcuts);
                          refreshSheet(() {});
                          _emit();
                        },
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('Reset shortcuts'),
                      ),
                    ),
                  ),
                ]),
              ),
            ));
  }
}

class MonitorKeyboardPanel extends StatefulWidget {
  const MonitorKeyboardPanel(
      {super.key,
      required this.onText,
      required this.onKey,
      this.onKeyState,
      this.initialText = '',
      this.onDraftChanged,
      this.shortcuts = kDefaultMonitorShortcuts,
      this.onShortcutsChanged});
  final ValueChanged<String> onText;
  final ValueChanged<PhysicalKeyboardKey> onKey;
  final void Function(PhysicalKeyboardKey key, bool down)? onKeyState;
  final String initialText;
  final ValueChanged<String>? onDraftChanged;
  final List<MonitorShortcutPreset> shortcuts;
  final ValueChanged<List<MonitorShortcutPreset>>? onShortcutsChanged;

  @override
  State<MonitorKeyboardPanel> createState() => _MonitorKeyboardPanelState();
}

class _MonitorKeyboardPanelState extends State<MonitorKeyboardPanel>
    with WidgetsBindingObserver {
  late final TextEditingController _text;
  final _textFocus = FocusNode();
  final _held = <PhysicalKeyboardKey>{};
  late List<MonitorShortcutPreset> _shortcuts;
  _MonitorKeyboardMode _mode = _MonitorKeyboardMode.text;

  @override
  void initState() {
    super.initState();
    _text = TextEditingController(text: widget.initialText);
    _shortcuts = List.of(widget.shortcuts);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didUpdateWidget(covariant MonitorKeyboardPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_shortcutListsEqual(oldWidget.shortcuts, widget.shortcuts) &&
        !_shortcutListsEqual(_shortcuts, widget.shortcuts)) {
      _shortcuts = List.of(widget.shortcuts);
    }
  }

  @override
  void dispose() {
    _releaseAll(rebuild: false);
    WidgetsBinding.instance.removeObserver(this);
    _textFocus.dispose();
    _text.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _releaseAll();
  }

  void _send() {
    if (_text.text.isEmpty) return;
    widget.onText(_text.text);
    _text.clear();
    widget.onDraftChanged?.call('');
  }

  Future<void> _pastePhoneClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || data?.text == null || data!.text!.isEmpty) return;
    final text = data.text!;
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.onDraftChanged?.call(text);
    _textFocus.requestFocus();
  }

  void _releaseAll({bool rebuild = true}) {
    if (_held.isEmpty) return;
    for (final key in _held.toList().reversed) {
      widget.onKeyState?.call(key, false);
    }
    _held.clear();
    if (rebuild && mounted) setState(() {});
  }

  void _toggleModifier(PhysicalKeyboardKey key) {
    final down = !_held.contains(key);
    setState(() {
      if (down) {
        _held.add(key);
      } else {
        _held.remove(key);
      }
    });
    widget.onKeyState?.call(key, down);
  }

  void _setMode(_MonitorKeyboardMode mode) {
    if (mode == _mode) return;
    if (mode == _MonitorKeyboardMode.text) _releaseAll();
    setState(() => _mode = mode);
    if (mode == _MonitorKeyboardMode.text) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _textFocus.requestFocus();
      });
    } else {
      _textFocus.unfocus();
    }
  }

  void _shortcut(List<PhysicalKeyboardKey> modifiers, PhysicalKeyboardKey key) {
    final transient =
        modifiers.where((modifier) => !_held.contains(modifier)).toList();
    for (final modifier in transient) {
      widget.onKeyState?.call(modifier, true);
    }
    widget.onKey(key);
    for (final modifier in transient.reversed) {
      widget.onKeyState?.call(modifier, false);
    }
  }

  void _runShortcut(MonitorShortcutPreset preset) {
    final key = _monitorShortcutPhysicalKey(preset.key);
    if (key == null) return;
    final modifiers = preset.modifiers
        .map(_monitorShortcutModifierKey)
        .whereType<PhysicalKeyboardKey>()
        .toList();
    _shortcut(modifiers, key);
  }

  void _emitShortcuts() =>
      widget.onShortcutsChanged?.call(List.unmodifiable(_shortcuts));

  void _showShortcutSettings() =>
      showMonitorShortcutSettings(context, shortcuts: _shortcuts,
          onChanged: (shortcuts) {
        setState(() => _shortcuts = List.of(shortcuts));
        _emitShortcuts();
      });

  Widget _keyButton(String label, PhysicalKeyboardKey key) => OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () => widget.onKey(key),
      child: Text(label));

  Widget _modifierButton(String label, PhysicalKeyboardKey key) {
    final held = _held.contains(key);
    return Semantics(
      button: true,
      toggled: held,
      enabled: widget.onKeyState != null,
      label: '$label modifier',
      value: held ? 'Held' : 'Released',
      child: OutlinedButton(
          style: OutlinedButton.styleFrom(
              minimumSize: const Size(48, 48),
              backgroundColor:
                  held ? MirpgRemoteTheme.accent.withOpacity(0.18) : null,
              foregroundColor: held ? MirpgRemoteTheme.accent : null),
          onPressed:
              widget.onKeyState == null ? null : () => _toggleModifier(key),
          child: Text(label)),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Expanded(child: Text('Windows input')),
              IconButton(
                  tooltip: 'Close keyboard',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop())
            ]),
            SegmentedButton<_MonitorKeyboardMode>(
              segments: const [
                ButtonSegment(
                    value: _MonitorKeyboardMode.text,
                    label: Text('Text'),
                    icon: Icon(Icons.text_fields)),
                ButtonSegment(
                    value: _MonitorKeyboardMode.keys,
                    label: Text('Keys'),
                    icon: Icon(Icons.keyboard_alt_outlined)),
              ],
              selected: {_mode},
              onSelectionChanged: (selection) => _setMode(selection.single),
            ),
            const SizedBox(height: 12),
            if (_mode == _MonitorKeyboardMode.text) ...[
              TextField(
                  controller: _text,
                  focusNode: _textFocus,
                  onChanged: widget.onDraftChanged,
                  autofocus: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  minLines: 2,
                  maxLines: 5,
                  decoration: InputDecoration(
                      labelText: 'Type text, then Send',
                      suffixIcon: IconButton(
                          tooltip: 'Send text',
                          onPressed: _send,
                          icon: const Icon(Icons.send_outlined)))),
              Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: 'Paste phone clipboard',
                  child: TextButton.icon(
                    onPressed: _pastePhoneClipboard,
                    icon: const Icon(Icons.content_paste_outlined),
                    label: const Text('Paste phone clipboard'),
                    style:
                        TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  ),
                ),
              ),
            ] else ...[
              Wrap(spacing: 8, runSpacing: 8, children: [
                _modifierButton('Ctrl', PhysicalKeyboardKey.controlLeft),
                _modifierButton('Alt', PhysicalKeyboardKey.altLeft),
                _modifierButton('Shift', PhysicalKeyboardKey.shiftLeft),
                _modifierButton('Win', PhysicalKeyboardKey.metaLeft),
                _keyButton('Esc', PhysicalKeyboardKey.escape),
                _keyButton('Tab', PhysicalKeyboardKey.tab),
                _keyButton('Enter', PhysicalKeyboardKey.enter),
                _keyButton('Backspace', PhysicalKeyboardKey.backspace),
                for (final key in <PhysicalKeyboardKey, IconData>{
                  PhysicalKeyboardKey.arrowLeft: Icons.arrow_back,
                  PhysicalKeyboardKey.arrowUp: Icons.arrow_upward,
                  PhysicalKeyboardKey.arrowDown: Icons.arrow_downward,
                  PhysicalKeyboardKey.arrowRight: Icons.arrow_forward,
                }.entries)
                  IconButton(
                      tooltip: key.key.debugName,
                      constraints:
                          const BoxConstraints(minWidth: 48, minHeight: 48),
                      onPressed: () => widget.onKey(key.key),
                      icon: Icon(key.value)),
                for (final entry in <String, PhysicalKeyboardKey>{
                  'F1': PhysicalKeyboardKey.f1,
                  'F2': PhysicalKeyboardKey.f2,
                  'F3': PhysicalKeyboardKey.f3,
                  'F4': PhysicalKeyboardKey.f4,
                  'F5': PhysicalKeyboardKey.f5,
                  'F6': PhysicalKeyboardKey.f6,
                  'F7': PhysicalKeyboardKey.f7,
                  'F8': PhysicalKeyboardKey.f8,
                  'F9': PhysicalKeyboardKey.f9,
                  'F10': PhysicalKeyboardKey.f10,
                  'F11': PhysicalKeyboardKey.f11,
                  'F12': PhysicalKeyboardKey.f12,
                }.entries)
                  _keyButton(entry.key, entry.value),
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final preset in _shortcuts)
                  OutlinedButton(
                      onPressed: () => _runShortcut(preset),
                      child: Text(preset.label)),
                Tooltip(
                  message: 'Customize shortcuts',
                  child: OutlinedButton.icon(
                    onPressed: _showShortcutSettings,
                    icon: const Icon(Icons.tune),
                    label: const Text('Customize'),
                  ),
                ),
                if (_held.isNotEmpty)
                  FilledButton.tonalIcon(
                      onPressed: _releaseAll,
                      icon: const Icon(Icons.lock_open_outlined),
                      label: const Text('Release all')),
              ]),
            ],
          ])));
}

class _MonitorControlViewState extends State<MonitorControlView> {
  static const double _dragSlop = 10;
  static const double _twoFingerTapSlop = 16;
  static const double _twoFingerDecideDistance = 8;
  static const double _pinchThreshold = 0.06;
  static const Duration _longPressTimeout = Duration(milliseconds: 500);
  static const Duration _twoFingerTapTimeout = Duration(milliseconds: 350);
  static const Duration _doubleTapTimeout = Duration(milliseconds: 450);
  static const double _doubleTapDistance = 28;
  static const double _wheelUnitsPerDesktopPixel = 1.5;
  static const double _wheelStepPixels = 18;
  static const double _thumbwheelUnitsPerPixel = 4;
  static const double _momentumMinSpeed = 250;
  static const double _momentumMaxSpeed = 6000;

  late Offset _pointer = widget.desktopSize.center(Offset.zero);
  Size _viewport = Size.zero;
  Offset _offset = Offset.zero;
  double _fit = 1;
  double? _zoom;
  late _MonitorViewPreset _viewPreset;
  late MonitorViewPreference _preferredView;
  late MonitorToolbarDock _toolbarDock;
  late bool _toolbarVisible;
  late bool _thumbwheelVisible;
  late List<MonitorShortcutPreset> _shortcuts;
  late MonitorOrientationPreference _orientationPreference;
  _MonitorPanel _panel = _MonitorPanel.none;
  _ArmedButton _armed = _ArmedButton.none;
  bool _liveKeyboard = false;
  final GlobalKey<MonitorLiveKeyboardBarState> _keyboardBarKey =
      GlobalKey<MonitorLiveKeyboardBarState>();

  /// Height at the bottom of this view covered by the phone keyboard and the
  /// key strip while typing.
  double _keyboardReserve = 0;

  /// Distance from this view's bottom edge to the screen's bottom edge.
  double _screenGap = 0;
  bool get _typing => _liveKeyboard && _liveKeyboardSupported;

  final Stopwatch _clock = Stopwatch()..start();
  final Map<int, Offset> _contacts = <int, Offset>{};
  final Map<int, Offset> _contactStarts = <int, Offset>{};
  int _maxContacts = 0;
  double _travel = 0;
  Duration _gestureStart = Duration.zero;
  _TouchGesture _gesture = _TouchGesture.none;
  Offset? _pressLocal;
  Offset? _lastLocal;
  Offset? _touchMarker;
  Timer? _longPressTimer;

  /// The button-down action (0 left, 5 right) held by a one-finger drag.
  int? _heldButton;
  Offset? _lastTapLocal;
  Offset? _lastTapPoint;
  Duration _lastTapAt = Duration.zero;

  double _startSpan = 0;
  double _lastSpan = 0;
  Offset _lastFocal = Offset.zero;
  Offset _twoFingerStartFocal = Offset.zero;
  Offset _twoFingerPending = Offset.zero;
  final Map<int, Offset> _twoFingerStarts = <int, Offset>{};
  Offset _focalVelocity = Offset.zero;
  Duration _lastFocalAt = Duration.zero;

  double _wheel = 0;
  Offset _smoothRemainder = Offset.zero;
  double _thumbwheelDelta = 0;
  Timer? _momentum;
  Offset _momentumVelocity = Offset.zero;

  double get _scale => _fit * (_zoom ?? 1);
  bool get _canSendInput => widget.canControl && !widget.localViewOnly;
  bool get _liveKeyboardSupported =>
      widget.onTextInput != null &&
      widget.onKeyTap != null &&
      widget.onKeyState != null;
  bool get _showThumbwheel => widget.canControl && _thumbwheelVisible;
  bool get _twoFingerActive =>
      _gesture == _TouchGesture.twoFinger ||
      _gesture == _TouchGesture.pinch ||
      _gesture == _TouchGesture.pan ||
      _gesture == _TouchGesture.scroll;

  @override
  void initState() {
    super.initState();
    _loadPreferences(widget.preferences);
    if (widget.focusRect != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocusRect());
    }
  }

  @override
  void didUpdateWidget(covariant MonitorControlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences) {
      _loadPreferences(widget.preferences, keepCustomZoom: true);
    }
    if (oldWidget.focusRevision != widget.focusRevision &&
        widget.focusRect != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealFocusRect());
    }
    final couldSend = oldWidget.canControl && !oldWidget.localViewOnly;
    if (!_canSendInput) {
      _stopMomentum();
      _armed = _ArmedButton.none;
      if (_heldButton != null || _longPressTimer != null) {
        _cancelContacts(release: couldSend);
      }
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _momentum?.cancel();
    final held = _heldButton;
    if (held != null && _canSendInput) {
      widget.onPointer(held == 0 ? 1 : 6, _pointer);
    }
    if (_liveKeyboard) widget.onSoftKeyboard?.call(false);
    super.dispose();
  }

  void _loadPreferences(MonitorControlPreferences preferences,
      {bool keepCustomZoom = false}) {
    _preferredView = preferences.preferredView;
    if (!keepCustomZoom || _viewPreset != _MonitorViewPreset.custom) {
      _viewPreset = preferences.preferredView == MonitorViewPreference.readable
          ? _MonitorViewPreset.readable
          : _MonitorViewPreset.fit;
      _zoom = null;
    }
    _toolbarDock = preferences.toolbarDock;
    _toolbarVisible = preferences.toolbarVisible;
    _thumbwheelVisible = preferences.thumbwheelVisible;
    _shortcuts = List.of(preferences.shortcuts);
    _orientationPreference = preferences.orientation;
  }

  void _emitPreferences() {
    widget.onPreferencesChanged?.call(MonitorControlPreferences(
      preferredView: _preferredView,
      toolbarDock: _toolbarDock,
      toolbarVisible: _toolbarVisible,
      thumbwheelVisible: _thumbwheelVisible,
      shortcuts: List.unmodifiable(_shortcuts),
      orientation: _orientationPreference,
    ));
  }

  // ---------------------------------------------------------------------
  // Viewport

  void _limitOffset() {
    final width = widget.desktopSize.width * _scale;
    final height = widget.desktopSize.height * _scale;
    _offset = Offset(
        width <= _viewport.width
            ? (_viewport.width - width) / 2
            : _offset.dx.clamp(_viewport.width - width, 0).toDouble(),
        _typing
            ? _offset.dy
                .clamp(
                    math.min(_viewport.height - _keyboardReserve - height, 0),
                    math.max(_viewport.height - height, 0))
                .toDouble()
            : height <= _viewport.height
                ? (_viewport.height - height) / 2
                : _offset.dy.clamp(_viewport.height - height, 0).toDouble());
  }

  /// Keeps the last tap just above the key strip while typing.
  void _panToPointer() {
    if (!_typing || _viewport.isEmpty) return;
    _offset = Offset(
        _offset.dx,
        monitorKeyboardPanDy(
            offsetDy: _offset.dy,
            scale: _scale,
            tapDesktopY: _pointer.dy,
            visibleHeight: _viewport.height - _keyboardReserve));
    _limitOffset();
  }

  void _measureKeyboard() {
    if (!mounted || !_typing) return;
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final screen = MediaQuery.sizeOf(context).height;
    final gap = math.max(
        0.0, screen - box.localToGlobal(Offset(0, box.size.height)).dy);
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    final strip = _keyboardBarKey.currentContext?.size?.height ?? 0;
    final reserve = math.max(0.0, inset - gap) + strip;
    if ((gap - _screenGap).abs() < 0.5 &&
        (reserve - _keyboardReserve).abs() < 0.5) {
      return;
    }
    setState(() {
      _screenGap = gap;
      _keyboardReserve = reserve;
      _panToPointer();
    });
  }

  void _revealFocusRect() {
    if (!mounted || _viewport.isEmpty || widget.focusRect == null) return;
    final rect = widget.focusRect!;
    final point = Offset(
      rect.center.dx.clamp(0, widget.desktopSize.width - 1).toDouble(),
      rect.center.dy.clamp(0, widget.desktopSize.height - 1).toDouble(),
    );
    setState(() {
      _pointer = point;
      _offset = _viewport.center(Offset.zero) - point * _scale;
      _limitOffset();
    });
  }

  void _setZoom(double zoom, Offset focus,
      {_MonitorViewPreset preset = _MonitorViewPreset.custom}) {
    final point = (focus - _offset) / _scale;
    _zoom = zoom.clamp(1, 6).toDouble();
    _viewPreset = preset == _MonitorViewPreset.custom && _zoom! <= 1.001
        ? _MonitorViewPreset.fit
        : preset;
    _offset = focus - point * _scale;
    _limitOffset();
  }

  void _applyPreset(_MonitorViewPreset preset) {
    if (preset == _MonitorViewPreset.fit) {
      _zoom = 1;
      _viewPreset = preset;
      _preferredView = MonitorViewPreference.fit;
      _limitOffset();
      _emitPreferences();
      return;
    }
    final readableZoom = (1 / _fit).clamp(1.0, 6.0).toDouble();
    _preferredView = MonitorViewPreference.readable;
    _setZoom(readableZoom, _viewport.center(Offset.zero), preset: preset);
    _emitPreferences();
  }

  void _zoomBy(double factor) => setState(
      () => _setZoom((_zoom ?? 1) * factor, _viewport.center(Offset.zero)));

  void _cycleOrientation() {
    _cancelContacts();
    setState(() {
      _orientationPreference = switch (_orientationPreference) {
        MonitorOrientationPreference.auto =>
          MonitorOrientationPreference.portrait,
        MonitorOrientationPreference.portrait =>
          MonitorOrientationPreference.landscape,
        MonitorOrientationPreference.landscape =>
          MonitorOrientationPreference.auto,
      };
    });
    _emitPreferences();
  }

  String get _orientationLabel => switch (_orientationPreference) {
        MonitorOrientationPreference.auto => 'Auto',
        MonitorOrientationPreference.portrait => 'Portrait',
        MonitorOrientationPreference.landscape => 'Landscape',
      };

  String get _viewLabel {
    switch (_viewPreset) {
      case _MonitorViewPreset.fit:
        return 'Fit';
      case _MonitorViewPreset.readable:
        return 'Readable';
      case _MonitorViewPreset.custom:
        final zoom = _zoom ?? 1;
        final digits = zoom < 2 ? 2 : 1;
        return '${zoom.toStringAsFixed(digits)}× Fit';
    }
  }

  /// Desktop pixel under a viewport position, or null in the black bars.
  /// With [clamp], positions outside the desktop snap to its nearest edge so
  /// a drag always ends at a valid position.
  Offset? _desktopPoint(Offset local, {bool clamp = false}) {
    final frame = Rect.fromLTWH(_offset.dx, _offset.dy,
        widget.desktopSize.width * _scale, widget.desktopSize.height * _scale);
    if (frame.isEmpty || (!clamp && !frame.contains(local))) return null;
    final point = (local - frame.topLeft) / _scale;
    return Offset(
      point.dx.clamp(0, widget.desktopSize.width - 1).toDouble(),
      point.dy.clamp(0, widget.desktopSize.height - 1).toDouble(),
    );
  }

  // ---------------------------------------------------------------------
  // Touch input

  void _sendMove(Offset point) {
    _pointer = point;
    widget.onPointer(2, point);
  }

  void _releaseHeld() {
    final held = _heldButton;
    if (held == null) return;
    _heldButton = null;
    widget.onPointer(held == 0 ? 1 : 6, _pointer);
  }

  /// Forgets every finger, for example when the layout rotates under them.
  /// Does not call setState.
  void _cancelContacts({bool release = true}) {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    final held = _heldButton;
    _heldButton = null;
    _contacts.clear();
    _contactStarts.clear();
    _maxContacts = 0;
    _travel = 0;
    _gesture = _TouchGesture.none;
    _touchMarker = null;
    _wheel = 0;
    _smoothRemainder = Offset.zero;
    _thumbwheelDelta = 0;
    if (release && held != null) {
      widget.onPointer(held == 0 ? 1 : 6, _pointer);
    }
  }

  void _onPointerDown(PointerDownEvent event) {
    _stopMomentum();
    final first = _contacts.isEmpty;
    _contacts[event.pointer] = event.localPosition;
    _contactStarts[event.pointer] = event.localPosition;
    if (first) {
      _maxContacts = 1;
      _travel = 0;
      _gestureStart = _clock.elapsed;
      _pressLocal = event.localPosition;
      _lastLocal = event.localPosition;
      _gesture = _TouchGesture.pending;
      _longPressTimer?.cancel();
      _longPressTimer =
          _canSendInput && _desktopPoint(event.localPosition) != null
              ? Timer(_longPressTimeout, _onLongPress)
              : null;
      setState(() => _touchMarker = event.localPosition);
      return;
    }
    _maxContacts = math.max(_maxContacts, _contacts.length);
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (_contacts.length == 2) {
      _releaseHeld();
      _beginTwoFinger();
    }
    setState(() => _touchMarker = null);
  }

  void _beginTwoFinger() {
    final points = _contacts.values.take(2).toList(growable: false);
    _startSpan = (points[0] - points[1]).distance;
    _lastSpan = _startSpan;
    _lastFocal = (points[0] + points[1]) / 2;
    _twoFingerStartFocal = _lastFocal;
    _twoFingerPending = Offset.zero;
    _twoFingerStarts
      ..clear()
      ..addAll(_contacts);
    _focalVelocity = Offset.zero;
    _lastFocalAt = _clock.elapsed;
    _wheel = 0;
    _smoothRemainder = Offset.zero;
    _gesture = _TouchGesture.twoFinger;
  }

  void _onPointerMove(PointerMoveEvent event) {
    final start = _contactStarts[event.pointer];
    if (start == null) return;
    _contacts[event.pointer] = event.localPosition;
    _travel = math.max(_travel, (event.localPosition - start).distance);
    if (_contacts.length >= 2) {
      _twoFingerUpdate();
      return;
    }
    // A finger left over from a two-finger gesture does nothing.
    if (_maxContacts > 1) return;
    final local = event.localPosition;
    final delta = local - (_lastLocal ?? local);
    _lastLocal = local;
    setState(() {
      _touchMarker = local;
      switch (_gesture) {
        case _TouchGesture.pending:
          if (_travel > _dragSlop) {
            // A plain drag moves the view, like a photo; nothing is sent.
            _longPressTimer?.cancel();
            _longPressTimer = null;
            _gesture = _TouchGesture.viewPan;
            _offset += local - (_pressLocal ?? local);
            _limitOffset();
          }
        case _TouchGesture.holding:
          if ((local - (_pressLocal ?? local)).distance > _dragSlop) {
            _beginDrag(local);
          }
        case _TouchGesture.drag:
          final point = _desktopPoint(local, clamp: true);
          if (point != null) _sendMove(point);
        case _TouchGesture.viewPan:
          _offset += delta;
          _limitOffset();
        default:
          break;
      }
    });
  }

  /// Starts a held-button drag after touch-and-hold.
  void _beginDrag(Offset local) {
    if (!_canSendInput) {
      _gesture = _TouchGesture.ignored;
      return;
    }
    final start = _pressLocal == null ? null : _desktopPoint(_pressLocal!);
    if (start == null) {
      // Started in the black bars around the desktop.
      _gesture = _TouchGesture.ignored;
      return;
    }
    _gesture = _TouchGesture.drag;
    final right = _armed == _ArmedButton.right;
    _armed = _ArmedButton.none;
    _sendMove(start);
    final down = right ? 5 : 0;
    _heldButton = down;
    widget.onPointer(down, _pointer);
    final point = _desktopPoint(local, clamp: true);
    if (point != null) _sendMove(point);
  }

  void _onLongPress() {
    _longPressTimer = null;
    if (!mounted ||
        _gesture != _TouchGesture.pending ||
        _contacts.length != 1 ||
        !_canSendInput) {
      return;
    }
    if (_pressLocal == null || _desktopPoint(_pressLocal!) == null) return;
    // Held: dragging from here holds the mouse button; lifting right-clicks.
    setState(() => _gesture = _TouchGesture.holding);
    unawaited(HapticFeedback.mediumImpact());
  }

  void _holdRightClick() {
    if (!_canSendInput || _pressLocal == null) return;
    final point = _desktopPoint(_pressLocal!);
    if (point == null) return;
    _sendMove(point);
    widget.onPointer(3, _pointer);
    _armed = _ArmedButton.none;
  }

  void _onPointerUp(PointerEvent event) {
    if (_contactStarts.remove(event.pointer) == null) return;
    _contacts.remove(event.pointer);
    if (_contacts.isNotEmpty) return;
    _longPressTimer?.cancel();
    _longPressTimer = null;
    final gesture = _gesture;
    final contacts = _maxContacts;
    final elapsed = _clock.elapsed - _gestureStart;
    _gesture = _TouchGesture.none;
    _maxContacts = 0;
    final cancelled = event is PointerCancelEvent;
    setState(() {
      _touchMarker = null;
      _releaseHeld();
      if (cancelled) return;
      if (contacts == 1 && gesture == _TouchGesture.pending) {
        _tap(_pressLocal);
      } else if (contacts == 1 && gesture == _TouchGesture.holding) {
        _holdRightClick();
      } else if (contacts == 2 &&
          gesture == _TouchGesture.twoFinger &&
          _travel <= _twoFingerTapSlop &&
          elapsed <= _twoFingerTapTimeout) {
        _twoFingerTap();
      } else if (gesture == _TouchGesture.scroll) {
        _startMomentum();
      }
    });
  }

  void _tap(Offset? local) {
    if (local == null || !_canSendInput) return;
    var point = _desktopPoint(local);
    if (point == null) return;
    final now = _clock.elapsed;
    // Windows only counts a double-click within a few pixels, so a second
    // quick tap near the first reuses its exact position.
    if (_lastTapPoint != null &&
        _lastTapLocal != null &&
        now - _lastTapAt <= _doubleTapTimeout &&
        (local - _lastTapLocal!).distance <= _doubleTapDistance) {
      point = _lastTapPoint!;
    }
    _lastTapLocal = local;
    _lastTapPoint = point;
    _lastTapAt = now;
    _sendMove(point);
    if (_typing) setState(_panToPointer);
    switch (_armed) {
      case _ArmedButton.right:
        widget.onPointer(3, _pointer);
      case _ArmedButton.middle:
        widget.onPointer(4, _pointer);
      case _ArmedButton.none:
        widget.onPointer(0, _pointer);
        widget.onPointer(1, _pointer);
    }
    _armed = _ArmedButton.none;
  }

  void _twoFingerTap() {
    if (!_canSendInput) return;
    final point = _desktopPoint(_twoFingerStartFocal);
    if (point != null) _sendMove(point);
    widget.onPointer(3, _pointer);
    _armed = _ArmedButton.none;
  }

  void _twoFingerUpdate() {
    if (!_twoFingerActive) return;
    final points = _contacts.values.take(2).toList(growable: false);
    final span = (points[0] - points[1]).distance;
    final focal = (points[0] + points[1]) / 2;
    final delta = focal - _lastFocal;
    final now = _clock.elapsed;
    final seconds =
        (now - _lastFocalAt).inMicroseconds / Duration.microsecondsPerSecond;
    if (seconds > 0) {
      final instant = delta / seconds;
      _focalVelocity =
          seconds > 0.1 ? instant : _focalVelocity * 0.4 + instant * 0.6;
    }
    _lastFocalAt = now;
    final spanChange = _startSpan <= 0 ? 0.0 : (span / _startSpan - 1).abs();
    var apply = delta;
    var pinchBase = _lastSpan;
    if (_gesture == _TouchGesture.twoFinger) {
      _twoFingerPending += delta;
      final decided = _classifyTwoFinger(spanChange);
      if (decided != null) {
        _gesture = decided;
        apply = _twoFingerPending;
        if (decided == _TouchGesture.pinch) pinchBase = _startSpan;
      }
    }
    setState(() {
      switch (_gesture) {
        case _TouchGesture.pinch:
          final factor = pinchBase > 0 ? span / pinchBase : 1.0;
          _offset += apply;
          _setZoom((_zoom ?? 1) * factor, focal);
        case _TouchGesture.pan:
          _offset += apply;
          _limitOffset();
        case _TouchGesture.scroll:
          _scrollBy(apply);
        default:
          break;
      }
    });
    _lastSpan = span;
    _lastFocal = focal;
  }

  /// Decides what a two-finger gesture is from how each finger moved since
  /// the second finger landed. Fingers report one at a time, so a single
  /// finger's step on its own is not read as a pinch.
  _TouchGesture? _classifyTwoFinger(double spanChange) {
    final ids = _contacts.keys.take(2).toList(growable: false);
    final firstStart = _twoFingerStarts[ids[0]];
    final secondStart = _twoFingerStarts[ids[1]];
    if (firstStart == null || secondStart == null) return null;
    final first = _contacts[ids[0]]! - firstStart;
    final second = _contacts[ids[1]]! - secondStart;
    final most = math.max(first.distance, second.distance);
    final least = math.min(first.distance, second.distance);
    if (most < _twoFingerDecideDistance) return null;
    // One finger moves the view, so two fingers scroll Windows.
    final travel = _canSendInput ? _TouchGesture.scroll : _TouchGesture.pan;
    final together = least >= 2 &&
        (first.dx * second.dx + first.dy * second.dy) /
                (first.distance * second.distance) >
            0.5;
    if (together && least >= most * 0.35) return travel;
    if (spanChange >= _pinchThreshold && (least >= 2 || most >= 30)) {
      return _TouchGesture.pinch;
    }
    if (most >= 30) return travel;
    return null;
  }

  /// Scrolls Windows so the content follows a finger movement in viewport
  /// pixels.
  void _scrollBy(Offset fingerDelta) {
    if (!_canSendInput) return;
    var delta = fingerDelta;
    if (delta.dy.abs() >= delta.dx.abs() * 1.6) {
      delta = Offset(0, delta.dy);
    } else if (delta.dx.abs() >= delta.dy.abs() * 1.6) {
      delta = Offset(delta.dx, 0);
    }
    if (widget.onSmoothScroll != null) {
      _sendWheelUnits(delta / _scale * _wheelUnitsPerDesktopPixel);
      return;
    }
    _wheel += delta.dy / _wheelStepPixels;
    final steps = _wheel.truncate();
    if (steps != 0) {
      widget.onScroll(steps);
      _wheel -= steps;
    }
  }

  void _sendWheelUnits(Offset units) {
    final total = _smoothRemainder + units;
    final sent =
        Offset(total.dx.truncateToDouble(), total.dy.truncateToDouble());
    _smoothRemainder = total - sent;
    if (sent == Offset.zero) return;
    widget.onSmoothScroll!(Offset(sent.dx.clamp(-1200.0, 1200.0).toDouble(),
        sent.dy.clamp(-1200.0, 1200.0).toDouble()));
  }

  void _startMomentum() {
    if (!_canSendInput || widget.onSmoothScroll == null) return;
    if (_clock.elapsed - _lastFocalAt > const Duration(milliseconds: 80)) {
      return;
    }
    var velocity = _focalVelocity;
    if (velocity.distance < _momentumMinSpeed) return;
    if (velocity.distance > _momentumMaxSpeed) {
      velocity = velocity / velocity.distance * _momentumMaxSpeed;
    }
    _momentum?.cancel();
    _momentumVelocity = velocity;
    _momentum = Timer.periodic(const Duration(milliseconds: 16), (_) {
      if (!mounted || !_canSendInput) {
        _stopMomentum();
        return;
      }
      _momentumVelocity = _momentumVelocity * 0.92;
      if (_momentumVelocity.distance < 60) {
        _stopMomentum();
        return;
      }
      _scrollBy(_momentumVelocity * 0.016);
    });
  }

  void _stopMomentum() {
    _momentum?.cancel();
    _momentum = null;
    _momentumVelocity = Offset.zero;
  }

  void _arm(_ArmedButton button) {
    if (!_canSendInput) return;
    setState(() {
      _armed = _armed == button ? _ArmedButton.none : button;
      _panel = _MonitorPanel.none;
    });
  }

  // ---------------------------------------------------------------------
  // Keyboard

  void _toggleKeyboard() {
    if (!_liveKeyboardSupported) {
      widget.onKeyboard();
      return;
    }
    if (_liveKeyboard) {
      _closeLiveKeyboard();
      return;
    }
    widget.onSoftKeyboard?.call(true);
    setState(() {
      _liveKeyboard = true;
      _panel = _MonitorPanel.none;
    });
  }

  void _closeLiveKeyboard() {
    if (!_liveKeyboard) return;
    setState(() => _liveKeyboard = false);
    widget.onSoftKeyboard?.call(false);
  }

  List<MonitorLiveShortcut> get _liveShortcuts => [
        for (final preset in _shortcuts)
          if (_monitorShortcutPhysicalKey(preset.key) != null)
            MonitorLiveShortcut(
              label: preset.label,
              modifiers: preset.modifiers
                  .map(_monitorShortcutModifierKey)
                  .whereType<PhysicalKeyboardKey>()
                  .toList(growable: false),
              key: _monitorShortcutPhysicalKey(preset.key)!,
            ),
      ];

  Widget _liveKeyboardBar() => MonitorLiveKeyboardBar(
        key: _keyboardBarKey,
        enabled: _canSendInput,
        onText: (text) => widget.onTextInput?.call(text),
        onKey: (key) => widget.onKeyTap?.call(key),
        onKeyState: (key, down) => widget.onKeyState?.call(key, down),
        shortcuts: _liveShortcuts,
        onShortcuts: () => showMonitorShortcutSettings(context,
            shortcuts: _shortcuts, onChanged: (shortcuts) {
          setState(() => _shortcuts = List.of(shortcuts));
          _emitPreferences();
        }),
        onClose: _closeLiveKeyboard,
      );

  // ---------------------------------------------------------------------
  // Controls

  void _showGestureHelp() {
    showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (_) => SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const ListTile(
                      leading: Icon(Icons.touch_app_outlined),
                      title: Text('Touch Windows directly'),
                      subtitle: Text(
                          'There is no pointer to steer. Windows is clicked exactly where you touch. Tap twice quickly to double-click.')),
                  const ListTile(
                      leading: Icon(Icons.pan_tool_alt_outlined),
                      title: Text('Drag with one finger'),
                      subtitle: Text(
                          'Moves the zoomed view around. Nothing is sent to Windows.')),
                  const ListTile(
                      leading: Icon(Icons.swipe_outlined),
                      title: Text('Touch and hold'),
                      subtitle: Text(
                          'Hold until the phone buzzes, then drag to hold the left button (select text, move windows), or lift to right-click.')),
                  const ListTile(
                      leading: Icon(Icons.ads_click),
                      title: Text('Right-click'),
                      subtitle: Text(
                          'Touch and hold then lift, or tap with two fingers. Controls also has right- and middle-click for the next tap.')),
                  const ListTile(
                      leading: Icon(Icons.zoom_out_map),
                      title: Text('Two fingers'),
                      subtitle: Text('Pinch to zoom. Drag to scroll Windows.')),
                  const ListTile(
                      leading: Icon(Icons.keyboard_outlined),
                      title: Text('Keyboard'),
                      subtitle: Text(
                          'Types into Windows as you go. Tap Ctrl, Alt, Shift or Win once for the next key, twice to lock it. Compose sends a whole block at once.')),
                  const ListTile(
                      leading: Icon(Icons.zoom_in),
                      title: Text('Local zoom only'),
                      subtitle: Text(
                          'Zooming and moving the view never change Windows resolution or click anything.')),
                ]))));
  }

  void _resetControls() {
    const defaults = MonitorControlPreferences();
    _cancelContacts();
    setState(() {
      _armed = _ArmedButton.none;
      _loadPreferences(defaults);
      _limitOffset();
    });
    _emitPreferences();
  }

  Widget _controlTile(
          String tooltip, IconData icon, String label, VoidCallback? action,
          {bool selected = false}) =>
      Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          enabled: action != null,
          selected: selected,
          child: InkWell(
            onTap: action,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              width: 84,
              height: 68,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                color: selected
                    ? MirpgRemoteTheme.accent.withOpacity(0.16)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      size: 22,
                      color: action == null
                          ? Colors.white38
                          : selected
                              ? MirpgRemoteTheme.accent
                              : MirpgRemoteTheme.textPrimary),
                  const SizedBox(height: 4),
                  Text(label,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          height: 1.1,
                          color: action == null
                              ? Colors.white38
                              : MirpgRemoteTheme.textSecondary,
                          fontSize: 11)),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _controlsPanel() => Material(
        key: const ValueKey('monitor-controls-panel'),
        color: MirpgRemoteTheme.surface,
        elevation: 8,
        borderRadius: BorderRadius.circular(16),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Wrap(spacing: 4, runSpacing: 4, children: [
            _controlTile('Right click', Icons.ads_click, 'Right-click next tap',
                _canSendInput ? () => _arm(_ArmedButton.right) : null,
                selected: _armed == _ArmedButton.right),
            _controlTile('Middle click', Icons.adjust, 'Middle-click next tap',
                _canSendInput ? () => _arm(_ArmedButton.middle) : null,
                selected: _armed == _ArmedButton.middle),
            _controlTile('Zoom out', Icons.zoom_out, 'Zoom out',
                () => _zoomBy(1 / 1.25)),
            _controlTile('Zoom in', Icons.zoom_in, 'Zoom in · $_viewLabel',
                () => _zoomBy(1.25)),
            _controlTile('Orientation: $_orientationLabel',
                Icons.screen_rotation, _orientationLabel, _cycleOrientation),
            _controlTile(
                _thumbwheelVisible ? 'Hide thumbwheel' : 'Show thumbwheel',
                Icons.swap_vert,
                'Scroll wheel', () {
              setState(() => _thumbwheelVisible = !_thumbwheelVisible);
              _emitPreferences();
            }, selected: _thumbwheelVisible),
            _controlTile(
                widget.localViewOnly ? 'Disable view only' : 'View only',
                widget.localViewOnly
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
                'View only',
                widget.onLocalViewOnlyChanged == null
                    ? null
                    : () =>
                        widget.onLocalViewOnlyChanged!(!widget.localViewOnly),
                selected: widget.localViewOnly),
            _controlTile(
                _toolbarDock == MonitorToolbarDock.right
                    ? 'Dock controls left'
                    : 'Dock controls right',
                _toolbarDock == MonitorToolbarDock.right
                    ? Icons.align_horizontal_left
                    : Icons.align_horizontal_right,
                _toolbarDock == MonitorToolbarDock.right
                    ? 'Dock left'
                    : 'Dock right', () {
              setState(() {
                _toolbarDock = _toolbarDock == MonitorToolbarDock.right
                    ? MonitorToolbarDock.left
                    : MonitorToolbarDock.right;
              });
              _emitPreferences();
            }),
            _controlTile('Ctrl+Alt+Del', Icons.security, 'Ctrl+Alt+Del',
                _canSendInput ? widget.onCtrlAltDel : null),
            if (widget.onRestartTaskbar != null)
              _controlTile('Restart taskbar', Icons.call_to_action_outlined,
                  'Taskbar', _canSendInput ? widget.onRestartTaskbar : null),
            _controlTile(
                'Gestures', Icons.help_outline, 'Gestures', _showGestureHelp),
            _controlTile(
                'Reset controls', Icons.restart_alt, 'Reset', _resetControls),
          ]),
        ),
      );

  void _toggleControls() =>
      setState(() => _panel = _panel == _MonitorPanel.controls
          ? _MonitorPanel.none
          : _MonitorPanel.controls);

  Widget _toolbarButton(String tooltip, IconData icon, VoidCallback? action,
          {bool selected = false}) =>
      IconButton(
          tooltip: tooltip,
          color: selected ? MirpgRemoteTheme.accent : Colors.white,
          disabledColor: Colors.white38,
          icon: Icon(icon),
          onPressed: action);

  void _handleSessionAction(_MonitorSessionAction action) {
    switch (action) {
      case _MonitorSessionAction.clipboard:
        widget.onClipboard?.call();
      case _MonitorSessionAction.windows:
        widget.onWindows?.call();
      case _MonitorSessionAction.quality:
        widget.onSessionStatus?.call();
      case _MonitorSessionAction.hideControls:
        setState(() {
          _toolbarVisible = false;
          _panel = _MonitorPanel.none;
        });
        _emitPreferences();
    }
  }

  PopupMenuItem<_MonitorSessionAction> _menuItem(
          _MonitorSessionAction value, IconData icon, String title) =>
      PopupMenuItem(
        value: value,
        child: ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon),
          title: Text(title),
        ),
      );

  Widget _sessionMenu() => PopupMenuButton<_MonitorSessionAction>(
        tooltip: 'Session controls',
        icon: const Icon(Icons.more_vert_rounded),
        onSelected: _handleSessionAction,
        itemBuilder: (context) => [
          if (widget.onClipboard != null)
            _menuItem(_MonitorSessionAction.clipboard,
                Icons.content_copy_outlined, 'Clipboard'),
          if (widget.onWindows != null)
            _menuItem(_MonitorSessionAction.windows, Icons.web_asset_outlined,
                'Windows'),
          if (widget.onSessionStatus != null)
            _menuItem(_MonitorSessionAction.quality, Icons.network_check,
                'Quality & connection'),
          if (widget.onClipboard != null ||
              widget.onWindows != null ||
              widget.onSessionStatus != null)
            const PopupMenuDivider(),
          _menuItem(_MonitorSessionAction.hideControls,
              Icons.keyboard_arrow_down_rounded, 'Hide controls'),
        ],
      );

  Widget _sessionTopBar() => Material(
        key: const ValueKey('monitor-top-bar'),
        color: MirpgRemoteTheme.background,
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: LayoutBuilder(builder: (context, constraints) {
              final compact = constraints.maxWidth < 560;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(children: [
                  _toolbarButton('Dashboard', Icons.arrow_back_rounded,
                      widget.onDashboard),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Desktop',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: MirpgRemoteTheme.textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 2),
                        Text(
                          '${widget.desktopSize.width.round()} × ${widget.desktopSize.height.round()} · $_viewLabel',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: MirpgRemoteTheme.textSecondary,
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  if (widget.localViewOnly)
                    Container(
                      margin: const EdgeInsets.only(right: 4),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 5),
                      decoration: BoxDecoration(
                        color: MirpgRemoteTheme.warning.withOpacity(0.14),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('View only',
                          style: TextStyle(
                              color: MirpgRemoteTheme.warning, fontSize: 12)),
                    ),
                  if (!compact && widget.onSessionStatus != null)
                    TextButton.icon(
                      onPressed: widget.onSessionStatus,
                      icon: const Icon(Icons.network_check, size: 18),
                      label: const Text('Quality'),
                    ),
                  _sessionMenu(),
                ]),
              );
            }),
          ),
        ),
      );

  Widget _footerControl(
    String tooltip,
    IconData icon,
    String label,
    VoidCallback? action, {
    bool selected = false,
  }) =>
      Expanded(
        child: Tooltip(
          message: tooltip,
          child: Semantics(
            button: true,
            enabled: action != null,
            selected: selected,
            label: label,
            child: InkWell(
              onTap: action,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                constraints: const BoxConstraints(
                    minWidth: MirpgRemoteTheme.minTouchTarget, minHeight: 60),
                margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
                decoration: BoxDecoration(
                  color: selected
                      ? MirpgRemoteTheme.accent.withOpacity(0.16)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon,
                        size: 21,
                        color: action == null
                            ? Colors.white38
                            : selected
                                ? MirpgRemoteTheme.accent
                                : MirpgRemoteTheme.textSecondary),
                    const SizedBox(height: 3),
                    Text(label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: action == null
                                ? Colors.white38
                                : selected
                                    ? MirpgRemoteTheme.accent
                                    : MirpgRemoteTheme.textSecondary,
                            fontSize: 11,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  VoidCallback? get _keyboardAction => _canSendInput ? _toggleKeyboard : null;

  Widget _sessionToolbar() => Material(
        color: MirpgRemoteTheme.background,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              _footerControl(
                  'Fit view',
                  Icons.fit_screen_outlined,
                  _viewPreset == _MonitorViewPreset.custom ? _viewLabel : 'Fit',
                  () => setState(() => _applyPreset(_MonitorViewPreset.fit)),
                  selected: _viewPreset == _MonitorViewPreset.fit),
              _footerControl(
                  'Readable view', Icons.text_fields_rounded, 'Readable', () {
                setState(() => _applyPreset(_MonitorViewPreset.readable));
              }, selected: _viewPreset == _MonitorViewPreset.readable),
              _footerControl('Keyboard', Icons.keyboard_outlined, 'Keyboard',
                  _keyboardAction,
                  selected: _liveKeyboard),
              _footerControl(
                  'Controls', Icons.tune_rounded, 'Controls', _toggleControls,
                  selected: _panel == _MonitorPanel.controls),
              _footerControl('Switch view', Icons.view_carousel_outlined,
                  'Targets', widget.onSwitchView),
            ]),
          ),
        ),
      );

  Widget _thumbwheel() {
    void scroll(double dy) {
      if (!_canSendInput) return;
      if (widget.onSmoothScroll != null) {
        _sendWheelUnits(Offset(0, dy * _thumbwheelUnitsPerPixel));
        return;
      }
      _thumbwheelDelta += dy / 12;
      final steps = _thumbwheelDelta.truncate();
      if (steps != 0) {
        widget.onScroll(steps);
        _thumbwheelDelta -= steps;
      }
    }

    return Semantics(
      label: 'Remote scroll thumbwheel',
      value: _canSendInput ? 'Ready' : 'Disabled',
      increasedValue: _canSendInput ? 'Scroll up' : null,
      decreasedValue: _canSendInput ? 'Scroll down' : null,
      enabled: _canSendInput,
      onIncrease: _canSendInput ? () => widget.onScroll(-1) : null,
      onDecrease: _canSendInput ? () => widget.onScroll(1) : null,
      child: GestureDetector(
        key: const ValueKey('monitor-thumbwheel'),
        behavior: HitTestBehavior.opaque,
        onVerticalDragStart: (_) => _stopMomentum(),
        onVerticalDragUpdate:
            _canSendInput ? (details) => scroll(details.delta.dy) : null,
        onVerticalDragEnd: (_) => _thumbwheelDelta = 0,
        onVerticalDragCancel: () => _thumbwheelDelta = 0,
        child: Material(
          color: MirpgRemoteTheme.surface.withOpacity(0.94),
          elevation: 8,
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            width: 48,
            height: 144,
            child:
                Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              const Icon(Icons.keyboard_arrow_up, color: Colors.white70),
              const SizedBox(height: 12),
              Icon(Icons.unfold_more,
                  color: _canSendInput ? Colors.white : Colors.white38),
              const SizedBox(height: 12),
              const Icon(Icons.keyboard_arrow_down, color: Colors.white70),
            ]),
          ),
        ),
      ),
    );
  }

  Widget? _modeBadge() {
    final labels = <String>[
      if (_armed == _ArmedButton.right) 'Next tap right-clicks',
      if (_armed == _ArmedButton.middle) 'Next tap middle-clicks',
      if (_gesture == _TouchGesture.holding)
        'Drag to hold the button · lift to right-click',
      if (_heldButton != null) 'Dragging',
    ];
    if (labels.isEmpty) return null;
    return Material(
      color: MirpgRemoteTheme.surface.withOpacity(0.94),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(labels.join(' · '),
              style: const TextStyle(color: MirpgRemoteTheme.textPrimary)),
          if (_armed != _ArmedButton.none) ...[
            const SizedBox(width: 8),
            TextButton(
                onPressed: () => setState(() => _armed = _ArmedButton.none),
                child: const Text('Cancel')),
          ],
        ]),
      ),
    );
  }

  Widget _sessionRail(List<Widget> controls) => Material(
        color: MirpgRemoteTheme.background,
        child: SizedBox(
          width: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: controls,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final height = box.maxHeight;
        final keyboard = _typing;
        if (keyboard) {
          // The phone keyboard covers the picture instead of shrinking it.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _measureKeyboard());
          final inset = MediaQuery.viewInsetsOf(context).bottom;
          return Stack(children: [
            Positioned.fill(child: _remoteViewport()),
            Positioned(
                left: 0,
                right: 0,
                bottom: math.max(0.0, inset - _screenGap),
                child: _liveKeyboardBar()),
          ]);
        }
        // Place controls along the axis that preserves the largest whole image.
        final railScale = math.min(
            (box.maxWidth - 112) / widget.desktopSize.width,
            height / widget.desktopSize.height);
        final barScale = math.min(box.maxWidth / widget.desktopSize.width,
            (height - 124) / widget.desktopSize.height);
        if (_toolbarVisible &&
            height >= 240 &&
            box.maxWidth >= 400 &&
            railScale > barScale) {
          return Column(children: [
            Expanded(
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                  _sessionRail([
                    _toolbarButton('Dashboard', Icons.arrow_back_rounded,
                        widget.onDashboard),
                    _toolbarButton(
                        'Fit view',
                        Icons.fit_screen_outlined,
                        () => setState(
                            () => _applyPreset(_MonitorViewPreset.fit)),
                        selected: _viewPreset == _MonitorViewPreset.fit),
                    _toolbarButton(
                        'Readable view',
                        Icons.text_fields_rounded,
                        () => setState(
                            () => _applyPreset(_MonitorViewPreset.readable)),
                        selected: _viewPreset == _MonitorViewPreset.readable),
                    _toolbarButton('Switch view', Icons.view_carousel_outlined,
                        widget.onSwitchView),
                  ]),
                  Expanded(child: _remoteViewport()),
                  _sessionRail([
                    _sessionMenu(),
                    _toolbarButton(
                        'Keyboard', Icons.keyboard_outlined, _keyboardAction,
                        selected: _liveKeyboard),
                    _toolbarButton(
                        'Controls', Icons.tune_rounded, _toggleControls,
                        selected: _panel == _MonitorPanel.controls),
                  ]),
                ])),
            if (keyboard) _liveKeyboardBar(),
          ]);
        }
        return Column(children: [
          if (_toolbarVisible) _sessionTopBar(),
          Expanded(child: _remoteViewport()),
          if (keyboard)
            _liveKeyboardBar()
          else if (_toolbarVisible)
            _sessionToolbar(),
        ]);
      });

  Widget _remoteViewport() => LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        if (size.isEmpty || widget.desktopSize.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_viewport != size) {
          _viewport = size;
          // While typing the picture keeps its size; only its position moves.
          if (!_typing || _fit == 0) {
            _fit = math.min(size.width / widget.desktopSize.width,
                size.height / widget.desktopSize.height);
            if (_viewPreset == _MonitorViewPreset.readable) {
              _zoom = (1 / _fit).clamp(1.0, 6.0).toDouble();
            } else if (_viewPreset == _MonitorViewPreset.fit) {
              _zoom = 1;
            } else {
              _zoom ??= 1;
            }
          }
          _offset = size.center(Offset.zero) - _pointer * _scale;
          _limitOffset();
          _panToPointer();
        }
        final frameStatus =
            widget.frameStatus ?? (widget.localViewOnly ? 'View only' : null);
        final badge = _modeBadge();
        final thumbwheelTop = math.max(12.0, (_viewport.height - 144) / 2);
        final marker = _touchMarker;
        return Stack(children: [
          Positioned.fill(
              child: Listener(
                  key: const ValueKey('monitor-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: _onPointerDown,
                  onPointerMove: _onPointerMove,
                  onPointerUp: _onPointerUp,
                  onPointerCancel: _onPointerUp,
                  child: Semantics(
                      label:
                          'Windows touch screen. Tap where you want to click, drag with one finger to move the view, touch and hold then drag to drag in Windows, touch and hold then lift or tap with two fingers to right-click, pinch to zoom, and drag with two fingers to scroll.',
                      child: ClipRect(
                          child: Stack(children: [
                        Positioned(
                            key: const ValueKey('monitor-frame'),
                            left: _offset.dx,
                            top: _offset.dy,
                            width: widget.desktopSize.width * _scale,
                            height: widget.desktopSize.height * _scale,
                            child: RawImage(
                                image: widget.image,
                                fit: BoxFit.fill,
                                filterQuality: FilterQuality.medium)),
                        if (widget.image == null)
                          const Center(child: CircularProgressIndicator()),
                        if (marker != null && widget.canControl)
                          Positioned(
                              key: const ValueKey('monitor-touch-marker'),
                              left: marker.dx - 18,
                              top: marker.dy - 18,
                              child: IgnorePointer(
                                  child: Container(
                                      width: 36,
                                      height: 36,
                                      decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Colors.white.withOpacity(0.12),
                                          border: Border.all(
                                              color: Colors.white70,
                                              width: 2))))),
                      ]))))),
          if (badge != null) Positioned(top: 12, left: 12, child: badge),
          if (frameStatus != null)
            Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(
                    child: Center(
                        child: DecoratedBox(
                            decoration: BoxDecoration(
                                color:
                                    MirpgRemoteTheme.surface.withOpacity(0.9),
                                borderRadius: BorderRadius.circular(999)),
                            child: Padding(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 7),
                                child: Text(frameStatus,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600))))))),
          if (_showThumbwheel)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 8 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 8 : null,
                top: thumbwheelTop,
                child: _thumbwheel()),
          if (_panel == _MonitorPanel.controls)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 8 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 8 : null,
                bottom: 12,
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: math.max(0, _viewport.width - 16),
                        maxHeight: math.max(0, _viewport.height - 24)),
                    child: _controlsPanel())),
          if (!_toolbarVisible)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 4 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 4 : null,
                bottom: 4,
                child: Material(
                    color: MirpgRemoteTheme.surface.withOpacity(0.94),
                    elevation: 8,
                    borderRadius: BorderRadius.circular(14),
                    child: IconButton(
                        tooltip: 'Show toolbar',
                        color: Colors.white,
                        icon: const Icon(Icons.keyboard_arrow_up),
                        onPressed: () {
                          setState(() => _toolbarVisible = true);
                          _emitPreferences();
                        }))),
        ]);
      });
}

enum _MonitorPanel { none, controls }

enum _MonitorSessionAction {
  clipboard,
  windows,
  quality,
  hideControls,
}

enum _TouchGesture {
  none,
  pending,
  drag,
  holding,
  viewPan,
  ignored,
  twoFinger,
  pinch,
  pan,
  scroll,
}

enum _ArmedButton { none, right, middle }

enum _MonitorViewPreset { fit, readable, custom }

enum _MonitorKeyboardMode { text, keys }
