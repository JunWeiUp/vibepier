import Foundation

/// A chat reply can overtake queued icons between lines, never halfway through a JSON line.
struct BluetoothNotificationQueue {
    struct Frame {
        let peer: UUID
        let data: Data
        let last: Bool
    }
    private var normal: [Frame] = []
    private var priority: [Frame] = []
    private var activePriority: Bool?
    var count: Int { normal.count + priority.count }
    var isEmpty: Bool { count == 0 }
    var betweenLines: Bool { activePriority == nil }
    mutating func append(_ line: Data, peer: UUID, size: Int, urgent: Bool = false) {
        var line = line
        line.append(10)
        let size = max(1, size)
        let frames = stride(from: 0, to: line.count, by: size).map { start in
            let end = min(start + size, line.count)
            return Frame(peer: peer, data: line.subdata(in: start..<end), last: end == line.count)
        }
        if urgent { priority.append(contentsOf: frames) } else { normal.append(contentsOf: frames) }
    }
    mutating func first(allowPriority: Bool) -> Frame? {
        if activePriority == nil {
            if allowPriority && !priority.isEmpty {
                activePriority = true
            } else if !normal.isEmpty {
                activePriority = false
            }
        }
        return activePriority == true ? priority.first : activePriority == false ? normal.first : nil
    }
    mutating func removeFirst() {
        let frame = activePriority == true ? priority.removeFirst() : normal.removeFirst()
        if frame.last { activePriority = nil }
    }
    mutating func remove(_ peer: UUID) {
        let current = activePriority == true ? priority.first : activePriority == false ? normal.first : nil
        if current?.peer == peer { activePriority = nil }
        normal.removeAll { $0.peer == peer }
        priority.removeAll { $0.peer == peer }
    }
    mutating func removeAll() {
        normal.removeAll()
        priority.removeAll()
        activePriority = nil
    }
}
