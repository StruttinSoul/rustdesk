import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../consts.dart'
    show kKeyFlutterKey, kPeerPlatformLinux, kPeerPlatformWindows;
import '../../common/widgets/dialog.dart' show clientClose;
import '../../models/platform_model.dart' show bind;
import '../../models/codex_model.dart';
import '../../models/emulator_model.dart';
import '../../models/host_management_model.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/remote_operation_state.dart';
import 'codex_page.dart';
import 'emulator_page.dart';
import 'file_manager_page.dart';
import 'host_management_page.dart';
import 'settings_page.dart';
import 'terminal_page.dart';
import '../widgets/mirpg_remote_theme.dart';
import '../widgets/clipboard_transfer_sheet.dart';
import '../widgets/monitor_control_view.dart';
import '../widgets/monitor_session_continuity.dart';
import '../widgets/privacy_controls_sheet.dart';
import '../widgets/session_quality_panel.dart';
import '../widgets/window_picker_sheet.dart';

enum _ConnectedPcSection { devices, system, files, powershell, codex }

class TargetDashboardPage extends StatefulWidget {
  const TargetDashboardPage({
    super.key,
    required this.ffi,
    this.initialCodexThreadId,
  });
  final FFI ffi;
  final String? initialCodexThreadId;

  @override
  State<TargetDashboardPage> createState() => _TargetDashboardPageState();
}

class _TargetDashboardPageState extends State<TargetDashboardPage>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _monitorFocus = FocusNode();
  Timer? _scrollDebounce;
  Timer? _refreshTimer;
  Timer? _healthTimer;
  _Target? _fullscreen;
  bool _chooser = false;
  bool _background = false;
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
  final Set<int> _monitorHeldKeys = <int>{};
  final Map<int, String> _monitorDrafts = <int, String>{};
  final Map<int, MonitorControlPreferences> _monitorPreferences =
      <int, MonitorControlPreferences>{};
  Future<void> _monitorEvents = Future.value();
  HostWindowInfo? _focusedWindow;
  int _windowFocusRevision = 0;
  bool? _landscape;
  String _subscription = '';
  double _viewport = 1;
  double _extent = 1;
  int _columns = 1;
  int _chooserStart = 0;
  _ConnectedPcSection _section = _ConnectedPcSection.devices;
  bool _filesOpened = false;
  bool _systemOpened = false;
  bool _powershellOpened = false;
  bool _codexOpened = false;
  MirpgQualityProfile _qualityProfile = MirpgQualityProfile.auto;
  String? _effectiveImageQuality;
  String _qualityError = '';
  bool _qualityApplying = false;
  bool _hasStoredQualityPreference = false;
  int _peerInfoGeneration = 0;
  int _reconnectGeneration = 0;
  int _codexOverviewRequestGeneration = -1;
  EmulatorModel get model => widget.ffi.emulatorModel;

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
          if (instance.provider == 'bluestacks') _Target.guest(instance),
      ];

  @override
  void initState() {
    super.initState();
    if (widget.initialCodexThreadId?.trim().isNotEmpty ?? false) {
      _section = _ConnectedPcSection.codex;
      _codexOpened = true;
    }
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_changed);
    widget.ffi.ffiModel.addListener(_changed);
    widget.ffi.qualityMonitorModel.addListener(_qualityChanged);
    widget.ffi.codexModel.addListener(_codexChanged);
    _peerInfoGeneration = widget.ffi.ffiModel.peerInfoGeneration;
    _reconnectGeneration = widget.ffi.ffiModel.reconnectGeneration;
    _scroll.addListener(_scrolled);
    unawaited(model.refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_background && !model.loading && !model.connecting) {
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
      _maybeLoadCodexOverview();
    });
  }

  void _codexChanged() {
    if (mounted) setState(() {});
  }

  void _maybeLoadCodexOverview({bool force = false}) {
    if (!mounted || !widget.ffi.ffiModel.pi.features.codex) return;
    final codex = widget.ffi.codexModel;
    if (codex.loadingThreads) return;
    final generation = widget.ffi.ffiModel.peerInfoGeneration;
    if (!force && _codexOverviewRequestGeneration == generation) return;
    _codexOverviewRequestGeneration = generation;
    unawaited(codex.listThreads());
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
      _codexOverviewRequestGeneration = -1;
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
    _presentation();
    setState(() {});
    _maybeLoadCodexOverview();
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _scrolled() {
    _scrollDebounce?.cancel();
    _scrollDebounce = Timer(const Duration(milliseconds: 100), _subscribe);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _background = state != AppLifecycleState.resumed;
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
    setState(() {});
  }

  void _subscribe() {
    if (!mounted) return;
    final all = targets;
    final guestIds = <String>[];
    final displays = <int>[];
    final active = _fullscreen;
    if (!_background && active?.display != null) displays.add(active!.display!);
    if (!_background && (active == null || _chooser)) {
      final first = _chooser
          ? _chooserStart
          : ((_scroll.hasClients ? _scroll.offset : 0) / _extent).floor() *
              _columns;
      final count =
          _chooser ? 4 : ((_viewport / _extent).ceil() + 1) * _columns;
      for (final target in all.skip(first).take(math.min(count, 4))) {
        if (guestIds.length + displays.length >= 4) break;
        if (target.display != null) {
          if (!displays.contains(target.display)) displays.add(target.display!);
        } else if (target.id != active?.id &&
            target.instance!.state != 'stopped') {
          guestIds.add(target.id);
        }
      }
    }
    final signature = '${guestIds.join(',')}|${displays.join(',')}';
    if (_subscription == signature && model.dashboardActive) return;
    _subscription = signature;
    unawaited(model.setPreviews(guestIds, displays));
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
    await _releaseMonitorInput();
    setState(() {
      _fullscreen = target;
      _focusedWindow = focusedWindow;
      if (focusedWindow != null) _windowFocusRevision++;
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

  Future<void> _dashboard() async {
    await _releaseMonitorInput();
    await model.desktop();
    if (!mounted) return;
    setState(() => _fullscreen = null);
    _resetMonitorLivenessForCurrentTarget();
    _landscape = null;
    await SystemChrome.setPreferredOrientations(const []);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _subscription = '';
    _subscribe();
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
    _chooserStart = 0;
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
            title: const Text('Switch view'),
            trailing: IconButton(
                tooltip: 'Dashboard',
                icon: const Icon(Icons.grid_view_outlined),
                onPressed: () =>
                    Navigator.of(sheetContext).pop(const _Target.dashboard())),
          ),
          Expanded(
              child: PageView.builder(
            itemCount: (targets.length / 4).ceil(),
            onPageChanged: (page) {
              _chooserStart = page * 4;
              _subscription = '';
              _subscribe();
            },
            itemBuilder: (_, page) => GridView.count(
              crossAxisCount: 2,
              padding: const EdgeInsets.all(12),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
              children: [
                for (final target in targets.skip(page * 4).take(4))
                  _card(target, () => Navigator.of(sheetContext).pop(target))
              ],
            ),
          )),
          if (targets.length > 4)
            const Padding(
                padding: EdgeInsets.all(12),
                child: Text('Swipe for more views')),
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
    model.removeListener(_changed);
    widget.ffi.ffiModel.removeListener(_changed);
    widget.ffi.qualityMonitorModel.removeListener(_qualityChanged);
    widget.ffi.codexModel.removeListener(_codexChanged);
    _scrollDebounce?.cancel();
    _refreshTimer?.cancel();
    _healthTimer?.cancel();
    _scroll.dispose();
    _monitorFocus.dispose();
    unawaited(model.setPreviews([], [], enabled: false));
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final active = _fullscreen;
    if (active?.instance != null) {
      return Theme(
        data: MirpgRemoteTheme.build(Theme.of(context)),
        child: EmulatorPage(
            ffi: widget.ffi,
            dashboardMode: true,
            onSwitch: _choose,
            onReturn: _dashboard),
      );
    }
    if (active?.display != null) {
      return Theme(
        data: MirpgRemoteTheme.build(Theme.of(context)),
        child: _monitor(active!),
      );
    }
    final pi = widget.ffi.ffiModel.pi;
    final filesAvailable = widget.ffi.ffiModel.permissions['file'] != false;
    final powershellAvailable =
        pi.platform == kPeerPlatformWindows && pi.features.terminal;
    final hostManagementAvailable =
        pi.platform == kPeerPlatformWindows && pi.features.hostManagement;
    final codexAvailable = pi.features.codex;
    final sections = <_ConnectedPcSection>[
      _ConnectedPcSection.devices,
      if (hostManagementAvailable) _ConnectedPcSection.system,
      if (filesAvailable) _ConnectedPcSection.files,
      if (powershellAvailable) _ConnectedPcSection.powershell,
      if (codexAvailable) _ConnectedPcSection.codex,
    ];
    final activeSection =
        sections.contains(_section) ? _section : _ConnectedPcSection.devices;
    final sectionIndex = sections.indexOf(activeSection);
    final connToken = bind.sessionGetConnToken(sessionId: widget.ffi.sessionId);
    final pages = <Widget>[
      _devicesBody(),
      if (hostManagementAvailable)
        _systemOpened
            ? HostManagementPage(
                model: model,
                active: activeSection == _ConnectedPcSection.system,
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
      if (codexAvailable)
        _codexOpened
            ? CodexPage(
                model: widget.ffi.codexModel,
                embedded: true,
                initialThreadId: widget.initialCodexThreadId,
                onWindowsAppOpened: () {
                  if (mounted) {
                    setState(() => _section = _ConnectedPcSection.devices);
                  }
                },
              )
            : const SizedBox.shrink(),
    ];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        handleConnectedPcWorkspaceBack(
          atOverview: activeSection == _ConnectedPcSection.devices,
          onReturnToOverview: () =>
              setState(() => _section = _ConnectedPcSection.devices),
          onStayConnected: _showSessionStillConnected,
        );
      },
      child: Theme(
        data: MirpgRemoteTheme.build(Theme.of(context)),
        child: Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            leadingWidth: 64,
            leading: Padding(
              padding: const EdgeInsets.only(left: 16, top: 8, bottom: 8),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: MirpgRemoteTheme.raised,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: MirpgRemoteTheme.divider),
                ),
                child: const Icon(Icons.computer_outlined,
                    color: MirpgRemoteTheme.accent),
              ),
            ),
            titleSpacing: 10,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.ffi.ffiModel.pi.hostname.isEmpty
                    ? 'Your PC'
                    : widget.ffi.ffiModel.pi.hostname),
                Text(
                  'Connected workspace',
                  style: Theme.of(context).textTheme.labelSmall,
                ),
              ],
            ),
            actions: [
              SessionStatusButton(
                direct: widget.ffi.ffiModel.direct,
                data: widget.ffi.qualityMonitorModel.data,
                now: DateTime.now(),
                onPressed: () => unawaited(_showQualityConnection()),
              ),
              if (activeSection == _ConnectedPcSection.devices)
                IconButton(
                    tooltip: 'Refresh views',
                    icon: const Icon(Icons.refresh),
                    onPressed: model.loading
                        ? null
                        : () {
                            _subscription = '';
                            unawaited(model.refresh());
                          }),
              if (activeSection == _ConnectedPcSection.system)
                IconButton(
                    tooltip: 'Refresh system status',
                    icon: const Icon(Icons.refresh),
                    onPressed: model.hostLoading
                        ? null
                        : () => unawaited(model.refreshHost())),
              ConnectedPcSessionMenu(
                onQualityConnection: () => unawaited(_showQualityConnection()),
                onPrivacyControls: () => unawaited(showPrivacyControlsSheet(
                  context,
                  ffi: widget.ffi,
                )),
                onSettings: _openSettings,
                onEndSession: () =>
                    clientClose(widget.ffi.sessionId, widget.ffi),
              ),
            ],
          ),
          body: IndexedStack(
            index: sectionIndex,
            children: pages,
          ),
          bottomNavigationBar: ConnectedPcTabBar(
            currentIndex: sectionIndex,
            filesAvailable: filesAvailable,
            hostManagementAvailable: hostManagementAvailable,
            powershellAvailable: powershellAvailable,
            codexAvailable: codexAvailable,
            onDestinationSelected: (index) {
              if (index < 0 || index >= sections.length) return;
              final selected = sections[index];
              if (selected == activeSection) return;
              setState(() {
                _section = selected;
                if (selected == _ConnectedPcSection.system) {
                  _systemOpened = true;
                }
                if (selected == _ConnectedPcSection.files) _filesOpened = true;
                if (selected == _ConnectedPcSection.powershell) {
                  _powershellOpened = true;
                }
                if (selected == _ConnectedPcSection.codex) _codexOpened = true;
              });
            },
          ),
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: SettingsPage(),
      ),
    ));
  }

  void _showSessionStillConnected() {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(
        content:
            Text('Session still connected. Use the session menu to end it.'),
        duration: Duration(seconds: 2),
      ));
  }

  Widget _devicesBody() {
    final codexAvailable = widget.ffi.ffiModel.pi.features.codex;
    final codexEntries = codexOverviewEntries(widget.ffi.codexModel);
    final desktopTargets = targets
        .where((target) => target.display != null)
        .toList(growable: false);
    final androidTargets = targets
        .where((target) => target.instance != null)
        .toList(growable: false);
    return Column(children: [
      Expanded(child: LayoutBuilder(builder: (context, box) {
        final columns = box.maxWidth >= 700 ? 2 : 1;
        final width = (box.maxWidth - 32 - (columns - 1) * 16) / columns;
        final cardExtent = math.max(width * 9 / 16 + 84, 236.0);
        final extent = cardExtent + 48;
        if (_viewport != box.maxHeight ||
            _extent != extent ||
            _columns != columns) {
          _viewport = box.maxHeight;
          _extent = extent;
          _columns = columns;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _subscription = '';
            _subscribe();
          });
        }
        final slivers = <Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: MirpgSectionHeader(
                title: 'Overview',
                subtitle: 'Your PC, Android instances and ongoing work',
                trailing: model.loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : null,
              ),
            ),
          ),
          if (model.error.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: MirpgSurface(
                  color: MirpgRemoteTheme.error.withOpacity(0.08),
                  borderColor: MirpgRemoteTheme.error.withOpacity(0.45),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.error_outline,
                          color: MirpgRemoteTheme.error),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Needs your attention',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleSmall
                                    ?.copyWith(color: MirpgRemoteTheme.error)),
                            const SizedBox(height: 4),
                            Text(model.error,
                                style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ];

        void addTargetGroup(
            String title, String subtitle, List<_Target> group) {
          if (group.isEmpty) return;
          slivers.add(SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
              child: MirpgSectionHeader(title: title, subtitle: subtitle),
            ),
          ));
          slivers.add(SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: cardExtent,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
              ),
              delegate: SliverChildBuilderDelegate(
                (_, index) {
                  final target = group[index];
                  return _card(target, () => unawaited(_open(target)));
                },
                childCount: group.length,
              ),
            ),
          ));
        }

        addTargetGroup(
          'Desktop',
          desktopTargets.length == 1
              ? 'Live view of this PC'
              : '${desktopTargets.length} live PC displays',
          desktopTargets,
        );
        addTargetGroup(
          'Android instances',
          androidTargets.length == 1
              ? 'BlueStacks guest'
              : '${androidTargets.length} BlueStacks guests',
          androidTargets,
        );

        if (codexAvailable) {
          slivers.add(SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
            sliver: SliverToBoxAdapter(
              child: SizedBox(
                height: math.max(236, math.min(cardExtent, 320)),
                child: CodexOverviewCard(
                  entries: codexEntries,
                  loading: widget.ffi.codexModel.loadingThreads,
                  error: widget.ffi.codexModel.error,
                  onOpen: () => setState(() {
                    _codexOpened = true;
                    _section = _ConnectedPcSection.codex;
                  }),
                  onRefresh: () => _maybeLoadCodexOverview(force: true),
                ),
              ),
            ),
          ));
        }

        if (targets.isEmpty && !codexAvailable) {
          slivers.add(SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: MirpgSurface(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.devices_outlined,
                          size: 36, color: MirpgRemoteTheme.textSecondary),
                      const SizedBox(height: 12),
                      Text('No views available',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        'Refresh after a Windows display or BlueStacks instance becomes available.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ));
        }

        return CustomScrollView(
          controller: _scroll,
          slivers: slivers,
        );
      })),
    ]);
  }

  Widget _card(_Target target, VoidCallback onOpen) => AnimatedBuilder(
        animation: Listenable.merge([widget.ffi.imageModel, model]),
        builder: (_, __) {
          final preview = model.previews[target.id];
          final activeGuest = _fullscreen?.id == target.id &&
              model.targetId == target.id &&
              model.streaming;
          final channel = target.display ??
              (activeGuest ? model.videoChannel : preview?.channel);
          final image = channel == null
              ? null
              : widget.ffi.imageModel.dashboardImage(channel);
          final stopped = target.instance?.state == 'stopped';
          final live = image != null &&
              (target.display != null ||
                  activeGuest ||
                  preview?.state == 'streaming');
          return TargetPreviewCard(
            name: target.name,
            type: target.display != null
                ? 'Windows'
                : 'Android ${target.instance!.androidVersion}',
            stopped: stopped,
            live: live,
            image: image,
            error: preview?.error ?? target.instance?.error ?? '',
            onOpen: model.connecting ||
                    (target.instance != null &&
                        (!widget.ffi.ffiModel.keyboard ||
                            widget.ffi.ffiModel.viewOnly))
                ? null
                : onOpen,
            onLaunchGame: target.instance?.defaultPackage.isNotEmpty == true &&
                    !model.connecting &&
                    widget.ffi.ffiModel.keyboard &&
                    !widget.ffi.ffiModel.viewOnly
                ? () => unawaited(_open(target, launchDefaultApp: true))
                : null,
            onRetry: () {
              _subscription = '';
              _subscribe();
            },
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
                        onPointer: (action, point) => _queueMonitor(() =>
                            _monitorTouch(action, point, target.display!)),
                        onScroll: (steps) => _queueMonitor(() async {
                          if (_canControlMonitor(target.display!)) {
                            await widget.ffi.inputModel.scroll(steps);
                          }
                        }),
                        onKeyboard: () =>
                            unawaited(_monitorKeyboard(target.display!)),
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
                      );
                    }),
              )),
            ]))),
      );

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

  void _queueMonitor(Future<void> Function() action) {
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
                onKey: (key) => _queueMonitor(() async {
                  if (_canControlMonitor(index)) {
                    await widget.ffi.inputModel
                        .tapHidKey(key.usbHidUsage & 0xFFFF);
                  }
                }),
                onKeyState: (key, down) => _queueMonitor(() async {
                  if (!mounted ||
                      _fullscreen?.display != index ||
                      index < 0 ||
                      index >= widget.ffi.ffiModel.pi.displays.length) {
                    return;
                  }
                  if (down && !_canControlMonitor(index)) return;
                  final hid = key.usbHidUsage & 0xFFFF;
                  if (down) {
                    if (!_monitorHeldKeys.add(hid)) return;
                  } else if (!_monitorHeldKeys.remove(hid)) {
                    return;
                  }
                  widget.ffi.inputModel
                      .newKeyboardMode(kKeyFlutterKey, hid, down, false);
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
    for (final hid in _monitorHeldKeys.toList()) {
      widget.ffi.inputModel.newKeyboardMode(kKeyFlutterKey, hid, false, false);
    }
    _monitorHeldKeys.clear();
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
    required this.codexAvailable,
    required this.onDestinationSelected,
  });

  final int currentIndex;
  final bool filesAvailable;
  final bool hostManagementAvailable;
  final bool powershellAvailable;
  final bool codexAvailable;
  final ValueChanged<int> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.devices_outlined),
        selectedIcon: Icon(Icons.devices_rounded),
        label: 'Overview',
      ),
      if (hostManagementAvailable)
        const NavigationDestination(
          icon: Icon(Icons.monitor_heart_outlined),
          selectedIcon: Icon(Icons.monitor_heart),
          label: 'System',
        ),
      if (filesAvailable)
        const NavigationDestination(
          icon: Icon(Icons.folder_outlined),
          selectedIcon: Icon(Icons.folder_rounded),
          label: 'Files',
        ),
      if (powershellAvailable)
        const NavigationDestination(
          icon: Icon(Icons.terminal_outlined),
          selectedIcon: Icon(Icons.terminal_rounded),
          label: 'Shell',
        ),
      if (codexAvailable)
        const NavigationDestination(
          icon: Icon(Icons.code_outlined),
          selectedIcon: Icon(Icons.code_rounded),
          label: 'Codex',
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

enum _ConnectedPcSessionAction {
  qualityConnection,
  privacyControls,
  settings,
  endSession,
}

class ConnectedPcSessionMenu extends StatelessWidget {
  const ConnectedPcSessionMenu({
    super.key,
    this.onQualityConnection,
    this.onPrivacyControls,
    required this.onSettings,
    required this.onEndSession,
  });

  final VoidCallback? onQualityConnection;
  final VoidCallback? onPrivacyControls;
  final VoidCallback onSettings;
  final VoidCallback onEndSession;

  @override
  Widget build(BuildContext context) =>
      PopupMenuButton<_ConnectedPcSessionAction>(
        tooltip: 'Session menu',
        icon: const Icon(Icons.more_vert),
        onSelected: (action) {
          switch (action) {
            case _ConnectedPcSessionAction.qualityConnection:
              onQualityConnection?.call();
            case _ConnectedPcSessionAction.privacyControls:
              onPrivacyControls?.call();
            case _ConnectedPcSessionAction.settings:
              onSettings();
            case _ConnectedPcSessionAction.endSession:
              onEndSession();
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: _ConnectedPcSessionAction.qualityConnection,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.network_check),
              title: Text('Quality & connection'),
            ),
          ),
          if (onPrivacyControls != null)
            const PopupMenuItem(
              value: _ConnectedPcSessionAction.privacyControls,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.privacy_tip_outlined),
                title: Text('Privacy & host controls'),
              ),
            ),
          const PopupMenuItem(
            value: _ConnectedPcSessionAction.settings,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.settings_outlined),
              title: Text('App settings'),
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: _ConnectedPcSessionAction.endSession,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout),
              title: Text('End session'),
            ),
          ),
        ],
      );
}

class CodexOverviewEntry {
  const CodexOverviewEntry({
    required this.thread,
    required this.label,
    required this.icon,
    required this.tone,
    required this.priority,
  });

  final CodexThread thread;
  final String label;
  final IconData icon;
  final MirpgStatusTone tone;
  final int priority;
}

List<CodexOverviewEntry> codexOverviewEntries(CodexModel model, {int? limit}) {
  final entries = <CodexOverviewEntry>[];
  for (final thread in model.threads) {
    final state = thread.state.toLowerCase();
    final originator = thread.originator.toLowerCase().replaceAll('_', ' ');
    if (state == 'resumable' && originator.contains('codex desktop')) {
      continue;
    }

    if (state == 'waiting_for_approval' || state == 'waiting_for_input') {
      entries.add(CodexOverviewEntry(
        thread: thread,
        label: 'Needs you',
        icon: Icons.notification_important_outlined,
        tone: MirpgStatusTone.warning,
        priority: 0,
      ));
    } else if (model.activeTurnIdFor(thread.id).isNotEmpty ||
        state == 'working' ||
        state == 'starting' ||
        state == 'interrupting') {
      entries.add(CodexOverviewEntry(
        thread: thread,
        label: 'Running',
        icon: Icons.pending_outlined,
        tone: MirpgStatusTone.good,
        priority: 1,
      ));
    } else {
      entries.add(CodexOverviewEntry(
        thread: thread,
        label: 'Review',
        icon: state == 'failed'
            ? Icons.error_outline_rounded
            : Icons.rate_review_outlined,
        tone:
            state == 'failed' ? MirpgStatusTone.error : MirpgStatusTone.neutral,
        priority: 2,
      ));
    }
  }
  entries.sort((a, b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    final byUpdated = b.thread.updatedAt.compareTo(a.thread.updatedAt);
    return byUpdated != 0 ? byUpdated : a.thread.id.compareTo(b.thread.id);
  });
  if (limit == null) return List.unmodifiable(entries);
  return entries.take(math.max(0, limit)).toList(growable: false);
}

class CodexOverviewCard extends StatelessWidget {
  const CodexOverviewCard({
    super.key,
    required this.entries,
    required this.loading,
    required this.error,
    required this.onOpen,
    required this.onRefresh,
  });

  final List<CodexOverviewEntry> entries;
  final bool loading;
  final String error;
  final VoidCallback onOpen;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final largeText = MediaQuery.textScalerOf(context).scale(16) >= 24;
    if (largeText) {
      final entry = entries.isEmpty ? null : entries.first;
      return MirpgSurface(
        key: const ValueKey('codex-overview-card'),
        color: MirpgRemoteTheme.raised,
        borderColor: MirpgRemoteTheme.outline,
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('Ongoing work',
                      style: Theme.of(context).textTheme.titleMedium),
                ),
                if (loading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: entry != null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CodexOverviewRow(entry: entry, showProject: false),
                        if (entries.length > 1)
                          Text(
                            '+${entries.length - 1} more in Codex',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelMedium,
                          ),
                      ],
                    )
                  : Center(
                      child: Text(
                        error.isNotEmpty
                            ? error
                            : loading
                                ? 'Checking for active tasks…'
                                : 'No ongoing Codex work',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: error.isNotEmpty
                                ? MirpgRemoteTheme.error
                                : null),
                      ),
                    ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                  onPressed: onOpen, child: const Text('Open Codex')),
            ),
          ],
        ),
      );
    }
    final visibleEntries = entries.take(largeText ? 1 : 2).toList();
    final hiddenCount = entries.length - visibleEntries.length;
    final title = Row(
      children: [
        const Icon(Icons.code_rounded, color: MirpgRemoteTheme.accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Ongoing work',
              style: Theme.of(context).textTheme.titleMedium),
        ),
        if (loading)
          const SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
      ],
    );
    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: 'Refresh Codex work',
          onPressed: loading ? null : onRefresh,
          icon: const Icon(Icons.refresh),
        ),
        TextButton(onPressed: onOpen, child: const Text('Open Codex')),
      ],
    );

    return MirpgSurface(
      key: const ValueKey('codex-overview-card'),
      color: MirpgRemoteTheme.raised,
      borderColor: MirpgRemoteTheme.outline,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (largeText) ...[
            title,
            Align(alignment: Alignment.centerRight, child: actions),
          ] else
            Row(children: [Expanded(child: title), actions]),
          const SizedBox(height: 4),
          Text(
            'Codex tasks on this PC',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: MirpgRemoteTheme.textSecondary),
          ),
          const SizedBox(height: 8),
          if (error.isNotEmpty && entries.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  error,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: MirpgRemoteTheme.error),
                ),
              ),
            )
          else if (entries.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  loading
                      ? 'Checking for active tasks…'
                      : 'No ongoing Codex work',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            )
          else ...[
            for (var i = 0; i < visibleEntries.length; i++) ...[
              if (i > 0) const Divider(),
              _CodexOverviewRow(entry: visibleEntries[i]),
            ],
            if (hiddenCount > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '+$hiddenCount more in Codex',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _CodexOverviewRow extends StatelessWidget {
  const _CodexOverviewRow({
    required this.entry,
    this.showProject = true,
  });

  final CodexOverviewEntry entry;
  final bool showProject;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
        constraints:
            const BoxConstraints(minHeight: MirpgRemoteTheme.minTouchTarget),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.thread.title.isEmpty
                          ? 'Codex task'
                          : entry.thread.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (showProject && entry.thread.project.isNotEmpty)
                      Text(
                        entry.thread.project,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              MirpgStatusChip(
                label: entry.label,
                icon: entry.icon,
                tone: entry.tone,
              ),
            ],
          ),
        ),
      );
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

class TargetPreviewCard extends StatelessWidget {
  const TargetPreviewCard(
      {super.key,
      required this.name,
      required this.type,
      required this.stopped,
      required this.live,
      this.image,
      this.error = '',
      this.onOpen,
      this.onLaunchGame,
      this.onRetry});
  final String name;
  final String type;
  final bool stopped;
  final bool live;
  final ui.Image? image;
  final String error;
  final VoidCallback? onOpen;
  final VoidCallback? onLaunchGame;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final stateLabel = stopped
        ? 'Stopped'
        : live
            ? 'Live'
            : error.isNotEmpty
                ? 'Attention'
                : 'Connecting';
    final stateTone = stopped
        ? MirpgStatusTone.neutral
        : live
            ? MirpgStatusTone.good
            : error.isNotEmpty
                ? MirpgStatusTone.error
                : MirpgStatusTone.warning;

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Column(
          children: [
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (image != null)
                      RawImage(
                        image: image,
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.low,
                      ),
                    if (image == null && !stopped && error.isEmpty)
                      const Center(
                        child: Icon(Icons.live_tv_outlined,
                            color: Color(0xFF69757A), size: 38),
                      ),
                    if (stopped)
                      Center(
                        child: FilledButton.icon(
                          onPressed: onOpen,
                          icon: const Icon(Icons.power_settings_new_rounded),
                          label: const Text('Boot'),
                        ),
                      )
                    else if (error.isNotEmpty)
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: SingleChildScrollView(
                            child: MirpgSurface(
                              padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
                              color:
                                  MirpgRemoteTheme.background.withOpacity(0.90),
                              borderColor:
                                  MirpgRemoteTheme.error.withOpacity(0.45),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    error,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style:
                                        Theme.of(context).textTheme.bodySmall,
                                  ),
                                  TextButton(
                                    onPressed: onRetry,
                                    child: const Text('Retry preview'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 10,
                      top: 10,
                      child: MirpgStatusChip(
                        label: type,
                        icon: type == 'Windows'
                            ? Icons.desktop_windows_outlined
                            : Icons.android_outlined,
                      ),
                    ),
                    Positioned(
                      right: 10,
                      top: 10,
                      child: MirpgStatusChip(
                        label: stateLabel,
                        icon: live ? Icons.circle : null,
                        tone: stateTone,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          stopped
                              ? 'Ready to boot'
                              : live
                                  ? 'Tap to control'
                                  : 'Waiting for a usable preview',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (onLaunchGame != null)
                    TextButton.icon(
                      onPressed: onLaunchGame,
                      icon: const Icon(Icons.sports_esports_outlined, size: 18),
                      label: const Text('Launch game'),
                    ),
                  if (!stopped)
                    TextButton.icon(
                      onPressed: onOpen,
                      icon: Icon(type == 'Windows'
                          ? Icons.open_in_full_rounded
                          : Icons.play_arrow_rounded),
                      label: Text(type == 'Windows' ? 'Open' : 'Resume'),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
