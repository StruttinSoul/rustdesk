import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'host_management_model.dart';
import 'platform_model.dart';
import 'remote_operation_state.dart';
import 'remote_frame_pacer.dart';

typedef EmulatorCommandSender = Future<void> Function(String key, String value);

({double left, double top, double width, double height})? containedGuestFrame({
  required double viewportWidth,
  required double viewportHeight,
  required int guestWidth,
  required int guestHeight,
}) {
  if (viewportWidth <= 0 ||
      viewportHeight <= 0 ||
      guestWidth <= 0 ||
      guestHeight <= 0) return null;
  final scale =
      math.min(viewportWidth / guestWidth, viewportHeight / guestHeight);
  final width = guestWidth * scale;
  final height = guestHeight * scale;
  return (
    left: (viewportWidth - width) / 2,
    top: (viewportHeight - height) / 2,
    width: width,
    height: height,
  );
}

({int x, int y})? mapEmulatorTouch({
  required double localX,
  required double localY,
  required double viewportWidth,
  required double viewportHeight,
  required int guestWidth,
  required int guestHeight,
  bool clampToFrame = false,
}) {
  final frame = containedGuestFrame(
    viewportWidth: viewportWidth,
    viewportHeight: viewportHeight,
    guestWidth: guestWidth,
    guestHeight: guestHeight,
  );
  if (frame == null) return null;
  final scale = frame.width / guestWidth;
  final left = frame.left;
  final top = frame.top;
  final right = left + frame.width;
  final bottom = top + frame.height;
  if (!clampToFrame &&
      (localX < left || localX >= right || localY < top || localY >= bottom)) {
    return null;
  }
  final x = (((localX.clamp(left, right) - left) / scale).floor())
      .clamp(0, guestWidth - 1)
      .toInt();
  final y = (((localY.clamp(top, bottom) - top) / scale).floor())
      .clamp(0, guestHeight - 1)
      .toInt();
  return (x: x, y: y);
}

/// Emulators the phone dashboard can stream: BlueStacks and Google's
/// Android Emulator (`avd`, listed by the PC while it is running).
bool isDashboardGuestProvider(String provider) =>
    provider == 'bluestacks' || provider == 'avd';

String emulatorProviderLabel(String provider) => switch (provider) {
      'bluestacks' => 'BlueStacks',
      'avd' => 'Android Emulator',
      _ => provider,
    };

class RemoteEmulator {
  const RemoteEmulator(
      {required this.id,
      required this.name,
      required this.provider,
      required this.state,
      this.androidVersion = '',
      this.defaultPackage = '',
      this.error = '',
      this.progressPercent = 0,
      this.windowVisible = false});
  final String id;
  final String name;
  final String provider;
  final String state;
  final String androidVersion;
  final String defaultPackage;
  final String error;
  final int progressPercent;
  final bool windowVisible;

  /// A ready guest can be reselected without requesting that BlueStacks boot.
  bool get readyForReconnect => state == 'ready' || state == 'running';

  String get runtimeLabel => switch (state) {
        'ready' || 'running' => 'Running',
        'booting' || 'starting' => 'Starting',
        'adb_offline' => 'ADB offline',
        'stopped' => 'Stopped',
        'cloning' => 'Cloning $progressPercent%',
        _ => 'Unknown',
      };
}

/// The one-word status every emulator surface shows.
enum EmulatorUiWord { live, starting, stopped, stopping, copying, problem }

/// `label` and `causeKey` are translate keys (label may carry one `{value}`).
/// `pcMessage` is the PC's own text, shown verbatim and preferred over
/// `causeKey`.
class EmulatorUiState {
  const EmulatorUiState(this.word, this.label,
      {this.causeKey = '', this.pcMessage = ''});
  final EmulatorUiWord word;
  final String label;
  final String causeKey;
  final String pcMessage;

  bool get canOpen =>
      word != EmulatorUiWord.stopping && word != EmulatorUiWord.copying;
  bool get hasCause => causeKey.isNotEmpty || pcMessage.isNotEmpty;
}

/// Phone-side signals that the PC's instance state does not carry.
class EmulatorUiFlags {
  const EmulatorUiFlags(
      {this.frameCurrent = false,
      this.shuttingDown = false,
      this.startRequested = false,
      this.seenLive = false,
      this.guestFailure = ''});
  final bool frameCurrent;
  final bool shuttingDown;
  final bool startRequested;

  /// The phone saw it live after the list that still says "stopped" was
  /// asked for.
  final bool seenLive;
  final String guestFailure;
}

EmulatorUiState emulatorUiState(RemoteEmulator instance,
    {RemotePreview? preview,
    EmulatorUiFlags flags = const EmulatorUiFlags()}) {
  final state = instance.state;
  if (flags.shuttingDown || state == 'stopping') {
    return const EmulatorUiState(EmulatorUiWord.stopping, 'Stopping');
  }
  if (state == 'shutdown_failed') {
    return instance.error.isNotEmpty
        ? EmulatorUiState(EmulatorUiWord.problem, 'Problem',
            pcMessage: instance.error)
        : const EmulatorUiState(EmulatorUiWord.problem, 'Problem',
            causeKey: "Couldn't stop");
  }
  if (state == 'cloning') {
    final p = instance.progressPercent.clamp(0, 100);
    return EmulatorUiState(EmulatorUiWord.copying, 'Copying {$p}%');
  }
  if (flags.guestFailure.isNotEmpty || preview?.state == 'failed') {
    final previewError = preview?.error ?? '';
    return EmulatorUiState(EmulatorUiWord.problem, 'Problem',
        causeKey: 'Stream stopped',
        pcMessage: previewError.isNotEmpty ? previewError : flags.guestFailure);
  }
  if (state == 'stopped') {
    if (flags.seenLive) {
      return const EmulatorUiState(EmulatorUiWord.live, 'Live');
    }
    if (flags.startRequested) {
      return const EmulatorUiState(EmulatorUiWord.starting, 'Starting');
    }
    return EmulatorUiState(EmulatorUiWord.stopped, 'Stopped',
        pcMessage: instance.error);
  }
  if (state == 'booting' || state == 'starting') {
    return const EmulatorUiState(EmulatorUiWord.starting, 'Starting');
  }
  if (state == 'adb_offline') {
    return EmulatorUiState(EmulatorUiWord.problem, 'Problem',
        causeKey: 'Android not responding', pcMessage: instance.error);
  }
  if (state == 'ready' || state == 'running') {
    if (preview?.state == 'streaming' && !flags.frameCurrent) {
      return const EmulatorUiState(EmulatorUiWord.problem, 'Problem',
          causeKey: 'Stream stopped');
    }
    return const EmulatorUiState(EmulatorUiWord.live, 'Live');
  }
  return EmulatorUiState(EmulatorUiWord.problem, 'Problem',
      causeKey: 'Status unavailable', pcMessage: instance.error);
}

class EmulatorModel extends ChangeNotifier {
  EmulatorModel(
    this.sessionId, {
    EmulatorCommandSender? commandSender,
    Duration guestFrameTimeout = const Duration(seconds: 4),
    Duration hostOperationTimeout = const Duration(seconds: 20),
  })  : _guestFrameTimeout = guestFrameTimeout,
        _hostOperationTimeout = hostOperationTimeout,
        _sender = commandSender ??
            ((key, value) => bind.sessionSetCommon(
                sessionId: sessionId, key: key, value: value));
  final UuidValue sessionId;
  final EmulatorCommandSender _sender;
  final Duration _guestFrameTimeout;
  final Duration _hostOperationTimeout;
  Future<void> _outbound = Future.value();
  int _sequence = 0;
  int _inventoryRequest = 0;
  int _selectionRequest = 0;
  int _desktopRequest = 0;
  Timer? _selectionTimeout;
  Timer? _inventoryTimeout;
  Timer? _desktopTimeout;
  Timer? _hostStatusTimeout;
  Timer? _hostWindowsTimeout;
  Timer? _phoneWorkspaceTimeout;
  Timer? _gatewayStatusTimeout;
  Timer? _gatewayReconcileTimer;
  Timer? _guestFrameTimer;
  bool _guestFrameFresh = false;
  bool _disposed = false;
  List<RemoteEmulator> instances = [];

  /// When the list [instances] came from was asked for (null before the
  /// first). A state in it is no newer than this.
  DateTime? listRequestedAt;
  DateTime? _inventoryRequestedAt;
  bool loading = false;
  bool selected = false;
  bool streaming = false;
  int guestSessionId = 0;
  int width = 0;
  int height = 0;
  String error = '';

  /// Why the emulator list is missing or incomplete (timeout, provider errors,
  /// a failed list send). Kept apart from [error] so a start or stream failure
  /// never shows as a list problem, and the reverse.
  String listError = '';
  String targetId = '';
  String startupPhase = '';
  bool connecting = false;
  bool dashboardSupported = false;
  bool dashboardActive = false;
  final framePacer = RemoteFramePacer();
  bool? _monitorPreviewMode;

  Future<void> setMonitorPreviewMode(bool preview, {bool force = false}) async {
    if (_disposed || (!force && _monitorPreviewMode == preview)) return;
    _monitorPreviewMode = preview;
    try {
      await _sender('dashboard-preview-mode', preview.toString());
    } catch (failure) {
      if (_monitorPreviewMode == preview) _monitorPreviewMode = null;
      debugPrint('Could not apply preview frame rate: $failure');
    }
  }

  int _previewRequest = 0;
  int _previewAcknowledgedRequest = 0;
  int _hostStatusRequest = 0;
  int _hostWindowsRequest = 0;
  int _phoneWorkspaceRequest = 0;
  int _gatewayStatusRequest = 0;
  int _hostStatusStartedMonotonicMs = -1;
  int _gatewayStatusStartedMonotonicMs = -1;
  bool _inventoryCurrent = false;
  RemoteCapabilitySet _capabilities = RemoteCapabilitySet.fromWire(null);
  final RemoteOperationTracker _hostOperations = RemoteOperationTracker();
  final Map<int, Timer> _hostOperationTimeouts = {};
  final Map<int, int> _hostOperationStartedMonotonicMs = {};
  final Map<int, Completer<HostWindowInfo?>> _hostWindowFocusCompletions = {};
  final Map<int, Completer<HostShellRestartResult>> _shellRestartCompletions =
      {};
  final Map<int, Completer<AvdActionResult>> _avdActionCompletions = {};
  final Set<int> _pendingHostOperations = {};
  final Set<String> _shutdownPending = {};
  final Map<int, String> _shutdownRequests = {};
  Timer? _shutdownRefreshTimer;
  Timer? _avdRefreshTimer;

  CapabilityStatus get emulatorShutdownCapability => _capabilities.status('host.emulator_shutdown.v1');
  bool isEmulatorShuttingDown(String id) => _shutdownPending.contains(id) ||
      instances.any((item) => item.id == id && item.state == 'stopping');
  /// [runningAsKnown]: the phone knows it is running although the list
  /// (older than that) still says stopped.
  bool canShutdownEmulator(String id, {bool runningAsKnown = false}) =>
      _canMutateHost('host.emulator_shutdown.v1') &&
      !isEmulatorShuttingDown(id) && instances.any((item) => item.id == id &&
          (item.provider == 'bluestacks' || item.provider == 'avd') &&
          (item.state != 'stopped' || runningAsKnown));

  bool get canManageAvds => _canMutateHost('host.avd_manage.v1');

  /// Whether [id] can be rebooted from the phone: Android restarts inside the
  /// running emulator, which keeps running.
  bool canRebootEmulator(String id, {bool runningAsKnown = false}) =>
      _canMutateHost('host.emulator_power.v1') &&
      !isEmulatorShuttingDown(id) &&
      instances.any((item) =>
          item.id == id &&
          isDashboardGuestProvider(item.provider) &&
          (item.state != 'stopped' || runningAsKnown) &&
          item.state != 'cloning');

  /// Emulators rebooted from this phone whose Android is not back yet, with
  /// when the reboot was acknowledged and whether a list has shown it down.
  final Map<String, ({int ticks, bool sawDown})> _rebooting = {};
  Timer? _rebootRefreshTimer;
  static const _rebootTick = Duration(milliseconds: 2500);

  /// 120 s of list ticks.
  static const _rebootTicks = 48;

  /// The list request whose answer keeps a failed game's error.
  int _guestErrorKeptFor = 0;

  bool isRebooting(String id) => _rebooting.containsKey(id);

  /// Lists the PC every 2.5 s after a reboot until Android is back (a list
  /// showed it down, then ready) or 120 s passed, so a failed game sees the
  /// emulator ready and reconnects on its own. The guest's error is kept.
  void _watchReboot(String id) {
    _rebooting[id] = (ticks: 0, sawDown: false);
    _rebootRefreshTimer ??= Timer.periodic(_rebootTick, (timer) {
      for (final id in _rebooting.keys.toList()) {
        final watch = _rebooting[id]!;
        _rebooting[id] = (ticks: watch.ticks + 1, sawDown: watch.sawDown);
      }
      _trackReboots();
      if (_disposed || !hostConnectionCurrent || _rebooting.isEmpty) {
        timer.cancel();
        _rebootRefreshTimer = null;
        return;
      }
      if (!loading) unawaited(refresh(keepGuestError: true));
    });
  }

  void _trackReboots() {
    for (final id in _rebooting.keys.toList()) {
      final watch = _rebooting[id]!;
      final matches = instances.where((item) => item.id == id);
      final ready = matches.isNotEmpty && matches.first.readyForReconnect;
      if (watch.ticks >= _rebootTicks || (watch.sawDown && ready)) {
        _rebooting.remove(id);
      } else if (!ready && !watch.sawDown) {
        _rebooting[id] = (ticks: watch.ticks, sawDown: true);
      }
    }
  }

  /// Memory, cores and screen are offered for managed emulators only.
  bool canChangeAvdSettings(String id) =>
      _canMutateHost('host.avd_settings.v1') &&
      instances.any((item) => item.id == id && item.provider == 'avd');

  /// Why a managed-emulator action is unavailable right now, or null.
  String? avdActionBlocker(String id, String action) {
    final matches = instances.where((item) => item.id == id);
    if (matches.isEmpty) return null;
    final item = matches.first;
    if (item.state == 'cloning') return 'Copy in progress';
    if (action == 'avd_window' ||
        action == 'avd_settings_set' ||
        action == 'emulator_reboot') {
      return null;
    }
    if (item.state != 'stopped') return 'Stop it first';
    return null;
  }

  String suggestAvdName(String base) {
    final taken = instances.where((item) => item.provider == 'avd')
        .map((item) => item.id.replaceFirst('avd:', '').toLowerCase()).toSet();
    var clean = base.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceFirst(RegExp(r'^\.+'), '');
    if (clean.isEmpty) clean = 'Emulator';
    if (clean.length > 64) clean = clean.substring(0, 64);
    final reserved = RegExp(r'^(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\..*)?$', caseSensitive: false);
    var candidate = clean;
    for (var n = 2; taken.contains(candidate.toLowerCase()) || reserved.hasMatch(candidate); n++) {
      final suffix = '_$n';
      candidate = '${clean.substring(0, math.min(clean.length, 64 - suffix.length))}$suffix';
    }
    return candidate;
  }

  Future<AvdActionResult> createAvd(String name) =>
      _sendAvdAction('avd_create', 'emulator:avd:$name', {'new_name': name});
  Future<AvdActionResult> cloneAvd(String id, String name) => _sendAvdAction(
      'avd_clone', 'emulator:$id', {'component': id, 'new_name': name}, id: id);
  Future<AvdActionResult> renameAvd(String id, String name) => _sendAvdAction(
      'avd_rename', 'emulator:$id', {'component': id, 'new_name': name}, id: id);
  Future<AvdActionResult> deleteAvd(String id) =>
      _sendAvdAction('avd_delete', 'emulator:$id', {'component': id}, id: id);
  Future<AvdActionResult> setAvdWindowVisible(String id, bool visible) => _sendAvdAction(
      'avd_window', 'emulator:$id', {'component': id, 'window_visible': visible}, id: id);

  Future<AvdActionResult> rebootEmulator(String id,
      {bool runningAsKnown = false}) {
    if (!canRebootEmulator(id, runningAsKnown: runningAsKnown)) {
      return Future.value(const AvdActionResult(
          false, 'This PC can’t manage emulators from the phone right now.'));
    }
    return _sendAvdAction('emulator_reboot', 'emulator:$id', {'component': id},
        id: id, capability: 'host.emulator_power.v1');
  }

  /// Saves [change] for the next start; with [restart] a running emulator
  /// is stopped and started again with it.
  Future<AvdActionResult> saveAvdSettings(String id, AvdSettings change,
      {bool restart = false}) {
    if (!canChangeAvdSettings(id) || change.isEmpty) {
      return Future.value(const AvdActionResult(
          false, 'This PC can’t manage emulators from the phone right now.'));
    }
    return _sendAvdAction(
        'avd_settings_set',
        'emulator:$id',
        {
          'component': id,
          'ram_mb': change.ramMb ?? 0,
          'cpu_cores': change.cores ?? 0,
          'screen_width': change.screen?.$1 ?? 0,
          'screen_height': change.screen?.$2 ?? 0,
          'restart': restart,
        },
        id: id,
        capability: 'host.avd_settings.v1');
  }

  final Map<int, Completer<AvdSettingsLoad>> _avdSettingsReads = {};
  final Map<int, Timer> _avdSettingsReadTimeouts = {};

  /// The PC's current and saved settings of managed emulator [id].
  Future<AvdSettingsLoad> loadAvdSettings(String id) {
    if (!canChangeAvdSettings(id)) {
      return Future.value((
        info: null,
        error: 'This PC can’t manage emulators from the phone right now.'
      ));
    }
    final requestId = ++_sequence;
    final completion = Completer<AvdSettingsLoad>();
    _avdSettingsReads[requestId] = completion;
    _avdSettingsReadTimeouts[requestId] = Timer(_hostOperationTimeout,
        () => _finishAvdSettingsRead(requestId, null, 'The PC did not answer. Try again.'));
    unawaited(_send(
        {'action': 'avd_settings_get', 'request_id': requestId, 'component': id}));
    return completion.future;
  }

  void _finishAvdSettingsRead(int requestId, AvdSettingsInfo? info, String error) {
    _avdSettingsReadTimeouts.remove(requestId)?.cancel();
    final completion = _avdSettingsReads.remove(requestId);
    if (completion != null && !completion.isCompleted) {
      completion.complete((info: info, error: error));
    }
  }

  /// Resolves with the PC's answer (or why there is none), not when sent.
  Future<AvdActionResult> _sendAvdAction(
      String action, String targetIdentity, Map<String, dynamic> fields,
      {String? id, String capability = 'host.avd_manage.v1'}) {
    if (!_canMutateHost(capability)) {
      return Future.value(const AvdActionResult(
          false, 'This PC can’t manage emulators from the phone right now.'));
    }
    if (id != null) {
      if (!instances.any((item) =>
          item.id == id &&
          (item.provider == 'avd' ||
              (action == 'emulator_reboot' &&
                  isDashboardGuestProvider(item.provider))))) {
        return Future.value(
            const AvdActionResult(false, 'This emulator is no longer listed.'));
      }
      final blocker = avdActionBlocker(id, action);
      if (blocker != null) {
        hostError = blocker;
        if (!_disposed) notifyListeners();
        return Future.value(AvdActionResult(false, blocker));
      }
    }
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    hostError = hostMessage = '';
    _beginHostOperation(requestId: requestId, operationId: operationId,
        targetIdentity: targetIdentity, action: action);
    _avdRefreshTimer ??= Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_disposed || !hostConnectionCurrent) { timer.cancel(); _avdRefreshTimer = null; return; }
      final busy = instances.any((item) => item.state == 'cloning') ||
          _pendingHostOperations.any((request) =>
              _hostOperations.operationForRequest(request)?.action.startsWith('avd_') ?? false);
      if (!busy) { timer.cancel(); _avdRefreshTimer = null; return; }
      if (!loading && !connecting) unawaited(refresh());
    });
    final completion = Completer<AvdActionResult>();
    _avdActionCompletions[requestId] = completion;
    notifyListeners();
    unawaited(_sendHostOperation({
      'action': action, 'request_id': requestId, ...fields,
      'operation_id': operationId, 'session_identity': _operationSessionIdentity,
      'target_identity': targetIdentity, 'session_generation': _operationGeneration,
    }, requestId: requestId, capability: capability,
      stillValid: () => hostConnectionCurrent &&
          (id == null || instances.any((item) => item.id == id))));
    return completion.future;
  }

  void _finishAvdAction(int requestId, bool ok, String message) {
    final completion = _avdActionCompletions.remove(requestId);
    if (completion != null && !completion.isCompleted) {
      completion.complete(AvdActionResult(ok, message));
    }
  }

  void _abandonAvdActions() {
    for (final requestId in _avdSettingsReads.keys.toList()) {
      _finishAvdSettingsRead(requestId, null,
          'The connection changed before the PC answered. Refresh to see the result.');
    }
    for (final completion in _avdActionCompletions.values) {
      if (!completion.isCompleted) {
        completion.complete(const AvdActionResult(false,
            'The connection changed before the PC answered. Refresh to see the result.'));
      }
    }
    _avdActionCompletions.clear();
  }

  Future<void> shutdownEmulator(String id, {bool runningAsKnown = false}) async {
    if (isEmulatorShuttingDown(id)) return;
    if (!canShutdownEmulator(id, runningAsKnown: runningAsKnown)) {
      hostError = 'Shutdown is not available for this emulator. Refresh or update the Windows host.';
      if (!_disposed) notifyListeners();
      return;
    }
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity = 'emulator:$id';
    _shutdownPending.add(id);
    _shutdownRequests[requestId] = id;
    hostError = hostMessage = '';
    _beginHostOperation(requestId: requestId, operationId: operationId,
        targetIdentity: targetIdentity, action: 'emulator_shutdown');
    _shutdownRefreshTimer ??= Timer.periodic(const Duration(seconds: 2), (timer) {
      if (_disposed || !hostConnectionCurrent) { _clearShutdownState(); return; }
      if (_shutdownPending.isEmpty && !instances.any((item) => item.state == 'stopping')) {
        timer.cancel(); _shutdownRefreshTimer = null; return;
      }
      if (!loading && !connecting) unawaited(refresh());
    });
    notifyListeners();
    await _sendHostOperation({
      'action': 'emulator_shutdown', 'request_id': requestId, 'component': id,
      'operation_id': operationId, 'session_identity': _operationSessionIdentity,
      'target_identity': targetIdentity, 'session_generation': _operationGeneration,
    }, requestId: requestId, capability: 'host.emulator_shutdown.v1',
      stillValid: () => hostConnectionCurrent && instances.any((item) =>
          item.id == id && (item.state != 'stopped' || runningAsKnown)));
  }

  void _clearShutdownState() {
    _rebootRefreshTimer?.cancel(); _rebootRefreshTimer = null;
    _rebooting.clear();
    _shutdownRefreshTimer?.cancel(); _shutdownRefreshTimer = null;
    _avdRefreshTimer?.cancel(); _avdRefreshTimer = null;
    _shutdownPending.clear(); _shutdownRequests.clear();
  }

  String _operationSessionIdentity = '';
  int _operationGeneration = 1;
  Set<String> _previewTargets = {};
  final Map<String, RemotePreview> previews = {};

  /// A failed fullscreen guest is distinct from the emulator's runtime state.
  /// Preserve its last failure for the dashboard until the stream reconnects.
  final Map<String, String> guestFailures = {};
  int get previewRequest => _previewRequest;
  int get previewAcknowledgedRequest => _previewAcknowledgedRequest;
  bool get previewsAcknowledged =>
      _previewRequest != 0 && _previewAcknowledgedRequest == _previewRequest;

  void invalidatePreviewAcknowledgement() {
    _monitorPreviewMode = null;
    dashboardActive = false;
    _previewRequest = 0;
    _previewAcknowledgedRequest = 0;
  }

  HostSystemSnapshot? hostSnapshot;
  HostWindowSnapshot? hostWindowsSnapshot;
  HostWindowInfo? focusedHostWindow;
  PhoneWorkspaceSupport? phoneWorkspaceSupport;
  GatewayStatus? gatewayStatus;
  bool _hostStatusLoading = false;
  bool _hostWindowsLoading = false;
  bool _phoneWorkspaceLoading = false;
  bool _gatewayStatusLoading = false;
  bool _gatewayMutationLoading = false;
  bool _gatewayStatusEvidenceValid = false;
  bool _phoneWorkspaceNeedsReconcile = false;
  bool _gatewayNeedsReconcile = false;
  String? _gatewayRestartExpectedIdentity;
  bool _gatewayRestartAcknowledged = false;
  bool _gatewayRestartRequireSiloVerified = false;
  bool _gatewayRestartRequireProfileSelected = false;
  bool _gatewayRestartRequireProfileVerified = false;
  int _gatewayRestartReconcileAttempts = 0;
  static const int _gatewayRestartMaxReconcileAttempts = 15;
  bool get hostLoading =>
      _hostStatusLoading || _pendingHostOperations.isNotEmpty;
  String hostError = '';
  String hostMessage = '';
  String hostWindowsError = '';
  String phoneWorkspaceError = '';
  String phoneWorkspaceMessage = '';
  String gatewayError = '';
  String gatewayMessage = '';
  bool get hostWindowsLoading => _hostWindowsLoading;
  bool get phoneWorkspaceLoading => _phoneWorkspaceLoading;
  bool get gatewayStatusLoading => _gatewayStatusLoading;
  bool get gatewayMutationLoading => _gatewayMutationLoading;
  bool get gatewayNeedsReconcile => _gatewayNeedsReconcile;
  bool get hostConnectionCurrent => _inventoryCurrent && !_disposed;
  bool get hostSnapshotFresh =>
      hostSnapshot?.isFreshAt(hostMonotonicNowMs(),
          connected: hostConnectionCurrent) ??
      false;
  bool get gatewayStatusFresh =>
      !_gatewayNeedsReconcile &&
      _gatewayStatusEvidenceValid &&
      (gatewayStatus?.isFreshAt(hostMonotonicNowMs(),
              connected: hostConnectionCurrent) ??
          false);
  CapabilityStatus get hostProcessEndCapability =>
      _capabilities.status('host.process_end');
  CapabilityStatus get hostProcessIdentityCapability =>
      _capabilities.status('host.process_identity.v2');
  CapabilityStatus get hostRecoveryCapability =>
      _capabilities.status('host.recover.bluestacks_adb');
  CapabilityStatus get hostWindowsCapability =>
      _capabilities.status('host.windows.list.v1');
  CapabilityStatus get hostWindowFocusCapability =>
      _capabilities.status('host.window_focus.v1');
  CapabilityStatus get hostShellRestartCapability =>
      _capabilities.status('host.shell_restart.v1');
  CapabilityStatus get phoneWorkspaceCapability =>
      _capabilities.status('host.phone_workspace.v1');
  CapabilityStatus get gatewayStatusCapability =>
      _capabilities.status('host.gateway.status.v1');
  CapabilityStatus get gatewaySetupCapability =>
      _capabilities.status('host.gateway.setup.v1');
  CapabilityStatus get gatewayImdbCapability =>
      _capabilities.status('host.gateway.imdb.v1');
  CapabilityStatus get gatewayRestartCapability =>
      _capabilities.status('host.gateway.restart.v1');
  CapabilityStatus get desktopStreamLivenessCapability =>
      _capabilities.status('desktop.stream_liveness.v1');
  CapabilityStatus get guestTextCapability =>
      _capabilities.status('guest.text.v1');
  bool get guestTextSupported =>
      guestTextCapability == CapabilityStatus.supported;
  bool get guestFrameFresh => streaming && _guestFrameFresh;
  RemoteOperationRecord? hostOperationForRequest(int requestId) =>
      _hostOperations.operationForRequest(requestId);
  int get videoChannel => 0x40000000 | (guestSessionId & 0x3fffffff);

  RemotePreview? previewForChannel(int channel) {
    for (final preview in previews.values) {
      if (preview.channel == channel && preview.state == 'streaming') {
        return preview;
      }
    }
    return null;
  }

  Future<void> setPreviews(List<String> targets, List<int> displays,
      {bool enabled = true}) {
    dashboardActive = enabled;
    _previewRequest = ++_sequence;
    _previewTargets = targets.toSet();
    previews.removeWhere((id, _) => !_previewTargets.contains(id));
    notifyListeners();
    return _send({
      'action': 'previews',
      'request_id': _previewRequest,
      'enabled': enabled,
      'target_ids': targets,
      'displays': displays
    });
  }

  Future<void> _send(Map<String, dynamic> payload) {
    payload['protocol_version'] = 1;
    final next = _outbound.then((_) => _disposed
        ? Future<void>.value()
        : _sender('emulator-request', jsonEncode(payload)));
    _outbound = next.catchError((Object failure) {
      if (_disposed) return;
      _inventoryCurrent = false;
      _clearShutdownState();
      error = failure.toString();
      if (payload['action'] == 'list') listError = failure.toString();
      connecting = false;
      loading = false;
      notifyListeners();
    });
    return _outbound;
  }

  Future<bool> _sendWithResult(
    Map<String, dynamic> payload, {
    bool Function()? stillValid,
  }) {
    payload['protocol_version'] = 1;
    final completion = Completer<bool>();
    final next = _outbound.then((_) async {
      if (_disposed || (stillValid != null && !stillValid())) {
        if (!completion.isCompleted) completion.complete(false);
        return;
      }
      try {
        await _sender('emulator-request', jsonEncode(payload));
        if (!completion.isCompleted) completion.complete(true);
      } catch (failure) {
        if (!completion.isCompleted) completion.complete(false);
        rethrow;
      }
    });
    _outbound = next.catchError((Object failure) {
      if (_disposed) return;
      _inventoryCurrent = false;
      _clearShutdownState();
      error = failure.toString();
      connecting = false;
      loading = false;
      notifyListeners();
    });
    return completion.future;
  }

  /// [keepGuestError] keeps a failed game's error, which its automatic
  /// reconnect waits on.
  Future<void> refresh({bool keepGuestError = false}) {
    loading = true;
    if (!keepGuestError) error = '';
    listError = '';
    _inventoryRequest = ++_sequence;
    _guestErrorKeptFor = keepGuestError ? _inventoryRequest : 0;
    _inventoryRequestedAt = DateTime.now();
    _inventoryTimeout?.cancel();
    _inventoryTimeout = Timer(const Duration(seconds: 25), () {
      loading = false;
      _inventoryCurrent = false;
      _clearShutdownState();
      error = 'The PC did not return its emulator list. Refresh to try again.';
      listError = error;
      notifyListeners();
    });
    notifyListeners();
    return _send({'action': 'list', 'request_id': _inventoryRequest});
  }

  Future<void> connect(String targetId,
      {bool launchDefaultApp = false, bool startIfStopped = true}) {
    if (connecting) return Future.value();
    connecting = true;
    streaming = false;
    _invalidateGuestFrameFreshness(notify: false);
    guestSessionId = 0;
    width = height = 0;
    this.targetId = targetId;
    guestFailures.remove(targetId);
    error = '';
    startupPhase = 'requesting';
    _selectionRequest = ++_sequence;
    _selectionTimeout?.cancel();
    _selectionTimeout = Timer(const Duration(seconds: 120), () {
      connecting = false;
      error = 'Took too long to start. Try again, or go back.';
      notifyListeners();
    });
    notifyListeners();
    return _send({
      'action': 'select',
      'request_id': _selectionRequest,
      'target_id': targetId,
      'start_if_stopped': startIfStopped,
      'launch_default_app': launchDefaultApp
    });
  }

  Future<void> desktop() {
    _desktopRequest = ++_sequence;
    _desktopTimeout?.cancel();
    _desktopTimeout = Timer(const Duration(seconds: 15), () {
      error =
          'The PC did not restore the desktop. Try returning again or disconnect.';
      notifyListeners();
    });
    return _send({'action': 'desktop', 'request_id': _desktopRequest});
  }

  Future<void> navigation(String action) {
    if (!guestFrameFresh || !['back', 'home', 'recents'].contains(action)) {
      return Future.value();
    }
    return _send({
      'action': 'navigation',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'navigation': action
    });
  }

  Future<void> touch(int action, int pointer, int x, int y,
      {int? frameWidth, int? frameHeight}) {
    final inputWidth = frameWidth ?? width;
    final inputHeight = frameHeight ?? height;
    if (!streaming ||
        (action != 3 && !guestFrameFresh) ||
        action < 0 ||
        action > 3 ||
        x < 0 ||
        y < 0 ||
        inputWidth <= 0 ||
        inputHeight <= 0 ||
        x >= inputWidth ||
        y >= inputHeight) return Future.value();
    return _send({
      'action': 'touch',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'touch_action': action,
      'pointer_id': pointer,
      'x': x,
      'y': y,
      'width': inputWidth,
      'height': inputHeight
    });
  }

  Future<void> key(int keycode, bool down) {
    if (!streaming ||
        (down && !guestFrameFresh) ||
        keycode < 1 ||
        keycode > 288) {
      return Future.value();
    }
    return _send({
      'action': 'key',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'keycode': keycode,
      'down': down
    });
  }

  Future<bool> sendText(String text) {
    if (!guestFrameFresh ||
        !guestTextSupported ||
        text.isEmpty ||
        utf8.encode(text).length > 4096) {
      return Future.value(false);
    }
    final sessionId = guestSessionId;
    final selectedTargetId = targetId;
    final selectionRequest = _selectionRequest;
    return _sendWithResult({
      'action': 'text',
      'request_id': ++_sequence,
      'session_id': sessionId,
      'text': text
    }, stillValid: () {
      return guestFrameFresh &&
          guestTextSupported &&
          guestSessionId == sessionId &&
          targetId == selectedTargetId &&
          _selectionRequest == selectionRequest;
    });
  }

  void noteGuestFrameDecoded({
    required int sessionId,
    required int frameWidth,
    required int frameHeight,
  }) {
    if (_disposed ||
        !streaming ||
        guestSessionId != sessionId ||
        width != frameWidth ||
        height != frameHeight) {
      return;
    }
    final changed = !_guestFrameFresh;
    _guestFrameFresh = true;
    _guestFrameTimer?.cancel();
    _guestFrameTimer = Timer(_guestFrameTimeout, () {
      if (_disposed ||
          !streaming ||
          guestSessionId != sessionId ||
          width != frameWidth ||
          height != frameHeight ||
          !_guestFrameFresh) {
        return;
      }
      _guestFrameFresh = false;
      _guestFrameTimer = null;
      notifyListeners();
    });
    if (changed) notifyListeners();
  }

  void _invalidateGuestFrameFreshness({bool notify = true}) {
    _guestFrameTimer?.cancel();
    _guestFrameTimer = null;
    final changed = _guestFrameFresh;
    _guestFrameFresh = false;
    if (changed && notify && !_disposed) notifyListeners();
  }

  Future<void> refreshHost() {
    _hostStatusLoading = true;
    hostError = '';
    _hostStatusRequest = ++_sequence;
    _hostStatusStartedMonotonicMs = hostMonotonicNowMs();
    _hostStatusTimeout?.cancel();
    final requestId = _hostStatusRequest;
    _hostStatusTimeout = Timer(HostSystemSnapshot.freshFor, () {
      if (_disposed || _hostStatusRequest != requestId) return;
      _hostStatusLoading = false;
      _hostStatusRequest = 0;
      _hostStatusStartedMonotonicMs = -1;
      hostError = 'System status timed out. Refresh to try again.';
      notifyListeners();
    });
    notifyListeners();
    return _sendWithResult(
      {'action': 'host_status', 'request_id': requestId},
      stillValid: () => _inventoryCurrent && _hostStatusRequest == requestId,
    ).then((_) {});
  }

  Future<void> refreshHostWindows() {
    if (!hostConnectionCurrent ||
        hostWindowsCapability != CapabilityStatus.supported) {
      return Future.value();
    }
    _hostWindowsLoading = true;
    hostWindowsError = '';
    hostWindowsSnapshot = null;
    focusedHostWindow = null;
    final requestId = ++_sequence;
    _hostWindowsRequest = requestId;
    _hostWindowsTimeout?.cancel();
    _hostWindowsTimeout = Timer(const Duration(seconds: 15), () {
      if (_disposed || _hostWindowsRequest != requestId) return;
      _hostWindowsLoading = false;
      _hostWindowsRequest = 0;
      hostWindowsSnapshot = null;
      focusedHostWindow = null;
      hostWindowsError =
          'The PC did not return its window list. Refresh to try again.';
      notifyListeners();
    });
    notifyListeners();
    return _sendWithResult(
      {'action': 'windows_list', 'request_id': requestId},
      stillValid: () =>
          _inventoryCurrent &&
          _hostWindowsRequest == requestId &&
          hostWindowsCapability == CapabilityStatus.supported,
    ).then((sent) {
      if (_disposed || sent || _hostWindowsRequest != requestId) return;
      _hostWindowsTimeout?.cancel();
      _hostWindowsTimeout = null;
      _hostWindowsRequest = 0;
      _hostWindowsLoading = false;
      hostWindowsSnapshot = null;
      focusedHostWindow = null;
      hostWindowsError =
          'Couldn’t send the Windows list request. Reconnect and try again.';
      notifyListeners();
    });
  }

  Future<void> refreshPhoneWorkspace() {
    if (!hostConnectionCurrent ||
        phoneWorkspaceCapability != CapabilityStatus.supported ||
        _phoneWorkspaceLoading) {
      return Future.value();
    }
    _phoneWorkspaceLoading = true;
    phoneWorkspaceError = '';
    final requestId = ++_sequence;
    _phoneWorkspaceRequest = requestId;
    _phoneWorkspaceTimeout?.cancel();
    _phoneWorkspaceTimeout = Timer(const Duration(seconds: 15), () {
      if (_disposed || _phoneWorkspaceRequest != requestId) return;
      _phoneWorkspaceRequest = 0;
      _phoneWorkspaceLoading = false;
      phoneWorkspaceError =
          'The PC did not return Phone Workspace support. Refresh to try again.';
      notifyListeners();
    });
    notifyListeners();
    return _sendWithResult(
      {'action': 'phone_workspace_support', 'request_id': requestId},
      stillValid: () =>
          _inventoryCurrent &&
          _phoneWorkspaceRequest == requestId &&
          phoneWorkspaceCapability == CapabilityStatus.supported,
    ).then((sent) {
      if (_disposed || sent || _phoneWorkspaceRequest != requestId) return;
      _phoneWorkspaceTimeout?.cancel();
      _phoneWorkspaceTimeout = null;
      _phoneWorkspaceRequest = 0;
      _phoneWorkspaceLoading = false;
      phoneWorkspaceError =
          'Couldn’t send the Phone Workspace request. Reconnect and try again.';
      notifyListeners();
    });
  }

  Future<void> refreshGatewayStatus() {
    if (!hostConnectionCurrent ||
        gatewayStatusCapability != CapabilityStatus.supported ||
        _gatewayStatusLoading) {
      return Future.value();
    }
    _gatewayStatusLoading = true;
    _gatewayStatusEvidenceValid = false;
    gatewayError = '';
    final requestId = ++_sequence;
    _gatewayStatusRequest = requestId;
    _gatewayStatusStartedMonotonicMs = hostMonotonicNowMs();
    _gatewayStatusTimeout?.cancel();
    _gatewayStatusTimeout = Timer(const Duration(seconds: 25), () {
      if (_disposed || _gatewayStatusRequest != requestId) return;
      _gatewayStatusRequest = 0;
      _gatewayStatusStartedMonotonicMs = -1;
      _gatewayStatusLoading = false;
      _gatewayStatusEvidenceValid = false;
      gatewayError = 'Gateway status timed out. Recheck to try again.';
      if (_gatewayRestartExpectedIdentity != null && _gatewayNeedsReconcile) {
        _scheduleGatewayReconcileRefresh();
      }
      notifyListeners();
    });
    notifyListeners();
    return _sendWithResult(
      {'action': 'gateway_status', 'request_id': requestId},
      stillValid: () =>
          hostConnectionCurrent &&
          _gatewayStatusRequest == requestId &&
          gatewayStatusCapability == CapabilityStatus.supported,
    ).then((sent) {
      if (_disposed || sent || _gatewayStatusRequest != requestId) return;
      _gatewayStatusTimeout?.cancel();
      _gatewayStatusTimeout = null;
      _gatewayStatusRequest = 0;
      _gatewayStatusStartedMonotonicMs = -1;
      _gatewayStatusLoading = false;
      _gatewayStatusEvidenceValid = false;
      gatewayError =
          'Couldn’t send the Gateway status request. Reconnect and try again.';
      notifyListeners();
    });
  }

  Future<void> openGatewaySetup() => _sendGatewayOperation(
        action: 'gateway_setup_open',
        targetIdentity: 'gateway:setup',
        capability: 'host.gateway.setup.v1',
        allowed: (status) => status.setupControlAvailable,
      );

  Future<void> setGatewayImdbEnabled(bool enabled) => _sendGatewayOperation(
        action: 'gateway_imdb_set_enabled',
        targetIdentity: 'gateway:imdb',
        capability: 'host.gateway.imdb.v1',
        allowed: (status) => status.providerControlAvailable,
        payload: {'enabled': enabled},
      );

  Future<void> refreshGatewayImdb() => _sendGatewayOperation(
        action: 'gateway_imdb_refresh',
        targetIdentity: 'gateway:imdb',
        capability: 'host.gateway.imdb.v1',
        allowed: (status) =>
            status.providerControlAvailable && status.imdbEnabled == true,
      );

  Future<void> restartGateway({GatewayStatus? confirmedStatus}) {
    final status = confirmedStatus ?? gatewayStatus;
    if (status == null || status.processIdentity.isEmpty) {
      gatewayError = 'Recheck Gateway before restarting it.';
      gatewayMessage = '';
      notifyListeners();
      return Future.value();
    }
    return _sendGatewayOperation(
      action: 'gateway_restart',
      targetIdentity: 'gateway:restart:${status.processIdentity}',
      capability: 'host.gateway.restart.v1',
      allowed: (current) =>
          current.restartControlAvailable &&
          current.processIdentity == status.processIdentity &&
          current.activeSessions == status.activeSessions,
      payload: {
        'expected_process_identity': status.processIdentity,
        'active_sessions_known': status.activeSessions != null,
        'confirmed_active_sessions': status.activeSessions ?? 0,
      },
    );
  }

  Future<void> _sendGatewayOperation({
    required String action,
    required String targetIdentity,
    required String capability,
    required bool Function(GatewayStatus status) allowed,
    Map<String, dynamic> payload = const {},
  }) {
    if (_gatewayNeedsReconcile) {
      gatewayError =
          'Recheck Gateway before retrying the last request with an unknown result.';
      gatewayMessage = '';
      notifyListeners();
      return Future.value();
    }
    final status = gatewayStatus;
    if (_gatewayMutationLoading) return Future.value();
    if (status == null || !gatewayStatusFresh) {
      gatewayError = 'Recheck Gateway before making this change.';
      gatewayMessage = '';
      notifyListeners();
      return Future.value();
    }
    if (!allowed(status) || !_canMutateHost(capability)) {
      gatewayError =
          'This Gateway action is not available for the current remote session.';
      gatewayMessage = '';
      notifyListeners();
      return Future.value();
    }

    gatewayError = '';
    gatewayMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    if (action == 'gateway_restart') {
      _gatewayRestartExpectedIdentity = status.processIdentity;
      _gatewayRestartAcknowledged = false;
      _gatewayRestartRequireSiloVerified = status.siloState == 'verified';
      _gatewayRestartRequireProfileSelected =
          status.siloProfileSelected == true;
      _gatewayRestartRequireProfileVerified =
          status.siloProfileVerified == true;
      _gatewayRestartReconcileAttempts = 0;
    }
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: action,
    );
    _gatewayMutationLoading = true;
    notifyListeners();
    return _sendHostOperation(
      {
        'action': action,
        'request_id': requestId,
        ...payload,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: capability,
      stillValid: () {
        final current = gatewayStatus;
        return current != null && gatewayStatusFresh && allowed(current);
      },
    );
  }

  Future<void> beginPhoneWorkspace(PhoneWorkspaceProfile profile) {
    final support = phoneWorkspaceSupport;
    if (_phoneWorkspaceNeedsReconcile) {
      phoneWorkspaceError =
          'Refresh Phone Workspace before retrying the last unknown request.';
      notifyListeners();
      return Future.value();
    }
    if (_phoneWorkspaceLoading ||
        support == null ||
        !support.supported ||
        support.activeSession != null ||
        !_canMutateHost('host.phone_workspace.v1')) {
      return Future.value();
    }
    phoneWorkspaceError = '';
    phoneWorkspaceMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity =
        'phone-workspace:new:${profile.width}x${profile.height}:${profile.orientation}:${profile.dpi}';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'phone_workspace_begin',
    );
    _phoneWorkspaceLoading = true;
    notifyListeners();
    return _sendHostOperation(
      {
        'action': 'phone_workspace_begin',
        'request_id': requestId,
        'display_width': profile.width,
        'display_height': profile.height,
        'display_dpi': profile.dpi,
        'display_orientation': profile.orientation,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.phone_workspace.v1',
      stillValid: () => hostConnectionCurrent,
    );
  }

  Future<void> endPhoneWorkspace() {
    final session = phoneWorkspaceSupport?.activeSession;
    if (_phoneWorkspaceNeedsReconcile) {
      phoneWorkspaceError =
          'Refresh Phone Workspace before retrying the last unknown request.';
      notifyListeners();
      return Future.value();
    }
    if (session == null ||
        !session.isValid ||
        phoneWorkspaceSupport?.supported != true ||
        _phoneWorkspaceLoading ||
        !_canMutateHost('host.phone_workspace.v1')) {
      return Future.value();
    }
    phoneWorkspaceError = '';
    phoneWorkspaceMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity = 'phone-workspace:${session.id}';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'phone_workspace_end',
    );
    _phoneWorkspaceLoading = true;
    notifyListeners();
    return _sendHostOperation(
      {
        'action': 'phone_workspace_end',
        'request_id': requestId,
        'owned_display_id': session.id,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.phone_workspace.v1',
      stillValid: () =>
          hostConnectionCurrent &&
          phoneWorkspaceSupport?.activeSession?.id == session.id,
    );
  }

  Future<HostWindowInfo?> focusHostWindow(HostWindowInfo window) {
    final snapshot = hostWindowsSnapshot;
    if (snapshot == null ||
        snapshot.desktopGeneration <= 0 ||
        !window.isValid ||
        !window.canFocus ||
        !snapshot.contains(window.id) ||
        !_canMutateHost('host.window_focus.v1')) {
      return Future.value(null);
    }
    hostError = '';
    hostMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity = 'window:${window.id}:${snapshot.desktopGeneration}';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'window_focus',
    );
    final completion = Completer<HostWindowInfo?>();
    _hostWindowFocusCompletions[requestId] = completion;
    notifyListeners();
    _sendHostOperation(
      {
        'action': 'window_focus',
        'request_id': requestId,
        'window_id': window.id,
        'desktop_generation': snapshot.desktopGeneration,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.window_focus.v1',
      stillValid: () {
        final current = hostWindowsSnapshot;
        return current != null &&
            current.desktopGeneration == snapshot.desktopGeneration &&
            current.contains(window.id);
      },
    );
    return completion.future;
  }

  Future<void> endProcess(
    int pid, {
    int? startTimeSecs,
    int? creationTime100ns,
  }) {
    if (!_canMutateHost('host.process_end') ||
        hostProcessIdentityCapability != CapabilityStatus.supported) {
      return Future.value();
    }
    final snapshot = hostSnapshot;
    var processStartTime = startTimeSecs ?? 0;
    var processCreationTime = creationTime100ns ?? 0;
    if ((processStartTime <= 0 || processCreationTime <= 0) &&
        snapshot != null) {
      for (final process in snapshot.processes) {
        if (process.pid == pid) {
          if (processStartTime <= 0) {
            processStartTime = process.startTimeSecs;
          }
          if (processCreationTime <= 0) {
            processCreationTime = process.creationTime100ns;
          }
          break;
        }
      }
    }
    if (snapshot == null ||
        snapshot.schema < 3 ||
        !hostSnapshotFresh ||
        processStartTime <= 0 ||
        processCreationTime <= 0 ||
        !snapshot.containsProcessIdentity(
          pid,
          processStartTime,
          creationTime100ns: processCreationTime,
        )) {
      hostError = 'Refresh System before ending this process.';
      hostMessage = '';
      notifyListeners();
      return Future.value();
    }
    hostError = '';
    hostMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity = 'process:$pid:$processCreationTime';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'process_end',
    );
    notifyListeners();
    return _sendHostOperation(
      {
        'action': 'process_end',
        'request_id': requestId,
        'pid': pid,
        'process_start_time_secs': processStartTime,
        'process_creation_time_100ns': processCreationTime,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.process_end',
      stillValid: () {
        final current = hostSnapshot;
        return current != null &&
            hostSnapshotFresh &&
            current.schema >= 3 &&
            current.containsProcessIdentity(
              pid,
              processStartTime,
              creationTime100ns: processCreationTime,
            );
      },
    );
  }

  Future<void> recoverComponent(String component) {
    if (component != 'bluestacks_adb' ||
        !hostSnapshotFresh ||
        !_canMutateHost('host.recover.bluestacks_adb')) {
      return Future.value();
    }
    hostError = '';
    hostMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    final targetIdentity = 'component:$component';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'recover',
    );
    notifyListeners();
    return _sendHostOperation(
      {
        'action': 'recover',
        'request_id': requestId,
        'component': component,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.recover.bluestacks_adb',
      stillValid: () => hostSnapshotFresh,
    );
  }

  /// Restarts Windows Explorer (taskbar and desktop) on the PC as the signed-in user.
  Future<HostShellRestartResult> restartHostShell() {
    if (!_canMutateHost('host.shell_restart.v1')) {
      return Future.value(const HostShellRestartResult(
          false, 'This PC can’t restart its taskbar from the phone.'));
    }
    hostError = '';
    hostMessage = '';
    final requestId = ++_sequence;
    final operationId = const Uuid().v4();
    const targetIdentity = 'shell:explorer';
    _beginHostOperation(
      requestId: requestId,
      operationId: operationId,
      targetIdentity: targetIdentity,
      action: 'shell_restart',
    );
    final completion = Completer<HostShellRestartResult>();
    _shellRestartCompletions[requestId] = completion;
    notifyListeners();
    unawaited(_sendHostOperation(
      {
        'action': 'shell_restart',
        'request_id': requestId,
        'operation_id': operationId,
        'session_identity': _operationSessionIdentity,
        'target_identity': targetIdentity,
        'session_generation': _operationGeneration,
      },
      requestId: requestId,
      capability: 'host.shell_restart.v1',
      stillValid: () => true,
    ));
    return completion.future;
  }

  void _finishShellRestart(int requestId, bool ok, String message) {
    final completion = _shellRestartCompletions.remove(requestId);
    if (completion != null && !completion.isCompleted) {
      completion.complete(HostShellRestartResult(ok, message));
    }
  }

  void _abandonShellRestarts() {
    for (final completion in _shellRestartCompletions.values) {
      if (!completion.isCompleted) {
        completion.complete(const HostShellRestartResult(
            false, 'The connection changed before the PC answered.'));
      }
    }
    _shellRestartCompletions.clear();
  }

  bool _canMutateHost(String capability) =>
      _operationSessionIdentity.isNotEmpty &&
      _operationGeneration > 0 &&
      _capabilities.allows('operation.identity.v1') &&
      _capabilities.allows('operation.ack.v1') &&
      hostConnectionCurrent &&
      _capabilities.allows(capability);

  void _beginHostOperation({
    required int requestId,
    required String operationId,
    required String targetIdentity,
    required String action,
  }) {
    _hostOperations.begin(
      requestId: requestId,
      operationId: operationId,
      sessionIdentity: _operationSessionIdentity,
      targetIdentity: targetIdentity,
      action: action,
    );
    _pendingHostOperations.add(requestId);
    _hostOperationStartedMonotonicMs[requestId] = hostMonotonicNowMs();
    _hostOperationTimeouts[requestId]?.cancel();
    _hostOperationTimeouts[requestId] = Timer(_hostOperationTimeout, () {
      if (_disposed || !_hostOperations.markTimedOut(requestId)) return;
      _pendingHostOperations.remove(requestId);
      final shutdownTarget = _shutdownRequests.remove(requestId);
      if (shutdownTarget != null) _shutdownPending.remove(shutdownTarget);
      _hostOperationTimeouts.remove(requestId);
      _hostOperationStartedMonotonicMs.remove(requestId);
      _hostWindowFocusCompletions.remove(requestId)?.complete(null);
      _finishShellRestart(requestId, false, _shellRestartUnfinished);
      hostMessage =
          'The PC may have applied the request. Refresh before retrying.';
      _finishAvdAction(requestId, false, hostMessage);
      if (action.startsWith('phone_workspace_')) {
        _phoneWorkspaceLoading = false;
        _phoneWorkspaceNeedsReconcile = true;
        phoneWorkspaceMessage = '';
        phoneWorkspaceError =
            'The Phone Workspace result is unknown. Refresh before retrying.';
      }
      if (action.startsWith('gateway_')) {
        _gatewayMutationLoading = false;
        _gatewayNeedsReconcile = true;
        gatewayMessage = '';
        gatewayError =
            'The Gateway result is unknown. Recheck status before retrying.';
        if (action == 'gateway_restart') {
          _scheduleGatewayReconcileRefresh();
        }
      }
      notifyListeners();
    });
  }

  Future<void> _sendHostOperation(
    Map<String, dynamic> payload, {
    required int requestId,
    required String capability,
    required bool Function() stillValid,
  }) {
    payload['protocol_version'] = 1;
    final operation = _hostOperations.operationForRequest(requestId);
    if (operation == null) return Future.value();
    final next = _outbound.then((_) async {
      if (_disposed) return;
      final current = _operationSessionIdentity == operation.sessionIdentity &&
          _operationGeneration == operation.generation &&
          _pendingHostOperations.contains(requestId) &&
          _canMutateHost(capability) &&
          stillValid();
      if (!current) {
        final resolved = _hostOperations.resolve(
          requestId: requestId,
          operationId: operation.operationId,
          sessionIdentity: operation.sessionIdentity,
          targetIdentity: operation.targetIdentity,
          generation: operation.generation,
          accepted: false,
          applied: false,
          errorCode: 'scope_changed_before_dispatch',
          error: 'Remote state changed before the request was sent.',
        );
        if (resolved) {
          _hostOperationTimeouts.remove(requestId)?.cancel();
          _pendingHostOperations.remove(requestId);
          final shutdownTarget = _shutdownRequests.remove(requestId);
          if (shutdownTarget != null) _shutdownPending.remove(shutdownTarget);
          _hostOperationStartedMonotonicMs.remove(requestId);
          _hostWindowFocusCompletions.remove(requestId)?.complete(null);
          _finishShellRestart(requestId, false, _shellRestartUnfinished);
          hostMessage = '';
          hostError = operation.error;
          _finishAvdAction(requestId, false, operation.error);
          if (operation.action.startsWith('phone_workspace_')) {
            _phoneWorkspaceLoading = false;
            phoneWorkspaceMessage = '';
            phoneWorkspaceError = operation.error;
          }
          if (operation.action.startsWith('gateway_')) {
            _gatewayMutationLoading = false;
            gatewayMessage = '';
            gatewayError = operation.error;
            if (operation.action == 'gateway_restart') {
              _clearGatewayRestartExpectation();
              _gatewayNeedsReconcile = false;
            }
          }
          notifyListeners();
        }
        return;
      }
      await _sender('emulator-request', jsonEncode(payload));
    });
    _outbound = next.catchError((Object failure) {
      if (_disposed) return;
      if (_pendingHostOperations.contains(requestId)) {
        final resolved = _hostOperations.markUnknownOutcome(
          requestId,
          errorCode: 'transport_failure',
          error: failure.toString(),
        );
        if (resolved) {
          _hostOperationTimeouts.remove(requestId)?.cancel();
          _pendingHostOperations.remove(requestId);
          _hostOperationStartedMonotonicMs.remove(requestId);
          _hostWindowFocusCompletions.remove(requestId)?.complete(null);
          _finishShellRestart(requestId, false, _shellRestartUnfinished);
          hostMessage = '';
          hostError = failure.toString();
          _finishAvdAction(requestId, false, hostError);
          if (operation.action.startsWith('phone_workspace_')) {
            _phoneWorkspaceLoading = false;
            _phoneWorkspaceNeedsReconcile = true;
            phoneWorkspaceMessage = '';
            phoneWorkspaceError = failure.toString();
          }
          if (operation.action.startsWith('gateway_')) {
            _gatewayMutationLoading = false;
            _gatewayNeedsReconcile = true;
            gatewayMessage = '';
            gatewayError =
                'The Gateway request may have reached the PC. Recheck status before retrying.';
          }
        }
      }
      _inventoryCurrent = false;
      _clearShutdownState();
      error = failure.toString();
      notifyListeners();
    });
    return _outbound;
  }

  void handleResponse(Map<String, dynamic> response) {
    if (_disposed || response['protocol_version'] != 1) return;
    final id = response['request_id'];
    if (response['type'] == 'host' && (id is! int || id <= 0)) return;
    if (response['type'] == 'host' && id == _hostStatusRequest) {
      final requestStartedMonotonicMs = _hostStatusStartedMonotonicMs;
      _hostStatusTimeout?.cancel();
      _hostStatusTimeout = null;
      _hostStatusRequest = 0;
      _hostStatusLoading = false;
      _hostStatusStartedMonotonicMs = -1;
      final host = response['host'];
      if (host is! Map) {
        hostError = 'The PC returned an invalid system response.';
      } else if (host['ok'] != true) {
        hostError =
            host['error']?.toString() ?? 'Host management request failed';
      } else if (host['snapshot'] is Map) {
        hostSnapshot = HostSystemSnapshot.fromMap(host['snapshot'] as Map,
            receivedMonotonicMs: hostMonotonicNowMs(),
            requestStartedMonotonicMs: requestStartedMonotonicMs);
        hostMessage = host['message']?.toString() ?? '';
        hostError = '';
      }
    } else if (response['type'] == 'host' && id == _hostWindowsRequest) {
      _hostWindowsTimeout?.cancel();
      _hostWindowsTimeout = null;
      _hostWindowsRequest = 0;
      _hostWindowsLoading = false;
      final host = response['host'];
      if (host is! Map) {
        hostWindowsSnapshot = null;
        focusedHostWindow = null;
        hostWindowsError = 'The PC returned an invalid window list.';
      } else if (host['ok'] != true) {
        hostWindowsSnapshot = null;
        focusedHostWindow = null;
        hostWindowsError =
            host['error']?.toString() ?? 'Window list request failed';
      } else {
        final snapshot = HostWindowSnapshot.fromHostMap(host);
        if (snapshot.desktopGeneration <= 0) {
          hostWindowsError = 'The PC returned an invalid desktop generation.';
        } else {
          hostWindowsSnapshot = snapshot;
          if (focusedHostWindow != null &&
              !snapshot.contains(focusedHostWindow!.id)) {
            focusedHostWindow = null;
          }
          hostWindowsError = '';
        }
      }
    } else if (response['type'] == 'host' && id == _phoneWorkspaceRequest) {
      _phoneWorkspaceTimeout?.cancel();
      _phoneWorkspaceTimeout = null;
      _phoneWorkspaceRequest = 0;
      _phoneWorkspaceLoading = false;
      final host = response['host'];
      if (host is! Map) {
        phoneWorkspaceSupport = null;
        phoneWorkspaceError =
            'The PC returned an invalid Phone Workspace response.';
      } else if (host['ok'] != true || host['phone_workspace'] is! Map) {
        phoneWorkspaceError =
            host['error']?.toString() ?? 'Phone Workspace request failed';
      } else {
        phoneWorkspaceSupport =
            PhoneWorkspaceSupport.fromMap(host['phone_workspace'] as Map);
        _phoneWorkspaceNeedsReconcile = false;
        phoneWorkspaceMessage = host['message']?.toString() ?? '';
        phoneWorkspaceError = '';
      }
    } else if (response['type'] == 'host' && id == _gatewayStatusRequest) {
      final requestStartedMonotonicMs = _gatewayStatusStartedMonotonicMs;
      _gatewayStatusTimeout?.cancel();
      _gatewayStatusTimeout = null;
      _gatewayStatusRequest = 0;
      _gatewayStatusStartedMonotonicMs = -1;
      _gatewayStatusLoading = false;
      final host = response['host'];
      if (host is! Map) {
        _gatewayStatusEvidenceValid = false;
        gatewayError = 'The PC returned an invalid Gateway response.';
        if (_gatewayRestartExpectedIdentity != null && _gatewayNeedsReconcile) {
          _scheduleGatewayReconcileRefresh();
        }
      } else if (host['ok'] != true || host['gateway'] is! Map) {
        _gatewayStatusEvidenceValid = false;
        gatewayError = host['error']?.toString() ?? 'Gateway status failed.';
        if (_gatewayRestartExpectedIdentity != null && _gatewayNeedsReconcile) {
          _scheduleGatewayReconcileRefresh();
        }
      } else {
        final gateway = host['gateway'] as Map;
        final schema = gateway['schema'];
        if (schema is! int) {
          _gatewayStatusEvidenceValid = false;
          gatewayError = 'The PC returned an invalid Gateway status payload.';
          if (_gatewayRestartExpectedIdentity != null &&
              _gatewayNeedsReconcile) {
            _scheduleGatewayReconcileRefresh();
          }
          notifyListeners();
          return;
        }
        if (schema != 1) {
          _gatewayStatusEvidenceValid = false;
          gatewayError =
              'The PC returned an unsupported Gateway status schema.';
          if (_gatewayRestartExpectedIdentity != null &&
              _gatewayNeedsReconcile) {
            _scheduleGatewayReconcileRefresh();
          }
          notifyListeners();
          return;
        }
        final measured = GatewayStatus.tryFromMap(
          gateway,
          receivedMonotonicMs: hostMonotonicNowMs(),
          requestStartedMonotonicMs: requestStartedMonotonicMs,
        );
        if (measured == null) {
          _gatewayStatusEvidenceValid = false;
          gatewayError = 'The PC returned an invalid Gateway status payload.';
          if (_gatewayRestartExpectedIdentity != null &&
              _gatewayNeedsReconcile) {
            _scheduleGatewayReconcileRefresh();
          }
          notifyListeners();
          return;
        }
        gatewayStatus = measured;
        _gatewayStatusEvidenceValid = true;
        final expectedRestartIdentity = _gatewayRestartExpectedIdentity;
        if (expectedRestartIdentity != null) {
          final processRestarted = measured.running &&
              measured.restartControlAvailable &&
              measured.processIdentity.isNotEmpty &&
              measured.processIdentity != expectedRestartIdentity;
          final runtimeReady = measured.identityReady == true;
          final siloReady = !_gatewayRestartRequireSiloVerified ||
              measured.siloState == 'verified';
          final profileSelected = !_gatewayRestartRequireProfileSelected ||
              measured.siloProfileSelected == true;
          final profileVerified = !_gatewayRestartRequireProfileVerified ||
              measured.siloProfileVerified == true;
          if (processRestarted &&
              runtimeReady &&
              siloReady &&
              profileSelected &&
              profileVerified) {
            _clearGatewayRestartExpectation();
            _gatewayNeedsReconcile = false;
            _gatewayReconcileTimer?.cancel();
            _gatewayReconcileTimer = null;
            gatewayMessage = 'Gateway restarted and is ready.';
          } else {
            _gatewayNeedsReconcile = true;
            gatewayMessage = processRestarted
                ? 'Gateway restarted; waiting for runtime and Silo readiness.'
                : _gatewayRestartAcknowledged
                    ? 'Restart accepted; waiting for the verified Gateway process to come back.'
                    : 'Restart result is being reconciled; waiting for a new verified Gateway process.';
            _scheduleGatewayReconcileRefresh();
          }
        } else {
          _gatewayNeedsReconcile = false;
        }
        gatewayError = '';
      }
    } else if (response['type'] == 'host' && _avdSettingsReads.containsKey(id)) {
      final host = response['host'];
      if (host is Map && host['ok'] == true && host['avd_settings'] is Map) {
        _finishAvdSettingsRead(id as int,
            AvdSettingsInfo.fromMap(host['avd_settings'] as Map), '');
      } else {
        _finishAvdSettingsRead(
            id as int,
            null,
            (host is Map ? host['error']?.toString() : null) ??
                'Host management request failed');
      }
    } else if (response['type'] == 'host' && id is int) {
      final operation = _hostOperations.operationForRequest(id);
      final host = response['host'];
      if (operation == null || host is! Map) return;
      final generation = (host['session_generation'] as num?)?.toInt() ?? 0;
      final resolved =
          host['session_identity']?.toString() == _operationSessionIdentity &&
              generation == _operationGeneration &&
              _hostOperations.resolve(
                requestId: id,
                operationId: host['operation_id']?.toString() ?? '',
                sessionIdentity: host['session_identity']?.toString() ?? '',
                targetIdentity: host['target_identity']?.toString() ?? '',
                generation: generation,
                accepted: host['accepted'] == true,
                applied: host['ok'] == true && host['state'] == 'applied',
                errorCode: host['error_code']?.toString() ?? '',
                error: host['error']?.toString() ?? '',
                observedState: host['snapshot'],
              );
      if (!resolved) return;
      final gatewayOutcomeUnknown = operation.action.startsWith('gateway_') &&
          host['ok'] != true &&
          host['accepted'] == true &&
          host['outcome_unknown'] != false;
      if (gatewayOutcomeUnknown) {
        _hostOperations.markUnknownOutcome(
          id,
          errorCode: host['error_code']?.toString() ?? 'gateway_result_unknown',
          error: host['error']?.toString() ?? 'Gateway result is unknown.',
        );
      }
      _hostOperationTimeouts.remove(id)?.cancel();
      final shutdownTarget = _shutdownRequests.remove(id);
      if (shutdownTarget != null) {
        if (host['ok'] != true) _shutdownPending.remove(shutdownTarget);
        if (hostConnectionCurrent) unawaited(refresh());
      }
      if (operation.action == 'emulator_reboot') {
        if (host['ok'] == true) {
          _watchReboot(operation.targetIdentity.replaceFirst('emulator:', ''));
        }
        if (hostConnectionCurrent) unawaited(refresh(keepGuestError: true));
      } else if (operation.action.startsWith('avd_') && hostConnectionCurrent) {
        unawaited(refresh());
      }
      _pendingHostOperations.remove(id);
      final requestStartedMonotonicMs =
          _hostOperationStartedMonotonicMs.remove(id) ?? -1;
      if (host['snapshot'] is Map) {
        hostSnapshot = HostSystemSnapshot.fromMap(host['snapshot'] as Map,
            receivedMonotonicMs: hostMonotonicNowMs(),
            requestStartedMonotonicMs: requestStartedMonotonicMs);
      }
      if (operation.action.startsWith('phone_workspace_')) {
        _phoneWorkspaceLoading = false;
        _phoneWorkspaceNeedsReconcile = false;
        if (host['phone_workspace'] is Map) {
          phoneWorkspaceSupport =
              PhoneWorkspaceSupport.fromMap(host['phone_workspace'] as Map);
        }
      }
      if (operation.action.startsWith('gateway_')) {
        _gatewayMutationLoading = false;
      }
      if (host['ok'] == true) {
        HostWindowInfo? observedWindow;
        if (operation.action == 'window_focus' && host['window_focus'] is Map) {
          final observed = HostWindowInfo.fromMap(host['window_focus'] as Map);
          final observedGeneration =
              (host['desktop_generation'] as num?)?.toInt() ?? 0;
          final expectedTarget = 'window:${observed.id}:$observedGeneration';
          if (observed.isValid &&
              observedGeneration > 0 &&
              expectedTarget == operation.targetIdentity) {
            focusedHostWindow = observed;
            observedWindow = observed;
          } else {
            hostError = 'The PC returned a mismatched window focus result.';
          }
        }
        _hostWindowFocusCompletions.remove(id)?.complete(observedWindow);
        hostMessage = host['message']?.toString() ?? '';
        _finishShellRestart(id, true, hostMessage);
        _finishAvdAction(id, true, hostMessage);
        if (operation.action.startsWith('phone_workspace_')) {
          phoneWorkspaceMessage = host['message']?.toString() ?? '';
          phoneWorkspaceError = '';
        }
        if (operation.action.startsWith('gateway_')) {
          gatewayMessage = host['message']?.toString() ?? '';
          gatewayError = '';
          if (operation.action == 'gateway_restart') {
            _gatewayNeedsReconcile = true;
            _gatewayRestartAcknowledged = true;
            _scheduleGatewayReconcileRefresh();
          } else {
            _gatewayNeedsReconcile = false;
            Timer.run(() {
              if (_disposed || !hostConnectionCurrent) return;
              unawaited(refreshGatewayStatus());
            });
          }
        }
        if (operation.action != 'window_focus' || observedWindow != null) {
          hostError = '';
        }
      } else {
        _hostWindowFocusCompletions.remove(id)?.complete(null);
        hostError =
            host['error']?.toString() ?? 'Host management request failed';
        _finishShellRestart(id, false, hostError);
        _finishAvdAction(id, false, hostError);
        if (operation.action.startsWith('phone_workspace_')) {
          phoneWorkspaceMessage = '';
          phoneWorkspaceError =
              host['error']?.toString() ?? 'Phone Workspace request failed';
        }
        if (operation.action.startsWith('gateway_')) {
          gatewayMessage = '';
          if (gatewayOutcomeUnknown) {
            gatewayError =
                'The Gateway may have applied this request. Recheck status before retrying.';
            _gatewayNeedsReconcile = true;
            if (operation.action == 'gateway_restart') {
              _scheduleGatewayReconcileRefresh();
            } else {
              Timer.run(() {
                if (_disposed || !hostConnectionCurrent) return;
                unawaited(refreshGatewayStatus());
              });
            }
          } else {
            gatewayError = host['error']?.toString() ??
                'Gateway management request failed';
            _gatewayNeedsReconcile = false;
            if (operation.action == 'gateway_restart') {
              _clearGatewayRestartExpectation();
            }
          }
        }
      }
    } else if (response['type'] == 'inventory' && id == _inventoryRequest) {
      _capabilities = RemoteCapabilitySet.fromWire(response['capabilities']);
      final operationIdentity =
          response['operation_session_identity']?.toString() ?? '';
      final operationGeneration =
          (response['operation_generation'] as num?)?.toInt() ?? 0;
      final preserveGatewayRestartReconcile =
          _gatewayRestartExpectedIdentity != null;
      if (operationIdentity != _operationSessionIdentity ||
          operationGeneration != _operationGeneration) {
        _hostStatusTimeout?.cancel();
        _hostStatusTimeout = null;
        _hostStatusRequest = 0;
        _hostStatusStartedMonotonicMs = -1;
        _hostStatusLoading = false;
        hostSnapshot = null;
        _hostWindowsTimeout?.cancel();
        _hostWindowsTimeout = null;
        _hostWindowsRequest = 0;
        _hostWindowsLoading = false;
        hostWindowsSnapshot = null;
        focusedHostWindow = null;
        hostWindowsError = '';
        _phoneWorkspaceTimeout?.cancel();
        _phoneWorkspaceTimeout = null;
        _phoneWorkspaceRequest = 0;
        _phoneWorkspaceLoading = false;
        _phoneWorkspaceNeedsReconcile = false;
        phoneWorkspaceSupport = null;
        phoneWorkspaceError = '';
        phoneWorkspaceMessage = '';
        _gatewayStatusTimeout?.cancel();
        _gatewayStatusTimeout = null;
        _gatewayStatusRequest = 0;
        _gatewayStatusStartedMonotonicMs = -1;
        _gatewayStatusLoading = false;
        _gatewayStatusEvidenceValid = false;
        gatewayStatus = null;
        gatewayError = '';
        gatewayMessage = '';
        _gatewayMutationLoading = false;
        _gatewayNeedsReconcile = preserveGatewayRestartReconcile;
        if (!preserveGatewayRestartReconcile) {
          _clearGatewayRestartExpectation();
        }
        hostMessage = '';
        _hostOperations.moveToGeneration(operationGeneration > 0
            ? operationGeneration
            : _operationGeneration + 1);
        for (final timer in _hostOperationTimeouts.values) {
          timer.cancel();
        }
        _hostOperationTimeouts.clear();
        _hostOperationStartedMonotonicMs.clear();
        _pendingHostOperations.clear();
        for (final completion in _hostWindowFocusCompletions.values) {
          if (!completion.isCompleted) completion.complete(null);
        }
        _hostWindowFocusCompletions.clear();
        _abandonShellRestarts();
        _abandonAvdActions();
        _clearShutdownState();
      }
      _operationSessionIdentity = operationIdentity;
      _operationGeneration = operationGeneration;
      _inventoryCurrent = true;
      if (preserveGatewayRestartReconcile &&
          gatewayStatusCapability == CapabilityStatus.supported) {
        _scheduleGatewayReconcileRefresh();
      }
      dashboardSupported = response['dashboard'] == true;
      _inventoryTimeout?.cancel();
      instances = (response['instances'] as List? ?? [])
          .whereType<Map>()
          .map((item) => RemoteEmulator(
              id: item['target_id']?.toString() ?? '',
              name: item['name']?.toString() ?? '',
              provider: item['provider']?.toString() ?? '',
              state: item['state']?.toString() ?? '',
              androidVersion: item['android_version']?.toString() ?? '',
              defaultPackage: item['default_package']?.toString() ?? '',
              error: item['last_error']?.toString() ?? '',
              progressPercent: (item['progress_percent'] as num?)?.toInt() ?? 0,
              windowVisible: item['window_visible'] == true))
          .toList();
      _trackReboots();
      listRequestedAt = _inventoryRequestedAt;
      loading = false;
      final providerErrors =
          (response['provider_errors'] as List? ?? []).join('\n');
      if (id != _guestErrorKeptFor || providerErrors.isNotEmpty) {
        error = providerErrors;
      }
      listError = providerErrors;
      if (!_capabilities.allows('host.emulator_shutdown.v1')) _clearShutdownState();
      _shutdownPending.removeWhere((id) => !instances.any((item) => item.id == id) ||
          instances.any((item) => item.id == id && ['stopped', 'stopping', 'shutdown_failed'].contains(item.state)));

    } else if (response['type'] == 'previews' && id == _previewRequest) {
      dashboardActive = response['enabled'] == true;
      _previewAcknowledgedRequest = id is int ? id : 0;
      final sessions = response['session_ids'] as List? ?? [];
      previews.removeWhere((_, preview) =>
          !dashboardActive || !sessions.contains(preview.sessionId));
    } else if (response['type'] == 'status' && response['preview'] == true) {
      final target = response['target_id']?.toString() ?? '';
      if (!dashboardActive || !_previewTargets.contains(target)) return;
      final session = response['session_id'] as int? ?? 0;
      final state = response['state']?.toString() ?? '';
      if (state == 'starting') {
        if (session == 0) return;
      } else if (previews[target]?.sessionId != session) {
        return;
      }
      previews[target] = RemotePreview(
          target,
          session,
          state,
          response['width'] as int? ?? 0,
          response['height'] as int? ?? 0,
          response['error']?.toString() ?? '');
    } else if (response['type'] == 'status') {
      if (response['state'] == 'desktop' && id == _desktopRequest) {
        if (dashboardActive) {
          _desktopTimeout?.cancel();
          _selectionTimeout?.cancel();
          selected = streaming = connecting = false;
          _invalidateGuestFrameFreshness(notify: false);
          guestSessionId = width = height = 0;
          targetId = error = '';
          startupPhase = '';
          notifyListeners();
          return;
        }
        reset();
        return;
      }
      if (id != _selectionRequest && response['session_id'] != guestSessionId) {
        return;
      }
      final state = response['state'];
      if (state == 'starting') {
        _invalidateGuestFrameFreshness(notify: false);
        guestSessionId = response['session_id'] as int? ?? 0;
        targetId = response['target_id']?.toString() ?? '';
        selected = guestSessionId != 0;
        streaming = false;
        width = height = 0;
        final phase = response['phase']?.toString() ?? '';
        if (phase.isNotEmpty) startupPhase = phase;
      } else if (state == 'streaming' &&
          response['session_id'] == guestSessionId) {
        final w = response['width'] as int? ?? 0;
        final h = response['height'] as int? ?? 0;
        if (w < 1 || h < 1 || w > 1280 || h > 1280) return;
        final streamChanged = !streaming || width != w || height != h;
        if (streamChanged) _invalidateGuestFrameFreshness(notify: false);
        width = w;
        height = h;
        streaming = true;
        connecting = false;
        error = '';
        guestFailures.remove(targetId);
        startupPhase = response['phase']?.toString().isNotEmpty == true
            ? response['phase'].toString()
            : 'stream_ready';
        _selectionTimeout?.cancel();
      } else if (state == 'failed' &&
          response['session_id'] == guestSessionId) {
        _invalidateGuestFrameFreshness(notify: false);
        error = response['error']?.toString() ?? 'Guest connection failed';
        if (targetId.isNotEmpty) guestFailures[targetId] = error;
        streaming = false;
        connecting = false;
        startupPhase = 'failed';
        _selectionTimeout?.cancel();
      } else {
        return;
      }
    } else if (response['type'] == 'error' &&
        id is int &&
        id > 0 &&
        [
          _inventoryRequest,
          _selectionRequest,
          _desktopRequest,
          _previewRequest,
          _hostStatusRequest,
          _hostWindowsRequest,
          _phoneWorkspaceRequest,
          _gatewayStatusRequest,
          ..._pendingHostOperations,
          ..._avdSettingsReads.keys,
        ].contains(id)) {
      final requestError =
          response['error']?.toString() ?? 'Remote request failed';
      if (id == _hostStatusRequest) {
        _hostStatusTimeout?.cancel();
        _hostStatusTimeout = null;
        _hostStatusRequest = 0;
        _hostStatusLoading = false;
        _hostStatusStartedMonotonicMs = -1;
        hostError = requestError;
      } else if (id == _hostWindowsRequest) {
        _hostWindowsTimeout?.cancel();
        _hostWindowsTimeout = null;
        _hostWindowsRequest = 0;
        _hostWindowsLoading = false;
        hostWindowsSnapshot = null;
        focusedHostWindow = null;
        hostWindowsError = requestError;
      } else if (id == _phoneWorkspaceRequest) {
        _phoneWorkspaceTimeout?.cancel();
        _phoneWorkspaceTimeout = null;
        _phoneWorkspaceRequest = 0;
        _phoneWorkspaceLoading = false;
        phoneWorkspaceError = requestError;
      } else if (id == _gatewayStatusRequest) {
        _gatewayStatusTimeout?.cancel();
        _gatewayStatusTimeout = null;
        _gatewayStatusRequest = 0;
        _gatewayStatusStartedMonotonicMs = -1;
        _gatewayStatusLoading = false;
        _gatewayStatusEvidenceValid = false;
        gatewayError = requestError;
        if (_gatewayRestartExpectedIdentity != null && _gatewayNeedsReconcile) {
          _scheduleGatewayReconcileRefresh();
        }
      } else if (_avdSettingsReads.containsKey(id)) {
        _finishAvdSettingsRead(id, null, requestError);
      } else if (_pendingHostOperations.contains(id)) {
        final operation = _hostOperations.operationForRequest(id);
        if (operation != null) {
          _hostOperations.resolve(
            requestId: id,
            operationId: operation.operationId,
            sessionIdentity: operation.sessionIdentity,
            targetIdentity: operation.targetIdentity,
            generation: operation.generation,
            accepted: false,
            applied: false,
            errorCode: 'request_rejected',
            error: requestError,
          );
        }
        _hostOperationTimeouts.remove(id)?.cancel();
        _pendingHostOperations.remove(id);
        _hostOperationStartedMonotonicMs.remove(id);
        _hostWindowFocusCompletions.remove(id)?.complete(null);
        _finishShellRestart(id, false, _shellRestartUnfinished);
        hostError = requestError;
        _finishAvdAction(id, false, requestError);
        if (operation?.action.startsWith('gateway_') == true) {
          _gatewayMutationLoading = false;
          gatewayMessage = '';
          gatewayError = requestError;
          _gatewayNeedsReconcile = false;
          if (operation?.action == 'gateway_restart') {
            _clearGatewayRestartExpectation();
          }
        }
      } else {
        error = requestError;
      }
      if (id == _inventoryRequest) {
        loading = false;
        _inventoryCurrent = false;
        _clearShutdownState();
        _inventoryTimeout?.cancel();
      }
      if (id == _selectionRequest) {
        connecting = false;
        _selectionTimeout?.cancel();
        if (targetId.isNotEmpty) guestFailures[targetId] = requestError;
      }
    } else {
      return;
    }
    notifyListeners();
  }

  void _scheduleGatewayReconcileRefresh() {
    _gatewayReconcileTimer?.cancel();
    _gatewayReconcileTimer = Timer(const Duration(seconds: 2), () {
      _gatewayReconcileTimer = null;
      if (_disposed || !hostConnectionCurrent || !_gatewayNeedsReconcile) {
        return;
      }
      if (_gatewayRestartExpectedIdentity != null &&
          _gatewayRestartReconcileAttempts >=
              _gatewayRestartMaxReconcileAttempts) {
        gatewayMessage = '';
        gatewayError =
            'Gateway restart is taking longer than expected. Recheck Gateway to verify the result.';
        notifyListeners();
        return;
      }
      if (_gatewayRestartExpectedIdentity != null) {
        _gatewayRestartReconcileAttempts++;
      }
      unawaited(refreshGatewayStatus());
    });
  }

  void _clearGatewayRestartExpectation() {
    _gatewayRestartExpectedIdentity = null;
    _gatewayRestartAcknowledged = false;
    _gatewayRestartRequireSiloVerified = false;
    _gatewayRestartRequireProfileSelected = false;
    _gatewayRestartRequireProfileVerified = false;
    _gatewayRestartReconcileAttempts = 0;
  }

  void invalidateConnection() {
    if (_disposed) return;
    final preserveGatewayRestartReconcile =
        _gatewayRestartExpectedIdentity != null;
    _selectionTimeout?.cancel();
    _inventoryTimeout?.cancel();
    _desktopTimeout?.cancel();
    _hostStatusTimeout?.cancel();
    _hostStatusTimeout = null;
    _hostWindowsTimeout?.cancel();
    _hostWindowsTimeout = null;
    _phoneWorkspaceTimeout?.cancel();
    _phoneWorkspaceTimeout = null;
    _gatewayStatusTimeout?.cancel();
    _gatewayStatusTimeout = null;
    _gatewayReconcileTimer?.cancel();
    _gatewayReconcileTimer = null;
    _invalidateGuestFrameFreshness(notify: false);
    for (final timer in _hostOperationTimeouts.values) {
      timer.cancel();
    }
    _hostOperationTimeouts.clear();
    _hostOperationStartedMonotonicMs.clear();
    _pendingHostOperations.clear();
    for (final completion in _hostWindowFocusCompletions.values) {
      if (!completion.isCompleted) completion.complete(null);
    }
    _hostWindowFocusCompletions.clear();
    _abandonShellRestarts();
    _abandonAvdActions();
    _hostOperations.advanceGeneration();
    _operationGeneration = _hostOperations.generation;
    _operationSessionIdentity = '';
    _capabilities = RemoteCapabilitySet.fromWire(null);
    _inventoryCurrent = false;
    _clearShutdownState();
    _hostStatusLoading = false;
    _hostWindowsLoading = false;
    _phoneWorkspaceLoading = false;
    _gatewayStatusLoading = false;
    _gatewayMutationLoading = false;
    _gatewayStatusEvidenceValid = false;
    _phoneWorkspaceNeedsReconcile = false;
    _gatewayNeedsReconcile = preserveGatewayRestartReconcile;
    if (!preserveGatewayRestartReconcile) {
      _clearGatewayRestartExpectation();
    }
    _hostStatusStartedMonotonicMs = -1;
    _gatewayStatusStartedMonotonicMs = -1;
    loading = false;
    connecting = false;
    selected = false;
    streaming = false;
    guestSessionId = 0;
    width = height = 0;
    startupPhase = '';
    dashboardActive = false;
    _previewAcknowledgedRequest = 0;
    previews.clear();
    guestFailures.clear();
    _previewTargets.clear();
    _selectionRequest =
        _desktopRequest = _inventoryRequest = _hostStatusRequest = 0;
    _hostWindowsRequest = 0;
    _gatewayStatusRequest = 0;
    _previewRequest = 0;
    hostMessage = '';
    hostWindowsSnapshot = null;
    focusedHostWindow = null;
    hostWindowsError = '';
    gatewayStatus = null;
    gatewayError = preserveGatewayRestartReconcile
        ? 'Connection lost while the Gateway restart result is unknown. Reconnecting will recheck it.'
        : '';
    gatewayMessage = '';
    notifyListeners();
  }

  void reset() {
    _selectionTimeout?.cancel();
    _inventoryTimeout?.cancel();
    _desktopTimeout?.cancel();
    _hostStatusTimeout?.cancel();
    _hostStatusTimeout = null;
    _hostWindowsTimeout?.cancel();
    _hostWindowsTimeout = null;
    _gatewayStatusTimeout?.cancel();
    _gatewayStatusTimeout = null;
    _gatewayReconcileTimer?.cancel();
    _gatewayReconcileTimer = null;
    _invalidateGuestFrameFreshness(notify: false);
    selected = streaming = connecting = loading = false;
    guestSessionId = width = height = 0;
    targetId = error = '';
    startupPhase = '';
    dashboardActive = false;
    _hostStatusLoading = false;
    _hostWindowsLoading = false;
    _gatewayStatusLoading = false;
    _gatewayMutationLoading = false;
    _gatewayStatusEvidenceValid = false;
    _hostStatusStartedMonotonicMs = -1;
    _gatewayStatusStartedMonotonicMs = -1;
    _inventoryCurrent = false;
    _clearShutdownState();
    hostSnapshot = null;
    hostWindowsSnapshot = null;
    focusedHostWindow = null;
    phoneWorkspaceSupport = null;
    gatewayStatus = null;
    _phoneWorkspaceNeedsReconcile = false;
    _gatewayNeedsReconcile = false;
    _clearGatewayRestartExpectation();
    hostError = hostMessage = '';
    hostWindowsError = '';
    phoneWorkspaceError = phoneWorkspaceMessage = '';
    gatewayError = gatewayMessage = '';
    _capabilities = RemoteCapabilitySet.fromWire(null);
    _operationSessionIdentity = '';
    _hostOperations.moveToGeneration(_operationGeneration + 1);
    _operationGeneration = 0;
    for (final timer in _hostOperationTimeouts.values) {
      timer.cancel();
    }
    _hostOperationTimeouts.clear();
    _hostOperationStartedMonotonicMs.clear();
    _pendingHostOperations.clear();
    for (final completion in _hostWindowFocusCompletions.values) {
      if (!completion.isCompleted) completion.complete(null);
    }
    _hostWindowFocusCompletions.clear();
    _abandonShellRestarts();
    _abandonAvdActions();
    previews.clear();
    guestFailures.clear();
    _previewTargets.clear();
    _selectionRequest =
        _desktopRequest = _inventoryRequest = _hostStatusRequest = 0;
    _hostWindowsRequest = 0;
    _gatewayStatusRequest = 0;
    _phoneWorkspaceRequest = 0;
    _previewRequest = _previewAcknowledgedRequest = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _clearShutdownState();
    _selectionTimeout?.cancel();
    _inventoryTimeout?.cancel();
    _desktopTimeout?.cancel();
    _hostStatusTimeout?.cancel();
    _hostWindowsTimeout?.cancel();
    _phoneWorkspaceTimeout?.cancel();
    _gatewayStatusTimeout?.cancel();
    _gatewayReconcileTimer?.cancel();
    _guestFrameTimer?.cancel();
    _guestFrameTimer = null;
    for (final timer in _hostOperationTimeouts.values) {
      timer.cancel();
    }
    _hostOperationTimeouts.clear();
    _hostOperationStartedMonotonicMs.clear();
    for (final completion in _hostWindowFocusCompletions.values) {
      if (!completion.isCompleted) completion.complete(null);
    }
    _hostWindowFocusCompletions.clear();
    _abandonShellRestarts();
    _abandonAvdActions();
    super.dispose();
  }
}

class RemotePreview {
  const RemotePreview(this.targetId, this.sessionId, this.state, this.width,
      this.height, this.error);
  final String targetId;
  final int sessionId;
  final String state;
  final int width;
  final int height;
  final String error;
  int get channel => 0x40000000 | (sessionId & 0x3fffffff);
}

const _shellRestartUnfinished =
    'The taskbar restart didn’t finish. Check the PC’s screen.';

class HostShellRestartResult {
  const HostShellRestartResult(this.ok, this.message);
  final bool ok;
  final String message;
}

/// The PC's answer to a managed-emulator action, or why there is none.
class AvdActionResult {
  const AvdActionResult(this.ok, this.message);
  final bool ok;
  final String message;
}

/// Memory, CPU cores and screen of a managed emulator; a null value is left
/// as it is.
class AvdSettings {
  const AvdSettings({this.ramMb, this.cores, this.screen});
  final int? ramMb;
  final int? cores;
  final (int, int)? screen;

  /// What the PC accepts; the same lists as the host's.
  static const ramChoicesMb = [2048, 3072, 4096, 6144, 8192];
  static const coreChoices = [2, 4, 6, 8];
  static const screenChoices = [(1080, 2208), (1080, 2400)];

  bool get isEmpty => ramMb == null && cores == null && screen == null;

  factory AvdSettings.fromMap(Object? map) {
    if (map is! Map) return const AvdSettings();
    int? number(String key) {
      final value = map[key];
      return value is num && value > 0 ? value.toInt() : null;
    }

    final width = number('screen_width');
    final height = number('screen_height');
    return AvdSettings(
        ramMb: number('ram_mb'),
        cores: number('cpu_cores'),
        screen: width != null && height != null ? (width, height) : null);
  }

  /// These settings with [newer]'s values where it has one.
  AvdSettings merged(AvdSettings newer) => AvdSettings(
      ramMb: newer.ramMb ?? ramMb,
      cores: newer.cores ?? cores,
      screen: newer.screen ?? screen);

  /// The values that differ from [other].
  AvdSettings changedFrom(AvdSettings other) => AvdSettings(
      ramMb: ramMb == other.ramMb ? null : ramMb,
      cores: cores == other.cores ? null : cores,
      screen: screen == other.screen ? null : screen);
}

/// A managed emulator's settings as the PC reports them.
class AvdSettingsInfo {
  const AvdSettingsInfo(
      {required this.current, required this.pending, required this.running});

  /// What its configuration has now.
  final AvdSettings current;

  /// Saved on the phone, applied at its next start.
  final AvdSettings pending;
  final bool running;

  /// What it has from its next start.
  AvdSettings get next => current.merged(pending);

  factory AvdSettingsInfo.fromMap(Map map) => AvdSettingsInfo(
      current: AvdSettings.fromMap(map['current']),
      pending: AvdSettings.fromMap(map['pending']),
      running: map['running'] == true);
}

typedef AvdSettingsLoad = ({AvdSettingsInfo? info, String error});
