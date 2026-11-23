import 'package:flutter/material.dart';
import 'package:flutter_hbb/common/widgets/studio_theme.dart';
import 'package:flutter_hbb/mobile/widgets/settings_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settings_ui/settings_ui.dart';

import 'support/fake_translate.dart';

const prePhase2Rows = [
  'account',
  'appearance',
  'language',
  'display-settings',
  'hwcodec',
  'keep-awake-outgoing',
  'note-at-conn-end',
  'terminal-extra-keys',
  'background-service',
  'start-on-boot',
  'floating-window',
  'keep-screen-on',
  'deny-lan-discovery',
  'ip-whitelisting',
  'id-whitelisting',
  'adaptive-bitrate',
  'enable-recording-session',
  'direct-ip-access',
  'auto-disconnect',
  '2fa',
  'telegram-bot',
  'trusted-devices',
  'manage-trusted-devices',
  'id-relay-server',
  'proxy',
  'deploy',
  'websocket',
  'insecure-tls-fallback',
  'disable-udp',
  'tcp-punch',
  'udp-punch',
  'ipv6-punch',
  'webrtc',
  'auto-record-incoming',
  'auto-record-outgoing',
  'recording-directory',
  'version',
  'build-date',
  'fingerprint',
  'my-id',
  'privacy-statement',
];

const networkIds = [
  'id-relay-server',
  'proxy',
  'deploy',
  'websocket',
  'insecure-tls-fallback',
  'disable-udp',
  'tcp-punch',
  'udp-punch',
  'ipv6-punch',
  'webrtc',
];

Map<String, AbstractSettingsTile> rowsFor(Iterable<String> ids) =>
    {for (final id in ids) id: SettingsTile(title: Text(id))};

final allIds = [...prePhase2Rows, 'built-on-rustdesk'];

Future<void> pumpSections(
  WidgetTester tester,
  Map<String, AbstractSettingsTile> rows, {
  bool networkExpanded = true,
  VoidCallback? onToggleNetwork,
  Size size = const Size(360, 8000),
  double textScale = 1.0,
  Brightness brightness = Brightness.dark,
  bool studioList = false,
}) async {
  final sections = buildMobileSettingsSections(
    rows: rows,
    networkExpanded: networkExpanded,
    onToggleNetwork: onToggleNetwork ?? () {},
    tr: fakeTr,
  );
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(
        brightness == Brightness.dark ? ThemeData.dark() : ThemeData.light()),
    home: MediaQuery(
      data:
          MediaQueryData(size: size, textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: studioList
            ? MobileSettingsList(sections: sections)
            : SettingsList(sections: sections),
      ),
    ),
  ));
}

List<String> inDyOrder(WidgetTester tester, List<String> texts) {
  final found = [
    for (final t in texts)
      if (find.text(t).evaluate().isNotEmpty)
        (t, tester.getTopLeft(find.text(t).first).dy)
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final f in found) f.$1];
}

const groupTitles = [
  'Account',
  'Appearance',
  'Display defaults',
  'Sharing this phone',
  'Security',
  'Network',
  'Recording',
  'About Aperture',
];

void main() {
  test('every row from before Phase 2 has exactly one place', () {
    final placed = kMobileSettingsLayout.values.expand((ids) => ids).toList();
    for (final id in prePhase2Rows) {
      expect(placed.where((p) => p == id).length, 1, reason: id);
    }
    expect(placed.toSet().difference(prePhase2Rows.toSet()),
        {'built-on-rustdesk'});
  });

  testWidgets('groups follow the spec order and skip empty ones',
      (tester) async {
    await pumpSections(tester, rowsFor(allIds));
    // 'Appearance' is both a group title and a row id; take titles only.
    expect(
        inDyOrder(tester, groupTitles.where((t) => t != 'Appearance').toList()),
        groupTitles.where((t) => t != 'Appearance').toList());
    expect(find.byType(SettingsSection), findsNWidgets(groupTitles.length));

    await pumpSections(tester, rowsFor(['appearance', 'version']));
    expect(find.byType(SettingsSection), findsNWidgets(2));
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('About Aperture'), findsOneWidget);
    expect(find.text('Network'), findsNothing);
  });

  testWidgets('network rows stay folded until Advanced is opened',
      (tester) async {
    var toggles = 0;
    await pumpSections(tester, rowsFor(allIds),
        networkExpanded: false, onToggleNetwork: () => toggles++);
    expect(find.text('Advanced'), findsOneWidget);
    expect(find.text('Server, proxy and connection options'), findsOneWidget);
    expect(find.byIcon(Icons.expand_more), findsOneWidget);
    expect(find.text('websocket'), findsNothing);
    expect(find.text('id-relay-server'), findsNothing);

    await tester.tap(find.text('Advanced'));
    expect(toggles, 1);

    await pumpSections(tester, rowsFor(allIds), networkExpanded: true);
    expect(find.byIcon(Icons.expand_less), findsOneWidget);
    expect(inDyOrder(tester, networkIds), networkIds);
  });

  testWidgets('a row the layout does not know is still shown', (tester) async {
    await pumpSections(tester, rowsFor([...allIds, 'mystery']));
    expect(find.text('Other'), findsOneWidget);
    expect(find.text('mystery'), findsOneWidget);
  });

  testWidgets('rows that are absent stay absent', (tester) async {
    await pumpSections(
        tester, rowsFor(allIds.where((id) => id != 'terminal-extra-keys')));
    expect(find.text('terminal-extra-keys'), findsNothing);
    expect(find.text('Display defaults'), findsOneWidget);
    expect(find.text('display-settings'), findsOneWidget);
    expect(find.text('note-at-conn-end'), findsOneWidget);
  });

  testWidgets('settings fit 360 dp at 1.3 text scale', (tester) async {
    await pumpSections(tester, rowsFor(allIds),
        size: const Size(360, 640), textScale: 1.3);
    expect(tester.takeException(), isNull);
    for (var i = 0; i < 40; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -400));
      await tester.pump();
      expect(tester.takeException(), isNull);
    }
    expect(find.text('built-on-rustdesk'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('the list paints the Studio palette (${brightness.name})',
        (tester) async {
      await pumpSections(tester, rowsFor(['appearance', 'version']),
          brightness: brightness, studioList: true);
      final palette = brightness == Brightness.dark
          ? MirpgStudioPalette.dark
          : MirpgStudioPalette.light;
      final list = find.byType(SettingsList);
      final background = tester.widget<Container>(
          find.descendant(of: list, matching: find.byType(Container)).first);
      expect(background.color, palette.background);
      final title = tester.widget<DefaultTextStyle>(find
          .ancestor(
              of: find.text('About Aperture'),
              matching: find.byType(DefaultTextStyle))
          .first);
      expect(title.style.color, palette.accent);
    });
  }
}
