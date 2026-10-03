import AVFAudio
import SwiftUI
import VibePierCore

struct AU05SettingsView: View {
    @ObservedObject var model: DeviceModel
    @State private var brightness: Double = 0
    @State private var adjustingBrightness = false
    @State private var microphonePermission = AVAudioApplication.shared.recordPermission

    private var hardwareAvailable: Bool { model.linkState == .linked && model.settings != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            deviceStatus
            group(L10n.text("mac.connection_and_audio")) {
                settingRow(
                    L10n.text("mac.device_heartbeat"),
                    detail: L10n.text("mac.always_on_by_default_experimental_on_demand_mode_may_lose_initial_sp")
                ) {
                    Picker(
                        L10n.text("mac.device_heartbeat"),
                        selection: Binding(
                            get: { model.heartbeatMode },
                            set: { mode in Task { await model.setHeartbeatMode(mode) } }
                        )
                    ) {
                        Text(L10n.text("mac.on_demand_experimental")).tag("auto")
                        Text(L10n.text("mac.always_on")).tag("on")
                        Text(L10n.text("mac.off")).tag("off")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 250)
                        .disabled(!model.daemonRunning || model.refreshing)
                }
                Divider()
                settingRow(
                    L10n.text("mac.system_input"),
                    detail: L10n.text("mac.hold_the_voice_key_to_use_au05_release_to_restore_the_previous_input")
                ) {
                    VStack(alignment: .trailing, spacing: 6) {
                        Picker(L10n.text("mac.system_input"), selection: inputDeviceBinding) {
                            ForEach(model.inputDevices) { device in Text(device.name).tag(device.uid) }
                        }.labelsHidden().frame(width: 220)
                            .disabled(model.inputDevices.isEmpty || model.refreshing)
                        if microphonePermission != .granted {
                            Button(
                                microphonePermission == .denied
                                    ? L10n.text("mac.open_microphone_permissions")
                                    : L10n.text("mac.allow_audio_device_access")
                            ) {
                                if microphonePermission == .denied {
                                    NSWorkspace.shared.open(
                                        URL(
                                            string:
                                                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                                        )!)
                                } else {
                                    AVAudioApplication.requestRecordPermission { _ in
                                        Task { @MainActor in
                                            microphonePermission = AVAudioApplication.shared.recordPermission
                                            model.refreshAudioDevices()
                                        }
                                    }
                                }
                            }.font(.caption)
                        }
                    }
                }
                Divider()
                settingRow(L10n.text("mac.noise_reduction")) {
                    Toggle(L10n.text("mac.noise_reduction"), isOn: denoiseBinding).labelsHidden().toggleStyle(.switch)
                        .disabled(!hardwareAvailable || model.refreshing)
                }
            }
            group(L10n.text("mac.standby_and_sleep")) {
                settingRow(L10n.text("mac.auto_standby"), detail: L10n.text("mac.enter_standby_after_inactivity")) {
                    Picker(L10n.text("mac.auto_standby"), selection: standbyBinding) {
                        Text(L10n.text("mac.5_minutes")).tag(300)
                        Text(L10n.text("mac.30_minutes")).tag(1800)
                        Text(L10n.text("mac.1_hour")).tag(3600)
                        Text(L10n.text("mac.4_hours")).tag(14400)
                        Text(L10n.text("mac.12_hours")).tag(43200)
                    }.labelsHidden().frame(width: 140)
                }
                Divider()
                settingRow(
                    L10n.text("mac.auto_sleep"),
                    detail: L10n.text("mac.power_off_after_standby_never_disables_automatic_power_off")
                ) {
                    Picker(L10n.text("mac.auto_sleep"), selection: sleepBinding) {
                        Text(L10n.text("mac.never")).tag(0)
                        Text(L10n.text("mac.1_hour")).tag(3600)
                        Text(L10n.text("mac.2_hours")).tag(7200)
                        Text(L10n.text("mac.3_hours")).tag(10800)
                        Text(L10n.text("mac.4_hours")).tag(14400)
                    }.labelsHidden().frame(width: 140)
                }
            }.disabled(!hardwareAvailable || model.refreshing)
            group(L10n.text("mac.light_and_sound")) {
                settingRow(L10n.text("mac.light_mode")) {
                    Picker(L10n.text("mac.light_mode"), selection: lightModeBinding) {
                        Text(L10n.text("mac.off")).tag(0)
                        Text(L10n.text("mac.steady")).tag(1)
                        Text(L10n.text("mac.working")).tag(2)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Divider()
                settingRow(L10n.text("mac.brightness")) {
                    Slider(value: $brightness, in: 0...20, step: 1) { editing in
                        adjustingBrightness = editing
                        if !editing, hardwareAvailable, Int(brightness) != model.settings?.lights.allOnBrightness {
                            Task { await model.applySetting(["set", "brightness", String(Int(brightness))]) }
                        }
                    }.accessibilityLabel(L10n.text("mac.light_brightness")).frame(width: 180)
                    Text("\(Int(brightness)) / 20").monospacedDigit().foregroundStyle(VibeAppearance.secondary).frame(
                        width: 52, alignment: .trailing)
                }
            }.disabled(!hardwareAvailable || model.refreshing)
            if !model.deviceSettingError.isEmpty {
                Text(model.deviceSettingError).font(.callout).foregroundStyle(VibeAppearance.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(
                    hardwareAvailable
                        ? L10n.text("mac.settings_are_written_to_the_device")
                        : L10n.text("mac.connect_au05_to_change_device_settings")
                )
                .font(.callout).foregroundStyle(VibeAppearance.secondary)
                Spacer()
                Button {
                    Task {
                        microphonePermission = AVAudioApplication.shared.recordPermission
                        model.refreshAudioDevices()
                        await model.refresh()
                    }
                } label: {
                    Label(L10n.text("mac.refresh_device_status"), systemImage: "arrow.clockwise")
                }.disabled(model.refreshing)
            }
        }
        .padding(24)
        .frame(width: 570)
        .task {
            await model.preparePanel()
            model.refreshAudioDevices()
            brightness = Double(model.settings?.lights.allOnBrightness ?? 0)
        }
        .onChange(of: model.settings?.lights.allOnBrightness) { _, value in
            if !adjustingBrightness { brightness = Double(value ?? 0) }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(VibeAppearance.faint).padding(.leading, 4)
            VStack(spacing: 0) { content() }
                .padding(.horizontal, 14)
                .vibeCard(radius: 12)
        }
    }

    private func settingRow<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control)
        -> some View
    {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(VibeAppearance.secondary) }
            }
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 11)
    }

    private var heartbeatName: String {
        switch model.heartbeatMode {
        case "auto": return L10n.text("mac.on_demand_experimental_2")
        case "off": return L10n.text("mac.off")
        default: return L10n.text("mac.always_on")
        }
    }

    private var deviceStatus: some View {
        let linked = model.linkState == .linked
        return HStack(spacing: 16) {
            Image(systemName: "mic.fill").font(.system(size: 28)).foregroundStyle(VibeAppearance.accent)
                .frame(width: 60, height: 60)
                .background(VibeAppearance.accentContainer, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("AU05").font(.title2.bold())
                HStack(spacing: 6) {
                    Circle().fill(linked ? VibeAppearance.accent : VibeAppearance.faint).frame(width: 7, height: 7)
                    Text(linked ? L10n.text("mac.connected") : model.statusText).foregroundStyle(
                        linked ? VibeAppearance.accent : VibeAppearance.secondary)
                    Text(
                        model.firmware.isEmpty
                            ? L10n.text("mac.firmware_version_not_read_yet")
                            : L10n.text("mac.firmware_0", model.firmware)
                    ).foregroundStyle(
                        VibeAppearance.secondary)
                }.font(.callout)
            }
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
            if let percent = model.batteryPercent, linked {
                stat(
                    model.charging
                        ? (model.chargeFull ? L10n.text("mac.fully_charged") : L10n.text("mac.charging"))
                        : L10n.text("mac.battery"), "\(percent)%")
            }
            stat(L10n.text("mac.heartbeat"), heartbeatName)
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(VibeAppearance.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minWidth: 76, alignment: .leading)
        .vibeCard(radius: 11, color: VibeAppearance.surface2)
    }

    private var lightModeBinding: Binding<Int> {
        Binding(
            get: { model.settings?.lights.mode ?? 0 },
            set: { mode in
                let name = ["off", "on", "work"][min(max(mode, 0), 2)]
                Task { await model.applySetting(["set", "light-mode", name]) }
            }
        )
    }

    private var denoiseBinding: Binding<Bool> {
        Binding(
            get: { (model.settings?.noiseReductionLevel ?? 0) > 0 },
            set: { on in
                Task { await model.applySetting(["set", "denoise", on ? "on" : "off"]) }
            }
        )
    }

    private var sleepBinding: Binding<Int> {
        Binding(
            get: { model.settings?.sleepTimeSeconds ?? 0 },
            set: { seconds in
                let arg: String
                switch seconds {
                case 0: arg = "off"
                case 3600: arg = "1h"
                case 7200: arg = "2h"
                case 10800: arg = "3h"
                default: arg = "4h"
                }
                Task { await model.applySetting(["set", "sleep", arg]) }
            }
        )
    }

    /// Standby is a shallower power save than sleep: the mic still links but the
    /// first key press only wakes it. Longer standby = fewer missed presses.
    private var standbyBinding: Binding<Int> {
        Binding(
            get: { model.settings?.standbyTimeSeconds ?? 300 },
            set: { seconds in
                Task { await model.applySetting(["set", "standby-time", String(seconds)]) }
            }
        )
    }

    private var inputDeviceBinding: Binding<String> {
        Binding(
            get: { model.defaultInputUID ?? "" },
            set: { uid in
                guard let dev = model.inputDevices.first(where: { $0.uid == uid }) else { return }
                model.switchInput(to: dev)
            }
        )
    }

}
