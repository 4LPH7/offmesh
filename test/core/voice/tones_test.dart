import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/core/voice/tones.dart';
import 'package:offmesh/core/voice/voice_burst.dart';

void main() {
  test('roger beep is 150 ms at 8 kHz and fades in and out', () {
    final beep = rogerBeep();
    expect(beep.length, voiceSampleRate * 150 ~/ 1000);
    expect(beep.first.abs(), lessThan(200));
    expect(beep.last.abs(), lessThan(200));
    expect(
      beep.reduce((a, b) => a.abs() > b.abs() ? a : b).abs(),
      greaterThan(4000),
    );
  });

  test('heard-ago labels', () {
    expect(heardAgo(const Duration(seconds: 3)), 'just now');
    expect(heardAgo(const Duration(seconds: -5)), 'just now');
    expect(heardAgo(const Duration(seconds: 45)), '45 s ago');
    expect(heardAgo(const Duration(minutes: 3, seconds: 20)), '3 min ago');
    expect(heardAgo(const Duration(hours: 2, minutes: 5)), '2 h ago');
    expect(heardAgo(const Duration(days: 4)), '4 d ago');
  });
}
