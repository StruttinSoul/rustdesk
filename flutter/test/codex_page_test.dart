import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
      ..._codexMutationContract('scope-list'),
      'control': {
        'resume_thread': true,
        'start_thread': true,
        'start_turn': true,
        'steer_turn': true,
        'queue_turn': true,
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
    await tester.pumpAndSettle();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Read only'), findsNothing);
    expect(find.text('New task'), findsOneWidget);
    expect(find.text('Remote-control checkpoint'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('groups Codex tasks by attention state and desktop history',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-groups',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-groups'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_review',
          'title': 'Review task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 10,
          'state': 'idle',
        },
        {
          'id': 'thr_running',
          'title': 'Running task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 20,
          'state': 'working',
        },
        {
          'id': 'thr_needs_you',
          'title': 'Approval task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 30,
          'state': 'waiting_for_approval',
        },
        {
          'id': 'thr_desktop',
          'title': 'Imported desktop task',
          'project': '',
          'originator': 'Codex Desktop',
          'updated_at': 40,
          'state': 'resumable',
        },
      ],
    });
    await tester.pump();

    expect(find.text('Needs you'), findsOneWidget);
    expect(find.text('Running'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.text('Desktop history'), findsOneWidget);
    expect(find.text('Approval task'), findsOneWidget);
    expect(find.text('Running task'), findsOneWidget);
    expect(find.text('Review task'), findsOneWidget);
    expect(find.text('Imported desktop task'), findsOneWidget);
  });

  testWidgets('new task requires a host workspace and shows host path/access',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    final listRequest =
        sent.lastWhere((command) => command.key == 'codex-list-threads');
    model.handleResponse({
      'type': 'thread_list',
      'request_id': listRequest.value,
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-workspace-picker'),
      'control': {'start_thread': true},
      'threads': const [],
    });
    await tester.pump();

    await tester.tap(find.text('New task'));
    await tester.pump();
    final workspaceRequest =
        sent.lastWhere((command) => command.key == 'codex-list-workspaces');
    final workspacePayload = jsonDecode(workspaceRequest.value);
    model.handleResponse({
      'type': 'workspace_list',
      'request_id': workspacePayload['request_id'],
      'next_cursor': '',
      'workspaces': const [
        {
          'id': 'ws_repo',
          'name': 'MIRPG',
          'path': r'C:\Programming Projects\MIRPG',
          'accessible': true,
          'status': 'Available',
        },
        {
          'id': 'ws_missing',
          'name': 'Missing repo',
          'path': r'D:\Missing',
          'accessible': false,
          'status': 'Workspace is unavailable on this host',
        },
      ],
    });
    await tester.pumpAndSettle();

    expect(find.text('Choose workspace'), findsOneWidget);
    expect(find.text(r'C:\Programming Projects\MIRPG'), findsOneWidget);
    expect(find.text('Workspace is unavailable on this host'), findsOneWidget);

    await tester.ensureVisible(find.text('MIRPG'));
    await tester.pump();
    await tester.tap(find.text('MIRPG'));
    await tester.pumpAndSettle();
    final start =
        sent.lastWhere((command) => command.key == 'codex-start-thread');
    final startPayload = jsonDecode(start.value);
    expect(startPayload['workspace_id'], 'ws_repo');
    expect(startPayload.containsKey('cwd'), isFalse);
  });

  testWidgets(
      'compact Codex task opens inside the workspace and returns to tasks',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-compact'),
      'control': {'start_turn': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Inline task',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();

    await tester.tap(find.text('Inline task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byTooltip('Back to tasks'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);

    await tester.tap(find.byTooltip('Back to tasks'));
    await tester.pump();
    expect(find.text('Inline task'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('review pane loads bounded changes diffs and artifact fallbacks',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexReviewMutationContract('scope-review-ui'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_review_ui',
          'title': 'Review UI task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Review UI task'));
    await tester.pumpAndSettle();
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pump();
    expect(find.byType(TextField), findsNothing);
    final changesRequest =
        sent.lastWhere((command) => command.key == 'codex-list-task-changes');
    final artifactsRequest =
        sent.lastWhere((command) => command.key == 'codex-list-artifacts');
    final changesPayload = jsonDecode(changesRequest.value);
    final artifactsPayload = jsonDecode(artifactsRequest.value);
    model.handleResponse({
      'type': 'task_change_list',
      'request_id': changesPayload['request_id'],
      'thread_id': 'thr_review_ui',
      'next_cursor': '',
      'changes': const [
        {
          'change_id': 'change_ui',
          'artifact_id': 'artifact_text',
          'path': 'lib/review.dart',
          'kind': 'update',
          'binary': false,
          'large': false,
          'size_bytes': 120,
          'diff_available': true,
          'fallback_reason': '',
        },
      ],
    });
    model.handleResponse({
      'type': 'artifact_list',
      'request_id': artifactsPayload['request_id'],
      'thread_id': 'thr_review_ui',
      'next_cursor': '',
      'artifacts': const [
        {
          'artifact_id': 'artifact_binary',
          'path': 'assets/output.png',
          'size_bytes': 2048,
          'binary': true,
          'large': false,
          'readable': false,
          'fallback_reason': 'Binary artifact preview is unavailable',
        }
      ],
    });
    await tester.pump();

    expect(find.text('lib/review.dart'), findsOneWidget);
    await tester.tap(find.text('lib/review.dart'));
    await tester.pump();
    final diffRequest =
        sent.lastWhere((command) => command.key == 'codex-read-task-diff');
    final diffPayload = jsonDecode(diffRequest.value);
    model.handleResponse({
      'type': 'task_diff',
      'request_id': diffPayload['request_id'],
      'thread_id': 'thr_review_ui',
      'id': 'change_ui',
      'text': '+ safe bounded diff',
      'offset': 0,
      'next_offset': 19,
      'complete': true,
      'fallback_reason': '',
    });
    await tester.pump();
    expect(find.text('+ safe bounded diff'), findsOneWidget);

    await tester.tap(find.text('Artifacts'));
    await tester.pump();
    expect(find.text('assets/output.png'), findsOneWidget);
    await tester.tap(find.text('assets/output.png'));
    await tester.pump();
    expect(find.text('Binary artifact preview is unavailable'), findsOneWidget);

    await tester.tap(find.text('Conversation'));
    await tester.pump();
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('review navigation stays accessible at 2x text scale',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(2.0)),
        child: CodexPage(model: model),
      ),
    ));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-review-scale',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexReviewMutationContract('scope-review-scale'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_review_scale',
          'title': 'Scaled review task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Scaled review task'));
    await tester.pumpAndSettle();

    final conversation = find.byKey(const ValueKey('codex-conversation-tab'));
    final review = find.byKey(const ValueKey('codex-review-tab'));
    expect(tester.getSize(conversation).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(review).height, greaterThanOrEqualTo(48));
    expect(tester.getSemantics(conversation).hasFlag(SemanticsFlag.isSelected),
        isTrue);

    await tester.tap(review);
    await tester.pump();
    final changes = find.byKey(const ValueKey('codex-review-changes-tab'));
    final artifacts = find.byKey(const ValueKey('codex-review-artifacts-tab'));
    final refresh = find.byKey(const ValueKey('codex-review-refresh'));
    expect(changes, findsOneWidget);
    expect(artifacts, findsOneWidget);
    expect(refresh, findsOneWidget);
    expect(tester.getSize(changes).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(artifacts).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(refresh).height, greaterThanOrEqualTo(48));
    expect(
        tester.getSemantics(changes).hasFlag(SemanticsFlag.isSelected), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    model.dispose();
  });

  testWidgets('composer draft survives compact navigation and reopens in task',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-draft-navigation',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-draft-navigation'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_draft',
          'title': 'Draft navigation task',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();

    await tester.tap(find.text('Draft navigation task'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this local draft');
    await tester.pump();
    expect(model.draftFor('thr_draft'), 'Keep this local draft');

    await tester.tap(find.byTooltip('Back to tasks'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draft navigation task'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this local draft',
    );
  });

  testWidgets('wide Codex workspace keeps task list beside the active task',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    tester.view.physicalSize = const Size(900, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-wide'),
      'control': {'start_turn': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Split-view task',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();

    await tester.tap(find.text('Split-view task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Split-view task'), findsNWidgets(2));
    expect(find.byTooltip('Back to tasks'), findsNothing);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('wide Codex selection follows thread id across reordered refresh',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    tester.view.physicalSize = const Size(900, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-stable-1',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-stable'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_a',
          'title': 'Task A',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 20,
          'state': 'idle',
        },
        {
          'id': 'thr_b',
          'title': 'Task B',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 10,
          'state': 'idle',
        },
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Task B'));
    await tester.pumpAndSettle();
    expect(find.text('Task B'), findsNWidgets(2));

    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads-stable-2',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-stable'),
      'control': {'start_turn': true},
      'threads': const [
        {
          'id': 'thr_b',
          'title': 'Task B refreshed',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 50,
          'state': 'working',
        },
        {
          'id': 'thr_a',
          'title': 'Task A',
          'project': 'MIRPG',
          'originator': '',
          'updated_at': 20,
          'state': 'idle',
        },
      ],
    });
    await tester.pump();

    expect(find.text('Task B refreshed'), findsNWidgets(2));
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('compact Codex workspace remains usable at 130 percent text size',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.3)),
        child: CodexPage(model: model),
      ),
    ));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-text'),
      'control': {'start_thread': true, 'start_turn': true},
      'threads': [
        {
          'id': 'thr_large_text',
          'title': 'A longer Codex task title that still remains usable',
          'project': 'RustDesk emulator remote',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('New task'), findsOneWidget);
    await tester.tap(find.textContaining('A longer Codex task title'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
  });

  testWidgets('attaches then sends steers and interrupts a Codex task',
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
      ..._codexMutationContract('scope-control'),
      'control': {
        'resume_thread': true,
        'start_thread': true,
        'start_turn': true,
        'steer_turn': true,
        'queue_turn': true,
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
    expect(find.textContaining('History'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Connecting to task…'), findsNothing);
    expect(find.byType(TextField), findsNothing);
    expect(
      sent.where((command) => command.key == 'codex-resume-thread'),
      isEmpty,
    );

    await tester.tap(find.text('Resume'));
    await tester.pump();
    expect(find.text('Connecting to task…'), findsOneWidget);

    final resume =
        sent.lastWhere((command) => command.key == 'codex-resume-thread');
    final resumePayload = jsonDecode(resume.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': resumePayload['request_id'],
      ..._codexAck(resumePayload),
      'action': 'thread_resumed',
      'thread_id': 'thr_1',
      'turn_id': '',
      'state': 'idle',
    });
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Continue checkpoint 4');
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Continue checkpoint 4',
    );
    final start =
        sent.lastWhere((command) => command.key == 'codex-start-turn');
    final startPayload = jsonDecode(start.value);
    expect(startPayload['text'], 'Continue checkpoint 4');

    model.handleControlResponse({
      'type': 'result',
      'request_id': startPayload['request_id'],
      ..._codexAck(startPayload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );

    expect(find.text('Starting'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);

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

    expect(find.text('Steer now'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Use the typed transport');
    await tester.tap(find.text('Steer now'));
    await tester.pump();
    final steer =
        sent.lastWhere((command) => command.key == 'codex-steer-turn');
    expect(jsonDecode(steer.value)['text'], 'Use the typed transport');

    final steerPayload = jsonDecode(steer.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': steerPayload['request_id'],
      ..._codexAck(steerPayload),
      'action': 'turn_steered',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(sent.last.key, 'codex-interrupt-turn');
    final interruptPayload = jsonDecode(sent.last.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': interruptPayload['request_id'],
      ..._codexAck(interruptPayload),
      'action': 'turn_interrupted',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'idle',
    });
    await tester.pump();
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
      ..._codexMutationContract('scope-approval'),
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
        'working_directory': r'C:\Programming Projects\MIRPG',
        'scope': r'C:\Programming Projects\MIRPG\rustdesk-emulator-remote',
        'started_at_ms': 123,
        'actionable': true,
      },
    });
    await tester.pump();

    expect(find.text('Command approval'), findsOneWidget);
    expect(find.text('cargo test codex'), findsOneWidget);
    expect(find.text('Working directory'), findsOneWidget);
    expect(find.text(r'C:\Programming Projects\MIRPG'), findsOneWidget);
    expect(find.text('Scope'), findsOneWidget);
    expect(
      find.text(r'C:\Programming Projects\MIRPG\rustdesk-emulator-remote'),
      findsOneWidget,
    );
    expect(find.text('Deny'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);

    await tester.tap(find.text('Approve'));
    await tester.pump();
    final response =
        sent.lastWhere((command) => command.key == 'codex-respond-approval');
    final payload = jsonDecode(response.value);
    expect(payload['approval_id'], 'approval_1');
    expect(payload['decision'], 'approve');
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'approval_approved',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();
  });

  testWidgets('unsupported approval has no fake Windows handoff',
      (tester) async {
    final model = CodexModel(
      Uuid().v4obj(),
      commandSender: (_, __) async {},
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-unsupported-approval'),
      'control': {'approvals': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Permission task',
          'project': 'RustDesk',
          'originator': 'mirpg',
          'updated_at': 1,
          'state': 'waiting_for_approval',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Permission task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    model.handleResponse({
      'type': 'approval',
      'approval': {
        'approval_id': 'approval_permissions',
        'thread_id': 'thr_1',
        'turn_id': 'turn_1',
        'item_id': 'item_1',
        'kind': 'permissions',
        'title': 'Permission approval',
        'summary': 'This request needs a compatible MIRPG bridge action.',
        'reason': 'Additional host permission is required.',
        'started_at_ms': 123,
        'actionable': false,
      },
    });
    await tester.pump();

    expect(
      find.text(
        'This request needs a compatible MIRPG bridge action. Opening Windows Codex does not transfer this approval.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Handle this approval in the Windows Codex app'),
        findsNothing);
  });

  testWidgets('lost Codex send acknowledgment preserves the composer draft',
      (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(milliseconds: 20),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-draft'),
      'control': {'start_turn': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Draft safety task',
          'project': 'RustDesk',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Draft safety task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'Keep this exact draft');
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent.last.key, 'codex-start-turn');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this exact draft',
    );

    await tester.pump(const Duration(milliseconds: 50));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this exact draft',
    );
    expect(find.textContaining('may have applied'), findsOneWidget);
  });

  testWidgets('ack clears only the submitted Codex snapshot', (tester) async {
    final sent = <({String key, String value})>[];
    final model = CodexModel(
      Uuid().v4obj(),
      controlTimeout: const Duration(seconds: 1),
      commandSender: (key, value) async => sent.add((key: key, value: value)),
    );

    await tester.pumpWidget(MaterialApp(home: CodexPage(model: model)));
    model.handleResponse({
      'type': 'thread_list',
      'request_id': 'threads',
      'service_state': 'ready',
      'codex_version': '0.155.1',
      ..._codexMutationContract('scope-newer-draft'),
      'control': {'start_turn': true},
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Draft edit task',
          'project': 'RustDesk',
          'originator': 'mirpg',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();
    await tester.tap(find.text('Draft edit task'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    await tester.enterText(find.byType(TextField), 'Submitted snapshot');
    await tester.tap(find.text('Send'));
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.enabled, isTrue);

    await tester.enterText(find.byType(TextField), 'Newer local draft');
    final request = sent.lastWhere((entry) => entry.key == 'codex-start-turn');
    final payload = jsonDecode(request.value);
    model.handleControlResponse({
      'type': 'result',
      'request_id': payload['request_id'],
      ..._codexAck(payload),
      'action': 'turn_started',
      'thread_id': 'thr_1',
      'turn_id': 'turn_1',
      'state': 'working',
    });
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Newer local draft',
    );
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
    expect(find.text('Open Windows app'), findsOneWidget);

    await tester.tap(find.text('Open Windows app'));
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
    expect(find.text('Open Windows app'), findsOneWidget);
  });
}

Map<String, dynamic> _codexMutationContract(String identity) => {
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
        'codex.workspaces.v1',
        'codex.queue.v1',
      ],
      'operation_session_identity': identity,
      'operation_generation': 1,
    };

Map<String, dynamic> _codexReviewMutationContract(String identity) => {
      'capabilities': const [
        'codex.operation.identity.v1',
        'codex.operation.ack.v1',
        'codex.workspaces.v1',
        'codex.queue.v1',
        'codex.review.v1',
      ],
      'operation_session_identity': identity,
      'operation_generation': 1,
    };

Map<String, dynamic> _codexAck(Map<String, dynamic> request) => {
      'operation_id': request['operation_id'],
      'session_identity': request['session_identity'],
      'target_identity': request['target_identity'],
      'session_generation': request['session_generation'],
      'accepted': true,
      'applied': true,
      'error_code': '',
    };
