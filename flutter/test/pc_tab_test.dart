import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart';
import 'package:flutter_hbb/mobile/widgets/pc_tab.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

class PcCounts {
  int system = 0;
  int files = 0;
  int powershell = 0;
  int quality = 0;
  int privacy = 0;
  int trusts = 0;
  int forgets = 0;
  int settings = 0;
  int ends = 0;
}

Future<void> pump(
  WidgetTester tester,
  PcCounts c, {
  bool system = true,
  bool files = true,
  bool powershell = true,
  bool privacy = true,
  String pairing = '',
  double textScale = 1.0,
  double height = 800,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(360, height);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(360, height),
        textScaler: TextScaler.linear(textScale),
      ),
      child: Scaffold(
        body: PcTabBody(
          onSystem: system ? () => c.system++ : null,
          onFiles: files ? () => c.files++ : null,
          onPowerShell: powershell ? () => c.powershell++ : null,
          onQuality: () => c.quality++,
          onPrivacy: privacy ? () => c.privacy++ : null,
          pairingState: pairing,
          onTrustPhone: () => c.trusts++,
          onForgetPairing: () => c.forgets++,
          onSettings: () => c.settings++,
          onEndSession: () => c.ends++,
          tr: fakeTr,
        ),
      ),
    ),
  ));
}

void main() {
  testWidgets('PC tab groups rows and ends with a red End session',
      (tester) async {
    // The test font is wide, so rows wrap far more than on a phone; a tall
    // surface keeps every row built for the position checks.
    await pump(tester, PcCounts(), height: 1600);
    final order = [
      'This PC',
      'System and processes',
      'Files',
      'PowerShell',
      'Connection',
      'Quality and connection',
      'Privacy and host controls',
      'App',
      'Appearance and settings',
      'End session',
    ];
    var previous = -1.0;
    for (final label in order) {
      final top = tester.getTopLeft(find.text(label)).dy;
      expect(top, greaterThan(previous), reason: label);
      previous = top;
    }
    expect(tester.widget<Text>(find.text('End session')).style!.color,
        MirpgStudioPalette.dark.error);
  });

  testWidgets('End session stays when the PC offers no tools', (tester) async {
    final c = PcCounts();
    await pump(tester, c,
        system: false, files: false, powershell: false, privacy: false);
    for (final label in [
      'This PC',
      'System and processes',
      'Files',
      'PowerShell',
      'Privacy and host controls',
    ]) {
      expect(find.text(label), findsNothing, reason: label);
    }
    expect(find.text('End session'), findsOneWidget);
    await tester.tap(find.text('End session'));
    await tester.pump();
    expect(c.ends, 1);
  });

  testWidgets('each row runs only its own action', (tester) async {
    final c = PcCounts();
    await pump(tester, c, pairing: 'can-pair');
    for (final label in [
      'System and processes',
      'Files',
      'PowerShell',
      'Quality and connection',
      'Privacy and host controls',
      'Trust this phone',
      'Appearance and settings',
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(c.system, 1);
    expect(c.files, 1);
    expect(c.powershell, 1);
    expect(c.quality, 1);
    expect(c.privacy, 1);
    expect(c.trusts, 1);
    expect(c.settings, 1);
    expect(c.forgets, 0);
    expect(c.ends, 0);
    await tester.ensureVisible(find.text('End session'));
    await tester.tap(find.text('End session'));
    await tester.pump();
    expect(c.ends, 1);
  });

  testWidgets('trust row follows the pairing state', (tester) async {
    for (final state in ['', 'unavailable']) {
      await pump(tester, PcCounts(), pairing: state);
      expect(find.text('Trust this phone'), findsNothing, reason: state);
      expect(find.text('This phone is trusted'), findsNothing, reason: state);
    }

    final canPair = PcCounts();
    await pump(tester, canPair, pairing: 'can-pair');
    expect(find.text('Trust this phone'), findsOneWidget);
    await tester.tap(find.text('Trust this phone'));
    await tester.pump();
    expect(canPair.trusts, 1);

    final paired = PcCounts();
    await pump(tester, paired, pairing: 'paired');
    expect(find.text('This phone is trusted'), findsOneWidget);
    expect(find.text('Connects without a password'), findsOneWidget);
    expect(find.text('Trust this phone'), findsNothing);
    await tester.tap(find.text('Forget'));
    await tester.pump();
    expect(paired.forgets, 1);
    expect(paired.trusts, 0);
  });

  testWidgets('PC tab fits 360 dp at 1.3 text scale', (tester) async {
    final c = PcCounts();
    await pump(tester, c, pairing: 'paired', textScale: 1.3);
    await tester.scrollUntilVisible(find.text('End session'), 100);
    expect(tester.takeException(), isNull);
    expect(find.text('End session').hitTestable(), findsOneWidget);
  });
}
