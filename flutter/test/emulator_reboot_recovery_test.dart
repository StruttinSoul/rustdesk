import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/mobile/widgets/avd_settings_sheet.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

const _caps = [
  'operation.identity.v1',
  'operation.ack.v1',
  'host.emulator_shutdown.v1',
  'host.avd_manage.v1',
  'host.emulator_power.v1',
  'host.avd_settings.v1',
];
const _id = 'avd:Maple_1';

Map<String, dynamic> _list(int requestId, String state) => {
      'type': 'inventory',
      'request_id': requestId,
      'protocol_version': 1,
      'instances': [
        {'target_id': _id, 'provider': 'avd', 'name': 'Maple 1', 'state': state},
      ],
      'provider_errors': const [],
      'capabilities': _caps,
      'operation_session_identity': 'scope-r',
      'operation_generation': 2,
    };

void main() {
  testWidgets(
      'after a reboot the failed game reconnects once the list shows Android back',
      (tester) async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    List<Map<String, dynamic>> lists() =>
        sent.where((m) => m['action'] == 'list').toList();
    await model.refresh();
    model.handleResponse(_list(lists().last['request_id'], 'ready'));

    // A game is live.
    await model.connect(_id);
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1, 'type': 'status', 'request_id': select,
      'session_id': 7, 'target_id': _id, 'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1, 'type': 'status', 'request_id': select,
      'session_id': 7, 'target_id': _id, 'state': 'streaming',
      'width': 626, 'height': 1280,
    });
    expect(model.streaming, isTrue);

    // Reboot: the PC ends the stream, then acknowledges.
    final result = model.rebootEmulator(_id);
    await tester.pump();
    final reboot = sent.lastWhere((m) => m['action'] == 'emulator_reboot');
    model.handleResponse({
      'protocol_version': 1, 'type': 'status', 'request_id': select,
      'session_id': 7, 'target_id': _id, 'state': 'failed',
      'error': 'Android restarted in the emulator',
    });
    model.handleResponse({
      'type': 'host', 'request_id': reboot['request_id'], 'protocol_version': 1,
      'host': {
        'ok': true, 'accepted': true, 'state': 'applied', 'message': 'Restarting…',
        'operation_id': reboot['operation_id'], 'session_identity': 'scope-r',
        'target_identity': 'emulator:$_id', 'session_generation': 2,
      },
    });
    expect((await result).ok, isTrue);
    await tester.pump();
    expect(model.isRebooting(_id), isTrue);
    expect(model.startupPhase, 'failed');
    expect(model.error, isNotEmpty, reason: 'the list refresh keeps the failure');

    Duration? retry() => guestAutoReconnectDelay(
          sessionFailed: model.selected &&
              !model.connecting &&
              model.startupPhase == 'failed' &&
              model.error.isNotEmpty,
          guestWasLive: true,
          emulatorRunning: guestReadyForReconnect(model, _id),
          foreground: true,
          canControl: true,
          attempts: 0,
        );

    // The list at the acknowledgement may still say ready: no retry while
    // Android restarts.
    model.handleResponse(_list(lists().last['request_id'], 'ready'));
    expect(model.isRebooting(_id), isTrue);
    expect(retry(), isNull);
    // Android is down: no retry yet.
    await tester.pump(const Duration(milliseconds: 2600));
    model.handleResponse(_list(lists().last['request_id'], 'booting'));
    expect(retry(), isNull);
    // The phone keeps listing on its own.
    final before = lists().length;
    await tester.pump(const Duration(milliseconds: 2600));
    expect(lists().length, before + 1);
    model.handleResponse(_list(lists().last['request_id'], 'ready'));
    expect(model.isRebooting(_id), isFalse);
    expect(model.error, isNotEmpty);
    expect(retry(), const Duration(seconds: 1),
        reason: 'the game reconnects automatically');
    // Listing stops once Android is back.
    final settled = lists().length;
    await tester.pump(const Duration(seconds: 10));
    expect(lists().length, settled);
    model.dispose();
  });

  testWidgets('the reboot watch ends after 120 s', (tester) async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)),
        hostOperationTimeout: const Duration(seconds: 200));
    List<Map<String, dynamic>> lists() =>
        sent.where((m) => m['action'] == 'list').toList();
    await model.refresh();
    model.handleResponse(_list(lists().last['request_id'], 'ready'));
    final result = model.rebootEmulator(_id);
    await tester.pump();
    final reboot = sent.lastWhere((m) => m['action'] == 'emulator_reboot');
    model.handleResponse({
      'type': 'host', 'request_id': reboot['request_id'], 'protocol_version': 1,
      'host': {
        'ok': true, 'accepted': true, 'state': 'applied',
        'operation_id': reboot['operation_id'], 'session_identity': 'scope-r',
        'target_identity': 'emulator:$_id', 'session_generation': 2,
      },
    });
    await result;
    for (var i = 0; i < 50; i++) {
      await tester.pump(const Duration(milliseconds: 2500));
      final last = lists().last['request_id'];
      model.handleResponse(_list(last, 'booting'));
    }
    expect(model.isRebooting(_id), isFalse);
    final count = lists().length;
    await tester.pump(const Duration(seconds: 10));
    expect(lists().length, count);
    model.dispose();
  });

  test('a running-as-known emulator offers Reboot and Stop', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.refresh();
    model.handleResponse(_list(sent.last['request_id'], 'stopped'));
    expect(model.canRebootEmulator(_id), isFalse);
    expect(model.canShutdownEmulator(_id), isFalse);
    expect(model.canRebootEmulator(_id, runningAsKnown: true), isTrue);
    expect(model.canShutdownEmulator(_id, runningAsKnown: true), isTrue);
    model.dispose();
  });

  test('an error reply to a settings read completes it', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.refresh();
    model.handleResponse(_list(sent.last['request_id'], 'ready'));
    final load = model.loadAvdSettings(_id);
    await Future<void>.delayed(Duration.zero);
    final read = sent.lastWhere((m) => m['action'] == 'avd_settings_get');
    model.handleResponse({
      'type': 'error', 'request_id': read['request_id'], 'protocol_version': 1,
      'error': 'Host management action requires control permission',
    });
    final loaded = await load;
    expect(loaded.info, isNull);
    expect(loaded.error, contains('control permission'));
    model.dispose();
  });

  testWidgets('settings show a spinner while they load', (tester) async {
    final pending = Completer<int>();
    int? got;
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async => got = await waitWithProgress(
                        context, pending.future,
                        label: 'Loading settings…'),
                    child: const Text('go'))))));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading settings…'), findsOneWidget);
    pending.complete(5);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(got, 5);
  });
}
