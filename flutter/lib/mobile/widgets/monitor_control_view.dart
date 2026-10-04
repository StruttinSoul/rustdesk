import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mirpg_remote_theme.dart';

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
    this.precision = false,
    this.precisionGain = 0.35,
    this.toolbarDock = MonitorToolbarDock.right,
    this.toolbarVisible = true,
    this.thumbwheelVisible = false,
    this.mouseButtonsVisible = false,
    this.mouseButtonsPosition = const Offset(0.78, 0.58),
    this.cursorOffset = false,
    this.shortcuts = kDefaultMonitorShortcuts,
    this.orientation = MonitorOrientationPreference.auto,
  });

  final MonitorViewPreference preferredView;
  final bool precision;
  final double precisionGain;
  final MonitorToolbarDock toolbarDock;
  final bool toolbarVisible;
  final bool thumbwheelVisible;
  final bool mouseButtonsVisible;
  final Offset mouseButtonsPosition;
  final bool cursorOffset;
  final List<MonitorShortcutPreset> shortcuts;
  final MonitorOrientationPreference orientation;

  MonitorControlPreferences copyWith({
    MonitorViewPreference? preferredView,
    bool? precision,
    double? precisionGain,
    MonitorToolbarDock? toolbarDock,
    bool? toolbarVisible,
    bool? thumbwheelVisible,
    bool? mouseButtonsVisible,
    Offset? mouseButtonsPosition,
    bool? cursorOffset,
    List<MonitorShortcutPreset>? shortcuts,
    MonitorOrientationPreference? orientation,
  }) =>
      MonitorControlPreferences(
        preferredView: preferredView ?? this.preferredView,
        precision: precision ?? this.precision,
        precisionGain: precisionGain ?? this.precisionGain,
        toolbarDock: toolbarDock ?? this.toolbarDock,
        toolbarVisible: toolbarVisible ?? this.toolbarVisible,
        thumbwheelVisible: thumbwheelVisible ?? this.thumbwheelVisible,
        mouseButtonsVisible: mouseButtonsVisible ?? this.mouseButtonsVisible,
        mouseButtonsPosition: mouseButtonsPosition ?? this.mouseButtonsPosition,
        cursorOffset: cursorOffset ?? this.cursorOffset,
        shortcuts: shortcuts ?? this.shortcuts,
        orientation: orientation ?? this.orientation,
      );

  Map<String, dynamic> toJson() => {
        'view': preferredView.name,
        'precision': precision,
        'precisionGain': precisionGain,
        'dock': toolbarDock.name,
        'toolbar': toolbarVisible,
        'thumbwheel': thumbwheelVisible,
        'mouseButtons': mouseButtonsVisible,
        'mouseX': mouseButtonsPosition.dx,
        'mouseY': mouseButtonsPosition.dy,
        'cursorOffset': cursorOffset,
        'shortcuts': shortcuts.map((shortcut) => shortcut.toJson()).toList(),
        'orientation': orientation.name,
      };

  factory MonitorControlPreferences.fromJson(Map<String, dynamic> json) {
    T enumValue<T extends Enum>(Iterable<T> values, dynamic raw, T fallback) =>
        values.cast<T?>().firstWhere((value) => value?.name == raw,
            orElse: () => fallback) ??
        fallback;
    double normalized(dynamic value, double fallback) {
      final parsed = value is num ? value.toDouble() : fallback;
      return parsed.clamp(0.0, 1.0).toDouble();
    }

    double precisionGain(dynamic value) {
      final parsed = value is num ? value.toDouble() : 0.35;
      return parsed.clamp(0.1, 1.0).toDouble();
    }

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
      precision: json['precision'] == true,
      precisionGain: precisionGain(json['precisionGain']),
      toolbarDock: enumValue(
          MonitorToolbarDock.values, json['dock'], MonitorToolbarDock.right),
      toolbarVisible: json['toolbar'] != false,
      thumbwheelVisible: json['thumbwheel'] == true,
      mouseButtonsVisible: json['mouseButtons'] == true,
      mouseButtonsPosition: Offset(
        normalized(json['mouseX'], 0.78),
        normalized(json['mouseY'], 0.58),
      ),
      cursorOffset: json['cursorOffset'] == true,
      shortcuts: shortcuts(json['shortcuts']),
      orientation: enumValue(MonitorOrientationPreference.values,
          json['orientation'], MonitorOrientationPreference.auto),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MonitorControlPreferences &&
      preferredView == other.preferredView &&
      precision == other.precision &&
      precisionGain == other.precisionGain &&
      toolbarDock == other.toolbarDock &&
      toolbarVisible == other.toolbarVisible &&
      thumbwheelVisible == other.thumbwheelVisible &&
      mouseButtonsVisible == other.mouseButtonsVisible &&
      mouseButtonsPosition == other.mouseButtonsPosition &&
      cursorOffset == other.cursorOffset &&
      _shortcutListsEqual(shortcuts, other.shortcuts) &&
      orientation == other.orientation;

  @override
  int get hashCode => Object.hash(
      preferredView,
      precision,
      precisionGain,
      toolbarDock,
      toolbarVisible,
      thumbwheelVisible,
      mouseButtonsVisible,
      mouseButtonsPosition,
      cursorOffset,
      Object.hashAll(shortcuts),
      orientation);
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
      required this.onKeyboard,
      this.onSwitchView,
      this.onDashboard,
      this.onCtrlAltDel});
  final Size desktopSize;
  final ui.Image? image;
  final bool canControl;
  final MonitorControlPreferences preferences;
  final ValueChanged<MonitorControlPreferences>? onPreferencesChanged;
  final bool localViewOnly;
  final ValueChanged<bool>? onLocalViewOnlyChanged;
  final void Function(int action, Offset point) onPointer;
  final void Function(int steps) onScroll;
  final VoidCallback onKeyboard;
  final VoidCallback? onSwitchView;
  final VoidCallback? onDashboard;
  final VoidCallback? onCtrlAltDel;

  @override
  State<MonitorControlView> createState() => _MonitorControlViewState();
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

  void _moveShortcut(int index, int delta, StateSetter refreshSheet) {
    final next = index + delta;
    if (next < 0 || next >= _shortcuts.length) return;
    setState(() {
      final shortcut = _shortcuts.removeAt(index);
      _shortcuts.insert(next, shortcut);
    });
    refreshSheet(() {});
    _emitShortcuts();
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
                        setState(() => _shortcuts[index] = preset.copyWith(
                            modifiers: orderedModifiers, key: key));
                        refreshSheet(() {});
                        _emitShortcuts();
                        Navigator.of(dialogContext).pop();
                      },
                      child: const Text('Save shortcut')),
                ],
              ),
            ));
  }

  void _showShortcutSettings() {
    showModalBottomSheet<void>(
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
                          setState(() =>
                              _shortcuts = List.of(kDefaultMonitorShortcuts));
                          refreshSheet(() {});
                          _emitShortcuts();
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

  Widget _keyButton(String label, PhysicalKeyboardKey key) => OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(48, 48)),
      onPressed: () => widget.onKey(key),
      child: Text(label));

  Widget _modifierButton(String label, PhysicalKeyboardKey key) {
    final held = _held.contains(key);
    return OutlinedButton(
        style: OutlinedButton.styleFrom(
            minimumSize: const Size(48, 48),
            backgroundColor:
                held ? MirpgRemoteTheme.accent.withOpacity(0.18) : null,
            foregroundColor: held ? MirpgRemoteTheme.accent : null),
        onPressed:
            widget.onKeyState == null ? null : () => _toggleModifier(key),
        child: Text(label));
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
  static const Size _floatingMouseSize = Size(132, 52);
  static const Offset _cursorFingerOffset = Offset(0, -56);
  late Offset _cursor = widget.desktopSize.center(Offset.zero);
  Size _viewport = Size.zero;
  Offset _offset = Offset.zero;
  double _fit = 1;
  double? _zoom;
  late _MonitorViewPreset _viewPreset;
  late MonitorViewPreference _preferredView;
  bool _panMode = false;
  late bool _precision;
  late double _precisionGain;
  bool _dragLocked = false;
  bool _gestureDragHeld = false;
  bool _doubleTapArmed = false;
  bool _doubleTapCandidate = false;
  Timer? _doubleTapHoldTimer;
  Timer? _doubleTapWindowTimer;
  Offset? _doubleTapLocalPosition;
  double _doubleTapPendingTravel = 0;
  late MonitorToolbarDock _toolbarDock;
  late bool _toolbarVisible;
  late bool _thumbwheelVisible;
  late bool _mouseButtonsVisible;
  late Offset _mouseButtonsPosition;
  late bool _cursorOffset;
  late List<MonitorShortcutPreset> _shortcuts;
  late MonitorOrientationPreference _orientationPreference;
  bool _floatingLeftPressed = false;
  bool _floatingRightPressed = false;
  double _thumbwheelDelta = 0;
  double _gestureScale = 1;
  double _wheel = 0;
  int _fingers = 0;
  int _maxFingers = 0;
  final Set<int> _rawPointers = <int>{};
  int _rawMaxFingers = 0;
  bool _suppressTap = false;
  Offset? _tapLocalPosition;
  Offset _lastFocal = Offset.zero;
  _TwoFingerMode _twoFingerMode = _TwoFingerMode.undecided;
  int _twoFingerUpdates = 0;
  double _twoFingerStartScale = 1;
  Offset _twoFingerPendingDelta = Offset.zero;
  _MonitorPanel _panel = _MonitorPanel.none;
  double get _scale => _fit * (_zoom ?? 1);
  bool get _canSendInput => widget.canControl && !widget.localViewOnly;

  @override
  void initState() {
    super.initState();
    _loadPreferences(widget.preferences);
  }

  @override
  void didUpdateWidget(covariant MonitorControlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.preferences != widget.preferences) {
      _loadPreferences(widget.preferences, keepCustomZoom: true);
    }
    if ((_dragLocked || _gestureDragHeld) && !_canSendInput) {
      final shouldRelease = oldWidget.canControl && !oldWidget.localViewOnly;
      _dragLocked = false;
      _gestureDragHeld = false;
      _doubleTapHoldTimer?.cancel();
      _doubleTapHoldTimer = null;
      if (shouldRelease) {
        widget.onPointer(1, _cursor);
      }
    }
    if (!_canSendInput) {
      _doubleTapHoldTimer?.cancel();
      _doubleTapWindowTimer?.cancel();
      _doubleTapHoldTimer = null;
      _doubleTapWindowTimer = null;
      _doubleTapArmed = false;
      _doubleTapCandidate = false;
      _floatingLeftPressed = false;
      _floatingRightPressed = false;
    }
  }

  @override
  void dispose() {
    _doubleTapHoldTimer?.cancel();
    _doubleTapWindowTimer?.cancel();
    if ((_dragLocked || _gestureDragHeld) && _canSendInput) {
      widget.onPointer(1, _cursor);
    }
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
    _precision = preferences.precision;
    _precisionGain = preferences.precisionGain;
    _toolbarDock = preferences.toolbarDock;
    _toolbarVisible = preferences.toolbarVisible;
    _thumbwheelVisible = preferences.thumbwheelVisible;
    _mouseButtonsVisible = preferences.mouseButtonsVisible;
    _mouseButtonsPosition = preferences.mouseButtonsPosition;
    _cursorOffset = preferences.cursorOffset;
    _shortcuts = List.of(preferences.shortcuts);
    _orientationPreference = preferences.orientation;
  }

  void _emitPreferences() {
    widget.onPreferencesChanged?.call(MonitorControlPreferences(
      preferredView: _preferredView,
      precision: _precision,
      precisionGain: _precisionGain,
      toolbarDock: _toolbarDock,
      toolbarVisible: _toolbarVisible,
      thumbwheelVisible: _thumbwheelVisible,
      mouseButtonsVisible: _mouseButtonsVisible,
      mouseButtonsPosition: _mouseButtonsPosition,
      cursorOffset: _cursorOffset,
      shortcuts: List.unmodifiable(_shortcuts),
      orientation: _orientationPreference,
    ));
  }

  void _limitOffset() {
    final width = widget.desktopSize.width * _scale;
    final height = widget.desktopSize.height * _scale;
    _offset = Offset(
        width <= _viewport.width
            ? (_viewport.width - width) / 2
            : _offset.dx.clamp(_viewport.width - width, 0).toDouble(),
        height <= _viewport.height
            ? (_viewport.height - height) / 2
            : _offset.dy.clamp(_viewport.height - height, 0).toDouble());
  }

  void _setZoom(double zoom, Offset focus,
      {_MonitorViewPreset preset = _MonitorViewPreset.custom}) {
    final point = (focus - _offset) / _scale;
    _zoom = zoom.clamp(1, 6).toDouble();
    _viewPreset = preset;
    _offset = focus - point * _scale;
    _limitOffset();
    if (_canSendInput && !_panMode) _followCursor();
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

  void _cycleOrientation() {
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

  void _followCursor() {
    final point = _offset + _cursor * _scale;
    final margin = math.min(48.0, _viewport.shortestSide / 4);
    _offset += Offset(
        point.dx < margin
            ? margin - point.dx
            : point.dx > _viewport.width - margin
                ? _viewport.width - margin - point.dx
                : 0,
        point.dy < margin
            ? margin - point.dy
            : point.dy > _viewport.height - margin
                ? _viewport.height - margin - point.dy
                : 0);
    _limitOffset();
  }

  void _move(Offset delta) {
    if (!_canSendInput) return;
    final gain = _precision ? _precisionGain : 1.0;
    final point = _cursor + delta / _scale * gain;
    _cursor = Offset(point.dx.clamp(0, widget.desktopSize.width - 1).toDouble(),
        point.dy.clamp(0, widget.desktopSize.height - 1).toDouble());
    _followCursor();
    widget.onPointer(2, _cursor);
  }

  Offset _sourcePointForLocal(Offset localPosition) {
    final viewportPoint = localPosition + _cursorFingerOffset;
    final point = (viewportPoint - _offset) / _scale;
    return Offset(
      point.dx.clamp(0, widget.desktopSize.width - 1).toDouble(),
      point.dy.clamp(0, widget.desktopSize.height - 1).toDouble(),
    );
  }

  void _moveToLocal(Offset localPosition) {
    if (!_canSendInput) return;
    _cursor = _sourcePointForLocal(localPosition);
    widget.onPointer(2, _cursor);
  }

  void _click([int count = 1]) {
    if (!_canSendInput) return;
    for (var i = 0; i < count; i++) {
      widget.onPointer(0, _cursor);
      widget.onPointer(1, _cursor);
    }
  }

  void _tap() {
    if (_suppressTap) {
      _suppressTap = false;
      _doubleTapCandidate = false;
      return;
    }
    final secondTap = _doubleTapCandidate;
    _doubleTapHoldTimer?.cancel();
    _doubleTapHoldTimer = null;
    _doubleTapCandidate = false;
    if (_cursorOffset && _tapLocalPosition != null) {
      _moveToLocal(_tapLocalPosition!);
    }
    _click();
    if (!secondTap && _canSendInput && _tapLocalPosition != null) {
      _armDoubleTap(_tapLocalPosition!);
    }
  }

  void _armDoubleTap(Offset localPosition) {
    _doubleTapWindowTimer?.cancel();
    _doubleTapArmed = true;
    _doubleTapLocalPosition = localPosition;
    _doubleTapWindowTimer = Timer(const Duration(milliseconds: 350), () {
      _doubleTapWindowTimer = null;
      _doubleTapArmed = false;
    });
  }

  void _beginDoubleTapHold(Offset localPosition) {
    _doubleTapWindowTimer?.cancel();
    _doubleTapWindowTimer = null;
    _doubleTapArmed = false;
    _doubleTapCandidate = true;
    _doubleTapPendingTravel = 0;
    _doubleTapLocalPosition = localPosition;
    _doubleTapHoldTimer?.cancel();
    _doubleTapHoldTimer = Timer(const Duration(milliseconds: 250), () {
      _doubleTapHoldTimer = null;
      if (!mounted ||
          !_canSendInput ||
          _panMode ||
          _rawPointers.length != 1 ||
          _rawMaxFingers > 1 ||
          !_doubleTapCandidate) {
        return;
      }
      setState(() {
        if (_cursorOffset && _doubleTapLocalPosition != null) {
          _moveToLocal(_doubleTapLocalPosition!);
        }
        _gestureDragHeld = true;
        _doubleTapCandidate = false;
      });
      widget.onPointer(0, _cursor);
    });
  }

  void _cancelDoubleTapCandidate() {
    _doubleTapHoldTimer?.cancel();
    _doubleTapHoldTimer = null;
    _doubleTapCandidate = false;
    _doubleTapPendingTravel = 0;
  }

  void _releaseGestureDrag() {
    if (!_gestureDragHeld) return;
    setState(() => _gestureDragHeld = false);
    widget.onPointer(1, _cursor);
  }

  void _scaleUpdate(ScaleUpdateDetails details) {
    _maxFingers = math.max(_maxFingers, details.pointerCount);
    if (_fingers != details.pointerCount) {
      _fingers = details.pointerCount;
      _lastFocal = details.localFocalPoint;
      _gestureScale = details.scale;
      if (details.pointerCount >= 2) {
        _twoFingerMode = _TwoFingerMode.undecided;
        _twoFingerUpdates = 0;
        _twoFingerStartScale = details.scale;
        _twoFingerPendingDelta = Offset.zero;
      }
      return;
    }
    final delta = details.localFocalPoint - _lastFocal;
    final factor = details.scale / _gestureScale;
    if (_doubleTapCandidate &&
        !_gestureDragHeld &&
        _doubleTapHoldTimer != null) {
      _doubleTapPendingTravel += delta.distance;
      if (_doubleTapPendingTravel > 8) _cancelDoubleTapCandidate();
    }
    setState(() {
      if (_maxFingers >= 2) {
        _twoFingerUpdates++;
        _twoFingerPendingDelta += delta;
        if (_twoFingerMode == _TwoFingerMode.undecided &&
            _twoFingerUpdates >= 2) {
          final scaleChange = (details.scale / _twoFingerStartScale - 1).abs();
          if (scaleChange >= 0.04) {
            _twoFingerMode = _TwoFingerMode.pinch;
          } else if (_twoFingerPendingDelta.distance >= 6) {
            _twoFingerMode = _TwoFingerMode.scroll;
          }
        }
        if (_twoFingerMode == _TwoFingerMode.pinch) {
          _setZoom((_zoom ?? 1) * factor, details.localFocalPoint);
        } else if (_twoFingerMode == _TwoFingerMode.scroll && _canSendInput) {
          _wheel += _twoFingerPendingDelta.dy / 8;
          final steps = _wheel.truncate();
          if (steps != 0) {
            widget.onScroll(steps);
            _wheel -= steps;
          }
          _twoFingerPendingDelta = Offset.zero;
        }
      } else if (_panMode || !_canSendInput) {
        _offset += delta;
        _limitOffset();
      } else if (_canSendInput) {
        if (_cursorOffset) {
          _moveToLocal(details.localFocalPoint);
        } else {
          _move(delta);
        }
      }
      _lastFocal = details.localFocalPoint;
      _gestureScale = details.scale;
    });
  }

  void _scaleEnd(ScaleEndDetails details) {
    _fingers = 0;
    _maxFingers = 0;
    _wheel = 0;
    _twoFingerMode = _TwoFingerMode.undecided;
    _twoFingerUpdates = 0;
    _twoFingerPendingDelta = Offset.zero;
  }

  void _rawPointerDown(PointerDownEvent event) {
    final firstPointer = _rawPointers.isEmpty;
    if (firstPointer) {
      _rawMaxFingers = 0;
    }
    _rawPointers.add(event.pointer);
    _rawMaxFingers = math.max(_rawMaxFingers, _rawPointers.length);
    if (firstPointer &&
        _doubleTapArmed &&
        _doubleTapLocalPosition != null &&
        (event.localPosition - _doubleTapLocalPosition!).distance <= 48 &&
        _canSendInput &&
        !_panMode) {
      _beginDoubleTapHold(event.localPosition);
    }
    if (_rawPointers.length > 1) {
      _cancelDoubleTapCandidate();
      if (_gestureDragHeld) _releaseGestureDrag();
    }
  }

  void _rawPointerUp(PointerEvent event) {
    _rawPointers.remove(event.pointer);
    if (_rawPointers.isNotEmpty) return;
    _doubleTapHoldTimer?.cancel();
    _doubleTapHoldTimer = null;
    final releasedGestureDrag = _gestureDragHeld;
    if (_gestureDragHeld) {
      _releaseGestureDrag();
    }
    if (event is PointerCancelEvent) _doubleTapCandidate = false;
    _suppressTap = releasedGestureDrag || _rawMaxFingers >= 2;
    _rawMaxFingers = 0;
  }

  Widget _button(String tooltip, IconData icon, VoidCallback? action,
          {bool selected = false}) =>
      SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
              tooltip: tooltip,
              icon: Icon(icon),
              color: selected ? MirpgRemoteTheme.accent : Colors.white,
              disabledColor: Colors.white38,
              padding: EdgeInsets.zero,
              onPressed: action));

  void _showGestureHelp() {
    showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        builder: (_) => SingleChildScrollView(
            child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const ListTile(
                      leading: Icon(Icons.mouse_outlined),
                      title: Text('Windows Pointer'),
                      subtitle: Text(
                          'Phone gestures control the Windows mouse. Local zoom and Pan never change Windows resolution.')),
                  ListTile(
                      leading: const Icon(Icons.touch_app_outlined),
                      title: const Text('One finger'),
                      subtitle: Text(_cursorOffset
                          ? 'Cursor offset is on. The pointer stays above your finger; tap to left-click and hold to right-click.'
                          : 'Swipe to move the pointer. Tap to left-click. Hold to right-click.')),
                  const ListTile(
                      leading: Icon(Icons.drag_indicator),
                      title: Text('Double tap and hold'),
                      subtitle: Text(
                          'Hold the second tap to drag. Lift your finger to release the left mouse button.')),
                  const ListTile(
                      leading: Icon(Icons.zoom_out_map),
                      title: Text('Two fingers'),
                      subtitle: Text(
                          'Pinch to zoom. Drag together to scroll the remote computer.')),
                ]))));
  }

  void _showPrecisionSettings() {
    showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        builder: (_) => StatefulBuilder(builder: (context, setSheetState) {
              final percent = (_precisionGain * 100).round();
              return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      const Expanded(
                          child: Text('Precision pointer speed',
                              style: TextStyle(fontWeight: FontWeight.w600))),
                      IconButton(
                          tooltip: 'Close precision settings',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close)),
                    ]),
                    Text('Pointer gain $percent%'),
                    Slider(
                        value: _precisionGain,
                        min: 0.1,
                        max: 1,
                        divisions: 18,
                        label: '$percent%',
                        onChanged: (value) {
                          setState(() => _precisionGain = value);
                          setSheetState(() {});
                          _emitPreferences();
                        }),
                    TextButton(
                        onPressed: () {
                          setState(() => _precisionGain = 0.35);
                          setSheetState(() {});
                          _emitPreferences();
                        },
                        child: const Text('Reset to 35%')),
                  ]));
            }));
  }

  void _resetControls() {
    const defaults = MonitorControlPreferences();
    setState(() {
      _loadPreferences(defaults);
      _limitOffset();
    });
    _emitPreferences();
  }

  Widget _actionsPanel() => Material(
      color: MirpgRemoteTheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
          padding: const EdgeInsets.all(6),
          child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _button(
                    'Left click', Icons.mouse, _canSendInput ? _click : null),
                _button('Right click', Icons.ads_click,
                    _canSendInput ? () => widget.onPointer(3, _cursor) : null),
                _button('Middle click', Icons.mouse_outlined,
                    _canSendInput ? () => widget.onPointer(4, _cursor) : null),
                _button('Pan', Icons.pan_tool_alt_outlined,
                    () => setState(() => _panMode = !_panMode),
                    selected: _panMode),
                _button(
                    'Precision',
                    Icons.gps_fixed,
                    _canSendInput
                        ? () {
                            setState(() => _precision = !_precision);
                            _emitPreferences();
                          }
                        : null,
                    selected: _precision),
                _button('Precision speed', Icons.tune, _showPrecisionSettings),
                _button('Drag lock', Icons.drag_indicator,
                    _canSendInput ? () => _setDragLocked(!_dragLocked) : null,
                    selected: _dragLocked),
                _button(
                    widget.localViewOnly ? 'Disable view only' : 'View only',
                    widget.localViewOnly
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    widget.onLocalViewOnlyChanged == null
                        ? null
                        : () => widget
                            .onLocalViewOnlyChanged!(!widget.localViewOnly),
                    selected: widget.localViewOnly),
                _button(
                    _toolbarDock == MonitorToolbarDock.right
                        ? 'Dock controls left'
                        : 'Dock controls right',
                    _toolbarDock == MonitorToolbarDock.right
                        ? Icons.align_horizontal_left
                        : Icons.align_horizontal_right, () {
                  setState(() {
                    _toolbarDock = _toolbarDock == MonitorToolbarDock.right
                        ? MonitorToolbarDock.left
                        : MonitorToolbarDock.right;
                  });
                  _emitPreferences();
                }),
                _button(
                    _mouseButtonsVisible
                        ? 'Hide mouse buttons'
                        : 'Show mouse buttons',
                    Icons.mouse_outlined, () {
                  setState(() => _mouseButtonsVisible = !_mouseButtonsVisible);
                  _emitPreferences();
                }, selected: _mouseButtonsVisible),
                _button(
                    _thumbwheelVisible ? 'Hide thumbwheel' : 'Show thumbwheel',
                    Icons.swap_vert, () {
                  setState(() => _thumbwheelVisible = !_thumbwheelVisible);
                  _emitPreferences();
                }, selected: _thumbwheelVisible),
                _button('Cursor offset', Icons.touch_app_outlined, () {
                  setState(() => _cursorOffset = !_cursorOffset);
                  _emitPreferences();
                }, selected: _cursorOffset),
                _button('Ctrl+Alt+Del', Icons.security,
                    _canSendInput ? widget.onCtrlAltDel : null),
                _button('Gestures', Icons.help_outline, _showGestureHelp),
                _button('Reset controls', Icons.restart_alt, _resetControls),
              ]))));

  Widget _displayPanel() => Material(
      color: MirpgRemoteTheme.surface,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _button('Fit screen', Icons.fit_screen,
                () => setState(() => _applyPreset(_MonitorViewPreset.fit))),
            _button(
                'Readable',
                Icons.text_fields,
                () =>
                    setState(() => _applyPreset(_MonitorViewPreset.readable))),
            _button(
                'Zoom out',
                Icons.zoom_out,
                () => setState(() => _setZoom(
                    (_zoom ?? 1) / 1.25, _viewport.center(Offset.zero)))),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(_viewLabel,
                    style: const TextStyle(color: Colors.white))),
            _button(
                'Zoom in',
                Icons.zoom_in,
                () => setState(() => _setZoom(
                    (_zoom ?? 1) * 1.25, _viewport.center(Offset.zero)))),
            _button('Orientation: $_orientationLabel', Icons.screen_rotation,
                _cycleOrientation),
          ])));

  Widget _toolbarButton(String tooltip, IconData icon, VoidCallback? action,
          {bool selected = false}) =>
      IconButton(
          tooltip: tooltip,
          color: selected ? MirpgRemoteTheme.accent : Colors.white,
          disabledColor: Colors.white38,
          icon: Icon(icon),
          onPressed: action);

  Widget _sessionToolbar() => Material(
      color: const Color(0xF2191F22),
      elevation: 10,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _toolbarButton('Keyboard', Icons.keyboard_outlined,
                _canSendInput ? widget.onKeyboard : null),
            _toolbarButton(
                'Actions',
                Icons.bolt_outlined,
                () => setState(() => _panel = _panel == _MonitorPanel.actions
                    ? _MonitorPanel.none
                    : _MonitorPanel.actions),
                selected: _panel == _MonitorPanel.actions),
            _toolbarButton(
                'Display',
                Icons.monitor_outlined,
                () => setState(() => _panel = _panel == _MonitorPanel.display
                    ? _MonitorPanel.none
                    : _MonitorPanel.display),
                selected: _panel == _MonitorPanel.display),
            _toolbarButton('Switch view', Icons.view_carousel_outlined,
                widget.onSwitchView),
            _toolbarButton(
                'Dashboard', Icons.grid_view_outlined, widget.onDashboard),
            _toolbarButton('Hide toolbar', Icons.keyboard_arrow_down, () {
              setState(() {
                _toolbarVisible = false;
                _panel = _MonitorPanel.none;
              });
              _emitPreferences();
            }),
          ])));

  void _setDragLocked(bool locked) {
    if (locked && !_canSendInput) return;
    if (_dragLocked == locked) return;
    setState(() => _dragLocked = locked);
    widget.onPointer(locked ? 0 : 1, _cursor);
  }

  Offset _floatingMouseTopLeft() {
    final maxX = math.max(0.0, _viewport.width - _floatingMouseSize.width);
    final maxY = math.max(0.0, _viewport.height - _floatingMouseSize.height);
    return Offset(
        _mouseButtonsPosition.dx * maxX, _mouseButtonsPosition.dy * maxY);
  }

  void _moveFloatingMouse(Offset delta) {
    final maxX = math.max(1.0, _viewport.width - _floatingMouseSize.width);
    final maxY = math.max(1.0, _viewport.height - _floatingMouseSize.height);
    _mouseButtonsPosition = Offset(
      (_mouseButtonsPosition.dx + delta.dx / maxX).clamp(0.0, 1.0).toDouble(),
      (_mouseButtonsPosition.dy + delta.dy / maxY).clamp(0.0, 1.0).toDouble(),
    );
  }

  void _setFloatingButton(bool left, bool down) {
    if (down && !_canSendInput) return;
    final wasDown = left ? _floatingLeftPressed : _floatingRightPressed;
    if (wasDown == down) return;
    setState(() {
      if (left) {
        _floatingLeftPressed = down;
      } else {
        _floatingRightPressed = down;
      }
    });
    widget.onPointer(left ? (down ? 0 : 1) : (down ? 5 : 6), _cursor);
  }

  Widget _floatingMouseButton(
      String tooltip, IconData icon, bool left, bool pressed) {
    return Tooltip(
      message: tooltip,
      child: Listener(
        onPointerDown:
            _canSendInput ? (_) => _setFloatingButton(left, true) : null,
        onPointerUp:
            _canSendInput ? (_) => _setFloatingButton(left, false) : null,
        onPointerCancel:
            _canSendInput ? (_) => _setFloatingButton(left, false) : null,
        child: Semantics(
          button: true,
          enabled: _canSendInput,
          label: tooltip,
          child: SizedBox(
            width: 48,
            height: 48,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: pressed
                    ? MirpgRemoteTheme.accent.withOpacity(0.24)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon,
                  color: _canSendInput
                      ? pressed
                          ? MirpgRemoteTheme.accent
                          : Colors.white
                      : Colors.white38),
            ),
          ),
        ),
      ),
    );
  }

  Widget _floatingMouseButtons() {
    return Material(
      key: const ValueKey('monitor-mouse-buttons'),
      color: const Color(0xF2191F22),
      elevation: 8,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        width: _floatingMouseSize.width,
        height: _floatingMouseSize.height,
        child: Row(children: [
          GestureDetector(
            key: const ValueKey('monitor-mouse-buttons-drag'),
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) =>
                setState(() => _moveFloatingMouse(details.delta)),
            onPanEnd: (_) => _emitPreferences(),
            child: const SizedBox(
              width: 32,
              height: 52,
              child:
                  Icon(Icons.drag_indicator, color: Colors.white70, size: 20),
            ),
          ),
          _floatingMouseButton('Remote left mouse button', Icons.mouse, true,
              _floatingLeftPressed),
          _floatingMouseButton('Remote right mouse button', Icons.ads_click,
              false, _floatingRightPressed),
        ]),
      ),
    );
  }

  Widget _thumbwheel() {
    return GestureDetector(
      key: const ValueKey('monitor-thumbwheel'),
      behavior: HitTestBehavior.opaque,
      onVerticalDragUpdate: _canSendInput
          ? (details) {
              _thumbwheelDelta += details.delta.dy / 8;
              final steps = _thumbwheelDelta.truncate();
              if (steps != 0) {
                widget.onScroll(steps);
                _thumbwheelDelta -= steps;
              }
            }
          : null,
      onVerticalDragEnd: (_) => _thumbwheelDelta = 0,
      onVerticalDragCancel: () => _thumbwheelDelta = 0,
      child: Material(
        color: const Color(0xF2191F22),
        elevation: 8,
        borderRadius: BorderRadius.circular(18),
        child: SizedBox(
          width: 44,
          height: 144,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.keyboard_arrow_up, color: Colors.white70),
            const SizedBox(height: 12),
            Icon(Icons.unfold_more,
                color: _canSendInput ? Colors.white : Colors.white38),
            const SizedBox(height: 12),
            const Icon(Icons.keyboard_arrow_down, color: Colors.white70),
          ]),
        ),
      ),
    );
  }

  Rect _visibleSourceRect() {
    final left =
        (-_offset.dx / _scale).clamp(0.0, widget.desktopSize.width).toDouble();
    final top =
        (-_offset.dy / _scale).clamp(0.0, widget.desktopSize.height).toDouble();
    final right = ((_viewport.width - _offset.dx) / _scale)
        .clamp(0.0, widget.desktopSize.width)
        .toDouble();
    final bottom = ((_viewport.height - _offset.dy) / _scale)
        .clamp(0.0, widget.desktopSize.height)
        .toDouble();
    return Rect.fromLTRB(
        left, top, math.max(left, right), math.max(top, bottom));
  }

  void _navigateMinimap(Offset localPosition, Size minimapSize) {
    final source = Offset(
      (localPosition.dx / minimapSize.width).clamp(0.0, 1.0).toDouble() *
          widget.desktopSize.width,
      (localPosition.dy / minimapSize.height).clamp(0.0, 1.0).toDouble() *
          widget.desktopSize.height,
    );
    _offset = _viewport.center(Offset.zero) - source * _scale;
    _limitOffset();
  }

  Widget _minimap() {
    final aspect = widget.desktopSize.height / widget.desktopSize.width;
    var width = math.min(176.0, _viewport.width * 0.36);
    var height = width * aspect;
    if (height > 116) {
      height = 116;
      width = height / aspect;
    }
    final minimapSize = Size(width, height);
    final visible = _visibleSourceRect();
    final left = visible.left / widget.desktopSize.width * width;
    final top = visible.top / widget.desktopSize.height * height;
    final rectWidth = visible.width / widget.desktopSize.width * width;
    final rectHeight = visible.height / widget.desktopSize.height * height;

    return GestureDetector(
      key: const ValueKey('monitor-minimap'),
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) =>
          setState(() => _navigateMinimap(details.localPosition, minimapSize)),
      onPanUpdate: (details) =>
          setState(() => _navigateMinimap(details.localPosition, minimapSize)),
      child: Material(
        color: Colors.black,
        elevation: 8,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          height: height,
          child: Stack(children: [
            Positioned.fill(
              child: RawImage(
                key: const ValueKey('monitor-minimap-image'),
                image: widget.image,
                fit: BoxFit.fill,
                filterQuality: FilterQuality.low,
              ),
            ),
            if (widget.image == null)
              const Positioned.fill(
                  child: ColoredBox(color: Color(0xFF242C30))),
            Positioned(
              left: left,
              top: top,
              width: math.max(8, rectWidth),
              height: math.max(8, rectHeight),
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border:
                        Border.all(color: MirpgRemoteTheme.accent, width: 2),
                  ),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _modeBadge() {
    final labels = <String>[
      if (_dragLocked) 'Drag locked',
      if (_gestureDragHeld) 'Dragging',
      if (_panMode) 'Pan',
      if (_precision) 'Precision ${(_precisionGain * 100).round()}%',
      if (_cursorOffset) 'Cursor offset',
    ];
    return Material(
      color: const Color(0xF2191F22),
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(labels.join(' · '),
              style: const TextStyle(color: MirpgRemoteTheme.textPrimary)),
          if (_dragLocked) ...[
            const SizedBox(width: 8),
            TextButton(
                onPressed: _canSendInput ? () => _setDragLocked(false) : null,
                child: const Text('Release')),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        if (size.isEmpty || widget.desktopSize.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_viewport != size) {
          _viewport = size;
          _fit = math.min(size.width / widget.desktopSize.width,
              size.height / widget.desktopSize.height);
          if (_viewPreset == _MonitorViewPreset.readable) {
            _zoom = (1 / _fit).clamp(1.0, 6.0).toDouble();
          } else if (_viewPreset == _MonitorViewPreset.fit) {
            _zoom = 1;
          } else {
            _zoom ??= 1;
          }
          _offset = size.center(Offset.zero) - _cursor * _scale;
          _limitOffset();
        }
        final floatingMouse = _floatingMouseTopLeft();
        return Stack(children: [
          Positioned.fill(
              child: Listener(
                  onPointerDown: _rawPointerDown,
                  onPointerUp: _rawPointerUp,
                  onPointerCancel: _rawPointerUp,
                  child: Semantics(
                      label:
                          'Windows mouse interaction. Swipe with one finger to move the pointer, tap to click, hold to right-click, pinch to zoom, and drag with two fingers to scroll.',
                      child: GestureDetector(
                          key: const ValueKey('monitor-trackpad'),
                          behavior: HitTestBehavior.opaque,
                          onTapDown: _panMode
                              ? null
                              : (details) =>
                                  _tapLocalPosition = details.localPosition,
                          onTap: _panMode ? null : _tap,
                          onLongPressStart: _canSendInput && !_panMode
                              ? (details) {
                                  if (_doubleTapCandidate ||
                                      _doubleTapHoldTimer != null ||
                                      _gestureDragHeld) {
                                    return;
                                  }
                                  if (_cursorOffset) {
                                    setState(() =>
                                        _moveToLocal(details.localPosition));
                                  }
                                  widget.onPointer(3, _cursor);
                                }
                              : null,
                          onScaleStart: (details) {
                            _fingers = details.pointerCount;
                            _maxFingers = details.pointerCount;
                            _lastFocal = details.localFocalPoint;
                            _gestureScale = 1;
                            _wheel = 0;
                            _twoFingerMode = _TwoFingerMode.undecided;
                            _twoFingerUpdates = 0;
                            _twoFingerStartScale = 1;
                            _twoFingerPendingDelta = Offset.zero;
                          },
                          onScaleUpdate: _scaleUpdate,
                          onScaleEnd: _scaleEnd,
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
                            if (widget.canControl)
                              Positioned(
                                  left: _offset.dx + _cursor.dx * _scale - 3,
                                  top: _offset.dy + _cursor.dy * _scale - 3,
                                  child: const IgnorePointer(
                                      child: Icon(Icons.north_west,
                                          size: 24,
                                          color: Colors.white,
                                          shadows: [
                                        Shadow(
                                            blurRadius: 3, color: Colors.black)
                                      ]))),
                          ])))))),
          if ((_zoom ?? 1) > 1.01)
            Positioned(top: 12, right: 12, child: _minimap()),
          if (_dragLocked ||
              _gestureDragHeld ||
              _panMode ||
              _precision ||
              _cursorOffset)
            Positioned(top: 12, left: 12, child: _modeBadge()),
          if (_mouseButtonsVisible)
            Positioned(
                left: floatingMouse.dx,
                top: floatingMouse.dy,
                child: _floatingMouseButtons()),
          if (_thumbwheelVisible)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 8 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 8 : null,
                top: math.max(12, (_viewport.height - 144) / 2),
                child: _thumbwheel()),
          if (_toolbarVisible && _panel != _MonitorPanel.none)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 8 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 8 : null,
                bottom: 72,
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: math.max(0, _viewport.width - 16)),
                    child: _panel == _MonitorPanel.actions
                        ? _actionsPanel()
                        : _displayPanel())),
          if (_toolbarVisible)
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 8 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 8 : null,
                bottom: 8,
                child: _sessionToolbar())
          else
            Positioned(
                left: _toolbarDock == MonitorToolbarDock.left ? 4 : null,
                right: _toolbarDock == MonitorToolbarDock.right ? 4 : null,
                bottom: 4,
                child: Material(
                    color: const Color(0xF2191F22),
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

enum _MonitorPanel { none, actions, display }

enum _TwoFingerMode { undecided, scroll, pinch }

enum _MonitorViewPreset { fit, readable, custom }

enum _MonitorKeyboardMode { text, keys }
