import CryptoKit
import Foundation

/// The desktop message ID is an opaque, deterministic UUID scoped to the authenticated
/// phone and native thread. The phone's operation ID remains the durable journal key.
struct CodexMessageIdentity {
    let nativeID: String

    init(client: String, thread: String, operation: String) throws {
        guard !client.isEmpty, client.utf8.count <= 1024,
            UUID(uuidString: thread) != nil, UUID(uuidString: operation) != nil
        else { throw CLIError(L10n.text("core.invalid_request")) }
        var data = Data("vibepier/codex-message/v1".utf8)
        // Length prefixes prevent ambiguous field boundaries. Preserve exact operation
        // bytes to match the durable journal's identity, including UUID letter case.
        for value in [client, thread, operation] {
            var count = UInt32(value.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
            data.append(contentsOf: value.utf8)
        }
        var bytes = Array(SHA256.hash(data: data).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80  // UUID version 8: application-defined payload.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        nativeID =
            UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                )
            ).uuidString
    }

    func delivered(in state: [String: Any]) -> Bool {
        CodexQuestions.acceptedMessage(state, operation: nativeID)
    }

    func queued(in rows: [[String: Any]]) -> Bool {
        rows.contains { $0["id"] as? String == nativeID }
    }

    func confirmedTurn(in state: [String: Any]) -> String? {
        let turns = CodexConversation.turns(state).filter { turn in
            (turn["items"] as? [[String: Any]] ?? []).contains { item in
                let type = item["type"] as? String
                return
                    (type == "userMessage"
                    || (type == "steeringUserMessage" && item["status"] as? String == "accepted"))
                    && (item["clientId"] as? String ?? item["clientUserMessageId"] as? String) == nativeID
            }
        }
        guard turns.count == 1 else { return nil }
        return turns[0]["turnId"] as? String ?? turns[0]["id"] as? String
    }
}
