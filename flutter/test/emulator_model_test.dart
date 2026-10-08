import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/models/host_management_model.dart';
import 'package:flutter_hbb/models/remote_operation_state.dart';
import 'package:uuid/uuid.dart';

void markCurrentGuestFrameDecoded(EmulatorModel model) {
  model.noteGuestFrameDecoded(
    sessionId: model.guestSessionId,
    frameWidth: model.width,
    frameHeight: model.height,
  );
}

void setFreshHostProcess(EmulatorModel model, int pid,
    {int startTimeSecs = 100, int? creationTime100ns}) {
  model.hostSnapshot = HostSystemSnapshot(
    schema: 3,
    sampledAtMs: DateTime.now().millisecondsSinceEpoch,
    source: 'windows_sysinfo',
    receivedMonotonicMs: hostMonotonicNowMs(),
    cpuPercent: 10,
    cpuName: 'CPU',
    logicalCpus: 8,
    memoryUsedBytes: 4,
    memoryTotalBytes: 8,
    uptimeSecs: 10,
    processes: [
      HostProcessInfo(
        pid: pid,
        startTimeSecs: startTimeSecs,
        creationTime100ns:
            creationTime100ns ?? (startTimeSecs * 10000000 + pid),
        name: 'test.exe',
        cpuPercent: 2,
        memoryBytes: 1024,
        executable: r'C:\Apps\test.exe',
        canEnd: true,
      ),
    ],
    watchdog: const HostWatchdogInfo(
      running: true,
      lastCheckMs: 1,
      lastRecoveryMs: 0,
      components: [],
    ),
  );
}

Map<String, dynamic> gatewayStatusFixture(
  String identity, {
  int? activeSessions = 1,
  bool identityReady = true,
  String siloState = 'verified',
  bool siloProfileSelected = true,
  bool siloProfileVerified = true,
}) =>
    {
      'schema': 1,
      'sampled_at_ms': 1000,
      'installed': true,
      'process_state': 'running',
      'gateway_pid': 4242,
      'process_identity': identity,
      'version': 'fixture',
      'reachability': 'reachable',
      'gateway_health': 'ready',
      'api_version': '1',
      'trusted_pin_matched': true,
      'protected_health_available': true,
      'identity_ready': identityReady,
      'silo_state': siloState,
      'silo_profile_selected': siloProfileSelected,
      'silo_profile_verified': siloProfileVerified,
      'active_sessions': activeSessions,
      'max_sessions': 3,
      'imdb_enabled': true,
      'imdb_state': 'fresh',
      'imdb_refreshing': false,
      'imdb_updated_at': '2026-10-06T19:00:00Z',
      'setup_control_available': true,
      'provider_control_available': true,
      'restart_control_available': true,
      'detail': 'Healthy',
    };

void main() {
  test('composed guest text is sent once as text with no implicit Enter',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    final inventory = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'inventory',
      'request_id': inventory,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['guest.text.v1'],
    });
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720
    });
    markCurrentGuestFrameDecoded(model);

    expect(await model.sendText('Café 中文 👋🏽'), isTrue);
    expect(sent.last['action'], 'text');
    expect(sent.last['text'], 'Café 中文 👋🏽');
    expect(sent.last['session_id'], 42);
    expect(sent.where((message) => message['action'] == 'key'), isEmpty);
    model.dispose();
  });

  test('queued guest text is dropped if its guest session changes', () async {
    final sent = <Map<String, dynamic>>[];
    final navigationStarted = Completer<void>();
    final releaseNavigation = Completer<void>();
    final model = EmulatorModel(
      Uuid().v4obj(),
      commandSender: (_, value) async {
        final message = jsonDecode(value) as Map<String, dynamic>;
        sent.add(message);
        if (message['action'] == 'navigation') {
          if (!navigationStarted.isCompleted) navigationStarted.complete();
          await releaseNavigation.future;
        }
      },
    );

    await model.refresh();
    final inventory = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'inventory',
      'request_id': inventory,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['guest.text.v1'],
    });
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720,
    });
    markCurrentGuestFrameDecoded(model);

    final navigation = model.navigation('home');
    await navigationStarted.future;
    final text = model.sendText('must not leak');
    model.reset();
    releaseNavigation.complete();

    await navigation;
    expect(await text, isFalse);
    expect(sent.where((message) => message['action'] == 'text'), isEmpty);
    model.dispose();
  });

  test('old peer cannot send guest text without negotiated capability',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting'
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720
    });
    final before = sent.length;
    expect(await model.sendText('hello'), isFalse);
    expect(sent.length, before);
    model.dispose();
  });

  test('guest text reports transport failure instead of pretending success',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      Uuid().v4obj(),
      commandSender: (_, value) async {
        final message = jsonDecode(value) as Map<String, dynamic>;
        sent.add(message);
        if (message['action'] == 'text') throw StateError('transport offline');
      },
    );
    await model.refresh();
    final inventory = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'inventory',
      'request_id': inventory,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['guest.text.v1'],
    });
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720,
    });
    markCurrentGuestFrameDecoded(model);

    expect(await model.sendText('retry me'), isFalse);
    expect(model.error, contains('transport offline'));
    expect(
      sent.where((message) => message['action'] == 'text').length,
      1,
    );
    model.dispose();
  });

  test('guest touch cancellation can retain the original frame geometry',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 720,
      'height': 1280,
    });

    await model.touch(
      3,
      7,
      320,
      240,
      frameWidth: 1280,
      frameHeight: 720,
    );
    expect(sent.last['action'], 'touch');
    expect(sent.last['width'], 1280);
    expect(sent.last['height'], 720);
    model.dispose();
  });

  test('startup phase distinguishes boot Android screen and stream readiness',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.connect('bluestacks:Tiramisu64');
    final request = sent.last['request_id'];

    for (final phase in [
      'boot_requested',
      'starting_android',
      'waiting_screen',
    ]) {
      model.handleResponse({
        'protocol_version': 1,
        'type': 'status',
        'request_id': request,
        'session_id': 42,
        'target_id': 'bluestacks:Tiramisu64',
        'state': 'starting',
        'phase': phase,
      });
      expect(model.startupPhase, phase);
      expect(model.streaming, isFalse);
    }
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': request,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'phase': 'stream_ready',
      'width': 1280,
      'height': 720,
    });
    expect(model.startupPhase, 'stream_ready');
    expect(model.streaming, isTrue);
    model.dispose();
  });

  test('guest input requires a recently decoded phone frame', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      Uuid().v4obj(),
      guestFrameTimeout: const Duration(milliseconds: 10),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
    await model.refresh();
    final inventory = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'inventory',
      'request_id': inventory,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['guest.text.v1'],
    });
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720,
    });

    expect(model.guestFrameFresh, isFalse);
    final beforeFresh = sent.length;
    await model.navigation('home');
    expect(await model.sendText('not yet'), isFalse);
    expect(sent.length, beforeFresh);

    markCurrentGuestFrameDecoded(model);
    expect(model.guestFrameFresh, isTrue);
    await model.navigation('home');
    expect(sent.last['action'], 'navigation');

    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(model.guestFrameFresh, isFalse);
    final afterExpiry = sent.length;
    await model.key(29, true);
    expect(sent.length, afterExpiry);
    await model.key(29, false);
    expect(sent.last['action'], 'key');
    expect(sent.last['down'], isFalse);
    model.dispose();
  });

  test('guest geometry change invalidates decoded-frame readiness', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.connect('bluestacks:Tiramisu64');
    final select = sent.last['request_id'];
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'starting',
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 1280,
      'height': 720,
    });
    markCurrentGuestFrameDecoded(model);
    expect(model.guestFrameFresh, isTrue);

    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': select,
      'session_id': 42,
      'target_id': 'bluestacks:Tiramisu64',
      'state': 'streaming',
      'width': 720,
      'height': 1280,
    });

    expect(model.guestFrameFresh, isFalse);
    model.dispose();
  });

  test('preview control is acknowledged only by the current request', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.setPreviews([], [0]);
    final first = sent.last['request_id'] as int;
    expect(model.previewRequest, first);
    expect(model.previewsAcknowledged, isFalse);

    await model.setPreviews([], [1]);
    final current = sent.last['request_id'] as int;
    model.handleResponse({
      'protocol_version': 1,
      'type': 'previews',
      'request_id': first,
      'enabled': true,
      'session_ids': const [],
    });
    expect(model.previewsAcknowledged, isFalse);

    model.handleResponse({
      'protocol_version': 1,
      'type': 'previews',
      'request_id': current,
      'enabled': true,
      'session_ids': const [],
    });
    expect(model.previewAcknowledgedRequest, current);
    expect(model.previewsAcknowledged, isTrue);
    model.dispose();
  });

  test('preview acknowledgement can be invalidated before resubscribe',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.setPreviews([], [0]);
    final request = sent.last['request_id'] as int;
    model.handleResponse({
      'protocol_version': 1,
      'type': 'previews',
      'request_id': request,
      'enabled': true,
      'session_ids': const [],
    });
    expect(model.previewsAcknowledged, isTrue);

    model.invalidatePreviewAcknowledgement();
    expect(model.previewsAcknowledged, isFalse);
    expect(model.previewRequest, request);
    expect(model.previewAcknowledgedRequest, 0);
    model.dispose();
  });

  test('a retained preview can finish starting after the visible set changes',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    await model.setPreviews(['bluestacks:one'], []);
    final first = sent.last['request_id'];
    await model.setPreviews(['bluestacks:one', 'bluestacks:two'], []);
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': first,
      'preview': true,
      'target_id': 'bluestacks:one',
      'session_id': 5,
      'state': 'starting'
    });
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': first,
      'preview': true,
      'target_id': 'bluestacks:one',
      'session_id': 5,
      'state': 'streaming',
      'width': 360,
      'height': 200
    });
    expect(model.previews['bluestacks:one']?.state, 'streaming');
    model.instances = [
      const RemoteEmulator(
          id: 'bluestacks:one',
          name: 'One',
          provider: 'bluestacks',
          state: 'ready')
    ];
    await model.desktop();
    model.handleResponse({
      'protocol_version': 1,
      'type': 'status',
      'request_id': sent.last['request_id'],
      'session_id': 0,
      'state': 'desktop'
    });
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

  test('old peer inventory leaves new host mutations unavailable', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.single['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
    });

    expect(model.hostProcessEndCapability, CapabilityStatus.unknown);
    expect(model.hostRecoveryCapability, CapabilityStatus.unknown);
    expect(model.gatewayStatusCapability, CapabilityStatus.unknown);
    final before = sent.length;
    await model.endProcess(1234);
    await model.recoverComponent('bluestacks_adb');
    await model.refreshGatewayStatus();
    expect(sent.length, before);
    model.dispose();
  });

  test('Gateway status is capability gated and parsed without mutations',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.single['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['host.gateway.status.v1'],
      'operation_session_identity': 'scope-gateway',
      'operation_generation': 2,
    });

    expect(model.gatewayStatusCapability, CapabilityStatus.supported);
    await model.refreshGatewayStatus();
    final request = Map<String, dynamic>.from(sent.last);
    expect(request['action'], 'gateway_status');
    model.handleResponse({
      'type': 'host',
      'request_id': request['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100')
          ..['version'] = 'dev'
          ..['gateway_health'] = 'ok'
          ..['api_version'] = 'v1'
          ..['setup_control_available'] = false
          ..['provider_control_available'] = false
          ..['restart_control_available'] = false,
      },
    });

    expect(model.gatewayStatusLoading, isFalse);
    expect(model.gatewayStatus?.running, isTrue);
    expect(model.gatewayStatus?.reachable, isTrue);
    expect(model.gatewayStatus?.version, 'dev');
    expect(model.gatewayStatus?.trustedPinMatched, isTrue);
    expect(model.gatewayStatus?.providerControlAvailable, isFalse);
    expect(model.gatewayStatusFresh, isTrue);
    model.dispose();
  });

  test('unsolicited zero-id Gateway status cannot replace measured state',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['host.gateway.status.v1'],
      'operation_session_identity': 'scope-gateway-zero',
      'operation_generation': 2,
    });

    model.handleResponse({
      'type': 'host',
      'request_id': 0,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:old'),
      },
    });

    expect(model.gatewayStatus, isNull);
    model.dispose();
  });

  test('unsupported Gateway schema cannot become current status', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['host.gateway.status.v1'],
      'operation_session_identity': 'scope-gateway-schema',
      'operation_generation': 2,
    });
    await model.refreshGatewayStatus();
    final request = sent.last['request_id'];
    final gateway = gatewayStatusFixture('gateway:4242:100');
    gateway['schema'] = 2;
    model.handleResponse({
      'type': 'host',
      'request_id': request,
      'protocol_version': 1,
      'host': {'ok': true, 'gateway': gateway},
    });

    expect(model.gatewayStatus, isNull);
    expect(model.gatewayError, contains('unsupported Gateway status schema'));
  });

  test('malformed Gateway status cannot throw or replace measured state',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-malformed',
      'operation_generation': 2,
    });
    await model.refreshGatewayStatus();
    model.handleResponse({
      'type': 'host',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:known'),
      },
    });
    final measured = model.gatewayStatus;
    expect(measured, isNotNull);

    for (final invalid in [
      gatewayStatusFixture('gateway:4242:bad-type')
        ..['active_sessions'] = 'one',
      gatewayStatusFixture('gateway:4242:missing')..remove('api_version'),
      gatewayStatusFixture('gateway:4242:bad-schema')..['schema'] = '1',
    ]) {
      await model.refreshGatewayStatus();
      expect(
        () => model.handleResponse({
          'type': 'host',
          'request_id': sent.last['request_id'],
          'protocol_version': 1,
          'host': {'ok': true, 'gateway': invalid},
        }),
        returnsNormally,
      );
      expect(identical(model.gatewayStatus, measured), isTrue);
      expect(model.gatewayError, contains('invalid Gateway status payload'));
      expect(model.gatewayStatusFresh, isFalse,
          reason: 'malformed rechecks must not leave mutation evidence fresh');
      final beforeMutation = sent.length;
      await model.restartGateway(confirmedStatus: measured);
      expect(sent.length, beforeMutation,
          reason: 'retained display state must not authorize a mutation');
    }
  });

  test('Gateway restart remains unreconciled until process identity changes',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-restart',
      'operation_generation': 4,
    });
    await model.refreshGatewayStatus();
    final firstStatusRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': firstStatusRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });
    final confirmed = model.gatewayStatus!;

    await model.restartGateway(confirmedStatus: confirmed);
    final restartRequest = Map<String, dynamic>.from(sent.last);
    expect(restartRequest['action'], 'gateway_restart');
    expect(restartRequest['expected_process_identity'], 'gateway:4242:100');
    expect(restartRequest['confirmed_active_sessions'], 1);
    model.handleResponse({
      'type': 'host',
      'request_id': restartRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': restartRequest['operation_id'],
        'session_identity': restartRequest['session_identity'],
        'session_generation': restartRequest['session_generation'],
        'target_identity': restartRequest['target_identity'],
        'message': 'Gateway restart requested',
      },
    });
    expect(model.gatewayNeedsReconcile, isTrue);

    await model.refreshGatewayStatus();
    final unchangedRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': unchangedRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });
    expect(model.gatewayNeedsReconcile, isTrue,
        reason:
            'an accepted restart is not complete while the same child remains');

    await model.refreshGatewayStatus();
    final startingRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': startingRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture(
          'gateway:5252:200',
          identityReady: false,
          siloState: 'remembered',
          siloProfileVerified: false,
        ),
      },
    });
    expect(model.gatewayNeedsReconcile, isTrue,
        reason: 'a new child is not ready until runtime/Silo are ready');
    expect(model.gatewayMessage, contains('runtime and Silo readiness'));

    await model.refreshGatewayStatus();
    final restartedRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': restartedRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:5252:200'),
      },
    });
    expect(model.gatewayNeedsReconcile, isFalse);
    expect(model.gatewayMessage, 'Gateway restarted and is ready.');
  });

  test(
      'ambiguous Gateway restart survives reconnect until a new child is ready',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-before-disconnect',
      'operation_generation': 8,
    });
    await model.refreshGatewayStatus();
    final statusRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': statusRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });

    await model.restartGateway(confirmedStatus: model.gatewayStatus);
    final restart = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': restart['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': false,
        'accepted': true,
        'state': 'failed',
        'outcome_unknown': true,
        'error_code': 'gateway_restart_failed',
        'error': 'Gateway local management response could not be read.',
        'operation_id': restart['operation_id'],
        'session_identity': restart['session_identity'],
        'session_generation': restart['session_generation'],
        'target_identity': restart['target_identity'],
      },
    });
    expect(
      model.hostOperationForRequest(restart['request_id'] as int)?.state,
      RemoteOperationState.unknownOutcome,
    );
    expect(model.gatewayNeedsReconcile, isTrue);

    model.invalidateConnection();
    expect(model.gatewayNeedsReconcile, isTrue,
        reason: 'disconnect must not erase an unresolved restart');

    await model.refresh();
    final reconnectInventory = sent.last['request_id'];
    model.handleResponse({
      'type': 'inventory',
      'request_id': reconnectInventory,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-after-disconnect',
      'operation_generation': 9,
    });
    expect(model.gatewayNeedsReconcile, isTrue);

    await model.refreshGatewayStatus();
    final unchangedRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': unchangedRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });
    expect(model.gatewayNeedsReconcile, isTrue);

    await model.refreshGatewayStatus();
    final restartedRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': restartedRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:5252:200'),
      },
    });
    expect(model.gatewayNeedsReconcile, isFalse);
    expect(model.gatewayMessage, 'Gateway restarted and is ready.');
  });

  test('definite Gateway restart rejection allows a fresh retry', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-definite-failure',
      'operation_generation': 3,
    });
    await model.refreshGatewayStatus();
    model.handleResponse({
      'type': 'host',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });

    await model.restartGateway(confirmedStatus: model.gatewayStatus);
    final firstRestart = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': firstRestart['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': false,
        'accepted': true,
        'state': 'failed',
        'outcome_unknown': false,
        'error_code': 'gateway_restart_failed',
        'error': 'Gateway active sessions changed.',
        'operation_id': firstRestart['operation_id'],
        'session_identity': firstRestart['session_identity'],
        'session_generation': firstRestart['session_generation'],
        'target_identity': firstRestart['target_identity'],
      },
    });
    expect(model.gatewayNeedsReconcile, isFalse);
    expect(
      model.hostOperationForRequest(firstRestart['request_id'] as int)?.state,
      RemoteOperationState.failed,
    );

    final beforeRetry = sent.length;
    await model.restartGateway(confirmedStatus: model.gatewayStatus);
    expect(sent.length, beforeRetry + 1);
    expect(sent.last['action'], 'gateway_restart');
    expect(sent.last['operation_id'], isNot(firstRestart['operation_id']));
  });

  test('accepted Gateway failure from an older peer is treated as unknown',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-old-peer',
      'operation_generation': 5,
    });
    await model.refreshGatewayStatus();
    model.handleResponse({
      'type': 'host',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': gatewayStatusFixture('gateway:4242:100'),
      },
    });

    await model.restartGateway(confirmedStatus: model.gatewayStatus);
    final restart = Map<String, dynamic>.from(sent.last);
    model.handleResponse({
      'type': 'host',
      'request_id': restart['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': false,
        'accepted': true,
        'state': 'failed',
        'error_code': 'gateway_restart_failed',
        'error': 'Older peer did not classify the outcome.',
        'operation_id': restart['operation_id'],
        'session_identity': restart['session_identity'],
        'session_generation': restart['session_generation'],
        'target_identity': restart['target_identity'],
      },
    });

    expect(
      model.hostOperationForRequest(restart['request_id'] as int)?.state,
      RemoteOperationState.unknownOutcome,
    );
    expect(model.gatewayNeedsReconcile, isTrue);
  });

  test('Gateway restart can explicitly proceed with unknown session impact',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.gateway.status.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-unknown-impact',
      'operation_generation': 2,
    });
    await model.refreshGatewayStatus();
    final statusRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': statusRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway':
            gatewayStatusFixture('gateway:4242:100', activeSessions: null),
      },
    });

    await model.restartGateway(confirmedStatus: model.gatewayStatus);
    final restart = sent.last;
    expect(restart['action'], 'gateway_restart');
    expect(restart['active_sessions_known'], isFalse);
    expect(restart['confirmed_active_sessions'], 0);
  });

  test('Phone Workspace support and owned display actions stay operation-bound',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.single['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.phone_workspace.v1',
      ],
      'operation_session_identity': 'scope-phone',
      'operation_generation': 7,
    });

    await model.refreshPhoneWorkspace();
    final supportRequest = Map<String, dynamic>.from(sent.last);
    expect(supportRequest['action'], 'phone_workspace_support');
    model.handleResponse({
      'type': 'host',
      'request_id': supportRequest['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'phone_workspace': {
          'supported': true,
          'driver': 'rustdesk_idd',
          'driver_installed': true,
          'requires_driver_install': false,
          'custom_dpi_supported': false,
          'owned_cleanup_supported': true,
          'reason': '',
          'reconciliation': 'none',
          'profiles': [
            {
              'width': 1080,
              'height': 2400,
              'orientation': 'portrait',
              'dpi': 0,
            }
          ],
          'active_session': null,
        },
      },
    });
    expect(model.phoneWorkspaceSupport?.supported, isTrue);
    final profile = model.phoneWorkspaceSupport!.profiles.single;
    expect(
      PhoneWorkspaceProfile.fromMap({
        'width': 1080,
        'height': 2400,
        'orientation': 'portrait',
        'dpi': 0,
      }),
      profile,
    );

    await model.beginPhoneWorkspace(profile);
    final begin = Map<String, dynamic>.from(sent.last);
    expect(begin['action'], 'phone_workspace_begin');
    expect(begin['session_identity'], 'scope-phone');
    expect(begin['session_generation'], 7);
    expect(
        begin['target_identity'], 'phone-workspace:new:1080x2400:portrait:0');
    final sentWhileBeginPending = sent.length;
    await model.refreshPhoneWorkspace();
    expect(sent.length, sentWhileBeginPending);
    model.handleResponse({
      'type': 'host',
      'request_id': begin['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': begin['operation_id'],
        'session_identity': 'scope-phone',
        'target_identity': begin['target_identity'],
        'session_generation': 7,
        'message': 'Phone Workspace display created',
        'phone_workspace': {
          'supported': true,
          'driver': 'rustdesk_idd',
          'driver_installed': true,
          'requires_driver_install': false,
          'custom_dpi_supported': false,
          'owned_cleanup_supported': true,
          'reason': '',
          'reconciliation': 'owned_display_present',
          'profiles': [
            {
              'width': 1080,
              'height': 2400,
              'orientation': 'portrait',
              'dpi': 0,
            }
          ],
          'active_session': {
            'id': 'phone-workspace-test',
            'driver': 'rustdesk_idd',
            'device_name': r'\\.\DISPLAY9',
            'profile': {
              'width': 1080,
              'height': 2400,
              'orientation': 'portrait',
              'dpi': 0,
            },
          },
        },
      },
    });
    expect(
        model.phoneWorkspaceSupport?.activeSession?.id, 'phone-workspace-test');
    expect(model.phoneWorkspaceMessage, contains('created'));

    await model.endPhoneWorkspace();
    final end = Map<String, dynamic>.from(sent.last);
    expect(end['action'], 'phone_workspace_end');
    expect(end['owned_display_id'], 'phone-workspace-test');
    expect(end['target_identity'], 'phone-workspace:phone-workspace-test');
    expect(end['operation_id'], isNot(begin['operation_id']));
    model.dispose();
  });

  test('negotiated host mutations carry identity and correlate concurrently',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.single['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
        'host.recover.bluestacks_adb',
      ],
      'operation_session_identity': 'scope-a',
      'operation_generation': 4,
    });
    expect(model.hostProcessEndCapability, CapabilityStatus.supported);
    expect(model.hostRecoveryCapability, CapabilityStatus.supported);

    setFreshHostProcess(model, 111, startTimeSecs: 101);
    await model.endProcess(111);
    final end = Map<String, dynamic>.from(sent.last);
    await model.recoverComponent('bluestacks_adb');
    final recover = Map<String, dynamic>.from(sent.last);

    expect(end['session_identity'], 'scope-a');
    expect(end['session_generation'], 4);
    expect(end['target_identity'], 'process:111:1010000111');
    expect(end['process_start_time_secs'], 101);
    expect(end['process_creation_time_100ns'], 1010000111);
    expect((end['operation_id'] as String).isNotEmpty, isTrue);
    expect(recover['session_identity'], 'scope-a');
    expect(recover['session_generation'], 4);
    expect(recover['target_identity'], 'component:bluestacks_adb');
    expect(recover['operation_id'], isNot(end['operation_id']));

    model.handleResponse({
      'type': 'host',
      'request_id': recover['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': recover['operation_id'],
        'session_identity': 'scope-a',
        'target_identity': 'component:bluestacks_adb',
        'session_generation': 4,
      },
    });
    expect(
      model.hostOperationForRequest(recover['request_id'] as int)?.state,
      RemoteOperationState.applied,
    );
    expect(
      model.hostOperationForRequest(end['request_id'] as int)?.state,
      RemoteOperationState.pending,
    );

    model.handleResponse({
      'type': 'host',
      'request_id': end['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': false,
        'accepted': true,
        'state': 'failed',
        'error_code': 'process_end_failed',
        'error': 'denied by Windows',
        'operation_id': end['operation_id'],
        'session_identity': 'scope-a',
        'target_identity': 'process:111:1010000111',
        'session_generation': 4,
      },
    });
    expect(
      model.hostOperationForRequest(end['request_id'] as int)?.state,
      RemoteOperationState.failed,
    );
    expect(
      model.hostOperationForRequest(end['request_id'] as int)?.error,
      'denied by Windows',
    );
    expect(
      model.hostOperationForRequest(end['request_id'] as int)?.errorCode,
      'process_end_failed',
    );
    model.dispose();
  });

  test('new operation generation invalidates late host replies', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    final firstInventory = sent.last['request_id'];
    model.handleResponse({
      'type': 'inventory',
      'request_id': firstInventory,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-a',
      'operation_generation': 10,
    });
    setFreshHostProcess(model, 222, startTimeSecs: 202);
    await model.endProcess(222);
    final operation = Map<String, dynamic>.from(sent.last);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-a',
      'operation_generation': 11,
    });
    expect(
      model.hostOperationForRequest(operation['request_id'] as int)?.state,
      RemoteOperationState.unknownOutcome,
    );

    model.handleResponse({
      'type': 'host',
      'request_id': operation['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'accepted': true,
        'state': 'applied',
        'operation_id': operation['operation_id'],
        'session_identity': 'scope-a',
        'target_identity': 'process:222:2020000222',
        'session_generation': 10,
      },
    });
    expect(
      model.hostOperationForRequest(operation['request_id'] as int)?.state,
      RemoteOperationState.unknownOutcome,
    );
    model.dispose();
  });

  test('queued host mutation revalidates scope before transport dispatch',
      () async {
    final sent = <Map<String, dynamic>>[];
    final previewBlock = Completer<void>();
    final model = EmulatorModel(
      Uuid().v4obj(),
      commandSender: (_, value) async {
        final payload = jsonDecode(value) as Map<String, dynamic>;
        sent.add(payload);
        if (payload['action'] == 'previews') {
          await previewBlock.future;
        }
      },
    );

    await model.refresh();
    final inventoryRequest = sent.single['request_id'];
    model.handleResponse({
      'type': 'inventory',
      'request_id': inventoryRequest,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-queued',
      'operation_generation': 4,
    });
    setFreshHostProcess(model, 333, startTimeSecs: 303);

    final previewFuture = model.setPreviews(const ['bluestacks:one'], const []);
    await Future<void>.delayed(Duration.zero);
    final mutationFuture = model.endProcess(333);

    model.handleResponse({
      'type': 'inventory',
      'request_id': inventoryRequest,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-queued',
      'operation_generation': 5,
    });

    previewBlock.complete();
    await previewFuture;
    await mutationFuture;

    expect(
        sent.where((payload) => payload['action'] == 'process_end'), isEmpty);
    model.dispose();
  });

  test('inventory generation change invalidates in-flight host status',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [],
      'operation_session_identity': 'scope-status-a',
      'operation_generation': 1,
    });
    setFreshHostProcess(model, 334, startTimeSecs: 304);
    await model.refreshHost();
    final staleStatusRequest = sent.last['request_id'] as int;

    await model.refresh();
    final nextInventoryRequest = sent.last['request_id'] as int;
    model.handleResponse({
      'type': 'inventory',
      'request_id': nextInventoryRequest,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [],
      'operation_session_identity': 'scope-status-b',
      'operation_generation': 2,
    });

    expect(model.hostSnapshot, isNull,
        reason:
            'host evidence from the previous generation is no longer current');
    expect(model.hostLoading, isFalse);

    model.handleResponse({
      'type': 'host',
      'request_id': staleStatusRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'snapshot': {
          'schema': 3,
          'sampled_at_ms': 1,
          'source': 'windows_sysinfo',
          'cpu_percent': 99,
          'logical_cpus': 8,
          'memory_used_bytes': 4,
          'memory_total_bytes': 8,
          'uptime_secs': 10,
          'processes': const [],
          'watchdog': const {'running': true, 'components': []},
        },
      },
    });
    expect(model.hostSnapshot, isNull,
        reason: 'a late response from the previous generation must be ignored');
    model.dispose();
  });

  test('queued host mutation that times out is not dispatched later', () async {
    final sent = <Map<String, dynamic>>[];
    final previewBlock = Completer<void>();
    final model = EmulatorModel(
      Uuid().v4obj(),
      hostOperationTimeout: const Duration(milliseconds: 10),
      commandSender: (_, value) async {
        final payload = jsonDecode(value) as Map<String, dynamic>;
        sent.add(payload);
        if (payload['action'] == 'previews') {
          await previewBlock.future;
        }
      },
    );

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-timeout',
      'operation_generation': 1,
    });
    setFreshHostProcess(model, 335, startTimeSecs: 305);

    final previewFuture = model.setPreviews(const ['bluestacks:one'], const []);
    await Future<void>.delayed(Duration.zero);
    final mutationFuture = model.endProcess(335);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    previewBlock.complete();
    await previewFuture;
    await mutationFuture;

    expect(
      sent.where((payload) => payload['action'] == 'process_end'),
      isEmpty,
      reason: 'a timed-out queued mutation must not reach the host later',
    );
    model.dispose();
  });

  test(
      'transport invalidation makes retained host evidence stale and rejects late replies',
      () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    final inventoryRequest = sent.last['request_id'] as int;
    model.handleResponse({
      'type': 'inventory',
      'request_id': inventoryRequest,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-disconnect',
      'operation_generation': 9,
    });
    setFreshHostProcess(model, 991, startTimeSecs: 991);
    await model.endProcess(991);
    final mutationRequest = sent.last['request_id'] as int;
    final before = model.hostSnapshot;
    expect(model.hostConnectionCurrent, isTrue);

    model.invalidateConnection();

    expect(model.hostSnapshot, same(before));
    expect(model.hostConnectionCurrent, isFalse);
    expect(model.hostSnapshotFresh, isFalse);
    expect(
      model.hostOperationForRequest(mutationRequest)?.state,
      RemoteOperationState.unknownOutcome,
    );

    model.handleResponse({
      'type': 'inventory',
      'request_id': inventoryRequest,
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [],
      'operation_session_identity': 'late-scope',
      'operation_generation': 99,
    });
    expect(model.hostConnectionCurrent, isFalse,
        reason:
            'a reply issued before disconnect must not restore current state');
    model.dispose();
  });

  test('queued host status is discarded when transport disconnects', () async {
    final sent = <Map<String, dynamic>>[];
    final previewBlock = Completer<void>();
    final model = EmulatorModel(
      Uuid().v4obj(),
      commandSender: (_, value) async {
        final payload = jsonDecode(value) as Map<String, dynamic>;
        sent.add(payload);
        if (payload['action'] == 'previews') {
          await previewBlock.future;
        }
      },
    );

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [],
      'operation_session_identity': 'scope-status-disconnect',
      'operation_generation': 1,
    });

    final previewFuture = model.setPreviews(const ['bluestacks:one'], const []);
    await Future<void>.delayed(Duration.zero);
    final statusFuture = model.refreshHost();
    model.invalidateConnection();
    previewBlock.complete();
    await previewFuture;
    await statusFuture;

    expect(
      sent.where((payload) => payload['action'] == 'host_status'),
      isEmpty,
      reason:
          'queued status work from a disconnected transport must not send later',
    );
    model.dispose();
  });

  test('host status reply does not clear a pending mutation', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
      ],
      'operation_session_identity': 'scope-overlap',
      'operation_generation': 3,
    });

    setFreshHostProcess(model, 4321, startTimeSecs: 303);
    await model.endProcess(4321);
    final mutationRequest = sent.last['request_id'] as int;
    await model.refreshHost();
    final statusRequest = sent.last['request_id'] as int;
    expect(statusRequest, isNot(mutationRequest));
    expect(model.hostLoading, isTrue);

    model.handleResponse({
      'type': 'host',
      'request_id': statusRequest,
      'protocol_version': 1,
      'host': {'ok': false, 'error': 'status unavailable'},
    });

    expect(model.hostLoading, isTrue,
        reason: 'The process mutation still has no acknowledgment');
    expect(
      model.hostOperationForRequest(mutationRequest)?.state,
      RemoteOperationState.pending,
    );
    model.dispose();
  });

  test('loads host health and sends bounded management actions', () async {
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(Uuid().v4obj(),
        commandSender: (_, value) async => sent.add(jsonDecode(value)));

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const [
        'operation.identity.v1',
        'operation.ack.v1',
        'host.process_end',
        'host.process_identity.v2',
        'host.recover.bluestacks_adb',
      ],
      'operation_session_identity': 'scope-host-test',
      'operation_generation': 1,
    });

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
          'schema': 3,
          'sampled_at_ms': 123456,
          'source': 'windows_sysinfo',
          'cpu_percent': 42.5,
          'cpu_name': 'Test CPU',
          'logical_cpus': 8,
          'memory_used_bytes': 4294967296,
          'memory_total_bytes': 8589934592,
          'uptime_secs': 7200,
          'processes': [
            {
              'pid': 1234,
              'start_time_secs': 404,
              'creation_time_100ns': 4040001234,
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
    expect(sent.last['process_start_time_secs'], 404);
    expect(sent.last['process_creation_time_100ns'], 4040001234);
    expect(sent.last['target_identity'], 'process:1234:4040001234');

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
    markCurrentGuestFrameDecoded(model);
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
