import 'dart:math';
import 'dart:typed_data';

import 'voice_burst.dart';

/// Roger beep length and pitch: short and high, so it is heard but does not mask speech.
const Duration rogerBeepLength = Duration(milliseconds: 150);
const double rogerBeepHz = 1400;

/// A short tone with a 10 ms fade in and out, played locally when a burst ends.
/// Generated on the phone; nothing is sent.
Int16List rogerBeep({int sampleRate = voiceSampleRate}) {
  final count = sampleRate * rogerBeepLength.inMilliseconds ~/ 1000;
  final fade = sampleRate * 10 ~/ 1000;
  return Int16List.fromList([
    for (var i = 0; i < count; i++)
      (8000 *
              min(1, min(i, count - 1 - i) / fade) *
              sin(2 * pi * rogerBeepHz * i / sampleRate))
          .round(),
  ]);
}

/// "just now", "45 s ago", "3 min ago", "2 h ago", "4 d ago". Future times read "just now".
String heardAgo(Duration elapsed) {
  if (elapsed.inSeconds < 10) return 'just now';
  if (elapsed.inMinutes < 1) return '${elapsed.inSeconds} s ago';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes} min ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours} h ago';
  return '${elapsed.inDays} d ago';
}
