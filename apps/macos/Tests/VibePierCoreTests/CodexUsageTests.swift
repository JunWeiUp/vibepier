import XCTest

@testable import VibePierCore

final class CodexUsageTests: XCTestCase {
    private final class RPC: CodexAccountRequesting, @unchecked Sendable {
        var usage: [String: Any]
        var outcome = "reset"
        var failReset = false
        var resets: [[String: Any]] = []
        var reads = 0
        init(_ usage: [String: Any]) { self.usage = usage }
        func request(_ method: String, params: [String: Any], mutable: Bool) throws -> [String: Any] {
            if method == "account/rateLimits/read" {
                XCTAssertFalse(mutable)
                reads += 1
                return usage
            }
            XCTAssertEqual(method, "account/rateLimitResetCredit/consume")
            XCTAssertTrue(mutable)
            resets.append(params)
            if failReset { throw CLIError("synthetic timeout") }
            return ["outcome": outcome]
        }
        func close() {}
    }
    private func source(used: Int = 93) -> [String: Any] {
        [
            "accountId": "account-a", "rateLimits": ["primary": ["usedPercent": 100]],
            "rateLimitsByLimitId": [
                "codex": [
                    "primary": ["usedPercent": used, "windowDurationMins": 10080, "resetsAt": 2000],
                    "secondary": NSNull(),
                ]
            ],
            "rateLimitResetCredits": [
                "availableCount": 3,
                "credits": [
                    ["id": "gift-a", "status": "available", "resetType": "codexRateLimits", "expiresAt": 3000]
                ],
            ],
        ]
    }
    private func intent() -> [String: Any] {
        [
            "id": UUID().uuidString, "op": "codexUsageReset", "accountId": "account-a", "creditId": "gift-a",
            "confirm": true,
        ]
    }

    func testUsagePrefersBucketsAndPreservesUnknownCountsAndWindows() throws {
        let value = try CodexUsage.project(source(), now: 1000)
        XCTAssertEqual((value["windows"] as? [[String: Any]])?.first?["remainingPercent"] as? Int, 7)
        XCTAssertEqual((value["windows"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(value["availableCount"] as? Int, 3, "Count is authoritative even when detail rows are capped")
        XCTAssertEqual(value["resetEligible"] as? Bool, true)
        let missing = try CodexUsage.project(["rateLimits": [:] as [String: Any]], now: 1000)
        XCTAssertTrue(missing["availableCount"] is NSNull)
        XCTAssertEqual(missing["resetEligible"] as? Bool, false)
        XCTAssertTrue((missing["windows"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertThrowsError(try CodexUsage.project([:], now: 1000))
    }

    func testReadsNeverConsumeAndRedemptionRequiresFreshConfirmedMatchingAccountAndCard() throws {
        for scenario in ["read", "confirmation", "account", "credit", "empty-credit", "usage", "expired", "count-only"]
        {
            let rpc = RPC(source())
            let service = CodexUsage(connect: { rpc }, clock: { 1000 })
            var request = intent()
            switch scenario {
            case "read": request["op"] = "codexUsage"
            case "confirmation": request["confirm"] = false
            case "account": request["accountId"] = "another-account"
            case "credit": request["creditId"] = "another-gift"
            case "empty-credit": request["creditId"] = ""
            case "usage": rpc.usage = source(used: 89)
            case "expired":
                rpc.usage["rateLimitResetCredits"] = [
                    "availableCount": 1,
                    "credits": [
                        ["id": "gift-a", "status": "available", "resetType": "codexRateLimits", "expiresAt": 500]
                    ],
                ]
            default: rpc.usage["rateLimitResetCredits"] = ["availableCount": 3, "credits": NSNull()]
            }
            let result = try service.reply(request, client: "phone")
            XCTAssertEqual(result["ok"] as? Bool, scenario == "read", scenario)
            XCTAssertEqual(rpc.reads, 1)
            XCTAssertTrue(rpc.resets.isEmpty, scenario)
        }
    }

    func testResetReceiptIsImmutableAndScopedWithoutDoubleRedemption() throws {
        let rpc = RPC(source())
        let service = CodexUsage(connect: { rpc }, clock: { 1000 })
        let request = intent()
        let first = try service.reply(request, client: "phone-a")
        XCTAssertEqual(first["outcome"] as? String, "reset")
        XCTAssertEqual(first["accountId"] as? String, "account-a")
        XCTAssertEqual(try service.reply(request, client: "phone-a")["outcome"] as? String, "reset")
        XCTAssertEqual(rpc.reads, 1)
        XCTAssertEqual(rpc.resets.count, 1)
        XCTAssertEqual(rpc.resets.first?["creditId"] as? String, "gift-a")
        let lookup: [String: Any] = ["op": "codexUsageResetReceipt", "operation": request["id"]!]
        XCTAssertEqual(try service.reply(lookup, client: "phone-a")["outcome"] as? String, "reset")
        XCTAssertEqual(try service.reply(lookup, client: "phone-b")["unknown"] as? Bool, true)
        _ = try service.reply(request, client: "phone-b")
        XCTAssertNotEqual(rpc.resets[0]["idempotencyKey"] as? String, rpc.resets[1]["idempotencyKey"] as? String)
        var changed = request
        changed["creditId"] = "different"
        XCTAssertThrowsError(try service.reply(changed, client: "phone-a"))
    }

    func testUnknownAndMalformedResetResultsNeverPermitAnotherAttempt() throws {
        for fail in [true, false] {
            let rpc = RPC(source())
            rpc.failReset = fail
            rpc.outcome = "unexpected"
            let service = CodexUsage(connect: { rpc }, clock: { 1000 })
            let request = intent()
            XCTAssertEqual(try service.reply(request, client: "phone")["unknown"] as? Bool, true)
            XCTAssertEqual(try service.reply(request, client: "phone")["unknown"] as? Bool, true)
            XCTAssertEqual(rpc.resets.count, 1)
        }
    }

    func testAllNativeOutcomesAndAccountBoundReceipts() throws {
        for outcome in ["reset", "alreadyRedeemed", "noCredit", "nothingToReset"] {
            let rpc = RPC(source())
            rpc.outcome = outcome
            let service = CodexUsage(connect: { rpc }, clock: { 1000 })
            let request = intent()
            let result = try service.reply(request, client: "phone")
            XCTAssertEqual(result["ok"] as? Bool, true)
            XCTAssertEqual(result["outcome"] as? String, outcome)
            XCTAssertEqual(result["accepted"] as? Bool, ["reset", "alreadyRedeemed"].contains(outcome))
            var foreign = result
            foreign["accountId"] = "foreign"
            let checked = SessionProviderReply(
                try JSONSerialization.data(withJSONObject: foreign), request: .init(request), mutable: true)
            XCTAssertFalse(checked.definitive)
        }
    }

    func testNativeAccountReadOnlySmoke() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_CODEX_USAGE_SMOKE"] == "1" else {
            throw XCTSkip("Explicit read-only native account opt-in; no reset is consumed")
        }
        let rpc = try CodexAccountRPC()
        defer { rpc.close() }
        let value = try CodexUsage.project(
            rpc.request("account/rateLimits/read", params: ["excludeResetCreditDetails": false], mutable: false),
            now: Date().timeIntervalSince1970)
        XCTAssertFalse((value["accountId"] as? String ?? "").isEmpty)
        XCTAssertFalse((value["windows"] as? [[String: Any]] ?? []).isEmpty)
    }
}
