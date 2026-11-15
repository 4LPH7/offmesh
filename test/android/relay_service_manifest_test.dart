import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The relay foreground service must be declared with the connectedDevice type, which
/// Android 14+ requires, and must not be exported to other apps.
void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  test('service is declared with connectedDevice and not exported', () {
    final start = manifest.indexOf('<service');
    expect(start, isNonNegative, reason: 'no <service> element');
    final end = manifest.indexOf('/>', start);
    final element = manifest.substring(start, end);

    expect(element, contains('android:name=".relay.RelayForegroundService"'));
    expect(
      element,
      contains('android:foregroundServiceType="connectedDevice"'),
    );
    expect(element, contains('android:exported="false"'));
  });

  test('foreground service permissions are requested', () {
    for (final permission in [
      'FOREGROUND_SERVICE',
      'FOREGROUND_SERVICE_CONNECTED_DEVICE',
      'POST_NOTIFICATIONS',
    ]) {
      expect(manifest, contains('android.permission.$permission"'));
    }
  });
}
