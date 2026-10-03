// SPDX-License-Identifier: MIT
//
// LaunchAgent management for `vibepier daemon`.

import Foundation

enum Service {
    static let label = "io.github.junweiup.vibepier"

    static var appExecutablePath: String {
        if Bundle.main.bundleURL.pathExtension == "app", let path = Bundle.main.executableURL?.path { return path }
        return "/Applications/VibePier.app/Contents/MacOS/VibePier"
    }

    static var appLoginEnabled: Bool {
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let arguments = plist["ProgramArguments"] as? [String]
        else { return false }
        return arguments.first?.hasSuffix("/VibePier.app/Contents/MacOS/VibePier") == true
    }

    /// Changes next-login behaviour without stopping the current menu app.
    static func configureAppLogin(enabled: Bool) throws {
        if enabled {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist(binary: appExecutablePath), format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: plistURL, options: .atomic)
        } else if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var persistedRelayProxy: String? {
        if let data = try? Data(contentsOf: plistURL),
            let job = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let variables = job["EnvironmentVariables"] as? [String: String],
            let proxy = variables["VIBEPIER_RELAY_PROXY"],
            !proxy.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return proxy
        }
        return ProcessInfo.processInfo.environment["VIBEPIER_RELAY_PROXY"]
    }

    static func plist(binary: String, relayProxy: String? = persistedRelayProxy) -> [String: Any] {
        var job: [String: Any] = [
            "Label": label,
            "ProgramArguments": binary.hasSuffix("/VibePier") ? [binary] : [binary, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardErrorPath": Paths.logFile.path,
            "StandardOutPath": Paths.logFile.path,
        ]
        // Preserve only the relay's explicit route when reinstalling or enabling login.
        // General HTTP(S)_PROXY must not propagate into desktop tools or child processes.
        if let relayProxy, RelayHTTPProxy.parse(relayProxy) != nil {
            job["EnvironmentVariables"] = [
                "VIBEPIER_RELAY_PROXY": relayProxy.trimmingCharacters(in: .whitespacesAndNewlines)
            ]
        }
        return job
    }

    static func install(binary: String) throws {
        let target = FileManager.default.isExecutableFile(atPath: appExecutablePath) ? appExecutablePath : binary
        let data = try PropertyListSerialization.data(fromPropertyList: plist(binary: target), format: .xml, options: 0)
        try FileManager.default.createDirectory(
            at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try data.write(to: plistURL, options: .atomic)
        var status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        for _ in 0..<5 where status != 0 {
            Thread.sleep(forTimeInterval: 0.2)
            status = launchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
        }
        if status != 0 {
            throw NSError(
                domain: "vibepier", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: L10n.text("cli.service_bootstrap_failed", status)])
        }
    }

    static func uninstall() throws {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    static func isLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(label)"], quiet: true) == 0
    }

    @discardableResult
    static func launchctl(_ args: [String], quiet: Bool = true) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        if quiet {
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
        }
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
