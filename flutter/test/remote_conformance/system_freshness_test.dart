import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/host_management_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/models/host_management_model.dart';
import 'package:uuid/uuid.dart';

HostSystemSnapshot _snapshot({
  int? receivedMonotonicMs,
  int? requestStartedMonotonicMs,
  int sampledAtMs = 1000,
  int processStartTimeSecs = 77,
  int processCreationTime100ns = 990077,
}) {
  return HostSystemSnapshot(
    schema: 3,
    sampledAtMs: sampledAtMs,
    source: 'windows_sysinfo',
    receivedMonotonicMs: receivedMonotonicMs ?? hostMonotonicNowMs(),
    requestStartedMonotonicMs: requestStartedMonotonicMs ?? -1,
    cpuPercent: 25,
    cpuName: 'Test CPU',
    logicalCpus: 8,
    memoryUsedBytes: 4 * 1024 * 1024,
    memoryTotalBytes: 8 * 1024 * 1024,
    uptimeSecs: 600,
    processes: [
      HostProcessInfo(
        pid: 1234,
        startTimeSecs: processStartTimeSecs,
        creationTime100ns: processCreationTime100ns,
        name: 'game.exe',
        cpuPercent: 12.5,
        memoryBytes: 1024,
        executable: r'C:\Games\game.exe',
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

Future<EmulatorModel> _connectedModel(List<Map<String, dynamic>> sent) async {
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
    'capabilities': const [
      'operation.identity.v1',
      'operation.ack.v1',
      'host.process_end',
      'host.process_identity.v2',
    ],
    'operation_session_identity': 'scope-system',
    'operation_generation': 2,
  });
  return model;
}

void main() {
  testWidgets('stale_sample_loses_live_label', (tester) async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent);
    addTearDown(model.dispose);
    model.hostSnapshot = _snapshot(
      receivedMonotonicMs:
          hostMonotonicNowMs() - HostSystemSnapshot.freshFor.inMilliseconds - 1,
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostManagementPage(
          model: model,
          active: false,
          canControl: true,
        ),
      ),
    ));

    expect(find.textContaining('Stale • Last updated'), findsOneWidget);
    expect(find.text('Active'), findsNothing,
        reason: 'a stale watchdog sample must not still claim Active');
    expect(find.byTooltip('End task'), findsNothing);
  });

  test('clock_skew_does_not_make_future_freshness', () {
    final snapshot = _snapshot(
      receivedMonotonicMs: 1000,
      sampledAtMs: 4102444800000,
    );

    expect(snapshot.isFreshAt(1001, connected: true), isTrue);
    expect(snapshot.isFreshAt(17000, connected: true), isFalse,
        reason: 'Host wall-clock timestamps never extend local freshness');
  });

  test('slow_status_response_is_stale_on_arrival', () {
    final snapshot = _snapshot(
      receivedMonotonicMs: 20000,
      requestStartedMonotonicMs:
          20000 - HostSystemSnapshot.freshFor.inMilliseconds - 1,
    );

    expect(snapshot.isFreshAt(20000, connected: true), isFalse);
  });

  test('unsupported_metric_not_zero', () {
    final snapshot = HostSystemSnapshot.fromMap(
      const <String, dynamic>{
        'schema': 2,
        'sampled_at_ms': 1,
        'source': 'windows_sysinfo',
      },
      receivedMonotonicMs: 1,
    );

    expect(snapshot.cpuPercent, isNull);
    expect(snapshot.memoryUsedBytes, isNull);
    expect(snapshot.memoryTotalBytes, isNull);
    expect(snapshot.uptimeSecs, isNull);
  });

  test('end_task_denial_keeps_process_visible', () async {
    final sent = <Map<String, dynamic>>[];
    final model = await _connectedModel(sent);
    addTearDown(model.dispose);
    model.hostSnapshot = _snapshot();

    await model.endProcess(
      1234,
      startTimeSecs: 77,
      creationTime100ns: 990077,
    );
    final request = Map<String, dynamic>.from(sent.last);
    expect(request['target_identity'], 'process:1234:990077');

    model.handleResponse({
      'type': 'host',
      'request_id': request['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': false,
        'accepted': true,
        'state': 'failed',
        'error_code': 'process_end_failed',
        'error': 'Windows denied the request',
        'operation_id': request['operation_id'],
        'session_identity': 'scope-system',
        'target_identity': 'process:1234:990077',
        'session_generation': 2,
      },
    });

    expect(model.hostSnapshot?.processes.single.pid, 1234);
    expect(model.hostSnapshot?.processes.single.startTimeSecs, 77);
    expect(model.hostError, 'Windows denied the request');
  });
}
