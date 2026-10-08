import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/emulator_model.dart';
import '../../models/model.dart';
import '../widgets/mirpg_remote_theme.dart';

bool shouldCancelGuestComposition({
  required int previousSessionId,
  required String previousTargetId,
  required int currentSessionId,
  required String currentTargetId,
}) =>
    previousSessionId != 0 &&
    (currentSessionId != previousSessionId ||
        currentTargetId != previousTargetId);

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

class _EmulatorPageState extends State<EmulatorPage>
    with WidgetsBindingObserver {
  final _keyboardFocus = FocusNode();
  final _textFocus = FocusNode();
  final _textController = TextEditingController();
  final _pointers = <int, (int, int, int, int)>{};
  final _heldKeys = <int>{};
  bool _textComposerVisible = false;
  bool _sendingText = false;
  int _textSendGeneration = 0;
  bool _returning = false;
  bool _guestPresentation = false;
  bool? _guestLandscape;
  bool _background = false;
  bool _viewFocused = true;
  bool _hostControlWasEnabled = false;
  int _observedSessionId = 0;
  String _observedTargetId = '';
  (int, int)? _observedGeometry;
  EmulatorModel get model => widget.ffi.emulatorModel;
  bool get _hostCanControl =>
      widget.ffi.ffiModel.keyboard && !widget.ffi.ffiModel.viewOnly;
  bool get canControl => _hostCanControl && !_background && _viewFocused;
  bool get canGuestControl => canControl && model.guestFrameFresh;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_changed);
    widget.ffi.ffiModel.addListener(_permissionChanged);
    _hostControlWasEnabled = _hostCanControl;
    _observedSessionId = model.guestSessionId;
    _observedTargetId = model.targetId;
    if (model.streaming && model.width > 0 && model.height > 0) {
      _observedGeometry = (model.width, model.height);
    }
    if (!widget.dashboardMode) unawaited(model.refresh());
  }

  void _changed() {
    if (!mounted) return;
    if (shouldCancelGuestComposition(
      previousSessionId: _observedSessionId,
      previousTargetId: _observedTargetId,
      currentSessionId: model.guestSessionId,
      currentTargetId: model.targetId,
    )) {
      _discardTextComposer(restoreKeyboardFocus: false);
    }
    final geometry = model.streaming && model.width > 0 && model.height > 0
        ? (model.width, model.height)
        : null;
    if (_observedGeometry != null &&
        geometry != null &&
        geometry != _observedGeometry &&
        (_pointers.isNotEmpty || _heldKeys.isNotEmpty)) {
      _cancelGuestInput();
    }
    _observedSessionId = model.guestSessionId;
    _observedTargetId = model.targetId;
    _observedGeometry = geometry;
    if (!model.streaming && (_pointers.isNotEmpty || _heldKeys.isNotEmpty)) {
      _cancelGuestInput();
    }
    if (!model.guestFrameFresh) {
      if (_pointers.isNotEmpty || _heldKeys.isNotEmpty) _cancelGuestInput();
      if (_textComposerVisible) {
        _discardTextComposer(restoreKeyboardFocus: false);
      }
    }
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
    _cancelGuestInput();
    _discardTextComposer(restoreKeyboardFocus: false);
    if (widget.onReturn != null) {
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
    WidgetsBinding.instance.removeObserver(this);
    _cancelGuestInput();
    model.removeListener(_changed);
    widget.ffi.ffiModel.removeListener(_permissionChanged);
    if (_guestPresentation) unawaited(_restoreRemotePresentation());
    _keyboardFocus.dispose();
    _textFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  void _openTextComposer() {
    if (!canGuestControl ||
        !model.streaming ||
        !model.guestTextSupported ||
        _returning) {
      return;
    }
    setState(() => _textComposerVisible = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textComposerVisible) _textFocus.requestFocus();
    });
  }

  void _discardTextComposer({bool restoreKeyboardFocus = true}) {
    _textSendGeneration++;
    _sendingText = false;
    _textController.value = TextEditingValue.empty;
    _textFocus.unfocus();
    _textComposerVisible = false;
    if (mounted && restoreKeyboardFocus) _keyboardFocus.requestFocus();
  }

  Future<void> _sendTextDraft() async {
    if (!canGuestControl || !model.streaming || _sendingText) return;
    final snapshot = _textController.text;
    if (snapshot.isEmpty) return;
    final sessionId = model.guestSessionId;
    final targetId = model.targetId;
    final generation = ++_textSendGeneration;
    setState(() {
      _sendingText = true;
      _textController.value = TextEditingValue.empty;
    });
    final sent = await model.sendText(snapshot);
    if (!mounted) return;
    if (generation != _textSendGeneration) return;
    final sameTarget =
        model.guestSessionId == sessionId && model.targetId == targetId;
    if (!sent && sameTarget) {
      final newer = _textController.text;
      _textController.value = TextEditingValue(
        text: '$snapshot$newer',
        selection:
            TextSelection.collapsed(offset: snapshot.length + newer.length),
      );
    }
    setState(() => _sendingText = false);
    if (sameTarget && _textComposerVisible) _textFocus.requestFocus();
  }

  void _cancelGuestInput() {
    final pointers = _pointers.entries.toList(growable: false);
    final keys = _heldKeys.toList(growable: false);
    _pointers.clear();
    _heldKeys.clear();
    for (final pointer in pointers) {
      unawaited(model.touch(
        3,
        pointer.key,
        pointer.value.$1,
        pointer.value.$2,
        frameWidth: pointer.value.$3,
        frameHeight: pointer.value.$4,
      ));
    }
    for (final key in keys) {
      unawaited(model.key(key, false));
    }
  }

  void _permissionChanged() {
    final enabled = _hostCanControl;
    if (!enabled && _hostControlWasEnabled) {
      _cancelGuestInput();
      _discardTextComposer(restoreKeyboardFocus: false);
    }
    _hostControlWasEnabled = enabled;
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final background = state != AppLifecycleState.resumed;
    if (background && !_background) {
      _cancelGuestInput();
      _discardTextComposer(restoreKeyboardFocus: false);
    }
    _background = background;
    if (mounted) setState(() {});
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (!mounted || View.of(context).viewId != event.viewId) return;
    final focused = event.state == ui.ViewFocusState.focused;
    if (!focused && _viewFocused) {
      _cancelGuestInput();
      _discardTextComposer(restoreKeyboardFocus: false);
    }
    _viewFocused = focused;
    setState(() {});
  }

  @override
  void didChangeMetrics() {
    if (_pointers.isNotEmpty || _heldKeys.isNotEmpty) _cancelGuestInput();
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
  Widget build(BuildContext context) => Theme(
        data: MirpgRemoteTheme.build(Theme.of(context)),
        child: PopScope(
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
                        title:
                            Text(model.selected ? _selectedName : 'Emulators'),
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
                body: model.selected || widget.dashboardMode
                    ? _guest()
                    : _picker(),
                bottomNavigationBar: model.selected && !model.streaming
                    ? SafeArea(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _navigation('Back', Icons.arrow_back, 'back'),
                            _navigation('Home', Icons.home_outlined, 'home'),
                            _navigation(
                                'Recents', Icons.crop_square, 'recents'),
                          ],
                        ),
                      )
                    : null,
              );
            },
          ),
        ),
      );

  String get _selectedName =>
      model.instances
          .where((instance) => instance.id == model.targetId)
          .map((instance) => instance.name)
          .firstOrNull ??
      'Android emulator';

  Widget _picker() => ListView(
        padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
        children: [
          const MirpgSectionHeader(
            title: 'Android instances',
            subtitle:
                'Choose a BlueStacks instance to view and control directly.',
          ),
          const SizedBox(height: 12),
          if (model.error.isNotEmpty) _error(),
          if (model.loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator())),
          if (!model.loading && model.instances.isEmpty)
            const MirpgSurface(
              child: Text(
                  'No emulator instances were found. Open BlueStacks on the PC, then refresh.'),
            ),
          for (final instance in model.instances)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MirpgSurface(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: MirpgRemoteTheme.raised,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.android_outlined,
                            color: MirpgRemoteTheme.accent),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(instance.name,
                              style: Theme.of(context).textTheme.titleMedium),
                          const SizedBox(height: 3),
                          Text(
                            [
                              instance.provider == 'bluestacks'
                                  ? 'BlueStacks'
                                  : instance.provider,
                              if (instance.androidVersion.isNotEmpty)
                                'Android ${instance.androidVersion}',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          if (instance.error.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(instance.error,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: MirpgRemoteTheme.error)),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: canControl && !model.connecting
                                    ? () => unawaited(model.connect(instance.id,
                                        launchDefaultApp: false))
                                    : null,
                                icon: Icon(instance.state == 'stopped'
                                    ? Icons.power_settings_new_rounded
                                    : Icons.play_arrow_rounded),
                                label: Text(instance.state == 'stopped'
                                    ? 'Boot'
                                    : 'Resume'),
                              ),
                              if (instance.defaultPackage.isNotEmpty)
                                OutlinedButton.icon(
                                  onPressed: canControl && !model.connecting
                                      ? () => unawaited(model.connect(
                                          instance.id,
                                          launchDefaultApp: true))
                                      : null,
                                  icon:
                                      const Icon(Icons.sports_esports_outlined),
                                  label: const Text('Launch game'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    MirpgStatusChip(
                      label:
                          instance.state.isEmpty ? 'Unknown' : instance.state,
                      tone: instance.state == 'stopped'
                          ? MirpgStatusTone.neutral
                          : instance.error.isNotEmpty
                              ? MirpgStatusTone.error
                              : MirpgStatusTone.good,
                    ),
                  ],
                ),
              ),
            ),
          if (!canControl)
            const MirpgSurface(
              child: Text(
                  'The PC must grant control permission before you can connect to an emulator.'),
            ),
          if (model.connecting)
            const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator())),
        ],
      );

  Widget _error() => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: MirpgSurface(
          color: MirpgRemoteTheme.error.withOpacity(0.08),
          borderColor: MirpgRemoteTheme.error.withOpacity(0.45),
          child: Text(model.error,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: MirpgRemoteTheme.error)),
        ),
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
                            ? _startupLabel
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
          child: Stack(
            children: [
              Row(children: [
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
                                _cancelGuestInput();
                                _discardTextComposer(
                                    restoreKeyboardFocus: false);
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
                          _overlayButton(
                              tooltip: model.guestTextSupported
                                  ? 'Type text'
                                  : 'Text input unavailable on this host',
                              icon: Icons.keyboard_outlined,
                              onPressed: canGuestControl &&
                                      model.streaming &&
                                      model.guestTextSupported &&
                                      !_returning
                                  ? _openTextComposer
                                  : null),
                          const SizedBox(height: 8),
                          _overlayNavigation(Icons.arrow_back, 'Back', 'back'),
                          const SizedBox(height: 8),
                          _overlayNavigation(
                              Icons.home_outlined, 'Home', 'home'),
                          const SizedBox(height: 8),
                          _overlayNavigation(
                              Icons.crop_square, 'Recents', 'recents'),
                        ])),
              ]),
              Positioned(
                top: 8,
                left: 64,
                right: 64,
                child: IgnorePointer(
                  child: Center(
                    child: MirpgStatusChip(
                      label: model.guestFrameFresh
                          ? '$_selectedName · Direct touch'
                          : '$_selectedName · Waiting for live frame',
                      icon: model.guestFrameFresh
                          ? Icons.touch_app_outlined
                          : Icons.hourglass_top_rounded,
                      tone: model.guestFrameFresh
                          ? MirpgStatusTone.good
                          : MirpgStatusTone.warning,
                    ),
                  ),
                ),
              ),
              if (_textComposerVisible)
                Positioned(
                  left: 64,
                  right: 64,
                  bottom: 12,
                  child: MirpgSurface(
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _textController,
                            focusNode: _textFocus,
                            autofocus: true,
                            maxLines: 1,
                            textInputAction: TextInputAction.done,
                            decoration: const InputDecoration(
                              hintText: 'Type text to Android',
                              border: InputBorder.none,
                            ),
                            onSubmitted: (_) {
                              if (mounted && _textComposerVisible) {
                                _textFocus.requestFocus();
                              }
                            },
                          ),
                        ),
                        IconButton(
                          tooltip: 'Send text',
                          onPressed: canGuestControl && !_sendingText
                              ? () => unawaited(_sendTextDraft())
                              : null,
                          icon: const Icon(Icons.send_rounded),
                        ),
                        IconButton(
                          tooltip: 'Close keyboard',
                          onPressed: () => setState(_discardTextComposer),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _touch(int action, PointerEvent event, BoxConstraints box) {
    if (!canGuestControl ||
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
      _pointers[event.pointer] = (x, y, model.width, model.height);
    }
    unawaited(model.touch(action, event.pointer, x, y));
  }

  Widget _navigation(String label, IconData icon, String action) =>
      TextButton.icon(
        onPressed: canGuestControl && model.streaming && !_returning
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
          color: MirpgRemoteTheme.surface.withOpacity(0.92),
          shape: BoxShape.circle,
          border: Border.all(color: MirpgRemoteTheme.outline),
        ),
        child: IconButton(
          tooltip: tooltip,
          color: MirpgRemoteTheme.textPrimary,
          onPressed: onPressed,
          icon: Icon(icon),
        ),
      );

  Widget _overlayNavigation(IconData icon, String tooltip, String action) =>
      IconButton(
        tooltip: tooltip,
        color: MirpgRemoteTheme.textPrimary,
        onPressed: canGuestControl && model.streaming && !_returning
            ? () => unawaited(model.navigation(action))
            : null,
        icon: Icon(icon),
      );

  void _key(KeyEvent event) {
    if (!canGuestControl || _textComposerVisible) return;
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
    if (code != null) {
      final down = event is! KeyUpEvent;
      if (down) {
        _heldKeys.add(code);
      } else {
        _heldKeys.remove(code);
      }
      unawaited(model.key(code, down));
    }
  }

  String get _startupLabel {
    switch (model.startupPhase) {
      case 'boot_requested':
        return 'Boot requested…';
      case 'starting_android':
        return 'Starting Android…';
      case 'waiting_screen':
        return 'Android ready · starting remote screen…';
      case 'stream_ready':
        return 'Stream ready';
      default:
        return 'Connecting to Android…';
    }
  }
}
