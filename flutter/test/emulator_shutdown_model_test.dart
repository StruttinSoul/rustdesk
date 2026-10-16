import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  Future<EmulatorModel> ready(List<Map<String, dynamic>> sent, {bool supported = true}) async {
    final model = EmulatorModel(const Uuid().v4obj(), commandSender: (_, payload) async => sent.add(jsonDecode(payload)));
    addTearDown(model.dispose);
    await model.refresh();
    model.handleResponse({'protocol_version': 1, 'type': 'inventory', 'request_id': sent.last['request_id'],
      'capabilities': ['operation.identity.v1', 'operation.ack.v1', if (supported) 'host.emulator_shutdown.v1'],
      'operation_session_identity': 'scope-shutdown', 'operation_generation': 4, 'dashboard': true,
      'instances': [{'target_id': 'bluestacks:Tiramisu64', 'provider': 'bluestacks', 'name': 'Player 1', 'state': 'ready'}]});
    return model;
  }
  test('shutdown is unavailable on an old host and unknown targets send nothing', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent, supported: false);
    expect(model.canShutdownEmulator('bluestacks:Tiramisu64'), isFalse);
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    expect(sent.where((p) => p['action'] == 'emulator_shutdown'), isEmpty);
    expect(model.hostError, contains('not available'));
  });
  test('shutdown sends one scoped request and blocks duplicate taps', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent);
    expect(model.canShutdownEmulator('bluestacks:Tiramisu64'), isTrue);
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    final requests = sent.where((p) => p['action'] == 'emulator_shutdown').toList();
    expect(requests, hasLength(1));
    expect(requests.single['component'], 'bluestacks:Tiramisu64');
    expect(requests.single['target_identity'], 'emulator:bluestacks:Tiramisu64');
    expect(requests.single['session_identity'], 'scope-shutdown');
    expect(requests.single['session_generation'], 4);
    expect(requests.single['operation_id'], isNotEmpty);
    expect(model.isEmulatorShuttingDown('bluestacks:Tiramisu64'), isTrue);
    expect(model.canShutdownEmulator('bluestacks:Tiramisu64'), isFalse);
  });
  test('shutdown acknowledgement failure clears pending state and preserves error', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent);
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    final request = sent.last;
    model.handleResponse({'protocol_version': 1, 'type': 'host', 'request_id': request['request_id'],
      'host': {'ok': false, 'accepted': true, 'state': 'failed', 'operation_id': request['operation_id'],
        'session_identity': request['session_identity'], 'session_generation': request['session_generation'],
        'target_identity': request['target_identity'], 'error': 'Player refused graceful shutdown', 'error_code': 'emulator_shutdown_failed'}});
    expect(model.isEmulatorShuttingDown('bluestacks:Tiramisu64'), isFalse);
    expect(model.hostError, contains('refused'));
  });
  test('inventory reports stopping until an actual stopped observation', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent);
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    for (final state in ['stopping', 'stopped']) {
      await model.refresh();
      model.handleResponse({'protocol_version': 1, 'type': 'inventory', 'request_id': sent.last['request_id'],
        'capabilities': ['operation.identity.v1', 'operation.ack.v1', 'host.emulator_shutdown.v1'],
        'operation_session_identity': 'scope-shutdown', 'operation_generation': 4, 'dashboard': true,
        'instances': [{'target_id': 'bluestacks:Tiramisu64', 'provider': 'bluestacks', 'name': 'Player 1', 'state': state}]});
      expect(model.isEmulatorShuttingDown('bluestacks:Tiramisu64'), state == 'stopping');
    }
    expect(model.canShutdownEmulator('bluestacks:Tiramisu64'), isFalse);
  });
  test('invalid targets never send shutdown', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent);
    for (final id in ['windows:0', 'bluestacks:missing', 'ldplayer:0']) {
      await model.shutdownEmulator(id);
    }
    expect(sent.where((p) => p['action'] == 'emulator_shutdown'), isEmpty);
  });
  test('target disappearing before dispatch clears shutdown progress', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await ready(sent);
    model.addListener(() {
      if (model.isEmulatorShuttingDown('bluestacks:Tiramisu64')) model.instances.clear();
    });
    await model.shutdownEmulator('bluestacks:Tiramisu64');
    expect(sent.where((p) => p['action'] == 'emulator_shutdown'), isEmpty);
    expect(model.isEmulatorShuttingDown('bluestacks:Tiramisu64'), isFalse);
    expect(model.hostError, contains('changed'));
  });

}