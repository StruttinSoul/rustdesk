bool monitorFrameIsCurrent({
  required int previewRequest,
  required int acknowledgedRequest,
  required int? frameRequest,
}) =>
    previewRequest != 0 &&
    acknowledgedRequest == previewRequest &&
    frameRequest == previewRequest;

// Empirical safety defaults for WP2, chosen around the normal one-second
// heartbeat cadence. They are engineering thresholds, not user-approved UX
// timings, and can be tuned from runtime evidence without changing semantics.
const Duration monitorTransportHeartbeatStaleAfter = Duration(seconds: 6);
const Duration monitorStreamHeartbeatStaleAfter = Duration(seconds: 4);

enum MonitorInputBlockReason {
  none,
  background,
  viewOnly,
  hostPermission,
  transportStale,
  decoderNotReady,
  decoderFailed,
  streamStale,
  frameNotReady,
}

class MonitorSessionLiveness {
  int _generation = 0;
  String _targetIdentity = '';
  bool _requireStreamHeartbeat = false;
  DateTime? _transportHeartbeatAt;
  DateTime? _streamHeartbeatAt;
  DateTime? _frameAt;
  int? _frameGeneration;
  String? _frameTargetIdentity;
  bool? _decoderHealthy;
  DateTime? _decoderUpdatedAt;

  int get generation => _generation;
  String get targetIdentity => _targetIdentity;
  DateTime? get frameUpdatedAt => _frameAt;
  DateTime? get transportHeartbeatAt => _transportHeartbeatAt;
  DateTime? get streamHeartbeatAt => _streamHeartbeatAt;
  bool? get decoderHealthy => _decoderHealthy;
  DateTime? get decoderUpdatedAt => _decoderUpdatedAt;

  void begin({
    required int generation,
    required String targetIdentity,
    required bool requireStreamHeartbeat,
  }) {
    _generation = generation;
    _targetIdentity = targetIdentity;
    _requireStreamHeartbeat = requireStreamHeartbeat;
    _transportHeartbeatAt = null;
    _streamHeartbeatAt = null;
    _frameAt = null;
    _frameGeneration = null;
    _frameTargetIdentity = null;
    _decoderHealthy = null;
    _decoderUpdatedAt = null;
  }

  bool noteTransportHeartbeat({
    required int generation,
    required DateTime at,
  }) {
    if (generation != _generation) return false;
    _transportHeartbeatAt = at;
    return true;
  }

  bool noteStreamHeartbeat({
    required int generation,
    required String targetIdentity,
    required DateTime at,
  }) {
    if (!_matches(generation, targetIdentity)) return false;
    _streamHeartbeatAt = at;
    return true;
  }

  bool noteDecoderHealth({
    required int generation,
    required String targetIdentity,
    required bool healthy,
    required DateTime at,
  }) {
    if (!_matches(generation, targetIdentity)) return false;
    _decoderHealthy = healthy;
    _decoderUpdatedAt = at;
    return true;
  }

  bool noteFrame({
    required int generation,
    required String targetIdentity,
    required DateTime at,
  }) {
    if (!_matches(generation, targetIdentity)) return false;
    final firstCurrentFrame = _frameGeneration != generation ||
        _frameTargetIdentity != targetIdentity ||
        _frameAt == null;
    if (firstCurrentFrame &&
        _requireStreamHeartbeat &&
        _streamHeartbeatAt?.isBefore(at) == true) {
      // A heartbeat received before this generation's first decoded frame can
      // belong to the previous preview/capture boundary. Require one heartbeat
      // at or after the first current frame before input is enabled.
      _streamHeartbeatAt = null;
    }
    _frameGeneration = generation;
    _frameTargetIdentity = targetIdentity;
    _frameAt = at;
    return true;
  }

  Duration? frameAge(DateTime now) {
    final at = _frameAt;
    if (at == null) return null;
    final age = now.difference(at);
    return age.isNegative ? Duration.zero : age;
  }

  MonitorInputBlockReason blockReason(
    DateTime now, {
    bool hostPermission = true,
    bool viewOnly = false,
    bool background = false,
  }) {
    if (background) return MonitorInputBlockReason.background;
    if (viewOnly) return MonitorInputBlockReason.viewOnly;
    if (!hostPermission) return MonitorInputBlockReason.hostPermission;
    if (!_fresh(
        _transportHeartbeatAt, now, monitorTransportHeartbeatStaleAfter)) {
      return MonitorInputBlockReason.transportStale;
    }
    if (_decoderHealthy == null) {
      return MonitorInputBlockReason.decoderNotReady;
    }
    if (_decoderHealthy == false) {
      return MonitorInputBlockReason.decoderFailed;
    }
    if (_requireStreamHeartbeat &&
        !_fresh(_streamHeartbeatAt, now, monitorStreamHeartbeatStaleAfter)) {
      return MonitorInputBlockReason.streamStale;
    }
    if (_frameGeneration != _generation ||
        _frameTargetIdentity != _targetIdentity ||
        _frameAt == null) {
      return MonitorInputBlockReason.frameNotReady;
    }
    return MonitorInputBlockReason.none;
  }

  bool canSendInput(
    DateTime now, {
    bool hostPermission = true,
    bool viewOnly = false,
    bool background = false,
  }) =>
      blockReason(
        now,
        hostPermission: hostPermission,
        viewOnly: viewOnly,
        background: background,
      ) ==
      MonitorInputBlockReason.none;

  bool _matches(int generation, String targetIdentity) =>
      generation == _generation && targetIdentity == _targetIdentity;

  static bool _fresh(DateTime? at, DateTime now, Duration staleAfter) {
    if (at == null) return false;
    final age = now.difference(at);
    return !age.isNegative && age <= staleAfter;
  }
}

class MonitorInputEpoch {
  int _value = 0;

  int capture() => _value;

  void invalidate() {
    _value++;
  }

  bool accepts(int value) => value == _value;
}
