import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';
import 'package:flutter_hbb/mobile/widgets/mirpg_remote_theme.dart';

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
      expect(video.bottom, controls.top);
      expect(video.height, size.height - 56);
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
      await tester.tapAt(video.topLeft + const Offset(1, 1));
      expect(touches.single, isNull, reason: 'Natural black bars reject input');
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
      controls: GuestTextComposer(
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
}
