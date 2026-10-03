import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/emulator_model.dart';
import '../../models/model.dart';

class EmulatorPage extends StatefulWidget {
  const EmulatorPage(
      {super.key,
      required this.ffi,
      this.dashboardMode = false,
      this.onSwitch,
      this.onReturn});
  final FFI ffi;
  final bool dashboardMode;
  final Future<void> Function()? onSwitch;
  final Future<void> Function()? onReturn;

  @override
  State<EmulatorPage> createState() => _EmulatorPageState();
}

class _EmulatorPageState extends State<EmulatorPage> {
  final _keyboardFocus = FocusNode();
  final _pointers = <int, (int, int)>{};
  bool _returning = false;
  bool _guestPresentation = false;
  bool? _guestLandscape;
  EmulatorModel get model => widget.ffi.emulatorModel;
  bool get canControl =>
      widget.ffi.ffiModel.keyboard && !widget.ffi.ffiModel.viewOnly;

  @override
  void initState() {
    super.initState();
    model.addListener(_changed);
    if (!widget.dashboardMode) unawaited(model.refresh());
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _syncGuestPresentation();
    if (_returning && !model.selected && !model.connecting) {
      _returning = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).pop();
      });
    } else if (_returning && model.error.isNotEmpty) {
      _returning = false;
    }
  }

  Future<bool> _back() async {
    if (widget.onReturn != null) {
      _cancelTouches();
      await widget.onReturn!();
      return false;
    }
    if (!model.selected && !model.connecting) return true;
    setState(() => _returning = true);
    await model.desktop();
    return false;
  }

  @override
  void dispose() {
    model.removeListener(_changed);
    for (final pointer in _pointers.entries) {
      unawaited(
          model.touch(3, pointer.key, pointer.value.$1, pointer.value.$2));
    }
    if (_guestPresentation) unawaited(_restoreRemotePresentation());
    _keyboardFocus.dispose();
    super.dispose();
  }

  void _cancelTouches() {
    for (final pointer in _pointers.entries) {
      unawaited(
          model.touch(3, pointer.key, pointer.value.$1, pointer.value.$2));
    }
    _pointers.clear();
  }

  void _syncGuestPresentation() {
    if (widget.dashboardMode) return;
    if (!model.streaming || model.width <= 0 || model.height <= 0) {
      if (_guestPresentation) {
        _guestPresentation = false;
        _guestLandscape = null;
        unawaited(_restoreRemotePresentation());
      }
      return;
    }
    final landscape = model.width > model.height;
    if (_guestPresentation && _guestLandscape == landscape) return;
    _guestPresentation = true;
    _guestLandscape = landscape;
    unawaited(_applyGuestPresentation(landscape));
  }

  Future<void> _applyGuestPresentation(bool landscape) async {
    await SystemChrome.setPreferredOrientations(landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight
          ]
        : const [DeviceOrientation.portraitUp, DeviceOrientation.portraitDown]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  Future<void> _restoreRemotePresentation() async {
    await SystemChrome.setPreferredOrientations(const []);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: []);
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: !widget.dashboardMode && !model.selected && !model.connecting,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop && !_returning) unawaited(_back());
        },
        child: AnimatedBuilder(
          animation: model,
          builder: (context, _) {
            final immersive = model.selected && model.streaming;
            return Scaffold(
              backgroundColor: immersive ? Colors.black : null,
              appBar: immersive
                  ? null
                  : AppBar(
                      title: Text(model.selected ? _selectedName : 'Emulators'),
                      leading: IconButton(
                        tooltip: model.selected
                            ? 'Return to Windows desktop'
                            : 'Back',
                        icon: const Icon(Icons.arrow_back),
                        onPressed: _returning
                            ? null
                            : () async {
                                if (await _back() && mounted) {
                                  Navigator.of(context).pop();
                                }
                              },
                      ),
                      actions: [
                        if (!model.selected)
                          IconButton(
                            tooltip: 'Refresh emulator instances',
                            onPressed: model.loading || model.connecting
                                ? null
                                : () => unawaited(model.refresh()),
                            icon: const Icon(Icons.refresh),
                          ),
                      ],
                    ),
              body:
                  model.selected || widget.dashboardMode ? _guest() : _picker(),
              bottomNavigationBar: model.selected && !model.streaming
                  ? SafeArea(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _navigation('Back', Icons.arrow_back, 'back'),
                          _navigation('Home', Icons.home_outlined, 'home'),
                          _navigation('Recents', Icons.crop_square, 'recents'),
                        ],
                      ),
                    )
                  : null,
            );
          },
        ),
      );

  String get _selectedName =>
      model.instances
          .where((instance) => instance.id == model.targetId)
          .map((instance) => instance.name)
          .firstOrNull ??
      'Android emulator';

  Widget _picker() => ListView(
        padding: const EdgeInsets.symmetric(vertical: 16),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
                'Choose an instance to view and control its Android screen.'),
          ),
          if (model.error.isNotEmpty) _error(),
          if (model.loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator())),
          if (!model.loading && model.instances.isEmpty)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'No emulator instances were found. Open BlueStacks or LDPlayer on the PC, then refresh.')),
          for (final instance in model.instances)
            ListTile(
              leading: const Icon(Icons.tablet_android),
              title: Text(instance.name),
              subtitle: Text([
                instance.provider == 'bluestacks' ? 'BlueStacks' : 'LDPlayer',
                instance.state,
                if (instance.androidVersion.isNotEmpty)
                  'Android ${instance.androidVersion}',
                if (instance.defaultPackage.isNotEmpty)
                  'Assigned game will open',
                if (instance.error.isNotEmpty) instance.error,
              ].join(' · ')),
              trailing: FilledButton(
                onPressed: canControl && !model.connecting
                    ? () => unawaited(model.connect(instance.id,
                        launchDefaultApp: instance.defaultPackage.isNotEmpty))
                    : null,
                child: const Text('Connect'),
              ),
            ),
          if (!canControl)
            const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                    'The PC must grant control permission before you can connect to an emulator.')),
          if (model.connecting)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator())),
        ],
      );

  Widget _error() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Text(model.error,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );

  Widget _guest() {
    if (!model.streaming) {
      return Center(
          child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (model.error.isEmpty) const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(
                    _returning
                        ? 'Returning to the desktop…'
                        : model.error.isEmpty
                            ? 'Starting Android…'
                            : model.error,
                    textAlign: TextAlign.center),
                if (model.error.isNotEmpty)
                  TextButton(
                      onPressed: () => unawaited(_back()),
                      child: const Text('Return to desktop')),
              ])));
    }
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _key,
      child: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          child: Row(children: [
            SizedBox(
                width: 56,
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _overlayButton(
                          tooltip: widget.onSwitch == null
                              ? 'Return to Windows desktop'
                              : 'Switch view',
                          icon: widget.onSwitch == null
                              ? Icons.desktop_windows_outlined
                              : Icons.view_agenda_outlined,
                          onPressed: () async {
                            _cancelTouches();
                            if (widget.onSwitch != null) {
                              await widget.onSwitch!();
                            } else {
                              await _back();
                            }
                          }),
                      if (widget.onReturn != null)
                        _overlayButton(
                            tooltip: 'Dashboard',
                            icon: Icons.grid_view_outlined,
                            onPressed: () => unawaited(_back())),
                    ])),
            Expanded(
                child: LayoutBuilder(
              builder: (context, constraints) => Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => _touch(0, event, constraints),
                onPointerMove: (event) {
                  if (_pointers.containsKey(event.pointer)) {
                    _touch(2, event, constraints);
                  }
                },
                onPointerUp: (event) => _touch(1, event, constraints),
                onPointerCancel: (event) => _touch(3, event, constraints),
                child: AnimatedBuilder(
                  animation: widget.ffi.imageModel,
                  builder: (_, __) => RawImage(
                    image: widget.dashboardMode
                        ? widget.ffi.imageModel
                            .dashboardImage(model.videoChannel)
                        : widget.ffi.imageModel.image,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.low,
                  ),
                ),
              ),
            )),
            SizedBox(
                width: 56,
                child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _overlayNavigation(Icons.arrow_back, 'Back', 'back'),
                      const SizedBox(height: 8),
                      _overlayNavigation(Icons.home_outlined, 'Home', 'home'),
                      const SizedBox(height: 8),
                      _overlayNavigation(
                          Icons.crop_square, 'Recents', 'recents'),
                    ])),
          ]),
        ),
      ),
    );
  }

  void _touch(int action, PointerEvent event, BoxConstraints box) {
    if (!canControl ||
        !model.streaming ||
        box.maxWidth <= 0 ||
        box.maxHeight <= 0) return;
    final active = _pointers.containsKey(event.pointer);
    final point = mapEmulatorTouch(
      localX: event.localPosition.dx,
      localY: event.localPosition.dy,
      viewportWidth: box.maxWidth,
      viewportHeight: box.maxHeight,
      guestWidth: model.width,
      guestHeight: model.height,
      clampToFrame: active,
    );
    if (point == null) return;
    final x = point.x;
    final y = point.y;
    if (action == 1 || action == 3) {
      _pointers.remove(event.pointer);
    } else {
      _pointers[event.pointer] = (x, y);
    }
    unawaited(model.touch(action, event.pointer, x, y));
  }

  Widget _navigation(String label, IconData icon, String action) =>
      TextButton.icon(
        onPressed: canControl && model.streaming && !_returning
            ? () => unawaited(model.navigation(action))
            : null,
        icon: Icon(icon),
        label: Text(label),
      );

  Widget _overlayButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
  }) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          shape: BoxShape.circle,
        ),
        child: IconButton(
          tooltip: tooltip,
          color: Colors.white,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );

  Widget _overlayNavigation(IconData icon, String tooltip, String action) =>
      IconButton(
        tooltip: tooltip,
        color: Colors.white,
        onPressed: canControl && model.streaming && !_returning
            ? () => unawaited(model.navigation(action))
            : null,
        icon: Icon(icon),
      );

  void _key(KeyEvent event) {
    if (!canControl) return;
    final logical = event.logicalKey;
    final known = {
      LogicalKeyboardKey.arrowUp: 19,
      LogicalKeyboardKey.arrowDown: 20,
      LogicalKeyboardKey.arrowLeft: 21,
      LogicalKeyboardKey.arrowRight: 22,
      LogicalKeyboardKey.enter: 66,
      LogicalKeyboardKey.backspace: 67,
      LogicalKeyboardKey.space: 62,
      LogicalKeyboardKey.escape: 4,
    };
    var code = known[logical];
    final label = logical.keyLabel.toUpperCase();
    if (code == null && label.length == 1) {
      final character = label.codeUnitAt(0);
      if (character >= 65 && character <= 90) code = 29 + character - 65;
      if (character >= 48 && character <= 57) code = 7 + character - 48;
    }
    if (code != null) unawaited(model.key(code, event is! KeyUpEvent));
  }
}
