# Audio spike (plan 06-00)

Goal: pick the capture, playback and codec path for push-to-talk on Android and Windows,
and measure frame size and latency.

Status, 2026-11-16: **build part done, device part NOT RUN.** No Android device is
attached and the Windows microphone path has not been exercised.

## Decision

| Part | Choice | Why |
|------|--------|-----|
| Capture | `record` ^6.2.1 (BSD-3) | `startStream` gives 16-bit PCM on Android and Windows. Windows source checked: `StartStream` accepts only `pcm16bits`, which is what we need. 7.x needs Flutter 3.44; this repo is on 3.38.5. |
| Playback | `flutter_soloud` ^3.5.4 (MIT) | `setBufferStream` plays streamed `s16le` on Android and Windows, minSdk 21. It can also decode Ogg/Opus (`BufferType.auto`) if an Opus encoder becomes available later. |
| Codec, v1 | IMA ADPCM in pure Dart, 8 kHz mono | 4 bits per sample, 32 kbit/s. A 20 ms frame is 80 bytes; two frames plus a 4-byte decoder state fit one 220-byte packet payload, so one packet every 40 ms. No native code, easy to test. |
| Codec, later | Codec2 (BLE) or Opus | No maintained Dart 3 Opus encoder binding exists (`opus_dart` 3.0.1 requires Dart below 3.0). Codec2 stays parked until BLE links are verified on phones. |

Rejected:

- `mp_audio_stream` 0.3.0: pins NDK 21.1 and minSdk 16 in its own Gradle file; the Android
  build fails with this repo's NDK 28 (CXX1104, then CXX1110).
- `flutter_pcm_sound`, `sound_stream`: no Windows support.
- `opus_dart` / `opus_flutter`: pre-Dart-3 SDK constraint.

## Build results (branch `spike/audio`)

- `flutter build windows --debug`: built.
- `flutter build apk --debug` (with `ANDROID_NDK_HOME=D:\Android\ndk-r28c`): built, after one
  Gradle change. `flutter_soloud` declares NDK 27.0.12077973, while `android/local.properties`
  forces `ndk.dir` to NDK 28.2. The spike pins `flutter_soloud`'s `ndkVersion` to 28.2 in
  `android/build.gradle.kts` (`afterEvaluate` override).
  Long-term fix, preferred: install NDK 28.2 under the SDK's `ndk/28.2.13676358` folder (the
  empty partial folder there must be deleted first) and drop `ndk.dir`, so each plugin can
  use its own NDK version.

## Bandwidth

- ADPCM 8 kHz: 4,000 bytes/s of audio. With one packet per 40 ms (25 packets/s), packet
  header 26 B, Noise tag 16 B and seal 32 B, about 6.9 kB/s (55 kbit/s) per speaker on the
  wire. Fine for LAN and internet; too heavy for multi-hop BLE.
- Raw PCM16 at 8 kHz would be 16 kB/s (128 kbit/s) before overhead; not used.

## Device procedure (NOT RUN)

Harness: `lib/spike/audio_loopback.dart` on branch `spike/audio` (mic to speaker, hold to
talk). Point `main()` at `AudioLoopbackApp`, run on a phone, then on Windows.

1. Hold the button and speak. Record: first-chunk delay (shown), average chunk size (shown),
   and perceived mouth-to-ear delay (clap test: clap near the phone, compare to a second
   phone recording both sounds).
2. Pass: first chunk under 100 ms, loopback under 300 ms, no audible gaps over 10 s.
3. Fill in:

| Device | First chunk (ms) | Avg chunk (bytes) | Loopback (ms) | Gaps? | Result |
|--------|------------------|-------------------|---------------|-------|--------|
| Phone A | | | | | |
| Windows PC | | | | | |

If the loopback fails the pass line, the next candidate is `flutter_sound` for playback; the
codec decision does not change.

## Next

Plan 06-01 (channel keys, sealed broadcast, group text) does not depend on the device
results and can start now. Plan 06-02 (voice bursts) needs the dependencies above added
to `main` with the NDK fix.
