import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'mirpg_remote_theme.dart';

class MonitorControlView extends StatefulWidget {
  const MonitorControlView(
      {super.key,
      required this.desktopSize,
      this.image,
      required this.canControl,
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
      {super.key, required this.onText, required this.onKey, this.onKeyState});
  final ValueChanged<String> onText;
  final ValueChanged<PhysicalKeyboardKey> onKey;
  final void Function(PhysicalKeyboardKey key, bool down)? onKeyState;

  @override
  State<MonitorKeyboardPanel> createState() => _MonitorKeyboardPanelState();
}

class _MonitorKeyboardPanelState extends State<MonitorKeyboardPanel>
    with WidgetsBindingObserver {
  final _text = TextEditingController();
  final _textFocus = FocusNode();
  final _held = <PhysicalKeyboardKey>{};
  _MonitorKeyboardMode _mode = _MonitorKeyboardMode.text;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
            if (_mode == _MonitorKeyboardMode.text)
              TextField(
                  controller: _text,
                  focusNode: _textFocus,
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
                          icon: const Icon(Icons.send_outlined))))
            else ...[
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
              ]),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton(
                    onPressed: () => _shortcut(
                        [PhysicalKeyboardKey.altLeft], PhysicalKeyboardKey.tab),
                    child: const Text('Alt+Tab')),
                OutlinedButton(
                    onPressed: () => _shortcut(
                        [PhysicalKeyboardKey.controlLeft],
                        PhysicalKeyboardKey.keyC),
                    child: const Text('Ctrl+C')),
                OutlinedButton(
                    onPressed: () => _shortcut(
                        [PhysicalKeyboardKey.controlLeft],
                        PhysicalKeyboardKey.keyV),
                    child: const Text('Ctrl+V')),
                OutlinedButton(
                    onPressed: () => _shortcut(
                        [PhysicalKeyboardKey.controlLeft],
                        PhysicalKeyboardKey.keyZ),
                    child: const Text('Ctrl+Z')),
                OutlinedButton(
                    onPressed: () => _shortcut([
                          PhysicalKeyboardKey.controlLeft,
                          PhysicalKeyboardKey.shiftLeft
                        ], PhysicalKeyboardKey.escape),
                    child: const Text('Ctrl+Shift+Esc')),
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
  static const double _precisionGain = 0.35;
  late Offset _cursor = widget.desktopSize.center(Offset.zero);
  Size _viewport = Size.zero;
  Offset _offset = Offset.zero;
  double _fit = 1;
  double? _zoom;
  _MonitorViewPreset _viewPreset = _MonitorViewPreset.fit;
  bool _panMode = false;
  bool _precision = false;
  bool _dragLocked = false;
  _ToolbarDock _toolbarDock = _ToolbarDock.right;
  double _gestureScale = 1;
  double _wheel = 0;
  int _fingers = 0;
  int _maxFingers = 0;
  final Set<int> _rawPointers = <int>{};
  int _rawMaxFingers = 0;
  bool _suppressTap = false;
  Offset _lastFocal = Offset.zero;
  _TwoFingerMode _twoFingerMode = _TwoFingerMode.undecided;
  int _twoFingerUpdates = 0;
  double _twoFingerStartScale = 1;
  Offset _twoFingerPendingDelta = Offset.zero;
  bool _toolbarVisible = true;
  _MonitorPanel _panel = _MonitorPanel.none;
  double get _scale => _fit * (_zoom ?? 1);
  bool get _canSendInput => widget.canControl && !widget.localViewOnly;

  @override
  void didUpdateWidget(covariant MonitorControlView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_dragLocked && !_canSendInput) {
      _dragLocked = false;
      if (oldWidget.canControl && !oldWidget.localViewOnly) {
        widget.onPointer(1, _cursor);
      }
    }
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
      _limitOffset();
      return;
    }
    final readableZoom = (1 / _fit).clamp(1.0, 6.0).toDouble();
    _setZoom(readableZoom, _viewport.center(Offset.zero), preset: preset);
  }

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
      return;
    }
    _click();
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
        _move(delta);
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
    if (_rawPointers.isEmpty) {
      _rawMaxFingers = 0;
    }
    _rawPointers.add(event.pointer);
    _rawMaxFingers = math.max(_rawMaxFingers, _rawPointers.length);
  }

  void _rawPointerUp(PointerEvent event) {
    _rawPointers.remove(event.pointer);
    if (_rawPointers.isNotEmpty) return;
    _suppressTap = _rawMaxFingers >= 2;
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
        builder: (_) => const Padding(
            padding: EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(
                  leading: Icon(Icons.touch_app_outlined),
                  title: Text('One finger'),
                  subtitle: Text(
                      'Swipe to move the pointer. Tap to left-click. Hold to right-click.')),
              ListTile(
                  leading: Icon(Icons.zoom_out_map),
                  title: Text('Two fingers'),
                  subtitle: Text(
                      'Pinch to zoom. Drag together to scroll the remote computer.')),
            ])));
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
                        ? () => setState(() => _precision = !_precision)
                        : null,
                    selected: _precision),
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
                    _toolbarDock == _ToolbarDock.right
                        ? 'Dock controls left'
                        : 'Dock controls right',
                    _toolbarDock == _ToolbarDock.right
                        ? Icons.align_horizontal_left
                        : Icons.align_horizontal_right,
                    () => setState(() {
                          _toolbarDock = _toolbarDock == _ToolbarDock.right
                              ? _ToolbarDock.left
                              : _ToolbarDock.right;
                        })),
                _button('Ctrl+Alt+Del', Icons.security,
                    _canSendInput ? widget.onCtrlAltDel : null),
                _button('Gestures', Icons.help_outline, _showGestureHelp),
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
            }),
          ])));

  void _setDragLocked(bool locked) {
    if (locked && !_canSendInput) return;
    if (_dragLocked == locked) return;
    setState(() => _dragLocked = locked);
    widget.onPointer(locked ? 0 : 1, _cursor);
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
      if (_panMode) 'Pan',
      if (_precision) 'Precision 35%',
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
          _zoom ??= 1;
          _offset = size.center(Offset.zero) - _cursor * _scale;
          _limitOffset();
        }
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
                          onTap: _panMode ? null : _tap,
                          onLongPress: _canSendInput && !_panMode
                              ? () => widget.onPointer(3, _cursor)
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
          if (_dragLocked || _panMode || _precision)
            Positioned(top: 12, left: 12, child: _modeBadge()),
          if (_toolbarVisible && _panel != _MonitorPanel.none)
            Positioned(
                left: _toolbarDock == _ToolbarDock.left ? 8 : null,
                right: _toolbarDock == _ToolbarDock.right ? 8 : null,
                bottom: 72,
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxWidth: math.max(0, _viewport.width - 16)),
                    child: _panel == _MonitorPanel.actions
                        ? _actionsPanel()
                        : _displayPanel())),
          if (_toolbarVisible)
            Positioned(
                left: _toolbarDock == _ToolbarDock.left ? 8 : null,
                right: _toolbarDock == _ToolbarDock.right ? 8 : null,
                bottom: 8,
                child: _sessionToolbar())
          else
            Positioned(
                left: _toolbarDock == _ToolbarDock.left ? 4 : null,
                right: _toolbarDock == _ToolbarDock.right ? 4 : null,
                bottom: 4,
                child: Material(
                    color: const Color(0xF2191F22),
                    elevation: 8,
                    borderRadius: BorderRadius.circular(14),
                    child: IconButton(
                        tooltip: 'Show toolbar',
                        color: Colors.white,
                        icon: const Icon(Icons.keyboard_arrow_up),
                        onPressed: () =>
                            setState(() => _toolbarVisible = true)))),
        ]);
      });
}

enum _MonitorPanel { none, actions, display }

enum _TwoFingerMode { undecided, scroll, pinch }

enum _MonitorViewPreset { fit, readable, custom }

enum _MonitorKeyboardMode { text, keys }

enum _ToolbarDock { left, right }
