import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/avd_manage_sheets.dart';

void main() {
  Future<void> openSheet(
    WidgetTester tester,
    List<String?> results, {
    String initialName = 'Phone',
    String confirmLabel = 'Create',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(await showAvdNameSheet(
              context,
              title: 'New emulator',
              initialName: initialName,
              note: 'Android 15 · 4 GB · 4 cores · about 12 GB on D after setup',
              isTaken: (name) => name.toLowerCase() == 'taken',
              confirmLabel: confirmLabel,
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool createEnabled(WidgetTester tester, [String label = 'Create']) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label))
          .onPressed !=
      null;

  testWidgets('sheet shows the title and note and creates a valid name',
      (tester) async {
    final results = <String?>[];
    await openSheet(tester, results);
    expect(find.text('New emulator'), findsOneWidget);
    expect(find.text('Android 15 · 4 GB · 4 cores · about 12 GB on D after setup'),
        findsOneWidget);
    expect(createEnabled(tester), isTrue);
    await tester.enterText(find.byType(TextField), 'Alt_2');
    await tester.pump();
    expect(createEnabled(tester), isTrue);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(results, ['Alt_2']);
  });

  testWidgets('sheet rejects invalid names', (tester) async {
    final results = <String?>[];
    await openSheet(tester, results);
    for (final bad in ['has space', '.hidden', 'NUL', 'com1.txt', 'a/b', 'x' * 65]) {
      await tester.enterText(find.byType(TextField), bad);
      await tester.pump();
      expect(find.text('Use letters, numbers, . _ -'), findsOneWidget,
          reason: bad);
      expect(createEnabled(tester), isFalse, reason: bad);
    }
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    expect(createEnabled(tester), isFalse);
    expect(results, isEmpty);
  });

  testWidgets('sheet rejects a taken name case-insensitively', (tester) async {
    final results = <String?>[];
    await openSheet(tester, results);
    await tester.enterText(find.byType(TextField), 'TAKEN');
    await tester.pump();
    expect(find.text('Name already used'), findsOneWidget);
    expect(createEnabled(tester), isFalse);
  });

  testWidgets('dismissing the sheet returns null', (tester) async {
    final results = <String?>[];
    await openSheet(tester, results, confirmLabel: 'Clone');
    expect(createEnabled(tester, 'Clone'), isTrue);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });

  testWidgets('delete dialog returns true only on Delete', (tester) async {
    final results = <bool>[];
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(await confirmAvdDelete(context, 'Phone 2')),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Phone 2?'), findsOneWidget);
    expect(find.text('Permanently deletes Phone 2 and everything in it.'),
        findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(results, [false, true]);
  });
}
