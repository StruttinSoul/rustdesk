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
    // 9:16 guest, width 412: frame height 732.4. A docked bottom rail needs
    // 88 dp of spare height; docking from collapsed needs 88 + 16.
    PlayRailPlacement at(double height, [PlayRailPlacement? previous]) =>
        playRailPlacement(
            viewport: Size(412, height),
            guestWidth: 1080,
            guestHeight: 1920,
            previous: previous);
    expect(at(837), PlayRailPlacement.bottom, reason: '104.6 dp spare docks');
    expect(at(821), PlayRailPlacement.collapsed,
        reason: '88.6 dp fits but is inside the docking margin');
    expect(at(821, PlayRailPlacement.bottom), PlayRailPlacement.bottom,
        reason: 'A docked rail stays while it still fits');
    // Spec 3.3 over the plan's pinned value: a docked rail never shrinks the
    // game, so 77.6 dp spare collapses even when it was docked.
    expect(at(810, PlayRailPlacement.bottom), isNot(PlayRailPlacement.bottom));
    expect(at(810), isNot(PlayRailPlacement.bottom));
    expect(at(800, PlayRailPlacement.bottom), isNot(PlayRailPlacement.bottom));
  });
  test('1 to 15 dp jitter (system bars, insets) never flips the rail', () {
    for (var d = 1; d <= 15; d++) {
      // Docked at 104.6 dp spare: losing up to 15 dp still holds 88.
      expect(
          playRailPlacement(
              viewport: Size(412, 837.0 - d),
              guestWidth: 1080,
              guestHeight: 1920,
              previous: PlayRailPlacement.bottom),
          PlayRailPlacement.bottom,
          reason: 'bottom loses $d dp');
      // Side: 821 dp wide leaves 88.6 dp beside a 16:9 game (docks); losing
      // up to 15 dp still holds the 72 dp rail.
      expect(
          playRailPlacement(
              viewport: Size(821.0 - d, 412),
              guestWidth: 1920,
              guestHeight: 1080,
              previous: PlayRailPlacement.side),
          PlayRailPlacement.side,
          reason: 'side loses $d dp');
      // Collapsed just at the docked minimum: gaining up to 15 dp does not
      // dock it.
      expect(
          playRailPlacement(
              viewport: Size(412, 821.0 + d),
              guestWidth: 1080,
              guestHeight: 1920,
              previous: PlayRailPlacement.collapsed),
          PlayRailPlacement.collapsed,
          reason: 'bottom gains $d dp');
      expect(
          playRailPlacement(
              viewport: Size(805.0 + d, 412),
              guestWidth: 1920,
              guestHeight: 1080,
              previous: PlayRailPlacement.collapsed),
          PlayRailPlacement.collapsed,
          reason: 'side gains $d dp');
    }
  });
  test('a docked rail never leaves the video smaller than the game', () {
    for (final previous in [
      null,
      PlayRailPlacement.bottom,
      PlayRailPlacement.side,
      PlayRailPlacement.collapsed,
    ]) {
      for (var size = 600.0; size <= 1100; size += 1) {
        for (final (viewport, gw, gh) in [
          (Size(412, size), 1080, 1920),
          (Size(size, 412), 1920, 1080),
          (Size(size, 412), 1080, 1920),
          (Size(412, size), 1920, 1080),
        ]) {
          final placement = playRailPlacement(
              viewport: viewport,
              guestWidth: gw,
              guestHeight: gh,
              previous: previous);
          final game = containedGuestFrame(
              viewportWidth: viewport.width,
              viewportHeight: viewport.height,
              guestWidth: gw,
              guestHeight: gh)!;
          final video = switch (placement) {
            PlayRailPlacement.bottom =>
              Size(viewport.width, viewport.height - kPlayRailBottomHeight),
            PlayRailPlacement.side =>
              Size(viewport.width - kPlayRailSideWidth, viewport.height),
            PlayRailPlacement.collapsed => viewport,
          };
          final shown = containedGuestFrame(
              viewportWidth: video.width,
              viewportHeight: video.height,
              guestWidth: gw,
              guestHeight: gh)!;
          expect(shown.width, closeTo(game.width, 1e-6),
              reason: '$viewport $gw×$gh after $previous: $placement');
          expect(shown.height, closeTo(game.height, 1e-6),
              reason: '$viewport $gw×$gh after $previous: $placement');
        }
      }
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
