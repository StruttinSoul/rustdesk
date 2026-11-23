import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/desktop/widgets/aperture_settings_frame.dart';

void main() {
  testWidgets('settings retains navigation and applies Aperture surfaces',
      (tester) async {
    var selected = false;
    Color? cardColor;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
          body: ApertureSettingsFrame(
        title: 'Settings',
        navigation: ListView(children: [
          ApertureSettingsItem(
            label: 'Account',
            icon: Icons.person_outline,
            selected: true,
            onTap: () => selected = true,
          )
        ]),
        content: Builder(builder: (context) {
          cardColor = Theme.of(context).cardTheme.color;
          return const Text('Existing settings controls');
        }),
      )),
    ));
    expect(find.text('Aperture'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Existing settings controls'), findsOneWidget);
    expect(cardColor, const Color(0xFF1C2938));
    await tester.tap(find.text('Account'));
    expect(selected, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings fills the viewport and supports large navigation text',
      (tester) async {
    tester.view.physicalSize = const Size(760, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: const MediaQueryData(textScaler: TextScaler.linear(2)),
      child: Scaffold(
          body: Stack(key: const Key('settings-window'), children: [
        ApertureSettingsFrame(
          title: 'Settings',
          navigation: ListView(children: [
            ApertureSettingsItem(
              label: 'BlueStacks',
              icon: Icons.layers_outlined,
              selected: false,
              onTap: () {},
            )
          ]),
          content: const Text('Controls'),
        ),
      ])),
    )));
    expect(tester.getSize(find.byType(ApertureSettingsFrame)),
        tester.getSize(find.byKey(const Key('settings-window'))));
    expect(find.text('BlueStacks').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings buttons and selections use Aperture cobalt',
      (tester) async {
    ThemeData? theme;
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
          body: ApertureSettingsFrame(
        title: 'Settings',
        navigation: const SizedBox(),
        content: Builder(builder: (context) {
          theme = Theme.of(context);
          return ElevatedButton(onPressed: () {}, child: const Text('Stop'));
        }),
      )),
    ));
    const cobalt = Color(0xFF3361D8);
    final style = theme!.elevatedButtonTheme.style!;
    expect(style.backgroundColor!.resolve(<WidgetState>{}), cobalt);
    expect(style.foregroundColor!.resolve(<WidgetState>{}), Colors.white);
    expect(
        theme!.checkboxTheme.fillColor!
            .resolve(<WidgetState>{WidgetState.selected}),
        cobalt);
    expect(
        theme!.radioTheme.fillColor!
            .resolve(<WidgetState>{WidgetState.selected}),
        cobalt);
    expect(tester.takeException(), isNull);
  });
}
