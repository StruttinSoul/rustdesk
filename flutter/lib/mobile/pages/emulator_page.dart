import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../models/emulator_model.dart';
import '../../models/model.dart';
import '../../common.dart' show translate;
import '../widgets/emulator_tile.dart' show EmulatorStateBadge;
import '../widgets/mirpg_remote_theme.dart';
import '../widgets/play_rail.dart';
import '../widgets/startup_checklist.dart';

bool shouldCancelGuestComposition({
  required int previousSessionId,
  required String previousTargetId,
  required int currentSessionId,
  required String currentTargetId,
}) =>
    previousSessionId != 0 &&
    (currentSessionId != previousSessionId ||
        currentTargetId != previousTargetId);

/// Whether a failed game of [target] may reconnect now: the PC lists it
/// ready, and after a Reboot from the phone Android is back (a reconnect
/// while it restarts would wait out the PC's boot timeout).
bool guestReadyForReconnect(EmulatorModel model, String target) =>
    !model.isRebooting(target) &&
    model.instances
        .any((instance) => instance.id == target && instance.readyForReconnect);

/// Retry only an unexpectedly failed, previously usable guest. Never boot an
/// instance in the background or loop indefinitely against a broken runtime,
/// and never take back a game that was [superseded] by another device.
Duration? guestAutoReconnectDelay({
  required bool sessionFailed,
  required bool guestWasLive,
  required bool emulatorRunning,
  required bool foreground,
  required bool canControl,
  required int attempts,
  bool superseded = false,
}) {
  if (!sessionFailed ||
      superseded ||
      !guestWasLive ||
      !emulatorRunning ||
      !foreground ||
      !canControl ||
      attempts >= 2) {
    return null;
  }
  return Duration(seconds: attempts == 0 ? 1 : 3);
}

/// Leaving a game takes two back presses: the first only warns, the second
/// within [window] leaves. A press after the window starts a new pair.
class DoubleBackGuard {
  DoubleBackGuard({this.window = const Duration(seconds: 2)});

  final Duration window;
  DateTime? _first;

  /// True when this press should leave.
  bool press(DateTime now) {
    final first = _first;
    if (first != null && now.difference(first) <= window) {
      _first = null;
      return true;
    }
    _first = now;
    return false;
  }

  void reset() => _first = null;
}

/// Where the "Back again to leave the game" hint floats: above the bottom
/// navigation bar of a portrait game, or clear of the strip on the right of a
/// landscape one.
EdgeInsets backHintMargin(Axis barAxis) => barAxis == Axis.vertical
    ? const EdgeInsets.fromLTRB(16, 0, kPlayNavBarThickness + 8, 16)
    : const EdgeInsets.fromLTRB(16, 0, 16, kPlayNavBarThickness + 8);

/// Keeps the whole guest visible. The controls are the navigation bar: 48 dp
/// at the bottom of a portrait game ([barAxis] horizontal) or 48 dp on the
/// right edge of a landscape one (vertical). The game takes everything the
/// bar leaves, contained and centred, so the bar never covers or crops it.
/// The text composer, while open, replaces the bar under the game.
///
/// The fallback page ([legacyLayout]) keeps its old behaviour: a controls row
/// below the video, shown by a movable round button.
class GuestControlStage extends StatefulWidget {
  const GuestControlStage({
    super.key,
    required this.video,
    required this.controls,
    this.barAxis = Axis.horizontal,
    this.controlsVisible = false,
    this.onToggleControls,
    this.composer,
    this.legacyLayout = false,
  });

  /// The fallback page (PCs without the dashboard): its controls row sits
  /// below the video and shrinks it, and only the round button toggles it.
  /// [barAxis] and [composer] are not used.
  final bool legacyLayout;

  final Widget video;

  /// The navigation bar (dashboard), or the controls row (fallback page).
  final Widget controls;

  /// Horizontal: the bar under a portrait game. Vertical: the strip on the
  /// right of a landscape game.
  final Axis barAxis;

  /// Fallback page only: whether the controls row shows.
  final bool controlsVisible;
  final VoidCallback? onToggleControls;

  /// The text composer; while set it replaces the bar under the video.
  final Widget? composer;

  @override
  State<GuestControlStage> createState() => _GuestControlStageState();
}

class _GuestControlStageState extends State<GuestControlStage> {
  // Relative placement survives orientation changes and the soft keyboard.
  Offset _buttonPosition = const Offset(1, 0.75);

  // One Flex and one Stack in every layout, so the video keeps its element
  // (and its pointer listener) when the composer opens or the game rotates.
  @override
  Widget build(BuildContext context) {
    if (widget.legacyLayout) {
      return Column(children: [
        Expanded(
          child: Stack(children: [
            Positioned.fill(child: widget.video),
            Positioned.fill(child: _toggleLayer()),
          ]),
        ),
        if (widget.controlsVisible) widget.controls,
      ]);
    }
    final composer = widget.composer;
    final side = composer == null && widget.barAxis == Axis.vertical;
    return Flex(
      direction: side ? Axis.horizontal : Axis.vertical,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Stack(children: [Positioned.fill(child: widget.video)]),
        ),
        if (composer != null)
          composer
        else if (side)
          SizedBox(width: kPlayNavBarThickness, child: widget.controls)
        else
          SizedBox(height: kPlayNavBarThickness, child: widget.controls),
      ],
    );
  }

  Widget _toggleLayer() => LayoutBuilder(builder: (context, constraints) {
            final horizontalSpace = (constraints.maxWidth - 64)
                .clamp(0.0, double.infinity)
                .toDouble();
            final verticalSpace = (constraints.maxHeight - 64)
                .clamp(0.0, double.infinity)
                .toDouble();
            return Stack(children: [
              if (constraints.maxHeight >= 64)
                Positioned(
                  left: 8 + horizontalSpace * _buttonPosition.dx,
                  top: 8 + verticalSpace * _buttonPosition.dy,
                  child: GestureDetector(
                    onPanUpdate: (details) => setState(() {
                      _buttonPosition = Offset(
                        horizontalSpace == 0
                            ? 0
                            : (_buttonPosition.dx +
                                    details.delta.dx / horizontalSpace)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                        verticalSpace == 0
                            ? 0
                            : (_buttonPosition.dy +
                                    details.delta.dy / verticalSpace)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                      );
                    }),
                    child: Semantics(
                      hint: 'Drag to move',
                      child: SizedBox.square(
                        dimension: 48,
                        child: Material(
                          color: MirpgRemoteTheme.surface.withOpacity(0.92),
                          shape: const CircleBorder(
                            side: BorderSide(color: MirpgRemoteTheme.outline),
                          ),
                          child: IconButton(
                            tooltip: widget.controlsVisible
                                ? 'Hide controls'
                                : 'Show controls',
                            color: MirpgRemoteTheme.textPrimary,
                            onPressed: widget.onToggleControls,
                            icon: Icon(widget.controlsVisible
                                ? Icons.close
                                : Icons.tune_rounded),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ]);
          });
}

class GuestTextComposer extends StatelessWidget {
  const GuestTextComposer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onSend,
    required this.onClose,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSubmitted;
  final VoidCallback? onSend;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: MirpgSurface(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Type text to Android',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                    border: InputBorder.none,
                  ),
                  onSubmitted: onSubmitted,
                ),
              ),
              IconButton(
                tooltip: 'Send text',
                onPressed: onSend,
                icon: const Icon(Icons.send_rounded),
              ),
              IconButton(
                tooltip: 'Close keyboard',
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      );
}

class EmulatorPage extends StatefulWidget {
  const EmulatorPage(
      {super.key,
      required this.ffi,
      this.dashboardMode = false,
      this.onSwitch,
      this.onReturn,
      this.nameFor,
      this.switchFrame,
      this.onShowOnPc,
      this.accounts = const [],
      this.onSelectTarget,
      this.onCurrentActions,
      this.alreadyRunning});
  final FFI ffi;
  final bool dashboardMode;

  /// Dashboard: opens the emulator grid sheet (the menu's "+"). Without a
  /// dashboard the legacy controls return to the Windows desktop instead.
  final Future<void> Function()? onSwitch;
  final Future<void> Function()? onReturn;

  /// The name shown for an emulator id (the phone-side label when set).
  final String Function(String targetId)? nameFor;

  /// The opened emulator's last preview frame, shown dimmed while switching
  /// to an emulator that is already running. Owned by the caller.
  final ui.Image? switchFrame;

  /// Shows the emulator's window on the PC; null when not offered.
  final Future<void> Function()? onShowOnPc;

  /// The menu's emulator chips, in grid order (dashboard only).
  final List<PlayAccount> accounts;

  /// Switches the game to another emulator (a chip tap).
  final Future<void> Function(String targetId)? onSelectTarget;

  /// Opens the current emulator's action sheet (a row in the bar's menu).
  final VoidCallback? onCurrentActions;

  /// Whether an emulator is running and ready as far as the dashboard knows
  /// (its list is not refreshed during a game), so opening it skips the
  /// checklist. Without it, the PC's list decides.
  final bool Function(String targetId)? alreadyRunning;

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
  bool _guestControlsVisible = false;
  bool _sendingText = false;
  int _textSendGeneration = 0;
  bool _returning = false;
  bool _guestPresentation = false;
  bool? _guestLandscape;
  bool _background = false;
  bool _viewFocused = true;
  bool _hostControlWasEnabled = false;
  Timer? _guestReconnectTimer;
  Timer? _guestStableTimer;
  String _guestRecoveryTarget = '';
  int _guestReconnectAttempts = 0;
  bool _guestWasLive = false;
  int _observedSessionId = 0;
  String _observedTargetId = '';
  (int, int)? _observedGeometry;

  /// Where the play rail sits; kept between layouts for the hysteresis.
  final _banner = NameBannerController();
  final _doubleBack = DoubleBackGuard();

  /// The "Back again to leave the game" snackbar, while it shows.
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _backHint;

  /// The (emulator, guest session) the name banner last announced.
  (String, int)? _bannerFor;

  /// The emulator the startup screen describes, and whether it was already
  /// running (ready to reconnect) when it was opened.
  String _startupTarget = '';
  bool _openedRunning = false;
  String _startupPhase = '';
  int _lastStartupStep = 0;
  final Stopwatch _startupClock = Stopwatch();
  Timer? _startupTicker;
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
    _guestRecoveryTarget = model.targetId;
    _guestWasLive = model.streaming;
    if (model.streaming && model.width > 0 && model.height > 0) {
      _observedGeometry = (model.width, model.height);
    }
    if (!widget.dashboardMode) unawaited(model.refresh());
    _updateGuestRecovery();
    _trackStartup();
    _announceLive();
  }

  /// Names the emulator for two seconds the first time each open or switch
  /// (each guest session) goes live, so the account in play is never a guess.
  void _announceLive() {
    if (!widget.dashboardMode || !model.streaming || model.targetId.isEmpty) {
      return;
    }
    final live = (model.targetId, model.guestSessionId);
    if (live == _bannerFor) return;
    _bannerFor = live;
    _banner.show('$_shownName · ${translate('Live')}');
  }

  bool _targetRunning(String target) =>
      widget.alreadyRunning?.call(target) ??
      model.instances.any(
          (instance) => instance.id == target && instance.readyForReconnect);

  /// Follows the start phases for the checklist: which step was reached,
  /// whether the emulator was already running, and the elapsed clock.
  void _trackStartup() {
    final phase = model.startupPhase;
    if (_startupTarget != model.targetId) {
      _startupTarget = model.targetId;
      _openedRunning = _targetRunning(_startupTarget);
      _startupClock
        ..reset()
        ..start();
    } else if (phase == 'requesting' && _startupPhase != 'requesting') {
      _startupClock
        ..reset()
        ..start();
    }
    _startupPhase = phase;
    if (phase != 'failed') {
      _lastStartupStep =
          startupStepIndex(phase, alreadyRunning: _openedRunning);
    }
    _syncStartupTicker();
  }

  bool get _showsChecklist =>
      !model.streaming &&
      (model.error.isNotEmpty ||
          !_openedRunning ||
          model.startupPhase == 'boot_requested' ||
          model.startupPhase == 'starting_android');

  /// The elapsed time only needs a repaint while the checklist shows it.
  void _syncStartupTicker() {
    final visible =
        mounted && (model.selected || widget.dashboardMode) && _showsChecklist;
    if (visible && _startupTicker == null) {
      _startupTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!visible && _startupTicker != null) {
      _startupTicker!.cancel();
      _startupTicker = null;
    }
  }

  void _cancelGuestRecovery() {
    _guestReconnectTimer?.cancel();
    _guestReconnectTimer = null;
    _guestStableTimer?.cancel();
    _guestStableTimer = null;
  }

  void _updateGuestRecovery() {
    if (_guestRecoveryTarget != model.targetId) {
      _cancelGuestRecovery();
      _guestRecoveryTarget = model.targetId;
      _guestReconnectAttempts = 0;
      _guestWasLive = model.streaming;
    }
    if (model.streaming) {
      _guestWasLive = true;
      _guestReconnectTimer?.cancel();
      _guestReconnectTimer = null;
      if (!model.guestFrameFresh) {
        _guestStableTimer?.cancel();
        _guestStableTimer = null;
      } else if (_guestStableTimer == null) {
        final target = model.targetId;
        final session = model.guestSessionId;
        _guestStableTimer = Timer(const Duration(seconds: 30), () {
          _guestStableTimer = null;
          if (mounted &&
              model.streaming &&
              model.guestFrameFresh &&
              model.targetId == target &&
              model.guestSessionId == session) {
            _guestReconnectAttempts = 0;
          }
        });
      }
      return;
    }
    _guestStableTimer?.cancel();
    _guestStableTimer = null;
    final target = model.targetId;
    final running = guestReadyForReconnect(model, target);
    final delay = guestAutoReconnectDelay(
      sessionFailed: model.selected &&
          !model.connecting &&
          !_returning &&
          model.startupPhase == 'failed' &&
          model.error.isNotEmpty,
      guestWasLive: _guestWasLive,
      emulatorRunning: running,
      foreground: !_background && _viewFocused,
      canControl: _hostCanControl,
      attempts: _guestReconnectAttempts,
      superseded: model.guestSuperseded,
    );
    if (delay == null) {
      _guestReconnectTimer?.cancel();
      _guestReconnectTimer = null;
      return;
    }
    if (_guestReconnectTimer != null) return;
    final failedSession = model.guestSessionId;
    final failedError = model.error;
    _guestReconnectTimer = Timer(delay, () {
      _guestReconnectTimer = null;
      if (!mounted ||
          _returning ||
          model.connecting ||
          model.streaming ||
          _background ||
          !_viewFocused ||
          !_hostCanControl ||
          model.targetId != target ||
          model.guestSessionId != failedSession ||
          model.error != failedError ||
          !guestReadyForReconnect(model, target)) {
        return;
      }
      _guestReconnectAttempts++;
      unawaited(model.connect(target, startIfStopped: false));
    });
  }

  void _reconnectGuest() {
    if (model.connecting || !_hostCanControl || model.targetId.isEmpty) return;
    _cancelGuestRecovery();
    _guestReconnectAttempts = 0;
    final target = model.targetId;
    final stopped = model.instances.any(
        (instance) => instance.id == target && instance.state == 'stopped');
    unawaited(model.connect(target, startIfStopped: stopped));
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
    if (!model.streaming || model.targetId != _observedTargetId) {
      _doubleBack.reset();
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
    _updateGuestRecovery();
    _trackStartup();
    _announceLive();
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

  /// Back inside a running game (dashboard): closes the text composer, else
  /// the first press only warns, the second leaves.
  void _gameBack() {
    if (_textComposerVisible) {
      setState(_discardTextComposer);
      return;
    }
    if (_doubleBack.press(DateTime.now())) {
      unawaited(_back());
      return;
    }
    final hint = (ScaffoldMessenger.of(context)..hideCurrentSnackBar())
        .showSnackBar(SnackBar(
      content: Text(translate('Back again to leave the game')),
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
      margin: backHintMargin(_barAxis),
    ));
    _backHint = hint;
    hint.closed.then((_) {
      if (_backHint == hint) _backHint = null;
    });
  }

  Future<bool> _back() async {
    _cancelGuestRecovery();
    _cancelGuestInput();
    _discardTextComposer(restoreKeyboardFocus: false);
    // The hint is about the game; it must not outlive it on the grid.
    if (_backHint != null) {
      _backHint = null;
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
    }
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
    _cancelGuestRecovery();
    _startupTicker?.cancel();
    _startupTicker = null;
    _startupClock.stop();
    _cancelGuestInput();
    if (_textComposerVisible) {
      _cancelGuestInput();
      unawaited(_hideGuestSoftKeyboard());
    }
    model.removeListener(_changed);
    widget.ffi.ffiModel.removeListener(_permissionChanged);
    if (_guestPresentation) unawaited(_restoreRemotePresentation());
    _keyboardFocus.dispose();
    _textFocus.dispose();
    _textController.dispose();
    _banner.dispose();
    if (!widget.dashboardMode) model.framePacer.focused = true;
    super.dispose();
  }

  void _openTextComposer() {
    if (!canGuestControl ||
        !model.streaming ||
        !model.guestTextSupported ||
        _returning) {
      return;
    }
    _cancelGuestInput();
    setState(() => _textComposerVisible = true);
    unawaited(_showGuestSoftKeyboard());
  }

  Future<void> _showGuestSoftKeyboard() async {
    try {
      await widget.ffi.invokeMethod('enable_soft_keyboard', true);
    } catch (error) {
      if (mounted && _textComposerVisible) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unable to open phone keyboard: $error')),
        );
      }
    }
    if (!mounted || !_textComposerVisible) {
      await _hideGuestSoftKeyboard();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _textComposerVisible) _textFocus.requestFocus();
    });
  }

  Future<void> _hideGuestSoftKeyboard() async {
    try {
      await widget.ffi.invokeMethod('enable_soft_keyboard', false);
    } catch (error) {
      debugPrint('Unable to restore phone keyboard state: $error');
    }
  }

  void _discardTextComposer({bool restoreKeyboardFocus = true}) {
    if (_textComposerVisible) {
      _cancelGuestInput();
      unawaited(_hideGuestSoftKeyboard());
    }
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
    _updateGuestRecovery();
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
    if (!widget.dashboardMode) {
      model.framePacer.focused = !_background && _viewFocused;
    }
    _updateGuestRecovery();
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
    if (!widget.dashboardMode) {
      model.framePacer.focused = !_background && _viewFocused;
    }
    _updateGuestRecovery();
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
  Widget build(BuildContext context) => PopScope(
        canPop: !widget.dashboardMode && !model.selected && !model.connecting,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop || _returning) return;
          if (widget.dashboardMode && model.streaming) {
            _gameBack();
          } else {
            unawaited(_back());
          }
        },
        child: AnimatedBuilder(
          animation: model,
          builder: (context, _) {
            final immersive = model.selected && model.streaming;
            return Scaffold(
              backgroundColor: immersive ? Colors.black : null,
              appBar: immersive || widget.dashboardMode
                  ? null
                  : AppBar(
                      title: Text(model.selected
                          ? _selectedName
                          : translate('Emulators')),
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
        padding: const EdgeInsets.all(MirpgRemoteTheme.pageMargin),
        children: [
          MirpgSectionHeader(
            title: translate('Emulators'),
            subtitle: translate('Choose an emulator to view and control.'),
          ),
          const SizedBox(height: 12),
          if (model.error.isNotEmpty) _error(),
          if (model.loading)
            const Center(
                child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator())),
          if (!model.loading && model.instances.isEmpty)
            MirpgSurface(
              child: Text(translate(
                  'No emulators found on this PC. Start one on the PC, then refresh.')),
            ),
          for (final instance in model.instances)
            Builder(builder: (context) {
              final uiState = emulatorUiState(instance);
              final canOpen =
                  canControl && !model.connecting && uiState.canOpen;
              return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: MirpgSurface(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: MirpgStudioPalette.of(context).raised,
                        borderRadius: BorderRadius.circular(12),
                      ),
                        child: SizedBox(
                        width: 48,
                        height: 48,
                        child: Icon(Icons.android_outlined,
                            color: MirpgStudioPalette.of(context).accent),
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
                              emulatorProviderLabel(instance.provider),
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
                                    ?.copyWith(color: MirpgStudioPalette.of(context).error)),
                          ],
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.icon(
                                onPressed: canOpen
                                    ? () => unawaited(model.connect(instance.id,
                                        launchDefaultApp: false))
                                    : null,
                                icon: Icon(instance.state == 'stopped'
                                    ? Icons.power_settings_new_rounded
                                    : Icons.play_arrow_rounded),
                                label: Text(translate(
                                    instance.state == 'stopped'
                                        ? 'Start'
                                        : 'Open')),
                              ),
                              if (instance.defaultPackage.isNotEmpty)
                                OutlinedButton.icon(
                                  onPressed: canOpen
                                      ? () => unawaited(model.connect(
                                          instance.id,
                                          launchDefaultApp: true))
                                      : null,
                                  icon:
                                      const Icon(Icons.sports_esports_outlined),
                                  label:
                                      Text(translate('Open and launch game')),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    EmulatorStateBadge(state: uiState, onDarkSurface: false),
                  ],
                ),
              ),
            );
            }),
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
          color: MirpgStudioPalette.of(context).error.withOpacity(0.08),
          borderColor: MirpgStudioPalette.of(context).error.withOpacity(0.45),
          child: Text(model.error,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: MirpgStudioPalette.of(context).error)),
        ),
      );

  Widget _guest() {
    if (!model.streaming) return _starting();
    return KeyboardListener(
      focusNode: _keyboardFocus,
      autofocus: true,
      onKeyEvent: _key,
      child: ColoredBox(
        color: Colors.black,
        child: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            final axis = _barAxis;
            final inset = model.height > model.width ? 8.0 : 64.0;
            final barInset =
                axis == Axis.vertical ? kPlayNavBarThickness : 0.0;
            return Stack(
            children: [
              GuestControlStage(
                barAxis: axis,
                video: _guestCanvas(),
                controlsVisible: _guestControlsVisible,
                onToggleControls: _toggleGuestControls,
                legacyLayout: !widget.dashboardMode,
                composer: widget.dashboardMode && _textComposerVisible
                    ? _guestTextComposer()
                    : null,
                // The fallback page keeps its own row, with the composer in
                // its place, exactly as before the play rail.
                controls: widget.dashboardMode
                    ? _playBar(axis)
                    : ColoredBox(
                        color: Colors.black,
                        child: _textComposerVisible
                            ? _guestTextComposer()
                            : _guestControls(),
                      ),
              ),
              if (widget.dashboardMode)
                Positioned(
                  top: 8,
                  left: inset,
                  right: inset + barInset,
                  child: GuestNameBanner(controller: _banner),
                ),
              if (!canControl || !model.guestFrameFresh)
              ListenableBuilder(
                listenable: _banner,
                // The banner sits above the warning chip while it shows.
                builder: (context, child) => AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  top: _banner.visible ? 8.0 + 48 : 8,
                  left: inset,
                  right: inset + barInset,
                  child: child!,
                ),
                child: IgnorePointer(
                  child: Center(
                    child: MirpgStatusChip(
                      label: !canControl
                          ? '$_shownName · ${translate('View only')}'
                          : '$_shownName · ${translate('Reconnecting…')}',
                      icon: canGuestControl
                          ? Icons.touch_app_outlined
                          : Icons.hourglass_top_rounded,
                      tone: canGuestControl
                          ? MirpgStatusTone.good
                          : MirpgStatusTone.warning,
                    ),
                  ),
                ),
              ),
            ],
          );
          }),
        ),
      ),
    );
  }

  /// The bar goes under a portrait game and on the right of a landscape one.
  /// Until the stream reports its size it sits at the bottom.
  Axis get _barAxis => widget.dashboardMode &&
          model.streaming &&
          model.width > model.height
      ? Axis.vertical
      : Axis.horizontal;

  Widget _playBar(Axis axis) => PlayNavBar(
        axis: axis,
        onNavigate: canGuestControl && model.streaming && !_returning
            ? (action) => unawaited(model.navigation(action))
            : null,
        onMenu: _returning ? null : _openPlayMenu,
        tr: translate,
      );

  /// The bar's menu: switcher, keyboard, grid and this emulator's actions.
  /// Input held on the game is released first, as for any other sheet.
  Future<void> _openPlayMenu() {
    _cancelGuestInput();
    return showPlayMenu(
      context,
      accounts: widget.accounts,
      currentId: model.targetId,
      switching: model.connecting,
      onSelect: (id) {
        final select = widget.onSelectTarget;
        if (select != null && id != model.targetId) {
          unawaited(_switchGuest(() => select(id)));
        }
      },
      onShowAll: widget.onSwitch == null || _returning
          ? null
          : () => unawaited(_switchView()),
      onGrid: () {
        if (!_returning) unawaited(_back());
      },
      onCurrentActions: widget.onCurrentActions,
      onType: canGuestControl &&
              model.streaming &&
              model.guestTextSupported &&
              !_returning
          ? _openTextComposer
          : null,
      tr: translate,
    );
  }

  /// Leaves this emulator for another one: input held on this guest is
  /// released and the composer closed before the switch starts.
  Future<void> _switchGuest(Future<void> Function() switchTo) async {
    if (model.connecting || _returning) return;
    _cancelGuestInput();
    _discardTextComposer(restoreKeyboardFocus: false);
    await switchTo();
  }

  String get _shownName {
    final target = model.targetId;
    final shown = target.isEmpty ? '' : widget.nameFor?.call(target) ?? '';
    return shown.isEmpty ? _selectedName : shown;
  }

  String get _providerLine {
    final instance = model.instances
        .where((instance) => instance.id == model.targetId)
        .firstOrNull;
    if (instance == null) return '';
    return [
      emulatorProviderLabel(instance.provider),
      if (instance.androidVersion.isNotEmpty)
        'Android ${instance.androidVersion}',
    ].join(' · ');
  }

  /// Before the stream is live: the startup checklist (or the failure on
  /// it), or, when switching to an emulator that was already running, its
  /// last frame with its name.
  Widget _starting() {
    final name = _shownName;
    if (!_showsChecklist) {
      return SwitchPlaceholder(frame: widget.switchFrame, name: name);
    }
    final failed = model.error.isNotEmpty;
    final retryArmed = failed && _guestReconnectTimer != null;
    // Rebooted from the menu: the stream ended on purpose and reopens once
    // Android is back.
    final rebooting = failed && model.isRebooting(model.targetId);
    final superseded = failed && model.guestSuperseded;
    final showOnPc = widget.onShowOnPc;
    return StartupChecklist(
      name: name,
      providerLabel: _providerLine,
      currentStep: _lastStartupStep,
      failedStep: failed ? (_guestWasLive ? 3 : _lastStartupStep) : null,
      elapsed: _startupClock.elapsed,
      failureTitle: !failed
          ? ''
          : rebooting
              ? 'Rebooting {$name}'
              : superseded
                  ? 'Opened on another device'
                  : _guestWasLive
                  ? 'Lost the screen for {$name}'
                  : "Couldn't start {$name}",
      failureMessage: rebooting || superseded ? '' : model.error,
      retryNote: !retryArmed
          ? ''
          : _guestReconnectAttempts == 0
              ? 'Trying again in 1 s (1 of 2)'
              : 'Trying again in 3 s (2 of 2)',
      onBack: () {
        if (!_returning) unawaited(_back());
      },
      backLabel: startupBackLabel(dashboardMode: widget.dashboardMode),
      backIcon: widget.dashboardMode
          ? Icons.grid_view_rounded
          : Icons.desktop_windows_outlined,
      onTryAgain: model.targetId.isEmpty ||
              model.connecting ||
              _returning ||
              !_hostCanControl
          ? null
          : _reconnectGuest,
      onShowOnPc: showOnPc == null ? null : () => unawaited(showOnPc()),
      tryAgainLabel: superseded ? 'Reopen' : 'Try again',
    );
  }

  void _toggleGuestControls() {
    _cancelGuestInput();
    setState(() {
      _guestControlsVisible = !_guestControlsVisible;
      if (!_guestControlsVisible) _discardTextComposer();
    });
  }

  Widget _guestTextComposer() => GuestTextComposer(
        controller: _textController,
        focusNode: _textFocus,
        onSubmitted: (_) {
          if (mounted && _textComposerVisible) _textFocus.requestFocus();
        },
        onSend: canGuestControl && !_sendingText
            ? () => unawaited(_sendTextDraft())
            : null,
        onClose: () => setState(_discardTextComposer),
      );

  Future<void> _switchView() async {
    _cancelGuestInput();
    _discardTextComposer(restoreKeyboardFocus: false);
    if (widget.onSwitch != null) {
      await widget.onSwitch!();
    } else {
      await _back();
    }
  }

  Widget _guestCanvas() => LayoutBuilder(
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
                  ? widget.ffi.imageModel.dashboardImage(model.videoChannel)
                  : widget.ffi.imageModel.image,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.low,
            ),
          ),
        ),
      );

  Widget _guestControls() => SizedBox(
        height: 56,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _overlayButton(
              tooltip: widget.onSwitch == null
                  ? 'Return to Windows desktop'
                  : 'Switch view',
              icon: widget.onSwitch == null
                  ? Icons.desktop_windows_outlined
                  : Icons.view_agenda_outlined,
              onPressed: () => unawaited(_switchView()),
            ),
            if (widget.onReturn != null)
              _overlayButton(
                tooltip: 'Dashboard',
                icon: Icons.grid_view_outlined,
                onPressed: () => unawaited(_back()),
              ),
            const Spacer(),
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
                  : null,
            ),
            _overlayNavigation(Icons.arrow_back, 'Back', 'back'),
            _overlayNavigation(Icons.home_outlined, 'Home', 'home'),
            _overlayNavigation(Icons.crop_square, 'Recents', 'recents'),
          ],
        ),
      );

  void _restoreGuestCanvasFocus() {
    // A delivered touch proves view focus even if Android missed its focus event.
    if (_textComposerVisible ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
        !_hostCanControl ||
        !model.guestFrameFresh) return;
    final changed = _background || !_viewFocused;
    if (changed) _cancelGuestInput();
    _background = false;
    _viewFocused = true;
    if (!_keyboardFocus.hasFocus) _keyboardFocus.requestFocus();
    if (changed) {
      if (!widget.dashboardMode) model.framePacer.focused = true;
      _updateGuestRecovery();
      setState(() {});
    }
  }

  void _touch(int action, PointerEvent event, BoxConstraints box) {
    if (action == 0) {
      _restoreGuestCanvasFocus();
    }
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
}
