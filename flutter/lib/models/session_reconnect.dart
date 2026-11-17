import 'dart:async';

import 'package:flutter/foundation.dart';

/// How long automatic reconnecting keeps trying before it shows the error.
const Duration kSessionReconnectWindow = Duration(seconds: 60);

/// The longest wait between two attempts.
const Duration kSessionReconnectMaxBackoff = Duration(seconds: 8);

/// Texts of a dropped connection (lower case). Only these start automatic
/// reconnecting; the PC ending the session ("Closed manually by the peer"),
/// refusals and anything unknown keep today's dialog.
const List<String> _transientTexts = [
  'reset by peer',
  'reset by the peer',
  'os error 104',
  'os error 103',
  'os error 110',
  'os error 101',
  'os error 32',
  '10054',
  '10053',
  '10060',
  '10052',
  'broken pipe',
  'connection aborted',
  'forcibly closed',
  'timed out',
  'timeout',
  'deadline',
  'closing handshake',
  'unexpected eof',
  'end of file',
  'network is unreachable',
];

/// Texts that mean the PC or its owner said no. They win over any network
/// word and stop automatic reconnecting.
const List<String> _refusalTexts = [
  'manually',
  'denied',
  'password',
  'permission',
  'not allowed',
  'restricted',
  'incoming only',
  'mismatch',
  'reject',
  'wrong',
  'invalid',
  'blocked',
  'not exist',
  'unauthor',
  '2fa',
  'login',
];

/// Message boxes that ask the user for something; automatic reconnecting
/// stops when one arrives and RustDesk shows it as it always has.
const List<String> _promptTypes = [
  'input-password',
  're-input-password',
  'input-2fa',
  'wait-remote-accept-nook',
  'terminal-admin-login',
  'terminal-admin-login-password',
];

bool _isConnectionErrorBox(String type, String title) =>
    title == 'Connection Error' &&
    (type == 'error' || type == 'relay-hint' || type == 'relay-hint2');

bool _isRefusal(String text) {
  final lower = text.toLowerCase();
  return _refusalTexts.any(lower.contains);
}

/// Whether a message box is a dropped connection that is worth reconnecting
/// from on its own: a connection error whose text is a network failure and
/// not a refusal.
bool isRecoverableSessionLoss({
  required String type,
  required String title,
  required String text,
}) {
  if (!_isConnectionErrorBox(type, title) || _isRefusal(text)) return false;
  final lower = text.toLowerCase();
  return _transientTexts.any(lower.contains);
}

/// The wait before the next attempt after [failedAttempts] failures (1, 2, 4,
/// then 8 s), or null when that attempt would start past
/// [kSessionReconnectWindow] since the drop.
Duration? sessionReconnectDelay({
  required int failedAttempts,
  required Duration elapsed,
}) {
  final seconds = 1 << (failedAttempts - 1).clamp(0, 6);
  final delay = Duration(
      seconds: seconds > kSessionReconnectMaxBackoff.inSeconds
          ? kSessionReconnectMaxBackoff.inSeconds
          : seconds);
  if (elapsed + delay > kSessionReconnectWindow) return null;
  return delay;
}

enum ReconnectRestoreKind { none, guest, monitor }

/// What to reopen once the session is back. The dashboard tab is not part of
/// it: the page keeps its own tab through the drop.
@immutable
class ReconnectRestore {
  const ReconnectRestore._(this.kind, {this.guestId, this.display});

  final ReconnectRestoreKind kind;
  final String? guestId;
  final int? display;
}

/// The view to reopen: the open emulator, else the open monitor, else
/// nothing (the user was on a tab).
ReconnectRestore reconnectRestoreFor({String? guestId, int? display}) {
  if (guestId != null && guestId.isNotEmpty) {
    return ReconnectRestore._(ReconnectRestoreKind.guest, guestId: guestId);
  }
  if (display != null) {
    return ReconnectRestore._(ReconnectRestoreKind.monitor, display: display);
  }
  return const ReconnectRestore._(ReconnectRestoreKind.none);
}

enum SessionReconnectPhase {
  /// Connected, or not trying.
  idle,

  /// Dropped while the app is in the background; resumes in the foreground.
  waitingForForeground,

  /// Attempts are under way.
  reconnecting,

  /// The 60 s ran out; the error dialog is showing and nothing retries until
  /// the user does.
  gaveUp,
}

typedef ReconnectScheduler = Timer Function(
    Duration delay, void Function() callback);

/// Reconnects a dropped dashboard session on its own: the first attempt at
/// once, then 1, 2, 4, 8 s apart for up to 60 s, only in the foreground. It
/// swallows the connection error box while it works, hands it back when it
/// gives up, and never touches credentials: a password or 2FA prompt, or any
/// refusal, ends it and shows as usual.
class SessionReconnectController extends ChangeNotifier {
  SessionReconnectController({
    required this.attempt,
    required this.onRestored,
    required this.onGiveUp,
    required this.isForeground,
    DateTime Function()? clock,
    ReconnectScheduler? scheduler,
  })  : _clock = clock ?? DateTime.now,
        _schedule = scheduler ?? ((delay, callback) => Timer(delay, callback));

  /// Starts one reconnect of the session.
  final void Function() attempt;

  /// The session is back after a drop this controller handled.
  final void Function() onRestored;

  /// Shows [event], the last connection error, because the time ran out.
  final void Function(Map<String, dynamic> event) onGiveUp;

  final bool Function() isForeground;
  final DateTime Function() _clock;
  final ReconnectScheduler _schedule;

  SessionReconnectPhase _phase = SessionReconnectPhase.idle;
  int _failed = 0;
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _attemptTimer;
  Timer? _deadline;
  Map<String, dynamic> _last = const {};
  bool _restorePending = false;

  /// A prompt or a refusal ended a run and no session has authenticated since.
  /// The PC drops an unaccepted connection after its grace period; that reset
  /// is not a new drop of a working session and must not start another run.
  bool _awaitingUser = false;
  bool _disposed = false;

  SessionReconnectPhase get phase => _phase;

  /// Whether the "Reconnecting…" state is showing.
  bool get showsReconnecting => _phase == SessionReconnectPhase.reconnecting;

  void _setPhase(SessionReconnectPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    if (!_disposed) notifyListeners();
  }

  void _cancelTimers() {
    _attemptTimer?.cancel();
    _attemptTimer = null;
    _deadline?.cancel();
    _deadline = null;
  }

  /// Offers a message box (`type`, `title`, `text`). Returns true when it was
  /// taken and no dialog should show.
  bool onMessage(Map<String, dynamic> event) {
    final type = (event['type'] ?? '').toString();
    final title = (event['title'] ?? '').toString();
    final text = (event['text'] ?? '').toString();
    if (type == 'restarting-show' && title == 'Connecting...') {
      // The peer-gone detector reconnects by itself under this box. Let that
      // run, and restore the view when it gets back.
      _restorePending = true;
      return false;
    }
    switch (_phase) {
      case SessionReconnectPhase.gaveUp:
        return false;
      case SessionReconnectPhase.idle:
        if (_awaitingUser ||
            !isRecoverableSessionLoss(type: type, title: title, text: text)) {
          return false;
        }
        _last = Map<String, dynamic>.of(event);
        _restorePending = true;
        _start();
        return true;
      case SessionReconnectPhase.waitingForForeground:
      case SessionReconnectPhase.reconnecting:
        if (_promptTypes.contains(type)) {
          // Credentials are RustDesk's to ask for. The prompt stays; once the
          // user is through it the view is still restored.
          _cancelTimers();
          _awaitingUser = true;
          _setPhase(SessionReconnectPhase.idle);
          return false;
        }
        if (!_isConnectionErrorBox(type, title)) return false;
        if (_isRefusal(text)) {
          _cancelTimers();
          _restorePending = false;
          _awaitingUser = true;
          _setPhase(SessionReconnectPhase.idle);
          return false;
        }
        _last = Map<String, dynamic>.of(event);
        return _attemptFailed();
    }
  }

  /// A fresh run of attempts: the first one now, the limit 60 s from now.
  void _start() {
    _cancelTimers();
    _failed = 0;
    _startedAt = _clock();
    if (!isForeground()) {
      _setPhase(SessionReconnectPhase.waitingForForeground);
      return;
    }
    _setPhase(SessionReconnectPhase.reconnecting);
    _deadline = _schedule(kSessionReconnectWindow, _onDeadline);
    attempt();
  }

  bool _attemptFailed() {
    _failed++;
    _attemptTimer?.cancel();
    _attemptTimer = null;
    if (!isForeground()) {
      _cancelTimers();
      _setPhase(SessionReconnectPhase.waitingForForeground);
      return true;
    }
    final delay = sessionReconnectDelay(
        failedAttempts: _failed, elapsed: _clock().difference(_startedAt));
    if (delay == null) {
      _giveUp();
      return false;
    }
    _attemptTimer = _schedule(delay, _nextAttempt);
    return true;
  }

  void _nextAttempt() {
    _attemptTimer = null;
    if (_phase != SessionReconnectPhase.reconnecting) return;
    if (!isForeground()) {
      _cancelTimers();
      _setPhase(SessionReconnectPhase.waitingForForeground);
      return;
    }
    attempt();
  }

  void _onDeadline() {
    _deadline = null;
    if (_phase != SessionReconnectPhase.reconnecting) return;
    _giveUp();
    onGiveUp(_last);
  }

  void _giveUp() {
    _cancelTimers();
    _setPhase(SessionReconnectPhase.gaveUp);
  }

  /// The app moved to or from the foreground.
  void onForegroundChanged(bool foreground) {
    if (foreground && _phase == SessionReconnectPhase.waitingForForeground) {
      _start();
    } else if (!foreground && _phase == SessionReconnectPhase.reconnecting) {
      _cancelTimers();
      _setPhase(SessionReconnectPhase.waitingForForeground);
    }
  }

  /// The session is connected (peer info arrived). Restores the view when a
  /// drop this controller handled is what led here, including a manual
  /// "Retry" after it gave up.
  void onConnected() {
    _cancelTimers();
    final restore = _restorePending;
    _restorePending = false;
    _awaitingUser = false;
    _failed = 0;
    _setPhase(SessionReconnectPhase.idle);
    if (restore) onRestored();
  }

  /// The session ended on purpose (End session, back out, dispose).
  void cancel() {
    _cancelTimers();
    _restorePending = false;
    _awaitingUser = false;
    _failed = 0;
    _setPhase(SessionReconnectPhase.idle);
  }

  @override
  void dispose() {
    _disposed = true;
    _cancelTimers();
    super.dispose();
  }
}
