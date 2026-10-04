package io.github.junweiup.vibepier.remote.core.transport

import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionTransport

import android.content.Context
import io.github.junweiup.vibepier.remote.core.security.DeviceKeys
import io.github.junweiup.vibepier.remote.core.security.SecureControlClient
import io.github.junweiup.vibepier.remote.core.security.ControlProtocol
import android.os.SystemClock
import org.json.JSONObject
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.ScheduledFuture
import java.util.UUID

/**
 * Sends one-line UDP datagrams and receives foreground-app status from VibePier.
 * Each key event goes out three times, and the Mac drops the repeats by
 * sender and sequence number.
 *
 *     vibepier1 <sender> <seq> <control> <down|up|step> <keys>
 *
 * `keys` is the hotkey bound on the phone, such as `cmd+return`, and the Mac
 * presses exactly that. The same lines also travel over Bluetooth ([BluetoothLink])
 * or the cloud relay ([RelayLink]), each sent once because those links are reliable.
 */
class RemoteSender(context: Context, private val simulateLaunchLoss: Boolean = false) : SessionTransport {
    private val sessionClientDelegate = lazy { io.github.junweiup.vibepier.remote.core.session.SessionClient(context.applicationContext, this, completionNotifications = !io.github.junweiup.vibepier.remote.BuildConfig.DESIGN_REVIEW) }
    val sessionClient get() = sessionClientDelegate.value

    companion object {
        const val PORT = 47800
        private val REPEAT_DELAYS_MS = longArrayOf(0, 40, 120)
        /** Same public STUN servers as the Mac; any one answering is enough. */
        private val STUN_SERVERS = listOf("stun.miwifi.com:3478", "stun.chat.bilibili.com:3478", "stun.l.google.com:19302")

        /** `1.2.3.4:5` or `[2408::1]:5`; numeric only, never resolves names. */
        fun parseCandidate(text: String): InetSocketAddress? {
            val colon = text.lastIndexOf(':')
            if (colon <= 0 || text.length > 64) return null
            val port = text.substring(colon + 1).toIntOrNull()?.takeIf { it in 1..65535 } ?: return null
            val host = text.substring(0, colon).removePrefix("[").removeSuffix("]")
            if (!host.all { it.isDigit() || it == '.' || it == ':' || it.lowercaseChar() in 'a'..'f' }) return null
            return try { InetSocketAddress(InetAddress.getByName(host), port) } catch (_: Exception) { null }
        }

        /** IPv4 `host:port` from a STUN Binding response (XOR-MAPPED-ADDRESS, else MAPPED-ADDRESS). */
        fun stunMapping(data: ByteArray, length: Int): String? {
            var i = 20; var fallback: String? = null
            while (i + 4 <= length) {
                val type = (data[i].toInt() and 0xFF shl 8) or (data[i + 1].toInt() and 0xFF)
                val size = (data[i + 2].toInt() and 0xFF shl 8) or (data[i + 3].toInt() and 0xFF)
                val v = i + 4
                if (v + size > length) break
                if ((type == 0x20 || type == 0x01) && size >= 8 && data[v + 1].toInt() == 1) {
                    val xor = type == 0x20
                    val cookie = intArrayOf(0x21, 0x12, 0xA4, 0x42)
                    var port = (data[v + 2].toInt() and 0xFF shl 8) or (data[v + 3].toInt() and 0xFF)
                    if (xor) port = port xor 0x2112
                    val ip = (0..3).joinToString(".") { ((data[v + 4 + it].toInt() and 0xFF) xor (if (xor) cookie[it] else 0)).toString() }
                    if (xor) return "$ip:$port"
                    fallback = "$ip:$port"
                }
                i = v + size + (4 - size % 4) % 4
            }
            return fallback
        }
    }

    private val resources = context.resources

    /** The Mac's address. Empty sends a broadcast to the local network. */
    @Volatile var host: String = ""
    @Volatile var lastKnownHost: String = ""
    @Volatile override var mode: String = "wifi"; private set
    val connectedHost: String? get() = when (mode) {
        "bluetooth" -> bluetooth.name
        "relay" -> direct?.let { resources.getString(R.string.transport_direct) } ?: resources.getString(R.string.transport_relay).takeIf { relay.peerOnline && lastReply != 0L }
        else -> selected?.hostAddress
    }
    override val enrollmentReady: Boolean get() = mode == "bluetooth" && bluetooth.enrollmentReady
    override val enrollmentConnectionID: String? get() = if (mode == "bluetooth") bluetooth.enrollmentConnectionID else null
    val bluetoothStatus: String get() = bluetooth.status
    val relayStatus: String get() = relay.status
    val wifiStatus: String get() = resources.getString(if (wifiSecurity.incompatible) R.string.transport_incompatible else R.string.wifi_same_network)
    val phoneAudioSupported: Boolean get() = when (mode) {
        "bluetooth" -> bluetooth.phoneAudioSupported
        "relay" -> direct != null && directSecurity.supports(ControlProtocol.PHONE_AUDIO)
        else -> wifiSecurity.supports(ControlProtocol.PHONE_AUDIO)
    }
    /** Relay mode whose keys and audio currently go straight over UDP (see [startDirect]). */
    override val binaryHost: String? get() = if (mode == "wifi") selected?.hostAddress else if (mode == "relay") direct?.address?.hostAddress else null
    val isDirect: Boolean get() = mode == "relay" && direct != null
    /** Saved from the pairing code; applied on the next watch. */
    @Volatile var relaySettings: RelayLink.Settings? = null
    @Volatile var onConnectionChanged: () -> Unit = {}
    data class Application(val bundleID: String, val name: String, val iconPNG: String = "")
    data class AppShortcut(val slot: Int, val bundleID: String, val name: String, val iconPNG: String, val available: Boolean)
    @Volatile var onShortcuts: (List<AppShortcut>) -> Unit = {}
    @Volatile var onMicrophoneState: (JSONObject) -> Unit = {}
    @Volatile var onBindings: (JSONObject) -> Unit = {}
    @Volatile var onBindingAck: (JSONObject) -> Unit = {}
    @Volatile var onBindingsReady: () -> Unit = {}
    @Volatile override var onSessionFrame: (JSONObject) -> Unit = {}
    @Volatile override var onSessionPair: (ByteArray?) -> Unit = {}
    private val configurationCache = RemoteConfigurationCache(context)
    private var bindingSnapshot: JSONObject? = null
    @Volatile private var displayedShortcuts = emptyList<AppShortcut>()
    private var displayedShortcutsRevision = ""
    val cachedShortcuts get() = displayedShortcuts
    private var bindingsRevision = ""
    private var bindingsComplete = false
    private var bindingsRequestedAt = 0L
    private var bindingParts: Array<String?>? = null
    private val shortcutSnapshot = ShortcutSnapshot<AppShortcut>()
    private val iconChunks = mutableMapOf<Int, IconChunks>()
    private var shortcutsRequestedAt = 0L
    private var currentApplication: Application? = null
    private var currentAppRevision = ""
    private var currentIconChunks: IconChunks? = null
    private var currentIconRequestedAt = 0L
    private val currentIcons = linkedMapOf<String, Pair<String, String>>()
    @Volatile var onApplication: (Application?) -> Unit = {}
    @Volatile private var selected: InetAddress? = null
    @Volatile private var watching = false
    @Volatile private var lastReply = 0L
    private var watchTask: ScheduledFuture<*>? = null
    private var lastStamp = -1L
    /** Direct path: the relay introduces both ends, then UDP flows phone↔Mac without it. */
    @Volatile private var direct: InetSocketAddress? = null
    @Volatile private var directReply = 0L
    @Volatile private var directToken: String? = null
    private var directAttemptAt = 0L
    @Volatile private var stunMapped: String? = null
    private val stunTransactions = java.util.Collections.synchronizedSet(mutableSetOf<String>())

    // Session identity also gates key deduplication and relay/direct replies across phones.
    private val deviceKeys = DeviceKeys(context)
    private val sender = deviceKeys.device
    private val wifiSecurity = SecureControlClient(sender, deviceKeys::controlKeys)
    private val directSecurity = SecureControlClient(sender, deviceKeys::controlKeys)
    @Volatile private var authenticatedWiFi: InetAddress? = null
    private val executor = Executors.newSingleThreadScheduledExecutor()
    private val directProbes = DirectProbeScheduler()
    private val socket = DatagramSocket().apply { broadcast = true }
    private val bluetooth: BluetoothLink = BluetoothLink(context.applicationContext, received = { line ->
        if (mode == "bluetooth" && watching) {
            try {
                val message = JSONObject(line)
                if (message.optString("type") == "vibepier-app1" && message.optString("sender") == sender) {
                    receiveApplicationStatus(message)
                    receiveBindingsRevision(message)
                    receiveRevision(message)
                } else if (message.optString("sender") == sender && receiveBindingsMessage(message)) {
                    // Shared configuration response.
                } else if (message.optString("type") == "vibepier-slot1" && message.optString("sender") == sender) {
                    receiveShortcut(message)
                }
            } catch (e: Exception) { TransportLog.warning(TransportLog.Event.BLUETOOTH_STATUS, e) }
        }
    }, changed = {
        if (mode == "bluetooth") {
            if (!bluetooth.authenticated) {
                synchronized(this) { if (!bindingsComplete) bindingParts = null; bindingsRequestedAt = 0 }
                clearCurrentApplication()
            }
            notifyConnectionChanged()
        }
    }, codexPairRead = { onSessionPair(it) })
    private val relay: RelayLink = RelayLink(context, received = { line ->
        if (mode == "relay" && watching) {
            try { receiveRelay(JSONObject(line)) } catch (e: Exception) { TransportLog.warning(TransportLog.Event.RELAY_STATUS, e) }
        }
    }, changed = {
        // RelayLink may invoke its callback while holding the transport lock.
        // Keep probe cancellation/state changes off that lock to avoid lock inversion.
        try {
            executor.execute {
                if (mode == "relay" && watching) {
                    synchronized(this) {
                        if (DirectPathHealth.shouldClearApplication(relay.peerOnline, direct != null, directReply, SystemClock.elapsedRealtime())) {
                            if (direct != null) dropDirect()
                            resetRelayPeer()
                        }
                    }
                    notifyConnectionChanged()
                }
            }
        } catch (_: RejectedExecutionException) { /* Sender is closing. */ }
    })

    init {
        Thread({
            val buffer = ByteArray(SecureControlClient.MAX_FRAME + 1)
            while (!socket.isClosed) {
                try {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    if (receiveDirect(packet)) continue
                    if (!watching || mode != "wifi" || packet.port != PORT) continue
                    val expected = host.trim().takeIf { it.isNotEmpty() }?.let(InetAddress::getByName)
                    if (expected != null && expected != packet.address) continue
                    if (authenticatedWiFi != null && authenticatedWiFi != packet.address) continue
                    val wire = String(packet.data, 0, packet.length, Charsets.UTF_8)
                    val plaintext = when (val result = wifiSecurity.receive(wire)) {
                        SecureControlClient.Result.Ready -> {
                            authenticatedWiFi = packet.address
                            executor.execute { transmit("vibepier-watch1 $sender".toByteArray(), packet.address) }
                            continue
                        }
                        SecureControlClient.Result.Incompatible -> {
                            synchronized(this) { selected = null; authenticatedWiFi = null; lastReply = 0; lastStamp = -1; clearCurrentApplication() }
                            notifyConnectionChanged()
                            continue
                        }
                        is SecureControlClient.Result.Message -> result.payload
                        SecureControlClient.Result.Rejected -> continue
                    }
                    if (authenticatedWiFi != packet.address) continue
                    val message = JSONObject(String(plaintext, Charsets.UTF_8))
                    if (message.optString("sender") != sender) continue
                    synchronized(this) {
                        if (selected != null && selected != packet.address) return@synchronized
                        if (selected == packet.address && receiveBindingsMessage(message)) return@synchronized
                        if (message.optString("type") == "vibepier-slot1") {
                            if (selected == packet.address) receiveShortcut(message)
                            return@synchronized
                        }
                        if (message.optString("type") != "vibepier-app1") return@synchronized
                        val stamp = message.getLong("stamp")
                        if (stamp < lastStamp) return@synchronized
                        selected = packet.address
                        lastKnownHost = packet.address.hostAddress ?: ""
                        lastStamp = stamp
                        lastReply = SystemClock.elapsedRealtime()
                        receiveApplicationStatus(message)
                        executor.execute { transmit("vibepier-ack1 $sender".toByteArray(), packet.address) }
                        receiveBindingsRevision(message)
                    receiveRevision(message)
                    }
                } catch (e: Exception) {
                    if (!socket.isClosed) TransportLog.warning(TransportLog.Event.UDP_STATUS, e)
                }
            }
        }, "vibepier-status").apply { isDaemon = true; start() }
    }

    @Synchronized fun ensureWatching() {
        if (!watching) watch(true)
    }

    @Synchronized fun watch(active: Boolean) {
        watching = active
        wifiSecurity.disconnect(); authenticatedWiFi = null
        // Keep same-Mac configuration and icon caches across background/foreground transitions.
        // The next status's revisions decide whether any data actually needs fetching.
        bindingsRequestedAt = 0; shortcutsRequestedAt = 0
        watchTask?.cancel(false)
        watchTask = null
        if (mode == "bluetooth") {
            clearCurrentApplication()
            bluetooth.watch(active, "vibepier-watch1 $sender")
            return
        }
        if (mode == "relay") {
            lastReply = 0; lastStamp = -1
            clearCurrentApplication()
            dropDirect(); directAttemptAt = 0
            if (!active) { relay.stop(); return }
            relay.start(relaySettings)
            var lastSent = 0L
            var lastDirectSent = 0L
            watchTask = executor.scheduleWithFixedDelay({
                val now = SystemClock.elapsedRealtime()
                var staleRelay = false
                synchronized(this) {
                    val directFresh = DirectPathHealth.isFresh(direct != null, directReply, now)
                    if (direct != null && !directFresh) {
                        dropDirect()
                        if (!relay.peerOnline) resetRelayPeer()
                    }
                    if (lastReply != 0L && now - lastReply > DirectPathHealth.REPLY_TIMEOUT_MS && !directFresh) {
                        staleRelay = relay.peerOnline
                        resetRelayPeer()
                    }
                }
                // A half-open mobile socket can keep peerOnline true long after traffic stops.
                // Reuse the existing 12-second application lease instead of waiting 75 seconds for TCP.
                if (staleRelay) relay.reconnect()
                if (relay.peerOnline && (lastReply == 0L || now - lastSent >= 4000)) {
                    lastSent = now
                    relay.send("vibepier-watch1 $sender")
                }
                val path = direct
                if (path != null && now - lastDirectSent >= 4000) {
                    lastDirectSent = now
                    transmit("vibepier-watch1 $sender".toByteArray(), path)
                } else if (path == null && lastReply != 0L && (directAttemptAt == 0L || now - directAttemptAt >= 60000)) {
                    directAttemptAt = now
                    startDirect()
                }
            }, 0, 1, TimeUnit.SECONDS)
            return
        }
        if (!active) {
            selected = null; lastReply = 0; lastStamp = -1
            clearCurrentApplication(); notifyConnectionChanged()
            return
        }
        if (active) {
            selected = null; lastReply = 0; lastStamp = -1
            clearCurrentApplication()
            var lastSent = 0L
            watchTask = executor.scheduleWithFixedDelay({
                synchronized(this) {
                    if (lastReply != 0L && SystemClock.elapsedRealtime() - lastReply > 12000) {
                        selected = null; lastReply = 0; lastStamp = -1
                        if (!wifiSecurity.ready) { wifiSecurity.disconnect(); authenticatedWiFi = null }
                        if (!bindingsComplete) bindingParts = null; bindingsRequestedAt = 0
                        clearCurrentApplication()
                    }
                }
                val now = SystemClock.elapsedRealtime()
                if (selected == null || now - lastSent >= 4000) {
                    lastSent = now
                    val bytes = "vibepier-watch1 $sender".toByteArray()
                    val known = lastKnownHost.takeIf { host.isBlank() && it.isNotBlank() }
                    if (selected == null && known != null) {
                        try { transmit(bytes, InetAddress.getByName(known)) } catch (_: Exception) {}
                    }
                    transmit(bytes, selected)
                }
            }, 0, 1, TimeUnit.SECONDS)
        }
    }

    private fun configurationScope(): String {
        val endpoint = when (mode) {
            "relay" -> "${relaySettings?.url}|${relaySettings?.room}"
            "bluetooth" -> "bluetooth"
            else -> host.ifBlank { lastKnownHost }
        }
        return java.security.MessageDigest.getInstance("SHA-256").digest("$mode|$endpoint".toByteArray()).joinToString("") { "%02x".format(it.toInt() and 255) }
    }
    private fun restoreConfigurationCache() {
        val cached = configurationCache.read(configurationScope()) ?: return
        bindingSnapshot = cached.bindings
        bindingsRevision = cached.bindings?.optString("revision") ?: ""
        bindingsComplete = bindingsRevision.isNotBlank()
        displayedShortcuts = cached.slots; displayedShortcutsRevision = cached.revision
        if (cached.slots.isNotEmpty()) {
            shortcutSnapshot.begin(cached.revision, cached.slots.size)
            for (slot in cached.slots) shortcutSnapshot.append(cached.revision, slot.slot, cached.slots.size, slot)
            onShortcuts(cached.slots)
        }
    }
    private fun saveConfigurationCache() = configurationCache.save(configurationScope(), displayedShortcutsRevision, displayedShortcuts, bindingSnapshot)
    private fun clearConfigurationCache() {
        bindingSnapshot = null; displayedShortcuts = emptyList(); displayedShortcutsRevision = ""
        bindingsRevision = ""; bindingsComplete = false; bindingParts = null; bindingsRequestedAt = 0
        shortcutSnapshot.clear(); iconChunks.clear(); shortcutsRequestedAt = 0
        currentIcons.clear(); clearCurrentApplication()
        onShortcuts(emptyList())
    }
    @Synchronized fun changeHost(value: String) {
        host = value
        clearConfigurationCache(); restoreConfigurationCache()
        selected = null; lastReply = 0; lastStamp = -1
        clearCurrentApplication()
        if (watching) watch(true)
    }

    @Synchronized fun changeMode(value: String) {
        require(value == "wifi" || value == "bluetooth" || value == "relay")
        if (mode == value && watching) return
        val active = watching
        watch(false)
        mode = value
        clearConfigurationCache(); restoreConfigurationCache()
        selected = null
        clearCurrentApplication()
        watch(active)
        notifyConnectionChanged()
    }

    fun send(control: String, event: String, keys: String, applicationID: String? = null) {
        val context = applicationID?.takeIf { it.isNotBlank() }?.let { " app=$it" } ?: ""
        val bytes = "vibepier1 $sender ${deviceKeys.nextSequence()} $control $event $keys$context".toByteArray()
        sendBytes(bytes, release = event == "up")
    }

    fun launchApplication(slot: AppShortcut, action: String = "activate") {
        if (simulateLaunchLoss) return // Isolated design-review fault injection; release always passes false.
        if (!slot.available || slot.bundleID.isBlank()) return
        require(action == "activate" || action == "hide")
        val suffix = if (action == "hide") " action=hide" else ""
        sendBytes("vibepier-launch1 $sender ${deviceKeys.nextSequence()} ${slot.slot} ${slot.bundleID}$suffix".toByteArray())
    }

    fun microphone(action: String, session: String, keys: String = "", app: String = "", rate: Int = 16000) {
        if (mode == "bluetooth") bluetooth.audioPriority(action == "begin")
        sendBinding(JSONObject().put("type", "vibepier-mic1").put("action", action).put("session", session)
            .put("button", "talk").put("keys", keys).put("app", app).put("rate", rate)
            .put("packetMs", if (mode == "bluetooth") 60 else 20))
    }

    fun microphoneFrame(session: String, sequence: Int, data: ByteArray) {
        if (!watching) return
        val line = "vibepier-audio1 $sender $session $sequence ${android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)}"
        if (mode == "bluetooth") bluetooth.sendAudio(line)
        else if (mode == "relay") direct?.let { path -> executor.execute { transmit(line.toByteArray(), path) } } // Never relayed.
        else selected?.let { destination -> executor.execute { transmit(line.toByteArray(), destination) } }
    }

    override fun sendBinding(message: JSONObject) {
        val copy = JSONObject(message.toString()).put("sender", sender)
        val path = direct
        if (mode == "relay" && path != null && (copy.optString("type") == "vibepier-mic1" || directSecurity.ready && copy.optString("type") == "vibepier-session1" && (!copy.has("upload") || copy.optInt("fragmentChars", 7200) == 512)))
            queueDatagram(copy.toString().toByteArray(), path, directSecurity, "relay", copy.optString("action") == "end")
        else if (mode == "relay") relay.send(copy.toString())
        else if (mode == "bluetooth" && copy.optString("type") == "vibepier-session1") bluetooth.sendChat(copy.toString())
        else sendBytes(copy.toString().toByteArray(), release = copy.optString("type") == "vibepier-mic1" && copy.optString("action") == "end")
    }
    override fun requestSessionPair(device: String, name: String) {
        if (mode != "bluetooth") return
        bluetooth.sendEnrollment(JSONObject().put("type", "vibepier-session-pair1").put("sender", sender).put("device", device).put("name", name).toString())
    }
    override fun readSessionPair() { if (mode == "bluetooth") bluetooth.readSessionPair() }
    override fun authorizationChanged() {
        bluetooth.authorizationChanged()
        relay.authorizationChanged()
        wifiSecurity.disconnect(); directSecurity.disconnect()
    }

    @Synchronized private fun receiveBindingsRevision(message: JSONObject) {
        val revision = message.optString("bindingsRevision")
        if (revision.isBlank()) return
        if (revision != bindingsRevision) {
            bindingsRevision = revision; bindingsComplete = false; bindingParts = null; bindingsRequestedAt = 0
        }
        if (bindingsComplete) { onBindingsReady(); return }
        val now = SystemClock.elapsedRealtime()
        if (bindingsRequestedAt == 0L || now - bindingsRequestedAt >= 1500) {
            bindingsRequestedAt = now
            sendBinding(JSONObject().put("type", "vibepier-bindings-get1"))
        }
    }

    @Synchronized private fun receiveBindingsMessage(message: JSONObject): Boolean {
        when (message.optString("type")) {
            "vibepier-current1" -> { receiveCurrentIcon(message); return true }
            "vibepier-session1" -> { onSessionFrame(message); return true }
            "vibepier-mic-state1" -> { onMicrophoneState(message); return true }
            "vibepier-binding-ack1" -> { onBindingAck(message); return true }
            "vibepier-bindings1" -> {
                if (message.optString("revision") != bindingsRevision || bindingsComplete) return true
                val count = message.optInt("parts")
                val index = message.optInt("part", -1)
                val data = message.optString("data")
                if (count !in 1..1024 || index !in 0 until count || data.length > 900) return true
                val parts = bindingParts ?: arrayOfNulls<String>(count).also { bindingParts = it }
                if (parts.size != count) return true
                parts[index] = data
                if (parts.all { it != null }) {
                    val json = String(android.util.Base64.decode(parts.joinToString("") { it!! }, android.util.Base64.DEFAULT), Charsets.UTF_8)
                    val snapshot = JSONObject(json)
                    if (snapshot.optString("revision") == bindingsRevision) {
                        bindingsComplete = true; bindingParts = null; bindingSnapshot = snapshot
                        saveConfigurationCache(); onBindings(snapshot)
                    }
                }
                return true
            }
        }
        return false
    }

    @Synchronized private fun clearCurrentApplication() {
        currentApplication = null; currentAppRevision = ""; currentIconChunks = null; currentIconRequestedAt = 0
        onApplication(null)
        updateSessionConnection()
    }

    @Synchronized private fun receiveApplicationStatus(message: JSONObject) {
        val bundle = message.getString("bundleID")
        val name = message.getString("name")
        val revision = message.optString("currentAppRevision")
        if (bundle != currentApplication?.bundleID || revision != currentAppRevision) {
            currentAppRevision = revision; currentIconChunks = null; currentIconRequestedAt = 0
        }
        val cached = currentIcons[bundle]?.also {
            currentIcons.remove(bundle); currentIcons[bundle] = it
        }
        currentApplication = Application(bundle, name, cached?.second ?: "")
        onApplication(currentApplication)
        updateSessionConnection()
        if (bundle.isBlank() || revision.isBlank() || cached?.first == revision) return
        val now = SystemClock.elapsedRealtime()
        if (currentIconRequestedAt == 0L || now - currentIconRequestedAt >= 1500) {
            currentIconRequestedAt = now
            sendBytes("vibepier-current1 $sender".toByteArray())
        }
    }

    @Synchronized private fun receiveCurrentIcon(message: JSONObject) {
        val app = currentApplication ?: return
        if (message.optString("sender") != sender || message.optString("bundleID") != app.bundleID ||
            message.optString("revision") != currentAppRevision || currentAppRevision.isBlank()) return
        val count = message.optInt("iconParts", 1)
        if (count !in 1..128) return
        val chunks = currentIconChunks ?: IconChunks(count).also { currentIconChunks = it }
        if (chunks.count != count) return
        val icon = chunks.append(message.optInt("iconPart", 0), message.optString("iconPNG")) ?: return
        currentIconChunks = null
        currentIcons.remove(app.bundleID)
        currentIcons[app.bundleID] = currentAppRevision to icon
        while (currentIcons.size > 16) currentIcons.remove(currentIcons.keys.first())
        currentApplication = app.copy(iconPNG = icon)
        onApplication(currentApplication)
        updateSessionConnection()
    }

    @Synchronized private fun receiveRevision(message: JSONObject) {
        val revision = message.optString("shortcutsRevision")
        if (revision.isEmpty()) return
        val total = message.optInt("shortcutsCount", 5)
        if (total <= 0) return
        if (shortcutSnapshot.begin(revision, total)) {
            iconChunks.clear()
            shortcutsRequestedAt = 0
            // Keep the prior complete list visible until the full new revision arrives.
        }
        val now = SystemClock.elapsedRealtime()
        if (!shortcutSnapshot.complete && (shortcutsRequestedAt == 0L || now - shortcutsRequestedAt >= 1500)) {
            shortcutsRequestedAt = now
            val line = "vibepier-slots1 $sender"
            if (mode == "bluetooth") bluetooth.send(line)
            else if (mode == "relay") relay.send(line)
            else selected?.let { target -> executor.execute { transmit(line.toByteArray(), target) } }
        }
    }

    @Synchronized private fun receiveShortcut(message: JSONObject) {
        val revision = message.optString("revision")
        if (shortcutSnapshot.revision.isEmpty() || revision != shortcutSnapshot.revision) return
        val total = message.optInt("count", 5)
        val slot = message.optInt("slot", -1)
        if (total != shortcutSnapshot.count || slot !in 0 until total || shortcutSnapshot.contains(slot)) return
        val count = message.optInt("iconParts", 1)
        val part = message.optInt("iconPart", 0)
        if (count !in 1..128) return
        val chunks = iconChunks.getOrPut(slot) { IconChunks(count) }
        if (chunks.count != count) return
        val icon = chunks.append(part, message.optString("iconPNG")) ?: return
        iconChunks.remove(slot)
        val entry = AppShortcut(slot, message.getString("bundleID"), message.getString("name"),
            icon, message.optBoolean("available"))
        shortcutSnapshot.append(revision, slot, total, entry)?.let { entries ->
            displayedShortcuts = entries; displayedShortcutsRevision = revision
            saveConfigurationCache(); onShortcuts(displayedShortcuts)
        }
    }

    /** Status from the Mac over the relay; the same messages the Bluetooth link carries. */
    @Synchronized private fun receiveRelay(message: JSONObject, viaDirect: Boolean = false) {
        if (message.optString("sender") != sender) return
        if (receiveBindingsMessage(message)) return
        when (message.optString("type")) {
            "vibepier-direct-answer1" -> answerDirect(message)
            "vibepier-slot1" -> receiveShortcut(message)
            "vibepier-app1" -> {
                val stamp = message.getLong("stamp")
                if (stamp < lastStamp) return
                lastStamp = stamp
                val first = lastReply == 0L
                lastReply = SystemClock.elapsedRealtime()
                if (!viaDirect) relay.send("vibepier-ack1 $sender")
                receiveApplicationStatus(message)
                if (first) notifyConnectionChanged()
                receiveBindingsRevision(message)
                receiveRevision(message)
            }
        }
    }

    @Synchronized private fun resetRelayPeer() {
        if (lastReply == 0L && lastStamp == -1L) return
        lastReply = 0; lastStamp = -1
        if (!bindingsComplete) bindingParts = null; bindingsRequestedAt = 0
        clearCurrentApplication()
    }

    private fun sendBytes(bytes: ByteArray, release: Boolean = false) {
        if (mode == "bluetooth") { bluetooth.send(String(bytes, Charsets.UTF_8)); return }
        val path = direct
        if (mode == "relay" && path != null) {
            queueDatagram(bytes, path, directSecurity, "relay", release)
            return
        }
        if (mode == "relay") { relay.send(String(bytes, Charsets.UTF_8)); return }
        val destination = selected ?: return
        queueDatagram(bytes, InetSocketAddress(destination, PORT), wifiSecurity, "wifi", release)
    }

    private fun queueDatagram(bytes: ByteArray, destination: InetSocketAddress, channel: SecureControlClient, selectedMode: String, release: Boolean) {
        if (!watching) return
        val sealed = channel.seal(bytes) ?: return
        val frame = sealed.toByteArray(Charsets.UTF_8)
        // Seal now: a final release must still leave during the short shutdown drain.
        // Repeats use the identical authenticated packet, so only one may execute.
        val delays = if (sealed.startsWith("vibepier-bulk1 ")) longArrayOf(0) else REPEAT_DELAYS_MS
        for (delay in delays) executor.schedule({
            if (!release && (!watching || mode != selectedMode)) return@schedule
            try { socket.send(DatagramPacket(frame, frame.size, destination)) }
            catch (_: Exception) { if (!socket.isClosed) TransportLog.warning(TransportLog.Event.UDP_CONTROL) }
        }, delay, TimeUnit.MILLISECONDS)
    }

    private fun transmit(bytes: ByteArray, destination: InetAddress?) {
        if (!watching || mode != "wifi") return
        try {
            val target: InetAddress
            val wire: ByteArray
            if (!wifiSecurity.ready) {
                if (!String(bytes, Charsets.UTF_8).startsWith("vibepier-watch1 ")) return
                authenticatedWiFi = null
                val hello = wifiSecurity.hello() ?: return
                target = destination ?: InetAddress.getByName(host.trim().ifEmpty { "255.255.255.255" })
                wire = hello.toByteArray(Charsets.UTF_8)
            } else {
                target = authenticatedWiFi ?: return
                if (destination != null && destination != target) return
                wire = wifiSecurity.seal(bytes)?.toByteArray(Charsets.UTF_8) ?: return
            }
            socket.send(DatagramPacket(wire, wire.size, target, PORT))
        } catch (_: Exception) { TransportLog.warning(TransportLog.Event.UDP_SEND) }
    }

    // Direct path (docs/relay-protocol.md): STUN for our public mapping, offer over the
    // relay, then both ends send `vibepier-punch1 <sender> <token>` until one gets through.

    private fun startDirect() {
        val token = RelayLink.hex(RelayLink.randomBytes(16))
        val accepted = directProbes.start(token, accepted = {
            directToken = token
            stunMapped = null
            stunTransactions.clear()
        }) { attempt ->
            for (server in STUN_SERVERS) {
                if (!attempt.isActive()) break
                try {
                    val (host, port) = server.split(':')
                    // Platform DNS may block despite interruption; it must never run on watch/key scheduling.
                    val address = Inet4Address.getByName(host)
                    attempt.emit {
                        if (watching && mode == "relay" && directToken == token) {
                            val transaction = RelayLink.randomBytes(12)
                            stunTransactions += RelayLink.hex(transaction)
                            val request = byteArrayOf(0, 1, 0, 0, 0x21, 0x12, 0xA4.toByte(), 0x42) + transaction
                            socket.send(DatagramPacket(request, request.size, address, port.toInt()))
                        }
                    }
                } catch (e: Exception) { TransportLog.warning(TransportLog.Event.STUN, e) }
            }
        }
        if (!accepted) return
        // Local candidates remain usable even while a public STUN lookup is slow.
        executor.schedule({
            directProbes.emit(token) {
                if (directToken == token && watching && mode == "relay") {
                    val candidates = org.json.JSONArray()
                    stunMapped?.let(candidates::put)
                    localCandidates().forEach(candidates::put)
                    TransportLog.info(TransportLog.Event.DIRECT_OFFER)
                    relay.send(JSONObject().put("type", "vibepier-direct-offer1").put("sender", sender)
                        .put("token", token).put("candidates", candidates).toString())
                }
            }
        }, 800, TimeUnit.MILLISECONDS)
    }

    private fun localCandidates(): List<String> = try {
        val port = socket.localPort
        NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback && !it.name.startsWith("tun") }
            .flatMap { it.inetAddresses.toList() }.mapNotNull { address ->
                when {
                    address is Inet6Address && !address.isLinkLocalAddress && !address.isSiteLocalAddress &&
                        (address.address[0].toInt() and 0xE0) == 0x20 -> "[${address.hostAddress?.substringBefore('%')}]:$port"
                    address is Inet4Address && address.isSiteLocalAddress -> "${address.hostAddress}:$port"
                    else -> null
                }
            }.take(6)
    } catch (e: Exception) { emptyList() }

    private fun answerDirect(message: JSONObject) {
        val token = directToken ?: return
        if (message.optString("token") != token || direct != null) return
        val list = message.optJSONArray("candidates") ?: return
        val targets = (0 until minOf(list.length(), 8)).mapNotNull { parseCandidate(list.optString(it)) }
        TransportLog.info(TransportLog.Event.DIRECT_ANSWER)
        val punch = "vibepier-punch1 $sender $token".toByteArray()
        for (delay in longArrayOf(0, 150, 400, 800, 1500, 2500, 4000)) {
            executor.schedule({
                directProbes.emit(token) {
                    if (direct == null && directToken == token && watching && mode == "relay") targets.forEach { transmit(punch, it) }
                }
            }, delay, TimeUnit.MILLISECONDS)
        }
    }

    /** Handles STUN replies, punches and direct-path status; true when the packet was consumed. */
    private fun receiveDirect(packet: DatagramPacket): Boolean {
        val data = packet.data; val length = packet.length
        if (length >= 20 && data[0].toInt() == 1 && data[1].toInt() == 1 && data[4].toInt() == 0x21 && data[5].toInt() == 0x12) {
            val transaction = RelayLink.hex(data.copyOfRange(8, 20))
            if (stunTransactions.remove(transaction)) stunMapping(data, length)?.let { stunMapped = it }
            return true
        }
        if (mode != "relay" || !watching) return false
        val from = packet.socketAddress as? InetSocketAddress ?: return false
        val text = String(data, 0, length, Charsets.UTF_8)
        val token = directToken
        if (text.startsWith("vibepier-punch")) {
            val parts = text.trim().split(' ')
            if (token == null || parts.size != 3 || parts[1] != sender || parts[2] != token) return true
            directProbes.emit(token) {
                if (parts[0] == "vibepier-punch1") transmit("vibepier-punch1 $sender $token".toByteArray(), from)
                else if (parts[0] == "vibepier-punch-ok1" && direct == null) {
                    directSecurity.disconnect()
                    direct = from; directReply = SystemClock.elapsedRealtime()
                    TransportLog.info(TransportLog.Event.DIRECT_CONNECTED)
                    transmit("vibepier-watch1 $sender".toByteArray(), from)
                    notifyConnectionChanged()
                }
            }
            return true
        }
        if (from != direct) return true
        try {
            val plaintext = when (val result = directSecurity.receive(text)) {
                SecureControlClient.Result.Ready -> { transmit("vibepier-watch1 $sender".toByteArray(), from); return true }
                SecureControlClient.Result.Incompatible -> { dropDirect(); return true }
                is SecureControlClient.Result.Message -> result.payload
                SecureControlClient.Result.Rejected -> return true
            }
            val message = JSONObject(String(plaintext, Charsets.UTF_8))
            if (message.optString("sender") != sender) return true
            directReply = SystemClock.elapsedRealtime()
            if (message.optString("type") == "vibepier-app1") transmit("vibepier-ack1 $sender".toByteArray(), from)
            receiveRelay(message, viaDirect = true)
        } catch (e: Exception) { TransportLog.warning(TransportLog.Event.DIRECT_STATUS, e) }
        return true
    }

    private fun dropDirect() {
        directProbes.cancel()
        val had = direct != null
        direct = null; directToken = null
        directSecurity.disconnect()
        stunMapped = null; stunTransactions.clear()
        if (had) { TransportLog.info(TransportLog.Event.DIRECT_LOST); notifyConnectionChanged() }
    }

    private fun transmit(bytes: ByteArray, destination: InetSocketAddress) {
        if (!watching || mode != "relay") return
        val text = String(bytes, Charsets.UTF_8)
        val wire = if (text.startsWith("vibepier-punch1 ")) bytes else {
            if (destination != direct) return
            if (!directSecurity.ready) {
                if (!text.startsWith("vibepier-watch1 ")) return
                directSecurity.hello()?.toByteArray(Charsets.UTF_8) ?: return
            } else directSecurity.seal(bytes)?.toByteArray(Charsets.UTF_8) ?: return
        }
        try { socket.send(DatagramPacket(wire, wire.size, destination)) } catch (_: Exception) { TransportLog.warning(TransportLog.Event.DIRECT_SEND) }
    }

    /** Reattach a recreated Activity without resetting the network or re-fetching unchanged data. */
    @Synchronized fun replayUIState() {
        onApplication(currentApplication)
        updateSessionConnection()
        onShortcuts(displayedShortcuts)
        bindingSnapshot?.let(onBindings)
        notifyConnectionChanged()
    }

    private val sessionHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private fun updateSessionConnection() {
        val connected = synchronized(this) { currentApplication != null && connectedHost != null }
        ConnectionDiagnostics.shared.observe(mode, isDirect, connected, deviceKeys.authorized)
        sessionHandler.post {
            if (sessionClientDelegate.isInitialized()) sessionClient.connectionChanged(connected)
        }
    }
    private fun notifyConnectionChanged() {
        updateSessionConnection()
        onConnectionChanged()
    }

    fun detachUICallbacks() {
        onConnectionChanged = {}; onShortcuts = {}; onMicrophoneState = {}
        onBindings = {}; onBindingAck = {}; onBindingsReady = {}; onApplication = {}
        // Session callbacks belong to the connection, including while no Activity exists.
    }

    fun close() {
        sessionHandler.removeCallbacksAndMessages(null)
        if (sessionClientDelegate.isInitialized()) sessionClient.close()
        onSessionFrame = {}; onSessionPair = {}
        watch(false)
        bluetooth.close()
        relay.stop()
        directProbes.close()
        // Let the final releases (including their retries) leave before closing.
        executor.schedule({ socket.close() }, 200, TimeUnit.MILLISECONDS)
        executor.shutdown()
    }
}
