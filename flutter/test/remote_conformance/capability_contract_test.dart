import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/models/remote_operation_state.dart';

void main() {
  test('old_peer_hides_new_actions', () {
    final capabilities = RemoteCapabilitySet.fromWire(null);

    expect(
      capabilities.status('host.process_end'),
      CapabilityStatus.unknown,
    );
    expect(capabilities.allows('host.process_end'), isFalse);
  });

  test('concurrent_replies_match_request', () {
    final tracker = RemoteOperationTracker(initialGeneration: 7);
    final first = tracker.begin(
      requestId: 101,
      operationId: 'op-first',
      sessionIdentity: 'session-a',
      targetIdentity: 'process:111',
      action: 'process_end',
    );
    final second = tracker.begin(
      requestId: 102,
      operationId: 'op-second',
      sessionIdentity: 'session-a',
      targetIdentity: 'component:bluestacks_adb',
      action: 'recover',
    );

    expect(
      tracker.resolve(
        requestId: 102,
        operationId: 'op-second',
        sessionIdentity: 'session-a',
        targetIdentity: 'component:bluestacks_adb',
        generation: 7,
        accepted: true,
        applied: true,
      ),
      isTrue,
    );
    expect(first.state, RemoteOperationState.pending);
    expect(second.state, RemoteOperationState.applied);
    expect(second.accepted, isTrue);

    expect(
      tracker.resolve(
        requestId: 101,
        operationId: 'op-first',
        sessionIdentity: 'session-a',
        targetIdentity: 'process:111',
        generation: 7,
        accepted: true,
        applied: false,
        errorCode: 'process_end_failed',
        error: 'Windows refused the request',
      ),
      isTrue,
    );
    expect(first.state, RemoteOperationState.failed);
    expect(first.accepted, isTrue);
    expect(first.errorCode, 'process_end_failed');
    expect(first.error, 'Windows refused the request');
  });

  test('late_reply_after_generation_change_ignored', () {
    final tracker = RemoteOperationTracker(initialGeneration: 3);
    final operation = tracker.begin(
      requestId: 41,
      operationId: 'op-old',
      sessionIdentity: 'session-a',
      targetIdentity: 'process:222',
      action: 'process_end',
    );

    tracker.advanceGeneration();

    expect(operation.state, RemoteOperationState.unknownOutcome);
    expect(
      tracker.resolve(
        requestId: 41,
        operationId: 'op-old',
        sessionIdentity: 'session-a',
        targetIdentity: 'process:222',
        generation: 3,
        accepted: true,
        applied: true,
      ),
      isFalse,
    );
    expect(operation.state, RemoteOperationState.unknownOutcome);
  });

  test('timeout_is_unknown_not_success', () {
    final tracker = RemoteOperationTracker(initialGeneration: 2);
    final operation = tracker.begin(
      requestId: 55,
      operationId: 'op-timeout',
      sessionIdentity: 'session-b',
      targetIdentity: 'component:bluestacks_adb',
      action: 'recover',
    );

    expect(tracker.markTimedOut(55), isTrue);
    expect(operation.state, RemoteOperationState.unknownOutcome);
    expect(operation.state, isNot(RemoteOperationState.applied));
  });

  test('mismatched_target_or_session_cannot_complete_operation', () {
    final tracker = RemoteOperationTracker(initialGeneration: 9);
    final operation = tracker.begin(
      requestId: 77,
      operationId: 'op-bound',
      sessionIdentity: 'session-real',
      targetIdentity: 'process:333',
      action: 'process_end',
    );

    expect(
      tracker.resolve(
        requestId: 77,
        operationId: 'op-bound',
        sessionIdentity: 'session-forged',
        targetIdentity: 'process:333',
        generation: 9,
        accepted: true,
        applied: true,
      ),
      isFalse,
    );
    expect(
      tracker.resolve(
        requestId: 77,
        operationId: 'op-bound',
        sessionIdentity: 'session-real',
        targetIdentity: 'process:999',
        generation: 9,
        accepted: true,
        applied: true,
      ),
      isFalse,
    );
    expect(operation.state, RemoteOperationState.pending);
  });
}
