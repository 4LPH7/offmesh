import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The identity lives in flutter_secure_storage shared prefs, wrapped by an
// Android Keystore key that never leaves the device. If backup or
// device transfer copies those prefs, the app cannot unwrap them and shows
// the startup error on every launch. These checks keep backup switched off.
void main() {
  const res = 'android/app/src/main/res';

  test('manifest disables auto-backup and points at extraction rules', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();

    expect(manifest, contains('android:allowBackup="false"'));
    expect(
      manifest,
      contains('android:dataExtractionRules="@xml/data_extraction_rules"'),
    );
  });

  test('extraction rules exclude shared prefs from cloud and transfer', () {
    final rules = File('$res/xml/data_extraction_rules.xml').readAsStringSync();
    const exclude = '<exclude domain="sharedpref" path="." />';

    for (final section in ['cloud-backup', 'device-transfer']) {
      final match = RegExp(
        '<$section>(.*?)</$section>',
        dotAll: true,
      ).firstMatch(rules);
      expect(match, isNotNull, reason: '$section section missing');
      expect(match!.group(1), contains(exclude), reason: section);
    }
  });
}
