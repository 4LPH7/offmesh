import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/app/runtime_permissions.dart';

/// Dart side of the Bluetooth permission prompt: method names and reported answers.
/// Relay Mode and the BLE link must never start a radio on a "not granted" answer.
void main() {
  const channel = MethodChannel(permissionsChannelName);
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;

  void mockChannel(Future<Object?> Function(MethodCall call) handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return handler(call);
        });
  }

  setUp(() => calls = []);
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('request asks the platform and reports granted', () async {
    mockChannel((_) async => true);
    final permissions = RuntimePermissions();

    expect(await permissions.request(), isTrue);
    expect(permissions.lastError, isNull);
    expect(calls, ['request']);
  });

  test('a denied answer is false, not an error', () async {
    mockChannel((_) async => false);
    final permissions = RuntimePermissions();

    expect(await permissions.request(), isFalse);
    expect(permissions.lastError, isNull);
  });

  test('granted() queries status without showing a prompt', () async {
    mockChannel((_) async => true);
    final permissions = RuntimePermissions();

    expect(await permissions.granted(), isTrue);
    expect(calls, ['status']);
  });

  test(
    'a platform failure is reported as its code and treated as denied',
    () async {
      mockChannel(
        (_) async => throw PlatformException(code: 'busy', message: 'x'),
      );
      final permissions = RuntimePermissions();

      expect(await permissions.request(), isFalse);
      expect(permissions.lastError, 'busy');
    },
  );

  test('a missing channel reports unavailable and not granted', () async {
    final permissions = RuntimePermissions();

    expect(await permissions.request(), isFalse);
    expect(permissions.lastError, 'unavailable');
  });
}
