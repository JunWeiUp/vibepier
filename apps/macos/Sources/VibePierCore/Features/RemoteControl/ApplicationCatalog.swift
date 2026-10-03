import Foundation

/// Installed applications offered over the authenticated phone channel. Paths never leave the Mac.
enum ApplicationCatalog {
    struct Entry: Sendable {
        let bundleID: String
        let name: String
        var value: [String: Any] { ["bundleID": bundleID, "name": name] }
    }
    static func installed() -> [Entry] {
        let fm = FileManager.default
        let roots = [
            URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/System/Applications"),
            fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        var pending = roots.map { ($0, 0) }
        var found: [String: Entry] = [:]
        var inspected = 0
        while let (folder, depth) = pending.popLast(), inspected < 4096 {
            let children =
                (try? fm.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles])) ?? []
            for url in children.sorted(by: { $0.path < $1.path }).prefix(4096 - inspected) {
                inspected += 1
                if url.pathExtension.lowercased() == "app" {
                    guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                        !id.isEmpty, id.utf8.count <= 255, !id.contains(where: { $0.isWhitespace || $0 == "/" }),
                        bundle.executableURL != nil
                    else { continue }
                    let name =
                        bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                        ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                        ?? url.deletingPathExtension().lastPathComponent
                    found[id] = Entry(bundleID: id, name: String(name.prefix(128)))
                    if found.count >= 512 { break }
                } else if depth < 2,
                    let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                    values.isDirectory == true, values.isSymbolicLink != true
                {
                    pending.append((url, depth + 1))
                }
            }
            if found.count >= 512 { break }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func revision(_ ids: [String]?) -> String {
        CodexConversation.fingerprint(["applications": ApplicationShortcuts.normalized(ids)])
    }
    /// Compare-and-set makes transport retries harmless and prevents a stale phone overwriting a Mac edit.
    static func setting(index: Int, bundleID: String, revision expected: String, ids: [String]?, installed: Set<String>)
        throws -> [String]
    {
        var values = ApplicationShortcuts.normalized(ids)
        guard index >= 0, index < 64, index <= values.count, bundleID.isEmpty || installed.contains(bundleID) else {
            throw CLIError(L10n.text("control.application_selection_invalid"))
        }
        guard revision(values) == expected else {
            if values.indices.contains(index), values[index] == bundleID { return values }
            throw CLIError(L10n.text("control.application_selection_changed"))
        }
        if index == values.count {
            guard !bundleID.isEmpty else { throw CLIError(L10n.text("control.application_selection_invalid")) }
            values.append(bundleID)
        } else {
            values = try ApplicationShortcuts.applying(.set(index: index, bundleID: bundleID), to: values)
        }
        return values
    }
    static func reply(ids: [String]?, installed: [Entry]) -> [String: Any] {
        let values = ApplicationShortcuts.normalized(ids)
        let names = Dictionary(installed.map { ($0.bundleID, $0.name) }, uniquingKeysWith: { first, _ in first })
        return [
            "ok": true, "revision": revision(values), "applications": installed.map(\.value),
            "shortcuts": values.enumerated().map { index, id in
                ["slot": index, "bundleID": id, "name": id.isEmpty ? "" : names[id] ?? id] as [String: Any]
            },
        ]
    }
}
