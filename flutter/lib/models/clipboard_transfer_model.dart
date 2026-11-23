import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'platform_model.dart';

enum ClipboardTransferDirection { phoneToHost, hostToPhone }

const int kManualClipboardMaxBytes = 1024 * 1024;

typedef ClipboardCommandSender = Future<void> Function(
    String key, String value);
typedef ClipboardTransferContextProvider = ClipboardTransferContext Function();

class ClipboardTransferContext {
  const ClipboardTransferContext({
    required this.targetIdentity,
    required this.generation,
    required this.authenticated,
    required this.capabilitySupported,
    required this.permissionGranted,
  });

  final String targetIdentity;
  final int generation;
  final bool authenticated;
  final bool capabilitySupported;
  final bool permissionGranted;

  ClipboardTransferContext copyWith({
    String? targetIdentity,
    int? generation,
    bool? authenticated,
    bool? capabilitySupported,
    bool? permissionGranted,
  }) =>
      ClipboardTransferContext(
        targetIdentity: targetIdentity ?? this.targetIdentity,
        generation: generation ?? this.generation,
        authenticated: authenticated ?? this.authenticated,
        capabilitySupported: capabilitySupported ?? this.capabilitySupported,
        permissionGranted: permissionGranted ?? this.permissionGranted,
      );
}

class ClipboardTransferPreview {
  const ClipboardTransferPreview({
    required this.direction,
    required this.text,
    required this.targetIdentity,
    required this.generation,
  });

  final ClipboardTransferDirection direction;
  final String text;
  final String targetIdentity;
  final int generation;
}

class _PendingClipboardTransfer {
  const _PendingClipboardTransfer({
    required this.requestId,
    required this.direction,
    required this.targetIdentity,
    required this.generation,
  });

  final String requestId;
  final ClipboardTransferDirection direction;
  final String targetIdentity;
  final int generation;
}

class ClipboardTransferModel extends ChangeNotifier {
  ClipboardTransferModel(
    this.sessionId, {
    required ClipboardTransferContextProvider contextProvider,
    ClipboardCommandSender? commandSender,
    Duration requestTimeout = const Duration(seconds: 8),
  })  : _contextProvider = contextProvider,
        _requestTimeout = requestTimeout,
        _commandSender = commandSender ??
            ((key, value) => bind.sessionSetCommon(
                  sessionId: sessionId,
                  key: key,
                  value: value,
                ));

  final UuidValue sessionId;
  final ClipboardTransferContextProvider _contextProvider;
  final ClipboardCommandSender _commandSender;
  final Duration _requestTimeout;

  ClipboardTransferPreview? _preview;
  _PendingClipboardTransfer? _pending;
  Timer? _pendingTimeout;
  bool _disposed = false;
  String errorCode = '';
  String error = '';
  String message = '';

  ClipboardTransferPreview? get preview => _preview;
  bool get pending => _pending != null;

  ClipboardTransferContext get context => _contextProvider();
  bool get capabilitySupported => context.capabilitySupported;
  bool get permissionGranted => context.permissionGranted;

  bool stagePhoneToHost(
    String text, {
    ClipboardTransferContext? expectedContext,
  }) {
    if (_disposed || _pending != null) return false;
    final current = context;
    final unavailable = _availabilityError(current);
    if (unavailable != null) {
      _setError(unavailable.$1, unavailable.$2);
      return false;
    }
    if (expectedContext != null &&
        !_sameScope(
          expectedContext.targetIdentity,
          expectedContext.generation,
          current,
        )) {
      clearEphemeralState();
      return false;
    }
    if (!_fitsLimit(text)) {
      _setError(
        'clipboard_too_large',
        'Clipboard text is larger than the 1 MiB transfer limit.',
      );
      return false;
    }
    errorCode = '';
    error = '';
    message = '';
    _preview = ClipboardTransferPreview(
      direction: ClipboardTransferDirection.phoneToHost,
      text: text,
      targetIdentity: current.targetIdentity,
      generation: current.generation,
    );
    notifyListeners();
    return true;
  }

  Future<bool> copyPreviewToHost() async {
    final preview = _preview;
    if (_disposed ||
        preview == null ||
        preview.direction != ClipboardTransferDirection.phoneToHost) {
      return false;
    }
    final current = context;
    final unavailable = _availabilityError(current);
    if (unavailable != null) {
      _setError(unavailable.$1, unavailable.$2);
      return false;
    }
    if (!_sameScope(preview.targetIdentity, preview.generation, current)) {
      clearEphemeralState();
      return false;
    }
    if (!_fitsLimit(preview.text)) {
      _setError(
        'clipboard_too_large',
        'Clipboard text is larger than the 1 MiB transfer limit.',
      );
      return false;
    }
    return _send(
      ClipboardTransferDirection.phoneToHost,
      text: preview.text,
      current: current,
    );
  }

  Future<bool> requestHostToPhone() async {
    if (_disposed) return false;
    final current = context;
    final unavailable = _availabilityError(current);
    if (unavailable != null) {
      _setError(unavailable.$1, unavailable.$2);
      return false;
    }
    _preview = null;
    return _send(
      ClipboardTransferDirection.hostToPhone,
      text: '',
      current: current,
    );
  }

  Future<bool> _send(
    ClipboardTransferDirection direction, {
    required String text,
    required ClipboardTransferContext current,
  }) async {
    if (_pending != null) return false;
    final requestId = const Uuid().v4();
    final pending = _PendingClipboardTransfer(
      requestId: requestId,
      direction: direction,
      targetIdentity: current.targetIdentity,
      generation: current.generation,
    );
    _pending = pending;
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(_requestTimeout, () {
      if (_disposed || _pending?.requestId != requestId) return;
      _pending = null;
      _pendingTimeout = null;
      _setError(
        'clipboard_timeout',
        'The clipboard request timed out. Review the current clipboard state before retrying.',
      );
    });
    errorCode = '';
    error = '';
    message = 'Waiting for PC…';
    notifyListeners();
    try {
      await _commandSender(
        'manual-clipboard-request',
        jsonEncode(<String, dynamic>{
          'request_id': requestId,
          'direction': _directionWire(direction),
          'text': text,
          'target_identity': current.targetIdentity,
        }),
      );
    } catch (_) {
      if (_disposed || _pending?.requestId != requestId) return false;
      _pendingTimeout?.cancel();
      _pendingTimeout = null;
      _pending = null;
      _setError(
        'clipboard_transport_failed',
        'The clipboard request was not confirmed. Review it before retrying.',
      );
      return false;
    }
    if (_disposed || _pending?.requestId != requestId) return false;
    final now = context;
    if (_pending?.requestId == requestId &&
        !_sameScope(pending.targetIdentity, pending.generation, now)) {
      clearEphemeralState();
      return false;
    }
    return true;
  }

  void handleResponse(Map<String, dynamic> response) {
    if (_disposed) return;
    final pending = _pending;
    if (pending == null ||
        response['request_id']?.toString() != pending.requestId) {
      return;
    }
    final current = context;
    if (!_sameScope(pending.targetIdentity, pending.generation, current) ||
        response['target_identity']?.toString() != pending.targetIdentity ||
        response['direction']?.toString() !=
            _directionWire(pending.direction)) {
      clearEphemeralState();
      return;
    }
    final unavailable = _availabilityError(current);
    if (unavailable != null) {
      _pendingTimeout?.cancel();
      _pendingTimeout = null;
      _pending = null;
      _preview = null;
      _setError(unavailable.$1, unavailable.$2);
      return;
    }
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    _pending = null;
    final accepted = response['accepted'] == true;
    final applied = response['applied'] == true;
    if (!accepted || !applied) {
      _setError(
        response['error_code']?.toString().isNotEmpty == true
            ? response['error_code'].toString()
            : 'clipboard_request_failed',
        response['error']?.toString().isNotEmpty == true
            ? response['error'].toString()
            : 'The PC did not apply the clipboard request.',
      );
      return;
    }

    errorCode = '';
    error = '';
    if (pending.direction == ClipboardTransferDirection.hostToPhone) {
      final text = response['text']?.toString() ?? '';
      if (!_fitsLimit(text)) {
        _setError(
          'clipboard_too_large',
          'Clipboard text is larger than the 1 MiB transfer limit.',
        );
        return;
      }
      _preview = ClipboardTransferPreview(
        direction: pending.direction,
        text: text,
        targetIdentity: pending.targetIdentity,
        generation: pending.generation,
      );
      message = 'Ready to copy to this phone.';
    } else {
      message = 'Copied to PC clipboard.';
    }
    notifyListeners();
  }

  bool canCopyPreviewToPhone(ClipboardTransferPreview preview) {
    if (_disposed ||
        !identical(_preview, preview) ||
        preview.direction != ClipboardTransferDirection.hostToPhone) {
      return false;
    }
    final current = context;
    return _availabilityError(current) == null &&
        _sameScope(preview.targetIdentity, preview.generation, current) &&
        _fitsLimit(preview.text);
  }

  bool markCopiedToPhone(ClipboardTransferPreview expectedPreview) {
    if (_disposed ||
        !identical(_preview, expectedPreview) ||
        expectedPreview.direction != ClipboardTransferDirection.hostToPhone) {
      return false;
    }
    final current = context;
    final unavailable = _availabilityError(current);
    if (unavailable != null ||
        !_sameScope(
          expectedPreview.targetIdentity,
          expectedPreview.generation,
          current,
        )) {
      clearEphemeralState();
      return false;
    }
    message = 'Copied to phone clipboard.';
    errorCode = '';
    error = '';
    notifyListeners();
    return true;
  }

  void onContextChanged() {
    if (_disposed) return;
    final current = context;
    if (!current.authenticated ||
        !current.capabilitySupported ||
        !current.permissionGranted) {
      if (_preview != null || _pending != null) clearEphemeralState();
      return;
    }
    final preview = _preview;
    final pending = _pending;
    final previewStale = preview != null &&
        !_sameScope(preview.targetIdentity, preview.generation, current);
    final pendingStale = pending != null &&
        !_sameScope(pending.targetIdentity, pending.generation, current);
    if (!previewStale && !pendingStale) return;
    clearEphemeralState();
  }

  void clearEphemeralState({bool notify = true}) {
    if (_disposed) return;
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    _preview = null;
    _pending = null;
    errorCode = '';
    error = '';
    message = '';
    if (notify) notifyListeners();
  }

  (String, String)? _availabilityError(ClipboardTransferContext current) {
    if (!current.authenticated || current.targetIdentity.isEmpty) {
      return (
        'clipboard_not_connected',
        'Connect to the PC before using clipboard transfer.'
      );
    }
    if (!current.capabilitySupported) {
      return (
        'clipboard_unsupported',
        'This PC does not support deliberate clipboard transfer.'
      );
    }
    if (!current.permissionGranted) {
      return (
        'clipboard_permission_denied',
        'Clipboard permission is disabled for this session.'
      );
    }
    return null;
  }

  void _setError(String code, String text) {
    errorCode = code;
    error = text;
    message = '';
    notifyListeners();
  }

  static bool _fitsLimit(String text) =>
      utf8.encode(text).length <= kManualClipboardMaxBytes;

  static bool _sameScope(
    String targetIdentity,
    int generation,
    ClipboardTransferContext current,
  ) =>
      current.authenticated &&
      current.targetIdentity == targetIdentity &&
      current.generation == generation;

  static String _directionWire(ClipboardTransferDirection direction) =>
      direction == ClipboardTransferDirection.phoneToHost
          ? 'phone_to_host'
          : 'host_to_phone';

  @override
  void dispose() {
    if (_disposed) return;
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    _preview = null;
    _pending = null;
    _disposed = true;
    super.dispose();
  }
}
