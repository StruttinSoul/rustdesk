import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/aperture_host_panel.dart';

void main() {
  testWidgets('host controls and secondary actions remain available',
      (tester) async {
    var settings = 0;
    var connect = 0;
    var hide = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ApertureHostPanel(
      status: const Text('Ready'),
      identity: const Text('1984606088'),
      password: const Text('One-time Password'),
      notice: const Text('Connection warning'),
      translate: (key) => key,
      onSettings: () => settings++,
      onConnect: () => connect++,
      onHide: () => hide++,
    ))));
    expect(find.text('Aperture'), findsOneWidget);
    for (final text in [
      'Ready',
      '1984606088',
      'One-time Password',
      'Connection warning'
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.text('Control Remote Desktop'), findsNothing);
    await tester.tap(find.byTooltip('Settings'));
    await tester.tap(find.text('Connect'));
    await tester.tap(find.text('Minimize'));
    expect([settings, connect, hide], [1, 1, 1]);
  });

  testWidgets('restricted host omits unavailable actions', (tester) async {
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ApertureHostPanel(
      status: const Text('Service is not running'),
      identity: const Text('ID'),
      password: const Text('Password'),
      translate: (key) => key,
      onSettings: null,
      onConnect: null,
      onHide: () {},
    ))));
    expect(find.byTooltip('Settings'), findsNothing);
    expect(find.text('Connect'), findsNothing);
    expect(find.text('Service is not running'), findsOneWidget);
    expect(find.text('Minimize'), findsOneWidget);
  });

  testWidgets('host panel scrolls at large text sizes without overflow',
      (tester) async {
    tester.view.physicalSize = const Size(360, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
          body: ApertureHostPanel(
        status: const Text('Service is not running'),
        identity: const SizedBox(height: 80, child: Text('1984606088')),
        password: const SizedBox(height: 80, child: Text('One-time Password')),
        notice: const Text('Connection warning'),
        translate: (key) => key,
        onSettings: () {},
        onConnect: () {},
        onHide: () {},
      )),
    )));
    await tester.scrollUntilVisible(find.text('Minimize'), 180);
    expect(find.text('Minimize').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
