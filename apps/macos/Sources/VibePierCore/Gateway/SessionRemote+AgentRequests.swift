import AppKit
import CryptoKit
import Foundation
import Security

/// Unified agent-session requests: the profile-2 service, its durable journal binding and pre-dispatch rejection.
extension SessionRemote {
    func extendedCapabilities(_ value: [String: Any]) -> [String: Any] {
        var result = value
        result["adapters"] =
            (value["adapters"] as? [[String: Any]] ?? []).map { $0.merging(["default": true]) { $1 } }
            + runtimeHost.descriptors().map { $0.merging(["default": false]) { $1 } }
        return result
    }
    func makeAgentService() -> AgentSessionService? {
        guard
            let directory = try? AgentSessionDirectory(
                file: Paths.supportDirectory.appendingPathComponent("agent-sessions.json"))
        else { return nil }
        let binding = AgentSessionService.Journal(
            read: { [weak self] key, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    journal.receipt(actual).map {
                        .init(
                            hash: $0.hash, thread: $0.thread, result: $0.result,
                            intent: $0.intent, retired: $0.retired == true, evidence: $0.evidence)
                    }
                }
            },
            reserve: { [weak self] key, hash, scope, intent, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    switch try journal.reserve(actual, hash: hash, thread: scope, intent: intent) {
                    case .fresh: return .fresh
                    case .complete(let data): return .complete(data)
                    case .unknown: return .unknown
                    case .conflict: return .conflict
                    }
                }
            },
            complete: { [weak self] key, data, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    try journal.complete(actual, result: data)
                }
            },
            recordEvidence: { [weak self] key, data, done in
                self?.withAgentJournal(key: key, completion: done) { journal, actual in
                    try journal.recordEvidence(actual, evidence: data)
                }
            })
        let service = AgentSessionService(
            directory: directory,
            execute: { [weak self] data, provider, client, done in
                guard let self else { return }
                self.queue.async {
                    guard self.trust.key(for: client) != nil else {
                        done(AgentSessionProfile.data(["ok": false, "code": "unauthorized_device"]))
                        return
                    }
                    let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                    if SessionV1Contract.descriptor(fields["op"] as? String ?? "")?.durableMutation == true,
                        !self.providerPolicy.isEnabled(provider)
                    {
                        done(AgentSessionProfile.data(["ok": false, "code": "provider_disabled"]))
                        return
                    }
                    let adapter = fields["agentAdapterId"] as? String ?? provider + ".currentV1"
                    if adapter == provider + ".currentV1" {
                        self.perform(data, provider: provider, client: client, completion: done)
                    } else {
                        self.runtimeHost.perform(data, adapter: adapter, client: client, completion: done)
                    }
                }
            }, journal: binding,
            describe: { [weak self] client, done in
                self?.queue.async { [weak self] in
                    guard let self else { return }
                    let current =
                        self.coordinator.describe(client: client, requestedVersion: 1, policy: self.providerPolicy)
                        ?? [:]
                    done(AgentSessionProfile.data(self.extendedCapabilities(current)))
                }
            },
            freshMutationFailure: { [weak self] data, client, done in
                guard let self else { return }
                let fields = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                if let adapter = fields["agentAdapterId"] as? String, !adapter.hasSuffix(".currentV1") {
                    self.runtimeHost.freshMutationFailure(data, client: client, completion: done)
                } else {
                    self.queue.async {
                        let current = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                        done(self.coordinator.freshMutationFailure(current, client: client))
                    }
                }
            },
            eventSink: { [weak self] client, data in
                guard let self, data.count <= 300_000,
                    case .accepted(let ticket) = self.events.begin(
                        device: client, id: UUID().uuidString, bytes: data.count)
                else { return }
                self.queue.async {
                    defer { self.events.finish(ticket) }
                    guard self.trust.key(for: client) != nil, self.routes[client] != nil,
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let body = object["body"] as? [String: Any], let event = body["data"] as? [String: Any],
                        let provider = event["provider"] as? String, SessionV1Contract.providers.contains(provider),
                        self.providerPolicy.isEnabled(provider)
                    else { return }
                    self.send(data, device: client, provider: provider)
                }
            }, additionalAdapters: { [weak self] in self?.runtimeHost.adapterProviders() ?? [:] })
        service.configurePolicy(providerPolicy)
        return service
    }
    private func withAgentJournal<T: Sendable>(
        key: String, completion: @escaping @Sendable (Result<T, Error>) -> Void,
        _ work: @escaping @Sendable (SessionReceiptJournal, String) throws -> T
    ) {
        queue.async {
            guard let journal = self.journal, journal.isReliable, let split = key.firstIndex(of: ":") else {
                completion(.failure(AgentSessionProfile.Failure(code: "agent_receipt_storage_unavailable")))
                return
            }
            let device = String(key[..<split])
            let operation = String(key[key.index(after: split)...])
            let actual = journal.existingKey(device: device, operation: operation) ?? key
            completion(Result { try work(journal, actual) })
        }
    }
    func acceptAgentRequest(_ outer: [String: Any], clear: Data, device: String) {
        let id = outer["id"] as? String ?? ""
        do {
            let request = try AgentSessionProfile.decode(outer)
            guard let service = agentService else {
                rejectAgentBeforeDispatch(
                    request, code: "agent_index_invalid", device: device, uncertain: request.mutable)
                return
            }
            service.admissionProvider(request, client: device) { [weak self] provider in
                self?.queue.async { [weak self] in
                    guard let self, self.trust.key(for: device) != nil else { return }
                    let lane =
                        provider.map {
                            SessionRequestLane.resolve(["provider": $0], receipt: request.method == "operation.get")
                        }
                        ?? SessionRequestLane.controls.rawValue
                    let admission = self.executions.begin(device: device, id: id, bytes: clear.count, lane: lane)
                    guard case .accepted(let ticket) = admission else {
                        if case .full = admission {
                            let recorded =
                                request.operationID.flatMap { self.journal?.existingKey(device: device, operation: $0) }
                                != nil
                            let uncertain = request.mutable && (recorded || self.journal?.isReliable != true)
                            self.rejectAgentBeforeDispatch(
                                request, code: "capacity_exceeded", device: device, uncertain: uncertain)
                        }
                        return
                    }
                    service.perform(request, client: device) { [weak self] result in
                        guard let self, self.executions.claimCompletion(ticket) else { return }
                        self.queue.async {
                            defer { self.executions.finish(ticket) }
                            let scoped =
                                !request.mutable
                                && !["operation.get", "session.unobserve", "agent.describe"].contains(request.method)
                            if scoped, let provider, !self.providerPolicy.isEnabled(provider) {
                                self.sendObject(
                                    [
                                        "id": id, "ok": false, "code": "provider_disabled",
                                        "body": ["agentProtocol": 2, "requestId": id, "code": "provider_disabled"],
                                    ], device: device)
                            } else {
                                self.send(result, device: device, provider: scoped ? provider : nil)
                            }
                        }
                    }
                }
            }
        } catch {
            let code = (error as? AgentSessionProfile.Failure)?.code ?? "agent_request_invalid"
            // A malformed request cannot invalidate an earlier reservation held by the phone.
            sendObject(
                [
                    "id": id, "ok": false, "code": code,
                    "body": ["agentProtocol": 2, "requestId": id, "code": code],
                ], device: device)
        }
    }
    private func rejectAgentBeforeDispatch(
        _ request: AgentSessionProfile.Request, code: String, device: String, uncertain: Bool
    ) {
        var body: [String: Any] = ["agentProtocol": 2, "requestId": request.id, "code": code]
        if request.mutable {
            body["operationId"] = request.operationID
            body["target"] = request.target
            body["status"] = uncertain ? "unknown" : "rejected"
            body["result"] = ["code": code]
        }
        var reply: [String: Any] = ["id": request.id, "ok": false, "code": code, "body": body]
        if uncertain { reply["unknown"] = true }
        sendObject(reply, device: device)
    }
}
