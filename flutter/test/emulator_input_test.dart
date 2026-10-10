import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';

void main() {
  testWidgets(
      'portrait guest uses the entire phone width and keeps controls below the frame',
      (tester) async {
    tester.view.physicalSize = const Size(384, 832);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 384,
          height: 832,
          child: PortraitGuestStage(
            guestWidth: 720,
            guestHeight: 1280,
            video: const SizedBox.expand(
              key: Key('portrait-video'),
              child: ColoredBox(color: Colors.black),
            ),
            controls: const SizedBox(
              key: Key('portrait-controls'),
              height: 56,
            ),
          ),
        ),
      ),
    ));

    final frame = containedGuestFrame(
      viewportWidth: 384,
      viewportHeight: 832,
      guestWidth: 720,
      guestHeight: 1280,
    )!;
    expect(frame.width, 384);
    expect(frame.height, closeTo(682.67, 0.01));
    expect(tester.getSize(find.byKey(const Key('portrait-video'))).width, 384);
    expect(
      tester.getRect(find.byKey(const Key('portrait-controls'))).top,
      greaterThanOrEqualTo(832 / 2 + frame.height / 2),
    );
  });

  testWidgets('portrait guest reserves a control row on less tall phones',
      (tester) async {
    tester.view.physicalSize = const Size(384, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(
      home: Center(
        child: SizedBox(
          width: 384,
          height: 700,
          child: PortraitGuestStage(
            guestWidth: 720,
            guestHeight: 1280,
            video: const SizedBox.expand(
              key: Key('portrait-video'),
              child: ColoredBox(color: Colors.black),
            ),
            controls: const SizedBox(
              key: Key('portrait-controls'),
              height: 56,
            ),
          ),
        ),
      ),
    ));
    expect(tester.getSize(find.byKey(const Key('portrait-video'))).width, 384);
    expect(tester.getRect(find.byKey(const Key('portrait-controls'))).top,
        greaterThanOrEqualTo(644));
  });

  for (final screenHeight in [832.0, 700.0]) {
    testWidgets(
        'portrait touch coordinates match the video at $screenHeight dp',
        (tester) async {
      tester.view.physicalSize = Size(384, screenHeight);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final touches = <({int x, int y})?>[];
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: SizedBox(
            width: 384,
            height: screenHeight,
            child: PortraitGuestStage(
              guestWidth: 720,
              guestHeight: 1280,
              video: LayoutBuilder(
                builder: (_, constraints) => Listener(
                  key: const Key('touch-surface'),
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => touches.add(mapEmulatorTouch(
                    localX: event.localPosition.dx,
                    localY: event.localPosition.dy,
                    viewportWidth: constraints.maxWidth,
                    viewportHeight: constraints.maxHeight,
                    guestWidth: 720,
                    guestHeight: 1280,
                  )),
                  child: const ColoredBox(color: Colors.black),
                ),
              ),
              controls: const SizedBox(height: 56),
            ),
          ),
        ),
      ));

      final viewport = tester.getRect(find.byKey(const Key('touch-surface')));
      final frame = containedGuestFrame(
        viewportWidth: viewport.width,
        viewportHeight: viewport.height,
        guestWidth: 720,
        guestHeight: 1280,
      )!;
      await tester.tapAt(viewport.topLeft +
          Offset(frame.left + frame.width / 2, frame.top + frame.height / 2));
      expect(touches.single, (x: 360, y: 640));

      touches.clear();
      await tester.tapAt(viewport.topLeft +
          Offset(frame.left + frame.width / 4, frame.top + frame.height / 4));
      expect(touches.single, (x: 180, y: 320));

      touches.clear();
      await tester.tapAt(viewport.topLeft +
          (screenHeight == 832 ? const Offset(192, 1) : const Offset(1, 322)));
      expect(touches.single, isNull,
          reason: 'Black bars must not inject guest input');
    });
  }

  test('composing_then_switch_cancels', () {
    expect(
      shouldCancelGuestComposition(
        previousSessionId: 42,
        previousTargetId: 'bluestacks:one',
        currentSessionId: 43,
        currentTargetId: 'bluestacks:one',
      ),
      isTrue,
    );
    expect(
      shouldCancelGuestComposition(
        previousSessionId: 42,
        previousTargetId: 'bluestacks:one',
        currentSessionId: 42,
        currentTargetId: 'bluestacks:two',
      ),
      isTrue,
    );
    expect(
      shouldCancelGuestComposition(
        previousSessionId: 42,
        previousTargetId: 'bluestacks:one',
        currentSessionId: 42,
        currentTargetId: 'bluestacks:one',
      ),
      isFalse,
    );
    expect(
      shouldCancelGuestComposition(
        previousSessionId: 0,
        previousTargetId: '',
        currentSessionId: 42,
        currentTargetId: 'bluestacks:one',
      ),
      isFalse,
    );
  });
}
