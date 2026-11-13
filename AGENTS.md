# Repository Guidelines

## Project Structure & Module Organization

OffMesh is a Flutter/Dart app. `lib/main.dart` starts the app. App coordination lives in `lib/app/`, screens in `lib/ui/`, and reusable logic in `lib/core/crypto/`, `lib/core/mesh/`, and `lib/core/protocol/`. LAN networking is in `lib/transports/`. Tests under `test/` mirror these areas; shared mesh fakes and protocol test vectors live beside the relevant tests. Platform runners are under `android/` and `windows/`. Do not hand-edit generated build output.

## Build, Test, and Development Commands

- `flutter pub get` resolves the locked Dart and Flutter dependencies.
- `flutter test` runs the full unit, widget, and integration test suite.
- `flutter test test/core/protocol/packet_test.dart` runs one focused test file.
- `flutter analyze` checks code against the configured Dart lints.
- `flutter run -d windows` launches the Windows desktop app when that target is available.
- `flutter build apk --debug` builds a debug Android APK.

## Coding Style & Naming Conventions

Use standard Dart formatting with two-space indentation; run `dart format lib test` before submitting. Follow `flutter_lints` from `analysis_options.yaml`. Name files and directories in `snake_case`; use `UpperCamelCase` for types and `lowerCamelCase` for members. Prefer package imports such as `package:offmesh/core/protocol/packet.dart` for app code and tests.

## Testing Guidelines

Name tests `*_test.dart` and place them in the directory matching the code under test. Add coverage for behavior changes, including malformed input and boundary conditions for protocol or networking code. Use focused unit tests for codecs and limits, and integration tests for multi-hop routing or LAN flows. No coverage threshold is configured. Run `flutter test` and `flutter analyze` before opening a pull request.

## Commit & Pull Request Guidelines

Recent history uses concise conventional prefixes such as `feat:`, `fix:`, `test:`, and `chore:`; keep subjects short and specific. A pull request should explain the change and its user-visible or protocol impact, list validation commands and results, and link a related issue when one exists. Include screenshots for UI changes and note the platforms/devices used for manual checks.