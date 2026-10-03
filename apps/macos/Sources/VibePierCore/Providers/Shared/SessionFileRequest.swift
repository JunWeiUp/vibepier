import Foundation

/// Created only after the provider has validated the selected device/session and native file references.
/// The captured work must not access mutable provider state or perform a desktop mutation.
struct SessionFileRequest: Error, Sendable {
    let thread: String
    let read: @Sendable () throws -> Data

    init(thread: String, read: @escaping @Sendable () throws -> [String: Any]) {
        self.thread = thread
        self.read = {
            var result = try read()
            result["ok"] = true
            result["threadId"] = thread
            return try JSONSerialization.data(withJSONObject: result)
        }
    }
}

/// A filesystem permission prompt can block open(2) indefinitely. Return a bounded error to the phone
/// without blocking a provider queue or admitting more workers while the original calls remain stuck.
final class SessionFileLoader: @unchecked Sendable {
    static let shared = SessionFileLoader()
    private let lock = NSLock()
    private var active = Set<UUID>()
    private var replies: [UUID: @Sendable (Data) -> Void] = [:]
    private let limit: Int
    private let timeout: Double
    private let timer = DispatchQueue(label: "vibepier.file-timeouts")

    init(limit: Int = 2, timeout: Double = 6) {
        self.limit = limit
        self.timeout = timeout
    }

    func perform(_ request: SessionFileRequest, provider: String, completion: @escaping @Sendable (Data) -> Void) {
        let token = UUID()
        let accepted = lock.withLock {
            guard active.count < limit else { return false }
            active.insert(token)
            replies[token] = completion
            return true
        }
        let unavailable = encode([
            "ok": false, "threadId": request.thread, "provider": provider,
            "error": L10n.text("session.file_access_unavailable"),
        ])
        guard accepted else {
            completion(unavailable)
            return
        }
        timer.asyncAfter(deadline: .now() + timeout) { [self] in
            let callback = lock.withLock { replies.removeValue(forKey: token) }
            callback?(unavailable)
        }
        DispatchQueue.global(qos: .utility).async { [self] in
            let result: Data
            do {
                var value = try JSONSerialization.jsonObject(with: request.read()) as? [String: Any] ?? [:]
                value["provider"] = provider
                result = encode(value)
            } catch {
                var value = ProviderFailure.reply(error, provider: provider)
                value["threadId"] = request.thread
                result = encode(value)
            }
            let callback = lock.withLock {
                active.remove(token)
                return replies.removeValue(forKey: token)
            }
            callback?(result)
        }
    }

    private func encode(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
    }
}
