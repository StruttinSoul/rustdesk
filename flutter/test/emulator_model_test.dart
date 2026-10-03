import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('a retained preview can finish starting after the visible set changes', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(), commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.setPreviews(['bluestacks:one'], []);
    final first = sent.last['request_id'];
    await model.setPreviews(['bluestacks:one', 'bluestacks:two'], []);
    model.handleResponse({'protocol_version': 1, 'type': 'status', 'request_id': first, 'preview': true, 'target_id': 'bluestacks:one', 'session_id': 5, 'state': 'starting'});
    model.handleResponse({'protocol_version': 1, 'type': 'status', 'request_id': first, 'preview': true, 'target_id': 'bluestacks:one', 'session_id': 5, 'state': 'streaming', 'width': 360, 'height': 200});
    expect(model.previews['bluestacks:one']?.state, 'streaming');
    model.instances = [const RemoteEmulator(id: 'bluestacks:one', name: 'One', provider: 'bluestacks', state: 'ready')];
    await model.desktop();
    model.handleResponse({'protocol_version': 1, 'type': 'status', 'request_id': sent.last['request_id'], 'session_id': 0, 'state': 'desktop'});
    expect(model.dashboardActive, true);
    expect(model.instances.single.name, 'One');
    expect(model.previews['bluestacks:one']?.state, 'streaming');
    model.dispose();
  });
  test(
      'preview statuses do not replace the selected guest or survive unsubscribe',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.setPreviews(['bluestacks:one', 'bluestacks:two'], [0]);
    final id = sent.last['request_id'];
    for (var i = 1; i <= 2; i++) {
      model.handleResponse({
        'protocol_version': 1,
        'type': 'status',
        'request_id': id,
        'preview': true,
        'target_id': i == 1 ? 'bluestacks:one' : 'bluestacks:two',
        'session_id': i,
        'state': 'starting'
      });
      model.handleResponse({
        'protocol_version': 1,
        'type': 'status',
        'request_id': id,
        'preview': true,
        'target_id': i == 1 ? 'bluestacks:one' : 'bluestacks:two',
        'session_id': i,
        'state': 'streaming',
        'width': 360,
        'height': 200
      });
    }
    expect(model.previews.length, 2);
    expect(model.selected, false);
    await model.navigation('home');
    expect(sent.last['action'], 'previews');
    await model.setPreviews([], [0]);
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': id,
      'preview': true,
      'target_id': 'bluestacks:one',
      'session_id': 1,
      'state': 'streaming',
      'width': 360,
      'height': 200
    });
    expect(model.previews, isEmpty);
    model.dispose();
  });
  test('maps direct phone touches through contained guest video', () {
    final center = mapEmulatorTouch(
      localX: 540,
      localY: 960,
      viewportWidth: 1080,
      viewportHeight: 1920,
      guestWidth: 720,
      guestHeight: 1280,
    );
    expect(center, (x: 360, y: 640));

    final letterboxed = mapEmulatorTouch(
      localX: 540,
      localY: 100,
      viewportWidth: 1080,
      viewportHeight: 1920,
      guestWidth: 1280,
      guestHeight: 720,
    );
    expect(letterboxed, isNull);

    final activeDrag = mapEmulatorTouch(
      localX: 540,
      localY: 100,
      viewportWidth: 1080,
      viewportHeight: 1920,
      guestWidth: 1280,
      guestHeight: 720,
      clampToFrame: true,
    );
    expect(activeDrag, (x: 640, y: 0));
  });

  test('loads authenticated instance inventory and reports provider errors',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model =
        EmulatorModel(Uuid().v4obj(), commandSender: (key, value) async {
      expect(key, 'emulator-request');
      sent.add(jsonDecode(value));
    });
    await model.refresh();
    expect(model.loading, isTrue);
    expect(sent.single['action'], 'list');
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.single['request_id'],
      'protocol_version': 1,
      'instances': [
        {
          'target_id': 'bluestacks:Tiramisu64',
          'name': 'MapleStory',
          'provider': 'bluestacks',
          'state': 'ready'
        }
      ],
      'provider_errors': ['LDPlayer: unavailable']
    });
    expect(model.instances.single.name, 'MapleStory');
    expect(model.loading, isFalse);
    expect(model.error, contains('LDPlayer'));
    model.dispose();
  });

  test('loads host health and sends bounded management actions', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refreshHost();
    expect(sent.last['action'], 'host_status');
    final requestId = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': requestId,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'snapshot': {
          'cpu_percent': 42.5,
          'cpu_name': 'Test CPU',
          'logical_cpus': 8,
          'memory_used_bytes': 4294967296,
          'memory_total_bytes': 8589934592,
          'uptime_secs': 7200,
          'processes': [
            {
              'pid': 1234,
              'name': 'game.exe',
              'cpu_percent': 10.0,
              'memory_bytes': 268435456,
              'executable': r'C:\Games\game.exe',
              'can_end': true,
            }
          ],
          'watchdog': {
            'running': true,
            'last_check_ms': 10,
            'last_recovery_ms': 0,
            'components': [
              {
                'id': 'bluestacks_adb',
                'label': 'BlueStacks ADB',
                'state': 'healthy',
                'detail': '1/1 running instance reachable',
                'recoverable': true,
              }
            ],
          },
        },
      },
    });
    expect(model.hostLoading, isFalse);
    expect(model.hostSnapshot?.cpuPercent, 42.5);
    expect(model.hostSnapshot?.processes.single.name, 'game.exe');
    expect(model.hostSnapshot?.watchdog.components.single.state, 'healthy');

    await model.endProcess(1234);
    expect(sent.last['action'], 'process_end');
    expect(sent.last['pid'], 1234);

    await model.recoverComponent('bluestacks_adb');
    expect(sent.last['action'], 'recover');
    expect(sent.last['component'], 'bluestacks_adb');
    model.dispose();
  });

  test('binds navigation to the selected guest and rejects stale statuses',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.connect('bluestacks:Tiramisu64');
    final requestId = sent.single['request_id'];
    model.handleResponse({
      'type': 'status',
      'request_id': requestId,
      'protocol_version': 1,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting'
    });
    model.handleResponse({
      'type': 'status',
      'request_id': requestId,
      'protocol_version': 1,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720
    });
    expect(model.streaming, isTrue);
    await model.navigation('back');
    expect(sent.last['session_id'], 42);
    model.handleResponse({
      'type': 'status',
      'request_id': requestId - 1,
      'protocol_version': 1,
      'session_id': 41,
      'state': 'failed',
      'error': 'old session'
    });
    expect(model.streaming, isTrue);
    expect(model.error, isEmpty);
    await model.desktop();
    model.handleResponse({
      'type': 'status',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'state': 'desktop',
      'session_id': 0
    });
    expect(model.selected, isFalse);
    final count = sent.length;
    await model.navigation('home');
    expect(sent.length, count);
    model.dispose();
  });
}
