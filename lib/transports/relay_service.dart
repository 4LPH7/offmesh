import 'package:flutter/services.dart';

/// Channel served by RelayServicePlugin on Android.
const String relayServiceChannelName = 'me.offmesh.offmesh/relay';

/// Starts and stops the Android foreground service that keeps relaying alive with the
/// screen off. On other platforms, or where the channel is missing, [start] reports
/// failure through [lastError] instead of pretending the service runs.
class RelayService {
  RelayService({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(relayServiceChannelName);

  final MethodChannel _channel;
  bool _running = false;
  String? _lastError;

  bool get running => _running;

  /// Short code for the last failure (never a platform message), or null when healthy.
  String? get lastError => _lastError;

  Future<bool> start() async {
    try {
      await _channel.invokeMethod<void>('start');
      _running = true;
      _lastError = null;
    } on PlatformException catch (error) {
      _running = false;
      _lastError = error.code;
    } on MissingPluginException {
      _running = false;
      _lastError = 'unavailable';
    }
    return _running;
  }

  /// Always sends stop, even when start has not finished yet: the channel is ordered, so
  /// the stop lands after a start that is still in flight. Native stop is idempotent.
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on PlatformException catch (error) {
      _lastError = error.code;
    } on MissingPluginException {
      _lastError = 'unavailable';
    }
    _running = false;
  }
}
