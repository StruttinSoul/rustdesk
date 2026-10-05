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
import '../../models/emulator_model.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import 'codex_page.dart';
import 'emulator_page.dart';
import 'file_manager_page.dart';
import 'host_management_page.dart';
import 'settings_page.dart';
import 'terminal_page.dart';
import '../widgets/mirpg_remote_theme.dart';
import '../widgets/monitor_control_view.dart';
import '../widgets/monitor_session_continuity.dart';
import '../widgets/session_quality_panel.dart';

enum _ConnectedPcSection { devices, system, files, powershell, codex }

class TargetDashboardPage extends StatefulWidget {
  const TargetDashboardPage({super.key, required this.ffi});
  final FFI ffi;

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
  bool _monitorDown = false;
  bool _monitorRightDown = false;
  bool _monitorLocalViewOnly = false;
  final MonitorInputEpoch _monitorInputEpoch = MonitorInputEpoch();
  final Set<int> _monitorHeldKeys = <int>{};
  final Map<int, String> _monitorDrafts = <int, String>{};
  final Map<int, MonitorControlPreferences> _monitorPreferences =
      <int, MonitorControlPreferences>{};
  Future<void> _monitorEvents = Future.value();
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
      _landscape = null;
      _presentation();
    }
  }

  List<_Target> get targets => [
        for (final instance in model.instances)
          if (instance.provider == 'bluestacks') _Target.guest(instance),
        for (var i = 0; i < widget.ffi.ffiModel.pi.displays.length; i++)
          _Target.monitor(i),
      ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    model.addListener(_changed);
    widget.ffi.ffiModel.addListener(_changed);
    widget.ffi.qualityMonitorModel.addListener(_qualityChanged);
    _peerInfoGeneration = widget.ffi.ffiModel.peerInfoGeneration;
    _reconnectGeneration = widget.ffi.ffiModel.reconnectGeneration;
    _scroll.addListener(_scrolled);
    unawaited(model.refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_background && !model.loading && !model.connecting) {
        unawaited(model.refresh());
      }
    });
    _healthTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted &&
          !_background &&
          widget.ffi.qualityMonitorModel.data.latestUpdatedAt != null) {
        setState(() {});
      }
    });
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _subscribe();
      unawaited(_loadQualityProfile());
    });
  }

  void _qualityChanged() {
    if (mounted) setState(() {});
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
        _subscription = '';
      }
    }
    final peerInfoGeneration = widget.ffi.ffiModel.peerInfoGeneration;
    if (peerInfoGeneration != _peerInfoGeneration) {
      _peerInfoGeneration = peerInfoGeneration;
      model.invalidatePreviewAcknowledgement();
      if (_hasStoredQualityPreference) {
        unawaited(_applyQualityProfile(_qualityProfile, persist: false));
      }
      if (_fullscreen?.display != null) {
        unawaited(_releaseMonitorInput());
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

  Future<void> _open(_Target target) async {
    if (model.connecting) return;
    await _releaseMonitorInput();
    setState(() => _fullscreen = target);
    _subscription = '';
    _subscribe();
    if (target.display != null) {
      await model.desktop();
    } else {
      await model.connect(target.id,
          launchDefaultApp: target.instance!.defaultPackage.isNotEmpty);
    }
    _presentation();
  }

  Future<void> _dashboard() async {
    await _releaseMonitorInput();
    await model.desktop();
    if (!mounted) return;
    setState(() => _fullscreen = null);
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
      return EmulatorPage(
          ffi: widget.ffi,
          dashboardMode: true,
          onSwitch: _choose,
          onReturn: _dashboard);
    }
    if (active?.display != null) return _monitor(active!);
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
            leading: const Icon(Icons.computer_outlined),
            title: Text(widget.ffi.ffiModel.pi.hostname.isEmpty
                ? 'Your PC'
                : widget.ffi.ffiModel.pi.hostname),
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

  Widget _devicesBody() => Column(children: [
        if (model.error.isNotEmpty)
          Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(model.error,
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.error))),
        if (model.loading) const LinearProgressIndicator(),
        Expanded(child: LayoutBuilder(builder: (context, box) {
          final columns = box.maxWidth >= 700 ? 2 : 1;
          final width = (box.maxWidth - 32 - (columns - 1) * 16) / columns;
          final extent = math.max(
              width * 9 / 16 + 64, box.maxHeight / (columns == 1 ? 3 : 1));
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
          if (targets.isEmpty) {
            return const Center(
                child: Text(
                    'No views are available. Refresh after opening BlueStacks on the PC.'));
          }
          return GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(16),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                mainAxisExtent: extent,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16),
            itemCount: targets.length,
            itemBuilder: (_, index) =>
                _card(targets[index], () => unawaited(_open(targets[index]))),
          );
        })),
      ]);

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
                      return MonitorControlView(
                        key: ValueKey(
                            '${target.id}:${display.width}x${display.height}'),
                        desktopSize: Size(display.width.toDouble(),
                            display.height.toDouble()),
                        image: image,
                        canControl: image != null &&
                            _hostCanControlMonitor(target.display!),
                        frameStatus: frameStatus,
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

  bool _hostCanControlMonitor(int index) =>
      mounted &&
      !_background &&
      _fullscreen?.display == index &&
      !model.selected &&
      !model.connecting &&
      widget.ffi.ffiModel.keyboard &&
      !widget.ffi.ffiModel.viewOnly &&
      index >= 0 &&
      index < widget.ffi.ffiModel.pi.displays.length &&
      _monitorFrameIsCurrent(index);

  bool _monitorFrameIsCurrent(int index) => monitorFrameIsCurrent(
        previewRequest: model.previewRequest,
        acknowledgedRequest: model.previewAcknowledgedRequest,
        frameRequest: widget.ffi.imageModel.dashboardImagePreviewRequest(index),
      );

  String? _monitorFrameStatus(int index, ui.Image? image) {
    if (_monitorFrameIsCurrent(index)) return null;
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

enum _ConnectedPcSessionAction { qualityConnection, settings, endSession }

class ConnectedPcSessionMenu extends StatelessWidget {
  const ConnectedPcSessionMenu({
    super.key,
    this.onQualityConnection,
    required this.onSettings,
    required this.onEndSession,
  });

  final VoidCallback? onQualityConnection;
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
            case _ConnectedPcSessionAction.settings:
              onSettings();
            case _ConnectedPcSessionAction.endSession:
              onEndSession();
          }
        },
        itemBuilder: (context) => const [
          PopupMenuItem(
            value: _ConnectedPcSessionAction.qualityConnection,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.network_check),
              title: Text('Quality & connection'),
            ),
          ),
          PopupMenuItem(
            value: _ConnectedPcSessionAction.settings,
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.settings_outlined),
              title: Text('App settings'),
            ),
          ),
          PopupMenuDivider(),
          PopupMenuItem(
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
      this.onRetry});
  final String name;
  final String type;
  final bool stopped;
  final bool live;
  final ui.Image? image;
  final String error;
  final VoidCallback? onOpen;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
            onTap: onOpen,
            child: Column(children: [
              Expanded(
                  child: ColoredBox(
                      color: Colors.black,
                      child: Stack(fit: StackFit.expand, children: [
                        if (image != null)
                          RawImage(
                              image: image,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.low),
                        if (stopped)
                          Center(
                              child: FilledButton.icon(
                                  onPressed: onOpen,
                                  icon: const Icon(Icons.power_settings_new),
                                  label: const Text('Boot')))
                        else if (error.isNotEmpty)
                          Center(
                              child: Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: SingleChildScrollView(
                                      child: Column(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                        Text(error,
                                            maxLines: 3,
                                            overflow: TextOverflow.ellipsis,
                                            textAlign: TextAlign.center,
                                            style: const TextStyle(
                                                color: Colors.white)),
                                        TextButton(
                                            onPressed: onRetry,
                                            child: const Text('Retry preview')),
                                      ]))))
                        else if (image == null)
                          const Center(
                              child: Icon(Icons.live_tv_outlined,
                                  color: Colors.white54, size: 40)),
                        Positioned(
                            right: 8,
                            top: 8,
                            child: DecoratedBox(
                                decoration: BoxDecoration(
                                    color: Colors.black87,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Padding(
                                    padding: const EdgeInsets.all(8),
                                    child: Text(live ? '$type · Live' : type,
                                        style: const TextStyle(
                                            color: Colors.white))))),
                      ]))),
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(children: [
                    Expanded(
                        child: Text(name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium)),
                    if (!stopped)
                      IconButton(
                          tooltip: 'Open $name',
                          onPressed: onOpen,
                          icon: const Icon(Icons.open_in_full)),
                  ])),
            ])),
      );
}
