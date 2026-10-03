import Darwin
import Foundation

/// File operations live in the invoking CLI; the running app owns config changes and phone synchronization.
enum PreferencesCommand {
    static func run(_ arguments: [String], request: ([String: Any]) -> [String: Any]?) throws {
        guard arguments.count == 2 || (arguments.count == 3 && arguments[2] == "--dry-run"),
            ["export", "import"].contains(arguments[0]),
            arguments[0] == "import" || arguments.count == 2
        else { throw CLIError(L10n.text("cli.preferences_usage")) }
        let file = URL(fileURLWithPath: arguments[1])
        let command = arguments[0]
        var payload: [String: Any] = ["cmd": "preferences-export"]
        if command == "export" {
            guard !FileManager.default.fileExists(atPath: file.path) else {
                throw CLIError(L10n.text("core.the_export_file_already_exists_choose_a_new_filename"))
            }
        } else {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            let archive = try PreferencesArchive.decode(
                handle.read(upToCount: PreferencesArchive.maximumBytes + 1) ?? Data())
            payload = [
                "cmd": arguments.count == 3 ? "preferences-preview" : "preferences-import",
                "archive": try JSONSerialization.jsonObject(with: archive.encoded()),
            ]
        }
        guard let reply = request(payload) else { throw CLIError(L10n.text("core.open_vibepier_on_this_mac_first")) }
        guard reply["ok"] as? Bool == true else {
            throw CLIError(reply["error"] as? String ?? L10n.text("core.the_settings_operation_failed"))
        }
        if command == "export" {
            guard let document = reply["archive"] else {
                throw CLIError(L10n.text("core.invalid_settings_export_receipt"))
            }
            let archive = try PreferencesArchive.decode(JSONSerialization.data(withJSONObject: document))
            let temporary = file.deletingLastPathComponent().appendingPathComponent(
                ".vibepier-export-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? output.close() }
            try output.write(contentsOf: archive.encoded())
            try output.synchronize()
            // A same-directory hard link publishes the complete file atomically and refuses replacement.
            try FileManager.default.linkItem(at: temporary, to: file)
            print(L10n.text("core.exported_shortcuts_device_settings_and_app_shortcuts_passwords_pairi"))
        } else {
            print(
                arguments.count == 3
                    ? L10n.text("core.settings_archive_validated_no_configuration_was_changed")
                    : L10n.text("core.settings_imported_bindings_will_sync_when_the_phone_connects"))
        }
    }
}
