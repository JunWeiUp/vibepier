import Foundation

/// Mac-owned visibility. Unknown providers never acquire access through a default.
public struct SessionProviderPolicy: Equatable, Sendable {
    public static let ids = SessionV1Contract.providers
    public let enabled: [String: Bool]
    let revision: Int64

    init(enabled: [String: Bool]? = nil, revision: Int64 = 0) {
        self.enabled = Dictionary(uniqueKeysWithValues: Self.ids.map { ($0, enabled?[$0] ?? true) })
        self.revision = max(0, revision)
    }

    init(_ config: Config) {
        self.init(enabled: config.sessionProviders, revision: config.sessionProviderRevision ?? 0)
    }

    public func isEnabled(_ provider: String) -> Bool { enabled[provider] == true }

    var object: [String: Any] { ["revision": revision, "enabled": enabled] }

    static func provider(_ request: [String: Any]) -> String {
        if SessionV1Contract.descriptor(request["op"] as? String ?? "")?.routeDomain == "account" { return "codex" }
        let value = request["provider"] as? String ?? "codex"
        return value.isEmpty ? "codex" : value
    }

    static func contentProvider(_ request: [String: Any]) -> String? {
        let op = request["op"] as? String ?? ""
        return SessionV1Contract.descriptor(op)?.contentProviderScope == false ? nil : provider(request)
    }

    func permits(_ request: [String: Any], recordedMutation: Bool = false) -> Bool {
        let op = request["op"] as? String ?? ""
        // Cleanup and read-only reconciliation never submit the original action again.
        if recordedMutation || SessionV1Contract.descriptor(op)?.providerPolicyExempt == true {
            return true
        }
        return isEnabled(Self.provider(request))
    }

    static let receiptOperations = Set(
        SessionV1Contract.operations.filter {
            $0.name == "receipt" || $0.name.hasSuffix("ReceiptCheck") || $0.name == "receiptCheck"
                || $0.name == "codexUsageResetReceipt"
        }.map(\.name))
    static let independentOperations = Set(
        SessionV1Contract.operations.filter {
            $0.providerPolicyExempt && !receiptOperations.contains($0.name)
        }.map(\.name))
}

extension Config {
    func settingSessionProvider(_ provider: String, enabled: Bool, minimumRevision: Int64 = 0) throws -> Config {
        guard SessionProviderPolicy.ids.contains(provider) else {
            throw CLIError(L10n.text("providers.invalid_setting"))
        }
        var values = SessionProviderPolicy(self).enabled
        guard values[provider] != enabled else { return self }
        let revision = max(sessionProviderRevision ?? 0, minimumRevision)
        guard revision >= 0, revision < Int64.max else {
            throw CLIError(L10n.text("providers.invalid_setting"))
        }
        values[provider] = enabled
        var result = self
        result.sessionProviders = values
        result.sessionProviderRevision = revision + 1
        return result
    }
}
