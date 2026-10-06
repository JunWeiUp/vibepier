import AppKit
import CryptoKit
import Foundation
import Security

/// Provider and desktop services routed after gateway admission: applications, account usage, screen lock and
/// the provider adapters reached through the session coordinator.
extension SessionRemote {
    /// All providers share the authorized device channel and require an explicit provider identity.
    func perform(
        _ data: Data, provider: String?, client: String, completion: @escaping @Sendable (Data) -> Void
    ) {
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ["applications", "applicationShortcutSet"].contains(request["op"] as? String ?? "")
        {
            // Only these two configuration commands may cross from the authenticated phone to the local runtime.
            // Rebuild the allowlisted payload; never forward a caller-supplied local command.
            DispatchQueue.global(qos: .userInitiated).async {
                let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                var command: [String: Any] = [
                    "cmd": fields["op"] as? String == "applications" ? "phone-applications" : "phone-application-set"
                ]
                for key in ["index", "bundleID", "revision"] { command[key] = fields[key] }
                let reply =
                    ControlSocket.request(command, timeout: 8) ?? [
                        "ok": false, "error": L10n.text("control.application_selection_unavailable"),
                    ]
                completion((try? JSONSerialization.data(withJSONObject: reply)) ?? Data())
            }
            return
        }
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            ["codexUsage", "codexUsageReset", "codexUsageResetReceipt"].contains(request["op"] as? String ?? "")
        {
            codexUsage.perform(data, client: client, completion: completion)
            return
        }
        if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let operation = request["op"] as? String, ["lockScreen", "unlockScreen"].contains(operation)
        {
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: Any]
                do {
                    if operation == "lockScreen" { try ScreenLock.lockNow() } else { try ScreenLock.unlockNow() }
                    result = ScreenLock.status()
                } catch {
                    result = [
                        "ok": false, "error": String(describing: error), "locked": ScreenLock.locked(),
                        "configured": ScreenLock.configured(),
                    ]
                }
                completion((try? JSONSerialization.data(withJSONObject: result)) ?? Data())
            }
            return
        }
        coordinator.performCurrentV1(data, provider: provider, trustedClient: client, completion: completion)
    }
}
