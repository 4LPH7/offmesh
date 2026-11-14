import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/crypto/replay_window.dart';

void main() {
  test('accepts each counter once and refuses a replay', () {
    final window = ReplayWindow(size: 8);

    expect(window.accept(0), isTrue);
    expect(window.accept(1), isTrue);
    expect(window.accept(1), isFalse);
    expect(window.accepts(0), isFalse);
  });

  test('accepts counters that arrive out of order inside the window', () {
    final window = ReplayWindow(size: 8);

    expect(window.accept(5), isTrue);
    expect(window.accept(2), isTrue);
    expect(window.accept(4), isTrue);
    expect(window.accept(2), isFalse);
  });

  test('refuses a counter that fell out of the window', () {
    final window = ReplayWindow(size: 8);

    expect(window.accept(20), isTrue);
    expect(window.accept(12), isFalse, reason: '20 - 8 is the oldest allowed');
    expect(window.accept(13), isTrue);
  });

  test('remembers no more than size counters', () {
    final window = ReplayWindow(size: 4);
    for (var counter = 0; counter < 100; counter++) {
      expect(window.accept(counter), isTrue);
    }

    expect(window.accept(96), isFalse);
    expect(window.accept(97), isFalse);
    expect(window.accept(99), isFalse);
  });

  test('a refused counter changes nothing', () {
    final window = ReplayWindow(size: 8);
    window.accept(3);

    expect(window.accept(3), isFalse);
    expect(window.accepts(2), isTrue);
  });
}
