import Foundation

/// Transport observation recovery is distinct from native task/operation lifetime.
struct AgentObservationStream {
    struct Event: Sendable {
        let sequence: Int64
        let body: Data
    }
    let epoch = UUID().uuidString.lowercased()
    private(set) var sequence: Int64 = 0
    private(set) var events: [Event] = []
    private(set) var bytes = 0
    mutating func append(_ body: [String: Any]) -> Event? {
        guard sequence < Int64.max else { return nil }
        let data = AgentSessionProfile.data(body.merging(["streamEpoch": epoch, "sequence": sequence + 1]) { $1 })
        guard !data.isEmpty, data.count <= 256 * 1024 else { return nil }
        sequence += 1
        let event = Event(sequence: sequence, body: data)
        events.append(event)
        bytes += data.count
        while events.count > 256 || bytes > 1024 * 1024 {
            bytes -= events.removeFirst().body.count
        }
        return event
    }
    func replay(epoch requestedEpoch: String, after cursor: Int64) -> [Event]? {
        guard requestedEpoch == epoch, cursor >= 0, cursor <= sequence,
            cursor >= (events.first?.sequence ?? (sequence + 1)) - 1
        else { return nil }
        return events.filter { $0.sequence > cursor }
    }
}
