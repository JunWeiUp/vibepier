import Foundation

/// Inspected 12553/12947 history hydration returns a stream revision, not the history itself.
/// A new owner-bound full snapshot at or beyond that revision is the read barrier.
enum CodexHistoryReadback {
    struct Snapshot {
        let data: Data
        let state: [String: Any]
        let revision: Int
    }

    struct Page {
        let rows: [[String: Any]]
        let hasOlder: Bool
    }

    /// A cached oldest boundary can become stale after native history is hydrated elsewhere.
    /// Read it once before accepting exhaustion, then hydrate only when the current native state is incomplete.
    static func older(
        _ cached: [String: Any], before: String, minimumRevision: Int,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        fresh: (Int, Double) throws -> Snapshot, hydrate: (Double) throws -> Int
    ) throws -> Page {
        func window(_ state: [String: Any]) -> (rows: [[String: Any]], start: Int)? {
            let turns = CodexConversation.turns(state)
            let rows = turns.map(CodexConversation.messages)
            guard let resolved = replyID(turns, rows: rows.flatMap { $0 }, requested: before) else { return nil }
            return ConversationReply.older(rows, before: resolved)
        }
        let current = try readState(
            cached, minimumRevision: minimumRevision, now: now,
            needsRead: { window($0)?.rows.isEmpty ?? true }, fresh: fresh, hydrate: hydrate)
        guard let page = window(current) else { throw CLIError(L10n.text("session.the_session_changed_reopen_it")) }
        return Page(rows: page.rows, hasOlder: page.start > 0 || !complete(current))
    }

    /// History bodies can be absent from a native tail snapshot even while the phone still shows their previews.
    /// Missing content is resolved only from fresh owner-bound snapshots; no write or retry is issued.
    static func readState(
        _ cached: [String: Any], minimumRevision: Int,
        now: () -> Double = { ProcessInfo.processInfo.systemUptime }, needsRead: ([String: Any]) -> Bool,
        fresh: (Int, Double) throws -> Snapshot, hydrate: (Double) throws -> Int
    ) throws -> [String: Any] {
        var current = cached
        if needsRead(current) {
            let deadline = now() + 25
            func read(_ revision: Int) throws -> Snapshot {
                let remaining = deadline - now()
                guard remaining > 0 else { throw CLIError(L10n.text("session.the_session_has_not_loaded_yet")) }
                return try fresh(revision, min(3, remaining))
            }
            current = try read(minimumRevision).state
            if needsRead(current) && !complete(current) {
                // Leave three seconds for the read barrier and one for CodexIPC's response wait allowance.
                let timeout = min(22, deadline - now() - 4)
                guard timeout > 0 else { throw CLIError(L10n.text("session.the_session_has_not_loaded_yet")) }
                let revision = try hydrate(timeout)
                current = try read(revision).state
            }
        }
        return current
    }

    static func parts(
        _ state: [String: Any], id: String, offset: Int, headersOnly: Bool = false, sequence: Bool = false,
        before: Int? = nil
    ) -> [String: Any]? {
        let turns = CodexConversation.turns(state)
        let rows = turns.flatMap(CodexConversation.messages)
        guard let resolved = replyID(turns, rows: rows, requested: id) else { return nil }
        return ConversationReply.partPage(
            rows, id: resolved, offset: offset, headersOnly: headersOnly, sequence: sequence, before: before)
    }

    /// A reply can exist in the tail while its earlier native items are still missing. Its part indexes are not
    /// authoritative until that turn is complete; unrelated turns do not make an available reply unreadable.
    static func needsPartsRead(_ state: [String: Any], id: String) -> Bool {
        let turns = CodexConversation.turns(state).map { (turn: $0, rows: CodexConversation.messages($0)) }
        guard let resolved = replyID(turns.map(\.turn), rows: turns.flatMap(\.rows), requested: id),
            let target = turns.first(where: { projection in
                projection.rows.contains { $0["id"] as? String == resolved && $0["parts"] is [[String: Any]] }
            })
        else { return true }
        return !itemsComplete(target.turn)
    }

    static func text(_ state: [String: Any], id: String) -> String? {
        let turns = CodexConversation.turns(state)
        let rows = turns.flatMap(CodexConversation.messages)
        if let text = ConversationReply.fullText(rows, id: id) { return text }
        guard let resolved = replyID(turns, rows: rows, requested: id) else { return nil }
        return ConversationReply.fullText(rows, id: resolved)
    }

    /// A tail without its user item names the reply after its first native part. Hydration restores the user anchor.
    /// Raw items retain native IDs even when adjacent prose is merged into one projected part.
    /// Accept that old name only when one renderable native item proves exactly one current reply.
    private static func replyID(_ turns: [[String: Any]], rows: [[String: Any]], requested: String) -> String? {
        if rows.contains(where: { $0["id"] as? String == requested }) { return requested }
        guard requested.hasPrefix("reply-") else { return nil }
        let anchor = String(requested.dropFirst("reply-".count))
        guard !anchor.isEmpty else { return nil }
        var match: (turn: [String: Any], items: [[String: Any]], index: Int)?
        for turn in turns {
            let items = turn["items"] as? [[String: Any]] ?? []
            for (index, item) in items.enumerated() where item["id"] as? String == anchor {
                guard match == nil else { return nil }
                match = (turn, items, index)
            }
        }
        guard let match, CodexConversation.part(match.items[match.index], id: anchor) != nil else { return nil }
        var prefix = match.turn
        prefix["items"] = Array(match.items.prefix(match.index + 1))
        guard let reply = CodexConversation.messages(prefix).last, reply["role"] as? String == "assistant",
            let id = reply["id"] as? String,
            rows.filter({ $0["id"] as? String == id && $0["role"] as? String == "assistant" }).count == 1
        else { return nil }
        return id
    }

    static func acknowledgedRevision(_ reply: [String: Any]) throws -> Int {
        guard let result = reply["result"] as? [String: Any],
            let revision = AgentSessionProfile.integer(result["revision"]), revision >= 0,
            let value = Int(exactly: revision)
        else { throw CLIError(L10n.text("core.invalid_receipt")) }
        return value
    }

    static func snapshot(_ data: Data, thread: String, owner: String, minimumRevision: Int) -> Snapshot? {
        guard minimumRevision >= 0, !thread.isEmpty, !owner.isEmpty, data.count <= 64 * 1024 * 1024,
            let packet = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            packet["type"] as? String == "broadcast",
            packet["method"] as? String == "thread-stream-state-changed",
            AgentSessionProfile.integer(packet["version"]) == 11,
            packet["sourceClientId"] as? String == owner,
            let params = packet["params"] as? [String: Any], params["hostId"] as? String == "local",
            params["conversationId"] as? String == thread,
            let change = params["change"] as? [String: Any], change["type"] as? String == "snapshot",
            let revision = AgentSessionProfile.integer(change["revision"]), revision >= Int64(minimumRevision),
            let value = Int(exactly: revision), let state = change["conversationState"] as? [String: Any],
            state["id"] as? String == thread
        else { return nil }
        return Snapshot(data: data, state: state, revision: value)
    }

    /// Matches native OB/WR, with malformed/unknown structures remaining incomplete.
    static func complete(_ state: [String: Any]) -> Bool {
        guard state["turnsPagination"] == nil || state["turnsPagination"] is [String: Any] else { return false }
        let pagination = state["turnsPagination"] as? [String: Any] ?? [:]
        guard pagination["source"] == nil || pagination["source"] is String else { return false }
        guard pagination["source"] as? String != "compact" else { return false }
        if let raw = state["turnHistory"] {
            guard let store = raw as? [String: Any], store["kind"] as? String == "canonical",
                let history = store["history"] as? [String: Any],
                SessionProviderReply.boolean(history["isComplete"]) == true,
                let islands = history["islands"] as? [[String: Any]], islands.count == 1,
                let entries = islands[0]["entries"] as? [[String: Any]],
                let entities = history["entitiesByKey"] as? [String: Any]
            else { return false }
            return entries.allSatisfy { entry in
                guard let key = entry["value"] as? String, let turn = entities[key] as? [String: Any] else {
                    return false
                }
                return itemsComplete(turn)
            }
        }
        guard state["resumeState"] as? String == "resumed", let turns = state["turns"] as? [[String: Any]],
            turns.allSatisfy(itemsComplete)
        else { return false }
        return pagination["hasLoadedOldest"] == nil
            || SessionProviderReply.boolean(pagination["hasLoadedOldest"]) == true
    }

    private static func itemsComplete(_ turn: [String: Any]) -> Bool {
        guard let raw = turn["itemsPagination"] else { return true }
        guard let pagination = raw as? [String: Any] else { return false }
        return pagination["hasLoadedOldest"] == nil
            || SessionProviderReply.boolean(pagination["hasLoadedOldest"]) == true
    }
}
