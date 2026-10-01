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
}

Map<String, dynamic> _item(String id, String kind, String text) => {
      'id': id,
      'turn_id': 'turn_1',
      'kind': kind,
      'text': text,
      'detail': '',
      'status': '',
    };
