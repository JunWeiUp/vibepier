import Foundation

/// Parses a relay setup request without reading Keychain data or starting a connection.
enum RelayCommand {
    static func payload(
        _ arguments: [String],
        readSecret: (String) throws -> Data = {
            let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: $0))
            defer { try? file.close() }
            return try file.read(upToCount: 1025) ?? Data()
        }
    ) throws -> [String: String] {
        guard let action = arguments.first else { throw CLIError(usage) }
        if action == "status", arguments.count == 1 { return ["cmd": "status"] }
        if action == "disable", arguments.count == 1 {
            return ["cmd": "relay-config", "url": "", "room": "", "secret": ""]
        }
        guard action == "configure", [7, 9].contains(arguments.count) else { throw CLIError(usage) }
        var values: [String: String] = [:]
        for index in stride(from: 1, to: arguments.count, by: 2) {
            let key = arguments[index]
            guard ["--url", "--room", "--secret-file", "--dns-recovery"].contains(key), values[key] == nil else {
                throw CLIError(usage)
            }
            values[key] = arguments[index + 1]
        }
        guard let url = values["--url"], let room = values["--room"], let path = values["--secret-file"] else {
            throw CLIError(usage)
        }
        let dns = values["--dns-recovery"] ?? "system"
        guard ["system", "alidns"].contains(dns) else { throw CLIError(usage) }
        let data = try readSecret(path)
        guard data.count <= 1024, let text = String(data: data, encoding: .utf8),
            let settings = RelaySettings(
                url: url, room: room, secret: text.trimmingCharacters(in: .whitespacesAndNewlines),
                dnsRecovery: dns == "alidns")
        else { throw CLIError(L10n.text("cli.invalid_relay")) }
        return [
            "cmd": "relay-config", "url": settings.url.absoluteString, "room": settings.room, "secret": settings.secret,
            "dnsRecovery": dns,
        ]
    }
    static let usage =
        "vibepier relay status|disable|configure --url wss://relay.example.com/vibepier/relay --room my-mac --secret-file /private/path/relay.secret [--dns-recovery system|alidns]"
}
