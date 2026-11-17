import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/screens_tab.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

Future<void> pumpAt(WidgetTester tester, Size size, Widget body,
    {double textScale = 1.0}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: body,
      ),
    ),
  ));
}

Widget card({
  bool live = true,
  String error = '',
  String detail = '',
  VoidCallback? onOpen,
  VoidCallback? onRetry,
  VoidCallback? onWindows,
  String Function(String) tr = fakeTr,
}) =>
    TargetPreviewCard(
      name: 'Monitor 1',
      detail: detail,
      live: live,
      error: error,
      onOpen: onOpen,
      onRetry: onRetry,
      onWindows: onWindows,
      tr: tr,
    );

void main() {
  test('screens previews start at the first visible monitor', () {
    expect(screensPreviewDisplays(monitorCount: 3, firstVisibleIndex: 0),
        [0, 1, 2]);
    expect(screensPreviewDisplays(monitorCount: 6, firstVisibleIndex: 3),
        [3, 4, 5, 2]);
    expect(screensPreviewDisplays(monitorCount: 0, firstVisibleIndex: 0),
        isEmpty);
  });

  test('card aspect ratio is clamped between 1.0 and 2.4', () {
    expect(const ScreensTabCard(aspectRatio: 0.5, child: SizedBox()).aspectRatio,
        1.0);
    expect(const ScreensTabCard(aspectRatio: 5, child: SizedBox()).aspectRatio,
        2.4);
    expect(
        const ScreensTabCard(aspectRatio: 16 / 9, child: SizedBox())
            .aspectRatio,
        16 / 9);
  });

  testWidgets('Screens shows one full-width card per monitor and no filter',
      (tester) async {
    await pumpAt(
      tester,
      const Size(412, 915),
      ScreensTabBody(
        hostName: 'atlas',
        tr: fakeTr,
        cards: [
          for (var i = 0; i < 3; i++)
            ScreensTabCard(
                aspectRatio: 16 / 9,
                child: ColoredBox(
                    key: ValueKey('m$i'), color: const Color(0xFF123456))),
        ],
      ),
    );
    for (var i = 0; i < 3; i++) {
      expect(tester.getSize(find.byKey(ValueKey('m$i'))).width, 412 - 32);
    }
    final dy = [
      for (var i = 0; i < 3; i++) tester.getTopLeft(find.byKey(ValueKey('m$i'))).dy
    ];
    expect(dy[0], lessThan(dy[1]));
    expect(dy[1], lessThan(dy[2]));
    expect(find.text('PC screens'), findsOneWidget);
    expect(find.textContaining('Android'), findsNothing);
    expect(find.textContaining('All ('), findsNothing);
  });

  testWidgets('no monitors yet names the PC', (tester) async {
    await pumpAt(tester, const Size(412, 915),
        ScreensTabBody(hostName: 'atlas', tr: fakeTr, cards: const []));
    expect(find.text('No screens from atlas yet'), findsOneWidget);
  });

  testWidgets('monitor card offers Reconnect only while not live',
      (tester) async {
    var retries = 0;
    await pumpAt(tester, const Size(412, 915),
        card(live: true, onRetry: () => retries++));
    expect(find.text('Reconnect'), findsNothing);
    expect(find.text('Live'), findsOneWidget);

    await pumpAt(tester, const Size(412, 915),
        card(live: false, onRetry: () => retries++));
    expect(find.text('Waiting for preview'), findsOneWidget);
    await tester.tap(find.text('Reconnect'));
    expect(retries, 1);

    await pumpAt(tester, const Size(412, 915),
        card(live: false, error: 'Capture failed', onRetry: () => retries++));
    expect(find.text('Problem'), findsOneWidget);
    expect(find.text('Capture failed'), findsOneWidget);
  });

  testWidgets('monitor card opens and shows Windows', (tester) async {
    var opens = 0;
    var windows = 0;
    await pumpAt(
        tester,
        const Size(412, 915),
        card(
            detail: '2560 × 1440',
            onOpen: () => opens++,
            onWindows: () => windows++));
    expect(find.text('2560 × 1440'), findsOneWidget);
    await tester.tap(find.text('Windows'));
    expect(windows, 1);
    await tester.tap(find.text('Open'));
    expect(opens, 1);

    await pumpAt(tester, const Size(412, 915), card(onOpen: () => opens++));
    expect(find.text('Windows'), findsNothing);
  });

  testWidgets('monitor card words go through translate', (tester) async {
    await pumpAt(tester, const Size(412, 915),
        card(live: true, tr: (k) => '[$k]'));
    expect(find.text('[Live]'), findsOneWidget);
    expect(find.text('[Open]'), findsOneWidget);
  });

  testWidgets('switcher grid uses two columns in portrait and four in landscape',
      (tester) async {
    Widget grid() => TargetSwitcherGrid(cards: [
          for (var i = 0; i < 6; i++) SizedBox(key: ValueKey('c$i')),
        ]);
    double dy(int i) => tester.getTopLeft(find.byKey(ValueKey('c$i'))).dy;

    await pumpAt(tester, const Size(412, 915), grid());
    expect(dy(0), dy(1));
    expect(dy(2), greaterThan(dy(0)));

    await pumpAt(tester, const Size(915, 412), grid());
    expect(dy(0), dy(1));
    expect(dy(0), dy(2));
    expect(dy(0), dy(3));
    expect(dy(4), greaterThan(dy(0)));
  });

  testWidgets('monitor card fits a 230×145 chooser cell at 1.3 text scale',
      (tester) async {
    await pumpAt(
      tester,
      const Size(412, 915),
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 230,
          height: 145,
          child: card(
              live: false,
              error:
                  'Enable ADB debugging in this emulator instance before connecting',
              onRetry: () {}),
        ),
      ),
      textScale: 1.3,
    );
    expect(tester.takeException(), isNull);
    expect(find.text('Reconnect'), findsOneWidget);
  });
}
