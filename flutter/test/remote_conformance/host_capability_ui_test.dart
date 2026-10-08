import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/host_management_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/models/host_management_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  Map<String, dynamic> gatewayFixture({
    String health = 'ready',
    bool refreshing = false,
  }) =>
      {
        'schema': 1,
        'sampled_at_ms': 1000,
        'installed': true,
        'process_state': 'running',
        'gateway_pid': 4242,
        'process_identity': 'gateway:4242:100',
        'version': '5.22',
        'reachability': 'reachable',
        'gateway_health': health,
        'api_version': '1',
        'trusted_pin_matched': true,
        'protected_health_available': true,
        'identity_ready': true,
        'silo_state': 'verified',
        'silo_profile_selected': true,
        'silo_profile_verified': true,
        'active_sessions': 0,
        'max_sessions': 3,
        'imdb_enabled': true,
        'imdb_state': refreshing ? 'refreshing' : 'fresh',
        'imdb_refreshing': refreshing,
        'imdb_updated_at': '2026-10-06T19:00:00Z',
        'setup_control_available': true,
        'provider_control_available': true,
        'restart_control_available': true,
        'detail': 'Healthy',
      };

  testWidgets('old_peer_hides_destructive_host_actions_until_negotiated',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
    addTearDown(model.dispose);
    final hostSnapshot = HostSystemSnapshot(
      schema: 3,
      sampledAtMs: 1000,
      source: 'windows_sysinfo',
      receivedMonotonicMs: hostMonotonicNowMs(),
      cpuPercent: 10,
      cpuName: 'CPU',
      logicalCpus: 8,
      memoryUsedBytes: 4,
      memoryTotalBytes: 8,
      uptimeSecs: 10,
      processes: const [
        HostProcessInfo(
          pid: 1234,
          startTimeSecs: 55,
          creationTime100ns: 990055,
          name: 'game.exe',
          cpuPercent: 2,
          memoryBytes: 1024,
          executable: r'C:\Games\game.exe',
          canEnd: true,
        ),
      ],
      watchdog: const HostWatchdogInfo(
        running: true,
        lastCheckMs: 1,
        lastRecoveryMs: 0,
        components: [
          HostComponentHealth(
            id: 'bluestacks_adb',
            label: 'BlueStacks ADB',
            state: 'healthy',
            detail: '1/1 reachable',
            recoverable: true,
          ),
        ],
      ),
    );
    model.hostSnapshot = hostSnapshot;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostManagementPage(
          model: model,
          active: false,
          canControl: true,
        ),
      ),
    ));

    expect(find.byTooltip('End task'), findsNothing);
    expect(find.byTooltip('Recover BlueStacks ADB'), findsNothing);
    expect(find.text('Services'), findsNothing);
    expect(find.text('Marquee Gateway'), findsNothing);

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
      'operation_session_identity': 'scope-ui',
      'operation_generation': 1,
    });
    model.hostSnapshot = hostSnapshot;
    await tester.pump();

    expect(find.byTooltip('End task'), findsOneWidget);
    expect(find.byTooltip('Recover BlueStacks ADB'), findsOneWidget);
    expect(find.text('Services'), findsNothing,
        reason: 'old peers must not expose unsupported Gateway UI');
  });

  testWidgets('Gateway service appears only after capability negotiation',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
    addTearDown(model.dispose);

    await model.refresh();
    model.handleResponse({
      'type': 'inventory',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'instances': const [],
      'provider_errors': const [],
      'capabilities': const ['host.gateway.status.v1'],
      'operation_session_identity': 'scope-gateway-ui',
      'operation_generation': 1,
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostManagementPage(
          model: model,
          active: false,
          canControl: true,
        ),
      ),
    ));

    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Marquee Gateway'), findsOneWidget);
  });

  testWidgets(
      'Gateway panel exposes verified setup provider and restart controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 2000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
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
        'host.gateway.setup.v1',
        'host.gateway.imdb.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-controls',
      'operation_generation': 3,
    });
    await model.refreshGatewayStatus();
    final statusRequest = sent.last['request_id'];
    model.handleResponse({
      'type': 'host',
      'request_id': statusRequest,
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': {
          'schema': 1,
          'sampled_at_ms': 1000,
          'installed': true,
          'process_state': 'running',
          'gateway_pid': 4242,
          'process_identity': 'gateway:4242:100',
          'version': '5.22',
          'reachability': 'reachable',
          'gateway_health': 'ready',
          'api_version': '1',
          'trusted_pin_matched': true,
          'protected_health_available': true,
          'identity_ready': true,
          'silo_state': 'verified',
          'silo_profile_selected': true,
          'silo_profile_verified': true,
          'active_sessions': null,
          'max_sessions': 3,
          'imdb_enabled': true,
          'imdb_state': 'fresh',
          'imdb_refreshing': false,
          'imdb_updated_at': '2026-10-06T19:00:00Z',
          'setup_control_available': true,
          'provider_control_available': true,
          'restart_control_available': true,
          'detail': 'Healthy',
        },
      },
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostManagementPage(
          model: model,
          active: false,
          canControl: true,
        ),
      ),
    ));
    await tester.tap(find.text('Gateway healthy'));
    await tester.pumpAndSettle();

    expect(find.text('Open setup on Windows'), findsOneWidget);
    expect(find.text('Disable IMDb'), findsOneWidget);
    expect(find.text('Refresh IMDb'), findsOneWidget);
    expect(find.text('Restart Gateway'), findsNWidgets(2));
    expect(find.textContaining('not available yet'), findsNothing);

    final restartButton = find.text('Restart Gateway').last;
    await tester.ensureVisible(restartButton);
    await tester.tap(restartButton);
    await tester.pumpAndSettle();
    expect(find.text('Restart anyway'), findsOneWidget);
    expect(find.textContaining('may interrupt active Gateway sessions'),
        findsOneWidget);
  });

  testWidgets('Gateway panel remains usable at phone width and large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
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
        'host.gateway.setup.v1',
        'host.gateway.imdb.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-large-text',
      'operation_generation': 4,
    });
    await model.refreshGatewayStatus();
    model.handleResponse({
      'type': 'host',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'host': {
        'ok': true,
        'gateway': {
          'schema': 1,
          'sampled_at_ms': 1000,
          'installed': true,
          'process_state': 'running',
          'gateway_pid': 4242,
          'process_identity': 'gateway:4242:100',
          'version': '5.22.123.4567',
          'reachability': 'reachable',
          'gateway_health': 'ready',
          'api_version': '1',
          'trusted_pin_matched': true,
          'protected_health_available': true,
          'identity_ready': true,
          'silo_state': 'verified',
          'silo_profile_selected': true,
          'silo_profile_verified': true,
          'active_sessions': 2,
          'max_sessions': 3,
          'imdb_enabled': true,
          'imdb_state': 'fresh',
          'imdb_refreshing': false,
          'imdb_updated_at': '2026-10-06T19:00:00Z',
          'setup_control_available': true,
          'provider_control_available': true,
          'restart_control_available': true,
          'detail':
              'Verified local management is ready and all required runtime checks passed.',
        },
      },
    });

    Future<void> pumpAtScale(double scale) => tester.pumpWidget(MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
            ),
            child: child!,
          ),
          home: Scaffold(
            body: HostManagementPage(
              model: model,
              active: false,
              canControl: true,
            ),
          ),
        ));

    await pumpAtScale(1.0);
    await tester.tap(find.text('Gateway healthy'));
    await tester.pumpAndSettle();

    for (final scale in const [1.0, 1.3, 2.0]) {
      await pumpAtScale(scale);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
      expect(find.text('Open setup on Windows'), findsOneWidget);
      expect(find.text('Refresh IMDb'), findsOneWidget);
      expect(find.text('Restart Gateway'), findsNWidgets(2));
    }
  });

  testWidgets(
      'Gateway panel reports unmeasured health and disables mutations in view-only sessions',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
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
        'host.gateway.setup.v1',
        'host.gateway.imdb.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-view-only',
      'operation_generation': 5,
    });
    await model.refreshGatewayStatus();
    model.handleResponse({
      'type': 'host',
      'request_id': sent.last['request_id'],
      'protocol_version': 1,
      'host': {'ok': true, 'gateway': gatewayFixture(health: '')},
    });

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: HostManagementPage(
          model: model,
          active: false,
          canControl: false,
        ),
      ),
    ));
    await tester.tap(find.text('Gateway running'));
    await tester.pumpAndSettle();

    expect(find.text('Not measured'), findsOneWidget);
    expect(find.textContaining('view-only'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.ancestor(
            of: find.text('Open setup on Windows'),
            matching:
                find.byWidgetPredicate((widget) => widget is OutlinedButton),
          ))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.ancestor(
            of: find.text('Disable IMDb'),
            matching:
                find.byWidgetPredicate((widget) => widget is OutlinedButton),
          ))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.ancestor(
            of: find.text('Restart Gateway').last,
            matching:
                find.byWidgetPredicate((widget) => widget is OutlinedButton),
          ))
          .onPressed,
      isNull,
    );
  });

  testWidgets('Gateway stale and refreshing states disable unsafe controls',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <Map<String, dynamic>>[];
    final model = EmulatorModel(
      const Uuid().v4obj(),
      commandSender: (_, value) async => sent.add(jsonDecode(value)),
    );
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
        'host.gateway.setup.v1',
        'host.gateway.imdb.v1',
        'host.gateway.restart.v1',
      ],
      'operation_session_identity': 'scope-gateway-stale',
      'operation_generation': 6,
    });
    final staleAt = hostMonotonicNowMs() -
        GatewayStatus.freshFor.inMilliseconds -
        const Duration(seconds: 1).inMilliseconds;
    model.gatewayStatus = GatewayStatus.fromMap(
      gatewayFixture(refreshing: true),
      receivedMonotonicMs: staleAt,
      requestStartedMonotonicMs: staleAt,
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
    await tester.tap(find.text('Gateway running'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Stale'), findsWidgets);
    expect(find.text('Refreshing'), findsOneWidget);
    final refreshButton = tester.widget<FilledButton>(find.ancestor(
      of: find.text('Refresh IMDb'),
      matching: find.byWidgetPredicate((widget) => widget is FilledButton),
    ));
    expect(refreshButton.onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(find.ancestor(
            of: find.text('Restart Gateway').last,
            matching:
                find.byWidgetPredicate((widget) => widget is OutlinedButton),
          ))
          .onPressed,
      isNull,
    );
    model.invalidateConnection();
  });
}
