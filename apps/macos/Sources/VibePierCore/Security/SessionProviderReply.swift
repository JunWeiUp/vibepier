import Foundation

/// Only explicit, well-formed results may finish a durable reservation. Never turn malformed data into a rejection.
struct SessionProviderReply {
    struct Context: Sendable {
        let id: String
        let operation: String
        let thread: String
        let cwd: String
        let fingerprint: String
        let accountId: String
        let creditId: String
        init(_ request: [String: Any]) {
            id = request["id"] as? String ?? ""
            operation = request["op"] as? String ?? ""
            thread = request["threadId"] as? String ?? ""
            cwd = request["cwd"] as? String ?? ""
            fingerprint = request["fingerprint"] as? String ?? ""
            accountId = request["accountId"] as? String ?? ""
            creditId = request["creditId"] as? String ?? ""
        }
    }
    let object: [String: Any]
    let data: Data
    var definitive: Bool { Self.boolean(object["unknown"]) != true }

    init(_ bytes: Data, request: Context, mutable: Bool) {
        let id = request.id
        var invalid: [String: Any] = ["id": id, "ok": false, "error": L10n.text("core.invalid_receipt")]
        if mutable { invalid["unknown"] = true }
        func normalized() -> [String: Any] {
            guard bytes.count <= 300_000,
                var reply = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                let ok = Self.boolean(reply["ok"]),
                reply["unknown"] == nil || Self.boolean(reply["unknown"]) != nil
            else { return invalid }
            reply["id"] = id
            if Self.boolean(reply["unknown"]) == true {
                reply["ok"] = false
                return reply
            }
            guard !mutable || !ok || Self.confirms(reply, request: request) else { return invalid }
            return reply
        }
        let value = normalized()
        if let encoded = try? JSONSerialization.data(withJSONObject: value), encoded.count <= 300_000 {
            object = value
            data = encoded
        } else {
            object = invalid
            data = (try? JSONSerialization.data(withJSONObject: invalid)) ?? Data()
        }
    }

    /// A native success is not a durable success until its reservation is completed on disk.
    func saving(_ save: (Data) throws -> Void) -> SessionProviderReply {
        guard definitive else { return self }
        do {
            try save(data)
            return self
        } catch {
            let value: [String: Any] = [
                "id": object["id"] as? String ?? "", "ok": false, "unknown": true,
                "error": L10n.text("control.receipt_result_save_failed"),
            ]
            return SessionProviderReply(
                object: value, data: (try? JSONSerialization.data(withJSONObject: value)) ?? Data())
        }
    }
    private init(object: [String: Any], data: Data) {
        self.object = object
        self.data = data
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    /// Reconciliation is observational. An unknown, contradictory or differently scoped lookup cannot clear a reservation.
    static func resolvedLookup(
        _ bytes: Data, thread: String, operation: String, cwd: String = "", fingerprint: String = "",
        accountId: String = "", creditId: String = ""
    ) -> [String: Any]? {
        guard bytes.count <= 300_000,
            let body = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            body["unknown"] == nil || boolean(body["unknown"]) == false
        else { return nil }
        let context = Context([
            "op": operation, "threadId": thread, "cwd": cwd, "fingerprint": fingerprint,
            "accountId": accountId, "creditId": creditId,
        ])
        if boolean(body["ok"]) == true && confirms(body, request: context) { return body }
        // The queue can explicitly report that a delete lost a race with sending; that is a resolved failure.
        if operation == "queueDelete", boolean(body["ok"]) == false, boolean(body["resolved"]) == true,
            boolean(body["accepted"]) == false, !(body["error"] as? String ?? "").isEmpty, sameThread(body, context)
        {
            return body
        }
        return nil
    }

    private static func confirms(_ reply: [String: Any], request: Context) -> Bool {
        switch request.operation {
        case "codexUsageReset":
            let outcome = reply["outcome"] as? String ?? ""
            return !request.accountId.isEmpty && !request.creditId.isEmpty
                && reply["accountId"] as? String == request.accountId
                && reply["creditId"] as? String == request.creditId
                && ["reset", "alreadyRedeemed", "nothingToReset", "noCredit"].contains(outcome)
                && boolean(reply["accepted"]) == ["reset", "alreadyRedeemed"].contains(outcome)
        case "new":
            return !(reply["threadId"] as? String ?? "").isEmpty
                && !request.cwd.isEmpty && reply["cwd"] as? String == request.cwd
        case "lockScreen": return boolean(reply["locked"]) == true
        case "unlockScreen": return boolean(reply["locked"]) == false
        case "approve":
            return boolean(reply["submitted"]) == true
                && !request.fingerprint.isEmpty
                && reply["fingerprint"] as? String == request.fingerprint
                && sameThread(reply, request)
        default: return boolean(reply["accepted"]) == true && sameThread(reply, request)
        }
    }

    private static func sameThread(_ reply: [String: Any], _ request: Context) -> Bool {
        !request.thread.isEmpty && reply["threadId"] as? String == request.thread
    }
}
