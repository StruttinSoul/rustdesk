import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/reconnecting_banner.dart';
import 'package:flutter_hbb/models/session_reconnect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

void main() {
  late SessionReconnectController controller;
  late int taps;

  setUp(() {
    taps = 0;
    controller = SessionReconnectController(
      attempt: () {},
      onRestored: () {},
      onGiveUp: (_) {},
      isForeground: () => true,
    );
  });

  tearDown(() => controller.dispose());

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: [
            Positioned.fill(
                child: GestureDetector(
                    behavior: HitTestBehavior.opaque, onTap: () => taps++)),
            ReconnectingBanner(controller: controller, tr: fakeTr),
          ]),
        ),
      ));

  testWidgets('shows Reconnecting… only while attempts run, without a dialog',
      (tester) async {
    await pump(tester);
    expect(find.text('Reconnecting…'), findsNothing);

    controller.onMessage(
        {'type': 'error', 'title': 'Connection Error', 'text': 'Timeout'});
    await tester.pump();
    expect(find.text('Reconnecting…'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);

    controller.onConnected();
    await tester.pump();
    expect(find.text('Reconnecting…'), findsNothing);
  });

  testWidgets('does not block the view underneath', (tester) async {
    await pump(tester);
    controller.onMessage(
        {'type': 'error', 'title': 'Connection Error', 'text': 'Timeout'});
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('Reconnecting…')));
    expect(taps, 1);
    controller.cancel(); // stop its 60 s timer
  });
}
