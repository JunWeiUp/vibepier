import SwiftUI
import VibePierCore

// MARK: - Main menu-bar panel

/// Fit before MenuBarExtra positions its window; never resize via an async preference.
struct MenuPanelLayout<Content: View>: View {
    let maximumHeight: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView(.vertical) { content }
                .frame(height: maximumHeight)
        }
        .frame(width: 340)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct PanelView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject private var commands = AppCommands.feedback
    @State private var showCommandError = false
    @Environment(\.openWindow) private var openWindow
    @State private var openedMaximumHeight: CGFloat?

    private var maximumHeight: CGFloat {
        if let openedMaximumHeight { return openedMaximumHeight }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        return max(240, min(760, (screen?.visibleFrame.height ?? 800) - 48))
    }

    var body: some View {
        MenuPanelLayout(maximumHeight: maximumHeight) { panelContent }
            .background(MenuPanelPosition())
            .onAppear {
                openedMaximumHeight = maximumHeight
                model.startMonitoring()
            }
            .onDisappear {
                model.stopMonitoring()
                openedMaximumHeight = nil
            }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            deviceTile
            phoneTile
            if !model.daemonRunning || !model.accessibilityTrusted { serviceWarning }
            TaskActivitySection(model: model)
            sectionTitle(L10n.text("mac.settings"))
            shortcutGrid
            if model.agentLightsEnabled { hooksSection }
            footer
        }
        .padding(12)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openPhone(_ page: PhoneRemotePage) {
        PhoneRemoteNavigation.shared.page = page
        open("phone-remote")
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(VibeAppearance.faint)
            .padding(.leading, 4).padding(.top, 4)
    }

    // MARK: Status

    private var header: some View {
        HStack(spacing: 8) {
            Text("VibePier").font(.headline)
            Spacer()
            if model.refreshing { ProgressView().controlSize(.mini) }
            Text(
                model.daemonRunning
                    ? (model.accessibilityTrusted
                        ? L10n.text("mac.running_normally") : L10n.text("mac.permission_required"))
                    : L10n.text("mac.service_not_running")
            )
            .font(.caption).foregroundStyle(
                model.daemonRunning && model.accessibilityTrusted
                    ? VibeAppearance.secondary : VibeAppearance.warning)
        }
        .padding(.horizontal, 4).padding(.bottom, 2)
    }

    private var heartbeatName: String {
        switch model.heartbeatMode {
        case "auto": return L10n.text("mac.with_voice_key")
        case "off": return L10n.text("mac.off")
        default: return L10n.text("mac.always_on")
        }
    }

    private var lightName: String? {
        guard let mode = model.settings?.lights.mode else { return nil }
        return [L10n.text("mac.off_2"), L10n.text("mac.steady"), L10n.text("mac.working")][min(max(Int(mode), 0), 2)]
    }

    /// AU05 at a glance; the whole tile opens its settings window.
    private var deviceTile: some View {
        let linked = model.linkState == .linked
        return Button {
            open("au05-settings")
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(
                        symbol: model.statusIcon, tint: linked ? VibeAppearance.accent : VibeAppearance.secondary,
                        container: linked ? VibeAppearance.accentContainer : VibeAppearance.surface3, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("AU05").font(.subheadline.weight(.semibold))
                        Text(
                            linked
                                ? (model.firmware.isEmpty
                                    ? L10n.text("mac.connected")
                                    : L10n.text("mac.connected_firmware_0", model.firmware)) : model.statusText
                        )
                        .font(.caption).foregroundStyle(VibeAppearance.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    if let percent = model.batteryPercent, linked {
                        BatteryBar(percent: percent, charging: model.charging).frame(width: 92)
                    }
                }
                if linked {
                    HStack(spacing: 6) {
                        chip(L10n.text("mac.heartbeat_0", heartbeatName), highlighted: true)
                        if let lightName { chip(L10n.text("mac.light_0", lightName)) }
                        if let level = model.settings?.noiseReductionLevel {
                            chip(level > 0 ? L10n.text("mac.noise_reduction_on") : L10n.text("mac.noise_reduction_off"))
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vibeCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("mac.open_au05_device_settings"))
        .accessibilityLabel(L10n.text("mac.au05_0_open_device_settings", model.statusText))
    }

    private func chip(_ text: String, highlighted: Bool = false) -> some View {
        Text(text).font(.caption2.weight(.medium)).lineLimit(1)
            .foregroundStyle(highlighted ? VibeAppearance.accent : VibeAppearance.secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(
                highlighted ? VibeAppearance.accentContainer : VibeAppearance.surface2,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var phoneDetail: String {
        var parts: [String] = []
        if let address = model.remoteConnectedAddresses.first { parts.append("Wi-Fi · \(address)") }
        if model.bluetoothConnectedCount > 0 { parts.append(L10n.text("mac.bluetooth_confirmed_online")) }
        if model.relayConnectedCount > 0 { parts.append(L10n.text("mac.cloud_relay")) }
        if !parts.isEmpty { return parts.joined(separator: "，") }
        return model.remoteListening
            ? L10n.text("mac.open_vibepier_and_choose_wi_fi_or_bluetooth") : L10n.text("mac.disabled")
    }

    /// The phone remote at a glance; the tile opens the phone window on its connection page.
    private var phoneTile: some View {
        let connected = model.connectedRemoteCount > 0
        return Button {
            openPhone(.connection)
        } label: {
            HStack(spacing: 10) {
                IconBadge(
                    symbol: "iphone", tint: VibeAppearance.blue, container: VibeAppearance.blueContainer, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("mac.phone_remote")).font(.subheadline.weight(.semibold))
                    Text(phoneDetail).font(.caption).foregroundStyle(VibeAppearance.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                HStack(spacing: 5) {
                    Circle().fill(connected ? VibeAppearance.accent : VibeAppearance.faint).frame(width: 6, height: 6)
                    Text(
                        connected
                            ? (model.connectedRemoteCount > 1
                                ? L10n.text("mac.phones_0", model.connectedRemoteCount) : L10n.text("mac.connected"))
                            : L10n.text("mac.disconnected")
                    )
                    .font(.caption).foregroundStyle(connected ? VibeAppearance.accent : VibeAppearance.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .vibeCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("mac.open_phone_remote_settings"))
        .accessibilityLabel(L10n.text("mac.phone_remote_0_open_phone_remote_settings", phoneDetail))
    }

    // MARK: Service

    private var serviceWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                model.daemonRunning
                    ? L10n.text("mac.accessibility_permission_is_required_for_shortcuts")
                    : L10n.text("mac.control_service_is_not_running"), systemImage: "exclamationmark.triangle.fill"
            )
            .font(.subheadline.weight(.medium)).foregroundStyle(VibeAppearance.warning)
            HStack {
                if !model.daemonRunning {
                    Button(L10n.text("mac.start_now_and_at_login")) {
                        Task { await model.applySetting(["service", "install"]) }
                    }
                }
                if !model.accessibilityTrusted {
                    Button(L10n.text("mac.allow_shortcut_control")) {
                        NSWorkspace.shared.open(
                            URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .vibeCard(color: VibeAppearance.warningContainer)
    }

    // MARK: Settings

    private var shortcutGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
            gridButton(L10n.text("mac.au05_device"), "slider.horizontal.3") { open("au05-settings") }
            gridButton(L10n.text("mac.phone_remote_2"), "iphone") { openPhone(.connection) }
            gridButton(L10n.text("mac.session_access"), "bubble.left.and.bubble.right") { openPhone(.access) }
            gridButton(L10n.text("mac.au05_keys"), "keyboard") { open("bindings") }
        }
    }

    private func gridButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.caption).foregroundStyle(VibeAppearance.secondary).frame(width: 16)
                Text(title).font(.callout).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .vibeCard(radius: 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Hooks

    private var hooksSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if model.hooksLines.isEmpty {
                    Text(L10n.text("mac.no_ai_agent_hooks_detected")).font(.caption).foregroundStyle(
                        VibeAppearance.secondary)
                } else {
                    ForEach(model.hooksLines.prefix(5), id: \.self) { line in
                        // Format: "claude-code   0/13 events  /path/to/settings.json"
                        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.caption).foregroundStyle(.tint)
                            Text(String(parts.first ?? "")).font(.caption).monospaced()
                            Spacer()
                            if parts.count > 1 {
                                Text(L10n.text("mac.events_0", parts[1])).font(.caption).foregroundStyle(
                                    VibeAppearance.secondary)
                            }
                        }
                    }
                }
                HStack {
                    Button(L10n.text("mac.install_hooks")) {
                        Task {
                            await AppCommands.runQuiet(["hooks", "install"])
                            await model.refreshHooks()
                        }
                    }
                    Button(L10n.text("mac.uninstall_hooks")) {
                        Task {
                            await AppCommands.runQuiet(["hooks", "uninstall"])
                            await model.refreshHooks()
                        }
                    }
                    Spacer()
                }
            }
        } label: {
            Label(L10n.text("mac.ai_agent_status_light"), systemImage: "lightbulb").font(.subheadline)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Button(L10n.text("mac.logs")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/vibepier.log"))
                }
                Button(L10n.text("mac.config_folder")) {
                    NSWorkspace.shared.selectFile(
                        nil, inFileViewerRootedAtPath: NSHomeDirectory() + "/Library/Application Support/vibepier")
                }
                Menu(L10n.text("mac.more")) {
                    Button(L10n.text("mac.refresh_device_status")) { Task { await model.refresh() } }
                    if model.daemonRunning {
                        Button(L10n.text("mac.reload_configuration")) {
                            Task { await AppCommands.runQuiet(["reload"]) }
                        }
                        Button(
                            model.launchAtLogin
                                ? L10n.text("mac.disable_launch_at_login") : L10n.text("mac.enable_launch_at_login")
                        ) {
                            Task {
                                await model.applySetting(["service", model.launchAtLogin ? "uninstall" : "install"])
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .tint(VibeAppearance.secondary)
                Spacer()
                Button(L10n.text("mac.quit")) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(VibeAppearance.secondary)
            if let phase = commands.phase {
                HStack(spacing: 6) {
                    if phase == .running { ProgressView().controlSize(.mini) }
                    Text(
                        commands.operation + " · "
                            + L10n.text(
                                phase == .running
                                    ? "mac.preparing" : phase == .success ? "mac.saved" : "mac.operation_failed")
                    )
                    .font(.caption).foregroundStyle(
                        phase == .failure ? VibeAppearance.danger : VibeAppearance.secondary)
                    if commands.error != nil {
                        Button(L10n.text("mac.details")) { showCommandError = true }.font(.caption)
                    }
                }
                .sheet(isPresented: $showCommandError) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(commands.operation).font(.headline)
                        Text(commands.error ?? "").textSelection(.enabled)
                        Button(L10n.text("common.close")) { showCommandError = false }
                    }.padding(24).frame(width: 480)
                }
            }
        }
        .padding(.horizontal, 6).padding(.top, 4)
    }
}

struct BatteryBar: View {
    let percent: Int
    let charging: Bool

    var color: Color {
        switch percent {
        case ...20: return VibeAppearance.danger
        case ...50: return VibeAppearance.warning
        default: return VibeAppearance.accent
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(VibeAppearance.outline.opacity(0.3))
                    Capsule().fill(color)
                        .frame(width: geometry.size.width * CGFloat(min(100, max(0, percent))) / 100)
                }
            }.frame(height: 7)
            if charging { Image(systemName: "bolt.fill").foregroundStyle(VibeAppearance.accent) }
            Text("\(percent)%").font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(VibeAppearance.text)
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.3), value: percent)
    }

}

// MARK: - Bindings editor window

struct BindingsView: View {
    @ObservedObject var model: DeviceModel
    @State private var drafts: [String: String] = [:]
    @State private var feedback: String?
    @State private var feedbackFailed = false
    @State private var showKeys = false
    @State private var keyList: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("mac.each_control_accepts_1_4_keys_such_as_cmd_shift_4_return_fn_wheel_up"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(model.bindings) { binding in
                HStack(spacing: 10) {
                    Text(binding.control).monospaced().frame(width: 90, alignment: .leading)
                    TextField(binding.keys, text: bindingDraft(binding.control))
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.text("mac.apply")) {
                        guard let keys = drafts[binding.control], !keys.isEmpty else { return }
                        Task {
                            let ok = await model.setBinding(control: binding.control, keys: keys)
                            feedbackFailed = !ok
                            if ok {
                                drafts[binding.control] = nil
                                feedback = "\(binding.control) → \(keys) ✓"
                            } else {
                                feedback = L10n.text(
                                    "mac.could_not_set_0_1", binding.control,
                                    AppCommands.lastError ?? L10n.text("mac.unknown_error"))
                            }
                        }
                    }
                    .disabled((drafts[binding.control] ?? "").isEmpty)
                }
            }

            if let feedback {
                Text(feedback).font(.caption).foregroundStyle(
                    feedbackFailed ? VibeAppearance.danger : VibeAppearance.accent)
            }

            Divider()

            HStack {
                Button(L10n.text("mac.restore_all_firmware_defaults")) {
                    Task {
                        if await model.resetBindings() {
                            feedbackFailed = false
                            drafts = [:]
                            feedback = L10n.text("mac.firmware_bindings_restored")
                        } else {
                            feedbackFailed = true
                            feedback = AppCommands.lastError ?? L10n.text("mac.unknown_error")
                        }
                    }
                }
                .disabled(model.refreshing)
                Spacer()
                Button(showKeys ? L10n.text("mac.hide_key_names") : L10n.text("mac.show_all_key_names")) {
                    if keyList.isEmpty {
                        Task {
                            let r = await AppCommands.run(["keys"])
                            keyList =
                                r.success
                                ? r.stdout.split(separator: "\n").map(String.init)
                                : [L10n.text("mac.could_not_list_key_names_0", r.stderr)]
                        }
                    }
                    withAnimation { showKeys.toggle() }
                }
            }

            if showKeys {
                ScrollView {
                    Text(keyList.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 140)
                .padding(6)
                .vibeCard(radius: 6)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 380)
        .onAppear { Task { await model.refreshBindings() } }
    }

    private func bindingDraft(_ control: String) -> Binding<String> {
        Binding(
            get: { drafts[control] ?? "" },
            set: { drafts[control] = $0 }
        )
    }
}
