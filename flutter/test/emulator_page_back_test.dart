import 'package:flutter_hbb/mobile/pages/emulator_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('second back within two seconds leaves', () {
    final g = DoubleBackGuard();
    final t0 = DateTime(2026, 11, 16, 12);
    expect(g.press(t0), isFalse);
    expect(g.press(t0.add(const Duration(milliseconds: 1900))), isTrue);
  });

  test('a back after the window starts over', () {
    final g = DoubleBackGuard();
    final t0 = DateTime(2026, 11, 16, 12);
    expect(g.press(t0), isFalse);
    expect(g.press(t0.add(const Duration(milliseconds: 2100))), isFalse);
    expect(g.press(t0.add(const Duration(milliseconds: 2500))), isTrue);
  });

  test('reset forgets the first press', () {
    final g = DoubleBackGuard()..press(DateTime(2026));
    g.reset();
    expect(g.press(DateTime(2026).add(const Duration(milliseconds: 500))),
        isFalse);
  });
}
