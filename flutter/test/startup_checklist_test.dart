import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/startup_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

const _screen = Size(412, 915);

Future<void> _pump(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = _screen;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(body: child),
  ));
  // The current step's ring animates forever; never pumpAndSettle.
  await tester.pump();
}

StartupChecklist _checklist({
  int currentStep = 0,
  int? failedStep,
  Duration elapsed = const Duration(seconds: 41),
  String failureTitle = '',
  String failureMessage = '',
  String retryNote = '',
  VoidCallback? onBack,
  VoidCallback? onTryAgain,
  VoidCallback? onShowOnPc,
}) =>
    StartupChecklist(
      name: 'Alt-2',
      providerLabel: 'Android Emulator · Android 15',
      currentStep: currentStep,
      failedStep: failedStep,
      elapsed: elapsed,
      failureTitle: failureTitle,
      failureMessage: failureMessage,
      retryNote: retryNote,
      onBack: onBack ?? () {},
      onTryAgain: onTryAgain,
      onShowOnPc: onShowOnPc,
      tr: fakeTr,
    );

void main() {
  test('phases map to the four steps', () {
    expect([
      for (final p in [
        '',
        'requesting',
        'boot_requested',
        'starting_android',
        'waiting_screen',
        'stream_ready'
      ])
        startupStepIndex(p, alreadyRunning: false)
    ], [
      0,
      0,
      0,
      1,
      2,
      3
    ]);
    expect(startupStepIndex('requesting', alreadyRunning: true), 2);
  });

  test('elapsed is m:ss', () {
    expect([
      formatElapsed(const Duration(seconds: 41)),
      formatElapsed(const Duration(seconds: 65)),
      formatElapsed(const Duration(minutes: 12))
    ], [
      '0:41',
      '1:05',
      '12:00'
    ]);
  });

  testWidgets('checklist marks done, current and pending steps',
      (tester) async {
    await _pump(tester, _checklist(currentStep: 2));
    expect(find.byKey(const ValueKey('step-done-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-done-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-current-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-pending-3')), findsOneWidget);
    for (final label in [
      'Start requested',
      'Starting Android',
      'Starting the screen',
      'Live'
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('Alt-2'), findsOneWidget);
    expect(find.text('Android Emulator · Android 15'), findsOneWidget);
  });

  testWidgets('hint changes after a minute', (tester) async {
    await _pump(tester, _checklist(elapsed: const Duration(seconds: 41)));
    expect(find.text('0:41 · usually under a minute'), findsOneWidget);
    expect(find.textContaining('Taking longer than usual'), findsNothing);

    await _pump(tester, _checklist(elapsed: const Duration(seconds: 61)));
    expect(find.textContaining('Taking longer than usual'), findsOneWidget);
    expect(find.textContaining('usually under a minute'), findsNothing);
  });

  testWidgets(
      'Back to emulators is the bottom primary action and there are no Android keys',
      (tester) async {
    var backs = 0;
    await _pump(tester, _checklist(onBack: () => backs++));
    final back = find.ancestor(
        of: find.text('Back to emulators'),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(back, findsOneWidget);
    expect(tester.getRect(back).bottom, greaterThan(0.8 * _screen.height));
    expect(find.byTooltip('Home'), findsNothing);
    expect(find.byTooltip('Back'), findsNothing);
    expect(find.text('Recents'), findsNothing);
    expect(find.text('Home'), findsNothing);
    await tester.tap(back);
    await tester.pump();
    expect(backs, 1);
  });

  test('the fallback picker page says where back goes', () {
    expect(startupBackLabel(dashboardMode: true), 'Back to emulators');
    expect(startupBackLabel(dashboardMode: false), 'Return to Windows desktop');
  });

  testWidgets('legacy back label replaces Back to emulators', (tester) async {
    var backs = 0;
    await _pump(
        tester,
        StartupChecklist(
          name: 'Alt-2',
          providerLabel: 'BlueStacks',
          currentStep: 1,
          elapsed: const Duration(seconds: 5),
          onBack: () => backs++,
          backLabel: startupBackLabel(dashboardMode: false),
          backIcon: Icons.desktop_windows_outlined,
          tr: fakeTr,
        ));
    expect(find.text('Back to emulators'), findsNothing);
    final back = find.ancestor(
        of: find.text('Return to Windows desktop'),
        matching: find.byWidgetPredicate((w) => w is FilledButton));
    expect(back, findsOneWidget);
    await tester.tap(back);
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('Show on PC only when offered', (tester) async {
    await _pump(tester, _checklist());
    expect(find.text('Show on PC'), findsNothing);

    var shows = 0;
    await _pump(tester, _checklist(onShowOnPc: () => shows++));
    expect(find.text('Show on PC'), findsOneWidget);
    await tester.tap(find.text('Show on PC'));
    await tester.pump();
    expect(shows, 1);
  });

  testWidgets('failure marks the failed step and puts the PC message second',
      (tester) async {
    var retries = 0;
    await _pump(
        tester,
        _checklist(
          currentStep: 1,
          failedStep: 1,
          failureTitle: "Couldn't start {Alt-2}",
          failureMessage: 'ADB did not answer',
          onTryAgain: () => retries++,
        ));
    expect(find.byKey(const ValueKey('step-failed-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-done-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-pending-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-pending-3')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-current-1')), findsNothing);
    final title = find.text("Couldn't start Alt-2");
    final message = find.text('ADB did not answer');
    expect(title, findsOneWidget);
    expect(message, findsOneWidget);
    expect(
        tester.getTopLeft(title).dy, lessThan(tester.getTopLeft(message).dy));
    expect(find.textContaining('usually under a minute'), findsNothing);
    expect(find.textContaining('0:41'), findsNothing);
    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(retries, 1);
    // Back to emulators stays available on the failure screen.
    expect(find.text('Back to emulators'), findsOneWidget);
  });

  testWidgets('retry note shows only while armed', (tester) async {
    await _pump(
        tester,
        _checklist(
          failedStep: 3,
          failureTitle: 'Lost the screen for {Alt-2}',
          failureMessage: 'Stream ended',
          retryNote: 'Trying again in 3 s (2 of 2)',
        ));
    expect(find.text('Trying again in 3 s (2 of 2)'), findsOneWidget);

    await _pump(
        tester,
        _checklist(
          failedStep: 3,
          failureTitle: 'Lost the screen for {Alt-2}',
          failureMessage: 'Stream ended',
        ));
    expect(find.textContaining('Trying again'), findsNothing);
  });

  testWidgets('landscape failure at large text scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(915, 412);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var backs = 0;
    await tester.pumpWidget(MaterialApp(
      theme: MirpgRemoteTheme.build(ThemeData.dark()),
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!),
      home: Scaffold(
          body: _checklist(
        failedStep: 1,
        failureTitle: "Couldn't start {Alt-2}",
        failureMessage: 'ADB did not answer',
        retryNote: 'Trying again in 1 s (1 of 2)',
        onBack: () => backs++,
        onTryAgain: () {},
        onShowOnPc: () {},
      )),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
    final back = find.text('Back to emulators');
    await tester.scrollUntilVisible(back, 100,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(back);
    await tester.pump();
    expect(backs, 1);
  });

  testWidgets('switch placeholder shows the name on black without a frame',
      (tester) async {
    await _pump(tester, const SwitchPlaceholder(name: 'Alt-1'));
    expect(find.text('Alt-1'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
