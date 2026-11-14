import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/codex_model.dart';
import 'package:flutter_hbb/models/remote_operation_state.dart';
import 'package:flutter_hbb/models/task_notification_policy.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('loads threads and prepends older history pages', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await model.listThreads();
    final threadRequest = sent.single.value;
    model.handleResponse({
      'type': 'thread_list',
      'request_id': threadRequest,
      'service_state': 'ready',
      'codex_version': '0.155.1',
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Build remote UI',
          'project': '',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });

    expect(model.loadingThreads, isFalse);
    expect(model.serviceState, 'ready');
    expect(model.threads.single.title, 'Build remote UI');

    await model.selectThread('thr_1');
    final initialHistoryCommand =
        sent.lastWhere((command) => command.key == 'codex-thread-history');
    final initialPayload = jsonDecode(initialHistoryCommand.value);
    model.handleResponse({
      'type': 'thread_history',
      'request_id': initialPayload['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': 'older-page',
      'items': [
        _item('item_2', 'agent_message', 'Second'),
        _item('item_3', 'user_message', 'Third'),
      ],
    });

    await model.loadHistory('thr_1', reset: false);
    final olderHistoryCommand =
        sent.lastWhere((command) => command.key == 'codex-thread-history');
    final olderPayload = jsonDecode(olderHistoryCommand.value);
    expect(olderPayload['cursor'], 'older-page');
    model.handleResponse({
      'type': 'thread_history',
      'request_id': olderPayload['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'items': [_item('item_1', 'user_message', 'First')],
    });

    expect(
      model.historyFor('thr_1').map((item) => item.id),
      ['item_1', 'item_2', 'item_3'],
    );
  });

  test('applies normalized live deltas and thread state updates', () {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Live task',
          'project': '',
          'originator': '',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    model.handleResponse({
      'type': 'thread_history',
      'request_id': 'history',
      'thread_id': 'thr_1',
      'next_cursor': '',
      'items': [_item('item_1', 'agent_message', 'Hello')],
    });

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': 'item_1',
      'kind': 'item_updated',
      'state': 'unavailable',
      'history_kind': 'agent_message',
      'text': ' world',
      'status': '',
    });
    expect(model.historyFor('thr_1').single.text, 'Hello world');

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': 'item_1',
      'kind': 'item_completed',
      'state': 'unavailable',
      'history_kind': 'agent_message',
      'text': 'Hello world!',
      'status': 'completed',
    });
    expect(model.historyFor('thr_1').single.text, 'Hello world!');
    expect(model.historyFor('thr_1').single.status, 'completed');

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    expect(model.threads.single.state, 'working');
  });

  test('history does not imply live control and explicit resume attaches',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-control'),
      'control': {
        'resume_thread': true,
        'start_thread': true,
        'start_turn': true,
        'steer_turn': true,
        'interrupt_turn': true,
      },
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Persisted desktop task',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'resumable',
        }
      ],
    });

    expect(model.canResumeThread, isTrue);
    expect(model.canStartThread, isTrue);
    expect(model.canStartTurn, isTrue);
    expect(model.canSteerTurn, isTrue);
    expect(model.canInterruptTurn, isTrue);
    expect(model.needsNativeResume('thr_1'), isTrue);

    await model.selectThread('thr_1');
    expect(
      sent.where((command) => command.key == 'codex-resume-thread'),
      isEmpty,
    );
    expect(model.threads.single.state, 'resumable');
    expect(model.isControlPending('thr_1'), isFalse);
    expect(
      sent.where((command) => command.key == 'codex-list-approvals'),
      isEmpty,
    );
    expect(
      sent.where((command) => command.key == 'codex-event-subscription'),
      isEmpty,
    );

    final resuming = model.resumeThread('thr_1');
    await Future<void>.delayed(Duration.zero);
    final resume =
        sent.lastWhere((command) => command.key == 'codex-resume-thread');
    expect(resume.key, 'codex-resume-thread');
    final resumePayload = jsonDecode(resume.value);
    expect(resumePayload['thread_id'], 'thr_1');
    expect((resumePayload['operation_id'] as String).isNotEmpty, isTrue);
    expect(resumePayload['session_identity'], 'scope-control');
    expect(resumePayload['target_identity'], 'thread:thr_1');
    expect(resumePayload['session_generation'], 1);
    expect(model.isControlPending('thr_1'), isTrue);
    expect(
      sent.where((command) => command.key == 'codex-list-approvals'),
      isEmpty,
    );
    expect(
      sent.where((command) => command.key == 'codex-event-subscription'),
      isEmpty,
    );

    model.handleControlResponse({
      'type': 'result',
      'request_id': resumePayload['request_id'],
      ..._codexAck(resumePayload),
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': '',
      'state': 'idle',
    });
    await resuming;
    expect(model.threads.single.state, 'idle');
    expect(model.isControlPending('thr_1'), isFalse);
    expect(
      sent.where((command) => command.key == 'codex-list-approvals'),
      isNotEmpty,
    );
    expect(
      sent.where((command) => command.key == 'codex-event-subscription'),
      isNotEmpty,
    );

    await model.send('thr_1', 'Implement the control path');
    final start = sent.last;
    expect(start.key, 'codex-start-turn');
    final startPayload = jsonDecode(start.value);
    expect(startPayload['thread_id'], 'thr_1');
    expect(startPayload['text'], 'Implement the control path');

    model.handleControlResponse({
      'type': 'result',
      'request_id': startPayload['request_id'],
      ..._codexAck(startPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.activeTurnIdFor('thr_1'), isEmpty);
    expect(model.isTurnStarting('thr_1'), isTrue);
    final sentBeforePrematureInterrupt = sent.length;
    await model.interrupt('thr_1');
    expect(sent.length, sentBeforePrematureInterrupt);

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    expect(model.activeTurnIdFor('thr_1'), 'turn_1');
    expect(model.isTurnStarting('thr_1'), isFalse);
    expect(model.threads.single.state, 'working');

    await model.steer('thr_1', 'Use the existing RustDesk transport');
    final steer = sent.last;
    expect(steer.key, 'codex-steer-turn');
    final steerPayload = jsonDecode(steer.value);
    expect(steerPayload['turn_id'], 'turn_1');
    expect(steerPayload['text'], 'Use the existing RustDesk transport');

    model.handleControlResponse({
      'type': 'result',
      'request_id': steerPayload['request_id'],
      ..._codexAck(steerPayload),
      'action': 'turn_steered',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });

    await model.interrupt('thr_1');
    final interrupt = sent.last;
    expect(interrupt.key, 'codex-interrupt-turn');
    final interruptPayload = jsonDecode(interrupt.value);
    expect(interruptPayload['turn_id'], 'turn_1');
    model.handleControlResponse({
      'type': 'result',
      'request_id': interruptPayload['request_id'],
      ..._codexAck(interruptPayload),
      'action': 'turn_interrupted',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'interrupting',
    });
    expect(model.threads.single.state, 'interrupting');

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': 'interrupted',
    });
    expect(model.activeTurnIdFor('thr_1'), isEmpty);
    expect(model.threads.single.state, 'idle');
  });

  test('starts a new task from a host-issued workspace without exposing a path',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-start-thread'),
      'control': {'start_thread': true},
      'threads': [
        {
          'id': 'thr_workspace',
          'title': 'RustDesk control work',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'resumable',
        }
      ],
    });

    await model.listWorkspaces();
    final workspaceCommand =
        sent.lastWhere((command) => command.key == 'codex-list-workspaces');
    final workspacePayload = jsonDecode(workspaceCommand.value);
    model.handleResponse({
      'type': 'workspace_list',
      'request_id': workspacePayload['request_id'],
      'next_cursor': '',
      'workspaces': const [
        {
          'id': 'ws_opaque',
          'name': 'RustDesk',
          'path': r'C:\Programming Projects\MIRPG\rustdesk-emulator-remote',
          'accessible': true,
          'status': 'Available',
        }
      ],
    });

    await model.startThread(workspaceId: 'ws_opaque');
    final start = sent.last;
    expect(start.key, 'codex-start-thread');
    final payload = jsonDecode(start.value);
    expect(payload['workspace_id'], 'ws_opaque');
    expect(payload.containsKey('workspace_thread_id'), isFalse);
    expect(payload.containsKey('cwd'), isFalse);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'thread_started',
      'thread_id': 'thr_new',
      'turn_id': '',
      'state': 'idle',
    });

    expect(model.lastStartedThreadId, 'thr_new');
    final created =
        model.threads.firstWhere((thread) => thread.id == 'thr_new');
    expect(created.project, 'RustDesk');
    expect(created.state, 'idle');
  });

  test(
      'workspace paging merges opaque roots and keeps unavailable roots disabled',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-workspaces'),
      'control': {'start_thread': true},
      'threads': const [],
    });

    await model.listWorkspaces();
    var request = jsonDecode(sent.last.value);
    model.handleResponse({
      'type': 'workspace_list',
      'request_id': request['request_id'],
      'next_cursor': 'workspace:snapshot:1',
      'workspaces': const [
        {
          'id': 'ws_1',
          'name': 'One',
          'path': r'C:\One',
          'accessible': true,
          'status': 'Available',
        }
      ],
    });
    expect(model.workspaces.single.id, 'ws_1');
    expect(model.nextWorkspaceCursor, 'workspace:snapshot:1');

    await model.listWorkspaces(reset: false);
    request = jsonDecode(sent.last.value);
    expect(request['cursor'], 'workspace:snapshot:1');
    model.handleResponse({
      'type': 'workspace_list',
      'request_id': request['request_id'],
      'next_cursor': '',
      'workspaces': const [
        {
          'id': 'ws_2',
          'name': 'Two',
          'path': r'C:\Two',
          'accessible': false,
          'status': 'Workspace is unavailable on this host',
        }
      ],
    });
    expect(model.workspaces.map((workspace) => workspace.id), ['ws_1', 'ws_2']);
    expect(model.workspaces.last.accessible, isFalse);

    await model.startThread(workspaceId: 'ws_2');
    expect(
        sent.where((command) => command.key == 'codex-start-thread'), isEmpty);
    expect(model.workspaceError, 'Choose an available host workspace.');
  });

  test('older host cannot start a task without negotiated workspace support',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.154.0',
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
      ],
      'operation_session_identity': 'old-peer',
      'operation_generation': 1,
      'control': {'start_thread': true},
      'threads': const [],
    });

    expect(model.supportsWorkspaces, isFalse);
    expect(model.canStartInWorkspace, isFalse);
    await model.startThread(workspaceId: 'C:\\raw-path');
    expect(
        sent.where((command) => command.key == 'codex-start-thread'), isEmpty);
  });

  test('reconciles remote approvals and prevents stale client replay',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-approval-reconcile'),
      'control': {'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Approval task',
          'project': 'RustDesk',
          'originator': '',
          'updated_at': 1,
          'state': 'working',
        }
      ],
    });

    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_old', 'cargo test old'),
    });
    expect(model.approvalsFor('thr_1').single.id, 'approval_old');
    expect(model.threads.single.state, 'waiting_for_approval');

    model.handleResponse({
      'type': 'approval_list',
      'request_id': 'approvals-1',
      'thread_id': 'thr_1',
      'approvals': [_approval('approval_live', 'cargo test codex')],
    });
    expect(model.approvalsFor('thr_1').single.id, 'approval_live');

    final staleActionable = model.approvalsFor('thr_1').single;
    model.handleResponse({
      'type': 'approval_list',
      'request_id': 'approvals-unknown-outcome',
      'thread_id': 'thr_1',
      'approvals': [
        {..._approval('approval_live', 'cargo test codex'), 'actionable': false}
      ],
    });
    final sentBeforeUnknownReplay = sent.length;
    await model.respondToApproval(staleActionable, true);
    expect(sent.length, sentBeforeUnknownReplay);
    expect(model.errorFor('thr_1'), contains('no longer actionable'));

    model.handleResponse({
      'type': 'approval_list',
      'request_id': 'approvals-2',
      'thread_id': 'thr_1',
      'approvals': [_approval('approval_live', 'cargo test codex')],
    });
    final live = model.approvalsFor('thr_1').single;
    await model.respondToApproval(live, true);
    final response = sent.last;
    expect(response.key, 'codex-respond-approval');
    final payload = jsonDecode(response.value);
    expect(payload['approval_id'], 'approval_live');
    expect(payload['thread_id'], 'thr_1');
    expect(payload['turn_id'], 'turn_1');
    expect(payload['decision'], 'approve');
    expect(model.isApprovalPending('approval_live'), isTrue);

    model.handleResponse({
      'type': 'approval_resolved',
      'approval_id': 'approval_live',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'decision': 'approve',
    });
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'approval_approved',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.approvalsFor('thr_1'), isEmpty);

    final sentBeforeReplay = sent.length;
    await model.respondToApproval(live, false);
    expect(sent.length, sentBeforeReplay);
    expect(model.errorFor('thr_1'), contains('no longer active'));
  });

  test('approval control errors trigger immediate reconciliation', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-approval-error'),
      'control': {'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Approval task',
          'project': '',
          'originator': '',
          'updated_at': 1,
          'state': 'waiting_for_approval',
        }
      ],
    });
    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_1', 'cargo test'),
    });

    await model.respondToApproval(model.approvalsFor('thr_1').single, true);
    final responsePayload = jsonDecode(sent.last.value);
    model.handleControlResponse({
      'type': 'error',
      'request_id': responsePayload['request_id'],
      ..._codexAck(responsePayload, applied: false),
      'error_code': 'approval_failed',
      'thread_id': 'thr_1',
      'message': 'Codex app-server stream disconnected',
    });

    expect(sent.last.key, 'codex-list-approvals');
    expect(model.errorFor('thr_1'), contains('disconnected'));
  });

  test('denies a current actionable approval with the deny decision', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-approval-deny'),
      'control': {'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Approval task',
          'project': '',
          'originator': '',
          'updated_at': 1,
          'state': 'waiting_for_approval',
        }
      ],
    });
    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_deny', 'cargo test'),
    });

    await model.respondToApproval(model.approvalsFor('thr_1').single, false);

    expect(sent.last.key, 'codex-respond-approval');
    final payload = jsonDecode(sent.last.value);
    expect(payload['approval_id'], 'approval_deny');
    expect(payload['turn_id'], 'turn_1');
    expect(payload['decision'], 'deny');
  });

  test('turn completion invalidates approval cards for that turn', () {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-approval-complete'),
      'control': {'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Approval task',
          'project': '',
          'originator': '',
          'updated_at': 1,
          'state': 'waiting_for_approval',
        }
      ],
    });
    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_1', 'cargo test'),
    });
    expect(model.approvalsFor('thr_1'), hasLength(1));

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': 'completed',
    });

    expect(model.approvalsFor('thr_1'), isEmpty);
  });

  test('live actionable approval emits one task notification', () async {
    final alerts = <TaskNotificationAlert>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
      taskNotificationsEnabled: true,
      notificationRuntimeIdProvider: () => 'pc-1',
      notificationPermissionRequester: () async => true,
      notificationSender: (alert) async {
        alerts.add(alert);
        return true;
      },
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'threads': [_thread('thr_1', 'working')],
    });

    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_notify', 'cargo test'),
    });
    await Future<void>.delayed(Duration.zero);
    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_notify', 'cargo test'),
    });
    await Future<void>.delayed(Duration.zero);

    expect(alerts, hasLength(1));
    expect(alerts.single.title, 'Codex needs your approval');
    expect(alerts.single.deepLink.host, 'pc-1');
    expect(alerts.single.deepLink.queryParameters['codex_thread'], 'thr_1');
  });

  test('approval refresh seeds history without notifying after reconnect',
      () async {
    final alerts = <TaskNotificationAlert>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
      taskNotificationsEnabled: true,
      notificationRuntimeIdProvider: () => 'pc-1',
      notificationPermissionRequester: () async => true,
      notificationSender: (alert) async {
        alerts.add(alert);
        return true;
      },
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'threads': [_thread('thr_1', 'waiting_for_approval')],
    });
    model.handleResponse({
      'type': 'approval_list',
      'request_id': 'approvals-reconnect',
      'thread_id': 'thr_1',
      'approvals': [_approval('approval_existing', 'cargo test')],
    });
    model.handleResponse({
      'type': 'approval',
      'approval': _approval('approval_existing', 'cargo test'),
    });
    await Future<void>.delayed(Duration.zero);

    expect(alerts, isEmpty);
  });

  test('unknown turn completion status does not emit review notification',
      () async {
    final alerts = <TaskNotificationAlert>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
      taskNotificationsEnabled: true,
      notificationRuntimeIdProvider: () => 'pc-1',
      notificationPermissionRequester: () async => true,
      notificationSender: (alert) async {
        alerts.add(alert);
        return true;
      },
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_unknown',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': '',
    });
    await Future<void>.delayed(Duration.zero);

    expect(alerts, isEmpty);
  });

  test('opens Windows Codex app when native attachment is unavailable',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await model.listThreads();
    final listRequestId = sent.single.value;
    model.handleResponse({
      'type': 'error',
      'request_id': listRequestId,
      'thread_id': '',
      'message': 'Codex app-server is unavailable',
    });
    expect(model.error, contains('unavailable'));

    final handoff = model.openWindowsApp();
    final request = sent.last;
    expect(request.key, 'codex-open-windows-app');
    final payload = jsonDecode(request.value);
    expect(payload['thread_id'], '');

    var completed = false;
    handoff.then((_) => completed = true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      'action': 'windows_app_opened',
      'thread_id': '',
      'turn_id': '',
      'state': 'ready',
    });

    expect(await handoff, isTrue);
    expect(model.error, isEmpty);
  });

  test('old peers stay read only without the Codex mutation contract', () {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'control': {
        'resume_thread': true,
        'start_thread': true,
        'start_turn': true,
        'steer_turn': true,
        'interrupt_turn': true,
        'approvals': true,
      },
      'threads': const [],
    });

    expect(model.canResumeThread, isFalse);
    expect(model.canStartThread, isFalse);
    expect(model.canStartTurn, isFalse);
    expect(model.canSteerTurn, isFalse);
    expect(model.canInterruptTurn, isFalse);
    expect(model.canRespondToApprovals, isFalse);
    model.dispose();
  });

  test('lost Codex mutation acknowledgment becomes unknown outcome', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(milliseconds: 15),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-timeout'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });

    final operationId = await model.send('thr_1', 'Keep this draft');
    expect(operationId, isNotNull);
    expect(model.operationState(operationId!), RemoteOperationState.pending);
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(
        model.operationState(operationId), RemoteOperationState.unknownOutcome);
    expect(model.isControlPending('thr_1'), isFalse);
    expect(model.errorFor('thr_1'), contains('may have applied'));
    model.dispose();
  });

  test('lost Codex acknowledgment reconciles once with the same operation id',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(milliseconds: 15),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-reconcile'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });

    final operationId = await model.send('thr_1', 'Reconcile this once');
    expect(operationId, isNotNull);
    final firstPayload = jsonDecode(sent.single.value);

    await Future<void>.delayed(const Duration(milliseconds: 18));
    expect(sent, hasLength(2));
    final reconciledPayload = jsonDecode(sent.last.value);
    expect(reconciledPayload['operation_id'], firstPayload['operation_id']);
    expect(reconciledPayload['request_id'], isNot(firstPayload['request_id']));
    expect(model.operationState(operationId!), RemoteOperationState.pending);

    model.handleControlResponse({
      'type': 'result',
      'request_id': reconciledPayload['request_id'],
      ..._codexAck(reconciledPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(sent, hasLength(2));
    expect(model.operationState(operationId), RemoteOperationState.applied);
    model.dispose();
  });

  test(
      'unknown Codex submission retries only the exact snapshot with the same operation id',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(milliseconds: 10),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-unknown-retry'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });

    final operationId = await model.send('thr_1', 'Exact uncertain draft');
    expect(operationId, isNotNull);
    final firstPayload = jsonDecode(sent.first.value);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(model.operationState(operationId!),
        RemoteOperationState.unknownOutcome);
    expect(sent, hasLength(2));

    final different = await model.send('thr_1', 'Different draft');
    expect(different, isNull);
    expect(sent, hasLength(2));
    expect(model.errorFor('thr_1'), contains('exact submitted text'));

    final retried = await model.send('thr_1', 'Exact uncertain draft');
    expect(retried, operationId);
    expect(sent, hasLength(3));
    final retryPayload = jsonDecode(sent.last.value);
    expect(retryPayload['operation_id'], firstPayload['operation_id']);
    expect(retryPayload['request_id'], isNot(firstPayload['request_id']));
    expect(model.operationState(operationId), RemoteOperationState.pending);

    model.handleControlResponse({
      'type': 'result',
      'request_id': retryPayload['request_id'],
      ..._codexAck(retryPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.operationState(operationId), RemoteOperationState.applied);
    model.dispose();
  });

  test('mismatched Codex acknowledgment is ignored until exact ack arrives',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(seconds: 1),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      ..._codexMutationContract('scope-ack'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });

    final operationId = await model.send('thr_1', 'Exact ack only');
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'operation_id': 'forged-operation',
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.operationState(operationId!), RemoteOperationState.pending);
    expect(model.isControlPending('thr_1'), isTrue);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.operationState(operationId), RemoteOperationState.applied);
    expect(model.isControlPending('thr_1'), isFalse);
    model.dispose();
  });

  test('exact Codex acknowledgment clears only the submitted draft snapshot',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-draft-ack',
      'service_state': 'ready',
      ..._codexMutationContract('scope-draft-ack'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });

    model.updateDraft('thr_1', 'Submitted draft');
    final firstOperation = await model.send('thr_1', 'Submitted draft');
    expect(firstOperation, isNotNull);
    final firstPayload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.updateDraft('thr_1', 'Submitted draft plus newer edit');

    model.handleControlResponse({
      'type': 'result',
      'request_id': firstPayload['request_id'],
      ..._codexAck(firstPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.draftFor('thr_1'), 'Submitted draft plus newer edit');

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': 'completed',
    });
    model.updateDraft('thr_1', 'Exact second draft');
    await model.send('thr_1', 'Exact second draft');
    final secondPayload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': secondPayload['request_id'],
      ..._codexAck(secondPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'state': 'working',
    });
    expect(model.draftFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('Codex draft survives connection reset and generation change', () {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-draft-generation-1',
      'service_state': 'ready',
      ..._codexMutationContract('scope-draft-generation'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });
    model.updateDraft('thr_1', 'Keep through reconnect');

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-draft-generation-2',
      'service_state': 'ready',
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
      ],
      'operation_session_identity': 'scope-draft-generation-next',
      'operation_generation': 2,
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });
    expect(model.draftFor('thr_1'), 'Keep through reconnect');

    model.reset();
    expect(model.draftFor('thr_1'), 'Keep through reconnect');
    model.dispose();
  });

  test(
      'queued instruction appears only after exact ack and advances on queued start',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue'),
      'control': {'start_turn': true, 'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });

    final operationId = await model.queue('thr_1', 'Run the next check');
    expect(operationId, isNotNull);
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(sent.last.key, 'codex-queue-turn');
    expect(payload['turn_id'], 'turn_1');
    expect(payload['text'], 'Run the next check');

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(
        model.queuedInstructionsFor('thr_1').single.text, 'Run the next check');

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': 'completed',
    });
    expect(model.queuedInstructionsFor('thr_1'), hasLength(1));

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'queuedStart',
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('queued start arriving before its ack cannot recreate stale queue UI',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue-race',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue-race'),
      'control': {'start_turn': true, 'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });

    await model.queue('thr_1', 'Run after this turn');
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'queuedStart',
      'operation_id': payload['operation_id'],
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('late queue ack cannot roll a completed queued turn back to working',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue-late-state',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue-late-state'),
      'control': {'start_turn': true, 'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });

    await model.queue('thr_1', 'Run after this turn');
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'queuedStart',
      'operation_id': payload['operation_id'],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'item_id': '',
      'kind': 'turn_completed',
      'state': 'idle',
      'history_kind': 'unknown',
      'text': '',
      'status': 'completed',
    });
    expect(model.threads.single.state, 'idle');

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });

    expect(model.threads.single.state, 'idle');
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('resume reconciles queued instructions with authoritative host ids',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue-reconcile',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue-reconcile'),
      'control': {
        'resume_thread': true,
        'start_turn': true,
        'queue_turn': true,
      },
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    await model.queue('thr_1', 'Queued work');
    final queuePayload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': queuePayload['request_id'],
      ..._codexAck(queuePayload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.queuedInstructionsFor('thr_1'), hasLength(1));

    final resuming = model.resumeThread('thr_1');
    await Future<void>.delayed(Duration.zero);
    final resume = sent.lastWhere(
      (command) => command.key == 'codex-resume-thread',
    );
    final resumePayload = jsonDecode(resume.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': resumePayload['request_id'],
      ..._codexAck(resumePayload),
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': 'turn_2',
      'state': 'working',
      'queued_operation_ids': const [],
    });
    await resuming;

    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('resume keeps host-only queued operations visible after reconnect',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue-host-only',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue-host-only'),
      'control': {
        'resume_thread': true,
        'start_turn': true,
        'queue_turn': true,
      },
      'threads': [_thread('thr_1', 'working')],
    });

    final resuming = model.resumeThread('thr_1');
    await Future<void>.delayed(Duration.zero);
    final resume = sent.lastWhere(
      (command) => command.key == 'codex-resume-thread',
    );
    final payload = jsonDecode(resume.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
      'queued_operation_ids': const ['op-host-only'],
    });
    await resuming;

    final queued = model.queuedInstructionsFor('thr_1');
    expect(queued, hasLength(1));
    expect(queued.single.operationId, 'op-host-only');
    expect(
        queued.single.text, 'Queued instruction on PC · details unavailable');
    model.dispose();
  });

  test('queue state clears on host queue failure and session generation change',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-queue-clear',
      'service_state': 'ready',
      ..._codexMutationContract('scope-queue-clear'),
      'control': {'start_turn': true, 'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    await model.queue('thr_1', 'Queued work');
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.queuedInstructionsFor('thr_1'), hasLength(1));

    model.handleResponse({
      'type': 'error',
      'request_id': '',
      'thread_id': 'thr_1',
      'error_code': 'queue_cleared',
      'message': 'Queued Codex instruction could not start.',
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);

    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });
    await model.queue('thr_1', 'Do not carry across reconnect');
    final reconnectPayload =
        jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleControlResponse({
      'type': 'result',
      'request_id': reconnectPayload['request_id'],
      ..._codexAck(reconnectPayload),
      'action': 'turn_queued',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(model.queuedInstructionsFor('thr_1'), hasLength(1));

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-after-reconnect',
      'service_state': 'ready',
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
        'codex.workspaces.v1',
        'codex.queue.v1',
        'codex.queue.reconcile.v1',
      ],
      'operation_session_identity': 'scope-queue-clear-next',
      'operation_generation': 2,
      'control': {'start_turn': true, 'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    expect(model.queuedInstructionsFor('thr_1'), isEmpty);
    expect(model.activeTurnIdFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('queue remains unavailable without the negotiated queue capability',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-no-queue',
      'service_state': 'ready',
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
      ],
      'operation_session_identity': 'scope-no-queue',
      'operation_generation': 1,
      'control': {'queue_turn': true},
      'threads': [_thread('thr_1', 'working')],
    });
    model.handleResponse({
      'type': 'event',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': '',
      'kind': 'turn_started',
      'state': 'working',
      'history_kind': 'unknown',
      'text': '',
      'status': 'inProgress',
    });

    expect(model.canQueueTurn, isFalse);
    expect(await model.queue('thr_1', 'No queue'), isNull);
    expect(sent.where((command) => command.key == 'codex-queue-turn'), isEmpty);
    model.dispose();
  });

  test(
      'Codex generation change makes pending mutation unknown and rejects late ack',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(seconds: 1),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-1',
      'service_state': 'ready',
      ..._codexMutationContract('scope-generation'),
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });
    final operationId = await model.send('thr_1', 'Do not replay me');
    final payload = jsonDecode(sent.last.value) as Map<String, dynamic>;

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-2',
      'service_state': 'ready',
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
      ],
      'operation_session_identity': 'scope-generation-next',
      'operation_generation': 2,
      'control': {'start_turn': true},
      'threads': [_thread('thr_1', 'idle')],
    });
    expect(model.operationState(operationId!),
        RemoteOperationState.unknownOutcome);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    expect(
        model.operationState(operationId), RemoteOperationState.unknownOutcome);
    model.dispose();
  });

  test('review lists and text previews page through host-issued ids', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    expect(model.supportsReview, isTrue);

    await model.loadTaskChanges('thr_1');
    var request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(sent.last.key, 'codex-list-task-changes');
    expect(request['thread_id'], 'thr_1');
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': 'changes:2',
      'changes': const [
        {
          'change_id': 'change_1',
          'artifact_id': 'artifact_1',
          'path': 'lib/a.dart',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 42,
          'diff_available': true,
          'fallback_reason': '',
        }
      ],
    });
    expect(model.taskChangesFor('thr_1').single.id, 'change_1');
    expect(model.nextTaskChangeCursorFor('thr_1'), 'changes:2');

    await model.loadTaskChanges('thr_1', reset: false);
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(request['cursor'], 'changes:2');
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'change_2',
          'artifact_id': '',
          'path': 'lib/b.dart',
          'kind': 'delete',
          'binary': false,
          'large': true,
          'size_bytes': 100000,
          'diff_available': false,
          'fallback_reason': 'Diff is too large to preview safely',
        }
      ],
    });
    expect(model.taskChangesFor('thr_1').map((item) => item.id),
        ['change_1', 'change_2']);

    await model.loadTaskDiff('thr_1', 'change_1');
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(sent.last.key, 'codex-read-task-diff');
    expect(request['change_id'], 'change_1');
    model.handleResponse({
      'type': 'task_diff',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'id': 'change_1',
      'text': 'abcd',
      'offset': 0,
      'next_offset': 4,
      'complete': false,
      'fallback_reason': '',
    });
    await model.loadTaskDiff('thr_1', 'change_1', reset: false);
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(request['offset'], 4);
    model.handleResponse({
      'type': 'task_diff',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'id': 'change_1',
      'text': 'efgh',
      'offset': 4,
      'next_offset': 8,
      'complete': true,
      'fallback_reason': '',
    });
    expect(model.taskDiffFor('change_1')?.text, 'abcdefgh');

    await model.loadArtifacts('thr_1');
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    expect(sent.last.key, 'codex-list-artifacts');
    model.handleResponse({
      'type': 'artifact_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'artifacts': const [
        {
          'artifact_id': 'artifact_1',
          'path': 'lib/a.dart',
          'size_bytes': 42,
          'binary': false,
          'large': false,
          'readable': true,
          'fallback_reason': '',
        }
      ],
    });
    expect(model.artifactsFor('thr_1').single.id, 'artifact_1');
    model.dispose();
  });

  test('diff preview cache evicts the oldest completed preview', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-cache',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-cache'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadTaskChanges('thr_1');
    var request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': List.generate(
        5,
        (index) => {
          'change_id': 'change_$index',
          'artifact_id': '',
          'path': 'lib/$index.dart',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 6,
          'diff_available': true,
          'fallback_reason': '',
        },
      ),
    });

    for (var index = 0; index < 5; index++) {
      await model.loadTaskDiff('thr_1', 'change_$index');
      request = jsonDecode(sent.last.value) as Map<String, dynamic>;
      final text = 'diff-$index';
      model.handleResponse({
        'type': 'task_diff',
        'request_id': request['request_id'],
        'thread_id': 'thr_1',
        'id': 'change_$index',
        'text': text,
        'offset': 0,
        'next_offset': text.length,
        'complete': true,
        'fallback_reason': '',
      });
    }

    expect(model.taskDiffFor('change_0'), isNull);
    expect(model.taskDiffFor('change_1')?.text, 'diff-1');
    expect(model.taskDiffFor('change_4')?.text, 'diff-4');
    model.dispose();
  });

  test('artifact preview cache evicts the oldest completed preview', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-artifact-cache',
      'service_state': 'ready',
      ..._codexReviewContract('scope-artifact-cache'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadArtifacts('thr_1');
    var request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'artifact_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'artifacts': List.generate(
        9,
        (index) => {
          'artifact_id': 'artifact_$index',
          'path': 'out/$index.txt',
          'size_bytes': 10,
          'binary': false,
          'large': false,
          'readable': true,
          'fallback_reason': '',
        },
      ),
    });

    for (var index = 0; index < 9; index++) {
      await model.loadArtifactPreview('thr_1', 'artifact_$index');
      request = jsonDecode(sent.last.value) as Map<String, dynamic>;
      final text = 'artifact-$index';
      model.handleResponse({
        'type': 'artifact',
        'request_id': request['request_id'],
        'thread_id': 'thr_1',
        'id': 'artifact_$index',
        'text': text,
        'offset': 0,
        'next_offset': text.length,
        'complete': true,
        'fallback_reason': '',
      });
    }

    expect(model.artifactPreviewFor('artifact_0'), isNull);
    expect(model.artifactPreviewFor('artifact_1')?.text, 'artifact-1');
    expect(model.artifactPreviewFor('artifact_8')?.text, 'artifact-8');
    model.dispose();
  });

  test('review responses from an old Codex generation are ignored', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-1',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-1'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    await model.loadTaskChanges('thr_1');
    final staleRequest = jsonDecode(sent.last.value) as Map<String, dynamic>;

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-2',
      'service_state': 'ready',
      'capabilities': const ['codex.review.v1'],
      'operation_session_identity': 'scope-review-2',
      'operation_generation': 2,
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': staleRequest['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'stale_change',
          'artifact_id': '',
          'path': 'stale.txt',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 1,
          'diff_available': true,
          'fallback_reason': '',
        }
      ],
    });

    expect(model.taskChangesFor('thr_1'), isEmpty);
    expect(model.isTaskChangesLoading('thr_1'), isFalse);
    model.dispose();
  });

  test('malformed review response does not consume the pending request',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-malformed',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-malformed'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadTaskChanges('thr_1');
    final request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_wrong',
      'next_cursor': '',
      'changes': const [],
    });
    expect(model.isTaskChangesLoading('thr_1'), isTrue);

    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'change_valid',
          'artifact_id': '',
          'path': 'valid.txt',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 5,
          'diff_available': true,
          'fallback_reason': '',
        }
      ],
    });
    expect(model.isTaskChangesLoading('thr_1'), isFalse);
    expect(model.taskChangesFor('thr_1').single.id, 'change_valid');
    model.dispose();
  });

  test('review request timeout clears loading and can retry the exact request',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      reviewTimeout: const Duration(milliseconds: 20),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-timeout',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-timeout'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadTaskChanges('thr_1');
    expect(model.isTaskChangesLoading('thr_1'), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(model.isTaskChangesLoading('thr_1'), isFalse);
    expect(model.reviewErrorFor('thr_1'), contains('timed out'));

    await model.retryReviewFailure('thr_1');
    expect(
        sent.where((item) => item.key == 'codex-list-task-changes').length, 2);
    expect(model.isTaskChangesLoading('thr_1'), isTrue);
    model.dispose();
  });

  test('non-progressing review text page is rejected and retryable', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-progress',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-progress'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    await model.loadTaskChanges('thr_1');
    var request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'change_1',
          'artifact_id': '',
          'path': 'lib/a.dart',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 3,
          'diff_available': true,
          'fallback_reason': '',
        }
      ],
    });
    await model.loadTaskDiff('thr_1', 'change_1');
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_diff',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'id': 'change_1',
      'offset': 0,
      'text': 'abc',
      'next_offset': 0,
      'complete': false,
      'fallback_reason': '',
    });

    expect(model.taskDiffFor('change_1'), isNull);
    expect(model.reviewErrorFor('thr_1'), contains('byte range'));
    await model.retryReviewFailure('thr_1');
    expect(sent.where((item) => item.key == 'codex-read-task-diff').length, 2);
    model.dispose();
  });

  test('review error for the wrong thread does not consume the request',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-error-scope',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-error-scope'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadTaskChanges('thr_1');
    final request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'error',
      'request_id': request['request_id'],
      'thread_id': 'thr_wrong',
      'message': 'wrong scope',
    });
    expect(model.isTaskChangesLoading('thr_1'), isTrue);
    expect(model.reviewErrorFor('thr_1'), isEmpty);

    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [],
    });
    expect(model.isTaskChangesLoading('thr_1'), isFalse);
    model.dispose();
  });

  test('review text offsets are validated as UTF-8 bytes', () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-utf8',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-utf8'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    await model.loadTaskChanges('thr_1');
    var request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'change_utf8',
          'artifact_id': '',
          'path': 'utf8.txt',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 2,
          'diff_available': true,
          'fallback_reason': '',
        }
      ],
    });
    await model.loadTaskDiff('thr_1', 'change_utf8');
    request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'task_diff',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'id': 'change_utf8',
      'offset': 0,
      'text': 'é',
      'next_offset': 2,
      'complete': true,
      'fallback_reason': '',
    });

    expect(model.taskDiffFor('change_utf8')?.text, 'é');
    expect(model.reviewErrorFor('thr_1'), isEmpty);
    model.dispose();
  });

  test('preview requests require ids from the current host review list',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-known-id',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-known-id'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });

    await model.loadTaskDiff('thr_1', 'forged_change');

    expect(sent.where((item) => item.key == 'codex-read-task-diff'), isEmpty);
    expect(model.reviewErrorFor('thr_1'), contains('Refresh Codex changes'));
    model.dispose();
  });

  test('successful parallel review request keeps an unrelated review failure',
      () async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-independent-error',
      'service_state': 'ready',
      ..._codexReviewContract('scope-review-independent-error'),
      'control': const {},
      'threads': [_thread('thr_1', 'idle')],
    });
    await model.loadTaskDiff('thr_1', 'unknown_change');
    expect(model.reviewErrorFor('thr_1'), contains('Refresh Codex changes'));

    await model.loadArtifacts('thr_1');
    final request = jsonDecode(sent.last.value) as Map<String, dynamic>;
    model.handleResponse({
      'type': 'artifact_list',
      'request_id': request['request_id'],
      'thread_id': 'thr_1',
      'next_cursor': '',
      'artifacts': const [],
    });

    expect(model.reviewErrorFor('thr_1'), contains('Refresh Codex changes'));
    model.dispose();
  });
}

Map<String, dynamic> _item(String id, String kind, String text) => {
      'id': id,
      'turn_id': 'turn_1',
      'kind': kind,
      'text': text,
      'detail': '',
      'status': '',
    };

Map<String, dynamic> _approval(String id, String command) => {
      'approval_id': id,
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'item_id': 'item_approval',
      'kind': 'command',
      'title': 'Command approval',
      'summary': command,
      'reason': 'Run tests',
      'started_at_ms': 123,
      'actionable': true,
    };

Map<String, dynamic> _thread(String id, String state) => {
      'id': id,
      'title': 'Codex task',
      'project': 'RustDesk',
      'originator': 'codex_desktop',
      'updated_at': 1,
      'state': state,
    };

Map<String, dynamic> _codexMutationContract(String identity) => {
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
        'codex.workspaces.v1',
        'codex.queue.v1',
        'codex.queue.reconcile.v1',
      ],
      'operation_session_identity': identity,
      'operation_generation': 1,
    };

Map<String, dynamic> _codexReviewContract(String identity) => {
      'capabilities': const ['codex.review.v1'],
      'operation_session_identity': identity,
      'operation_generation': 1,
    };

Map<String, dynamic> _codexAck(Map<String, dynamic> request,
        {bool accepted = true, bool applied = true}) =>
    {
      'operation_id': request['operation_id'],
      'session_identity': request['session_identity'],
      'target_identity': request['target_identity'],
      'session_generation': request['session_generation'],
      'accepted': accepted,
      'applied': applied,
      'error_code': '',
    };
