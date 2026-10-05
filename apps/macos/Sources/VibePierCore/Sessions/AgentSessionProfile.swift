import CoreFoundation
import CryptoKit
import Foundation

/// Strict product protocol. It never forwards arbitrary upstream methods or caller device identities.
enum AgentSessionProfile {
    static let version = 2
    static let maximumBytes = 256 * 1024
    static let mutations: Set<String> = [
        "session.create", "session.configure", "message.submit", "queue.cancel", "queue.steer", "turn.interrupt",
        "approval.resolve", "question.answer",
    ]
    static let parameters: [String: Set<String>] = [
        "agent.describe": [],
        "workspace.list": ["search", "offset", "limit"],
        "session.list": ["search", "offset", "limit", "workspaceRef"],
        "session.open": [],
        "session.snapshot": [],
        "session.items": [
            "kind", "messageId", "before", "offset", "limit", "headersOnly", "sequence", "refreshOptions",
        ],
        "session.observe": ["subscriptionId", "streamEpoch", "afterSequence"],
        "session.unobserve": ["subscriptionId"],
        "session.creationOptions": ["workspaceRef", "draftId", "refreshOptions"],
        "session.create": ["initialMessage", "options"],
        "session.configure": ["options"],
        "message.submit": ["mode", "content", "expectedTurnId"],
        "queue.cancel": ["queueId"],
        "queue.steer": ["queueId", "expectedTurnId"],
        "turn.interrupt": ["expectedTurnId"],
        "approval.resolve": ["approvalId", "fingerprint", "revision", "decision"],
        "question.answer": ["questionId", "fingerprint", "revision", "answers"],
        "operation.get": ["operationId"],
    ]
    static var methods: [String] { parameters.keys.sorted() }
    struct Request: @unchecked Sendable {
        let id: String
        let operationID: String?
        let method: String
        let target: [String: Any]
        let params: [String: Any]
        let lease: String?
        let viewVersion: Int64
        let body: [String: Any]
        let fingerprint: String
        var mutable: Bool { mutations.contains(method) }
    }
    struct Failure: Error {
        let code: String
        var diagnostic: String? = nil
    }

    static func decode(_ outer: [String: Any]) throws -> Request {
        guard let id = outer["id"] as? String, UUID(uuidString: id) != nil,
            let body = outer["body"] as? [String: Any],
            Set(body.keys).isSubset(of: [
                "agentProtocol", "requestId", "operationId", "method", "target", "params", "controlLease",
            ]),
            integer(body["agentProtocol"]) == 2, body["requestId"] as? String == id,
            let method = body["method"] as? String, let allowed = parameters[method],
            let params = body["params"] as? [String: Any], Set(params.keys).isSubset(of: allowed),
            let target = body["target"] as? [String: Any],
            Set(target.keys).isSubset(of: [
                "adapterId", "sessionRef", "ownershipEpoch", "capabilityRevision", "workspaceRef", "draftId",
                "optionsRevision",
            ]),
            target.values.allSatisfy({ bounded($0 as? String, maximum: 4096) })
        else { throw Failure(code: "agent_request_invalid") }
        let mutable = mutations.contains(method)
        let operation = body["operationId"] as? String
        if mutable {
            guard let operation, UUID(uuidString: operation) != nil,
                let lease = body["controlLease"] as? String, UUID(uuidString: lease) != nil
            else { throw Failure(code: "agent_request_invalid") }
        } else if body["operationId"] != nil || body["controlLease"] != nil {
            throw Failure(code: "agent_request_invalid")
        }
        if let refresh = params["refreshOptions"] {
            guard Self.boolean(refresh) != nil,
                method == "session.creationOptions"
                    || method == "session.items" && params["kind"] as? String == "composerOptions"
            else {
                throw Failure(code: "agent_request_invalid")
            }
        }
        if let options = params["options"] {
            guard let options = options as? [String: Any],
                Set(options.keys).isSubset(of: [
                    "model", "mode", "effort", "executionMode", "serviceTier", "confirmation",
                ]),
                options.allSatisfy({ key, value in
                    key == "confirmation" ? boolean(value) != nil : bounded(value as? String, maximum: 256)
                })
            else { throw Failure(code: "agent_request_invalid") }
        }
        if let options = params["options"] as? [String: Any], let tier = options["serviceTier"] {
            guard ["session.configure", "session.create"].contains(method), let tier = tier as? String,
                ["standard", "priority"].contains(tier)
            else {
                throw Failure(code: "agent_options_invalid")
            }
        }
        if let options = params["options"] as? [String: Any], let execution = options["executionMode"] {
            guard let mode = execution as? String, ["default", "plan"].contains(mode) else {
                throw Failure(code: "agent_options_invalid")
            }
        }
        for key in ["offset", "limit", "afterSequence"] where params[key] != nil {
            guard let value = integer(params[key]), value >= 0, value <= 1_000_000 else {
                throw Failure(code: "agent_request_invalid")
            }
        }
        for key in ["headersOnly", "sequence"] where params[key] != nil {
            guard boolean(params[key]) != nil else { throw Failure(code: "agent_request_invalid") }
        }
        // An empty search is the phone's normal unfiltered discovery request, not an empty identity.
        if let search = params["search"] {
            guard let search = search as? String, search.utf8.count <= 200, !search.utf8.contains(0) else {
                throw Failure(code: "agent_request_invalid")
            }
        }
        for key in [
            "workspaceRef", "draftId", "subscriptionId", "streamEpoch", "messageId", "kind",
            "expectedTurnId", "queueId", "approvalId", "questionId", "fingerprint", "revision", "decision",
            "operationId", "mode",
        ] where params[key] != nil && !(params[key] is NSNull) {
            guard bounded(params[key] as? String, maximum: 1024) else {
                throw Failure(code: "agent_request_invalid")
            }
        }
        if let before = params["before"], !(before is NSNull) {
            if method == "session.items", params["kind"] as? String == "parts" {
                guard let value = integer(before), value >= 0, value <= 1_000_000 else {
                    throw Failure(code: "agent_request_invalid")
                }
            } else {
                guard bounded(before as? String, maximum: 1024) else { throw Failure(code: "agent_request_invalid") }
            }
        }
        let encoded = try canonical(body)
        guard encoded.count <= maximumBytes else { throw Failure(code: "agent_request_too_large") }
        let view = integer(outer["viewVersion"]) ?? 0
        guard outer["viewVersion"] == nil || integer(outer["viewVersion"]) != nil, view >= 0 else {
            throw Failure(code: "agent_request_invalid")
        }
        let semantic = body.filter { !["requestId", "controlLease"].contains($0.key) }
        let fingerprint = digest(try canonical(semantic))
        return Request(
            id: id, operationID: operation, method: method, target: target, params: params,
            lease: body["controlLease"] as? String, viewVersion: view, body: body, fingerprint: fingerprint)
    }

    /// UTF-8, scalar-key order, unescaped slash, finite safe integers; shared vectors freeze these rules.
    static func canonical(_ value: Any, depth: Int = 0) throws -> Data {
        guard depth <= 16 else { throw Failure(code: "agent_request_invalid") }
        if value is NSNull { return Data("null".utf8) }
        if let value = value as? String {
            guard value.utf8.count <= maximumBytes else { throw Failure(code: "agent_request_too_large") }
            return try JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return Data((value.boolValue ? "true" : "false").utf8) }
            guard let number = integer(value), abs(Double(number)) <= 9_007_199_254_740_991 else {
                throw Failure(code: "agent_request_invalid")
            }
            return Data(String(number).utf8)
        }
        if let values = value as? [Any] {
            guard values.count <= 4096 else { throw Failure(code: "agent_request_too_large") }
            var output = Data("[".utf8)
            for (index, value) in values.enumerated() {
                if index > 0 { output.append(Data(",".utf8)) }
                output.append(try canonical(value, depth: depth + 1))
                guard output.count <= maximumBytes else { throw Failure(code: "agent_request_too_large") }
            }
            output.append(Data("]".utf8))
            return output
        }
        if let object = value as? [String: Any] {
            guard object.count <= 4096, object.keys.allSatisfy({ $0.utf8.count <= 256 }) else {
                throw Failure(code: "agent_request_too_large")
            }
            var output = Data("{".utf8)
            let keys = object.keys.sorted {
                Array($0.unicodeScalars.map(\.value)).lexicographicallyPrecedes(Array($1.unicodeScalars.map(\.value)))
            }
            for (index, key) in keys.enumerated() {
                if index > 0 { output.append(Data(",".utf8)) }
                output.append(try canonical(key, depth: depth + 1))
                output.append(Data(":".utf8))
                output.append(try canonical(object[key]!, depth: depth + 1))
                guard output.count <= maximumBytes else { throw Failure(code: "agent_request_too_large") }
            }
            output.append(Data("}".utf8))
            return output
        }
        throw Failure(code: "agent_request_invalid")
    }
    static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite,
            value.doubleValue.rounded() == value.doubleValue, abs(value.doubleValue) <= 9_007_199_254_740_991
        else { return nil }
        return value.int64Value
    }
    static func boolean(_ value: Any?) -> Bool? { SessionProviderReply.boolean(value) }
    static func bounded(_ value: String?, maximum: Int) -> Bool {
        guard let value else { return false }
        return !value.isEmpty && value.utf8.count <= maximum && !value.contains("\0")
    }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    static func data(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }
}
