import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/trust_phone_sheet.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

void main() {
  test('the prompt is offered once, only when the PC can pair', () {
    expect(shouldOfferPairing(pairingState: 'can-pair', promptedFlag: ''),
        isTrue);
    expect(shouldOfferPairing(pairingState: 'can-pair', promptedFlag: 'Y'),
        isFalse);
    for (final s in ['', 'paired', 'unavailable']) {
      expect(shouldOfferPairing(pairingState: s, promptedFlag: ''), isFalse,
          reason: s);
    }
  });

  test('keys are per PC', () {
    expect(pairPromptedKey('123'), 'aperture-pair-prompted:123');
    expect(pairedFlagKey('123'), 'aperture-paired:123');
  });

  Future<void> pumpHost(WidgetTester tester, List<bool?> results,
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
        child: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () async => results.add(await showTrustPhoneSheet(
                    context,
                    hostName: 'atlas',
                    tr: fakeTr)),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  testWidgets('sheet names the PC and returns the choice', (tester) async {
    final results = <bool?>[];
    await pumpHost(tester, results);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Trust this phone on atlas?'), findsOneWidget);
    expect(find.text('Next time it connects without a password.'),
        findsOneWidget);
    await tester.tap(find.text('Trust'));
    await tester.pumpAndSettle();
    expect(results, [true]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(results, [true, false]);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(results, [true, false, null]);
  });

  testWidgets('sheet fits 360 dp at 1.3 text scale', (tester) async {
    final results = <bool?>[];
    await pumpHost(tester, results, textScale: 1.3);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Trust'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
