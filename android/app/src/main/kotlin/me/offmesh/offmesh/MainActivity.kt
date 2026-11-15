package me.offmesh.offmesh

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import me.offmesh.offmesh.ble.BleRadioPlugin
import me.offmesh.offmesh.relay.RelayServicePlugin

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        BleRadioPlugin(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
        RelayServicePlugin(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }
}
