import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../consts.dart' show kPeerPlatformLinux, kPeerPlatformWindows;
import '../../models/platform_model.dart' show bind;
import '../../models/emulator_model.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import 'codex_page.dart';
import 'emulator_page.dart';
import 'file_manager_page.dart';
import 'host_management_page.dart';
import 'terminal_page.dart';
import '../widgets/monitor_control_view.dart';

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
  _Target? _fullscreen;
  bool _chooser = false;
  bool _background = false;
  bool _leaving = false;
  bool _monitorDown = false;
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
  EmulatorModel get model => widget.ffi.emulatorModel;

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
    _scroll.addListener(_scrolled);
    unawaited(model.refresh());
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!_background && !_leaving && !model.loading && !model.connecting) {
        unawaited(model.refresh());
      }
    });
    unawaited(SystemChrome.setPreferredOrientations(const []));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    WidgetsBinding.instance.addPostFrameCallback((_) => _subscribe());
  }

  void _changed() {
    if (!mounted || _leaving) return;
    if (_monitorDown &&
        (!widget.ffi.ffiModel.keyboard || widget.ffi.ffiModel.viewOnly)) {
      unawaited(_releaseMonitor());
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
    if (_background) unawaited(_releaseMonitor());
    _subscription = '';
    _subscribe();
  }

  void _subscribe() {
    if (!mounted || _leaving) return;
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
      for (final preview in model.previews.values) preview.channel,
      if (model.selected && model.guestSessionId != 0) model.videoChannel,
    });
  }

  Future<void> _open(_Target target) async {
    if (_leaving || model.connecting) return;
    await _releaseMonitor();
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
    await _releaseMonitor();
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
    final landscape = width > height;
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
    await _releaseMonitor();
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

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    await _releaseMonitor();
    await model.desktop();
    await model.setPreviews([], [], enabled: false);
    widget.ffi.imageModel.retainDashboardImages({});
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    model.removeListener(_changed);
    widget.ffi.ffiModel.removeListener(_changed);
    _scrollDebounce?.cancel();
    _refreshTimer?.cancel();
    _scroll.dispose();
    _monitorFocus.dispose();
    if (!_leaving) unawaited(model.setPreviews([], [], enabled: false));
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
    final connToken =
        bind.sessionGetConnToken(sessionId: widget.ffi.sessionId);
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
      canPop: _leaving,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (activeSection != _ConnectedPcSection.devices) {
          setState(() => _section = _ConnectedPcSection.devices);
          return;
        }
        unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.ffi.ffiModel.pi.hostname.isEmpty
              ? 'Your PC'
              : widget.ffi.ffiModel.pi.hostname),
          leading: IconButton(
              tooltip: 'Return to desktop',
              icon: const Icon(Icons.close),
              onPressed: () => unawaited(_leave())),
          actions: [
            Center(
                child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(widget.ffi.ffiModel.direct == null
                        ? 'Connecting'
                        : widget.ffi.ffiModel.direct!
                            ? 'Direct'
                            : 'Relay'))),
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
              if (selected == _ConnectedPcSection.system) _systemOpened = true;
              if (selected == _ConnectedPcSection.files) _filesOpened = true;
              if (selected == _ConnectedPcSection.powershell) {
                _powershellOpened = true;
              }
              if (selected == _ConnectedPcSection.codex) _codexOpened = true;
            });
          },
        ),
      ),
    );
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
                  if (!model.selected &&
                      !model.connecting &&
                      widget.ffi.ffiModel.keyboard &&
                      !widget.ffi.ffiModel.viewOnly) {
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
                      return MonitorControlView(
                        key: ValueKey(
                            '${target.id}:${display.width}x${display.height}'),
                        desktopSize: Size(display.width.toDouble(),
                            display.height.toDouble()),
                        image: image,
                        canControl: image != null &&
                            _canControlMonitor(target.display!),
                        onPointer: (action, point) => _queueMonitor(() =>
                            _monitorTouch(action, point, target.display!)),
                        onScroll: (steps) => _queueMonitor(() async {
                          if (_canControlMonitor(target.display!)) {
                            await widget.ffi.inputModel.scroll(steps);
                          }
                        }),
                        onKeyboard: () =>
                            unawaited(_monitorKeyboard(target.display!)),
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
              Positioned(
                  left: 8,
                  top: 0,
                  bottom: 0,
                  child: Center(
                      child: Material(
                          color: Colors.black87,
                          elevation: 8,
                          borderRadius: BorderRadius.circular(16),
                          child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                        tooltip: 'Switch view',
                                        color: Colors.white,
                                        icon: const Icon(
                                            Icons.view_agenda_outlined),
                                        onPressed: () => unawaited(_choose())),
                                    IconButton(
                                        tooltip: 'Dashboard',
                                        color: Colors.white,
                                        icon: const Icon(
                                            Icons.grid_view_outlined),
                                        onPressed: () =>
                                            unawaited(_dashboard())),
                                  ]))))),
            ]))),
      );

  bool _canControlMonitor(int index) =>
      mounted &&
      !_background &&
      _fullscreen?.display == index &&
      !model.selected &&
      !model.connecting &&
      widget.ffi.ffiModel.keyboard &&
      !widget.ffi.ffiModel.viewOnly &&
      index >= 0 &&
      index < widget.ffi.ffiModel.pi.displays.length;

  Future<void> _monitorTouch(int action, Offset point, int index) async {
    if (!_canControlMonitor(index) || (action == 1 && !_monitorDown)) return;
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
    }
  }

  void _queueMonitor(Future<void> Function() action) {
    _monitorEvents =
        _monitorEvents.then((_) => action()).catchError((Object error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Monitor input failed: $error')));
      }
    });
  }

  Future<void> _monitorKeyboard(int index) async {
    await _releaseMonitor();
    if (!_canControlMonitor(index)) return;
    await widget.ffi.invokeMethod('enable_soft_keyboard', true);
    try {
      if (!_canControlMonitor(index)) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          builder: (_) => MonitorKeyboardPanel(
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
              ));
    } finally {
      await widget.ffi.invokeMethod('enable_soft_keyboard', false);
      if (mounted) _monitorFocus.requestFocus();
    }
  }

  Future<void> _releaseMonitor() async {
    await _monitorEvents;
    if (!_monitorDown) return;
    _monitorDown = false;
    await widget.ffi.inputModel.tapUp(MouseButtons.left);
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
        label: 'Devices',
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
          label: 'PowerShell',
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
