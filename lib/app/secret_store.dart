import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Byte-valued secrets kept in platform secure storage.
abstract interface class SecretStore {
  Future<Uint8List?> read(String key);
  Future<void> write(String key, Uint8List value);
  Future<void> delete(String key);
}

/// Android: AES-GCM data key wrapped by an RSA-OAEP key held in Android Keystore.
/// Windows: DPAPI-encrypted file under the app support directory.
class PlatformSecretStore implements SecretStore {
  PlatformSecretStore()
    : _storage = const FlutterSecureStorage(
        // resetOnError would wipe the store on a decrypt error, silently
        // replacing the identity; fail loudly instead.
        aOptions: AndroidOptions(resetOnError: false),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<Uint8List?> read(String key) async {
    final value = await _storage.read(key: key);
    return value == null ? null : base64Decode(value);
  }

  @override
  Future<void> write(String key, Uint8List value) =>
      _storage.write(key: key, value: base64Encode(value));

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// In-memory store for tests.
class MemorySecretStore implements SecretStore {
  final Map<String, Uint8List> _values = {};

  @override
  Future<Uint8List?> read(String key) async {
    final value = _values[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> write(String key, Uint8List value) async {
    _values[key] = Uint8List.fromList(value);
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}
