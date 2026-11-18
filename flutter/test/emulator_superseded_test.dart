import 'dart:convert';

import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

const _id = 'bluestacks:Pie64';

void main() {
  test('a game opened on another device fails without an automatic reopen',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.refresh();
    final list = sent.lastWhere((m) => m['action'] == 'list');
    model.handleResponse({
      'type': 'inventory', 'request_id': list['request_id'],
      'protocol_version': 1,
      'instances': [
        {'target_id': _id, 'provider': 'bluestacks', 'name': 'Pie64', 'state': 'ready'},
      ],
      'provider_errors': const [],
    });

    Future<int> open() async {
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
      return select;
    }

    Duration? retry() => guestAutoReconnectDelay(
          sessionFailed:
              model.startupPhase == 'failed' && model.error.isNotEmpty,
          guestWasLive: true,
          emulatorRunning: guestReadyForReconnect(model, _id),
          foreground: true,
          canControl: true,
          attempts: 0,
          superseded: model.guestSuperseded,
        );

    var select = await open();
    expect(model.streaming, isTrue);
    model.handleResponse({
      'protocol_version': 1, 'type': 'status', 'request_id': select,
      'session_id': 7, 'target_id': _id, 'state': 'failed',
      'phase': 'superseded',
      'error': 'This emulator was opened on another device.',
    });
    expect(model.startupPhase, 'failed');
    expect(model.guestSuperseded, isTrue);
    expect(retry(), isNull, reason: 'it would take the game back');

    // Reopening on this phone clears it; another failure retries as before.
    select = await open();
    expect(model.guestSuperseded, isFalse);
    model.handleResponse({
      'protocol_version': 1, 'type': 'status', 'request_id': select,
      'session_id': 7, 'target_id': _id, 'state': 'failed',
      'error': 'Guest input stopped',
    });
    expect(model.guestSuperseded, isFalse);
    expect(retry(), const Duration(seconds: 1));
  });
}
