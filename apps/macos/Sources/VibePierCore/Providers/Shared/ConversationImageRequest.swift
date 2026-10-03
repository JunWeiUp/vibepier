import Foundation

/// Prepared on the provider queue after verifying the selected view and resolving its opaque image ID.
/// Only immutable native references cross to the file/decoder workers.
struct ConversationImageRequest: Error, Sendable {
    let thread: String
    let id: String
    let source: String
    let cwd: String
    let maxPixel: Int
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
    private let limit: Int
    private let timeout: Double
    private let decode: Decode
    private let timer = DispatchQueue(label: "vibepier.image-timeouts")

    init(
        limit: Int = 2, timeout: Double = 6,
        decode: @escaping Decode = {
            try ConversationReply.jpeg($0.source, cwd: $0.cwd, maxPixel: $0.maxPixel)
        }
    ) {
        self.limit = limit
        self.timeout = timeout
        self.decode = decode
    }

    func perform(_ request: ConversationImageRequest, provider: String, completion: @escaping @Sendable (Data) -> Void)
    {
        let token = UUID()
        let accepted = lock.withLock {
            guard active.count < limit else { return false }
            active.insert(token)
            replies[token] = completion
            return true
        }
        @Sendable func reply(_ image: Data?, error: String? = nil) -> Data {
            var value: [String: Any] = [
                "ok": image != nil, "threadId": request.thread,
                "imageId": request.id, "provider": provider,
            ]
            if let image { value["image"] = image.base64EncodedString() }
            if let error { value["error"] = error }
            return (try? JSONSerialization.data(withJSONObject: value)) ?? Data()
        }
        let unavailable = reply(nil, error: L10n.text("session.image_preview_unavailable"))
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
                let image = try decode(request)
                result = reply(image)
            } catch { result = unavailable }
            let callback = lock.withLock {
                active.remove(token)
                return replies.removeValue(forKey: token)
            }
            callback?(result)
        }
    }
}
