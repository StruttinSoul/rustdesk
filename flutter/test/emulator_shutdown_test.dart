import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/target_dashboard_page.dart';

void main() {
  for (final compact in [false, true]) {
    testWidgets('running Android ${compact ? 'compact card' : 'row'} shuts down only from its menu', (tester) async {
      var shutdowns = 0;
      var opens = 0;
      final target = compact
          ? TargetPreviewCard(name: 'Player 1', type: 'Android 13', stopped: false, live: true,
              onOpen: () => opens++, onShutdown: () => shutdowns++)
          : TargetScreenRow(name: 'Player 1', type: 'Android 13', stopped: false, live: true,
              onOpen: () => opens++, onShutdown: () => shutdowns++);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(
          width: compact ? 172 : 360, height: compact ? 218 : 120, child: target))));
      expect(shutdowns, 0);
      await tester.tap(find.byTooltip('More Player 1 actions'));
      await tester.pumpAndSettle();
      expect(shutdowns, 0);
      await tester.tap(find.text('Shut down emulator'));
      await tester.pumpAndSettle();
      expect(shutdowns, 1);
      expect(opens, 0);
      expect(tester.takeException(), isNull);
    });
  }
  for (final type in ['Windows', 'Android 13']) {
    testWidgets('$type stopped targets do not offer shutdown', (tester) async {
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 172, height: 218,
        child: TargetPreviewCard(name: 'Target', type: type, stopped: type != 'Windows', live: false,
          onShutdown: () => fail('Shutdown must not be available'))))));
      expect(find.byTooltip('More Target actions'), findsNothing);
    });
  }
  testWidgets('shutdown pending blocks reopening and repeated shutdown', (tester) async {
    var actions = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 172, height: 218,
      child: TargetPreviewCard(name: 'Player 1', type: 'Android 13', stopped: false, live: true,
        shuttingDown: true, onOpen: () => actions++, onShutdown: () => actions++)))));
    expect(find.text('Shutting down…'), findsWidgets);
    await tester.tap(find.byType(TargetPreviewCard));
    expect(actions, 0);
    expect(tester.takeException(), isNull);
  });
  for (final confirmed in [false, true]) {
    testWidgets('shutdown confirmation ${confirmed ? 'accepts' : 'cancels'} the named instance', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () async { result = await showEmulatorShutdownConfirmation(context, 'Player 1'); },
        child: const Text('Ask'))))));
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Player 1'), findsWidgets);
      await tester.tap(find.text(confirmed ? 'Shut down' : 'Cancel'));
      await tester.pumpAndSettle();
      expect(result, confirmed);
    });
  }
  testWidgets('compact shutdown menu remains usable with large text', (tester) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(1.75)), child: child!),
      home: Scaffold(body: SizedBox(width: 172, height: 218, child: TargetPreviewCard(
        name: 'Player 1 with a long name', type: 'Android 13', stopped: false, live: true,
        onShutdown: () => calls++)))));
    await tester.tap(find.byTooltip('More Player 1 with a long name actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Shut down emulator'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(tester.takeException(), isNull);
  });

}