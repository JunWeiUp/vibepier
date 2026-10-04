// SPDX-License-Identifier: MIT
//
// The background daemon. It keeps the dongle session open, pushes the
// configuration to the device whenever the mic links, runs host actions on
// key events, and turns AI-agent hook events into indicator LED updates.

import ApplicationServices
import Foundation
import VibeKit

enum HeartbeatMode: String { case auto, on, off }

final class Daemon: @unchecked Sendable {
    let session: VibeSession
    let key: VibeKey
    private var config: Config
    private let lock = NSLock()
    private var server: ControlServer?
    private var listener: UUID?
    private var heartbeatProbe: DispatchWorkItem?
    private var heartbeatProbeInterval: Double?
    private var heartbeatProbeID: UUID?
    private var heartbeatProbeDeadline: Date?
    private var heartbeatMode: HeartbeatMode
    private var voiceHeartbeatActive = false
    private let talkFlow = TalkKeyFlow()
    private var talkPressCount = 0
    private var talkReleaseCount = 0
    private var keyEventCount = 0
    private var agentSessions: [String: (state: String, updated: Date)] = [:]
    private var lastPattern: LEDPattern?
    private var applyTask: Task<Void, Never>?
    private var lastBattery: BatteryStatus?
    private var micLinked = false
    /// True when the last event ended a session, so that the LEDs go dark once
    /// no session remains.
    private var lastEnded = false
    /// The six firmware bindings, read from the device after each apply.
    private var bindings: [Control: ButtonBinding] = [:]
    /// What each held control pressed, so that the release matches the press.
    private var held: [Control: Replay] = [:]
    private let replayQueue = DispatchQueue(label: "vibepier.replay")
    private let herdrQueue = DispatchQueue(label: "vibepier.herdr")
    private var agentModeActive = false
    private var pendingKnobPress: DispatchWorkItem?
    private var agentModeTimeout: DispatchWorkItem?
    /// A second knob release within this window counts as a double-press.
    static let doublePressWindow: TimeInterval = 0.3
    /// Agent mode ends after this many seconds without a turn.
    static let agentModeIdle: TimeInterval = 5
    private var lastHerdrAgent: String?
    private var remote: RemoteListener?
    private var bluetoothRemote: BluetoothRemote?
    private var relayClient: RelayClient?
    private let enableBluetooth: Bool
    private let remoteEventQueue = DispatchQueue(label: "vibepier.remote-events")
    private var remoteOwners = RemoteControlOwners()
    private var remoteApplicationDedup = RemoteDeduplicator()
    private var remoteTalkHeld = false
    private var applicationLaunchError: String?
    /// The phone's talk keys at press time, so that the release lets go of the same keys.
    private var remoteTalkKeys: String?
    private var remoteTalkWatchdog: DispatchWorkItem?
    private var remoteTalkLeaseID: UUID?
    /// The phone repeats "talk down" every second while held. Silence this long
    /// releases the key, so a lost "up" datagram cannot leave dictation running.
    static let remoteTalkTimeout: TimeInterval = 3

    init(config: Config, verbose: Bool, enableBluetooth: Bool = false) {
        self.enableBluetooth = enableBluetooth
        let s = VibeSession()
        s.logFrames = verbose
        session = s
        key = VibeKey(session: s)
        self.config = config
        heartbeatMode = HeartbeatMode(rawValue: config.heartbeatMode ?? "on") ?? .on
        session.configureHeartbeat(interval: heartbeatMode == .on ? 1 : nil)
    }

    func log(_ text: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("\(stamp) \(text)\n".utf8))
    }

    func start() throws {
        guard server == nil else { return }
        guard ControlSocket.request(["cmd": "status"]) == nil else {
            throw CLIError(L10n.text("core.vibepier_or_the_vibepier_service_is_already_running_quit_the_existin"))
        }
        config = try RelayCredentialMigration.migrate(config)
        PhoneMicrophone.shared.recoverInputAfterRestart()
        let applicationIDs = lock.withLock { config.applicationShortcuts }
        Task { @MainActor in
            ApplicationShortcuts.shared.configure(applicationIDs)
            CurrentApplicationShortcut.shared.startObserving()
            ApplicationUsage.shared.start()
        }
        let srv = ControlServer { [weak self] req in
            guard let self else { return ["ok": false] }
            return await self.handle(req)
        }
        try srv.start()
        server = srv
        log("control socket at \(Paths.socket.path)")
        ConversationActivity.shared.setOpener { provider, id in
            try await ConversationTaskOpener.open(provider: provider, id: id)
        }
        ConversationActivity.shared.setCompletionHandler { event in
            SessionRemote.shared.taskCompleted(event)
        }
        ConversationActivity.shared.start()

        if !Replay.checkAccessibility(prompt: true) {
            log(
                "Accessibility access is missing. Allow the running app in System Settings > Privacy & Security > Accessibility."
            )
        }
        listener = session.addListener { [weak self] event in self?.onEvent(event) }
        session.start()
        startRemote()
        restartRelay()
        // CLI diagnostics do not advertise or request Bluetooth permission.
        if enableBluetooth {
            let bluetooth = BluetoothRemote(
                microphoneAllowed: { [weak self] in self?.talkFlow.isHolding == false },
                handler: { [weak self] in self?.onRemote($0) })
            bluetoothRemote = bluetooth
            bluetooth.start()
        }
        log("waiting for the Vibe Key dongle (\(String(format: "%04X:%04X", VibeUSB.vendorID, VibeUSB.productID)))")
    }

    func stop() {
        ConversationActivity.shared.stop()
        Task { @MainActor in
            CurrentApplicationShortcut.shared.stopObserving()
            ApplicationUsage.shared.stop()
        }
        bluetoothRemote?.stop()
        bluetoothRemote = nil
        relayClient?.stop()
        relayClient = nil
        remote?.stop()
        remote = nil
        remoteEventQueue.sync {
            lock.withLock {
                remoteTalkWatchdog?.cancel()
                remoteTalkWatchdog = nil
                remoteTalkLeaseID = nil
                remoteOwners.removeAll()
                remoteTalkHeld = false
                remoteTalkKeys = nil
            }
        }
        PhoneMicrophone.shared.stop()
        SessionRemote.shared.stop()
        talkFlow.stop()
        heartbeatProbe?.cancel()
        applyTask?.cancel()
        if let listener {
            session.removeListener(listener)
            self.listener = nil
        }
        ActionRunner.shutdown()
        replayQueue.sync {
            let active = lock.withLock {
                let active = held
                held.removeAll()
                return active
            }
            for replay in active.values { try? replay.release() }
        }
        session.stop()
        server?.stop()
        server = nil
    }

    func run() async throws {
        try start()

        let signals = [SIGINT, SIGTERM].map { sig -> DispatchSourceSignal in
            signal(sig, SIG_IGN)
            // The main queue never runs while `run()` awaits, so handle signals on a
            // background queue. Otherwise SIGINT and SIGTERM are swallowed.
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global(qos: .userInitiated))
            src.setEventHandler { [weak self] in
                self?.log("stopping")
                self?.stop()
                exit(0)
            }
            src.resume()
            return src
        }
        _ = signals
        while true {
            try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000)
        }
    }

    // MARK: Session events

    private func onEvent(_ event: SessionEvent) {
        switch event {
        case .connected(let info):
            log("dongle connected: \(info)")
        case .authenticated:
            log("dongle authenticated")
            scheduleApply(reason: "dongle ready")
        case .disconnected:
            log("dongle disconnected")
            lock.withLock {
                micLinked = false
                lastPattern = nil
            }
            if let action = lock.withLock({ config.actions?["talk"] }) { handleTalk(action, pressed: false) }
        case .message(let message, _):
            onMessage(message)
        }
    }

    private func onMessage(_ message: VibeMessage) {
        switch message {
        case .keyEvent(let e):
            lock.withLock { keyEventCount += 1 }
            guard let control = e.control else {
                log("key event for unknown index \(e.physicalIndex) status \(e.status)")
                return
            }
            let rotation = control == .knobLeft || control == .knobRight
            let pressed = e.status != 0 || rotation
            if session.logFrames {
                log("key \(control.name) \(rotation ? "step" : (pressed ? "press" : "release"))")
            }
            dispatch(control, pressed: pressed, rotation: rotation, remote: false)
        case .linkActive(let on):
            let changed = lock.withLock {
                let changed = micLinked != on
                micLinked = on
                if !on {
                    lastBattery = nil
                    lastPattern = nil
                }
                return changed
            }
            if changed {
                log("mic \(on ? "linked" : "unlinked")")
                if on { scheduleApply(reason: "mic linked") }
            }
        case .powerOn:
            log("mic powered on")
            scheduleApply(reason: "mic powered on")
        case .batteryNotice(let b), .battery(let b):
            let changed = lock.withLock { () -> Bool in
                let c = lastBattery?.percent != b.percent || lastBattery?.charging != b.charging
                lastBattery = b
                return c
            }
            if changed {
                log("battery \(b.percent)% \(b.millivolts) mV\(b.charging ? " charging" : "")")
            }
        default:
            break
        }
    }

    /// Runs the configured action, or replays the firmware binding, for one control event.
    /// `keys` comes from the phone and replaces the binding; talk keeps its input switching.
    private func dispatch(_ control: Control, pressed: Bool, rotation: Bool, remote: Bool, keys: String? = nil) {
        if control == .talk && pressed && PhoneMicrophone.shared.active { PhoneMicrophone.shared.stop() }
        let (action, replayEnabled, agentModeOn) = lock.withLock {
            (
                config.actions?[control.name], config.replayBindings ?? true,
                (config.agentMode ?? "herdr") != "off"
            )
        }
        if agentModeOn, handleAgentMode(control, pressed: pressed, rotation: rotation, action: action) { return }
        if var action, keys == nil || control == .talk {
            if control == .talk && action.keysMode == "hold" && action.trigger == "both" {
                if let keys { action.keys = keys }
                lock.withLock {
                    if pressed { talkPressCount += 1 } else { talkReleaseCount += 1 }
                }
                handleTalk(action, pressed: pressed, remote: remote)
                return
            }
            let wanted = action.trigger
            if wanted == "both" || (wanted == "press") == pressed {
                ActionRunner.run(action, pressed: pressed) { [weak self] in self?.log($0) }
            }
        } else if replayEnabled || keys != nil {
            replay(control, pressed: pressed, rotation: rotation, remote: remote, keys: keys)
        }
    }

    // MARK: Android remote

    private func startRemote() {
        BinaryFileTransfers.shared.configure(nil)
        let port = lock.withLock { config.remotePort } ?? Int(RemoteListener.defaultPort)
        guard port > 0, let p = UInt16(exactly: port) else { return }
        let listener = RemoteListener(
            microphoneAllowed: { [weak self] in self?.talkFlow.isHolding == false },
            handler: {
                [weak self] e in self?.onRemote(e)
            })
        do {
            try listener.start(port: p)
            remote = listener
            log("remote: listening on UDP \(p)")
        } catch {
            log("\(error)")
        }
    }

    /// (Re)joins the cloud relay with the current config; no relay settings means off.
    private func restartRelay() {
        relayClient?.stop()
        relayClient = nil
        let settings = lock.withLock { RelaySettings(config) }
        BinaryFileTransfers.shared.configure(settings)
        guard let settings else { return }
        let client = RelayClient(settings: settings) { [weak self] e in self?.onRemote(e) }
        client.directOffer = { [weak self] sender, token, candidates, answer in
            guard let remote = self?.remote else {
                answer([])
                return
            }
            remote.acceptDirect(sender: sender, token: token, candidates: candidates, answer: answer)
        }
        relayClient = client
        client.start()
        log("remote: relay configured")
    }

    private func onRemote(_ e: RemoteEvent) {
        // UDP, BLE, relay and watchdog callbacks run on different queues. Keep
        // owner changes and their corresponding key transitions in one order.
        remoteEventQueue.sync { handleRemote(e) }
    }

    private func handleRemote(_ e: RemoteEvent) {
        if let slot = e.applicationSlot, let bundleID = e.applicationID {
            // The same tap can arrive by direct UDP and relay during a path change.
            // BLE adds its central UUID; the underlying phone sender still identifies this tap.
            guard remoteApplicationDedup.isNewApplication(e) else { return }
            PhoneMicrophone.shared.stop()
            if let owner = lock.withLock({ remoteOwners.owner(.talk) }) {
                handleRemote(RemoteEvent(sender: owner, seq: 0, control: .talk, event: "up"))
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.talkFlow.waitUntilIdle()
                // Drain queued modifier releases before bringing another app forward.
                await withCheckedContinuation { continuation in
                    self.replayQueue.async { continuation.resume() }
                }
                let error = await ApplicationShortcuts.shared.perform(
                    slot: slot, bundleID: bundleID, action: e.applicationAction)
                self.lock.withLock { self.applicationLaunchError = error }
                if let error { self.log(error) }
                NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
            }
            return
        }
        guard let control = e.control else { return }
        // Reject an old profile after the Mac has switched apps. Releases and
        // keep-alives of an already held talk key must still complete normally.
        if let app = e.applicationID, e.event != "up",
            !(e.control == .talk && lock.withLock({ remoteOwners.owns(.talk, sender: e.sender) })),
            app != FrontmostApplication.current().bundleID
        {
            return
        }
        guard lock.withLock({ remoteOwners.accept(e) }) else { return }
        if session.logFrames { log("remote \(e.sender) \(control.name) \(e.event)") }
        guard e.control == .talk else {
            let rotation = e.isMomentary
            dispatch(control, pressed: e.event != "up", rotation: rotation, remote: true, keys: e.keys)
            return
        }
        let pressed = e.event == "down"
        let (changed, keys) = lock.withLock { () -> (Bool, String?) in
            remoteTalkWatchdog?.cancel()
            remoteTalkWatchdog = nil
            remoteTalkLeaseID = nil
            if pressed {
                let owner = RemoteControlOwners.identity(e.sender)
                let leaseID = UUID()
                remoteTalkLeaseID = leaseID
                let item = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.remoteEventQueue.async { [weak self] in
                        guard let self,
                            self.lock.withLock({
                                self.remoteTalkLeaseID == leaseID && self.remoteOwners.owns(.talk, sender: owner)
                            })
                        else { return }
                        self.log("remote: talk release timed out")
                        self.handleRemote(RemoteEvent(sender: owner, seq: 0, control: .talk, event: "up"))
                    }
                }
                remoteTalkWatchdog = item
                DispatchQueue.global().asyncAfter(deadline: .now() + Daemon.remoteTalkTimeout, execute: item)
            }
            let changed = remoteTalkHeld != pressed
            remoteTalkHeld = pressed
            if changed && pressed { remoteTalkKeys = e.keys }
            return (changed, remoteTalkKeys)
        }
        if changed { dispatch(.talk, pressed: pressed, rotation: false, remote: true, keys: keys) }
    }

    // MARK: Applying the configuration

    /// All talk events are ordered, including a release received while waking.
    /// Remote presses come from the phone, so they leave the dongle heartbeat alone.
    private func handleTalk(_ action: HostAction, pressed: Bool, remote: Bool = false) {
        talkFlow.handle(
            pressed: pressed,
            prepare: { [weak self] in
                guard let self else { throw SessionError.cancelled }
                if remote { return }
                let automatic = self.lock.withLock {
                    self.voiceHeartbeatActive = true
                    self.cancelHeartbeatProbeLocked()
                    self.applyHeartbeatLocked()
                    return self.heartbeatMode == .auto
                }
                NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
                if automatic { try await self.session.wakeHeartbeat() }
            },
            run: { [weak self] pressed, shouldRun in
                guard action.trigger == "both" || (action.trigger == "press") == pressed else { return false }
                return await ActionRunner.runAndWait(action, pressed: pressed, shouldRun: shouldRun) { [weak self] in
                    self?.log($0)
                }
            },
            finish: { [weak self] in
                guard let self, !remote else { return }
                self.lock.withLock {
                    self.voiceHeartbeatActive = false
                    self.applyHeartbeatLocked()
                }
                NotificationCenter.default.post(name: DriverNotifications.statusChanged, object: nil)
            }, log: { [weak self] in self?.log($0) })
    }

    private var baselineHeartbeatEnabled: Bool {
        heartbeatMode == .on || (heartbeatMode == .auto && voiceHeartbeatActive)
    }

    private func applyHeartbeatLocked() {
        if let interval = heartbeatProbeInterval {
            session.configureHeartbeat(interval: interval == 0 ? nil : interval)
        } else {
            session.configureHeartbeat(interval: baselineHeartbeatEnabled ? 1 : nil)
        }
    }

    private func cancelHeartbeatProbeLocked() {
        heartbeatProbe?.cancel()
        heartbeatProbe = nil
        heartbeatProbeID = nil
        heartbeatProbeDeadline = nil
        heartbeatProbeInterval = nil
    }

    private func scheduleApply(reason: String) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.apply(reason: reason)
        }
        let previous = lock.withLock { () -> Task<Void, Never>? in
            let old = applyTask
            applyTask = task
            return old
        }
        previous?.cancel()
    }

    private func apply(reason: String) async {
        do {
            guard try await key.isMicLinked() else {
                lock.withLock {
                    micLinked = false
                    lastBattery = nil
                }
                log("mic is not linked. The configuration will be applied when it links.")
                return
            }
            let cfg = lock.withLock { () -> Config in
                micLinked = true
                lastPattern = nil
                return config
            }
            log("applying configuration (\(reason))")
            try await Apply.settings(cfg.settings, to: key, log: { [weak self] in self?.log($0) })
            try await Apply.buttons(cfg.buttons, to: key, log: { [weak self] in self?.log($0) })
            if cfg.agentLightsEnabled != false {
                try await Apply.ledWorkTime(
                    cfg.settings?.ledWorkTime ?? 255, to: key, log: { [weak self] in self?.log($0) })
            }
            await refreshBindings()
            await refreshAgentLights()
        } catch {
            log("could not apply the configuration: \(error)")
        }
    }

    // MARK: Agent mode

    /// Double-press the knob to enter agent mode. In agent mode, each turn steps
    /// through Herdr agents, and a knob press or 5 idle seconds exits. Confirm and
    /// cancel both light solid while the mode is on. A single knob press fires its
    /// binding after the double-press window. Returns true when the event was consumed.
    private func handleAgentMode(_ control: Control, pressed: Bool, rotation: Bool, action: HostAction?) -> Bool {
        if control == .knobPress {
            if pressed { return true }
            if lock.withLock({ agentModeActive }) {
                exitAgentMode(reason: "knob press")
                return true
            }
            let pending = lock.withLock { () -> DispatchWorkItem? in
                let p = pendingKnobPress
                pendingKnobPress = nil
                return p
            }
            if let pending {
                pending.cancel()
                enterAgentMode()
                return true
            }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.pendingKnobPress = nil }
                if let action {
                    ActionRunner.run(action, pressed: true) { [weak self] in self?.log($0) }
                } else if self.lock.withLock({ self.config.replayBindings ?? true }) {
                    self.replay(.knobPress, pressed: true, rotation: true)
                }
            }
            lock.withLock { pendingKnobPress = item }
            herdrQueue.asyncAfter(deadline: .now() + Daemon.doublePressWindow, execute: item)
            return true
        }
        guard rotation, lock.withLock({ agentModeActive }) else { return false }
        armAgentModeTimeout()
        let step = control == .knobRight ? 1 : -1
        herdrQueue.async { [weak self] in
            guard let self else { return }
            let last = self.lock.withLock { self.lastHerdrAgent }
            do {
                if let agent = try Herdr.cycle(step: step, after: last) {
                    self.focused(agent)
                } else {
                    self.log("herdr: no agents")
                }
            } catch {
                self.log("\(error)")
            }
        }
        return true
    }

    private func focused(_ agent: Herdr.Agent) {
        let mode = lock.withLock { () -> String in
            lastHerdrAgent = agent.id
            return config.herdrFocusTerminal ?? "always"
        }
        log("herdr: focused \(agent.id) (\(agent.name), \(agent.status))")
        if mode == "always" { bringTerminalToFront() }
    }

    /// Moves the terminal that runs Herdr to the front, on the Herdr queue.
    private func bringTerminalToFront() {
        let (app, corner) = lock.withLock { (config.herdrApp, config.herdrPointer ?? "bottom-right") }
        herdrQueue.async { [weak self] in
            if Herdr.bringTerminalToFront(appName: app, pointerCorner: corner) == nil {
                self?.log("herdr: could not find the terminal app. Set \"herdrApp\" in the configuration file.")
            }
        }
    }

    private func enterAgentMode() {
        let mode = lock.withLock { () -> String in
            agentModeActive = true
            return config.herdrFocusTerminal ?? "always"
        }
        log("agent mode on")
        if mode != "off" { bringTerminalToFront() }
        armAgentModeTimeout()
        Task { [weak self] in
            guard let self else { return }
            try? await self.key.setLED(1, .workType, LEDType.solid)
            try? await self.key.setLED(2, .workType, LEDType.solid)
            self.lock.withLock { self.lastPattern = nil }
        }
        // Start at the agent that needs you most: blocked first, then done.
        herdrQueue.async { [weak self] in
            guard let self else { return }
            do {
                let agents = try Herdr.agents()
                for status in ["blocked", "done"] {
                    if let a = agents.first(where: { $0.status == status && !$0.focused }) {
                        try Herdr.focus(a.id)
                        self.focused(a)
                        return
                    }
                }
            } catch {
                self.log("\(error)")
            }
        }
    }

    private func exitAgentMode(reason: String) {
        let was = lock.withLock { () -> Bool in
            let w = agentModeActive
            agentModeActive = false
            agentModeTimeout?.cancel()
            agentModeTimeout = nil
            return w
        }
        guard was else { return }
        log("agent mode off (\(reason))")
        Task { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.lastPattern = nil }
            if self.effectivePattern() == nil {
                try? await self.key.setLED(1, .workType, LEDType.off)
                try? await self.key.setLED(2, .workType, LEDType.off)
            }
            await self.refreshAgentLights()
        }
    }

    private func armAgentModeTimeout() {
        let item = DispatchWorkItem { [weak self] in self?.exitAgentMode(reason: "idle") }
        lock.withLock {
            agentModeTimeout?.cancel()
            agentModeTimeout = item
        }
        herdrQueue.asyncAfter(deadline: .now() + Daemon.agentModeIdle, execute: item)
    }

    // MARK: Key replay

    func refreshBindings() async {
        do {
            var out: [Control: ButtonBinding] = [:]
            for b in try await key.bindings() { out[b.control] = b }
            lock.withLock { bindings = out }
            log("bindings: " + Control.allCases.map { "\($0.name)=\(out[$0]?.summary ?? "?")" }.joined(separator: " "))
        } catch {
            log("could not read the button bindings: \(error)")
        }
    }

    /// Performs a control's firmware binding on the host. While the daemon holds
    /// a session, the firmware reports presses instead of typing the binding.
    private func replay(_ control: Control, pressed: Bool, rotation: Bool, remote: Bool = false, keys: String? = nil) {
        replayQueue.async { [weak self] in
            guard let self else { return }
            if let keys {
                do {
                    let r = Replay.keys(try Hotkey.parseHIDCodes(keys))
                    if rotation {
                        try r.tap()
                    } else if pressed {
                        self.lock.withLock { self.held[control] = r }
                        try r.press()
                    } else {
                        try (self.lock.withLock { self.held.removeValue(forKey: control) } ?? r).release()
                    }
                } catch {
                    self.log("remote \(control.name) keys '\(keys)': \(error)")
                }
                return
            }
            var binding = self.lock.withLock { self.bindings[control] }
            // The phone works without the dongle, so it falls back to the factory keys.
            if binding == nil, remote {
                binding = ButtonBinding(control: control, fixedFunction: control.factoryFixedFunction, shortcut: [])
            }
            guard let binding else {
                self.log("binding for \(control.name) is not loaded yet")
                Task { await self.refreshBindings() }
                return
            }
            do {
                if rotation {
                    try Replay(binding: binding).tap()
                } else if pressed {
                    let r = Replay(binding: binding)
                    self.lock.withLock { self.held[control] = r }
                    try r.press()
                } else {
                    let r = self.lock.withLock { self.held.removeValue(forKey: control) } ?? Replay(binding: binding)
                    try r.release()
                }
            } catch {
                self.log("replay \(control.name): \(error)")
            }
        }
    }

    // MARK: Agent state -> LEDs

    private func pattern(for state: String) -> LEDPattern? {
        lock.withLock {
            if config.agentLightsEnabled == false { return nil }
            let preset = config.agentLightsPreset == "ulanzi" ? vendorAgentLights : defaultAgentLights
            return config.agentLights?[state] ?? preset[state]
        }
    }

    /// States in priority order, most urgent first. A pending permission request
    /// wins, which mirrors `UlanziDeck::hasNotificationSession`.
    static let statePriority = [
        "notification", "error", "attention", "working", "thinking", "sweeping", "idle", "sleeping",
    ]
    static let busyStates: Set<String> = ["working", "thinking", "sweeping"]

    /// The most urgent state across sessions, and the most urgent busy state if any
    /// session is busy. Ended sessions and sessions idle for 6 hours drop out.
    private func effectiveStates() -> (top: String, busy: String?)? {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-6 * 3600)
            agentSessions = agentSessions.filter { $0.value.updated > cutoff && $0.value.state != "sleeping" }
            let states = Set(agentSessions.values.map(\.state))
            guard !states.isEmpty else { return lastEnded ? ("sleeping", nil) : nil }
            let rank = { (s: String) in Daemon.statePriority.firstIndex(of: s) ?? Daemon.statePriority.count }
            let top = states.min(by: { rank($0) < rank($1) })!
            let busy = states.filter { Daemon.busyStates.contains($0) }.min(by: { rank($0) < rank($1) })
            return (top, busy)
        }
    }

    private func effectiveState() -> String? { effectiveStates()?.top }

    /// Confirm and cancel follow the most urgent session. The knob shows activity
    /// while any session is busy, so a finished session does not hide a busy one.
    private func effectivePattern() -> (String, LEDPattern)? {
        guard let (top, busy) = effectiveStates(), var p = pattern(for: top) else { return nil }
        var label = top
        if let busy, busy != top, let knob = pattern(for: busy)?["3"] {
            p["3"] = knob
            label = "\(top)+\(busy)"
        }
        return (label, p)
    }

    private func refreshAgentLights() async {
        if lock.withLock({ agentModeActive || config.agentLightsEnabled == false }) { return }
        guard let (state, p) = effectivePattern() else { return }
        let (unchanged, linked) = lock.withLock { (lastPattern == p, micLinked) }
        guard linked, !unchanged else { return }
        do {
            for (ledText, type) in p.sorted(by: { $0.key < $1.key }) {
                guard let led = Int(ledText), (0...3).contains(led) else { continue }
                try await key.setLED(led, .workType, type)
            }
            lock.withLock { lastPattern = p }
            let text = p.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            log("agent state \(state): LEDs \(text)")
        } catch {
            log("could not update LEDs for agent state \(state): \(error)")
        }
    }

    // MARK: Control socket

    private func finishHeartbeatProbe(_ id: UUID) {
        lock.withLock {
            guard heartbeatProbeID == id else { return }
            cancelHeartbeatProbeLocked()
            applyHeartbeatLocked()
        }
    }

    func handle(_ req: [String: Any]) async -> [String: Any] {
        // App Nap can defer a dispatch deadline. Any subsequent control request
        // must enforce expiry before reporting state or beginning another probe.
        if let expired = lock.withLock({
            heartbeatProbeDeadline.map { $0 <= Date() } == true ? heartbeatProbeID : nil
        }) {
            finishHeartbeatProbe(expired)
        }
        return await RuntimeCommands.handle(req, runtime: handleRuntimeCommand)
    }

    private func handleRuntimeCommand(_ req: [String: Any]) async -> [String: Any] {
        switch req["cmd"] as? String ?? "" {
        case "preferences-export":
            do {
                try PhoneBindings.shared.validateMerge([:])
                let archive = try lock.withLock {
                    try PreferencesArchive(config: Config.load(), bindings: PhoneBindings.shared.snapshot).encoded()
                }
                return ["ok": true, "archive": try JSONSerialization.jsonObject(with: archive)]
            } catch { return ["ok": false, "error": String(describing: error)] }
        case "preferences-import", "preferences-preview":
            do {
                guard let value = req["archive"] as? [String: Any] else {
                    throw CLIError(L10n.text("core.missing_settings_archive_content"))
                }
                let archive = try PreferencesArchive.decode(JSONSerialization.data(withJSONObject: value))
                try PhoneBindings.shared.validateMerge(archive.phoneBindings)
                if req["cmd"] as? String == "preferences-preview" { return ["ok": true] }
                try lock.withLock {
                    let current = try Config.load()
                    _ = try archive.apply(to: current, bindings: PhoneBindings.shared, save: { try $0.save() })
                }
                return await handleRuntimeCommand(["cmd": "reload"])
            } catch { return ["ok": false, "error": String(describing: error)] }
        case "heartbeat-mode":
            guard let name = req["mode"] as? String, let mode = HeartbeatMode(rawValue: name) else {
                return ["ok": false, "error": L10n.text("core.heartbeat_mode")]
            }
            do {
                if req["persist"] as? Bool == true {
                    var saved = try Config.load()
                    saved.heartbeatMode = name
                    try saved.save()
                }
                lock.withLock {
                    config.heartbeatMode = name
                    heartbeatMode = mode
                    cancelHeartbeatProbeLocked()
                    applyHeartbeatLocked()
                }
                return ["ok": true]
            } catch { return ["ok": false, "error": "\(error)"] }
        case "heartbeat":
            guard let enabled = req["enabled"] as? Bool else {
                return ["ok": false, "error": L10n.text("core.heartbeat_enabled")]
            }
            lock.withLock {
                cancelHeartbeatProbeLocked()
                heartbeatMode = enabled ? .on : .off
                applyHeartbeatLocked()
            }
            return ["ok": true, "heartbeatEnabled": enabled]
        case "heartbeat-probe":
            // Local-only diagnostic, automatically returns to the user's manual state.
            guard let interval = req["interval"] as? Double, [0.0, 1.0, 2.0, 5.0].contains(interval),
                let seconds = req["seconds"] as? Double, (1...90).contains(seconds)
            else {
                return ["ok": false, "error": L10n.text("core.heartbeat_probe_range")]
            }
            return lock.withLock {
                guard heartbeatProbe == nil else {
                    return ["ok": false, "error": L10n.text("core.heartbeat_probe_running")]
                }
                heartbeatProbeInterval = interval
                let id = UUID()
                heartbeatProbeID = id
                heartbeatProbeDeadline = Date().addingTimeInterval(seconds)
                session.configureHeartbeat(interval: interval == 0 ? nil : interval)
                let item = DispatchWorkItem { [weak self] in
                    self?.finishHeartbeatProbe(id)
                }
                heartbeatProbe = item
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds, execute: item)
                return ["ok": true, "interval": interval, "seconds": seconds]
            }
        case "agent-state":
            if lock.withLock({ config.agentLightsEnabled == false }) { return ["ok": true, "ignored": true] }
            guard let state = req["state"] as? String else {
                return ["ok": false, "error": L10n.text("core.missing_agent_state")]
            }
            let sessionID = (req["session"] as? String) ?? "default"
            let agent = (req["agent"] as? String) ?? "unknown"
            lock.withLock {
                agentSessions["\(agent):\(sessionID)"] = (state, Date())
                lastEnded = state == "sleeping"
            }
            await refreshAgentLights()
            return ["ok": true]
        case "refresh-bindings":
            await refreshBindings()
            return ["ok": true]
        case "phone-applications", "phone-application-set":
            do {
                let installed = ApplicationCatalog.installed()
                let ids = try lock.withLock { () -> [String]? in
                    if req["cmd"] as? String == "phone-application-set" {
                        guard let index = req["index"] as? Int, let id = req["bundleID"] as? String,
                            let revision = req["revision"] as? String
                        else {
                            throw CLIError(L10n.text("core.invalid_request"))
                        }
                        var saved = try Config.load()
                        let values = try ApplicationCatalog.setting(
                            index: index, bundleID: id, revision: revision,
                            ids: saved.applicationShortcuts, installed: Set(installed.map(\.bundleID)))
                        saved.applicationShortcuts = values
                        try saved.save()
                        config.applicationShortcuts = values
                    }
                    return config.applicationShortcuts
                }
                await ApplicationShortcuts.shared.configure(ids)
                return ApplicationCatalog.reply(ids: ids, installed: installed)
            } catch { return ["ok": false, "error": String(describing: error)] }
        case "application-shortcut-set", "application-shortcut-move", "application-shortcut-add",
            "application-shortcut-remove":
            do {
                try lock.withLock {
                    var saved = try Config.load()
                    let change: ApplicationShortcutChange
                    if req["cmd"] as? String == "application-shortcut-add" {
                        guard let id = req["bundleID"] as? String else {
                            throw CLIError(L10n.text("core.invalid_application_identifier"))
                        }
                        change = .add(bundleID: id)
                    } else {
                        guard let index = req["index"] as? Int else {
                            throw CLIError(L10n.text("core.invalid_application_slot"))
                        }
                        switch req["cmd"] as? String {
                        case "application-shortcut-move":
                            guard let target = req["target"] as? Int else {
                                throw CLIError(L10n.text("core.invalid_destination_slot"))
                            }
                            change = .move(index: index, target: target)
                        case "application-shortcut-remove": change = .remove(index: index)
                        default:
                            guard let id = req["bundleID"] as? String else {
                                throw CLIError(L10n.text("core.invalid_application_identifier"))
                            }
                            change = .set(index: index, bundleID: id)
                        }
                    }
                    let ids = try ApplicationShortcuts.applying(change, to: saved.applicationShortcuts)
                    saved.applicationShortcuts = ids
                    try saved.save()
                    config.applicationShortcuts = ids
                }
                let ids = lock.withLock { config.applicationShortcuts }
                await ApplicationShortcuts.shared.configure(ids)
                return ["ok": true]
            } catch { return ["ok": false, "error": "\(error)"] }
        case "relay-config":
            let dns = req["dnsRecovery"] as? String ?? "system"
            guard ["system", "alidns"].contains(dns) else {
                return ["ok": false, "error": L10n.text("core.unsupported_dns_recovery_setting")]
            }
            let url = (req["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let room = (req["room"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var secret = (req["secret"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            if secret.isEmpty { secret = lock.withLock { RelaySettings(config)?.secret } ?? "" }
            if !url.isEmpty && RelaySettings(url: url, room: room, secret: secret, dnsRecovery: dns == "alidns") == nil
            {
                return [
                    "ok": false,
                    "error": L10n.text("core.use_a_ws_s_relay_url_a_room_with_letters_numbers_or_and_a_secret_of_"),
                ]
            }
            do {
                try lock.withLock {
                    var saved = try Config.load()
                    saved.relayURL = url.isEmpty ? nil : url
                    saved.relayRoom = url.isEmpty ? nil : room
                    try RelayCredentialStore.save(
                        url.isEmpty ? nil : RelaySettings(url: url, room: room, secret: secret))
                    saved.relaySecret = nil
                    saved.relayDNSRecovery = url.isEmpty ? nil : dns == "alidns"
                    try saved.save()
                    config.relayURL = saved.relayURL
                    config.relayRoom = saved.relayRoom
                    config.relaySecret = saved.relaySecret
                    config.relayDNSRecovery = saved.relayDNSRecovery
                }
                restartRelay()
                return ["ok": true]
            } catch { return ["ok": false, "error": "\(error)"] }
        case "relay-pairing":
            guard let settings = lock.withLock({ RelaySettings(config) }) else {
                return ["ok": false, "error": L10n.text("core.cloud_relay_is_not_configured")]
            }
            return ["ok": true, "code": settings.pairingCode]
        case "reload":
            do {
                let cfg = try RelayCredentialMigration.migrate(Config.load())
                let relayChanged = lock.withLock { RelaySettings(config) != RelaySettings(cfg) }
                defer { if relayChanged { restartRelay() } }
                let needsApply = lock.withLock {
                    let old = config
                    config = cfg
                    if old.heartbeatMode != cfg.heartbeatMode {
                        heartbeatMode = HeartbeatMode(rawValue: cfg.heartbeatMode ?? "on") ?? .on
                        cancelHeartbeatProbeLocked()
                        applyHeartbeatLocked()
                    }
                    if cfg.agentLightsEnabled == false {
                        agentSessions.removeAll()
                        lastEnded = false
                        lastPattern = nil
                    }
                    return old.settings != cfg.settings || old.buttons != cfg.buttons
                        || (old.agentLightsEnabled == false && cfg.agentLightsEnabled != false)
                }
                await ApplicationShortcuts.shared.configure(cfg.applicationShortcuts)
                if needsApply {
                    scheduleApply(reason: "reload")
                } else {
                    await refreshAgentLights()
                }
                return ["ok": true]
            } catch {
                return ["ok": false, "error": "\(error)"]
            }
        case "status":
            let (b, linked, sessions) = lock.withLock {
                (lastBattery, micLinked, agentSessions.mapValues { $0.state })
            }
            let bluetoothStatus =
                bluetoothRemote?.status ?? ["state": L10n.text("mac.not_started"), "connectedCount": 0]
            let relayStatus =
                relayClient?.status ?? [
                    "state": L10n.text("mac.not_configured"), "connectedCount": 0, "url": "", "room": "",
                ]
            let connectedPhoneIDs = Set(
                (remote?.connectedDeviceIDs ?? []) + (bluetoothStatus["deviceIDs"] as? [String] ?? [])
                    + (relayStatus["deviceIDs"] as? [String] ?? []))
            var out: [String: Any] = [
                "ok": true,
                "dongleConnected": session.isConnected,
                "authenticated": session.isAuthenticated,
                "accessibilityTrusted": Replay.checkAccessibility(prompt: false),
                "micLinked": linked,
                "agentSessions": sessions,
                "taskActivity": ConversationActivity.shared.snapshot,
                "agentLightsEnabled": lock.withLock { config.agentLightsEnabled != false },
                "sessionTimerWakeups": session.timerWakeupCount,
                "processID": ProcessInfo.processInfo.processIdentifier,
                "launchAtLogin": Service.appLoginEnabled,
                "keyEventCount": lock.withLock { keyEventCount },
                "remoteConnectedAddresses": remote?.connectedAddresses ?? [],
                "connectedPhoneIDs": connectedPhoneIDs.sorted(),
                "remoteListening": remote != nil,
                "phoneMicrophone": PhoneMicrophone.shared.status,
                "bluetooth": bluetoothStatus,
                "relay": relayStatus,
                "applicationShortcuts": ApplicationShortcuts.shared.snapshot.entries.map {
                    [
                        "slot": $0.slot, "bundleID": $0.bundleID, "name": $0.name, "iconPNG": "",
                        "available": $0.available,
                    ] as [String: Any]
                },
                "applicationLaunchError": lock.withLock { applicationLaunchError ?? "" },
                "remotePort": lock.withLock { config.remotePort ?? Int(RemoteListener.defaultPort) },
                "heartbeatInterval": lock.withLock { heartbeatProbeInterval ?? (baselineHeartbeatEnabled ? 1 : 0) },
                "heartbeatEnabled": lock.withLock {
                    (heartbeatProbeInterval ?? (baselineHeartbeatEnabled ? 1 : 0)) > 0
                },
                "heartbeatMode": lock.withLock { heartbeatMode.rawValue },
                "voiceHeartbeatActive": lock.withLock { voiceHeartbeatActive },
                "talkPressCount": lock.withLock { talkPressCount },
                "talkReleaseCount": lock.withLock { talkReleaseCount },
            ]
            if let b { out["battery"] = ["percent": b.percent, "millivolts": b.millivolts, "charging": b.charging] }
            if let s = effectiveState() { out["agentState"] = s }
            return out
        default:
            return ["ok": false, "error": L10n.text("core.unknown_local_command")]
        }
    }
}
