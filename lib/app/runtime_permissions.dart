import 'package:flutter/services.dart';

/// Channel served by PermissionsPlugin on Android.
const String permissionsChannelName = 'me.offmesh.offmesh/permissions';

/// Runtime Bluetooth permissions needed before the BLE link or the relay service starts.
/// Off Android, or when the channel is missing, the answer is "not granted" with
/// [lastError] set, so callers never start a radio they were not allowed to use.
class RuntimePermissions {
  RuntimePermissions({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(permissionsChannelName);

  final MethodChannel _channel;
  String? _lastError;

  /// Short code for the last failure, or null when the last call succeeded.
  String? get lastError => _lastError;

  /// True when every required permission is already granted.
  Future<bool> granted() => _ask('status');

  /// Shows the system prompt for anything still missing. Resolves to true when all are granted.
  Future<bool> request() => _ask('request');

  Future<bool> _ask(String method) async {
    try {
      final ok = await _channel.invokeMethod<bool>(method);
      _lastError = null;
      return ok ?? false;
    } on PlatformException catch (error) {
      _lastError = error.code;
      return false;
    } on MissingPluginException {
      _lastError = 'unavailable';
      return false;
    }
  }
}
