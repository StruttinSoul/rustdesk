import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/codex_model.dart';
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

  test('drives resume send steer and interrupt through advertised controls',
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

    await model.resumeThread('thr_1');
    final resume = sent.last;
    expect(resume.key, 'codex-resume-thread');
    final resumePayload = jsonDecode(resume.value);
    expect(resumePayload['thread_id'], 'thr_1');
    expect(model.isControlPending('thr_1'), isTrue);

    model.handleControlResponse({
      'type': 'result',
      'request_id': resumePayload['request_id'],
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': '',
      'state': 'idle',
    });
    expect(model.threads.single.state, 'idle');
    expect(model.isControlPending('thr_1'), isFalse);

    await model.send('thr_1', 'Implement the control path');
    final start = sent.last;
    expect(start.key, 'codex-start-turn');
    final startPayload = jsonDecode(start.value);
    expect(startPayload['thread_id'], 'thr_1');
    expect(startPayload['text'], 'Implement the control path');

    model.handleControlResponse({
      'type': 'result',
      'request_id': startPayload['request_id'],
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

  test('starts a new task in an existing workspace without exposing a path',
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

    await model.startThread(workspaceThreadId: 'thr_workspace');
    final start = sent.last;
    expect(start.key, 'codex-start-thread');
    final payload = jsonDecode(start.value);
    expect(payload['workspace_thread_id'], 'thr_workspace');
    expect(payload.containsKey('cwd'), isFalse);

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
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
}

Map<String, dynamic> _item(String id, String kind, String text) => {
      'id': id,
      'turn_id': 'turn_1',
      'kind': kind,
      'text': text,
      'detail': '',
      'status': '',
    };
