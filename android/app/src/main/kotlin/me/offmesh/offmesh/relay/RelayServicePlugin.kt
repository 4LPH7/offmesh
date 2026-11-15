package me.offmesh.offmesh.relay

import android.content.Context
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Starts and stops [RelayForegroundService] on request from Dart (lib/transports/relay_service.dart). */
class RelayServicePlugin(private val context: Context, messenger: BinaryMessenger) {
    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            handle(call, result)
        }
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> guarded(result) { RelayForegroundService.start(context) }
            "stop" -> guarded(result) { RelayForegroundService.stop(context) }
            else -> result.notImplemented()
        }
    }

    // Failures are reported by code only; the platform message can name internal state.
    private fun guarded(result: MethodChannel.Result, action: () -> Unit) {
        try {
            action()
            result.success(null)
        } catch (error: RuntimeException) {
            result.error("service_failed", error.javaClass.simpleName, null)
        }
    }

    companion object {
        const val CHANNEL = "me.offmesh.offmesh/relay"
    }
}
