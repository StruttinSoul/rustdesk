import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import '../../common.dart' show translate;
import '../../consts.dart' show kPeerPlatformLinux, kPeerPlatformWindows;
import '../../common/widgets/dialog.dart' show clientClose;
import '../../models/platform_model.dart' show bind;
import '../../models/emulator_labels.dart';
import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/remote_operation_state.dart';
import 'emulator_page.dart';
import 'file_manager_page.dart';
import 'host_management_page.dart';
import 'settings_page.dart';
import 'terminal_page.dart';
import '../widgets/mirpg_remote_theme.dart';
import '../../common/widgets/aperture_brand.dart';
import '../widgets/avd_manage_sheets.dart';
import '../widgets/clipboard_transfer_sheet.dart';
import '../widgets/computers_hero.dart' show hostDisplayName;
import '../widgets/emulator_action_sheet.dart';
export '../widgets/emulator_action_sheet.dart' show AvdCardActions;
import '../widgets/emulator_tile.dart';
import '../widgets/monitor_control_view.dart';
import '../widgets/monitor_key_sender.dart';
import '../widgets/monitor_session_continuity.dart';
import '../widgets/play_rail.dart';
import '../widgets/pc_tab.dart';
import '../widgets/reconnecting_banner.dart';
import '../widgets/play_tab.dart';
import '../widgets/privacy_controls_sheet.dart';
import '../widgets/screens_tab.dart';
export '../widgets/screens_tab.dart' show TargetPreviewCard, TargetSwitcherGrid;
import '../widgets/session_quality_panel.dart';
import '../widgets/trust_phone_sheet.dart';
import '../widgets/window_picker_sheet.dart';
import '../../models/session_reconnect.dart';

/// The dashboard's pages. `devices` is the Play tab (emulators); the bottom
/// bar reads Screens, Play, PC.
enum ConnectedPcSection {
  devices,
  screens,
  pc,
  system,
  files,
  powershell,
}

/// The dashboard opens on Screens.
const ConnectedPcSection kConnectedPcInitialSection = ConnectedPcSection.screens;

/// Position of [section] in the bottom bar: Screens, Play, PC. System, Files
/// and PowerShell are sub-pages of PC.
int connectedPcNavigationIndex(ConnectedPcSection section) => switch (section) {
      ConnectedPcSection.screens => 0,
      ConnectedPcSection.devices => 1,
      _ => 2,
    };

/// The section a bottom-bar [index] selects, or null when out of range.
ConnectedPcSection? connectedPcSectionForIndex(int index) => switch (index) {
      0 => ConnectedPcSection.screens,
      1 => ConnectedPcSection.devices,
      2 => ConnectedPcSection.pc,
      _ => null,
    };

/// Where Android Back goes from [section]: sub-pages to PC, Play and PC to
/// Screens, and null on Screens itself (the root).
ConnectedPcSection? connectedPcBackTarget(ConnectedPcSection section) =>
    switch (section) {
      ConnectedPcSection.screens => null,
      ConnectedPcSection.system ||
      ConnectedPcSection.files ||
      ConnectedPcSection.powershell =>
        ConnectedPcSection.pc,
      _ => ConnectedPcSection.screens,
    };

class TargetDashboardPage extends StatefulWidget {
  const TargetDashboardPage({
    super.key,
    required this.ffi,
  });
  final FFI ffi;

  @override
  State<TargetDashboardPage> createState() => _TargetDashboardPageState();
}

class _TargetDashboardPageState extends State<TargetDashboardPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _playScroll = ScrollController();
  final _chooserScroll = ScrollController();
  final _monitorFocus = FocusNode();

  /// Height of one Play grid row (tile + spacing) from the last layout.
  double _playRowExtent = 0;

  /// Stopped emulators the phone asked to start, until the PC's list shows
  /// them as no longer stopped (or 120 s pass), so their tile reads Starting.
  final Map<String, DateTime> _startRequested = {};

  /// When this phone last saw each emulator live (a fresh frame of the game).
  /// The list is not refreshed during a game, so this keeps an emulator
  /// started from the phone running until a newer list says otherwise.
  final Map<String, DateTime> _seenLive = {};

  /// New emulators the PC is creating (id -> name shown), until it lists them.
  final Map<String, String> _settingUp = {};

  /// Whether the first emulator list after opening the dashboard has ended.
  bool _listSeen = false;
  Timer? _scrollDebounce;
  Timer? _refreshTimer;
  Timer? _healthTimer;
  _Target? _fullscreen;

  /// A copy of the opened emulator's last preview frame, shown dimmed until
  /// its stream is live. Preview images are disposed when no longer retained,
  /// so this page owns its copy.
  ui.Image? _switchFrame;

  /// A chip switch has been accepted but has not reached the PC yet (so
  /// `model.connecting` is still false); further switches are ignored.
  bool _switchPending = false;
  bool _chooser = false;
  bool _background = false;

  /// Reconnects the session on its own after an unexpected drop, then reopens
  /// the emulator or monitor that was open.
  late final SessionReconnectController _sessionReconnect;
  bool _viewFocused = true;
  bool _monitorDown = false;
  bool _monitorRightDown = false;
  bool _monitorLocalViewOnly = false;
  final MonitorInputEpoch _monitorInputEpoch = MonitorInputEpoch();
  final MonitorSessionLiveness _monitorLiveness = MonitorSessionLiveness();
  int _monitorLivenessGeneration = 0;
  int? _monitorLivenessDisplay;
  DateTime _monitorLivenessStartedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _monitorRequiresStreamHeartbeat = false;
  bool _monitorInputWasLive = false;
  late final MonitorKeySender _monitorKeys = MonitorKeySender((name,
          {required down,
          required press,
          required alt,
          required ctrl,
          required shift,
          required command}) =>
      bind.sessionInputKey(
          sessionId: widget.ffi.sessionId,
          name: name,
          down: down,
          press: press,
          alt: alt,
          ctrl: ctrl,
          shift: shift,
          command: command));
  final Map<int, String> _monitorDrafts = <int, String>{};
  final Map<int, MonitorControlPreferences> _monitorPreferences =
      <int, MonitorControlPreferences>{};
  Future<void> _monitorEvents = Future.value();
  _MonitorMoveSlot? _openMonitorMove;
  _MonitorWheelSlot? _openMonitorWheel;
  HostWindowInfo? _focusedWindow;
  int _windowFocusRevision = 0;
  bool? _landscape;
  String _subscription = '';
  /// Distance between the tops of the Screens cards (card plus spacing), from
  /// the last layout, for choosing which monitors get a preview.
  List<double> _screensExtents = const [];

  /// Size of the view switcher's grid from its last layout.
  Size _chooserSize = Size.zero;
  ConnectedPcSection _section = kConnectedPcInitialSection;
  bool _filesOpened = false;
  bool _systemOpened = false;
  bool _powershellOpened = false;
  MirpgQualityProfile _qualityProfile = MirpgQualityProfile.auto;
  String? _effectiveImageQuality;
  String _qualityError = '';
  bool _qualityApplying = false;
  bool _hasStoredQualityPreference = false;
  int _peerInfoGeneration = 0;
  int _reconnectGeneration = 0;
  EmulatorModel get model => widget.ffi.emulatorModel;
  late final EmulatorLabelStore _labels = EmulatorLabelStore(
    peerId: widget.ffi.id,
    read: (k) => bind.getLocalFlutterOption(k: k),
    write: (k, v) => bind.setLocalFlutterOption(k: k, v: v),
  );

  void _labelsChanged() {
    if (mounted) setState(() {});
  }

  /// The name a confirmation dialog shows: "Label (emulator name)" when a
  /// phone-side label is set, so the person sees both what they named it and
  /// what the PC calls it.
  String _confirmationName(_Target target) {
    final label = _labels.labelFor(target.id);
    return label.isEmpty ? target.name : '$label (${target.name})';
  }

  String get _qualityPreferenceKey => 'mirpg-quality-profile:${widget.ffi.id}';

  String _monitorPreferenceKey(int display) =>
      'mirpg-monitor-controls:${widget.ffi.id}:monitor:$display';

  MonitorControlPreferences _preferencesForMonitor(int display) {
    return _monitorPreferences.putIfAbsent(display, () {
      final raw = bind.getLocalFlutterOption(k: _monitorPreferenceKey(display));
      if (raw.isEmpty) return const MonitorControlPreferences();
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return MonitorControlPreferences.fromJson(
              Map<String, dynamic>.from(decoded));
        }
      } catch (_) {
        // Ignore corrupt or stale local preferences and fall back safely.
      }
      return const MonitorControlPreferences();
    });
  }

  void _saveMonitorPreferences(
      int display, MonitorControlPreferences preferences) {
    final previous = _preferencesForMonitor(display);
    _monitorPreferences[display] = preferences;
    unawaited(bind.setLocalFlutterOption(
        k: _monitorPreferenceKey(display),
        v: jsonEncode(preferences.toJson())));
    if (mounted) setState(() {});
    if (previous.orientation != preferences.orientation &&
        _fullscreen?.display == display) {
      unawaited(_releaseMonitorInput());
      _landscape = null;
      _presentation();
    }
  }

  List<_Target> get targets => [
        for (var i = 0; i < widget.ffi.ffiModel.pi.displays.length; i++)
          _Target.monitor(i),
        for (final instance in model.instances)
          if (isDashboardGuestProvider(instance.provider))
            _Target.guest(instance),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sessionReconnect = SessionReconnectController(
      attempt: widget.ffi.ffiModel.reconnectQuietly,
      onRestored: _restoreAfterReconnect,
      onGiveUp: (event) => widget.ffi.ffiModel
          .handleMsgBox(event, widget.ffi.sessionId, widget.ffi.id),
      isForeground: () => !_background,
    );
    widget.ffi.ffiModel.sessionReconnect = _sessionReconnect;
    model.addListener(_changed);
    _labels.addListener(_labelsChanged);
    widget.ffi.ffiModel.addListener(_changed);
    widget.ffi.qualityMonitorModel.addListener(_qualityChanged);
    _peerInfoGeneration = widget.ffi.ffiModel.peerInfoGeneration;
    _reconnectGeneration = widget.ffi.ffiModel.reconnectGeneration;
    _scroll.addListener(_scrolled);
    _playScroll.addListener(_scrolled);
    _chooserScroll.addListener(_scrolled);
    widget.ffi.aperturePairResult.addListener(_pairResultChanged);
    unawaited(_refreshPairingState());
    unawaited(model.refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      // Inventory discovery stalls older hosts' video dispatch while it runs.
      // Fullscreen control does not need the list; refresh when browsing targets.
      if (!_background &&
          (_fullscreen == null || _chooser) &&
          !model.loading &&
          !model.connecting) {
        unawaited(model.refresh());
      }
    });
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _background || _fullscreen?.display == null) return;
      _refreshMonitorInputLiveness();
      setState(() {});
    });
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribe();
      unawaited(_loadQualityProfile());
    });
  }

  /// 'paired' | 'can-pair' | 'unavailable' (or empty until loaded).
  String _pairingState = '';

  Future<void> _refreshPairingState() async {
    try {
      final state = await bind.sessionGetCommon(
          sessionId: widget.ffi.sessionId,
          key: 'aperture-pairing-state',
          param: '');
      if (!mounted) return;
      setState(() => _pairingState = state ?? '');
      if (state == 'paired') _setPairedFlag('Y');
      if (state == 'can-pair') _setPairedFlag('N');
    } catch (_) {
      if (mounted) setState(() => _pairingState = 'unavailable');
      return;
    }
    unawaited(_maybeOfferPairing());
  }

  void _setPairedFlag(String value) => unawaited(bind.setLocalFlutterOption(
      k: pairedFlagKey(widget.ffi.id), v: value));

  /// Offers "Trust this phone" once per PC, never over a game or the monitor;
  /// a prompt deferred meanwhile appears when the dashboard is shown again.
  bool _offeringPairing = false;

  Future<void> _maybeOfferPairing() async {
    if (!mounted || _fullscreen != null || _offeringPairing) return;
    final promptedKey = pairPromptedKey(widget.ffi.id);
    if (!shouldOfferPairing(
        pairingState: _pairingState,
        promptedFlag: bind.getLocalFlutterOption(k: promptedKey))) {
      return;
    }
    _offeringPairing = true;
    try {
      // Recorded before the sheet opens so it is one-time even if the app dies.
      await bind.setLocalFlutterOption(k: promptedKey, v: 'Y');
      // A game or monitor may have opened during the write.
      if (!mounted || _fullscreen != null) return;
      final trust = await showTrustPhoneSheet(context, hostName: _hostName);
      if (trust == true) await _trustThisPhone();
    } catch (_) {
      // Runs unawaited: report instead of reaching the zone's uncaught handler.
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(translate('Pairing failed'))));
      }
    } finally {
      _offeringPairing = false;
    }
  }

  Future<String> _defaultPhoneName() async {
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final model = info.model.trim();
      if (model.isNotEmpty) return model;
    } catch (_) {}
    return 'Phone';
  }

  Future<void> _trustThisPhone() async {
    final name = await _defaultPhoneName();
    await bind.sessionSetCommon(
        sessionId: widget.ffi.sessionId,
        key: 'aperture-pair-device',
        value: name);
  }

  Future<void> _forgetPairing() async {
    await bind.sessionSetCommon(
        sessionId: widget.ffi.sessionId,
        key: 'aperture-forget-pairing',
        value: '');
    _setPairedFlag('N');
    await _refreshPairingState();
  }

  void _pairResultChanged() {
    final evt = widget.ffi.aperturePairResult.value;
    if (evt == null || !mounted) return;
    final okRaw = evt['ok'];
    final ok = okRaw == true || okRaw.toString().toLowerCase() == 'true';
    final error = (evt['error'] ?? '').toString();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(ok
            ? translate('This phone connects without a password at home')
            : (error.isEmpty ? translate('Pairing failed') : error)),
      ));
    if (ok) _setPairedFlag('Y');
    unawaited(_refreshPairingState());
  }

  void _qualityChanged() {
    if (!mounted) return;
    _refreshMonitorInputLiveness();
    setState(() {});
  }

  void _resetMonitorLivenessForCurrentTarget() {
    final display = _fullscreen?.display;
    _monitorLivenessGeneration++;
    _monitorLivenessDisplay = display;
    _monitorLivenessStartedAt = DateTime.now();
    _monitorInputWasLive = false;
    _monitorInputEpoch.invalidate();
    if (display == null) return;
    _monitorRequiresStreamHeartbeat =
        model.desktopStreamLivenessCapability == CapabilityStatus.supported;
    _monitorLiveness.begin(
      generation: _monitorLivenessGeneration,
      targetIdentity: 'monitor:$display',
      requireStreamHeartbeat: _monitorRequiresStreamHeartbeat,
    );
  }

  void _syncMonitorLiveness(int index) {
    final requireStreamHeartbeat =
        model.desktopStreamLivenessCapability == CapabilityStatus.supported;
    if (_monitorLivenessDisplay != index ||
        _monitorRequiresStreamHeartbeat != requireStreamHeartbeat) {
      _resetMonitorLivenessForCurrentTarget();
    }
    if (_monitorLivenessDisplay != index) return;

    final generation = _monitorLivenessGeneration;
    final target = 'monitor:$index';
    final quality = widget.ffi.qualityMonitorModel.data;
    final transportAt = quality.transportHeartbeatUpdatedAt;
    if (transportAt != null &&
        !transportAt.isBefore(_monitorLivenessStartedAt)) {
      _monitorLiveness.noteTransportHeartbeat(
        generation: generation,
        at: transportAt,
      );
    }
    final streamAt = quality.streamHeartbeatUpdatedAt[index];
    if (streamAt != null && !streamAt.isBefore(_monitorLivenessStartedAt)) {
      _monitorLiveness.noteStreamHeartbeat(
        generation: generation,
        targetIdentity: target,
        at: streamAt,
      );
    }
    final decoderAt = quality.decoderUpdatedAt[index];
    final decoderHealthy = quality.decoderHealthy[index];
    if (decoderAt != null &&
        decoderHealthy != null &&
        !decoderAt.isBefore(_monitorLivenessStartedAt)) {
      _monitorLiveness.noteDecoderHealth(
        generation: generation,
        targetIdentity: target,
        healthy: decoderHealthy,
        at: decoderAt,
      );
    }
    final frameAt = widget.ffi.imageModel.dashboardImageUpdatedAt(index);
    if (_monitorPreviewFrameIsCurrent(index) &&
        frameAt != null &&
        !frameAt.isBefore(_monitorLivenessStartedAt)) {
      _monitorLiveness.noteFrame(
        generation: generation,
        targetIdentity: target,
        at: frameAt,
      );
    }
  }

  void _refreshMonitorInputLiveness() {
    final display = _fullscreen?.display;
    if (display == null) {
      _monitorInputWasLive = false;
      return;
    }
    final live = _canControlMonitor(display);
    if (_monitorInputWasLive && !live) {
      unawaited(_releaseMonitorInput());
    }
    _monitorInputWasLive = live;
  }

  Future<void> _loadQualityProfile() async {
    final stored = bind.getLocalFlutterOption(k: _qualityPreferenceKey);
    _hasStoredQualityPreference = stored.isNotEmpty;
    String? effective;
    try {
      effective =
          await bind.sessionGetImageQuality(sessionId: widget.ffi.sessionId);
    } catch (_) {
      // A connecting session can report the effective value on the next open.
    }
    if (!mounted) return;
    final preferred = stored.isNotEmpty
        ? mirpgQualityProfileFromStored(stored)
        : mirpgQualityProfileFromEffective(effective);
    setState(() {
      _qualityProfile = preferred;
      _effectiveImageQuality = effective;
    });
    if (stored.isNotEmpty && effective != mirpgQualityProfileValue(preferred)) {
      await _applyQualityProfile(preferred, persist: false);
    }
  }

  Future<void> _applyQualityProfile(MirpgQualityProfile profile,
      {bool persist = true}) async {
    if (persist) {
      _hasStoredQualityPreference = true;
      unawaited(bind.setLocalFlutterOption(
          k: _qualityPreferenceKey, v: profile.name));
    }
    if (mounted) {
      setState(() {
        _qualityProfile = profile;
        _qualityApplying = true;
        _qualityError = '';
      });
    }
    String? effective;
    String error = '';
    try {
      await bind.sessionSetImageQuality(
          sessionId: widget.ffi.sessionId,
          value: mirpgQualityProfileValue(profile));
      effective =
          await bind.sessionGetImageQuality(sessionId: widget.ffi.sessionId);
      if (mounted) {
        await model.setMonitorPreviewMode(
            _background || !_viewFocused || _chooser || _fullscreen?.display == null,
            force: true);
      }
    } catch (e) {
      error = 'Could not apply this quality profile: $e';
    }
    if (!mounted) return;
    setState(() {
      _effectiveImageQuality = effective ?? _effectiveImageQuality;
      _qualityApplying = false;
      _qualityError = error;
    });
  }

  Future<void> _showQualityConnection() async {
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, sheetSetState) => AnimatedBuilder(
          animation: widget.ffi.qualityMonitorModel,
          builder: (_, __) => SessionQualityConnectionSheet(
            preferredProfile: _qualityProfile,
            effectiveQuality: _effectiveImageQuality,
            applying: _qualityApplying,
            direct: widget.ffi.ffiModel.direct,
            data: widget.ffi.qualityMonitorModel.data,
            now: DateTime.now(),
            error: _qualityError,
            onProfileChanged: (profile) async {
              sheetSetState(() {});
              await _applyQualityProfile(profile);
              if (sheetContext.mounted) sheetSetState(() {});
            },
          ),
        ),
      ),
    );
  }

  void _changed() {
    if (!mounted) return;
    if (!model.loading) _listSeen = true;
    final now = DateTime.now();
    pruneStartRequests(_startRequested, model.instances, now);
    // Only a fresh frame of the open game counts. Previews never go to an
    // emulator the list calls stopped, and a stale preview state must not
    // keep one "running" past the next list.
    if (model.streaming && model.guestFrameFresh && model.targetId.isNotEmpty) {
      noteSeenLive(_seenLive, model.targetId, now);
    }
    _settingUp
        .removeWhere((id, _) => model.instances.any((item) => item.id == id));
    if (!widget.ffi.ffiModel.keyboard || widget.ffi.ffiModel.viewOnly) {
      unawaited(_releaseMonitorInput());
    }
    final reconnectGeneration = widget.ffi.ffiModel.reconnectGeneration;
    if (reconnectGeneration != _reconnectGeneration) {
      _reconnectGeneration = reconnectGeneration;
      model.invalidatePreviewAcknowledgement();
      if (_fullscreen?.display != null) {
        unawaited(_releaseMonitorInput());
        _resetMonitorLivenessForCurrentTarget();
        _subscription = '';
      }
    }
    final peerInfoGeneration = widget.ffi.ffiModel.peerInfoGeneration;
    if (peerInfoGeneration != _peerInfoGeneration) {
      _peerInfoGeneration = peerInfoGeneration;
      unawaited(_refreshPairingState());
      model.invalidatePreviewAcknowledgement();
      if (_hasStoredQualityPreference) {
        unawaited(_applyQualityProfile(_qualityProfile, persist: false));
      }
      if (_fullscreen?.display != null) {
        unawaited(_releaseMonitorInput());
        _resetMonitorLivenessForCurrentTarget();
        _subscription = '';
      }
    }
    if (_fullscreen != null &&
        !targets.any((target) => target.id == _fullscreen!.id)) {
      unawaited(_dashboard());
      return;
    }
    if (_switchFrame != null &&
        model.streaming &&
        !model.connecting &&
        model.targetId == _fullscreen?.id) {
      // Cleared in the same rebuild, so the page never shows a disposed image.
      _switchFrame!.dispose();
      _switchFrame = null;
    }
    _presentation();
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _scrolled() {
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 100), _subscribe);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
    _sessionReconnect.onForegroundChanged(!_background);
    if (_background) unawaited(_releaseMonitorInput());
    _subscription = '';
    _subscribe();
  }

  @override
  void didChangeViewFocus(ui.ViewFocusEvent event) {
    if (!mounted || View.of(context).viewId != event.viewId) return;
    final focused = event.state == ui.ViewFocusState.focused;
    if (_viewFocused == focused) return;
    _viewFocused = focused;
    if (!focused) unawaited(_releaseMonitorInput());
    _subscribe();
    setState(() {});
  }

  void _subscribe() {
    if (!mounted) return;
    model.framePacer.focused = !_background && _viewFocused;
    unawaited(model.setMonitorPreviewMode(
        _background || !_viewFocused || _chooser || _fullscreen?.display == null));
    final all = targets;
    final guestIds = <String>[];
    final displays = <int>[];
    final active = _fullscreen;
    final previewsEnabled = !_background &&
        (active != null ||
            _chooser ||
            _section == ConnectedPcSection.devices ||
            _section == ConnectedPcSection.screens);
    if (!_background && active?.display != null) displays.add(active!.display!);
    if (!_background && previewsEnabled && (active == null || _chooser)) {
      if (_chooser) {
        // The view switcher: the first four monitors or running emulators
        // from the grid's first visible card. Stopped instances consume no
        // stream, so they must not take up preview slots.
        final first = switcherGridFirstVisibleIndex(
            _chooserSize, _chooserScroll.hasClients ? _chooserScroll.offset : 0);
        for (final target in all.skip(first)) {
          if (guestIds.length + displays.length >= 4) break;
          if (target.display != null) {
            if (!displays.contains(target.display)) {
              displays.add(target.display!);
            }
          } else if (target.id != active?.id &&
              target.instance!.state != 'stopped' &&
              !model.isEmulatorShuttingDown(target.id)) {
            guestIds.add(target.id);
          }
        }
      } else if (_section == ConnectedPcSection.devices) {
        // Play: all four slots go to running emulators nearest the top of
        // the viewport; no monitor preview on this tab.
        guestIds.addAll(playTabPreviewIds(
          [
            for (final target in all)
              if (target.instance != null) target.instance!,
          ],
          firstVisibleIndex: playTabFirstVisibleIndex(
              _playScroll.hasClients ? _playScroll.offset : 0, _playRowExtent),
          shuttingDown: model.isEmulatorShuttingDown,
          activeId: active?.id,
        ));
      } else if (_section == ConnectedPcSection.screens) {
        // Screens shows monitors only; emulators never take a slot here.
        displays.addAll(screensPreviewDisplays(
          monitorCount: widget.ffi.ffiModel.pi.displays.length,
          firstVisibleIndex: screensTabFirstVisibleIndex(
              _screensExtents, _scroll.hasClients ? _scroll.offset : 0),
        ));
      }
    }
    final signature = '${guestIds.join(',')}|${displays.join(',')}';
    if (_subscription == signature &&
        model.dashboardActive == previewsEnabled) {
      return;
    }
    _subscription = signature;
    unawaited(model.setPreviews(guestIds, displays, enabled: previewsEnabled));
    _retainImages(displays);
  }

  void _retainImages(List<int> displays) {
    widget.ffi.imageModel.retainDashboardImages({
      ...displays,
      if (_fullscreen?.display != null) _fullscreen!.display!,
      for (final preview in model.previews.values) preview.channel,
      if (model.selected && model.guestSessionId != 0) model.videoChannel,
    });
  }

  Future<void> _open(
    _Target target, {
    bool launchDefaultApp = false,
    HostWindowInfo? focusedWindow,
  }) async {
    if (model.connecting) return;
    final instance = target.instance;
    if (instance != null) {
      noteStartRequest(_startRequested, instance, DateTime.now());
    }
    await _releaseMonitorInput();
    final frame = instance == null ? null : _guestFrame(target).image;
    setState(() {
      _fullscreen = target;
      _focusedWindow = focusedWindow;
      if (focusedWindow != null) _windowFocusRevision++;
      _switchFrame?.dispose();
      _switchFrame = frame?.clone();
    });
    _resetMonitorLivenessForCurrentTarget();
    _subscription = '';
    _subscribe();
    if (target.display != null) {
      await model.desktop();
    } else {
      await model.connect(target.id, launchDefaultApp: launchDefaultApp);
    }
    _presentation();
  }

  Future<void> _shutdownEmulator(_Target target) async {
    if (!await showEmulatorShutdownConfirmation(context, _confirmationName(target)) || !mounted) return;
    if (_fullscreen?.id == target.id) await _dashboard();
    await model.shutdownEmulator(target.id);
    if (mounted && model.hostError.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(model.hostError)));
    }
  }

  String _avdRawName(String id) => id.replaceFirst('avd:', '');

  bool _avdNameTaken(String name, {String? except}) {
    final lower = name.toLowerCase();
    return model.instances.any((item) =>
        item.provider == 'avd' &&
        item.id != except &&
        _avdRawName(item.id).toLowerCase() == lower);
  }

  /// Shows the PC's refusal or failure as is; on success a short [success]
  /// confirmation (already translated) replaces whatever snackbar is showing.
  void _reportAvdResult(AvdActionResult result, {required String success}) {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    if (!result.ok) {
      if (result.message.isNotEmpty) {
        messenger.showSnackBar(SnackBar(content: Text(result.message)));
      }
      return;
    }
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(success), duration: const Duration(seconds: 2)));
  }

  /// The label when set, else the emulator name, for confirmations.
  String _shownName(String id, String name) => _labels.displayName(id, name);

  Future<void> _newAvd() async {
    final created = await showAvdCreateSheet(context,
        title: 'New emulator',
        initialName: model.suggestAvdName('Emulator'),
        note: 'Android 15 · 4 GB · 4 cores · about 12 GB on D after setup',
        isTaken: _avdNameTaken);
    if (created == null || !mounted) return;
    final shown = created.label.isEmpty ? created.name : created.label;
    final id = 'avd:${created.name}';
    setState(() => _settingUp[id] = shown);
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
          content: Text(translate('Setting up {$shown} on the PC')),
          duration: const Duration(seconds: 2)));
    final result = await model.createAvd(created.name);
    if (!result.ok && mounted) setState(() => _settingUp.remove(id));
    if (result.ok) await _labels.setLabel(id, created.label);
    _reportAvdResult(result, success: translate('Created {$shown}'));
  }

  Future<void> _cloneAvd(_Target target) async {
    final raw = _avdRawName(target.id);
    final created = await showAvdCreateSheet(context,
        title: 'Clone ${target.name}',
        initialName: model.suggestAvdName('${raw}_copy'),
        note: 'Exact copy, including Google and game sign-ins. The game will see it as the same device.',
        isTaken: _avdNameTaken,
        confirmLabel: 'Clone');
    if (created == null || !mounted) return;
    final shown = created.label.isEmpty ? created.name : created.label;
    final result = await model.cloneAvd(target.id, created.name);
    if (result.ok) await _labels.setLabel('avd:${created.name}', created.label);
    _reportAvdResult(result, success: translate('Copied to {$shown}'));
  }

  Future<void> _renameAvd(_Target target) async {
    final raw = _avdRawName(target.id);
    final name = await showAvdNameSheet(context,
        title: 'Rename ${target.name}',
        initialName: raw,
        note: 'Only the name changes. The emulator keeps everything in it.',
        isTaken: (candidate) => _avdNameTaken(candidate, except: target.id),
        confirmLabel: 'Rename',
        tr: translate);
    if (name == null || name == raw || !mounted) return;
    final result = await model.renameAvd(target.id, name);
    final newId = 'avd:$name';
    if (result.ok) await _labels.moveLabel(target.id, newId);
    // The label moved with it, so name what the PC now calls it.
    _reportAvdResult(result, success: translate('Renamed to {$name}'));
  }

  Future<void> _deleteAvd(_Target target) async {
    final shown = _shownName(target.id, target.name);
    if (!await confirmAvdDelete(context, _confirmationName(target)) || !mounted) {
      return;
    }
    final result = await model.deleteAvd(target.id);
    if (result.ok) await _labels.clearLabel(target.id);
    _reportAvdResult(result, success: translate('Deleted {$shown}'));
  }

  Future<void> _toggleAvdWindow(_Target target) async {
    final show = !(target.instance?.windowVisible ?? false);
    _reportAvdResult(await model.setAvdWindowVisible(target.id, show),
        success: translate(show ? 'Shown on the PC' : 'Hidden on the PC'));
  }

  bool get _canControl =>
      widget.ffi.ffiModel.keyboard && !widget.ffi.ffiModel.viewOnly;

  String get _hostName {
    final name = widget.ffi.ffiModel.pi.hostname;
    return name.isEmpty ? 'Your PC' : name;
  }

  _Target? _targetById(String id) {
    for (final target in targets) {
      if (target.id == id) return target;
    }
    return null;
  }

  /// The guest's latest preview image and whether it is current (acknowledged
  /// preview request, under 8 s old), as the dashboard cards decide it.
  ({ui.Image? image, RemotePreview? preview, bool frameCurrent}) _guestFrame(
      _Target target) {
    final preview = model.previews[target.id];
    final activeGuest = _fullscreen?.id == target.id &&
        model.targetId == target.id &&
        model.streaming;
    final channel = activeGuest ? model.videoChannel : preview?.channel;
    final image =
        channel == null ? null : widget.ffi.imageModel.dashboardImage(channel);
    final updatedAt = channel == null
        ? null
        : widget.ffi.imageModel.dashboardImageUpdatedAt(channel);
    final frameAge =
        updatedAt == null ? null : DateTime.now().difference(updatedAt);
    final frameCurrent = image != null &&
        frameAge != null &&
        !frameAge.isNegative &&
        frameAge < const Duration(seconds: 8) &&
        (activeGuest
            ? model.guestFrameFresh
            : preview?.state == 'streaming' &&
                model.previewsAcknowledged &&
                widget.ffi.imageModel.dashboardImagePreviewRequest(channel!) ==
                    model.previewRequest);
    return (image: image, preview: preview, frameCurrent: frameCurrent);
  }

  EmulatorUiState _guestState(
          _Target target, RemotePreview? preview, bool frameCurrent) =>
      emulatorUiState(target.instance!,
          preview: preview,
          flags: EmulatorUiFlags(
            frameCurrent: frameCurrent,
            shuttingDown: model.isEmulatorShuttingDown(target.id),
            startRequested: startRequestPending(
                _startRequested, target.id, DateTime.now()),
            seenLive:
                seenLiveSinceList(_seenLive, target.id, model.listRequestedAt),
            guestFailure: model.guestFailures[target.id] ?? '',
          ));

  /// Opening [id] needs no startup checklist: the PC lists it ready, or this
  /// phone has played it since that list. A start request alone does not
  /// count; that emulator is still booting and the checklist shows it.
  bool _alreadyRunning(String id) {
    final instance = _targetById(id)?.instance;
    return instance != null &&
        (instance.readyForReconnect ||
            (_runningAsKnown(instance) &&
                seenLiveSinceList(_seenLive, id, model.listRequestedAt)));
  }

  /// [emulatorRunningAsKnown] with this page's start requests and sightings.
  bool _runningAsKnown(RemoteEmulator instance) => emulatorRunningAsKnown(
        instance,
        startRequests: _startRequested,
        seenLive: _seenLive,
        listRequestedAt: model.listRequestedAt,
        now: DateTime.now(),
      );

  EmulatorTileData _guestTile(_Target target) {
    final instance = target.instance!;
    final frame = _guestFrame(target);
    final label = _labels.labelFor(target.id);
    return EmulatorTileData(
      id: target.id,
      title: _labels.displayName(target.id, instance.name),
      secondary: label.isEmpty ? '' : instance.name,
      state: _guestState(target, frame.preview, frame.frameCurrent),
      image: frame.image,
      windowVisible: instance.windowVisible,
    );
  }

  /// Every listed emulator in the PC's order, then emulators being set up.
  List<EmulatorTileData> _playTiles() {
    final guests = [
      for (final target in targets)
        if (target.instance != null) target,
    ];
    return [
      for (final target in guests) _guestTile(target),
      for (final entry in _settingUp.entries)
        if (!guests.any((target) => target.id == entry.key))
          EmulatorTileData(
            id: entry.key,
            title: entry.value,
            secondary: entry.value == _avdRawName(entry.key)
                ? ''
                : _avdRawName(entry.key),
            state: const EmulatorUiState(EmulatorUiWord.starting, 'Starting'),
            placeholder: true,
          ),
    ];
  }

  /// Tile tap: opens (and starts, if stopped) the emulator, or says why not.
  void _openGuest(String id) {
    final target = _targetById(id);
    if (target == null) return;
    if (!_canControl) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(translate("{$_hostName} hasn't granted control"))));
      return;
    }
    unawaited(_open(target));
  }

  void _showGuestActions(String id) {
    final target = _targetById(id);
    if (target != null) unawaited(_showEmulatorActions(target));
  }

  AvdCardActions? _avdActions(_Target target) {
    final instance = target.instance;
    if (instance == null ||
        instance.provider != 'avd' ||
        !model.canManageAvds ||
        !_canControl) {
      return null;
    }
    final cloning = instance.state == 'cloning';
    // The list may still say stopped for the emulator being played.
    final running = _runningAsKnown(instance);
    return AvdCardActions(
      cloningLabel: cloning ? instance.runtimeLabel : null,
      running: running,
      windowVisible: instance.windowVisible,
      blocker: model.avdActionBlocker(target.id, 'avd_delete') ??
          (running ? 'Stop it first' : null),
      onToggleWindow: () => unawaited(_toggleAvdWindow(target)),
      onStop: model.canShutdownEmulator(target.id)
          ? () => unawaited(_shutdownEmulator(target))
          : null,
      onClone: () => unawaited(_cloneAvd(target)),
      onRename: () => unawaited(_renameAvd(target)),
      onDelete: () => unawaited(_deleteAvd(target)),
    );
  }

  Future<void> _showEmulatorActions(_Target target) async {
    final instance = target.instance;
    if (instance == null) return;
    final frame = _guestFrame(target);
    final state = _guestState(target, frame.preview, frame.frameCurrent);
    final control = _canControl;
    final stopped = instance.state == 'stopped';
    final cloning = instance.state == 'cloning';
    // Open on the game being played would only reconnect its stream.
    final playing = target.id == _fullscreen?.id && model.streaming;
    final label = _labels.labelFor(target.id);
    final subtitle = [
      if (label.isNotEmpty) instance.name,
      emulatorProviderLabel(instance.provider),
      if (instance.androidVersion.isNotEmpty)
        'Android ${instance.androidVersion}',
    ].join(' · ');
    await showEmulatorActionSheet(
      context,
      EmulatorActionSheet(
        title: _labels.displayName(target.id, instance.name),
        subtitle: subtitle,
        state: state,
        stopped: state.word == EmulatorUiWord.stopped,
        onOpen: control && state.canOpen && !model.connecting && !playing
            ? () => unawaited(_open(target))
            : null,
        openBlocker: !control
            ? translate("{$_hostName} hasn't granted control")
            : cloning
                ? translate('Copy in progress')
                : null,
        onLaunchGame: instance.defaultPackage.isNotEmpty &&
                !model.connecting &&
                control
            ? () => unawaited(_open(target, launchDefaultApp: true))
            : null,
        onStop: instance.provider == 'bluestacks' &&
                !stopped &&
                model.emulatorShutdownCapability ==
                    CapabilityStatus.supported &&
                control
            ? () => unawaited(_shutdownEmulator(target))
            : null,
        onLabel: () => unawaited(_editLabel(target)),
        avd: _avdActions(target),
        shuttingDown: model.isEmulatorShuttingDown(target.id),
      ),
    );
  }

  Future<void> _editLabel(_Target target) async {
    final instance = target.instance;
    if (instance == null) return;
    final label = await showEmulatorLabelSheet(context,
        emulatorName: instance.name,
        currentLabel: _labels.labelFor(target.id));
    if (label == null || !mounted) return;
    await _labels.setLabel(target.id, label);
  }

  /// The play rail's chips: Live and Starting emulators plus the open one,
  /// in grid order, named by their labels.
  List<PlayAccount> _playAccounts() => playRailAccounts([
        for (final target in targets)
          if (target.instance != null) _playAccount(_guestTile(target)),
      ], currentId: _fullscreen?.id);

  static PlayAccount _playAccount(EmulatorTileData tile) =>
      PlayAccount(id: tile.id, label: tile.title, word: tile.state.word);

  /// In a game: switches to emulator [id] (starting it if stopped). Ignored
  /// for the open emulator and while another switch is under way, so a
  /// second chip tap during a switch does nothing.
  Future<void> _switchTo(String id) async {
    if (!playRailCanSwitch(
        id: id,
        currentId: _fullscreen?.id,
        connecting: model.connecting,
        pending: _switchPending)) {
      return;
    }
    final target = _targetById(id);
    if (target == null || target.instance == null) return;
    if (!_canControl) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(
            content: Text(translate("{$_hostName} hasn't granted control"))));
      return;
    }
    _switchPending = true;
    try {
      await _open(target);
    } finally {
      _switchPending = false;
    }
  }

  /// The menu's "+": every emulator as a tile. Tapping one switches to it,
  /// starting it if it is stopped. No extra preview streams are requested
  /// while a game is streaming; tiles show their state and any frame held.
  Future<void> _chooseEmulator() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.85,
        child: AnimatedBuilder(
          animation: Listenable.merge([widget.ffi.imageModel, model, _labels]),
          builder: (context, _) {
            final guests = [
              for (final target in targets)
                if (target.instance != null) target,
            ];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                      MirpgRemoteTheme.pageMargin,
                      0,
                      MirpgRemoteTheme.pageMargin,
                      MirpgRemoteTheme.rhythm),
                  child: Text(translate('Emulators'),
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                Expanded(
                  child: LayoutBuilder(builder: (context, constraints) {
                    // Two columns; four in landscape so a row fits the sheet.
                    final size = MediaQuery.sizeOf(context);
                    final columns = size.width > size.height ? 4 : 2;
                    const spacing = 12.0;
                    final tileWidth = math.max(
                        0.0,
                        (constraints.maxWidth -
                                2 * MirpgRemoteTheme.pageMargin -
                                (columns - 1) * spacing) /
                            columns);
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(
                          MirpgRemoteTheme.pageMargin,
                          0,
                          MirpgRemoteTheme.pageMargin,
                          MirpgRemoteTheme.pageMargin),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: spacing,
                        crossAxisSpacing: spacing,
                        mainAxisExtent: playTabTileExtent(
                            tileWidth, MediaQuery.textScalerOf(context)),
                      ),
                      itemCount: guests.length,
                      itemBuilder: (_, index) {
                        final data = _guestTile(guests[index]);
                        return EmulatorTile(
                          data: data,
                          onOpen: data.state.canOpen &&
                                  _canControl &&
                                  !model.connecting
                              ? () => Navigator.of(sheetContext).pop(data.id)
                              : null,
                        );
                      },
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
    if (!mounted || picked == null) return;
    await _switchTo(picked);
  }

  Future<void> _dashboard() async {
    await _releaseMonitorInput();
    await model.desktop();
    if (!mounted) return;
    // The list is not refreshed during a game; catch up on what was started
    // or stopped meanwhile before the grid shows it.
    if (!model.loading) unawaited(model.refresh());
    setState(() {
      _fullscreen = null;
      _switchFrame?.dispose();
      _switchFrame = null;
    });
    _resetMonitorLivenessForCurrentTarget();
    _landscape = null;
    await SystemChrome.setPreferredOrientations(const []);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _subscription = '';
    _subscribe();
    unawaited(_maybeOfferPairing());
  }

  void _presentation() {
    final active = _fullscreen;
    if (active == null) return;
    final display = active.display;
    if (display != null && display >= widget.ffi.ffiModel.pi.displays.length) {
      return;
    }
    final width = display == null
        ? model.width
        : widget.ffi.ffiModel.pi.displays[display].width;
    final height = display == null
        ? model.height
        : widget.ffi.ffiModel.pi.displays[display].height;
    if (width <= 0 || height <= 0) return;
    final landscape = display == null
        ? width > height
        : monitorUsesLandscape(
            _preferencesForMonitor(display).orientation,
            Size(width.toDouble(), height.toDouble()),
          );
    if (_landscape == landscape) return;
    _landscape = landscape;
    unawaited(SystemChrome.setPreferredOrientations(landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight
          ]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown
          ]));
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
  }

  Future<void> _choose() async {
    await _releaseMonitorInput();
    if (!mounted) return;
    _chooser = true;
    _chooserSize = Size.zero;
    _subscription = '';
    _subscribe();
    final selected = await showModalBottomSheet<_Target>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: 0.85,
        child: Column(children: [
          ListTile(
            title: Text(translate('Switch view')),
            trailing: IconButton(
                tooltip: translate('Exit'),
                icon: const Icon(Icons.grid_view_outlined),
                onPressed: () =>
                    Navigator.of(sheetContext).pop(const _Target.dashboard())),
          ),
          Expanded(
              child: LayoutBuilder(builder: (_, box) {
            if (box.biggest != _chooserSize) {
              _chooserSize = box.biggest;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                _subscription = '';
                _subscribe();
              });
            }
            return TargetSwitcherGrid(
              controller: _chooserScroll,
              cards: [
                for (final target in targets)
                  target.instance == null
                      ? _monitorCard(
                          target, () => Navigator.of(sheetContext).pop(target))
                      : _guestSwitcherTile(
                          target, () => Navigator.of(sheetContext).pop(target))
              ],
            );
          })),
        ]),
      ),
    );
    _chooser = false;
    _subscription = '';
    if (!mounted) return;
    if (selected?.id == '') {
      await _dashboard();
    } else if (selected != null) {
      await _open(selected);
    } else {
      _subscribe();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(widget.ffi.ffiModel.sessionReconnect, _sessionReconnect)) {
      widget.ffi.ffiModel.sessionReconnect = null;
    }
    _sessionReconnect.dispose();
    model.removeListener(_changed);
    _labels.removeListener(_labelsChanged);
    _labels.dispose();
    _switchFrame?.dispose();
    _switchFrame = null;
    widget.ffi.ffiModel.removeListener(_changed);
    widget.ffi.qualityMonitorModel.removeListener(_qualityChanged);
    widget.ffi.aperturePairResult.removeListener(_pairResultChanged);
    _scrollDebounce?.cancel();
    _refreshTimer?.cancel();
    _healthTimer?.cancel();
    _scroll.dispose();
    _playScroll.dispose();
    _chooserScroll.dispose();
    _monitorFocus.dispose();
    model.framePacer.focused = true;
    unawaited(model.setMonitorPreviewMode(false));
    unawaited(model.setPreviews([], [], enabled: false));
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []));
    super.dispose();
  }

  /// The session is back after a drop: ask the PC for its list again and
  /// reopen what was open. The tab is unchanged (this page stayed open), and a
  /// stopped emulator is never started by this.
  void _restoreAfterReconnect() {
    // Peer info is still being applied when this is called.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _subscription = '';
      unawaited(model.refresh());
      final active = _fullscreen;
      final restore = reconnectRestoreFor(
        guestId: active?.instance != null ? active!.id : null,
        display: active?.display,
      );
      switch (restore.kind) {
        case ReconnectRestoreKind.guest:
          unawaited(model.connect(restore.guestId!, startIfStopped: false));
        case ReconnectRestoreKind.monitor:
          unawaited(model.desktop());
        case ReconnectRestoreKind.none:
          break;
      }
      _subscribe();
    });
  }

  /// The page with the "Reconnecting…" state over it.
  @override
  Widget build(BuildContext context) {
    final body = _buildPage(context);
    final inGame = _fullscreen != null;
    return Stack(
      fit: StackFit.expand,
      children: [
        body,
        ReconnectingBanner(
          controller: _sessionReconnect,
          // Over a game or monitor the bottom holds controls; over a tab the
          // navigation bar does.
          alignment: inGame ? Alignment.topCenter : Alignment.bottomCenter,
          padding: EdgeInsets.fromLTRB(
              16, inGame ? 56 : 16, 16, inGame ? 16 : 96),
        ),
      ],
    );
  }

  Widget _buildPage(BuildContext context) {
    final active = _fullscreen;
    if (active?.instance != null) {
      // The list refreshes, so read the emulator's current window state.
      final current = _targetById(active!.id) ?? active;
      final instance = current.instance!;
      final offerShowOnPc = instance.provider == 'avd' &&
          model.canManageAvds &&
          !instance.windowVisible;
      return EmulatorPage(
          ffi: widget.ffi,
          dashboardMode: true,
          onSwitch: _chooseEmulator,
          onReturn: _dashboard,
          nameFor: (id) =>
              _labels.displayName(id, _targetById(id)?.name ?? ''),
          switchFrame: _switchFrame,
          onShowOnPc:
              offerShowOnPc ? () => _toggleAvdWindow(current) : null,
          accounts: _playAccounts(),
          onSelectTarget: _switchTo,
          onCurrentActions: () => unawaited(_showEmulatorActions(current)),
          alreadyRunning: _alreadyRunning);
    }
    if (active?.display != null) {
      return _monitor(active!);
    }
    final pi = widget.ffi.ffiModel.pi;
    final filesAvailable = widget.ffi.ffiModel.permissions['file'] != false;
    final powershellAvailable =
        pi.platform == kPeerPlatformWindows && pi.features.terminal;
    final hostManagementAvailable =
        pi.platform == kPeerPlatformWindows && pi.features.hostManagement;
    final sections = <ConnectedPcSection>[
      ConnectedPcSection.screens,
      ConnectedPcSection.devices,
      ConnectedPcSection.pc,
      if (hostManagementAvailable) ConnectedPcSection.system,
      if (filesAvailable) ConnectedPcSection.files,
      if (powershellAvailable) ConnectedPcSection.powershell,
    ];
    final activeSection = sections.contains(_section)
        ? _section
        : kConnectedPcInitialSection;
    final sectionIndex = sections.indexOf(activeSection);
    final navigationIndex = connectedPcNavigationIndex(activeSection);
    final hostName = _hostName;
    final root = activeSection == kConnectedPcInitialSection;
    final subPage = activeSection == ConnectedPcSection.system ||
        activeSection == ConnectedPcSection.files ||
        activeSection == ConnectedPcSection.powershell;
    final theme = Theme.of(context);
    final connToken = bind.sessionGetConnToken(sessionId: widget.ffi.sessionId);
    final pages = <Widget>[
      _screensBody(hostName),
      _homeBody(hostName),
      PcTabBody(
        onSystem: hostManagementAvailable
            ? () => _openToolsSection(ConnectedPcSection.system)
            : null,
        onFiles: filesAvailable
            ? () => _openToolsSection(ConnectedPcSection.files)
            : null,
        onPowerShell: powershellAvailable
            ? () => _openToolsSection(ConnectedPcSection.powershell)
            : null,
        onQuality: () => unawaited(_showQualityConnection()),
        onPrivacy: () => unawaited(showPrivacyControlsSheet(
          context,
          ffi: widget.ffi,
        )),
        pairingState: _pairingState,
        onTrustPhone: () => unawaited(_trustThisPhone()),
        onForgetPairing: () => unawaited(_forgetPairing()),
        onSettings: _openSettings,
        onEndSession: () => clientClose(widget.ffi.sessionId, widget.ffi),
      ),
      if (hostManagementAvailable)
        _systemOpened
            ? HostManagementPage(
                model: model,
                active: activeSection == ConnectedPcSection.system,
                canControl: widget.ffi.ffiModel.keyboard &&
                    !widget.ffi.ffiModel.viewOnly,
              )
            : const SizedBox.shrink(),
      if (filesAvailable)
        _filesOpened
            ? FileManagerPage(
                id: widget.ffi.id,
                connToken: connToken,
                embedded: true,
                initiallyShowRemote: true,
              )
            : const SizedBox.shrink(),
      if (powershellAvailable)
        _powershellOpened
            ? TerminalPage(
                id: widget.ffi.id,
                password: null,
                isSharedPassword: false,
                connToken: connToken,
                embedded: true,
              )
            : const SizedBox.shrink(),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        handleConnectedPcWorkspaceBack(
          atOverview: connectedPcBackTarget(activeSection) == null,
          onReturnToOverview: () => setState(() {
            _section = connectedPcBackTarget(activeSection) ??
                kConnectedPcInitialSection;
            _subscription = '';
            _subscribe();
          }),
          onStayConnected: _showSessionStillConnected,
        );
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leadingWidth: 56,
          leading: activeSection == kConnectedPcInitialSection
              ? Padding(
                  padding: const EdgeInsets.only(left: 16, top: 10, bottom: 10),
                  child: const ApertureBrandMark(size: 36),
                )
              : IconButton(
                  tooltip: 'Back',
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => setState(() {
                    _section = connectedPcBackTarget(activeSection) ??
                        kConnectedPcInitialSection;
                    _subscription = '';
                    _subscribe();
                  }),
                ),
          titleSpacing: 10,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                switch (activeSection) {
                  ConnectedPcSection.devices ||
                  ConnectedPcSection.screens ||
                  ConnectedPcSection.pc => hostDisplayName(hostName),
                  ConnectedPcSection.system => 'System',
                  ConnectedPcSection.files => 'Files',
                  ConnectedPcSection.powershell => 'PowerShell',
                },
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (!root)
                Text(
                  switch (activeSection) {
                    ConnectedPcSection.devices => translate('Play'),
                    ConnectedPcSection.pc => translate('PC'),
                    _ => hostDisplayName(hostName),
                  },
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium,
                ),
            ],
          ),
          actions: [
            // The status pill is on every tab and sub-page (compact on
            // narrow phones).
            // Play refreshes by pulling the grid down; Screens has nothing to
            // refresh (monitors come with the connection).
            if (activeSection == ConnectedPcSection.system)
              IconButton(
                  tooltip: 'Refresh system status',
                  icon: const Icon(Icons.refresh),
                  onPressed: model.hostLoading
                      ? null
                      : () => unawaited(model.refreshHost())),
            Padding(
              padding: const EdgeInsets.only(right: MirpgRemoteTheme.pageMargin),
              child: SessionStatusButton(
                compact: MediaQuery.sizeOf(context).width < 480,
                direct: widget.ffi.ffiModel.direct,
                data: widget.ffi.qualityMonitorModel.data,
                now: DateTime.now(),
                onPressed: () => unawaited(_showQualityConnection()),
              ),
            ),
          ],
        ),
        body: IndexedStack(
          index: sectionIndex,
          children: pages,
        ),
        // System, Files and PowerShell look like pushed pages (back arrow,
        // no tab bar) but stay in the IndexedStack so their sessions survive.
        bottomNavigationBar: subPage
            ? null
            : ConnectedPcTabBar(
              currentIndex: navigationIndex,
              filesAvailable: filesAvailable,
              hostManagementAvailable: hostManagementAvailable,
              powershellAvailable: powershellAvailable,
              onDestinationSelected: (index) {
                final selected =
                    connectedPcSectionForIndex(index) ?? activeSection;
                if (selected == activeSection) return;
                setState(() {
                  _section = selected;
                  if (selected == ConnectedPcSection.system) {
                    _systemOpened = true;
                  }
                  if (selected == ConnectedPcSection.files) _filesOpened = true;
                  if (selected == ConnectedPcSection.powershell) {
                    _powershellOpened = true;
                  }
                });
                _subscribe();
              },
            ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (routeContext) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SettingsPage(),
      ),
    ));
  }

  void _showSessionStillConnected() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(translate('Session still connected. End it from the PC tab.')),
        duration: Duration(seconds: 2),
      ));
  }

  void _openToolsSection(ConnectedPcSection section) {
    setState(() {
      _section = section;
      if (section == ConnectedPcSection.system) _systemOpened = true;
      if (section == ConnectedPcSection.files) _filesOpened = true;
      if (section == ConnectedPcSection.powershell) _powershellOpened = true;
    });
    _subscription = '';
    _subscribe();
  }

  /// Keeps the pull-to-refresh spinner until the PC answers the list request
  /// (the model's own 25 s list timeout ends it at the latest).
  Future<void> _pullToRefresh() async {
    _subscription = '';
    // A list already in flight (the 10 s refresh) is awaited, not repeated.
    if (!model.loading) await model.refresh();
    if (!mounted || !model.loading) return;
    final done = Completer<void>();
    void check() {
      if (!model.loading && !done.isCompleted) done.complete();
    }

    model.addListener(check);
    try {
      await done.future
          .timeout(const Duration(seconds: 30), onTimeout: () {});
    } finally {
      model.removeListener(check);
    }
  }

  /// Play: every emulator as a tile.
  Widget _homeBody(String hostName) {
    final canCreate = model.canManageAvds && _canControl;
    return LayoutBuilder(builder: (context, constraints) {
      final rowExtent = playTabRowExtent(
          constraints.maxWidth, MediaQuery.textScalerOf(context));
      if (rowExtent != _playRowExtent) {
        _playRowExtent = rowExtent;
        WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
      }
      return AnimatedBuilder(
        animation: Listenable.merge([widget.ffi.imageModel, model, _labels]),
        builder: (context, _) {
          final tiles = _playTiles();
          return PlayTabBody(
            tiles: tiles,
            hostName: hostName,
            firstLoad: !_listSeen && tiles.isEmpty,
            listError: model.listError,
            scrollController: _playScroll,
            onRefresh: _pullToRefresh,
            onRetryList: () {
              _subscription = '';
              unawaited(model.refresh());
            },
            onOpen: _openGuest,
            onMore: _showGuestActions,
            onNew: canCreate ? () => unawaited(_newAvd()) : null,
          );
        },
      );
    });
  }

  /// Screens: one card per PC monitor, nothing else.
  Widget _screensBody(String hostName) {
    final displays = widget.ffi.ffiModel.pi.displays;
    ScreensTabCard cardFor(int index) {
      final display = displays[index];
      return ScreensTabCard(
        aspectRatio: display.width > 0 && display.height > 0
            ? display.width / display.height
            : 16 / 9,
        child: _monitorCard(
          _Target.monitor(index),
          () => unawaited(_open(_Target.monitor(index))),
          windows: () => unawaited(_monitorWindows(index)),
        ),
      );
    }

    return LayoutBuilder(builder: (context, constraints) {
      final cards = [for (var i = 0; i < displays.length; i++) cardFor(i)];
      final cardWidth = math.max(
          0.0, constraints.maxWidth - 2 * MirpgRemoteTheme.pageMargin);
      final extents = [
        for (final card in cards)
          screensTabCardExtent(
              cardWidth, card.aspectRatio, MediaQuery.textScalerOf(context))
      ];
      if (!listEquals(extents, _screensExtents)) {
        _screensExtents = extents;
        WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
      }
      return ScreensTabBody(
        cards: cards,
        hostName: hostName,
        scrollController: _scroll,
        tr: translate,
      );
    });
  }

  /// A PC monitor as a preview card, on Screens (with [windows]) or in the
  /// view switcher.
  Widget _monitorCard(_Target target, VoidCallback onOpen,
          {VoidCallback? windows}) =>
      AnimatedBuilder(
        animation: Listenable.merge([widget.ffi.imageModel, model]),
        builder: (_, __) {
          final display = target.display!;
          final image = widget.ffi.imageModel.dashboardImage(display);
          final updatedAt =
              widget.ffi.imageModel.dashboardImageUpdatedAt(display);
          final frameAge =
              updatedAt == null ? null : DateTime.now().difference(updatedAt);
          final live = image != null &&
              frameAge != null &&
              !frameAge.isNegative &&
              frameAge < const Duration(seconds: 8) &&
              _monitorPreviewFrameIsCurrent(display);
          final info = display < widget.ffi.ffiModel.pi.displays.length
              ? widget.ffi.ffiModel.pi.displays[display]
              : null;
          return TargetPreviewCard(
            name: target.name,
            detail: info == null || info.width <= 0 || info.height <= 0
                ? ''
                : '${info.width} × ${info.height}',
            live: live,
            image: image,
            onOpen: model.connecting ? null : onOpen,
            onRetry: () {
              _subscription = '';
              _subscribe();
            },
            onWindows: windows,
          );
        },
      );

  /// An emulator in the view switcher; tapping picks it.
  Widget _guestSwitcherTile(_Target target, VoidCallback onPick) =>
      AnimatedBuilder(
        animation: Listenable.merge([widget.ffi.imageModel, model, _labels]),
        builder: (_, __) {
          final data = _guestTile(target);
          return EmulatorTile(
            data: data,
            onOpen: data.state.canOpen && _canControl && !model.connecting
                ? onPick
                : null,
          );
        },
      );

  Widget _monitor(_Target target) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_dashboard());
        },
        child: Scaffold(
            backgroundColor: Colors.black,
            // The remote view lays the phone keyboard over the picture itself.
            resizeToAvoidBottomInset: false,
            body: SafeArea(
                child: Stack(children: [
              Positioned.fill(
                  child: KeyboardListener(
                focusNode: _monitorFocus,
                autofocus: true,
                onKeyEvent: (event) {
                  if (_canControlMonitor(target.display!)) {
                    widget.ffi.inputModel.handleKeyEvent(event);
                  }
                },
                child: AnimatedBuilder(
                    animation: widget.ffi.imageModel,
                    builder: (_, __) {
                      final image =
                          widget.ffi.imageModel.dashboardImage(target.display!);
                      final display =
                          widget.ffi.ffiModel.pi.displays[target.display!];
                      final preferences =
                          _preferencesForMonitor(target.display!);
                      final frameStatus =
                          _monitorFrameStatus(target.display!, image);
                      final focused = _focusedWindow;
                      return MonitorControlView(
                        key: ValueKey(
                            '${target.id}:${display.width}x${display.height}'),
                        desktopSize: Size(display.width.toDouble(),
                            display.height.toDouble()),
                        image: image,
                        canControl: image != null &&
                            _hostCanControlMonitor(target.display!),
                        frameStatus: frameStatus,
                        focusRect: focused?.monitor == target.display
                            ? Rect.fromLTWH(
                                focused!.x.toDouble(),
                                focused.y.toDouble(),
                                focused.width.toDouble(),
                                focused.height.toDouble(),
                              )
                            : null,
                        focusRevision: _windowFocusRevision,
                        preferences: preferences,
                        onPreferencesChanged: (next) =>
                            _saveMonitorPreferences(target.display!, next),
                        localViewOnly: _monitorLocalViewOnly,
                        onLocalViewOnlyChanged: (value) =>
                            unawaited(_setMonitorLocalViewOnly(value)),
                        onPointer: (action, point) => action == 2
                            ? _queueMonitorMove(point, target.display!)
                            : _queueMonitor(() =>
                                _monitorTouch(action, point, target.display!)),
                        onScroll: (steps) => _queueMonitor(() async {
                          if (_canControlMonitor(target.display!)) {
                            await widget.ffi.inputModel.scroll(steps);
                          }
                        }),
                        onSmoothScroll: widget.ffi.ffiModel.pi.platform ==
                                kPeerPlatformWindows
                            ? (units) =>
                                _queueMonitorWheel(units, target.display!)
                            : null,
                        onKeyboard: () =>
                            unawaited(_monitorKeyboard(target.display!)),
                        onTextInput: (text) => _queueMonitor(() async {
                          if (_canControlMonitor(target.display!)) {
                            await bind.sessionInputString(
                                sessionId: widget.ffi.sessionId, value: text);
                          }
                        }),
                        onKeyTap: (key) => _queueMonitor(
                            () => _monitorTapKey(key, target.display!)),
                        onKeyState: (key, down) => _queueMonitor(() async {
                          _monitorKeyState(key, down, target.display!);
                        }),
                        onSoftKeyboard: (enabled) =>
                            unawaited(_monitorSoftKeyboard(enabled)),
                        onClipboard: () => unawaited(_monitorClipboard()),
                        onWindows: () =>
                            unawaited(_monitorWindows(target.display!)),
                        onSwitchView: () => unawaited(_choose()),
                        onDashboard: () => unawaited(_dashboard()),
                        onSessionStatus: () =>
                            unawaited(_showQualityConnection()),
                        onCtrlAltDel: (widget.ffi.ffiModel.pi.platform ==
                                    kPeerPlatformLinux ||
                                widget.ffi.ffiModel.pi.sasEnabled)
                            ? () => _queueMonitor(() async {
                                  if (_canControlMonitor(target.display!)) {
                                    await bind.sessionCtrlAltDel(
                                        sessionId: widget.ffi.sessionId);
                                  }
                                })
                            : null,
                        onRestartTaskbar: model.hostShellRestartCapability ==
                                CapabilityStatus.supported
                            ? () => unawaited(_restartTaskbar(target.display!))
                            : null,
                      );
                    }),
              )),
            ]))),
      );

  Future<void> _restartTaskbar(int display) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Restart the PC’s taskbar?'),
            content: const Text(
                'This restarts Windows Explorer on the PC, which brings back a missing taskbar and desktop. Open File Explorer folders close; other apps stay open.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('Restart')),
            ],
          ),
        ) ??
        false;
    if (!mounted) return;
    if (!confirmed || !_canControlMonitor(display)) {
      _monitorFocus.requestFocus();
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
          const SnackBar(content: Text('Restarting the PC’s taskbar…')));
    final result = await model.restartHostShell().timeout(
        const Duration(seconds: 30),
        onTimeout: () => const HostShellRestartResult(
            false, 'The PC didn’t answer. Check its screen.'));
    if (!mounted) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(result.ok ? 'Taskbar restarted' : result.message)));
    _monitorFocus.requestFocus();
  }

  Future<void> _monitorWindows(int display) async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WindowPickerSheet(
        model: model,
        canControl: widget.ffi.ffiModel.keyboard &&
            !widget.ffi.ffiModel.viewOnly &&
            !_background &&
            _viewFocused,
        onFocused: _applyFocusedWindow,
      ),
    );
    if (mounted) _monitorFocus.requestFocus();
  }

  Future<void> _applyFocusedWindow(HostWindowInfo window) async {
    if (!mounted ||
        window.monitor < 0 ||
        window.monitor >= widget.ffi.ffiModel.pi.displays.length) {
      return;
    }
    if (_chooser) setState(() => _chooser = false);
    await _open(
      _Target.monitor(window.monitor),
      focusedWindow: window,
    );
  }

  bool _hostCanControlMonitor(int index) =>
      mounted &&
      !_background &&
      _viewFocused &&
      _fullscreen?.display == index &&
      !model.selected &&
      !model.connecting &&
      widget.ffi.ffiModel.keyboard &&
      !widget.ffi.ffiModel.viewOnly &&
      index >= 0 &&
      index < widget.ffi.ffiModel.pi.displays.length &&
      _monitorFrameIsCurrent(index);

  bool _monitorPreviewFrameIsCurrent(int index) => monitorFrameIsCurrent(
        previewRequest: model.previewRequest,
        acknowledgedRequest: model.previewAcknowledgedRequest,
        frameRequest: widget.ffi.imageModel.dashboardImagePreviewRequest(index),
      );

  bool _monitorFrameIsCurrent(int index) {
    if (!_monitorPreviewFrameIsCurrent(index)) return false;
    _syncMonitorLiveness(index);
    return _monitorLiveness.canSendInput(
      DateTime.now(),
      hostPermission: true,
      background: _background || !_viewFocused,
    );
  }

  String? _monitorFrameStatus(int index, ui.Image? image) {
    if (_monitorPreviewFrameIsCurrent(index)) {
      _syncMonitorLiveness(index);
      final reason = _monitorLiveness.blockReason(
        DateTime.now(),
        hostPermission: true,
        background: _background || !_viewFocused,
      );
      switch (reason) {
        case MonitorInputBlockReason.none:
          return null;
        case MonitorInputBlockReason.transportStale:
          return 'Connection heartbeat lost · input paused';
        case MonitorInputBlockReason.streamStale:
          return 'Video stream paused · input paused';
        case MonitorInputBlockReason.decoderNotReady:
          return 'Waiting for video decoder · input paused';
        case MonitorInputBlockReason.decoderFailed:
          return 'Video decoder recovering · input paused';
        case MonitorInputBlockReason.frameNotReady:
          return 'Waiting for current-session video';
        case MonitorInputBlockReason.background:
          return 'Input paused while app is inactive';
        case MonitorInputBlockReason.viewOnly:
        case MonitorInputBlockReason.hostPermission:
          break;
      }
    }
    if (image == null) return 'Waiting for live video';
    if (!model.previewsAcknowledged) return 'Last frame · reconnecting';
    final updatedAt = widget.ffi.imageModel.dashboardImageUpdatedAt(index);
    if (updatedAt == null) return 'Last frame · waiting for fresh video';
    final age = DateTime.now().difference(updatedAt);
    if (age.isNegative || age.inSeconds < 2) {
      return 'Last frame · waiting for fresh video';
    }
    return 'Last frame · ${age.inSeconds}s old';
  }

  bool _canControlMonitor(int index) =>
      !_monitorLocalViewOnly && _hostCanControlMonitor(index);

  Future<void> _setMonitorLocalViewOnly(bool value) async {
    if (value == _monitorLocalViewOnly) return;
    if (value) await _releaseMonitorInput();
    if (!mounted) return;
    setState(() => _monitorLocalViewOnly = value);
  }

  Future<void> _monitorTouch(int action, Offset point, int index) async {
    if (!_canControlMonitor(index) ||
        (action == 0 && _monitorDown) ||
        (action == 1 && !_monitorDown) ||
        (action == 5 && _monitorRightDown) ||
        (action == 6 && !_monitorRightDown)) return;
    final display = widget.ffi.ffiModel.pi.displays[index];
    if (!point.dx.isFinite ||
        !point.dy.isFinite ||
        point.dx < 0 ||
        point.dy < 0 ||
        point.dx >= display.width ||
        point.dy >= display.height) return;
    await widget.ffi.inputModel
        .moveMouse(display.x + point.dx, display.y + point.dy);
    if (action == 0) {
      _monitorDown = true;
      await widget.ffi.inputModel.tapDown(MouseButtons.left);
    } else if (action == 1) {
      _monitorDown = false;
      await widget.ffi.inputModel.tapUp(MouseButtons.left);
    } else if (action == 3) {
      await widget.ffi.inputModel.tap(MouseButtons.right);
    } else if (action == 4) {
      await widget.ffi.inputModel.tap(MouseButtons.wheel);
    } else if (action == 5) {
      _monitorRightDown = true;
      await widget.ffi.inputModel.tapDown(MouseButtons.right);
    } else if (action == 6) {
      _monitorRightDown = false;
      await widget.ffi.inputModel.tapUp(MouseButtons.right);
    }
  }

  /// Queues one monitor input action. Any queued pointer move or wheel
  /// burst is closed first so input keeps its order.
  void _queueMonitor(Future<void> Function() action) {
    _openMonitorMove = null;
    _openMonitorWheel = null;
    _enqueueMonitor(action);
  }

  /// Moves are coalesced: while one is still waiting in the queue, newer
  /// positions replace it, so a fast drag never builds a backlog.
  void _queueMonitorMove(Offset point, int index) {
    _openMonitorWheel = null;
    final open = _openMonitorMove;
    if (open != null && open.index == index) {
      open.point = point;
      return;
    }
    final slot = _MonitorMoveSlot(point, index);
    _openMonitorMove = slot;
    _enqueueMonitor(() {
      if (identical(_openMonitorMove, slot)) _openMonitorMove = null;
      return _monitorTouch(2, slot.point, slot.index);
    });
  }

  /// Smooth wheel units (120 per notch) for Windows hosts, coalesced like
  /// moves. Uses the host's existing trackpad wheel path.
  void _queueMonitorWheel(Offset units, int index) {
    _openMonitorMove = null;
    final open = _openMonitorWheel;
    if (open != null && open.index == index) {
      open.units += units;
      return;
    }
    final slot = _MonitorWheelSlot(units, index);
    _openMonitorWheel = slot;
    _enqueueMonitor(() async {
      if (identical(_openMonitorWheel, slot)) _openMonitorWheel = null;
      if (!_canControlMonitor(slot.index)) return;
      final x = slot.units.dx.round().clamp(-2400, 2400);
      final y = slot.units.dy.round().clamp(-2400, 2400);
      if (x == 0 && y == 0) return;
      await bind.sessionSendMouse(
          sessionId: widget.ffi.sessionId,
          msg: '{"type": "trackpad", "x": "$x", "y": "$y"}');
    });
  }

  /// Taps [key] on the PC as a named key, with any held Ctrl/Alt/Shift/Win.
  Future<void> _monitorTapKey(PhysicalKeyboardKey key, int index) async {
    if (!_canControlMonitor(index)) return;
    _monitorKeys.tap(key);
  }

  void _monitorKeyState(PhysicalKeyboardKey key, bool down, int index) {
    if (!mounted ||
        _fullscreen?.display != index ||
        index < 0 ||
        index >= widget.ffi.ffiModel.pi.displays.length) {
      return;
    }
    if (down && !_canControlMonitor(index)) return;
    _monitorKeys.setState(key, down);
  }

  Future<void> _monitorSoftKeyboard(bool enabled) async {
    await widget.ffi.invokeMethod('enable_soft_keyboard', enabled);
    if (!enabled && mounted) _monitorFocus.requestFocus();
  }

  void _enqueueMonitor(Future<void> Function() action) {
    final epoch = _monitorInputEpoch.capture();
    _monitorEvents = _monitorEvents.then((_) {
      if (!_monitorInputEpoch.accepts(epoch)) return Future<void>.value();
      return action();
    }).catchError((Object error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Monitor input failed: $error')));
      }
    });
  }

  Future<void> _monitorKeyboard(int index) async {
    await _releaseMonitorInput();
    if (!_canControlMonitor(index)) return;
    await widget.ffi.invokeMethod('enable_soft_keyboard', true);
    try {
      if (!_canControlMonitor(index)) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => MonitorKeyboardPanel(
                initialText: _monitorDrafts[index] ?? '',
                shortcuts: _preferencesForMonitor(index).shortcuts,
                onShortcutsChanged: (shortcuts) => _saveMonitorPreferences(
                    index,
                    _preferencesForMonitor(index)
                        .copyWith(shortcuts: shortcuts)),
                onDraftChanged: (value) {
                  if (value.isEmpty) {
                    _monitorDrafts.remove(index);
                  } else {
                    _monitorDrafts[index] = value;
                  }
                },
                onText: (text) => _queueMonitor(() async {
                  if (_canControlMonitor(index)) {
                    await bind.sessionInputString(
                        sessionId: widget.ffi.sessionId, value: text);
                  }
                }),
                onKey: (key) => _queueMonitor(() => _monitorTapKey(key, index)),
                onKeyState: (key, down) => _queueMonitor(() async {
                  if (!mounted ||
                      _fullscreen?.display != index ||
                      index < 0 ||
                      index >= widget.ffi.ffiModel.pi.displays.length) {
                    return;
                  }
                  if (down && !_canControlMonitor(index)) return;
                  _monitorKeys.setState(key, down);
                }),
              ));
    } finally {
      await widget.ffi.invokeMethod('enable_soft_keyboard', false);
      if (mounted) _monitorFocus.requestFocus();
    }
  }

  Future<void> _monitorClipboard() async {
    await _releaseMonitorInput();
    if (!mounted) return;
    widget.ffi.clipboardTransferModel.onContextChanged();
    final hostname = widget.ffi.ffiModel.pi.hostname.trim();
    final targetLabel = hostname.isNotEmpty ? hostname : widget.ffi.id;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => ClipboardTransferSheet(
        model: widget.ffi.clipboardTransferModel,
        targetLabel: targetLabel,
      ),
    );
    if (mounted) _monitorFocus.requestFocus();
  }

  Future<void> _releaseMonitor() async {
    await _monitorEvents;
    if (_monitorDown) {
      _monitorDown = false;
      await widget.ffi.inputModel.tapUp(MouseButtons.left);
    }
    if (_monitorRightDown) {
      _monitorRightDown = false;
      await widget.ffi.inputModel.tapUp(MouseButtons.right);
    }
  }

  Future<void> _releaseMonitorInput({bool invalidateQueued = true}) async {
    if (invalidateQueued) _monitorInputEpoch.invalidate();
    await _releaseMonitor();
    widget.ffi.inputModel.toReleaseKeys
        .release(widget.ffi.inputModel.handleKeyEvent);
    widget.ffi.inputModel.toReleaseRawKeys
        .release(widget.ffi.inputModel.handleRawKeyEvent);
    widget.ffi.inputModel.resetModifiers();
    _monitorKeys.releaseAll();
  }
}

void handleConnectedPcWorkspaceBack({
  required bool atOverview,
  required VoidCallback onReturnToOverview,
  required VoidCallback onStayConnected,
}) {
  if (atOverview) {
    onStayConnected();
  } else {
    onReturnToOverview();
  }
}

class ConnectedPcTabBar extends StatelessWidget {
  const ConnectedPcTabBar({
    super.key,
    required this.currentIndex,
    this.filesAvailable = false,
    this.hostManagementAvailable = false,
    this.powershellAvailable = false,
    required this.onDestinationSelected,
    this.tr = translate,
  });

  final int currentIndex;
  final bool filesAvailable;
  final bool hostManagementAvailable;
  final bool powershellAvailable;
  final ValueChanged<int> onDestinationSelected;
  final String Function(String) tr;

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationDestination>[
      NavigationDestination(
        icon: const Icon(Icons.layers_outlined),
        selectedIcon: const Icon(Icons.layers_rounded),
        label: tr('Screens'),
      ),
      NavigationDestination(
        icon: const Icon(Icons.sports_esports_outlined),
        selectedIcon: const Icon(Icons.sports_esports_rounded),
        label: tr('Play'),
      ),
      NavigationDestination(
        icon: const Icon(Icons.computer_outlined),
        selectedIcon: const Icon(Icons.computer_rounded),
        label: tr('PC'),
      ),
    ];
    if (destinations.length <= 1) return const SizedBox.shrink();
    return NavigationBar(
      selectedIndex: currentIndex.clamp(0, destinations.length - 1),
      onDestinationSelected: onDestinationSelected,
      destinations: destinations,
    );
  }
}

class _Target {
  const _Target.guest(this.instance) : display = null;
  const _Target.monitor(this.display) : instance = null;
  const _Target.dashboard()
      : instance = null,
        display = null;
  final RemoteEmulator? instance;
  final int? display;
  String get id => instance?.id ?? (display == null ? '' : 'monitor:$display');
  String get name => instance?.name ?? 'Monitor ${display! + 1}';
}

Future<bool> showEmulatorShutdownConfirmation(BuildContext context, String name,
        {String Function(String) tr = translate}) =>
    showDestructiveConfirmation(
      context,
      title: tr('Stop {$name}?'),
      body: tr('Apps running in it will close.'),
      confirmLabel: tr('Stop'),
      cancelLabel: tr('Cancel'),
    );

class _MonitorMoveSlot {
  _MonitorMoveSlot(this.point, this.index);
  Offset point;
  final int index;
}

class _MonitorWheelSlot {
  _MonitorWheelSlot(this.units, this.index);
  Offset units;
  final int index;
}
