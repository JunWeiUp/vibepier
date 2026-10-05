import Foundation

/// A bounded observation cache, never a store for approval decisions or mutations.
public final class RuntimeEventBuffer: @unchecked Sendable {
    private struct Stream {
        var epoch = UUID().uuidString
        var sequence: UInt64 = 0
        var droppedThrough: UInt64 = 0
        var events: [RuntimeEvent] = []
        var bytes = 0
    }
    private let lock = NSLock()
    private var streams: [RuntimeSessionReference: Stream] = [:]
    private var totalBytes = 0
    private let maxEvents: Int
    private let maxStreamBytes: Int
    private let maxTotalBytes: Int
    private let maxStreams: Int
    public init(
        maxEvents: Int = 256, maxStreamBytes: Int = 1_048_576,
        maxTotalBytes: Int = 16_777_216, maxStreams: Int = 64
    ) {
        self.maxEvents = max(1, maxEvents)
        self.maxStreamBytes = max(1, maxStreamBytes)
        self.maxTotalBytes = max(1, maxTotalBytes)
        self.maxStreams = max(1, maxStreams)
    }
    public func append(_ session: RuntimeSessionReference, method: String, payload: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard streams[session] != nil || streams.count < maxStreams else { return }
        var stream = streams[session] ?? Stream()
        stream.sequence += 1
        let size = payload.count + method.utf8.count + 64
        if payload.count > 300_000 || size > maxStreamBytes || size > maxTotalBytes {
            totalBytes -= stream.bytes
            stream.events.removeAll()
            stream.bytes = 0
            stream.droppedThrough = stream.sequence
        } else {
            while !stream.events.isEmpty,
                stream.events.count >= maxEvents || stream.bytes + size > maxStreamBytes
                    || totalBytes + size > maxTotalBytes
            {
                let removed = stream.events.removeFirst()
                let bytes = removed.payload.count + removed.nativeMethod.utf8.count + 64
                stream.bytes -= bytes
                totalBytes -= bytes
                stream.droppedThrough = removed.cursor.sequence
            }
            if totalBytes + size <= maxTotalBytes {
                stream.events.append(
                    RuntimeEvent(
                        cursor: RuntimeCursor(epoch: stream.epoch, sequence: stream.sequence),
                        nativeMethod: method, payload: payload))
                stream.bytes += size
                totalBytes += size
            } else {
                stream.droppedThrough = stream.sequence
            }
        }
        streams[session] = stream
    }
    public func replay(_ session: RuntimeSessionReference, after: RuntimeCursor?) -> RuntimeReplay {
        lock.lock()
        defer { lock.unlock() }
        guard let stream = streams[session] else {
            return RuntimeReplay(cursor: RuntimeCursor(epoch: "", sequence: 0), events: [], requiresResync: true)
        }
        let cursor = RuntimeCursor(epoch: stream.epoch, sequence: stream.sequence)
        let valid =
            after.map {
                $0.epoch == stream.epoch && $0.sequence >= stream.droppedThrough
                    && $0.sequence <= stream.sequence
            } ?? (stream.droppedThrough == 0)
        return RuntimeReplay(
            cursor: cursor,
            events: valid ? stream.events.filter { $0.cursor.sequence > (after?.sequence ?? 0) } : [],
            requiresResync: !valid)
    }
    public func retire(_ session: RuntimeSessionReference) {
        lock.lock()
        defer { lock.unlock() }
        if let old = streams.removeValue(forKey: session) { totalBytes -= old.bytes }
    }
}
