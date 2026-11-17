import 'dart:ui' show SemanticsFlag;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/play_rail.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_translate.dart';

const _accounts = [
  PlayAccount(id: 'avd:Main', label: 'Main', word: EmulatorUiWord.live),
  PlayAccount(id: 'avd:Alt-1', label: 'Alt-1', word: EmulatorUiWord.live),
  PlayAccount(id: 'avd:Alt-2', label: 'Alt-2', word: EmulatorUiWord.starting),
];

Future<void> _pumpRail(
  WidgetTester tester, {
  required Size size,
  Axis axis = Axis.horizontal,
  List<PlayAccount> accounts = _accounts,
  bool switching = false,
  List<String>? selected,
  List<String>? nav,
  void Function()? onAll,
  void Function()? onGrid,
  void Function()? onActions,
  void Function()? onType,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: Align(
        alignment: axis == Axis.horizontal
            ? Alignment.bottomCenter
            : Alignment.centerRight,
        child: SizedBox(
          width: axis == Axis.horizontal ? size.width : kPlayRailSideWidth,
          height: axis == Axis.horizontal ? kPlayRailBottomHeight : size.height,
          child: PlayRail(
            accounts: accounts,
            currentId: 'avd:Main',
            axis: axis,
            onSelect: (id) => selected?.add(id),
            onShowAll: onAll,
            onGrid: onGrid ?? () {},
            onGridLongPress: onActions,
            onType: onType,
            onNavigate: nav?.add,
            switching: switching,
            tr: fakeTr,
          ),
        ),
      ),
    ),
  ));
}

void main() {
  test('portrait 9:16 game on a 19.5:9 phone docks the rail at the bottom', () {
    expect(
        playRailPlacement(
            viewport: const Size(412, 915),
            guestWidth: 1080,
            guestHeight: 1920),
        PlayRailPlacement.bottom);
  });
  test('landscape 16:9 game docks the rail on the short edge', () {
    expect(
        playRailPlacement(
            viewport: const Size(915, 412),
            guestWidth: 1920,
            guestHeight: 1080),
        PlayRailPlacement.side);
  });
  test('a game that fills the screen collapses the rail', () {
    expect(
        playRailPlacement(
            viewport: const Size(915, 412),
            guestWidth: 2400,
            guestHeight: 1080),
        PlayRailPlacement.collapsed);
  });
  test('small viewport changes near the threshold do not flip the rail', () {
    // 9:16 guest, width 412: frame height 732.4; bottom needs 88 dp of spare height.
    expect(
        playRailPlacement(
            viewport: const Size(412, 821),
            guestWidth: 1080,
            guestHeight: 1920),
        PlayRailPlacement.bottom);
    expect(
        playRailPlacement(
            viewport: const Size(412, 810),
            guestWidth: 1080,
            guestHeight: 1920,
            previous: PlayRailPlacement.bottom),
        PlayRailPlacement.bottom);
    expect(
        playRailPlacement(
            viewport: const Size(412, 810),
            guestWidth: 1080,
            guestHeight: 1920),
        isNot(PlayRailPlacement.bottom));
    expect(
        playRailPlacement(
            viewport: const Size(412, 800),
            guestWidth: 1080,
            guestHeight: 1920,
            previous: PlayRailPlacement.bottom),
        isNot(PlayRailPlacement.bottom));
  });
  test('every 1 to 15 dp loss (system bars, insets) keeps a docked rail', () {
    for (var d = 1; d <= 15; d++) {
      // Bottom: 821 dp tall leaves 88.6 dp under a 9:16 game.
      expect(
          playRailPlacement(
              viewport: Size(412, 821.0 - d),
              guestWidth: 1080,
              guestHeight: 1920,
              previous: PlayRailPlacement.bottom),
          PlayRailPlacement.bottom,
          reason: 'bottom, $d dp');
      // Side: 805 dp wide leaves 72.6 dp beside a 16:9 game.
      expect(
          playRailPlacement(
              viewport: Size(805.0 - d, 412),
              guestWidth: 1920,
              guestHeight: 1080,
              previous: PlayRailPlacement.side),
          PlayRailPlacement.side,
          reason: 'side, $d dp');
      // And regaining the same few dp does not re-dock a collapsed rail
      // until the full size fits again.
      expect(
          playRailPlacement(
              viewport: Size(412, 821.0 - d),
              guestWidth: 1080,
              guestHeight: 1920,
              previous: PlayRailPlacement.collapsed),
          PlayRailPlacement.collapsed,
          reason: 're-dock, $d dp');
    }
  });
  test('a missing guest size collapses the rail', () {
    expect(
        playRailPlacement(
            viewport: const Size(412, 915), guestWidth: 0, guestHeight: 0),
        PlayRailPlacement.collapsed);
  });
  test('chips list live and starting emulators plus the current one', () {
    const all = [
      PlayAccount(id: 'a', label: 'A', word: EmulatorUiWord.live),
      PlayAccount(id: 'b', label: 'B', word: EmulatorUiWord.stopped),
      PlayAccount(id: 'c', label: 'C', word: EmulatorUiWord.starting),
      PlayAccount(id: 'd', label: 'D', word: EmulatorUiWord.problem),
      PlayAccount(id: 'e', label: 'E', word: EmulatorUiWord.copying),
    ];
    expect(playRailAccounts(all, currentId: 'd').map((a) => a.id),
        ['a', 'c', 'd']);
    expect(playRailAccounts(all).map((a) => a.id), ['a', 'c']);
  });
  test('a switch is ignored while one is connecting or for the current one',
      () {
    expect(
        playRailCanSwitch(
            id: 'b', currentId: 'a', connecting: false, pending: false),
        isTrue);
    expect(
        playRailCanSwitch(
            id: 'b', currentId: 'a', connecting: true, pending: false),
        isFalse);
    expect(
        playRailCanSwitch(
            id: 'c', currentId: 'b', connecting: false, pending: true),
        isFalse,
        reason: 'A second tap before the first switch reaches the PC');
    expect(
        playRailCanSwitch(
            id: 'a', currentId: 'a', connecting: false, pending: false),
        isFalse);
  });
  testWidgets('banner shows for two seconds then hides', (tester) async {
    final c = NameBannerController()..show('Alt-1 · Live');
    addTearDown(c.dispose);
    expect((c.visible, c.text), (true, 'Alt-1 · Live'));
    await tester.pump(const Duration(milliseconds: 1999));
    expect(c.visible, isTrue);
    await tester.pump(const Duration(milliseconds: 2));
    expect(c.visible, isFalse);
  });

  testWidgets('chips follow grid order and mark the current account',
      (tester) async {
    final selected = <String>[];
    await _pumpRail(tester, size: const Size(412, 915), selected: selected);
    final main = tester.getCenter(find.text('Main')).dx;
    final alt1 = tester.getCenter(find.text('Alt-1')).dx;
    final alt2 = tester.getCenter(find.text('Alt-2')).dx;
    expect(main, lessThan(alt1));
    expect(alt1, lessThan(alt2));
    expect(
        tester
            .getSemantics(find.text('Main'))
            .hasFlag(SemanticsFlag.isSelected),
        isTrue);
    expect(
        tester
            .getSemantics(find.text('Alt-1'))
            .hasFlag(SemanticsFlag.isSelected),
        isFalse);
    await tester.tap(find.text('Alt-1'));
    await tester.pump();
    expect(selected, ['avd:Alt-1']);
    await tester.tap(find.text('Main'));
    await tester.pump();
    expect(selected, ['avd:Alt-1'], reason: 'The current chip does nothing');
    expect(tester.takeException(), isNull);
  });

  testWidgets('chips are disabled while a switch is connecting',
      (tester) async {
    final selected = <String>[];
    await _pumpRail(tester,
        size: const Size(412, 915), selected: selected, switching: true);
    await tester.tap(find.text('Alt-1'));
    await tester.pump();
    expect(selected, isEmpty);
  });

  testWidgets('plus opens the full list and keys keep their actions',
      (tester) async {
    var all = 0, grid = 0, actions = 0, typed = 0;
    final nav = <String>[];
    await _pumpRail(
      tester,
      size: const Size(412, 915),
      nav: nav,
      onAll: () => all++,
      onGrid: () => grid++,
      onActions: () => actions++,
      onType: () => typed++,
    );
    await tester.tap(find.byTooltip('Show all emulators'));
    await tester.pump();
    expect(all, 1);
    await tester.tap(find.byTooltip('Type text'));
    await tester.pump();
    expect(typed, 1);
    for (final key in ['Back', 'Home', 'Recents']) {
      await tester.tap(find.byTooltip(key));
      await tester.pump();
    }
    expect(nav, ['back', 'home', 'recents']);
    await tester.longPress(find.byTooltip('Emulators'));
    await tester.pump();
    expect(actions, 1);
    expect(grid, 0);
    await tester.tap(find.byTooltip('Emulators'));
    await tester.pump();
    expect(grid, 1);
    expect(actions, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keys are disabled without their callbacks', (tester) async {
    await _pumpRail(tester, size: const Size(412, 915));
    for (final key in ['Type text', 'Back', 'Home', 'Recents']) {
      final button = tester.widget<IconButton>(find.ancestor(
          of: find.byTooltip(key), matching: find.byType(IconButton)));
      expect(button.onPressed, isNull, reason: key);
    }
  });

  testWidgets('vertical rail fits 72 dp wide at 412 dp tall with four accounts',
      (tester) async {
    await _pumpRail(
      tester,
      size: const Size(915, 412),
      axis: Axis.vertical,
      accounts: const [
        PlayAccount(id: 'avd:Main', label: 'Main', word: EmulatorUiWord.live),
        PlayAccount(id: 'avd:Alt-1', label: 'Alt-1', word: EmulatorUiWord.live),
        PlayAccount(
            id: 'avd:Alt-2', label: 'Alt-2', word: EmulatorUiWord.starting),
        PlayAccount(
            id: 'avd:Alt-3-with-a-long-name',
            label: 'Alt-3-with-a-long-name',
            word: EmulatorUiWord.live),
      ],
    );
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Recents'), findsOneWidget);
    expect(tester.getRect(find.byType(PlayRail)).width, kPlayRailSideWidth);
  });

  testWidgets('vertical rail survives a very short viewport', (tester) async {
    await _pumpRail(tester, size: const Size(915, 200), axis: Axis.vertical);
    expect(tester.takeException(), isNull);
  });

  testWidgets('banner widget fades out', (tester) async {
    final controller = NameBannerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: GuestNameBanner(controller: controller)),
      ]),
    ));
    controller.show('Alt-1 · Live');
    await tester.pump();
    expect(find.text('Alt-1 · Live'), findsOneWidget);
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        1);
    expect(find.byType(IgnorePointer), findsWidgets);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
        0);
  });
}
