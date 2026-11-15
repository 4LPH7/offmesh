import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final manifest = File(
    'android/app/src/main/AndroidManifest.xml',
  ).readAsStringSync();

  test('declares the Android 12+ BLE permissions', () {
    for (final permission in [
      'BLUETOOTH_SCAN',
      'BLUETOOTH_ADVERTISE',
      'BLUETOOTH_CONNECT',
    ]) {
      expect(manifest, contains('android.permission.$permission"'));
    }
    expect(manifest, contains('usesPermissionFlags="neverForLocation"'));
  });

  test('legacy Bluetooth and location permissions stop at API 30', () {
    for (final permission in [
      'BLUETOOTH',
      'BLUETOOTH_ADMIN',
      'ACCESS_FINE_LOCATION',
    ]) {
      final line = manifest
          .split('\n')
          .firstWhere((l) => l.contains('android.permission.$permission"'));
      expect(line, contains('android:maxSdkVersion="30"'));
    }
  });
}
