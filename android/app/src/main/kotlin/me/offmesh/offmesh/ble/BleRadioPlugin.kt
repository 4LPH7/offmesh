package me.offmesh.offmesh.ble

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/// Moves bytes between Dart and the Android BLE stack. It holds no protocol logic: every
/// frame is sealed and segmented in Dart (lib/transports/ble_link.dart).
///
/// Client channels are keyed by the peer address. Server channels (a central connected to
/// our GATT server) are keyed "srv:" + address. Events: sighting, inbound, chunk, mtu, closed.
@SuppressLint("MissingPermission")
class BleRadioPlugin(private val context: Context, messenger: BinaryMessenger) {
    private val main = Handler(Looper.getMainLooper())
    private val events = EventChannel(messenger, EVENT_CHANNEL)
    private var sink: EventChannel.EventSink? = null

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var server: BluetoothGattServer? = null
    private var rxCharacteristic: BluetoothGattCharacteristic? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var scanCallback: ScanCallback? = null
    private val clients = HashMap<String, BluetoothGatt>()
    private val serverDevices = HashMap<String, BluetoothDevice>()
    private val pendingConnect = HashMap<String, MethodChannel.Result>()
    private val pendingWrites = HashMap<String, MethodChannel.Result>()
    private val pendingNotify = HashMap<String, MethodChannel.Result>()

    init {
        MethodChannel(messenger, CONTROL_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startAdvertising" -> startAdvertising(call.argument<ByteArray>("rotatingId"), result)
                "stopAdvertising" -> guarded(result) { stopAdvertising(); reply(result, null) }
                "startScan" -> startScan(result)
                "stopScan" -> guarded(result) { stopScan(); reply(result, null) }
                "connect" -> connect(call.argument<String>("address"), result)
                "writeChunk" -> writeChunk(call.argument<String>("key"), call.argument<ByteArray>("data"), result)
                "closeChannel" -> closeChannel(call.argument<String>("key"), result)
                else -> result.notImplemented()
            }
        }
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) {
                sink = eventSink
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    private fun canUse(permission: String): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    private fun reply(result: MethodChannel.Result, value: Any?) {
        main.post { result.success(value) }
    }

    private fun fail(result: MethodChannel.Result, code: String) {
        main.post { result.error(code, null, null) }
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    private fun guarded(result: MethodChannel.Result, block: () -> Unit) {
        try {
            block()
        } catch (e: SecurityException) {
            fail(result, "permission_denied")
        }
    }

    private fun startAdvertising(id: ByteArray?, result: MethodChannel.Result) = guarded(result) {
        if (id == null || id.size != ID_LENGTH) return@guarded fail(result, "bad_id")
        if (!canUse(Manifest.permission.BLUETOOTH_ADVERTISE) || !canUse(Manifest.permission.BLUETOOTH_CONNECT)) {
            return@guarded fail(result, "permission_denied")
        }
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return@guarded fail(result, "unavailable")
        openServer()
        advertiseCallback?.let { advertiser.stopAdvertising(it) }
        val callback = object : AdvertiseCallback() {}
        advertiseCallback = callback
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER)
            .setConnectable(true)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .build()
        // The stack adds the 3-byte flags structure; this is 26 bytes of service data.
        val data = AdvertiseData.Builder()
            .setIncludeDeviceName(false)
            .setIncludeTxPowerLevel(false)
            .addServiceData(ParcelUuid(SERVICE_UUID), id)
            .build()
        advertiser.startAdvertising(settings, data, callback)
        reply(result, null)
    }

    private fun stopAdvertising() {
        val callback = advertiseCallback ?: return
        if (canUse(Manifest.permission.BLUETOOTH_ADVERTISE)) adapter?.bluetoothLeAdvertiser?.stopAdvertising(callback)
        advertiseCallback = null
    }

    /// Opens the GATT server with the OffMesh service: one RX characteristic that centrals
    /// write to and that notifies them. Idempotent.
    private fun openServer() {
        if (server != null) return
        if (!canUse(Manifest.permission.BLUETOOTH_CONNECT)) return
        val manager = context.getSystemService(BluetoothManager::class.java) ?: return
        val opened = manager.openGattServer(context, serverCallback) ?: return
        val rx = BluetoothGattCharacteristic(
            RX_UUID,
            BluetoothGattCharacteristic.PROPERTY_WRITE or
                BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE or
                BluetoothGattCharacteristic.PROPERTY_NOTIFY,
            BluetoothGattCharacteristic.PERMISSION_WRITE,
        )
        rx.addDescriptor(
            BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or BluetoothGattDescriptor.PERMISSION_WRITE,
            ),
        )
        val service = BluetoothGattService(SERVICE_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
        service.addCharacteristic(rx)
        opened.addService(service)
        server = opened
        rxCharacteristic = rx
    }

    private fun startScan(result: MethodChannel.Result) = guarded(result) {
        if (!canUse(Manifest.permission.BLUETOOTH_SCAN)) return@guarded fail(result, "permission_denied")
        val scanner = adapter?.bluetoothLeScanner ?: return@guarded fail(result, "unavailable")
        stopScan()
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, scanResult: ScanResult) = onSighting(scanResult)

            override fun onBatchScanResults(results: MutableList<ScanResult>) = results.forEach { onSighting(it) }
        }
        scanCallback = callback
        // Unfiltered scan, checked in software: a service-data filter is not reliable across
        // stacks. ponytail: add a hardware filter if scan power matters on the spike.
        scanner.startScan(
            emptyList(),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(),
            callback,
        )
        reply(result, null)
    }

    private fun stopScan() {
        val callback = scanCallback ?: return
        if (canUse(Manifest.permission.BLUETOOTH_SCAN)) adapter?.bluetoothLeScanner?.stopScan(callback)
        scanCallback = null
    }

    private fun onSighting(scanResult: ScanResult) {
        val id = scanResult.scanRecord?.getServiceData(ParcelUuid(SERVICE_UUID)) ?: return
        emit(mapOf("event" to "sighting", "address" to scanResult.device.address, "data" to id))
    }

    private fun connect(address: String?, result: MethodChannel.Result) = guarded(result) {
        if (address == null) return@guarded fail(result, "bad_address")
        if (!canUse(Manifest.permission.BLUETOOTH_CONNECT)) return@guarded fail(result, "permission_denied")
        val device = adapter?.getRemoteDevice(address) ?: return@guarded fail(result, "unavailable")
        if (clients.containsKey(address)) return@guarded fail(result, "already_connected")
        pendingConnect[address] = result
        clients[address] = device.connectGatt(context, false, clientCallback(address), BluetoothDevice.TRANSPORT_LE)
    }

    private fun clientCallback(address: String) = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED && status == BluetoothGatt.GATT_SUCCESS) {
                gatt.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                clients.remove(address)?.close()
                pendingConnect.remove(address)?.let { fail(it, "disconnected") }
                emit(mapOf("event" to "closed", "key" to address))
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status != BluetoothGatt.GATT_SUCCESS || gatt.getService(SERVICE_UUID) == null) {
                gatt.disconnect()
                return
            }
            // Ask for the largest MTU first; notifications are enabled in onMtuChanged.
            if (!gatt.requestMtu(MAX_MTU)) enableNotifications(gatt)
        }

        override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) {
            emit(mapOf("event" to "mtu", "key" to address, "mtu" to mtu))
            enableNotifications(gatt)
        }

        override fun onDescriptorWrite(gatt: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) {
            if (descriptor.uuid != CCCD_UUID) return
            val waiting = pendingConnect.remove(address) ?: return
            if (status == BluetoothGatt.GATT_SUCCESS) reply(waiting, mapOf("key" to address)) else fail(waiting, "cccd_failed")
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            emitChunk(address, characteristic.value)
        }

        override fun onCharacteristicChanged(
            gatt: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            emitChunk(address, value)
        }

        override fun onCharacteristicWrite(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
            val waiting = pendingWrites.remove(address) ?: return
            if (status == BluetoothGatt.GATT_SUCCESS) reply(waiting, null) else fail(waiting, "write_failed")
        }
    }

    private fun enableNotifications(gatt: BluetoothGatt) {
        val rx = gatt.getService(SERVICE_UUID)?.getCharacteristic(RX_UUID) ?: return
        val cccd = rx.getDescriptor(CCCD_UUID) ?: return
        gatt.setCharacteristicNotification(rx, true)
        @Suppress("DEPRECATION")
        cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        gatt.writeDescriptor(cccd)
    }

    private fun emitChunk(key: String, data: ByteArray?) {
        if (data != null) emit(mapOf("event" to "chunk", "key" to key, "data" to data))
    }

    private val serverCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            val address = device.address
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverDevices[address] = device
                emit(mapOf("event" to "inbound", "key" to SERVER_KEY_PREFIX + address))
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                serverDevices.remove(address)
                pendingNotify.remove(address)?.let { fail(it, "disconnected") }
                emit(mapOf("event" to "closed", "key" to SERVER_KEY_PREFIX + address))
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (characteristic.uuid == RX_UUID) emitChunk(SERVER_KEY_PREFIX + device.address, value)
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray,
        ) {
            if (responseNeeded) server?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, 0, null)
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            emit(mapOf("event" to "mtu", "key" to SERVER_KEY_PREFIX + device.address, "mtu" to mtu))
        }

        override fun onNotificationSent(device: BluetoothDevice, status: Int) {
            val waiting = pendingNotify.remove(device.address) ?: return
            if (status == BluetoothGatt.GATT_SUCCESS) reply(waiting, null) else fail(waiting, "notify_failed")
        }
    }

    /// Client key: a write with response to the peer's RX characteristic. Server key: a notification.
    private fun writeChunk(key: String?, data: ByteArray?, result: MethodChannel.Result) = guarded(result) {
        if (key == null || data == null) return@guarded fail(result, "bad_args")
        if (key.startsWith(SERVER_KEY_PREFIX)) {
            val address = key.removePrefix(SERVER_KEY_PREFIX)
            val device = serverDevices[address] ?: return@guarded fail(result, "not_connected")
            val srv = server ?: return@guarded fail(result, "unavailable")
            val rx = rxCharacteristic ?: return@guarded fail(result, "unavailable")
            if (pendingNotify.containsKey(address)) return@guarded fail(result, "busy")
            pendingNotify[address] = result
            @Suppress("DEPRECATION")
            rx.value = data
            if (!srv.notifyCharacteristicChanged(device, rx, false)) {
                pendingNotify.remove(address)
                fail(result, "notify_failed")
            }
        } else {
            val gatt = clients[key] ?: return@guarded fail(result, "not_connected")
            val rx = gatt.getService(SERVICE_UUID)?.getCharacteristic(RX_UUID) ?: return@guarded fail(result, "unavailable")
            if (pendingWrites.containsKey(key)) return@guarded fail(result, "busy")
            pendingWrites[key] = result
            @Suppress("DEPRECATION")
            rx.value = data
            rx.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            if (!gatt.writeCharacteristic(rx)) {
                pendingWrites.remove(key)
                fail(result, "write_failed")
            }
        }
    }

    private fun closeChannel(key: String?, result: MethodChannel.Result) = guarded(result) {
        if (key == null) return@guarded fail(result, "bad_args")
        if (key.startsWith(SERVER_KEY_PREFIX)) {
            serverDevices[key.removePrefix(SERVER_KEY_PREFIX)]?.let { server?.cancelConnection(it) }
        } else {
            clients.remove(key)?.let {
                it.disconnect()
                it.close()
            }
        }
        reply(result, null)
    }

    companion object {
        const val CONTROL_CHANNEL = "me.offmesh.offmesh/ble"
        const val EVENT_CHANNEL = "me.offmesh.offmesh/ble/events"
        const val ID_LENGTH = 8
        const val MAX_MTU = 517
        const val SERVER_KEY_PREFIX = "srv:"
        val SERVICE_UUID: UUID = UUID.fromString("4f66664d-6573-6800-0000-000000000001")
        val RX_UUID: UUID = UUID.fromString("4f66664d-6573-6800-0000-000000000002")
        val CCCD_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }
}
