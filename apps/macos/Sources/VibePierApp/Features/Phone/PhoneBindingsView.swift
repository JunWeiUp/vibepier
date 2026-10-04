import AppKit
import SwiftUI
import VibePierCore

struct PhoneBindingsView: View {
    @ObservedObject var model: DeviceModel
    @State private var snapshot = PhoneBindings.shared.snapshot
    @State private var profile = ""
    @State private var addedApps: [String: String] = [:]
    @State private var editing: Editing?
    @State private var message = ""
    private struct Editing: Identifiable {
        let id: String
        let key: String
        let app: String
        let version: String
        let value: String
        let label: String
    }
    private let titles = [
        "knob-left": L10n.text("mac.rotate_left"), "knob-right": L10n.text("mac.rotate_right"),
        "cancel": L10n.text("mac.cancel"), "confirm": L10n.text("mac.confirm"), "talk": L10n.text("mac.voice"),
        "knob-press": L10n.text("mac.delete"),
    ]
    private let symbols = [
        "knob-left": "arrow.up", "knob-right": "arrow.down", "cancel": "xmark", "confirm": "checkmark", "talk": "mic",
        "knob-press": "delete.left",
    ]
    private var applications: [String: String] {
        var apps = addedApps
        for (key, entry) in snapshot.entries {
            if let id = PhoneBindings.application(for: key), entry.value != nil {
                apps[id] = entry.name.isEmpty ? id : entry.name
            }
        }
        for app in model.applicationShortcuts where !app.bundleID.isEmpty { apps[app.bundleID] = app.name }
        return apps
    }
    private var profileName: String {
        profile.isEmpty ? L10n.text("mac.general_profile") : applications[profile] ?? profile
    }
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("mac.profile_scope")).font(.caption).foregroundStyle(VibeAppearance.secondary).padding(
                    .horizontal, 12)
                List(selection: $profile) {
                    Label(L10n.text("mac.general_profile"), systemImage: "square.grid.2x2").tag("")
                    Section(L10n.text("mac.per_application")) {
                        ForEach(
                            applications.keys.sorted {
                                (applications[$0] ?? $0).localizedStandardCompare(applications[$1] ?? $1)
                                    == .orderedAscending
                            }, id: \.self
                        ) { id in
                            Text(applications[id] ?? id).lineLimit(1).help(id).tag(id)
                        }
                    }
                }.listStyle(.sidebar)
                Button {
                    chooseApplication()
                } label: {
                    Label(L10n.text("mac.choose_application"), systemImage: "plus")
                }
                .padding(.horizontal, 12)
            }.padding(.vertical, 16).frame(width: 180)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(profileName).font(.title2.bold()).lineLimit(1)
                        Text(
                            profile.isEmpty
                                ? L10n.text("mac.default_bindings_for_all_applications")
                                : L10n.text("mac.the_phone_uses_these_bindings_when_this_application_is_active")
                        )
                        .font(.caption).foregroundStyle(VibeAppearance.secondary)
                    }
                    Spacer()
                    Image(systemName: "iphone").font(.title2).foregroundStyle(VibeAppearance.secondary)
                }
                VStack(spacing: 0) {
                    ForEach(PhoneBindings.controls, id: \.self) { control in
                        let entry = snapshot.entries[PhoneBindings.key(control, app: profile)]
                        HStack(spacing: 12) {
                            Image(systemName: symbols[control] ?? "keyboard").frame(width: 24).foregroundStyle(
                                VibeAppearance.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(controlTitle(control)).fontWeight(.medium)
                                Text(
                                    control == "talk"
                                        ? L10n.text("mac.hold_to_press_release_to_stop")
                                        : control == "knob-press"
                                            ? L10n.text("mac.hold_to_repeat")
                                            : control.hasPrefix("knob-")
                                                ? L10n.text("mac.tap_once_hold_to_repeat")
                                                : L10n.text("mac.tap_to_trigger")
                                )
                                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                            }.frame(width: 124, alignment: .leading)
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(PhoneBindings.label(PhoneBindings.shared.resolved(control, app: profile))).font(
                                    .system(.body, design: .monospaced))
                                Text(
                                    entry?.value != nil
                                        ? L10n.text("mac.customized")
                                        : profile.isEmpty
                                            ? L10n.text("mac.default") : L10n.text("mac.use_general_profile")
                                )
                                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                            }
                            Button(L10n.text("mac.edit")) {
                                editing = Editing(
                                    id: control, key: PhoneBindings.key(control, app: profile), app: profile,
                                    version: entry?.version ?? "",
                                    value: PhoneBindings.shared.resolved(control, app: profile),
                                    label: controlTitle(control))
                            }.accessibilityLabel(L10n.text("mac.edit_0_shortcut", controlTitle(control)))
                        }.padding(.vertical, 12).padding(.horizontal, 14)
                        if control != PhoneBindings.controls.last { Divider().padding(.leading, 50) }
                    }
                }.vibeCard(radius: 12)
                Label(
                    model.connectedRemoteCount > 0
                        ? L10n.text("mac.phone_connected_changes_sync_automatically")
                        : L10n.text("mac.saved_on_the_mac_syncs_when_the_phone_connects"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(VibeAppearance.danger) }
            }.padding(24).frame(width: 520)
        }
        .frame(minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: PhoneBindings.changed).receive(on: RunLoop.main)) { _ in
            snapshot = PhoneBindings.shared.snapshot
        }
        .sheet(item: $editing) { item in
            PhoneKeyEditor(
                title: item.label, profile: profileName, value: item.value, label: item.label,
                resetTitle: item.app.isEmpty ? L10n.text("mac.restore_defaults") : L10n.text("mac.use_general_profile")
            ) { value, label in
                do {
                    guard
                        try PhoneBindings.shared.set(
                            key: item.key, value: value, name: applications[item.app] ?? "", label: label,
                            expectedVersion: item.version)
                    else {
                        return L10n.text("mac.this_binding_was_changed_on_the_phone_close_and_reopen_the_editor")
                    }
                    if !item.app.isEmpty { addedApps[item.app] = applications[item.app] ?? item.app }
                    snapshot = PhoneBindings.shared.snapshot
                    editing = nil
                    message = ""
                    return nil
                } catch { return L10n.text("mac.could_not_save_0", error) }
            }
        }
    }
    private func controlTitle(_ control: String) -> String {
        PhoneBindings.shared.resolvedLabel(control, app: profile, fallback: titles[control] ?? control)
    }
    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = L10n.text("mac.choose")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
            let id = bundle.bundleIdentifier
        else { return }
        addedApps[id] =
            (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        profile = id
    }
}

struct PhoneKeyEditor: View {
    let title: String
    let profile: String
    @State var value: String
    @State var label: String
    let resetTitle: String
    let save: (String?, String?) -> String?
    @State private var error = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("mac.0_shortcut", title)).font(.title2.bold())
                Text(profile).font(.subheadline).foregroundStyle(VibeAppearance.secondary)
            }
            TextField(L10n.text("mac.key_name"), text: $label)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(L10n.text("mac.key_name"))
            TextField(L10n.text("mac.for_example_cmd_ctrl_cmd_return_rcmd"), text: $value)
                .textFieldStyle(.roundedBorder).onSubmit { commit(value) }
                .accessibilityLabel(L10n.text("mac.shortcut_combination"))
            HStack {
                ForEach(
                    [("cmd", "⌘ Command"), ("ctrl", "⌃ Control"), ("alt", "⌥ Option"), ("shift", "⇧ Shift")], id: \.0
                ) { key, title in
                    Toggle(
                        title,
                        isOn: Binding(
                            get: { PhoneBindings.hasModifier(value, modifier: key) },
                            set: { enabled in
                                do {
                                    value = try PhoneBindings.togglingModifier(value, modifier: key, enabled: enabled)
                                    error = ""
                                } catch {
                                    self.error = L10n.text(
                                        "mac.enter_valid_keys_first_a_combination_can_contain_up_to_4_keys")
                                }
                            }
                        )
                    ).toggleStyle(.button)
                }
            }
            HStack {
                Text(L10n.text("mac.common_keys")).foregroundStyle(VibeAppearance.secondary)
                Menu(L10n.text("mac.choose_2")) {
                    ForEach(
                        [
                            "rcmd", "fn", "return", "escape", "backspace", "space", "tab", "wheel-up", "wheel-down",
                            "cmd+ctrl", "cmd+c", "cmd+v", "cmd+z", "k",
                        ], id: \.self
                    ) { key in
                        Button(PhoneBindings.label(key)) {
                            do {
                                value = try PhoneBindings.choosingPreset(key, text: value)
                                error = ""
                            } catch {
                                self.error = L10n.text(
                                    "mac.enter_valid_keys_first_a_combination_can_contain_up_to_4_keys")
                            }
                        }
                    }
                }.frame(width: 130)
            }.font(.callout)
            Text(L10n.text("mac.supports_single_keys_modifier_only_combinations_and_up_to_4_keys_the"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
            if !error.isEmpty { Text(error).foregroundStyle(VibeAppearance.danger).font(.caption) }
            Divider()
            HStack {
                Button(resetTitle) { commit(nil) }
                Spacer()
                Button(L10n.text("mac.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.text("mac.save")) { commit(value) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 490)
    }
    private func commit(_ value: String?) {
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if value != nil && (name.isEmpty || name.count > 200) {
            error = L10n.text("mac.key_name_required")
            return
        }
        if let message = save(value, value == nil ? nil : name) { error = message }
    }
}
