package io.github.junweiup.vibepier.remote.core.transport

import io.github.junweiup.vibepier.remote.R

import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import io.github.junweiup.vibepier.remote.core.security.ControlProtocol

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.*
import android.content.pm.PackageManager
import android.os.*
import java.io.ByteArrayOutputStream
import java.util.UUID

/** All GATT operations are serialized on the main handler and use write responses. */
@SuppressLint("MissingPermission")
class BluetoothLink(private val context: Context, private val received: (String) -> Unit,
                    private val changed: () -> Unit,
                    private val codexPairRead: (ByteArray?) -> Unit = {}) {
    companion object {
        val SERVICE: UUID = UUID.fromString("a5780001-2bd2-4d66-abe6-7c9f0f4b9100")
        val COMMAND: UUID = UUID.fromString("a5780002-2bd2-4d66-abe6-7c9f0f4b9100")
        val STATE: UUID = UUID.fromString("a5780003-2bd2-4d66-abe6-7c9f0f4b9100")
        val CODEX_PAIR: UUID = UUID.fromString("a5780004-2bd2-4d66-abe6-7c9f0f4b9100")
        val CCC: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
        fun permissions() = arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
    }
    private val deviceKeys = DeviceKeys(context)
    private val security = SecureControlClient(deviceKeys.device, deviceKeys::controlKeys)
    @Volatile var status = context.getString(R.string.ble_disconnected); private set
    @Volatile var name: String? = null; private set
    private val main = Handler(Looper.getMainLooper())
    private val adapter get() = context.getSystemService(BluetoothManager::class.java)?.adapter
    private var gatt: BluetoothGatt? = null
    private var command: BluetoothGattCharacteristic? = null
    private var wantsPairRead = false
    private var readingPair = false
    private var active = false
    private var scanning = false
    private var ready = false
    private var writing = false
    private var pairing = false
    private var setupStarted = false
    private var receivedState = false
    val authenticated: Boolean get() = active && ready && receivedState && security.ready
    val phoneAudioSupported: Boolean get() = authenticated && security.supports(ControlProtocol.PHONE_AUDIO)
    val enrollmentReady: Boolean get() = active && ready && receivedState
    val enrollmentConnectionID: String? get() = if (enrollmentReady) generation.toString() else null
    private var mtu = 23
    private var generation = 0
    private val pending = ArrayDeque<ByteArray>()
    private val chatPending = ArrayDeque<String>()
    private var audioActive = false
    private val incoming = ByteArrayOutputStream()
    private var hello = ""
    private fun report(text: String) { status = text; changed() }
    private val timeout = Runnable { fail(context.getString(R.string.ble_timeout)) }
    private val keepAlive = object : Runnable {
        override fun run() {
            if (!active) return
            if (ready) send(hello)
            main.postDelayed(this, 4000)
        }
    }
    private val bondReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context?, intent: Intent?) {
            if (intent?.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED || !pairing) return
            val device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
            if (device?.address != gatt?.device?.address) return
            if (device?.bondState == BluetoothDevice.BOND_BONDED) {
                pairing = false; writing = false; main.removeCallbacks(timeout); pump()
            } else if (device?.bondState == BluetoothDevice.BOND_NONE) {
                active = false; disconnect(); report(context.getString(R.string.ble_pairing_incomplete))
            }
        }
    }
    init {
        val filter = IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
        context.registerReceiver(bondReceiver, filter, Context.RECEIVER_EXPORTED)
    }
    fun watch(on: Boolean, helloLine: String) { main.post {
        active = on; hello = helloLine
        disconnect()
        if (on) scan() else report(context.getString(R.string.ble_disconnected))
    } }
    private fun scan() {
        if (!active || gatt != null || scanning) return
        if (permissions().any { context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }) {
            report(context.getString(R.string.ble_permission)); return
        }
        val bluetooth = adapter
        if (bluetooth == null) { report(context.getString(R.string.ble_unsupported)); return }
        if (!bluetooth.isEnabled) { report(context.getString(R.string.ble_enable)); return }
        report(context.getString(R.string.ble_searching))
        scanning = true
        val token = generation
        bluetooth.bluetoothLeScanner?.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
            ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build(), scanner)
        main.postDelayed({ if (active && scanning && generation == token) { stopScan(); report(context.getString(R.string.ble_mac_not_found)); main.postDelayed({ scan() }, 3000) } }, 12000)
    }
    private fun stopScan() {
        if (scanning) try { adapter?.bluetoothLeScanner?.stopScan(scanner) } catch (_: SecurityException) {}
        scanning = false
    }
    private val scanner = object : ScanCallback() {
        override fun onScanResult(type: Int, result: ScanResult) { main.post {
            if (!active || !scanning) return@post
            stopScan(); report(context.getString(R.string.ble_connecting))
            gatt = result.device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
            main.postDelayed(timeout, 15000)
        } }
        override fun onScanFailed(errorCode: Int) { main.post {
            scanning = false; report(context.getString(R.string.ble_scan_failed, errorCode))
        } }
    }
    private fun current(value: BluetoothGatt) = active && gatt === value
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) { main.post {
            if (!current(g)) return@post
            if (status == BluetoothGatt.GATT_SUCCESS && newState == BluetoothProfile.STATE_CONNECTED) {
                report(context.getString(R.string.ble_reading_services)); if (!g.discoverServices()) fail(context.getString(R.string.ble_services_failed))
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED || status != BluetoothGatt.GATT_SUCCESS) fail(context.getString(R.string.ble_reconnecting))
        } }
        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) { main.post {
            if (!current(g)) return@post
            val service = g.getService(SERVICE)
            command = service?.getCharacteristic(COMMAND)
            if (status != BluetoothGatt.GATT_SUCCESS || command == null) { fail(context.getString(R.string.ble_incompatible)); return@post }
            if (!g.requestMtu(517)) subscribe(g)
            else main.postDelayed({ if (current(g)) subscribe(g) }, 2000)
        } }
        override fun onMtuChanged(g: BluetoothGatt, value: Int, status: Int) { main.post {
            if (!current(g)) return@post
            if (status == BluetoothGatt.GATT_SUCCESS) mtu = value.coerceAtLeast(23)
            subscribe(g)
        } }
        override fun onDescriptorWrite(g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int) { main.post {
            if (!current(g)) return@post
            if (status != BluetoothGatt.GATT_SUCCESS) { fail(context.getString(R.string.ble_subscribe_failed)); return@post }
            main.removeCallbacks(timeout)
            ready = true; name = g.device.name ?: "VibePier"
            report(context.getString(R.string.ble_syncing))
            keepAlive.run()
        } }
        override fun onCharacteristicWrite(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) { main.post {
            if (!current(g)) return@post
            main.removeCallbacks(timeout)
            if (status == BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION || status == BluetoothGatt.GATT_INSUFFICIENT_ENCRYPTION) {
                pairing = true; report(context.getString(R.string.ble_confirm_pairing))
                if (g.device.bondState == BluetoothDevice.BOND_BONDED || !g.device.createBond()) {
                    active = false; disconnect(); report(context.getString(R.string.ble_pairing_failed))
                } else main.postDelayed(timeout, 60000)
                return@post
            }
            if (status != BluetoothGatt.GATT_SUCCESS) { fail(context.getString(R.string.ble_send_failed)); return@post }
            if (pending.isNotEmpty()) pending.removeFirst()
            writing = false; pump()
        } }
        override fun onCharacteristicRead(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            finishPairRead(g, value, status)
        }
        override fun onCharacteristicChanged(g: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray) { accept(g, value) }
    }
    private fun finishPairRead(g: BluetoothGatt, value: ByteArray?, status: Int) { main.post {
        if (!current(g) || !readingPair) return@post
        readingPair = false; main.removeCallbacks(timeout)
        codexPairRead(if (status == BluetoothGatt.GATT_SUCCESS) value else null)
        pump()
    } }
    fun readSessionPair() { main.post { wantsPairRead = true; pump() } }
    private fun subscribe(g: BluetoothGatt) {
        if (setupStarted || !current(g)) return
        setupStarted = true
        val state = g.getService(SERVICE)?.getCharacteristic(STATE)
        val descriptor = state?.getDescriptor(CCC)
        if (state == null || descriptor == null || !g.setCharacteristicNotification(state, true)) { fail(context.getString(R.string.ble_missing_state)); return }
        val ok = g.writeDescriptor(descriptor, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE) == BluetoothStatusCodes.SUCCESS
        if (!ok) fail(context.getString(R.string.ble_notifications_failed))
    }
    private fun accept(g: BluetoothGatt, bytes: ByteArray) { main.post {
        if (!current(g)) return@post
        for (byte in bytes) {
            if (byte == 10.toByte()) {
                val line = incoming.toString(Charsets.UTF_8.name()); incoming.reset()
                if (line == "vibepier-available1 ${deviceKeys.device} 1") {
                    receivedState = true
                    report(if (deviceKeys.authorized) context.getString(R.string.ble_verifying) else context.getString(R.string.ble_awaiting_approval))
                } else when (val result = security.receive(line)) {
                    SecureControlClient.Result.Ready -> { receivedState = true; send(hello) }
                    SecureControlClient.Result.Incompatible -> { fail(context.getString(R.string.transport_incompatible)); return@post }
                    is SecureControlClient.Result.Message -> {
                        receivedState = true
                        report(context.getString(R.string.ble_connected))
                        received(String(result.payload, Charsets.UTF_8))
                    }
                    SecureControlClient.Result.Rejected -> Unit
                }
            } else incoming.write(byte.toInt())
            if (incoming.size() > SecureControlClient.MAX_FRAME) { fail(context.getString(R.string.ble_invalid_state)); return@post }
        }
    } }
    fun audioPriority(active: Boolean) { main.post {
        audioActive = active
        if (!active) pump()
        try { gatt?.requestConnectionPriority(if (active) BluetoothGatt.CONNECTION_PRIORITY_HIGH else BluetoothGatt.CONNECTION_PRIORITY_BALANCED) }
        catch (_: SecurityException) {}
    } }
    fun sendAudio(line: String) { main.post {
        // Drop whole stale packets, never partial newline frames. Control messages stay reliable.
        if (!active || !ready || pending.size > 3) return@post
        val wire = security.seal(line.toByteArray(Charsets.UTF_8)) ?: return@post
        enqueueLine(wire)
    } }
    private fun enqueueLine(line: String) {
        (line + "\n").toByteArray(Charsets.UTF_8).toList().chunked((mtu - 3).coerceIn(20, 512)).forEach {
            pending.addLast(it.toByteArray())
        }
        pump()
    }
    fun sendChat(line: String) { main.post {
        if (!active || !ready || !security.ready || chatPending.size >= 512) return@post
        chatPending.addLast(line); pump()
    } }
    fun send(line: String) { main.post {
        if (!active || !ready) return@post
        if (pending.size > 256) { fail(context.getString(R.string.ble_congested)); return@post }
        if (!security.ready) { requestSecureHello(); return@post }
        val wire = security.seal(line.toByteArray(Charsets.UTF_8)) ?: return@post
        enqueueLine(wire)
    } }

    private fun requestSecureHello() {
        if (!active || !ready) return
        val line = security.hello() ?: "vibepier-discover1 ${deviceKeys.device}"
        enqueueLine(line)
    }

    fun sendEnrollment(line: String) { main.post {
        if (!active || !ready || line.toByteArray(Charsets.UTF_8).size > 4096) return@post
        val value = try { org.json.JSONObject(line) } catch (_: Exception) { return@post }
        if (value.optString("type") != "vibepier-session-pair1" || value.optString("device") != deviceKeys.device ||
            value.optString("sender") != deviceKeys.device) return@post
        enqueueLine(line)
    } }

    fun authorizationChanged() { main.post {
        security.disconnect(); chatPending.clear()
        main.removeCallbacks(keepAlive)
        if (active && ready) keepAlive.run()
    } }

    private fun pump() {
        val g = gatt ?: return; val c = command ?: return
        if (writing || readingPair || pairing || !ready) return
        if (pending.isEmpty() && !audioActive && chatPending.isNotEmpty()) {
            val line = chatPending.removeFirst()
            val wire = security.seal(line.toByteArray(Charsets.UTF_8))
            if (wire != null) enqueueLine(wire) else { chatPending.clear(); requestSecureHello() }
            return
        }
        if (pending.isEmpty()) {
            if (wantsPairRead) {
                wantsPairRead = false
                val pair = g.getService(SERVICE)?.getCharacteristic(CODEX_PAIR)
                if (pair == null || !g.readCharacteristic(pair)) codexPairRead(null)
                else { readingPair = true; main.postDelayed(timeout, 10000) }
            }
            return
        }
        writing = true
        val ok = g.writeCharacteristic(c, pending.first(), BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT) == BluetoothStatusCodes.SUCCESS
        if (!ok) fail(context.getString(R.string.ble_write_failed)) else main.postDelayed(timeout, if (receivedState) 10000 else 60000)
    }
    private fun disconnect() {
        generation++
        security.disconnect()
        main.removeCallbacks(timeout)
        main.removeCallbacks(keepAlive)
        stopScan()
        try { gatt?.disconnect(); gatt?.close() } catch (_: SecurityException) {}
        gatt = null; command = null; name = null; ready = false; writing = false; pairing = false; setupStarted = false
        receivedState = false
        mtu = 23; pending.clear(); chatPending.clear(); audioActive = false; incoming.reset()
        wantsPairRead = false; readingPair = false
    }
    private fun fail(message: String) {
        disconnect(); report(message)
        if (active) main.postDelayed({ scan() }, 3000)
    }
    fun close() { main.post { active = false; disconnect(); context.unregisterReceiver(bondReceiver) } }
}
