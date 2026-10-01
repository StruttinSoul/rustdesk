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
}
