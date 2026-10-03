import Foundation

/// Account-scoped usage, separate from session selection. All redemption is explicit,
/// serialized and covered by the same durable mutation journal as other phone actions.
final class CodexUsage: @unchecked Sendable {
    private let queue = DispatchQueue(label: "vibepier.codex-account")
    private let receipts = ProviderOperationReceipts()
    private let connect: @Sendable () throws -> CodexAccountRequesting
    private let clock: @Sendable () -> TimeInterval
    init(
        connect: @escaping @Sendable () throws -> CodexAccountRequesting = { try CodexAccountRPC() },
        clock: @escaping @Sendable () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.connect = connect
        self.clock = clock
    }

    func perform(_ data: Data, client: String, completion: @escaping @Sendable (Data) -> Void) {
        queue.async {
            let value: [String: Any]
            do {
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw CLIError(L10n.text("core.invalid_request"))
                }
                value = try self.reply(request, client: client)
            } catch { value = ProviderFailure.reply(error, provider: "codex") }
            completion((try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
    }

    func reply(_ request: [String: Any], client: String) throws -> [String: Any] {
        let op = request["op"] as? String ?? ""
        if op == "codexUsageResetReceipt" {
            return receipts.lookup(
                client: client, operation: request["operation"] as? String ?? "", thread: "", kind: "codexUsageReset")
        }
        guard ["codexUsage", "codexUsageReset"].contains(op) else {
            throw CLIError(L10n.text("core.invalid_request"))
        }
        var ticket: ProviderOperationReceipts.Ticket?
        if op == "codexUsageReset" {
            switch try receipts.begin(request, client: client) {
            case .cached(let value): return value
            case .fresh(let value): ticket = value
            }
        }
        do {
            let rpc = try connect()
            defer { rpc.close() }
            let current = try Self.project(
                rpc.request("account/rateLimits/read", params: ["excludeResetCreditDetails": false], mutable: false),
                now: clock())
            guard let ticket else { return current }
            let account = request["accountId"] as? String ?? ""
            let credit = request["creditId"] as? String ?? ""
            guard SessionProviderReply.boolean(request["confirm"]) == true, !account.isEmpty,
                account == current["accountId"] as? String, !credit.isEmpty, credit.utf8.count <= 512,
                let operation = request["id"] as? String, UUID(uuidString: operation) != nil
            else { throw CLIError(L10n.text("usage.account_changed")) }
            guard current["resetEligible"] as? Bool == true else {
                throw CLIError(L10n.text("usage.not_eligible"))
            }
            guard let count = current["availableCount"] as? Int, count > 0 else {
                throw CLIError(L10n.text("usage.no_credit"))
            }
            guard
                (current["resetCards"] as? [[String: Any]] ?? []).contains(where: {
                    $0["id"] as? String == credit && $0["available"] as? Bool == true
                })
            else { throw CLIError(L10n.text("usage.card_changed")) }
            // Scoped to the authenticated phone, account and original operation, never a phone-supplied RPC key.
            let key = CodexConversation.fingerprint([
                "scope": "codex-usage-reset-v1", "client": client, "account": account, "operation": operation,
            ])
            let params: [String: Any] = ["idempotencyKey": key, "creditId": credit]
            let outcome = try UnconfirmedDesktopMutation.attempting {
                let value = try rpc.request("account/rateLimitResetCredit/consume", params: params, mutable: true)
                guard let outcome = value["outcome"] as? String,
                    ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"].contains(outcome)
                else { throw CLIError(L10n.text("core.invalid_receipt")) }
                return outcome
            }
            // A successful redemption remains successful even if the subsequent refresh fails.
            return receipts.finish(
                ticket,
                result: [
                    "ok": true, "provider": "codex", "accountId": account, "creditId": credit,
                    "outcome": outcome, "accepted": ["reset", "alreadyRedeemed"].contains(outcome),
                ])
        } catch {
            let value = ProviderFailure.reply(error, provider: "codex")
            if let ticket { return receipts.finish(ticket, result: value) }
            throw error
        }
    }

    static func project(_ source: [String: Any], now: TimeInterval) throws -> [String: Any] {
        guard source["rateLimits"] is [String: Any] else { throw CLIError(L10n.text("usage.unavailable")) }
        func integer(_ value: Any?, maximum: Double = 253_402_300_799) -> Int? {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                number.doubleValue.isFinite, number.doubleValue >= 0, number.doubleValue <= maximum,
                number.doubleValue.rounded() == number.doubleValue
            else { return nil }
            return number.intValue
        }
        var windows: [[String: Any]] = []
        var eligible = false
        let buckets =
            source["rateLimitsByLimitId"] as? [String: [String: Any]]
            ?? ["codex": source["rateLimits"] as? [String: Any] ?? [:]]
        guard buckets.count <= 32 else { throw CLIError(L10n.text("usage.unavailable")) }
        for key in buckets.keys.sorted() {
            let bucket = buckets[key]!
            for slot in ["primary", "secondary"] {
                guard let window = bucket[slot] as? [String: Any],
                    let used = integer(window["usedPercent"], maximum: 100_000)
                else { continue }
                let minutes = integer(window["windowDurationMins"])
                let resets = integer(window["resetsAt"])
                windows.append([
                    "limitId": String(key.prefix(100)),
                    "name": String((bucket["limitName"] as? String ?? key).prefix(160)),
                    "slot": slot, "remainingPercent": max(0, 100 - used),
                    "windowDurationMins": minutes as Any? ?? NSNull(), "resetsAt": resets as Any? ?? NSNull(),
                ])
                if key == "codex", minutes == 300 || minutes == 10_080, used >= 90,
                    resets == nil || Double(resets!) > now
                {
                    eligible = true
                }
            }
        }
        let summary = source["rateLimitResetCredits"] as? [String: Any]
        let rawCards = summary?["credits"] as? [[String: Any]]
        let cards: [[String: Any]] = (rawCards ?? []).prefix(100).compactMap { row in
            guard let id = row["id"] as? String, !id.isEmpty, id.utf8.count <= 512 else { return nil }
            let expiry = integer(row["expiresAt"])
            return [
                "id": id, "title": String((row["title"] as? String ?? "").prefix(160)),
                "description": String((row["description"] as? String ?? "").prefix(400)),
                "expiresAt": expiry as Any? ?? NSNull(),
                "available": row["status"] as? String == "available" && row["resetType"] as? String == "codexRateLimits"
                    && (expiry == nil || Double(expiry!) > now),
            ]
        }
        let account = source["accountId"] as? String ?? ""
        guard account.utf8.count <= 256 else { throw CLIError(L10n.text("usage.unavailable")) }
        return [
            "ok": true, "provider": "codex", "accountId": account, "windows": windows,
            "resetEligible": eligible && !account.isEmpty,
            "availableCount": integer(summary?["availableCount"], maximum: 100_000) as Any? ?? NSNull(),
            "cardDetailsKnown": rawCards != nil, "resetCards": cards, "fetchedAt": Int(now),
        ]
    }
}
