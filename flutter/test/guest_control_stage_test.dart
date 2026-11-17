import 'package:flutter/gestures.dart' show kDoubleTapMinTime, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';
import 'package:flutter_hbb/mobile/widgets/play_rail.dart';

import 'support/fake_translate.dart';

Finder controlButton(String tooltip) => find
    .ancestor(of: find.byTooltip(tooltip), matching: find.byType(IconButton))
    .first;

void main() {
  for (final size in [const Size(384, 832), const Size(832, 384)]) {
    testWidgets('phone-shaped guest fills $size with movable controls',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var visible = false;
      var toggles = 0;
      var homeActions = 0;
      final touches = <({int x, int y})?>[];
      final width = size.width > size.height ? 2340 : 1080;
      final height = size.width > size.height ? 1080 : 2340;
      await tester.pumpWidget(
          MaterialApp(home: StatefulBuilder(builder: (context, setState) {
        return GuestControlStage(
          controlsVisible: visible,
          onToggleControls: () => setState(() {
            visible = !visible;
            toggles++;
          }),
          video: LayoutBuilder(
              builder: (_, box) => Listener(
                    key: const Key('video'),
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) => touches.add(mapEmulatorTouch(
                      localX: event.localPosition.dx,
                      localY: event.localPosition.dy,
                      viewportWidth: box.maxWidth,
                      viewportHeight: box.maxHeight,
                      guestWidth: width,
                      guestHeight: height,
                    )),
                    child: const ColoredBox(color: Colors.black),
                  )),
          controls: SizedBox(
              key: const Key('controls'),
              height: 56,
              child: Center(
                  child: IconButton(
                      tooltip: 'Guest Home',
                      onPressed: () => homeActions++,
                      icon: const Icon(Icons.home_outlined)))),
        );
      })));
      expect(tester.getSize(find.byKey(const Key('video'))), size,
          reason: 'Matching guest aspect ratio needs the whole viewport');
      expect(find.byKey(const Key('controls')), findsNothing);
      expect(
          tester.getSize(controlButton('Show controls')), const Size(48, 48));
      await tester.tap(controlButton('Show controls'));
      await tester.pump();
      expect(toggles, 1);
      expect(touches, isEmpty,
          reason: 'Opening controls must not touch the guest');
      var video = tester.getRect(find.byKey(const Key('video')));
      final controls = tester.getRect(find.byKey(const Key('controls')));
      expect(video.size, size,
          reason: 'The collapsed rail opens over the game, never shrinking it');
      expect(controls.bottom, size.height);
      await tester.tap(find.byTooltip('Guest Home'));
      expect(homeActions, 1);
      expect(touches, isEmpty);
      final frame = containedGuestFrame(
          viewportWidth: video.width,
          viewportHeight: video.height,
          guestWidth: width,
          guestHeight: height)!;
      await tester.tapAt(video.topLeft +
          Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
      expect(touches.single?.x, closeTo(width / 2, 1));
      expect(touches.single?.y, closeTo(height / 2, 1));
      touches.clear();
      // The guest has the viewport's exact shape, so no black bars remain:
      // the top-left corner maps to the guest's top-left corner. Black-bar
      // rejection is covered by the docked test below.
      await tester.tapAt(video.topLeft + const Offset(1, 1));
      expect(touches.single?.x, lessThanOrEqualTo(3));
      expect(touches.single?.y, lessThanOrEqualTo(3));
      touches.clear();
      final before = tester.getRect(controlButton('Hide controls'));
      await tester.drag(
          controlButton('Hide controls'), const Offset(-170, -90));
      await tester.pump();
      final moved = tester.getRect(controlButton('Hide controls'));
      expect(moved.left, lessThan(before.left - 100));
      expect(moved.top, greaterThanOrEqualTo(8));
      expect(toggles, 1, reason: 'Dragging must not toggle the tray');
      expect(touches, isEmpty,
          reason: 'Dragging must not inject guest touches');
      await tester.tap(controlButton('Hide controls'));
      await tester.pump();
      expect(find.byKey(const Key('controls')), findsNothing);
      video = tester.getRect(find.byKey(const Key('video')));
      expect(video.size, size);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('control stays reachable after rotation and keyboard resize',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> resize(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: GuestControlStage(
        key: const Key('stage'),
        video: const ColoredBox(color: Colors.black),
        controls: const SizedBox(height: 56),
        controlsVisible: true,
        onToggleControls: () {},
      )));
      final button = tester.getRect(controlButton('Hide controls'));
      expect(button.left, greaterThanOrEqualTo(8));
      expect(button.top, greaterThanOrEqualTo(8));
      expect(button.right, lessThanOrEqualTo(size.width - 8));
      expect(button.bottom, lessThanOrEqualTo(size.height - 56 - 8));
      expect(tester.takeException(), isNull);
    }

    await resize(const Size(384, 832));
    await tester.drag(controlButton('Hide controls'), const Offset(5000, 5000));
    await tester.pump();
    await resize(const Size(832, 384));
    await resize(const Size(384, 280));
  });
  testWidgets('landscape IME keeps guest visible above compact composer',
      (tester) async {
    tester.view.physicalSize = const Size(832, 104);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    var closed = false;
    await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(ThemeData.dark()),
        home: Scaffold(body: GuestControlStage(
      video: const ColoredBox(key: Key('video'), color: Colors.black),
      controlsVisible: true,
      onToggleControls: () {},
      controls: const SizedBox(height: 56),
      composer: GuestTextComposer(
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) {},
        onSend: () {},
        onClose: () => closed = true,
      ),
    ))));
    final video = tester.getRect(find.byKey(const Key('video')));
    final composer = tester.getRect(find.byType(GuestTextComposer));
    expect(video.height, greaterThanOrEqualTo(48),
        reason: 'Samsung landscape keyboard must leave a visible guest image');
    expect(video.bottom, composer.top);
    expect(composer.bottom, lessThanOrEqualTo(104));
    expect(find.byTooltip('Hide controls'), findsNothing,
        reason:
            'Use the composer close button when the video is too short for a bubble');
    await tester.enterText(find.byType(TextField), 'mirpg-fit-check');
    expect(controller.text, 'mirpg-fit-check');
    await tester.tap(find.byTooltip('Close keyboard'));
    expect(closed, isTrue);
    expect(tester.takeException(), isNull);
  });

  Widget guestVideo(List<({int x, int y})?> touches, int width, int height) =>
      LayoutBuilder(
          builder: (_, box) => Listener(
                key: const Key('video'),
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) => touches.add(mapEmulatorTouch(
                  localX: event.localPosition.dx,
                  localY: event.localPosition.dy,
                  viewportWidth: box.maxWidth,
                  viewportHeight: box.maxHeight,
                  guestWidth: width,
                  guestHeight: height,
                )),
                child: const ColoredBox(color: Colors.black),
              ));

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('docked bottom rail sits under the video without a toggle button',
      (tester) async {
    const size = Size(412, 915);
    await setSize(tester, size);
    final touches = <({int x, int y})?>[];
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      placement: PlayRailPlacement.bottom,
      controlsVisible: false,
      onToggleControls: () {},
      video: guestVideo(touches, 1080, 1920),
      controls: const ColoredBox(key: Key('controls'), color: Colors.black),
    )));
    final video = tester.getRect(find.byKey(const Key('video')));
    final controls = tester.getRect(find.byKey(const Key('controls')));
    expect(video.bottom, controls.top);
    expect(controls.height, 88);
    expect(controls.bottom, size.height);
    expect(find.byTooltip('Show controls'), findsNothing);
    expect(find.byTooltip('Hide controls'), findsNothing);
    final frame = containedGuestFrame(
        viewportWidth: video.width,
        viewportHeight: video.height,
        guestWidth: 1080,
        guestHeight: 1920)!;
    expect(frame.height, closeTo(732.4, 0.1),
        reason: 'The docked rail sits in the letterbox; the game keeps its size');
    await tester.tapAt(video.topLeft +
        Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
    expect(touches.single?.x, closeTo(540, 1));
    expect(touches.single?.y, closeTo(960, 1));
    touches.clear();
    await tester.tapAt(video.topLeft + const Offset(1, 1));
    expect(touches.single, isNull, reason: 'Natural black bars reject input');
    touches.clear();
    await tester.tapAt(controls.center);
    expect(touches, isEmpty, reason: 'The rail never touches the guest');
    expect(tester.takeException(), isNull);
  });

  testWidgets('side rail sits beside the video', (tester) async {
    const size = Size(915, 412);
    await setSize(tester, size);
    final touches = <({int x, int y})?>[];
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      placement: PlayRailPlacement.side,
      controlsVisible: false,
      onToggleControls: () {},
      video: guestVideo(touches, 1920, 1080),
      controls: const ColoredBox(key: Key('controls'), color: Colors.black),
    )));
    final video = tester.getRect(find.byKey(const Key('video')));
    final controls = tester.getRect(find.byKey(const Key('controls')));
    expect(video.right, controls.left);
    expect(controls.width, 72);
    expect(controls.height, size.height);
    expect(find.byTooltip('Show controls'), findsNothing);
    final frame = containedGuestFrame(
        viewportWidth: video.width,
        viewportHeight: video.height,
        guestWidth: 1920,
        guestHeight: 1080)!;
    expect(frame.width, closeTo(732.4, 0.1));
    await tester.tapAt(video.topLeft +
        Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
    expect(touches.single?.x, closeTo(960, 1));
    expect(touches.single?.y, closeTo(540, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('double tap on the round button jumps without toggling',
      (tester) async {
    await setSize(tester, const Size(915, 412));
    var toggles = 0;
    var doubles = 0;
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      controlsVisible: false,
      onToggleControls: () => toggles++,
      onDoubleTapToggle: () => doubles++,
      video: const ColoredBox(color: Colors.black),
      controls: const SizedBox(height: 88),
    )));
    await tester.tap(controlButton('Show controls'));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(controlButton('Show controls'));
    await tester.pumpAndSettle();
    expect(doubles, 1);
    expect(toggles, 0);
    await tester.tap(controlButton('Show controls'));
    await tester.pump(kDoubleTapTimeout);
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(doubles, 1);
  });

  for (final size in [const Size(412, 915), const Size(915, 412)]) {
    testWidgets(
        'expanded rail over the game keeps rail and game touches apart '
        'at $size', (tester) async {
      await setSize(tester, size);
      final touches = <({int x, int y})?>[];
      final selected = <String>[];
      final width = size.width > size.height ? 2400 : 1080;
      final height = size.width > size.height ? 1080 : 2400;
      await tester.pumpWidget(MaterialApp(
          home: GuestControlStage(
        controlsVisible: true,
        onToggleControls: () {},
        video: guestVideo(touches, width, height),
        controls: PlayRail(
          accounts: const [
            PlayAccount(id: 'a', label: 'Main', word: EmulatorUiWord.live),
            PlayAccount(id: 'b', label: 'Alt-1', word: EmulatorUiWord.live),
          ],
          currentId: 'a',
          axis: Axis.horizontal,
          onSelect: selected.add,
          onGrid: () {},
          tr: fakeTr,
        ),
      )));
      final video = tester.getRect(find.byKey(const Key('video')));
      final rail = tester.getRect(find.byType(PlayRail));
      expect(video.size, size, reason: 'The overlay never shrinks the game');
      expect(rail.height, 88);
      expect(rail.bottom, size.height);
      // Empty rail space (between the keyboard and Back keys, and beside the
      // chips) is still rail.
      await tester.tapAt(Offset(rail.center.dx, rail.bottom - 24));
      await tester.tapAt(Offset(rail.right - 70, rail.top + 20));
      expect(touches, isEmpty, reason: 'Rail touches must not reach the game');
      await tester.tap(find.text('Alt-1'));
      expect(selected, ['b']);
      expect(touches, isEmpty);
      await tester.tapAt(Offset(video.center.dx, rail.top - 24));
      expect(touches, hasLength(1), reason: 'The game above the rail is live');
      expect(selected, ['b']);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(384, 832), const Size(832, 384)]) {
    testWidgets('fallback page keeps its row below the video at $size',
        (tester) async {
      await setSize(tester, size);
      var visible = false;
      final touches = <({int x, int y})?>[];
      final width = size.width > size.height ? 2340 : 1080;
      final height = size.width > size.height ? 1080 : 2340;
      await tester.pumpWidget(
          MaterialApp(home: StatefulBuilder(builder: (context, setState) {
        return GuestControlStage(
          legacyLayout: true,
          controlsVisible: visible,
          onToggleControls: () => setState(() => visible = !visible),
          video: guestVideo(touches, width, height),
          controls: const SizedBox(key: Key('controls'), height: 56),
        );
      })));
      expect(tester.getSize(find.byKey(const Key('video'))), size);
      await tester.tap(controlButton('Show controls'));
      await tester.pump();
      final video = tester.getRect(find.byKey(const Key('video')));
      final controls = tester.getRect(find.byKey(const Key('controls')));
      expect(video.bottom, controls.top);
      expect(video.height, size.height - 56);
      final frame = containedGuestFrame(
          viewportWidth: video.width,
          viewportHeight: video.height,
          guestWidth: width,
          guestHeight: height)!;
      await tester.tapAt(video.topLeft +
          Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
      expect(touches.single?.x, closeTo(width / 2, 1));
      expect(touches.single?.y, closeTo(height / 2, 1));
      touches.clear();
      await tester.tapAt(video.topLeft + const Offset(1, 1));
      expect(touches.single, isNull, reason: 'Natural black bars reject input');
      expect(find.byKey(const Key('controls')), findsOneWidget,
          reason: 'Only the round button hides the fallback row');
      expect(tester.takeException(), isNull);
    });
  }
}
