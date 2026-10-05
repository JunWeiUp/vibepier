import CoreFoundation
import Foundation

public struct RuntimeNativeQuestion: Codable, Sendable {
    public let id: String
    public let question: String
    public let header: String
    public let options: [String]
    public let allowsOther: Bool
}

public struct RuntimeNativeRequest: Codable, Sendable {
    public let id: String
    public let fingerprint: String
    public let method: String
    public let nativeSessionID: String
    public let nativeTurnID: String
    public let nativeItemID: String
    public let allowedDecisions: [String]
    public let questions: [RuntimeNativeQuestion]
    public let nativeParamsJSON: Data
}

/// Connection-scoped reverse RPCs. Never invents requests from transcript text.
final class CodexRuntimePendingRequests: @unchecked Sendable {
    struct Entry {
        let value: RuntimeNativeRequest
        let nativeIDJSON: Data
        let session: RuntimeSessionReference
        var submitted: RuntimeOperationContext?
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func register(nativeIDJSON: Data, method: String, params: Data, session: RuntimeSessionReference) -> Bool {
        guard params.count <= 280_000,
            let value = try? JSONSerialization.jsonObject(with: params) as? [String: Any],
            let threadID = value["threadId"] as? String, threadID == session.nativeSessionID,
            let turnID = id(value["turnId"]), let itemID = id(value["itemId"])
        else { return false }
        let canonical = (try? JSONSerialization.data(withJSONObject: value, options: .sortedKeys)) ?? params
        let fingerprint = RuntimeOperationLedger.hash(nativeIDJSON + Data(method.utf8) + canonical)
        let requestID = RuntimeOperationLedger.hash(
            Data(session.instanceID.utf8) + Data(session.ownershipEpoch.utf8) + nativeIDJSON)
        var decisions: [String] = []
        var questions: [RuntimeNativeQuestion] = []
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            guard let started = value["startedAtMs"] as? NSNumber, CFGetTypeID(started) != CFBooleanGetTypeID(),
                floor(started.doubleValue) == started.doubleValue
            else { return false }
            // Exact schema includes these turn-only decisions. Session/rule/root
            // amendments require separate product scope and are not exposed.
            decisions = ["accept", "decline", "cancel"]
        case "item/tool/requestUserInput":
            guard let blocking = value["isBlocking"] as? NSNumber, CFGetTypeID(blocking) == CFBooleanGetTypeID(),
                let requested = value["questions"] as? [[String: Any]], !requested.isEmpty, requested.count <= 8
            else { return false }
            for question in requested {
                guard let questionID = id(question["id"]), let text = question["question"] as? String,
                    text.utf8.count <= 16_384, let header = question["header"] as? String, header.utf8.count <= 1024,
                    question["isSecret"] == nil || Self.boolean(question["isSecret"]) == false,
                    question["isOther"] == nil || Self.boolean(question["isOther"]) != nil
                else { return false }
                var options: [String] = []
                if let values = question["options"] as? [[String: Any]] {
                    guard values.count <= 32 else { return false }
                    for option in values {
                        guard let label = option["label"] as? String, !label.isEmpty, label.utf8.count <= 4096,
                            option["description"] is String
                        else { return false }
                        options.append(label)
                    }
                } else if question["options"] != nil && !(question["options"] is NSNull) {
                    return false
                }
                questions.append(
                    RuntimeNativeQuestion(
                        id: questionID, question: text, header: header, options: options,
                        allowsOther: options.isEmpty || Self.boolean(question["isOther"]) == true))
            }
            guard Set(questions.map(\.id)).count == questions.count else { return false }
        default: return false
        }
        lock.lock()
        defer { lock.unlock() }
        guard entries.count < 32, entries[requestID] == nil,
            entries.values.reduce(params.count, { $0 + $1.value.nativeParamsJSON.count }) <= 2_097_152
        else { return false }
        entries[requestID] = Entry(
            value: RuntimeNativeRequest(
                id: requestID, fingerprint: fingerprint, method: method,
                nativeSessionID: threadID, nativeTurnID: turnID, nativeItemID: itemID, allowedDecisions: decisions,
                questions: questions, nativeParamsJSON: params), nativeIDJSON: nativeIDJSON, session: session)
        return true
    }
    func pending(_ session: RuntimeSessionReference) -> [RuntimeNativeRequest] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.filter { $0.session == session && $0.submitted == nil }.map(\.value).sorted {
            $0.id < $1.id
        }
    }
    func claim(command: RuntimeCommand, context: RuntimeOperationContext) throws -> (Data, Data) {
        let requestID: String
        let fingerprint: String
        let result: [String: Any]
        switch command {
        case .resolveApproval(let id, let hash, let decision):
            requestID = id
            fingerprint = hash
            result = ["decision": decision]
        case .answerQuestion(let id, let hash, let answers):
            requestID = id
            fingerprint = hash
            result = ["answers": answers.mapValues { ["answers": $0] }]
        default: throw RuntimeDriverError.invalidRequest
        }
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[requestID], entry.session == context.session,
            entry.value.fingerprint == fingerprint, entry.submitted == nil
        else { throw RuntimeDriverError.staleOwner }
        switch command {
        case .resolveApproval(_, _, let decision):
            guard entry.value.allowedDecisions.contains(decision), entry.value.questions.isEmpty else {
                throw RuntimeDriverError.invalidRequest
            }
        case .answerQuestion(_, _, let answers):
            guard !entry.value.questions.isEmpty, Set(answers.keys) == Set(entry.value.questions.map(\.id)) else {
                throw RuntimeDriverError.invalidRequest
            }
            for question in entry.value.questions {
                guard let values = answers[question.id], !values.isEmpty, values.count <= 32,
                    values.allSatisfy({
                        !$0.isEmpty && $0.utf8.count <= 16_384
                            && (question.allowsOther || question.options.contains($0))
                    })
                else { throw RuntimeDriverError.invalidRequest }
            }
        default: throw RuntimeDriverError.invalidRequest
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        guard data.count <= 280_000 else { throw RuntimeDriverError.invalidRequest }
        entry.submitted = context
        entries[requestID] = entry
        return (entry.nativeIDJSON, data)
    }
    func resolved(nativeIDJSON: Data, sessionID: String) -> RuntimeOperationContext? {
        lock.lock()
        defer { lock.unlock() }
        guard
            let key = entries.first(where: {
                $0.value.nativeIDJSON == nativeIDJSON && $0.value.value.nativeSessionID == sessionID
            })?.key
        else { return nil }
        return entries.removeValue(forKey: key)?.submitted
    }
    func closeTurn(_ sessionID: String, turnID: String) {
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter {
            $0.value.value.nativeSessionID != sessionID || $0.value.value.nativeTurnID != turnID
        }
    }
    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
    private func id(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 256, !value.contains("\0") else {
            return nil
        }
        return value
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
