import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:uuid/uuid.dart';

Future<EmulatorModel> _connectedModel(List<Map<String, dynamic>> sent,
    {List<String> capabilities = const [
      'operation.identity.v1',
      'operation.ack.v1',
      'host.windows.list.v1',
      'host.window_focus.v1',
    ]}) async {
  final model = EmulatorModel(
    const Uuid().v4obj(),
    commandSender: (_, value) async => sent.add(jsonDecode(value)),
  );
  await model.refresh();
  model.handleResponse({
    'type': 'inventory',
    'request_id': sent.last['request_id'],
    'protocol_version': 1,
    'instances': const [],
    'provider_errors': const [],
    'capabilities': capabilities,
    'operation_session_identity': 'scope-windows',
    'operation_generation': 4,
  });
  return model;
}

void main() {
  test('window list and focus stay opaque and scope bound', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent);
    addTearDown(model.dispose);
    final dynamic windows = model;

    await windows.refreshHostWindows();
    final listRequest = Map<String, dynamic>.from(sent.last);
    expect(listRequest['action'], 'windows_list');

    model.handleResponse({
      'type': 'host',
      'request_id': listRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'desktop_generation': 7,
        'windows': [
          {
            'id': 'win-opaque-a',
            'title': 'MapleStory',
            'application': 'MapleStory.exe',
            'monitor': 1,
            'x': 120,
            'y': 80,
            'width': 1280,
            'height': 720,
            'minimized': false,
            'can_focus': true,
          }
        ],
      },
    });

    final dynamic snapshot = windows.hostWindowsSnapshot;
    expect(snapshot.desktopGeneration, 7);
    expect(snapshot.windows.single.id, 'win-opaque-a');
    expect(snapshot.windows.single.monitor, 1);

    final Future<dynamic> focusResult =
        windows.focusHostWindow(snapshot.windows.single);
    await Future<void>.delayed(Duration.zero);
    final focusRequest = Map<String, dynamic>.from(sent.last);
    expect(focusRequest['action'], 'window_focus');
    expect(focusRequest['window_id'], 'win-opaque-a');
    expect(focusRequest['desktop_generation'], 7);
    expect(focusRequest['session_identity'], 'scope-windows');
    expect(focusRequest['session_generation'], 4);
    expect(focusRequest['target_identity'], 'window:win-opaque-a:7');
    expect(focusRequest.containsKey('hwnd'), isFalse,
        reason: 'raw HWND values must never cross the remote protocol');

    model.handleResponse({
      'type': 'host',
      'request_id': focusRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': focusRequest['operation_id'],
        'session_identity': 'scope-windows',
        'target_identity': 'window:win-opaque-a:7',
        'session_generation': 4,
        'desktop_generation': 7,
        'window_focus': {
          'id': 'win-opaque-a',
          'title': 'MapleStory',
          'application': 'MapleStory.exe',
          'monitor': 0,
          'x': 32,
          'y': 48,
          'width': 1000,
          'height': 700,
          'minimized': false,
          'can_focus': true,
        },
      },
    });

    expect((await focusResult)?.id, 'win-opaque-a');
    expect(windows.focusedHostWindow.monitor, 0,
        reason: 'the observed focus result must reconcile monitor changes');
    expect(windows.focusedHostWindow.x, 32);
  });

  test('unsupported peers do not send window picker requests', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent, capabilities: const []);
    addTearDown(model.dispose);
    final dynamic windows = model;
    final before = sent.length;

    await windows.refreshHostWindows();

    expect(sent.length, before);
  });

  test('mismatched focus acknowledgement is rejected', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent);
    addTearDown(model.dispose);

    await model.refreshHostWindows();
    final listRequest = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': listRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'desktop_generation': 9,
        'windows': [
          {
            'id': 'win-original',
            'title': 'Original',
            'application': 'Original.exe',
            'monitor': 0,
            'x': 0,
            'y': 0,
            'width': 800,
            'height': 600,
            'minimized': false,
            'can_focus': true,
          }
        ],
      },
    });

    final future =
        model.focusHostWindow(model.hostWindowsSnapshot!.windows.single);
    await Future<void>.delayed(Duration.zero);
    final focusRequest = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': focusRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': focusRequest['operation_id'],
        'session_identity': 'scope-windows',
        'target_identity': 'window:win-original:9',
        'session_generation': 4,
        'desktop_generation': 9,
        'window_focus': {
          'id': 'win-other',
          'title': 'Other',
          'application': 'Other.exe',
          'monitor': 0,
          'x': 0,
          'y': 0,
          'width': 800,
          'height': 600,
          'minimized': false,
          'can_focus': true,
        },
      },
    });

    expect(await future, isNull);
    expect(model.focusedHostWindow, isNull);
    expect(model.hostError, contains('mismatched'));
  });

  test('window list transport error clears stale actionable snapshot',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent);
    addTearDown(model.dispose);

    await model.refreshHostWindows();
    final first = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': first['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'desktop_generation': 11,
        'windows': [
          {
            'id': 'win-a',
            'title': 'A',
            'application': 'A.exe',
            'monitor': 0,
            'x': 0,
            'y': 0,
            'width': 640,
            'height': 480,
            'minimized': false,
            'can_focus': true,
          }
        ],
      },
    });
    expect(model.hostWindowsSnapshot, isNotNull);

    await model.refreshHostWindows();
    final second = Map<String, dynamic>.from(sent.last);
    expect(model.hostWindowsSnapshot, isNull,
        reason: 'refresh must immediately stale-block the previous list');
    model.handleResponse({
      'type': 'error',
      'request_id': second['request_id'],
      'protocol_version': 1,
      'error': 'window enumeration failed',
    });

    expect(model.hostWindowsSnapshot, isNull);
    expect(model.hostWindowsLoading, isFalse);
    expect(model.hostWindowsError, 'window enumeration failed');
  });
}
