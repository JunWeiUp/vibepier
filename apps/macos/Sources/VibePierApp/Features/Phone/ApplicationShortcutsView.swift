import SwiftUI
import UniformTypeIdentifiers
import VibePierCore

struct ApplicationShortcutsView: View {
    @ObservedObject var model: DeviceModel
    @State private var choosingApplication = false

    private var configuredCount: Int { model.applicationShortcuts.filter { !$0.bundleID.isEmpty }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("mac.phone_app_shortcuts")).font(.title2.bold())
                Spacer()
                Text(L10n.text("mac.apps_0", configuredCount)).font(.callout).foregroundStyle(VibeAppearance.secondary)
            }
            Text(L10n.text("mac.a_temporary_slot_on_the_phone_shows_the_active_app_when_it_is_not_al"))
                .font(.callout).foregroundStyle(VibeAppearance.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.applicationShortcuts) { item in
                            shortcutRow(item)
                                .id(item.slot)
                        }
                    }
                    .padding(.trailing, 4)
                }
                .onChange(of: model.applicationShortcuts.count) { oldCount, newCount in
                    if newCount > oldCount, oldCount > 0 {
                        withAnimation { proxy.scrollTo(newCount - 1, anchor: .bottom) }
                    }
                }
            }
            .disabled(model.refreshing || choosingApplication)
            Button {
                choose(nil)
            } label: {
                Label(L10n.text("mac.add_application"), systemImage: "plus")
            }
            .disabled(model.refreshing || choosingApplication || !model.daemonRunning)
            if !model.applicationShortcutError.isEmpty {
                Text(model.applicationShortcutError).font(.caption).foregroundStyle(VibeAppearance.danger)
            }
            Text(L10n.text("mac.changes_are_saved_automatically_and_synced_to_the_phone_over_an_auth"))
                .font(.caption).foregroundStyle(VibeAppearance.secondary)
        }
        .padding(22)
        .frame(width: 560, height: 620)
        .task { await model.refreshStatus() }
    }

    private func shortcutRow(_ item: ApplicationShortcut) -> some View {
        let index = item.slot
        let removable = model.applicationShortcuts.count > 5
        return HStack(spacing: 10) {
            Text("\(index + 1)").monospacedDigit().foregroundStyle(VibeAppearance.secondary).frame(width: 24)
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.bundleID),
                !item.bundleID.isEmpty
            {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
            } else {
                Image(systemName: "app.dashed").font(.title2).frame(width: 32, height: 32).foregroundStyle(
                    VibeAppearance.secondary)
            }
            VStack(alignment: .leading) {
                Text(item.name).lineLimit(1).help(item.name)
                if !item.bundleID.isEmpty, !item.available {
                    Text(L10n.text("mac.application_was_removed_choose_it_again")).font(.caption).foregroundStyle(
                        VibeAppearance.warning)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await model.moveApplicationShortcut(index: index, target: index - 1) }
            } label: {
                Image(systemName: "arrow.up")
            }.disabled(index == 0).help(L10n.text("mac.move_0_earlier", item.name)).accessibilityLabel(
                L10n.text("mac.move_0_earlier", item.name))
            Button {
                Task { await model.moveApplicationShortcut(index: index, target: index + 1) }
            } label: {
                Image(systemName: "arrow.down")
            }.disabled(index == model.applicationShortcuts.count - 1)
                .help(L10n.text("mac.move_0_later", item.name)).accessibilityLabel(
                    L10n.text("mac.move_0_later", item.name))
            Button(L10n.text("mac.choose_2")) { choose(index) }.help(L10n.text("mac.replace_application_0", index + 1))
            Button {
                Task { await model.removeApplicationShortcut(index: index) }
            } label: {
                Image(systemName: removable ? "minus.circle" : "xmark")
            }.disabled(!removable && item.bundleID.isEmpty)
                .help(removable ? L10n.text("mac.remove_0", item.name) : L10n.text("mac.clear_slot"))
                .accessibilityLabel(
                    removable ? L10n.text("mac.remove_0", item.name) : L10n.text("mac.clear_slot_0", index + 1))
        }
        .padding(10)
        .vibeCard(radius: 10)
    }

    private func choose(_ index: Int?) {
        choosingApplication = true
        let picker = NSOpenPanel()
        picker.title =
            index.map { L10n.text("mac.choose_application_0", $0 + 1) } ?? L10n.text("mac.add_phone_app_shortcut")
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications")
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.begin { response in
            Task { @MainActor in
                defer { choosingApplication = false }
                guard response == .OK, let url = picker.url else { return }
                guard let id = Bundle(url: url)?.bundleIdentifier else {
                    model.applicationShortcutError = L10n.text(
                        "mac.the_selected_app_has_no_valid_bundle_identifier_choose_another_app")
                    return
                }
                if let index {
                    await model.updateApplicationShortcut(index: index, bundleID: id)
                } else {
                    await model.addApplicationShortcut(bundleID: id)
                }
            }
        }
    }
}
