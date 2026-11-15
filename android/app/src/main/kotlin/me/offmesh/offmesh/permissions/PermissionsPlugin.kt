package me.offmesh.offmesh.permissions

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

/**
 * Runtime Bluetooth permissions for the BLE link and the relay foreground service
 * (lib/app/runtime_permissions.dart). Only the permissions the BLE link needs are
 * requested; notifications are optional and are not asked for.
 */
class PermissionsPlugin(private val activity: Activity, messenger: BinaryMessenger) {
    private var pending: MethodChannel.Result? = null

    init {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> result.success(missing().isEmpty())
                "request" -> request(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun required(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_ADVERTISE,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            // Android 11 and below: scanning needs location as well.
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun missing(): List<String> =
        required().filter { activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }

    private fun request(result: MethodChannel.Result) {
        if (pending != null) {
            result.error("busy", "a permission request is already open", null)
            return
        }
        val toAsk = missing()
        if (toAsk.isEmpty()) {
            result.success(true)
            return
        }
        pending = result
        activity.requestPermissions(toAsk.toTypedArray(), REQUEST_CODE)
    }

    /** Called from MainActivity; returns true when the result belonged to this plugin. */
    fun onPermissionResult(requestCode: Int): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val result = pending ?: return true
        pending = null
        result.success(missing().isEmpty())
        return true
    }

    companion object {
        const val CHANNEL = "me.offmesh.offmesh/permissions"
        const val REQUEST_CODE = 4217
    }
}
