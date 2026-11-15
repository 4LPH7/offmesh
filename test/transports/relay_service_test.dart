import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:offmesh/transports/relay_service.dart';

/// Covers the Dart side of the relay foreground service: method names sent to the
/// channel, and that failures are reported as codes instead of being swallowed.
void main() {
  const channel = MethodChannel(relayServiceChannelName);
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

  test('start invokes start and reports running', () async {
    mockChannel((_) async => null);
    final service = RelayService();

    expect(await service.start(), isTrue);
    expect(service.running, isTrue);
    expect(service.lastError, isNull);
    expect(calls, ['start']);
  });

  test('a platform failure is reported as its code, not running', () async {
    mockChannel(
      (_) async => throw PlatformException(
        code: 'service_failed',
        message: 'path /data/x',
      ),
    );
    final service = RelayService();

    expect(await service.start(), isFalse);
    expect(service.running, isFalse);
    expect(service.lastError, 'service_failed');
  });

  test('a missing channel (non-Android, tests) reports unavailable', () async {
    final service = RelayService();

    expect(await service.start(), isFalse);
    expect(service.lastError, 'unavailable');
  });

  test('stop does nothing unless the service was started', () async {
    mockChannel((_) async => null);
    final service = RelayService();

    await service.stop();
    expect(calls, isEmpty);

    await service.start();
    await service.stop();
    expect(calls, ['start', 'stop']);
    expect(service.running, isFalse);
  });
}
