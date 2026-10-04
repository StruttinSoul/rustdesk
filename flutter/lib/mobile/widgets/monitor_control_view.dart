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
      this.onCtrlAltDel});
  final Size desktopSize;
  final ui.Image? image;
  final bool canControl;
  final void Function(int action, Offset point) onPointer;
  final void Function(int steps) onScroll;
  final VoidCallback onKeyboard;
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
  double _rawTravel = 0;
  bool _suppressTap = false;
  Offset _lastFocal = Offset.zero;
  bool _menuOpen = false;
  double? _menuY;
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
      return;
    }
    final delta = details.localFocalPoint - _lastFocal;
    final factor = details.scale / _gestureScale;
    setState(() {
      if (_maxFingers >= 3) {
        if (widget.canControl) {
          _wheel += delta.dy / 8;
          final steps = _wheel.truncate();
          if (steps != 0) {
            widget.onScroll(steps);
            _wheel -= steps;
          }
        }
      } else if (_maxFingers == 2) {
        if ((factor - 1).abs() > 0.001) {
          _setZoom((_zoom ?? 1) * factor, details.localFocalPoint);
        }
        _offset += delta;
        _limitOffset();
        if (widget.canControl) _followCursor();
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
  }

  void _rawPointerDown(PointerDownEvent event) {
    if (_rawPointers.isEmpty) {
      _rawMaxFingers = 0;
      _rawTravel = 0;
    }
    _rawPointers.add(event.pointer);
    _rawMaxFingers = math.max(_rawMaxFingers, _rawPointers.length);
  }

  void _rawPointerMove(PointerMoveEvent event) {
    if (_rawPointers.contains(event.pointer)) {
      _rawTravel += event.delta.distance;
    }
  }

  void _rawPointerUp(PointerEvent event) {
    _rawPointers.remove(event.pointer);
    if (_rawPointers.isNotEmpty) return;
    _suppressTap = _rawMaxFingers >= 2;
    if (_rawMaxFingers >= 3 && _rawTravel < 12 && widget.canControl) {
      widget.onPointer(4, _cursor);
    }
    _rawMaxFingers = 0;
    _rawTravel = 0;
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
                      'Pinch or move together to zoom and reposition the desktop.')),
              ListTile(
                  leading: Icon(Icons.swipe_vertical),
                  title: Text('Three fingers'),
                  subtitle: Text(
                      'Swipe to scroll. Tap with three fingers for middle-click.')),
            ])));
  }

  Widget _sessionPanel() => Material(
      color: Colors.black87,
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      child: Padding(
          padding: const EdgeInsets.all(6),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
                width: 148,
                child: Row(children: [
                  const Icon(Icons.desktop_windows_outlined,
                      size: 18, color: Colors.white70),
                  const SizedBox(width: 8),
                  Text('${((_zoom ?? 1) * 100).round()}%',
                      style: const TextStyle(color: Colors.white)),
                ])),
            const Divider(height: 8, color: Colors.white24),
            SizedBox(
                width: 148,
                child: Wrap(spacing: 2, runSpacing: 2, children: [
                  _button(
                      'Fit screen',
                      Icons.fit_screen,
                      () => setState(
                          () => _setZoom(1, _viewport.center(Offset.zero)))),
                  _button(
                      'Zoom out',
                      Icons.zoom_out,
                      () => setState(() => _setZoom(
                          (_zoom ?? 1) / 1.25, _viewport.center(Offset.zero)))),
                  _button(
                      'Zoom in',
                      Icons.zoom_in,
                      () => setState(() => _setZoom(
                          (_zoom ?? 1) * 1.25, _viewport.center(Offset.zero)))),
                  _button('Keyboard', Icons.keyboard_outlined,
                      widget.canControl ? widget.onKeyboard : null),
                  _button(
                      'Right click',
                      Icons.ads_click,
                      widget.canControl
                          ? () => widget.onPointer(3, _cursor)
                          : null),
                  _button(
                      'Middle click',
                      Icons.mouse_outlined,
                      widget.canControl
                          ? () => widget.onPointer(4, _cursor)
                          : null),
                  _button('Ctrl+Alt+Del', Icons.security,
                      widget.canControl ? widget.onCtrlAltDel : null),
                  _button('Gestures', Icons.help_outline, _showGestureHelp),
                ])),
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
        final menuTop = (_menuY ?? (size.height - 56) / 2)
            .clamp(8.0, math.max(8.0, size.height - 64))
            .toDouble();
        final panelTop = (menuTop - 190)
            .clamp(8.0, math.max(8.0, size.height - 420))
            .toDouble();
        return Stack(children: [
          Positioned.fill(
              child: Listener(
                  onPointerDown: _rawPointerDown,
                  onPointerMove: _rawPointerMove,
                  onPointerUp: _rawPointerUp,
                  onPointerCancel: _rawPointerUp,
                  child: Semantics(
                      label:
                          'Windows trackpad. Swipe with one finger to move the pointer, tap to click, hold to right-click, use two fingers to zoom, and three fingers to scroll.',
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
          if (_menuOpen)
            Positioned(
                right: 72,
                top: panelTop,
                child: ConstrainedBox(
                    constraints: BoxConstraints(
                        maxHeight: math.max(120, size.height - 16)),
                    child: SingleChildScrollView(child: _sessionPanel()))),
          Positioned(
              right: 8,
              top: menuTop,
              child: GestureDetector(
                  onVerticalDragUpdate: (details) => setState(() {
                        _menuY = (menuTop + details.delta.dy)
                            .clamp(8.0, math.max(8.0, size.height - 64))
                            .toDouble();
                      }),
                  child: Material(
                      color: Colors.black87,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: const BorderSide(color: Colors.white24)),
                      elevation: 8,
                      child: SizedBox(
                          width: 48,
                          height: 56,
                          child: IconButton(
                              tooltip: 'Session menu',
                              color: Colors.white,
                              icon: Icon(_menuOpen
                                  ? Icons.close
                                  : Icons.mouse_outlined),
                              onPressed: () =>
                                  setState(() => _menuOpen = !_menuOpen)))))),
        ]);
      });
}
