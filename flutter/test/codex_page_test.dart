import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/codex_page.dart';
import 'package:flutter_hbb/models/codex_model.dart';
import 'package:uuid/uuid.dart';

void main() {
  testWidgets('shows read-only Codex thread list', (tester) async {
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
      'threads': [
        {
          'id': 'thr_1',
          'title': 'Remote-control checkpoint',
          'project': '',
          'originator': 'codex_desktop',
          'updated_at': 1,
          'state': 'idle',
        }
      ],
    });
    await tester.pump();

    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Remote-control checkpoint'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
