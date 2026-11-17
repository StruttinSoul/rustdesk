import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_hbb/models/emulator_model.dart';

void main() {
  test('automatic guest reconnect has a bounded foreground-only retry budget',
      () {
    Duration? attempt(int count,
            {bool failed = true,
            bool liveBefore = true,
            bool ready = true,
            bool foreground = true,
            bool canControl = true}) =>
        guestAutoReconnectDelay(
          sessionFailed: failed,
          guestWasLive: liveBefore,
          emulatorRunning: ready,
          foreground: foreground,
          canControl: canControl,
          attempts: count,
        );
    expect(attempt(0), const Duration(seconds: 1));
    expect(attempt(1), const Duration(seconds: 3));
    expect(attempt(2), isNull);
    expect(attempt(0, failed: false), isNull);
    expect(attempt(0, liveBefore: false), isNull);
    expect(attempt(0, ready: false), isNull);
    expect(attempt(0, foreground: false), isNull);
    expect(attempt(0, canControl: false), isNull);
    expect(
        const RemoteEmulator(
                id: 'x', name: 'x', provider: 'bluestacks', state: 'stopped')
            .readyForReconnect,
        isFalse);
  });
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
          child: GuestControlStage(
            legacyLayout: true,
            controlsVisible: true,
            onToggleControls: () {},
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
          child: GuestControlStage(
            legacyLayout: true,
            controlsVisible: true,
            onToggleControls: () {},
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
            child: GuestControlStage(
              legacyLayout: true,
              controlsVisible: true,
              onToggleControls: () {},
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

  for (final screenHeight in [832.0, 700.0]) {
    testWidgets(
        'dashboard bar under the game keeps touch coordinates at '
        '$screenHeight dp', (tester) async {
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
            child: GuestControlStage(
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
              controls: const SizedBox(key: Key('rail'), height: 48),
            ),
          ),
        ),
      ));

      final viewport = tester.getRect(find.byKey(const Key('touch-surface')));
      expect(viewport.size, Size(384, screenHeight - 48),
          reason: 'The game takes everything the 48 dp bar leaves');
      expect(
          tester.getRect(find.byKey(const Key('rail'))).bottom, screenHeight);
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

      // A 9:16 guest leaves a black bar at the top (tall phone) or at the
      // left (short phone).
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
