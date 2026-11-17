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
  testWidgets('fallback page: the round button stays reachable after rotation and keyboard resize',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Future<void> resize(Size size) async {
      tester.view.physicalSize = size;
      await tester.pumpWidget(MaterialApp(
          home: GuestControlStage(
        key: const Key('stage'),
        legacyLayout: true,
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

  testWidgets('portrait: the bar is 48 dp at the bottom and the game takes the rest',
      (tester) async {
    const size = Size(412, 915);
    await setSize(tester, size);
    final touches = <({int x, int y})?>[];
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      video: guestVideo(touches, 1080, 1920),
      controls: const ColoredBox(key: Key('controls'), color: Colors.black),
    )));
    final video = tester.getRect(find.byKey(const Key('video')));
    final controls = tester.getRect(find.byKey(const Key('controls')));
    expect(controls.height, kPlayNavBarThickness);
    expect(controls.width, size.width);
    expect(controls.bottom, size.height);
    expect(video.bottom, controls.top, reason: 'The bar never covers the game');
    expect(video.size, Size(size.width, size.height - 48),
        reason: 'No letterbox is reserved beyond the bar itself');
    expect(find.byTooltip('Show controls'), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    // The picture: the largest 9:16 frame in the area above the bar, centred.
    final frame = containedGuestFrame(
        viewportWidth: video.width,
        viewportHeight: video.height,
        guestWidth: 1080,
        guestHeight: 1920)!;
    expect(frame.width / frame.height, closeTo(1080 / 1920, 1e-6));
    expect(frame.width, closeTo(video.width, 1e-6),
        reason: 'A 9:16 game on this phone is width-bound: the largest frame');
    expect(frame.height, lessThanOrEqualTo(video.height));
    expect(frame.left, closeTo((video.width - frame.width) / 2, 1e-6));
    expect(frame.top + frame.height, lessThanOrEqualTo(video.height + 1e-6));
    await tester.tapAt(video.topLeft +
        Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
    expect(touches.single?.x, closeTo(540, 1));
    expect(touches.single?.y, closeTo(960, 1));
    touches.clear();
    await tester.tapAt(video.topLeft + const Offset(1, 1));
    expect(touches.single, isNull, reason: 'Natural black bars reject input');
    touches.clear();
    await tester.tapAt(controls.center);
    expect(touches, isEmpty, reason: 'The bar never touches the guest');
    expect(tester.takeException(), isNull);
  });

  testWidgets('landscape: the bar is a 48 dp strip on the right',
      (tester) async {
    const size = Size(915, 412);
    await setSize(tester, size);
    final touches = <({int x, int y})?>[];
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      barAxis: Axis.vertical,
      video: guestVideo(touches, 1920, 1080),
      controls: const ColoredBox(key: Key('controls'), color: Colors.black),
    )));
    final video = tester.getRect(find.byKey(const Key('video')));
    final controls = tester.getRect(find.byKey(const Key('controls')));
    expect(controls.width, kPlayNavBarThickness);
    expect(controls.height, size.height);
    expect(controls.right, size.width);
    expect(video.right, controls.left);
    expect(video.size, Size(size.width - 48, size.height));
    final frame = containedGuestFrame(
        viewportWidth: video.width,
        viewportHeight: video.height,
        guestWidth: 1920,
        guestHeight: 1080)!;
    expect(frame.width / frame.height, closeTo(16 / 9, 1e-6));
    expect(frame.height, closeTo(video.height, 1e-6));
    await tester.tapAt(video.topLeft +
        Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
    expect(touches.single?.x, closeTo(960, 1));
    expect(touches.single?.y, closeTo(540, 1));
    touches.clear();
    await tester.tapAt(controls.center);
    expect(touches, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a game wider than the phone is contained, never cropped',
      (tester) async {
    const size = Size(915, 412);
    await setSize(tester, size);
    final touches = <({int x, int y})?>[];
    await tester.pumpWidget(MaterialApp(
        home: GuestControlStage(
      barAxis: Axis.vertical,
      video: guestVideo(touches, 2400, 1080),
      controls: const ColoredBox(key: Key('controls'), color: Colors.black),
    )));
    final video = tester.getRect(find.byKey(const Key('video')));
    final frame = containedGuestFrame(
        viewportWidth: video.width,
        viewportHeight: video.height,
        guestWidth: 2400,
        guestHeight: 1080)!;
    expect(frame.width, lessThanOrEqualTo(video.width + 1e-6));
    expect(frame.height, lessThanOrEqualTo(video.height + 1e-6));
    expect(frame.width / frame.height, closeTo(2400 / 1080, 1e-6));
    // The corners of the picture map to the corners of the game.
    await tester.tapAt(video.topLeft + Offset(frame.left + 1, frame.top + 1));
    expect(touches.single?.x, lessThanOrEqualTo(5));
    expect(touches.single?.y, lessThanOrEqualTo(5));
  });

  testWidgets('the composer replaces the bar under the game', (tester) async {
    const size = Size(412, 915);
    await setSize(tester, size);
    final controller = TextEditingController();
    final focus = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(focus.dispose);
    await tester.pumpWidget(MaterialApp(
        theme: MirpgRemoteTheme.build(ThemeData.dark()),
        home: Scaffold(
            body: GuestControlStage(
          video: guestVideo(<({int x, int y})?>[], 1080, 1920),
          controls: const ColoredBox(key: Key('controls'), color: Colors.black),
          composer: GuestTextComposer(
            controller: controller,
            focusNode: focus,
            onSubmitted: (_) {},
            onSend: () {},
            onClose: () {},
          ),
        ))));
    expect(find.byKey(const Key('controls')), findsNothing);
    final video = tester.getRect(find.byKey(const Key('video')));
    final composer = tester.getRect(find.byType(GuestTextComposer));
    expect(video.bottom, composer.top);
    expect(composer.bottom, lessThanOrEqualTo(size.height));
  });

  testWidgets('the real bar keeps bar and game touches apart in both places',
      (tester) async {
    for (final (size, axis, gw, gh) in [
      (const Size(412, 915), Axis.horizontal, 1080, 2400),
      (const Size(915, 412), Axis.vertical, 2400, 1080),
    ]) {
      await setSize(tester, size);
      final touches = <({int x, int y})?>[];
      final nav = <String>[];
      var menus = 0;
      await tester.pumpWidget(MaterialApp(
          home: GuestControlStage(
        barAxis: axis,
        video: guestVideo(touches, gw, gh),
        controls: PlayNavBar(
          axis: axis,
          onNavigate: nav.add,
          onMenu: () => menus++,
          tr: fakeTr,
        ),
      )));
      final video = tester.getRect(find.byKey(const Key('video')));
      expect(video.size,
          axis == Axis.horizontal ? Size(size.width, size.height - 48) : Size(size.width - 48, size.height));
      // Gaps between the keys are still the bar.
      final back = tester.getRect(find.byTooltip('Back'));
      final home = tester.getRect(find.byTooltip('Home'));
      await tester.tapAt(Offset(
          (back.center.dx + home.center.dx) / 2,
          (back.center.dy + home.center.dy) / 2));
      expect(touches, isEmpty, reason: 'Bar touches must not reach the game');
      await tester.tap(find.byTooltip('Home'));
      await tester.tap(find.byTooltip('More'));
      expect(nav, ['home']);
      expect(menus, 1);
      expect(touches, isEmpty);
      await tester.tapAt(video.center);
      expect(touches, hasLength(1), reason: 'The game is live above the bar');
      expect(tester.takeException(), isNull);
    }
  });

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
