import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/widgets/monitor_session_continuity.dart';

void main() {
  final base = DateTime(2026, 10, 5, 12);

  MonitorSessionLiveness liveMonitor({
    int generation = 1,
    String target = 'monitor:0',
  }) {
    final liveness = MonitorSessionLiveness();
    liveness.begin(
      generation: generation,
      targetIdentity: target,
      requireStreamHeartbeat: true,
    );
    expect(
      liveness.noteTransportHeartbeat(generation: generation, at: base),
      isTrue,
    );
    expect(
      liveness.noteStreamHeartbeat(
        generation: generation,
        targetIdentity: target,
        at: base,
      ),
      isTrue,
    );
    expect(
      liveness.noteDecoderHealth(
        generation: generation,
        targetIdentity: target,
        healthy: true,
        at: base,
      ),
      isTrue,
    );
    expect(
      liveness.noteFrame(
        generation: generation,
        targetIdentity: target,
        at: base,
      ),
      isTrue,
    );
    return liveness;
  }

  test('static_desktop_heartbeat_stays_usable', () {
    final liveness = liveMonitor();
    final muchLater = base.add(const Duration(seconds: 30));

    expect(
      liveness.noteTransportHeartbeat(generation: 1, at: muchLater),
      isTrue,
    );
    expect(
      liveness.noteStreamHeartbeat(
        generation: 1,
        targetIdentity: 'monitor:0',
        at: muchLater,
      ),
      isTrue,
    );

    expect(liveness.frameAge(muchLater), const Duration(seconds: 30));
    expect(liveness.canSendInput(muchLater), isTrue,
        reason: 'A static screen can have an old frame while the video service '
            'and transport are both still alive.');
  });

  test('one_frame_then_dead_stream_blocks_input', () {
    final liveness = liveMonitor();
    final later = base.add(const Duration(seconds: 5));

    expect(
      liveness.noteTransportHeartbeat(generation: 1, at: later),
      isTrue,
    );

    expect(liveness.canSendInput(later), isFalse);
    expect(liveness.blockReason(later), MonitorInputBlockReason.streamStale);
  });

  test('old_peer_does_not_require_stream_heartbeat', () {
    final liveness = MonitorSessionLiveness();
    liveness.begin(
      generation: 1,
      targetIdentity: 'monitor:0',
      requireStreamHeartbeat: false,
    );
    liveness.noteTransportHeartbeat(generation: 1, at: base);
    liveness.noteDecoderHealth(
      generation: 1,
      targetIdentity: 'monitor:0',
      healthy: true,
      at: base,
    );
    liveness.noteFrame(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: base,
    );

    expect(liveness.canSendInput(base), isTrue);
  });

  test('old_peer_still_requires_known_healthy_decoder', () {
    final liveness = MonitorSessionLiveness();
    liveness.begin(
      generation: 1,
      targetIdentity: 'monitor:0',
      requireStreamHeartbeat: false,
    );
    liveness.noteTransportHeartbeat(generation: 1, at: base);
    liveness.noteFrame(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: base,
    );

    expect(liveness.canSendInput(base), isFalse);
    expect(
      liveness.blockReason(base),
      MonitorInputBlockReason.decoderNotReady,
    );
  });

  test('first_current_frame_requires_a_follow_up_stream_heartbeat', () {
    final liveness = MonitorSessionLiveness();
    liveness.begin(
      generation: 1,
      targetIdentity: 'monitor:0',
      requireStreamHeartbeat: true,
    );
    liveness.noteTransportHeartbeat(generation: 1, at: base);
    liveness.noteStreamHeartbeat(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: base,
    );
    final frameAt = base.add(const Duration(milliseconds: 10));
    liveness.noteDecoderHealth(
      generation: 1,
      targetIdentity: 'monitor:0',
      healthy: true,
      at: frameAt,
    );
    liveness.noteFrame(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: frameAt,
    );

    expect(liveness.canSendInput(frameAt), isFalse);
    expect(
      liveness.blockReason(frameAt),
      MonitorInputBlockReason.streamStale,
    );

    final heartbeatAt = frameAt.add(const Duration(milliseconds: 10));
    liveness.noteStreamHeartbeat(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: heartbeatAt,
    );
    expect(liveness.canSendInput(heartbeatAt), isTrue);
  });

  test('decoder_failure_blocks_input_before_transport_timeout', () {
    final liveness = liveMonitor();
    final later = base.add(const Duration(seconds: 1));
    liveness.noteTransportHeartbeat(generation: 1, at: later);
    liveness.noteStreamHeartbeat(
      generation: 1,
      targetIdentity: 'monitor:0',
      at: later,
    );
    liveness.noteDecoderHealth(
      generation: 1,
      targetIdentity: 'monitor:0',
      healthy: false,
      at: later,
    );

    expect(liveness.canSendInput(later), isFalse);
    expect(liveness.blockReason(later), MonitorInputBlockReason.decoderFailed);
  });

  test('late_frame_cannot_unlock_new_target', () {
    final liveness = liveMonitor();
    liveness.begin(
      generation: 2,
      targetIdentity: 'monitor:1',
      requireStreamHeartbeat: true,
    );
    final later = base.add(const Duration(seconds: 1));
    liveness.noteTransportHeartbeat(generation: 2, at: later);
    liveness.noteStreamHeartbeat(
      generation: 2,
      targetIdentity: 'monitor:1',
      at: later,
    );
    liveness.noteDecoderHealth(
      generation: 2,
      targetIdentity: 'monitor:1',
      healthy: true,
      at: later,
    );

    expect(
      liveness.noteFrame(
        generation: 1,
        targetIdentity: 'monitor:0',
        at: later,
      ),
      isFalse,
    );
    expect(liveness.canSendInput(later), isFalse);
    expect(liveness.blockReason(later), MonitorInputBlockReason.frameNotReady);

    expect(
      liveness.noteFrame(
        generation: 2,
        targetIdentity: 'monitor:1',
        at: later,
      ),
      isTrue,
    );
    expect(liveness.canSendInput(later), isTrue);
  });

  test('reconnect_releases_and_never_replays', () {
    final epoch = MonitorInputEpoch();
    final queuedBeforeReconnect = epoch.capture();
    final liveness = liveMonitor();

    epoch.invalidate();
    liveness.begin(
      generation: 2,
      targetIdentity: 'monitor:0',
      requireStreamHeartbeat: true,
    );

    expect(epoch.accepts(queuedBeforeReconnect), isFalse,
        reason: 'Queued input from the prior connection must not replay.');
    expect(
      liveness.canSendInput(base.add(const Duration(milliseconds: 1))),
      isFalse,
    );
  });

  test('view_only_blocks_all_input_paths', () {
    final liveness = liveMonitor();
    expect(liveness.canSendInput(base, viewOnly: true), isFalse);
    expect(
      liveness.blockReason(base, viewOnly: true),
      MonitorInputBlockReason.viewOnly,
    );
  });
}
