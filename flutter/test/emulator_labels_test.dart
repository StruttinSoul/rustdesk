import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/emulator_labels.dart';
import 'support/fake_translate.dart';

EmulatorLabelStore store(Map<String, String> disk) => EmulatorLabelStore(
    peerId: '123',
    read: (k) => disk[k] ?? '',
    write: (k, v) async => disk[k] = v);

void main() {
  test('normalize trims, collapses, strips braces and control characters', () {
    expect(normalizeEmulatorLabel('  Alt  {EU}\n '), 'Alt EU');
    expect(normalizeEmulatorLabel('   '), '');
    expect(normalizeEmulatorLabel('a\u0007b'), 'ab');
  });

  test('normalize cuts to 32 characters without splitting an emoji', () {
    final out = normalizeEmulatorLabel('👍🏽' * 40);
    expect(out.characters.length, 32);
    expect(out, '👍🏽' * 32);
    expect(normalizeEmulatorLabel('x' * 200), 'x' * kEmulatorLabelMaxLength);
  });

  test('label is stored per PC and emulator and shown instead of the name',
      () async {
    final disk = <String, String>{};
    final s = store(disk);
    await s.setLabel('avd:Maple_1', 'Main');
    expect(disk[EmulatorLabelStore.storageKey('123', 'avd:Maple_1')], 'Main');
    expect(s.displayName('avd:Maple_1', 'Maple_1'), 'Main');
    expect(s.displayName('avd:Maple_2', 'Maple_2'), 'Maple_2');
    expect(store(disk).labelFor('avd:Maple_1'), 'Main',
        reason: 'a new store reads it back from disk');
  });

  test('rename moves the label and delete clears it', () async {
    final disk = <String, String>{};
    final s = store(disk);
    await s.setLabel('avd:A', 'Main');
    await s.moveLabel('avd:A', 'avd:B');
    expect((s.labelFor('avd:A'), s.labelFor('avd:B')), ('', 'Main'));
    await s.clearLabel('avd:B');
    expect(store(disk).labelFor('avd:B'), '',
        reason: 'a re-created emulator must not inherit it');
  });

  test('moving an unlabeled emulator does not leave a stale label behind',
      () async {
    final s = store({});
    await s.setLabel('avd:B', 'Old');
    await s.moveLabel('avd:A', 'avd:B');
    expect(s.labelFor('avd:B'), '');
  });

  test('whitespace-only label clears', () async {
    final s = store({});
    await s.setLabel('avd:A', 'Main');
    await s.setLabel('avd:A', '  ');
    expect(s.labelFor('avd:A'), '');
  });

  test('changes notify listeners', () async {
    final s = store({});
    var calls = 0;
    s.addListener(() => calls++);
    await s.setLabel('avd:A', 'Main');
    await s.setLabel('avd:A', 'Main');
    await s.clearLabel('avd:A');
    expect(calls, 2, reason: 'an unchanged label does not notify');
  });

  Future<void> openLabelSheet(
    WidgetTester tester,
    List<String?> results, {
    String currentLabel = '',
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(await showEmulatorLabelSheet(
              context,
              emulatorName: 'Maple_1',
              currentLabel: currentLabel,
              tr: fakeTr,
            )),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'label sheet returns the normalized label, Clear label returns empty, dismiss returns null',
      (tester) async {
    final results = <String?>[];
    await openLabelSheet(tester, results);
    expect(find.text('Label for Maple_1'), findsOneWidget);
    expect(find.text('Clear label'), findsNothing);
    await tester.enterText(find.byType(TextField), ' Alt 1 (EU) ');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(results, ['Alt 1 (EU)']);

    await openLabelSheet(tester, results, currentLabel: 'Main');
    expect(find.text('Main'), findsOneWidget);
    await tester.tap(find.text('Clear label'));
    await tester.pumpAndSettle();
    expect(results, ['Alt 1 (EU)', '']);

    await openLabelSheet(tester, results);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, ['Alt 1 (EU)', '', null]);
  });
}
