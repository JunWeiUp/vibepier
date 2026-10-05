import Foundation

enum AgentSubmissionPolicy {
    static func allows(_ mode: String, active: Bool, queued: Bool) -> Bool {
        switch mode {
        case "start": return !active && !queued
        case "queue": return active || queued
        default: return false
        }
    }
}
