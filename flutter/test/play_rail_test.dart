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

Future<void> _pumpBar(
  WidgetTester tester, {
  required Size size,
  Axis axis = Axis.horizontal,
  List<String>? nav,
  bool navigable = true,
  VoidCallback? onMenu,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(
      backgroundColor: Colors.grey,
      body: Align(
        alignment: axis == Axis.horizontal
            ? Alignment.bottomCenter
            : Alignment.centerRight,
        child: PlayNavBar(
          axis: axis,
          onNavigate: navigable ? (action) => nav?.add(action) : null,
          onMenu: onMenu ?? () {},
          tr: fakeTr,
        ),
      ),
    ),
  ));
}

/// The whole button (its touch target) for a tooltip.
Rect _button(WidgetTester tester, String tooltip) => tester.getRect(find
    .ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton))
    .first);

/// A page with one button that opens the menu, as the game does.
Future<void> _openMenu(
  WidgetTester tester, {
  List<PlayAccount> accounts = _accounts,
  bool switching = false,
  List<String>? selected,
  VoidCallback? onAll,
  VoidCallback? onGrid,
  VoidCallback? onActions,
  VoidCallback? onType,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: MirpgRemoteTheme.build(ThemeData.dark()),
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => showPlayMenu(
            context,
            accounts: accounts,
            currentId: 'avd:Main',
            switching: switching,
            onSelect: (id) => selected?.add(id),
            onShowAll: onAll,
            onGrid: onGrid ?? () {},
            onCurrentActions: onActions,
            onType: onType,
            tr: fakeTr,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
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

  group('PlayNavBar', () {
    testWidgets('portrait: a 48 dp bar, full width, at the bottom',
        (tester) async {
      await _pumpBar(tester, size: const Size(412, 915));
      final bar = tester.getRect(find.byType(PlayNavBar));
      expect(bar.height, kPlayNavBarThickness);
      expect(bar.width, 412);
      expect(bar.bottom, 915);
      expect(
          tester.widget<Material>(find.descendant(
              of: find.byType(PlayNavBar), matching: find.byType(Material))
              .first).color,
          const Color(0xFF000000),
          reason: 'Near black like the system navigation bar');
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('Back, Home and Recents send the same keys as before',
        (tester) async {
      final nav = <String>[];
      await _pumpBar(tester, size: const Size(412, 915), nav: nav);
      for (final key in ['Back', 'Home', 'Recents']) {
        await tester.tap(find.byTooltip(key));
        await tester.pump();
      }
      expect(nav, ['back', 'home', 'recents']);
    });

    testWidgets('keys are evenly spaced and every target is 48 dp',
        (tester) async {
      await _pumpBar(tester, size: const Size(412, 915));
      final back = _button(tester, 'Back');
      final home = _button(tester, 'Home');
      final recents = _button(tester, 'Recents');
      final more = _button(tester, 'More');
      expect(back.center.dx, lessThan(home.center.dx));
      expect(home.center.dx, lessThan(recents.center.dx));
      expect(recents.center.dx, lessThan(more.center.dx));
      expect(home.center.dx - back.center.dx,
          closeTo(recents.center.dx - home.center.dx, 0.5));
      expect(more.right, closeTo(412, 0.5),
          reason: 'The menu icon is at the far right');
      for (final rect in [back, home, recents, more]) {
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('the menu icon opens the menu', (tester) async {
      var menus = 0;
      await _pumpBar(tester,
          size: const Size(412, 915), onMenu: () => menus++);
      await tester.tap(find.byTooltip('More'));
      expect(menus, 1);
    });

    testWidgets('keys are disabled without navigation, the menu stays',
        (tester) async {
      var menus = 0;
      await _pumpBar(tester,
          size: const Size(412, 915),
          navigable: false,
          onMenu: () => menus++);
      for (final key in ['Back', 'Home', 'Recents']) {
        final button = tester.widget<IconButton>(find.ancestor(
            of: find.byTooltip(key), matching: find.byType(IconButton)));
        expect(button.onPressed, isNull, reason: key);
      }
      await tester.tap(find.byTooltip('More'));
      expect(menus, 1);
    });

    testWidgets('landscape: a 48 dp strip on the right with icons stacked',
        (tester) async {
      final nav = <String>[];
      await _pumpBar(tester,
          size: const Size(915, 412), axis: Axis.vertical, nav: nav);
      final bar = tester.getRect(find.byType(PlayNavBar));
      expect(bar.width, kPlayNavBarThickness);
      expect(bar.height, 412);
      expect(bar.right, 915);
      final back = _button(tester, 'Back');
      final home = _button(tester, 'Home');
      final recents = _button(tester, 'Recents');
      final more = _button(tester, 'More');
      for (final rect in [back, home, recents, more]) {
        expect(rect.center.dx, closeTo(915 - 24, 0.5));
        expect(rect.width, greaterThanOrEqualTo(48));
      }
      // Android stacks them Recents, Home, Back from the top.
      expect(more.center.dy, lessThan(recents.center.dy));
      expect(recents.center.dy, lessThan(home.center.dy));
      expect(home.center.dy, lessThan(back.center.dy));
      await tester.tap(find.byTooltip('Back'));
      await tester.tap(find.byTooltip('Home'));
      await tester.tap(find.byTooltip('Recents'));
      expect(nav, ['back', 'home', 'recents']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a very short landscape screen does not overflow',
        (tester) async {
      await _pumpBar(tester, size: const Size(915, 200), axis: Axis.vertical);
      expect(tester.takeException(), isNull);
    });
  });

  group('showPlayMenu', () {
    testWidgets('holds the switcher, keyboard, grid and emulator actions',
        (tester) async {
      await _openMenu(tester,
          onAll: () {}, onType: () {}, onActions: () {});
      for (final name in ['Main', 'Alt-1', 'Alt-2']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.byTooltip('Show all emulators'), findsOneWidget);
      expect(find.text('Type text'), findsOneWidget);
      expect(find.text('Emulators'), findsOneWidget);
      expect(find.text('More Main actions'), findsOneWidget);
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('chips follow grid order and mark the current emulator',
        (tester) async {
      final selected = <String>[];
      await _openMenu(tester, selected: selected);
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
      // The current chip does nothing and leaves the menu open.
      await tester.tap(find.text('Main'));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(find.text('Alt-1'), findsOneWidget);
      // Another chip switches and closes the menu.
      await tester.tap(find.text('Alt-1'));
      await tester.pumpAndSettle();
      expect(selected, ['avd:Alt-1']);
      expect(find.text('Alt-2'), findsNothing);
    });

    testWidgets('chips are disabled while a switch is connecting',
        (tester) async {
      final selected = <String>[];
      await _openMenu(tester, selected: selected, switching: true);
      await tester.tap(find.text('Alt-1'));
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
    });

    testWidgets('chip touch targets are 48 dp', (tester) async {
      await _openMenu(tester);
      final chip = tester.getRect(find
          .ancestor(of: find.text('Alt-1'), matching: find.byType(InkWell))
          .first);
      expect(chip.height, greaterThanOrEqualTo(48));
    });

    testWidgets('each row closes the menu and runs its action',
        (tester) async {
      var all = 0, grid = 0, actions = 0, typed = 0;
      Future<void> open() => _openMenu(tester,
          onAll: () => all++,
          onGrid: () => grid++,
          onActions: () => actions++,
          onType: () => typed++);

      await open();
      await tester.tap(find.byTooltip('Show all emulators'));
      await tester.pumpAndSettle();
      expect((all, find.text('Type text').evaluate().length), (1, 0));

      await open();
      await tester.tap(find.text('Type text'));
      await tester.pumpAndSettle();
      expect(typed, 1);

      await open();
      await tester.tap(find.text('Emulators'));
      await tester.pumpAndSettle();
      expect(grid, 1);

      await open();
      await tester.tap(find.text('More Main actions'));
      await tester.pumpAndSettle();
      expect(actions, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keyboard row is disabled when typing is unavailable',
        (tester) async {
      await _openMenu(tester);
      final tile = tester.widget<ListTile>(
          find.ancestor(of: find.text('Type text'), matching: find.byType(ListTile)));
      expect(tile.enabled, isFalse);
      expect(find.text('More Main actions'), findsNothing,
          reason: 'No actions row without a callback');
    });
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
