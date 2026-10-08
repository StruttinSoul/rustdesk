import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_hbb/mobile/pages/emulator_page.dart';

void main() {
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
