import Foundation

/// Prepared on the provider queue after verifying the selected view and resolving its opaque image ID.
/// Only immutable native references cross to the file/decoder workers.
struct ConversationImageRequest: Error, Sendable {
    let thread: String
    let id: String
    let source: String
    let cwd: String
    let maxPixel: Int
    let device: String
    let binary: Bool
    let zcodeArtifactRoot: String?
    init(
        thread: String, id: String, source: String, cwd: String, maxPixel: Int, device: String = "",
        binary: Bool = false, zcodeArtifactRoot: String? = nil
    ) {
        self.thread = thread
        self.id = id
        self.source = source
        self.cwd = cwd
        self.maxPixel = maxPixel
        self.device = device
        self.binary = binary
        self.zcodeArtifactRoot = zcodeArtifactRoot
    }
}

/// File opens can wait indefinitely on filesystem or macOS permission services even with O_NONBLOCK.
/// Never perform them on a session queue. A timeout answers the RPC once, but retains the worker slot
/// until the actual work exits, so repeated requests cannot accumulate blocked threads or image data.
final class ConversationImageLoader: @unchecked Sendable {
    static let shared = ConversationImageLoader()
    typealias Decode = @Sendable (ConversationImageRequest) throws -> Data
    private let lock = NSLock()
    private var active = Set<UUID>()
    private var replies: [UUID: @Sendable (Data) -> Void] = [:]
    private struct Pending {
        let token: UUID
        let large: Bool
        let work: @Sendable () -> Void
    }
    private var pending: [Pending] = []
    private let queueLimit: Int
    private let limit: Int
    private let timeout: Double
    private let decode: Decode
    private let timer = DispatchQueue(label: "vibepier.image-timeouts")

    init(
        limit: Int = 2, timeout: Double = 6, queueLimit: Int = 16,
        decode: @escaping Decode = {
            if let root = $0.zcodeArtifactRoot {
                return try ZCodeImageArtifacts.jpeg(
                    $0.source, session: $0.thread, root: root, maxPixel: $0.maxPixel,
                    maximumBytes: $0.binary ? 4 * 1024 * 1024 : 200_000)
            }
            return try ConversationReply.jpeg(
                $0.source, cwd: $0.cwd, maxPixel: $0.maxPixel, maximumBytes: $0.binary ? 4 * 1024 * 1024 : 200_000)
        }
    ) {
        self.queueLimit = queueLimit
        self.limit = limit
        self.timeout = timeout
        self.decode = decode
    }

    func perform(_ request: ConversationImageRequest, provider: String, completion: @escaping @Sendable (Data) -> Void)
    {
        let token = UUID()
        @Sendable func reply(_ image: Data?, error: String? = nil) -> Data {
            var value: [String: Any] = [
                "ok": image != nil, "threadId": request.thread,
                "imageId": request.id, "provider": provider,
            ]
            if let image { value["image"] = image.base64EncodedString() }
            if let error { value["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: value, options: [.withoutEscapingSlashes])) ?? Data()
        }
        let unavailable = reply(nil, error: L10n.text("session.image_preview_unavailable"))
        let work: @Sendable () -> Void = { [self] in

            let result: Data
            do {
                let image = try decode(request)
                if request.binary {
                    let profile = try BinaryMediaFiles.offer(
                        BinaryMediaFiles.snapshot(image), device: request.device,
                        thread: request.thread, mime: "image/jpeg")
                    result = try JSONSerialization.data(
                        withJSONObject: [
                            "ok": true, "threadId": request.thread,
                            "imageId": request.id, "provider": provider, "binary": profile,
                        ], options: [.withoutEscapingSlashes])
                } else {
                    result = reply(image)
                }
            } catch { result = unavailable }
            let (callback, next) = lock.withLock {
                active.remove(token)
                let callback = replies.removeValue(forKey: token)
                let next = pending.isEmpty ? nil : pending.removeFirst()
                if let next { active.insert(next.token) }
                return (callback, next)
            }
            callback?(result)
            if callback == nil, request.binary,
                let value = try? JSONSerialization.jsonObject(with: result) as? [String: Any],
                let profile = value["binary"] as? [String: Any], let ticket = profile["id"] as? String
            {
                BinaryFileTransfers.shared.cancelTicket(device: request.device, ticket: ticket)
            }
            if let next { DispatchQueue.global(qos: .utility).async(execute: next.work) }
        }
        let disposition = lock.withLock {
            guard active.count + pending.count < limit + queueLimit else { return 0 }
            replies[token] = completion
            if active.count < limit {
                active.insert(token)
                return 1
            }
            let entry = Pending(token: token, large: request.maxPixel > 480, work: work)
            let index = entry.large ? (pending.firstIndex { !$0.large } ?? pending.count) : pending.count
            pending.insert(entry, at: index)
            return 2
        }
        guard disposition != 0 else {
            completion(unavailable)
            return
        }
        timer.asyncAfter(deadline: .now() + timeout) { [self] in
            let callback = lock.withLock {
                pending.removeAll { $0.token == token }
                return replies.removeValue(forKey: token)
            }
            callback?(unavailable)
        }
        if disposition == 1 { DispatchQueue.global(qos: .utility).async(execute: work) }
    }
}
