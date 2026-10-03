import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'host_management_model.dart';
import 'platform_model.dart';

typedef EmulatorCommandSender = Future<void> Function(String key, String value);

({int x, int y})? mapEmulatorTouch({
  required double localX,
  required double localY,
  required double viewportWidth,
  required double viewportHeight,
  required int guestWidth,
  required int guestHeight,
  bool clampToFrame = false,
}) {
  if (viewportWidth <= 0 ||
      viewportHeight <= 0 ||
      guestWidth <= 0 ||
      guestHeight <= 0) return null;
  final scale =
      math.min(viewportWidth / guestWidth, viewportHeight / guestHeight);
  final renderedWidth = guestWidth * scale;
  final renderedHeight = guestHeight * scale;
  final left = (viewportWidth - renderedWidth) / 2;
  final top = (viewportHeight - renderedHeight) / 2;
  final right = left + renderedWidth;
  final bottom = top + renderedHeight;
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

class RemoteEmulator {
  const RemoteEmulator(
      {required this.id,
      required this.name,
      required this.provider,
      required this.state,
      this.androidVersion = '',
      this.defaultPackage = '',
      this.error = ''});
  final String id;
  final String name;
  final String provider;
  final String state;
  final String androidVersion;
  final String defaultPackage;
  final String error;
}

class EmulatorModel extends ChangeNotifier {
  EmulatorModel(this.sessionId, {EmulatorCommandSender? commandSender})
      : _sender = commandSender ??
            ((key, value) => bind.sessionSetCommon(
                sessionId: sessionId, key: key, value: value));
  final UuidValue sessionId;
  final EmulatorCommandSender _sender;
  Future<void> _outbound = Future.value();
  int _sequence = 0;
  int _inventoryRequest = 0;
  int _selectionRequest = 0;
  int _desktopRequest = 0;
  Timer? _selectionTimeout;
  Timer? _inventoryTimeout;
  Timer? _desktopTimeout;
  bool _disposed = false;
  List<RemoteEmulator> instances = [];
  bool loading = false;
  bool selected = false;
  bool streaming = false;
  int guestSessionId = 0;
  int width = 0;
  int height = 0;
  String error = '';
  String targetId = '';
  bool connecting = false;
  bool dashboardSupported = false;
  bool dashboardActive = false;
  int _previewRequest = 0;
  int _hostRequest = 0;
  Set<String> _previewTargets = {};
  final Map<String, RemotePreview> previews = {};
  HostSystemSnapshot? hostSnapshot;
  bool hostLoading = false;
  String hostError = '';
  String hostMessage = '';
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
      error = failure.toString();
      connecting = false;
      loading = false;
      notifyListeners();
    });
    return _outbound;
  }

  Future<void> refresh() {
    loading = true;
    error = '';
    _inventoryRequest = ++_sequence;
    _inventoryTimeout?.cancel();
    _inventoryTimeout = Timer(const Duration(seconds: 25), () {
      loading = false;
      error = 'The PC did not return its emulator list. Refresh to try again.';
      notifyListeners();
    });
    notifyListeners();
    return _send({'action': 'list', 'request_id': _inventoryRequest});
  }

  Future<void> connect(String targetId, {bool launchDefaultApp = false}) {
    if (connecting) return Future.value();
    connecting = true;
    streaming = false;
    guestSessionId = 0;
    width = height = 0;
    error = '';
    _selectionRequest = ++_sequence;
    _selectionTimeout?.cancel();
    _selectionTimeout = Timer(const Duration(seconds: 120), () {
      connecting = false;
      error =
          'The emulator did not become ready. Return to the desktop or reconnect.';
      notifyListeners();
    });
    notifyListeners();
    return _send({
      'action': 'select',
      'request_id': _selectionRequest,
      'target_id': targetId,
      'start_if_stopped': true,
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
    if (!streaming || !['back', 'home', 'recents'].contains(action)) {
      return Future.value();
    }
    return _send({
      'action': 'navigation',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'navigation': action
    });
  }

  Future<void> touch(int action, int pointer, int x, int y) {
    if (!streaming ||
        action < 0 ||
        action > 3 ||
        x < 0 ||
        y < 0 ||
        x >= width ||
        y >= height) return Future.value();
    return _send({
      'action': 'touch',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'touch_action': action,
      'pointer_id': pointer,
      'x': x,
      'y': y,
      'width': width,
      'height': height
    });
  }

  Future<void> key(int keycode, bool down) {
    if (!streaming || keycode < 1 || keycode > 288) return Future.value();
    return _send({
      'action': 'key',
      'request_id': ++_sequence,
      'session_id': guestSessionId,
      'keycode': keycode,
      'down': down
    });
  }

  Future<void> refreshHost() {
    hostLoading = true;
    hostError = '';
    _hostRequest = ++_sequence;
    notifyListeners();
    return _send({'action': 'host_status', 'request_id': _hostRequest});
  }

  Future<void> endProcess(int pid) {
    hostLoading = true;
    hostError = '';
    hostMessage = '';
    _hostRequest = ++_sequence;
    notifyListeners();
    return _send({
      'action': 'process_end',
      'request_id': _hostRequest,
      'pid': pid,
    });
  }

  Future<void> recoverComponent(String component) {
    hostLoading = true;
    hostError = '';
    hostMessage = '';
    _hostRequest = ++_sequence;
    notifyListeners();
    return _send({
      'action': 'recover',
      'request_id': _hostRequest,
      'component': component,
    });
  }

  void handleResponse(Map<String, dynamic> response) {
    if (_disposed || response['protocol_version'] != 1) return;
    final id = response['request_id'];
    if (response['type'] == 'host' && id == _hostRequest) {
      hostLoading = false;
      final host = response['host'];
      if (host is! Map) {
        hostError = 'The PC returned an invalid system response.';
      } else if (host['ok'] != true) {
        hostError =
            host['error']?.toString() ?? 'Host management request failed';
      } else if (host['snapshot'] is Map) {
        hostSnapshot = HostSystemSnapshot.fromMap(host['snapshot'] as Map);
        hostMessage = host['message']?.toString() ?? '';
        hostError = '';
      }
    } else if (response['type'] == 'inventory' && id == _inventoryRequest) {
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
              error: item['last_error']?.toString() ?? ''))
          .toList();
      loading = false;
      error = (response['provider_errors'] as List? ?? []).join('\n');
    } else if (response['type'] == 'previews' && id == _previewRequest) {
      dashboardActive = response['enabled'] == true;
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
          guestSessionId = width = height = 0;
          targetId = error = '';
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
        guestSessionId = response['session_id'] as int? ?? 0;
        targetId = response['target_id']?.toString() ?? '';
        selected = guestSessionId != 0;
        streaming = false;
        width = height = 0;
      } else if (state == 'streaming' &&
          response['session_id'] == guestSessionId) {
        final w = response['width'] as int? ?? 0;
        final h = response['height'] as int? ?? 0;
        if (w < 1 || h < 1 || w > 1280 || h > 1280) return;
        width = w;
        height = h;
        streaming = true;
        connecting = false;
        _selectionTimeout?.cancel();
      } else if (state == 'failed' &&
          response['session_id'] == guestSessionId) {
        error = response['error']?.toString() ?? 'Guest connection failed';
        streaming = false;
        connecting = false;
        _selectionTimeout?.cancel();
      } else {
        return;
      }
    } else if (response['type'] == 'error' &&
        [
          _inventoryRequest,
          _selectionRequest,
          _desktopRequest,
          _previewRequest,
          _hostRequest
        ].contains(id)) {
      final requestError =
          response['error']?.toString() ?? 'Remote request failed';
      if (id == _hostRequest) {
        hostLoading = false;
        hostError = requestError;
      } else {
        error = requestError;
      }
      if (id == _inventoryRequest) {
        loading = false;
        _inventoryTimeout?.cancel();
      }
      if (id == _selectionRequest) {
        connecting = false;
        _selectionTimeout?.cancel();
      }
    } else {
      return;
    }
    notifyListeners();
  }

  void reset() {
    _selectionTimeout?.cancel();
    _inventoryTimeout?.cancel();
    _desktopTimeout?.cancel();
    selected = streaming = connecting = loading = false;
    guestSessionId = width = height = 0;
    targetId = error = '';
    dashboardActive = false;
    hostLoading = false;
    hostSnapshot = null;
    hostError = hostMessage = '';
    previews.clear();
    _previewTargets.clear();
    _selectionRequest = _desktopRequest = _inventoryRequest = _hostRequest = 0;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _selectionTimeout?.cancel();
    _inventoryTimeout?.cancel();
    _desktopTimeout?.cancel();
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
