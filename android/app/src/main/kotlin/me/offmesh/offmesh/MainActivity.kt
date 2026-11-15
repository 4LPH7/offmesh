package me.offmesh.offmesh

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import me.offmesh.offmesh.ble.BleRadioPlugin
import me.offmesh.offmesh.permissions.PermissionsPlugin
import me.offmesh.offmesh.relay.RelayServicePlugin

class MainActivity : FlutterActivity() {
    private var permissionsPlugin: PermissionsPlugin? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        BleRadioPlugin(applicationContext, messenger)
        RelayServicePlugin(applicationContext, messenger)
        permissionsPlugin = PermissionsPlugin(this, messenger)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (permissionsPlugin?.onPermissionResult(requestCode) != true) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        }
    }
}
