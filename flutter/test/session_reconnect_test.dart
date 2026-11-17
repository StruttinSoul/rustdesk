import 'dart:async';

import 'package:flutter_hbb/models/session_reconnect.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock and timer factory the tests advance by hand.
class FakeClock {
  DateTime now = DateTime(2026, 11, 17, 12);
  final DateTime start = DateTime(2026, 11, 17, 12);
  final List<FakeTimer> timers = [];

  Timer schedule(Duration delay, void Function() callback) {
    final timer = FakeTimer(now.add(delay), callback);
    timers.add(timer);
    return timer;
  }

  void advance(Duration by) {
    final target = now.add(by);
    while (true) {
      final due = timers
          .where((t) => t.active && !t.at.isAfter(target))
          .toList()
        ..sort((a, b) => a.at.compareTo(b.at));
      if (due.isEmpty) break;
      final next = due.first;
      if (next.at.isAfter(now)) now = next.at;
      next.fire();
    }
    now = target;
  }

  int get pending => timers.where((t) => t.active).length;
}

class FakeTimer implements Timer {
  FakeTimer(this.at, this._callback);
  final DateTime at;
  final void Function() _callback;
  bool active = true;

  void fire() {
    active = false;
    _callback();
  }

  @override
  void cancel() => active = false;

  @override
  bool get isActive => active;

  @override
  int get tick => 0;
}

Map<String, dynamic> error(String text,
        {String type = 'error', String title = 'Connection Error'}) =>
    {'type': type, 'title': title, 'text': text};

Map<String, dynamic> prompt(String type) =>
    {'type': type, 'title': '', 'text': ''};

const reset = 'Connection reset by peer (os error 104)';

void main() {
  group('isRecoverableSessionLoss', () {
    test('network drops reconnect', () {
      for (final text in [
        reset,
        'Reset by the peer',
        'Timeout',
        'Connection reset by peer (os error 10054)',
        'An existing connection was forcibly closed by the remote host. (os error 10054)',
        'Broken pipe (os error 32)',
        'Software caused connection abort (os error 103)',
        'Connection timed out (os error 110)',
        'deadline has elapsed',
        'Connection reset without closing handshake',
        'unexpected end of file',
        'Network is unreachable (os error 101)',
      ]) {
        expect(
            isRecoverableSessionLoss(
                type: 'error', title: 'Connection Error', text: text),
            isTrue,
            reason: text);
      }
    });

    test('the relay hint dialogs carry the same drops', () {
      for (final type in ['relay-hint', 'relay-hint2']) {
        expect(
            isRecoverableSessionLoss(
                type: type, title: 'Connection Error', text: reset),
            isTrue);
      }
    });

    test('the PC closing the session, refusals and auth errors do not', () {
      for (final text in [
        'Closed manually by the peer',
        'No permission of file transfer',
        'Connection denied by the PC',
        'Wrong Password',
        'Login Error: 2FA failed',
        'Remote desktop is offline',
        'ID does not exist',
        'Key mismatch',
        'Connection is restricted',
        'Failed to connect via rendezvous server',
        '',
      ]) {
        expect(
            isRecoverableSessionLoss(
                type: 'error', title: 'Connection Error', text: text),
            isFalse,
            reason: text);
      }
      // A refusal wins over a network word in the same text.
      expect(
          isRecoverableSessionLoss(
              type: 'error',
              title: 'Connection Error',
              text: 'Wrong password (timeout)'),
          isFalse);
    });

    test('only connection errors count, not other message boxes', () {
      expect(
          isRecoverableSessionLoss(
              type: 'error', title: 'Error', text: 'Timeout'),
          isFalse);
      for (final type in [
        're-input-password',
        'input-password',
        'input-2fa',
        'wait-remote-accept-nook',
        'restarting',
        'custom-error',
        'success',
      ]) {
        expect(
            isRecoverableSessionLoss(
                type: type, title: 'Connection Error', text: reset),
            isFalse,
            reason: type);
      }
    });
  });

  group('sessionReconnectDelay', () {
    test('backs off 1, 2, 4, 8 s and stays at 8 s', () {
      final delays = [
        for (var failed = 1; failed <= 7; failed++)
          sessionReconnectDelay(
              failedAttempts: failed, elapsed: const Duration(seconds: 1))
      ];
      expect(delays.map((d) => d!.inSeconds), [1, 2, 4, 8, 8, 8, 8]);
    });

    test('stops once the next try would pass 60 s', () {
      expect(
          sessionReconnectDelay(
              failedAttempts: 6, elapsed: const Duration(seconds: 51)),
          const Duration(seconds: 8));
      expect(
          sessionReconnectDelay(
              failedAttempts: 6, elapsed: const Duration(seconds: 53)),
          isNull);
      expect(
          sessionReconnectDelay(
              failedAttempts: 1, elapsed: const Duration(seconds: 60)),
          isNull);
    });
  });

  group('reconnectRestoreFor', () {
    test('an open emulator is reopened, never started', () {
      final restore = reconnectRestoreFor(guestId: 'avd:Play35');
      expect(restore.kind, ReconnectRestoreKind.guest);
      expect(restore.guestId, 'avd:Play35');
    });
    test('an open monitor is reopened', () {
      final restore = reconnectRestoreFor(display: 1);
      expect(restore.kind, ReconnectRestoreKind.monitor);
      expect(restore.display, 1);
    });
    test('on a tab nothing is reopened and the tab stays', () {
      expect(reconnectRestoreFor().kind, ReconnectRestoreKind.none);
    });
  });

  group('SessionReconnectController', () {
    late FakeClock clock;
    late bool foreground;
    late int attempts;
    late int restored;
    late List<Map<String, dynamic>> gaveUp;
    late SessionReconnectController controller;

    setUp(() {
      clock = FakeClock();
      foreground = true;
      attempts = restored = 0;
      gaveUp = [];
      controller = SessionReconnectController(
        attempt: () => attempts++,
        onRestored: () => restored++,
        onGiveUp: gaveUp.add,
        isForeground: () => foreground,
        clock: () => clock.now,
        scheduler: clock.schedule,
      );
    });

    tearDown(() => controller.dispose());

    test('a reset swallows the dialog and reconnects at once', () {
      expect(controller.onMessage(error(reset)), isTrue);
      expect(attempts, 1);
      expect(controller.phase, SessionReconnectPhase.reconnecting);
    });

    test('a refusal or an unrelated box is left to the normal dialogs', () {
      expect(
          controller.onMessage(error('Closed manually by the peer')), isFalse);
      expect(controller.onMessage(prompt('input-password')), isFalse);
      expect(attempts, 0);
      expect(controller.phase, SessionReconnectPhase.idle);
    });

    test('each failure schedules the next attempt after its backoff', () {
      controller.onMessage(error(reset)); // attempt 1 at once
      expect(attempts, 1);
      final expectedWaits = [1, 2, 4, 8, 8];
      for (var i = 0; i < expectedWaits.length; i++) {
        controller.onMessage(error('Timeout')); // attempt i+1 failed
        final wait = expectedWaits[i];
        clock.advance(Duration(milliseconds: wait * 1000 - 1));
        expect(attempts, i + 1, reason: 'not before ${wait}s');
        clock.advance(const Duration(milliseconds: 1));
        expect(attempts, i + 2, reason: 'at ${wait}s');
      }
    });

    test("gives up after about 60 s and shows today's error", () {
      controller.onMessage(error(reset));
      var guard = 0;
      while (controller.phase == SessionReconnectPhase.reconnecting &&
          guard++ < 40) {
        // Each attempt fails as soon as it is made; wait out the backoff.
        if (!controller.onMessage(error('Timeout'))) break;
        clock.advance(const Duration(seconds: 8));
      }
      expect(controller.phase, SessionReconnectPhase.gaveUp);
      expect(clock.now.difference(clock.start).inSeconds, lessThanOrEqualTo(70));
      expect(attempts, greaterThanOrEqualTo(7));
      final made = attempts;
      // The failure after giving up is handed back, so the box shows.
      expect(controller.onMessage(error('Timeout')), isFalse);
      // And nothing starts over by itself.
      clock.advance(const Duration(minutes: 5));
      expect(attempts, made);
      expect(clock.pending, 0);
    });

    test('an attempt that hangs is ended by the 60 s limit', () {
      controller.onMessage(error(reset));
      clock.advance(const Duration(seconds: 59));
      expect(controller.phase, SessionReconnectPhase.reconnecting);
      expect(gaveUp, isEmpty);
      clock.advance(const Duration(seconds: 2));
      expect(controller.phase, SessionReconnectPhase.gaveUp);
      expect(gaveUp.single['text'], reset);
    });

    test('a refusal while retrying stops it and shows the dialog', () {
      controller.onMessage(error(reset));
      expect(controller.onMessage(error('Connection denied by the PC')),
          isFalse);
      expect(controller.phase, SessionReconnectPhase.idle);
      clock.advance(const Duration(seconds: 30));
      expect(attempts, 1);
      expect(clock.pending, 0);
    });

    test('a password or 2FA prompt stops auto retry and is shown', () {
      for (final type in ['input-password', 're-input-password', 'input-2fa']) {
        controller.onMessage(error(reset));
        expect(controller.onMessage(prompt(type)), isFalse, reason: type);
        expect(controller.phase, SessionReconnectPhase.idle, reason: type);
        clock.advance(const Duration(seconds: 30));
        expect(clock.pending, 0, reason: type);
        controller.onConnected(); // the user got through; ready for the next
      }
    });

    test('after a prompt, a later drop of the unauthorised connection does '
        'not start another run (no 3 minute loop)', () {
      controller.onMessage(error(reset));
      controller.onMessage(prompt('wait-remote-accept-nook'));
      // The PC drops the connection nobody accepted; the phone sees a reset.
      clock.advance(const Duration(seconds: 180));
      expect(controller.onMessage(error('Reset by the peer')), isFalse);
      expect(attempts, 1);
      expect(controller.phase, SessionReconnectPhase.idle);
      expect(clock.pending, 0);
      // Once the session really authenticates, drops are handled again.
      controller.onConnected();
      expect(controller.onMessage(error(reset)), isTrue);
      expect(attempts, 2);
    });

    test('after a refusal, drops are left to the dialogs until connected', () {
      controller.onMessage(error(reset));
      controller.onMessage(error('Connection denied by the PC'));
      expect(controller.onMessage(error(reset)), isFalse);
      expect(attempts, 1);
      controller.onConnected();
      expect(controller.onMessage(error(reset)), isTrue);
    });

    test('a drop reported as Connecting... is restored after the stock '
        'reconnect, which keeps running', () {
      final stock = {
        'type': 'restarting-show',
        'title': 'Connecting...',
        'text': 'Connection in progress. Please wait.',
      };
      expect(controller.onMessage(stock), isFalse,
          reason: 'The stock reconnect continues');
      expect(attempts, 0, reason: 'Not a second reconnect on top of it');
      expect(controller.phase, SessionReconnectPhase.idle);
      controller.onConnected();
      expect(restored, 1);
    });

    test('other restarting-show titles do not mark a drop', () {
      expect(
          controller.onMessage({
            'type': 'restarting-show',
            'title': 'Restarting remote device',
            'text': ''
          }),
          isFalse);
      controller.onConnected();
      expect(restored, 0);
    });

    test('success restores once and goes back to idle', () {
      controller.onMessage(error(reset));
      controller.onMessage(error('Timeout'));
      controller.onConnected();
      expect(restored, 1);
      expect(controller.phase, SessionReconnectPhase.idle);
      clock.advance(const Duration(minutes: 2));
      expect(attempts, 1);
      expect(clock.pending, 0);
      // A normal connect later does not restore.
      controller.onConnected();
      expect(restored, 1);
      // The next drop starts a fresh cycle at once.
      expect(controller.onMessage(error(reset)), isTrue);
      expect(attempts, 2);
    });

    test('lost in the background: waits, then reconnects at once on resume',
        () {
      foreground = false;
      expect(controller.onMessage(error(reset)), isTrue);
      expect(attempts, 0);
      expect(controller.phase, SessionReconnectPhase.waitingForForeground);
      clock.advance(const Duration(minutes: 3));
      expect(attempts, 0);
      expect(controller.phase, SessionReconnectPhase.waitingForForeground);
      foreground = true;
      controller.onForegroundChanged(true);
      expect(attempts, 1);
      expect(controller.phase, SessionReconnectPhase.reconnecting);
    });

    test('backgrounding mid-retry pauses; resume starts a fresh 60 s', () {
      controller.onMessage(error(reset));
      controller.onMessage(error('Timeout')); // a 1 s wait is scheduled
      foreground = false;
      controller.onForegroundChanged(false);
      expect(controller.phase, SessionReconnectPhase.waitingForForeground);
      clock.advance(const Duration(minutes: 5));
      expect(attempts, 1);
      expect(gaveUp, isEmpty);
      foreground = true;
      controller.onForegroundChanged(true);
      expect(attempts, 2);
      clock.advance(const Duration(seconds: 59));
      expect(controller.phase, SessionReconnectPhase.reconnecting);
    });

    test('a failure that arrives in the background does not retry there', () {
      controller.onMessage(error(reset));
      foreground = false;
      expect(controller.onMessage(error('Timeout')), isTrue);
      clock.advance(const Duration(minutes: 1));
      expect(attempts, 1);
      expect(controller.phase, SessionReconnectPhase.waitingForForeground);
    });

    test('cancel (session ended by the user) stops everything', () {
      controller.onMessage(error(reset));
      controller.onMessage(error('Timeout'));
      controller.cancel();
      expect(controller.phase, SessionReconnectPhase.idle);
      clock.advance(const Duration(minutes: 2));
      expect(attempts, 1);
      expect(clock.pending, 0);
    });

    test('a manual retry after giving up that connects restores too', () {
      controller.onMessage(error(reset));
      clock.advance(const Duration(seconds: 61));
      expect(controller.phase, SessionReconnectPhase.gaveUp);
      controller.onConnected();
      expect(restored, 1);
      expect(controller.phase, SessionReconnectPhase.idle);
    });

    test('listeners hear phase changes (the Reconnecting banner)', () {
      var heard = 0;
      controller.addListener(() => heard++);
      controller.onMessage(error(reset));
      expect(controller.showsReconnecting, isTrue);
      controller.onConnected();
      expect(controller.showsReconnecting, isFalse);
      expect(heard, greaterThanOrEqualTo(2));
    });

    test('the banner shows only while attempts are running', () {
      foreground = false;
      controller.onMessage(error(reset));
      expect(controller.showsReconnecting, isFalse);
      foreground = true;
      controller.onForegroundChanged(true);
      expect(controller.showsReconnecting, isTrue);
      clock.advance(const Duration(seconds: 61));
      expect(controller.showsReconnecting, isFalse);
    });
  });
}
