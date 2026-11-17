import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart';
import 'package:flutter_hbb/mobile/widgets/computers_hero.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

Future<void> pumpBody(WidgetTester tester, Widget body,
    {double textScale = 1.0}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 800);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: MediaQuery(
      data: MediaQueryData(
        size: const Size(360, 800),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: body,
        ),
      ),
    ),
  ));
}

void main() {
  group('ConnectAttemptTracker', () {
    test('cancelling the connect or password dialog is not a failure', () {
      final t = ConnectAttemptTracker()..started('1');
      t.ended('1', authenticated: false, reason: '');
      expect(t.value.phase, ConnectPhase.idle);
    });

    test('a connection error keeps its reason for the card', () {
      final t = ConnectAttemptTracker()..started('1');
      t.ended('1', authenticated: false, reason: 'Remote desktop is offline');
      expect((t.value.phase, t.value.peerId, t.value.reason),
          (ConnectPhase.failed, '1', 'Remote desktop is offline'));
    });

    test('an older page closing does not overwrite a newer attempt', () {
      final t = ConnectAttemptTracker()
        ..started('1')
        ..started('2');
      t.ended('1', authenticated: false, reason: 'x');
      expect((t.value.phase, t.value.peerId), (ConnectPhase.connecting, '2'));
    });

    test('reaching the PC clears an earlier failure', () {
      final t = ConnectAttemptTracker()..started('1');
      t.ended('1', authenticated: false, reason: 'x');
      t
        ..started('1')
        ..authenticated('1');
      expect(t.value.phase, ConnectPhase.idle);
      t.ended('1', authenticated: true, reason: 'Connection reset');
      expect(t.value.phase, ConnectPhase.idle);
    });
  });

  group('ComputerHeroCard', () {
    int connects = 0;

    Widget card(ComputerHeroData data,
            [ConnectAttempt attempt = const ConnectAttempt()]) =>
        ComputerHeroCard(
          data: data,
          attempt: attempt,
          onConnect: () => connects++,
          tr: fakeTr,
        );

    setUp(() => connects = 0);

    testWidgets('idle card names the PC, its state and one Connect',
        (tester) async {
      await pumpBody(
          tester,
          card(const ComputerHeroData(
              id: '1', name: 'atlas', online: true, trusted: true)));
      expect(find.text('ATLAS'), findsOneWidget);
      expect(find.text('atlas'), findsNothing);
      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Trusted · connects without password'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
      await tester.tap(find.text('Connect'));
      expect(connects, 1);
    });

    testWidgets('offline is stated and unknown is not', (tester) async {
      await pumpBody(tester,
          card(const ComputerHeroData(id: '1', name: 'atlas', online: false)));
      expect(find.text('Offline'), findsOneWidget);
      expect(find.text('Online'), findsNothing);

      await pumpBody(tester,
          card(const ComputerHeroData(id: '1', name: 'atlas', online: null)));
      expect(find.text('Offline'), findsNothing);
      expect(find.text('Online'), findsNothing);
    });

    testWidgets('connecting disables the button', (tester) async {
      await pumpBody(
          tester,
          card(const ComputerHeroData(id: '1', name: 'atlas'),
              const ConnectAttempt(
                  phase: ConnectPhase.connecting, peerId: '1')));
      expect(find.text('Connecting…'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      await tester.tap(find.text('Connecting…'), warnIfMissed: false);
      expect(connects, 0);
    });

    testWidgets('failure puts the reason under the title and offers Try again',
        (tester) async {
      await pumpBody(
          tester,
          card(
              const ComputerHeroData(id: '1', name: 'atlas', online: true),
              const ConnectAttempt(
                  phase: ConnectPhase.failed,
                  peerId: '1',
                  reason: 'Remote desktop is offline')));
      final title = tester.getTopLeft(find.text("Couldn't connect to atlas"));
      final reason = tester.getTopLeft(find.text('Remote desktop is offline'));
      expect(title.dy, lessThan(reason.dy));
      expect(find.text('Connect'), findsNothing);
      await tester.tap(find.text('Try again'));
      expect(connects, 1);
    });

    testWidgets('a failure for another PC does not show', (tester) async {
      await pumpBody(
          tester,
          card(
              const ComputerHeroData(id: '1', name: 'atlas'),
              const ConnectAttempt(
                  phase: ConnectPhase.failed, peerId: '2', reason: 'x')));
      expect(find.text('Connect'), findsOneWidget);
      expect(find.text("Couldn't connect to atlas"), findsNothing);
    });

    testWidgets(
        'hero fits 360 dp at 1.3 text scale with a long name and reason',
        (tester) async {
      final reason = List.filled(13, 'abcdefghi').join(' ').substring(0, 120);
      await pumpBody(
          tester,
          card(
              const ComputerHeroData(
                  id: '1',
                  name: 'atlas-gaming-workstation-upstairs',
                  online: true,
                  trusted: true),
              ConnectAttempt(
                  phase: ConnectPhase.failed, peerId: '1', reason: reason)),
          textScale: 1.3);
      expect(tester.takeException(), isNull);
    });
  });

  group('hostDisplayName', () {
    test('shows the PC name in capitals without changing the stored name', () {
      const data = ComputerHeroData(id: '1', name: 'atlas');
      expect(hostDisplayName(data.name), 'ATLAS');
      expect(data.name, 'atlas');
      expect(hostDisplayName('Your PC'), 'YOUR PC');
      expect(hostDisplayName(''), '');
    });
  });

  group('AddComputerSection', () {
    int saved = 0;
    List<bool> changes = [];

    Widget section({required bool hasHero, required bool expanded}) =>
        AddComputerSection(
          hasHero: hasHero,
          expanded: expanded,
          onExpandedChanged: changes.add,
          idField: const TextField(key: ValueKey('id')),
          onSavedComputers: () => saved++,
          tr: fakeTr,
        );

    setUp(() {
      saved = 0;
      changes = [];
    });

    testWidgets('Add another computer starts collapsed', (tester) async {
      await pumpBody(tester, section(hasHero: true, expanded: false));
      expect(find.byKey(const ValueKey('id')), findsNothing);
      expect(find.text('Saved computers'), findsNothing);
      await tester.tap(find.text('Add another computer'));
      expect(changes, [true]);

      await pumpBody(tester, section(hasHero: true, expanded: true));
      expect(find.byKey(const ValueKey('id')), findsOneWidget);
      await tester.tap(find.text('Saved computers'));
      expect(saved, 1);
    });

    testWidgets('without a last PC the ID field is open', (tester) async {
      await pumpBody(tester, section(hasHero: false, expanded: false));
      expect(find.text('Add a computer'), findsOneWidget);
      expect(find.byKey(const ValueKey('id')), findsOneWidget);
      expect(find.text('Add another computer'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
    });
  });
}
