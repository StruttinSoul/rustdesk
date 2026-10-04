import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class MonitorControlView extends StatefulWidget {
  const MonitorControlView(
      {super.key,
      required this.desktopSize,
      this.image,
      required this.canControl,
      required this.onPointer,
      required this.onScroll,
      required this.onKeyboard,
      this.onSwitchView,
      this.onDashboard,
      this.onCtrlAltDel});
  final Size desktopSize;
  final ui.Image? image;
  final bool canControl;
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
      {super.key, required this.onText, required this.onKey});
  final ValueChanged<String> onText;
  final ValueChanged<PhysicalKeyboardKey> onKey;

  @override
  State<MonitorKeyboardPanel> createState() => _MonitorKeyboardPanelState();
}

class _MonitorKeyboardPanelState extends State<MonitorKeyboardPanel> {
  final _text = TextEditingController();
  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _send() {
    if (_text.text.isEmpty) return;
    widget.onText(_text.text);
    _text.clear();
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
      child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, 12, 16, MediaQuery.of(context).viewInsets.bottom + 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              const Expanded(child: Text('Windows keyboard')),
              IconButton(
                  tooltip: 'Close keyboard',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop())
            ]),
            TextField(
                controller: _text,
                autofocus: true,
                autocorrect: false,
                enableSuggestions: false,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                    labelText: 'Type text, then Send',
                    suffixIcon: IconButton(
                        tooltip: 'Send text',
                        onPressed: _send,
                        icon: const Icon(Icons.send_outlined)))),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final key in <String, PhysicalKeyboardKey>{
                'Esc': PhysicalKeyboardKey.escape,
                'Tab': PhysicalKeyboardKey.tab,
                'Windows': PhysicalKeyboardKey.metaLeft,
                'Enter': PhysicalKeyboardKey.enter,
                'Backspace': PhysicalKeyboardKey.backspace,
              }.entries)
                OutlinedButton(
                    style: OutlinedButton.styleFrom(
                        minimumSize: const Size(48, 48)),
                    onPressed: () => widget.onKey(key.value),
                    child: Text(key.key)),
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
          ])));
}

class _MonitorControlViewState extends State<MonitorControlView> {
  late Offset _cursor = widget.desktopSize.center(Offset.zero);
  Size _viewport = Size.zero;
  Offset _offset = Offset.zero;
  double _fit = 1;
  double? _zoom;
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

  void _setZoom(double zoom, Offset focus) {
    final point = (focus - _offset) / _scale;
    _zoom = zoom.clamp(1, 6).toDouble();
    _offset = focus - point * _scale;
    _limitOffset();
    if (widget.canControl) _followCursor();
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
    if (!widget.canControl) return;
    final point = _cursor + delta / _scale;
    _cursor = Offset(point.dx.clamp(0, widget.desktopSize.width - 1).toDouble(),
        point.dy.clamp(0, widget.desktopSize.height - 1).toDouble());
    _followCursor();
    widget.onPointer(2, _cursor);
  }

  void _click([int count = 1]) {
    if (!widget.canControl) return;
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
        } else if (_twoFingerMode == _TwoFingerMode.scroll &&
            widget.canControl) {
          _wheel += _twoFingerPendingDelta.dy / 8;
          final steps = _wheel.truncate();
          if (steps != 0) {
            widget.onScroll(steps);
            _wheel -= steps;
          }
          _twoFingerPendingDelta = Offset.zero;
        }
      } else if (widget.canControl) {
        _move(delta);
      } else {
        _offset += delta;
        _limitOffset();
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

  Widget _button(String tooltip, IconData icon, VoidCallback? action) =>
      SizedBox(
          width: 48,
          height: 48,
          child: IconButton(
              tooltip: tooltip,
              icon: Icon(icon),
              color: Colors.white,
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
      color: Colors.black87,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
          padding: const EdgeInsets.all(6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _button('Right click', Icons.ads_click,
                widget.canControl ? () => widget.onPointer(3, _cursor) : null),
            _button('Middle click', Icons.mouse_outlined,
                widget.canControl ? () => widget.onPointer(4, _cursor) : null),
            _button('Ctrl+Alt+Del', Icons.security,
                widget.canControl ? widget.onCtrlAltDel : null),
            _button('Gestures', Icons.help_outline, _showGestureHelp),
          ])));

  Widget _displayPanel() => Material(
      color: Colors.black87,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _button(
                'Fit screen',
                Icons.fit_screen,
                () =>
                    setState(() => _setZoom(1, _viewport.center(Offset.zero)))),
            _button(
                'Zoom out',
                Icons.zoom_out,
                () => setState(() => _setZoom(
                    (_zoom ?? 1) / 1.25, _viewport.center(Offset.zero)))),
            Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('${((_zoom ?? 1) * 100).round()}%',
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
          color: selected ? const Color(0xFF2D8CFF) : Colors.white,
          disabledColor: Colors.white38,
          icon: Icon(icon),
          onPressed: action);

  Widget _sessionToolbar() => Material(
      color: const Color(0xEE161B22),
      elevation: 10,
      borderRadius: BorderRadius.circular(18),
      child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _toolbarButton('Keyboard', Icons.keyboard_outlined,
                widget.canControl ? widget.onKeyboard : null),
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
                          onTap: _tap,
                          onLongPress: widget.canControl
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
          if (_toolbarVisible && _panel != _MonitorPanel.none)
            Positioned(
                left: 8,
                right: 8,
                bottom: 72,
                child: Center(
                    child: _panel == _MonitorPanel.actions
                        ? _actionsPanel()
                        : _displayPanel())),
          if (_toolbarVisible)
            Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Center(child: _sessionToolbar()))
          else
            Positioned(
                left: 0,
                right: 0,
                bottom: 4,
                child: Center(
                    child: Material(
                        color: const Color(0xEE161B22),
                        elevation: 8,
                        borderRadius: BorderRadius.circular(14),
                        child: IconButton(
                            tooltip: 'Show toolbar',
                            color: Colors.white,
                            icon: const Icon(Icons.keyboard_arrow_up),
                            onPressed: () =>
                                setState(() => _toolbarVisible = true))))),
        ]);
      });
}

enum _MonitorPanel { none, actions, display }

enum _TwoFingerMode { undecided, scroll, pinch }
