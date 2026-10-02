import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/codex_page.dart';
import 'package:flutter_hbb/models/codex_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  testWidgets('shows interactive Codex thread list and new task action',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    await tester.pumpWidget(
      MaterialApp(home: CodexPage(model: model)),
    );
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'codex-threads-1',
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
          'title': 'Remote-control checkpoint',
          'project': '',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'resumable',
        }
      ],
    });
    await tester.pump();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Read only'), findsNothing);
    expect(find.text('NEW CODEX TASK'), findsOneWidget);
    expect(find.text('Remote-control checkpoint'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('resumes then sends steers and interrupts a Codex task',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'codex-threads-1',
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
          'title': 'Remote-control checkpoint',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'resumable',
        }
      ],
    });
    await tester.pump();

    await tester.tap(find.text('Remote-control checkpoint'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('RESUME NATIVELY'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await tester.tap(find.text('RESUME NATIVELY'));
    await tester.pump();
    final resume =
        sent.lastWhere((command) => command.key == 'codex-resume-thread');
    final resumePayload = jsonDecode(resume.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': resumePayload['request_id'],
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': '',
      'state': 'idle',
    });
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('SEND'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Continue checkpoint 4');
    await tester.tap(find.text('SEND'));
    await tester.pump();
    final start =
        sent.lastWhere((command) => command.key == 'codex-start-turn');
    final startPayload = jsonDecode(start.value);
    expect(startPayload['text'], 'Continue checkpoint 4');

    model.handleControlResponse({
      'type': 'result',
      'request_id': startPayload['request_id'],
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();

    expect(find.text('STARTING'), findsOneWidget);
    expect(find.text('INTERRUPT'), findsNothing);

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
    await tester.pump();

    expect(find.text('STEER'), findsOneWidget);
    expect(find.text('INTERRUPT'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Use the typed transport');
    await tester.tap(find.text('STEER'));
    await tester.pump();
    final steer =
        sent.lastWhere((command) => command.key == 'codex-steer-turn');
    expect(jsonDecode(steer.value)['text'], 'Use the typed transport');

    final steerPayload = jsonDecode(steer.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': steerPayload['request_id'],
      'action': 'turn_steered',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();

    await tester.tap(find.text('INTERRUPT'));
    await tester.pump();
    expect(sent.last.key, 'codex-interrupt-turn');
  });

  testWidgets('shows a live approval card and sends approve action',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      'control': {'start_turn': true, 'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Approval task',
          'project': 'RustDesk',
          'originator': '',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Approval task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    model.handleResponse({
      'type': 'approval',
      'approval': {
        'approval_id': 'approval_1',
        'thread_id': 'thr_1',
        'turn_id': 'turn_1',
        'item_id': 'item_1',
        'kind': 'command',
        'title': 'Command approval',
        'summary': 'cargo test codex',
        'reason': 'Run the Codex tests',
        'started_at_ms': 123,
        'actionable': true,
      },
    });
    await tester.pump();

    expect(find.text('Command approval'), findsOneWidget);
    expect(find.text('cargo test codex'), findsOneWidget);
    expect(find.text('DENY'), findsOneWidget);
    expect(find.text('APPROVE'), findsOneWidget);

    await tester.tap(find.text('APPROVE'));
    await tester.pump();
    final response =
        sent.lastWhere((command) => command.key == 'codex-respond-approval');
    final payload = jsonDecode(response.value);
    expect(payload['approval_id'], 'approval_1');
    expect(payload['decision'], 'approve');
  });

  testWidgets('Windows app handoff returns to the remote desktop view',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                const Text('Desktop'),
                FilledButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => CodexPage(model: model)),
                  ),
                  child: const Text('Open Codex'),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Codex'));
    await tester.pump();
    final listRequest =
        sent.lastWhere((command) => command.key == 'codex-list-threads');
    model.handleResponse({
      'type': 'thread_list',
      'request_id': listRequest.value,
      'service_state': 'ready',
      'codex_version': '0.155.1',
      'control': {},
      'threads': [
        {
          'id': 'thr_desktop',
          'title': 'Desktop-owned task',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'resumable',
        }
      ],
    });
    await tester.pump();

    await tester.tap(find.text('Desktop-owned task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('OPEN WINDOWS APP'), findsOneWidget);

    await tester.tap(find.text('OPEN WINDOWS APP'));
    await tester.pump();
    final handoff =
        sent.lastWhere((command) => command.key == 'codex-open-windows-app');
    final payload = jsonDecode(handoff.value);
    expect(payload['thread_id'], 'thr_desktop');

    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      'action': 'windows_app_opened',
      'thread_id': 'thr_desktop',
      'turn_id': '',
      'state': 'ready',
    });
    await tester.pumpAndSettle();

    expect(find.text('Desktop'), findsOneWidget);
    expect(find.text('Desktop-owned task'), findsNothing);
  });

  testWidgets('offers Windows app handoff when Codex native attachment fails',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    await tester.pump();
    final listRequest =
        sent.lastWhere((command) => command.key == 'codex-list-threads');
    model.handleResponse({
      'type': 'error',
      'request_id': listRequest.value,
      'thread_id': '',
      'message': 'Codex app-server is unavailable',
    });
    await tester.pump();

    expect(find.text('Codex is unavailable'), findsOneWidget);
    expect(find.text('OPEN WINDOWS APP'), findsOneWidget);
  });
}
