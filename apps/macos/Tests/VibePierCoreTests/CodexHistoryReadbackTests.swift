import Foundation
import XCTest

@testable import VibePierCore

final class CodexHistoryReadbackTests: XCTestCase {
    static func state(_ indexes: [Int], complete: Bool = true) -> [String: Any] {
        let entities = Dictionary(
            uniqueKeysWithValues: indexes.map { index in
                (
                    "t\(index)",
                    [
                        "turnId": "t\(index)", "itemsPagination": ["hasLoadedOldest": true],
                        "items": [["id": "u\(index)", "type": "userMessage", "text": "Synthetic message \(index)"]],
                    ] as [String: Any]
                )
            })
        return [
            "id": "native-thread", "turnsPagination": ["source": "timeline"],
            "turnHistory": [
                "kind": "canonical",
                "history": [
                    "isComplete": complete, "entitiesByKey": entities,
                    "islands": [["entries": indexes.map { ["value": "t\($0)"] }]],
                ],
            ],
        ]
    }
    static func packet(state: [String: Any], revision: Any = 4) -> [String: Any] {
        [
            "type": "broadcast", "method": "thread-stream-state-changed", "version": 11,
            "sourceClientId": "owner",
            "params": [
                "hostId": "local", "conversationId": "native-thread",
                "change": ["type": "snapshot", "revision": revision, "conversationState": state],
            ],
        ]
    }
    func testCompleteCanonicalHistoryStopsAfterTheActualOldestWindow() throws {
        let all = Self.state([0, 1, 2, 3])
        XCTAssertTrue(CodexHistoryReadback.complete(all))
        let page = CodexConversation.page(all)
        XCTAssertEqual(page["hasOlder"] as? Bool, true)
        let before = try XCTUnwrap((page["messages"] as? [[String: Any]])?.first?["id"] as? String)
        let earlier = try XCTUnwrap(
            ConversationReply.older(CodexConversation.turns(all).map(CodexConversation.messages), before: before))
        XCTAssertEqual(earlier.rows.compactMap { $0["id"] as? String }, ["u0", "u1", "u2"])
        XCTAssertEqual(earlier.start, 0)
        XCTAssertFalse(earlier.start > 0 || !CodexHistoryReadback.complete(all))
        XCTAssertEqual(CodexConversation.page(Self.state([0]))["hasOlder"] as? Bool, false)
        XCTAssertTrue(
            CodexHistoryReadback.complete(Self.state([])), "Native complete empty history has one exhausted island")
        XCTAssertEqual(CodexConversation.page(Self.state([]))["hasOlder"] as? Bool, false)
    }
    func testCompactSparsePartialItemsAndUnknownStructuresRemainIncomplete() {
        let complete = Self.state([0])
        var compact = complete
        compact["turnsPagination"] = ["source": "compact", "hasLoadedOldest": true]
        var islands = complete
        var history = (islands["turnHistory"] as? [String: Any])?["history"] as? [String: Any] ?? [:]
        history["islands"] = [["entries": [["value": "t0"]]], ["entries": []]]
        islands["turnHistory"] = ["kind": "canonical", "history": history]
        var missing = complete
        history["islands"] = [["entries": [["value": "missing-turn"]]]]
        missing["turnHistory"] = ["kind": "canonical", "history": history]
        var items = complete
        history["islands"] = [["entries": [["value": "t0"]]]]
        history["entitiesByKey"] = ["t0": ["itemsPagination": ["hasLoadedOldest": false]]]
        items["turnHistory"] = ["kind": "canonical", "history": history]
        for state in [
            compact, islands, missing, items, Self.state([0], complete: false), ["turnHistory": ["kind": "future"]],
            [:],
        ] {
            XCTAssertFalse(CodexHistoryReadback.complete(state))
            XCTAssertEqual(CodexConversation.page(state)["hasOlder"] as? Bool, true)
        }
    }
    func testLegacyOldestStillRequiresResumedStateAndCompleteItems() {
        let resumed: [String: Any] = ["resumeState": "resumed", "turns": []]
        XCTAssertTrue(CodexHistoryReadback.complete(resumed))
        var state = resumed
        state["turnsPagination"] = ["hasLoadedOldest": true]
        XCTAssertTrue(CodexHistoryReadback.complete(state))
        state["turnsPagination"] = ["hasLoadedOldest": false]
        XCTAssertFalse(CodexHistoryReadback.complete(state))
        state["turnsPagination"] = ["hasLoadedOldest": true]
        state["resumeState"] = "resuming"
        XCTAssertFalse(CodexHistoryReadback.complete(state))
        state["resumeState"] = "resumed"
        state["turns"] = [["itemsPagination": ["hasLoadedOldest": false]]]
        XCTAssertFalse(CodexHistoryReadback.complete(state))
    }
    private func snapshot(_ indexes: [Int], complete: Bool = true, revision: Int = 4) throws
        -> CodexHistoryReadback.Snapshot
    {
        try snapshot(Self.state(indexes, complete: complete), revision: revision)
    }

    private func snapshot(_ state: [String: Any], revision: Int = 4) throws -> CodexHistoryReadback.Snapshot {
        try XCTUnwrap(
            CodexHistoryReadback.snapshot(
                JSONSerialization.data(withJSONObject: Self.packet(state: state, revision: revision)),
                thread: "native-thread", owner: "owner", minimumRevision: revision))
    }

    private func replyState(includeUser: Bool, complete: Bool = true) -> [String: Any] {
        var state = Self.state([0], complete: complete)
        var store = state["turnHistory"] as! [String: Any]
        var history = store["history"] as! [String: Any]
        var items: [[String: Any]] = includeUser ? [["id": "u0", "type": "userMessage", "text": "Synthetic user"]] : []
        items += (0..<12).map {
            ["id": "p\($0)", "type": "commandExecution", "command": "synthetic \($0)", "status": "completed"]
        }
        history["entitiesByKey"] = [
            "t0": ["turnId": "t0", "items": items, "itemsPagination": ["hasLoadedOldest": complete]]
        ]
        store["history"] = history
        state["turnHistory"] = store
        return state
    }

    func testMissingReplyPartsRefreshThenHydrateAtAcknowledgedRevisionWithoutAnyWrite() throws {
        for id in ["reply-u0", "reply-p0"] {
            var requests: [String] = []
            func parts(_ state: [String: Any]) -> [String: Any]? {
                CodexHistoryReadback.parts(state, id: id, offset: 0, sequence: true, before: 8)
            }
            let current = try CodexHistoryReadback.readState(
                Self.state([3], complete: false), minimumRevision: 4, needsRead: { parts($0) == nil },
                fresh: { revision, _ in
                    requests.append("fresh:\(revision)")
                    return try self.snapshot(
                        requests.count == 1 ? Self.state([3], complete: false) : self.replyState(includeUser: true),
                        revision: revision)
                },
                hydrate: { _ in
                    requests.append("hydrate")
                    return 8
                })
            let page = try XCTUnwrap(parts(current))
            XCTAssertEqual(requests, ["fresh:4", "hydrate", "fresh:8"], "Only native reads are requested")
            XCTAssertEqual(page["partCount"] as? Int, 12)
            XCTAssertEqual(
                (page["parts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, (0..<8).map { "p\($0)" })
        }
        let tail = replyState(includeUser: false, complete: false)
        XCTAssertEqual(CodexConversation.messages(CodexConversation.turns(tail)[0]).first?["id"] as? String, "reply-p0")
        XCTAssertNotNil(CodexHistoryReadback.parts(replyState(includeUser: true), id: "reply-p0", offset: 0))
    }

    func testMissingUserAnchoredReplyCanBeRecoveredFromPartialTailOnlyAfterHydration() throws {
        let tail = replyState(includeUser: false, complete: false)
        var requests: [String] = []
        let current = try CodexHistoryReadback.readState(
            tail, minimumRevision: 4,
            needsRead: { CodexHistoryReadback.parts($0, id: "reply-u0", offset: 0) == nil },
            fresh: { revision, _ in
                requests.append("fresh:\(revision)")
                return try self.snapshot(
                    requests.count == 1 ? tail : self.replyState(includeUser: true), revision: revision)
            },
            hydrate: { _ in
                requests.append("hydrate")
                return 5
            })
        XCTAssertEqual(requests, ["fresh:4", "hydrate", "fresh:5"])
        XCTAssertNotNil(CodexHistoryReadback.parts(current, id: "reply-u0", offset: 0))
    }

    func testExistingReplyWithPartialItemsHydratesBeforePagingAndUnrelatedPartialTurnsDoNotTriggerReads() throws {
        var tail = replyState(includeUser: true, complete: false)
        var store = tail["turnHistory"] as! [String: Any]
        var history = store["history"] as! [String: Any]
        var entities = history["entitiesByKey"] as! [String: Any]
        var turn = entities["t0"] as! [String: Any]
        let items = turn["items"] as! [[String: Any]]
        turn["items"] = [items[0]] + Array(items.suffix(4))
        entities["t0"] = turn
        history["entitiesByKey"] = entities
        store["history"] = history
        tail["turnHistory"] = store
        XCTAssertEqual(CodexHistoryReadback.parts(tail, id: "reply-u0", offset: 0)?["partCount"] as? Int, 4)
        XCTAssertTrue(CodexHistoryReadback.needsPartsRead(tail, id: "reply-u0"))

        var requests: [String] = []
        let current = try CodexHistoryReadback.readState(
            tail, minimumRevision: 4, needsRead: { CodexHistoryReadback.needsPartsRead($0, id: "reply-u0") },
            fresh: { revision, _ in
                requests.append("fresh:\(revision)")
                return try self.snapshot(
                    requests.count == 1 ? tail : self.replyState(includeUser: true), revision: revision)
            },
            hydrate: { _ in
                requests.append("hydrate")
                return 5
            })
        XCTAssertEqual(requests, ["fresh:4", "hydrate", "fresh:5"])
        XCTAssertFalse(CodexHistoryReadback.needsPartsRead(current, id: "reply-u0"))
        let page = try XCTUnwrap(
            CodexHistoryReadback.parts(current, id: "reply-u0", offset: 0, sequence: true, before: 8))
        XCTAssertEqual(page["partCount"] as? Int, 12)
        XCTAssertEqual(
            (page["parts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, (0..<8).map { "p\($0)" })

        var unrelated = current
        store = unrelated["turnHistory"] as! [String: Any]
        history = store["history"] as! [String: Any]
        entities = history["entitiesByKey"] as! [String: Any]
        entities["t1"] = ["turnId": "t1", "items": [], "itemsPagination": ["hasLoadedOldest": false]]
        history["entitiesByKey"] = entities
        history["islands"] = [["entries": [["value": "t0"], ["value": "t1"]]]]
        history["isComplete"] = false
        store["history"] = history
        unrelated["turnHistory"] = store
        XCTAssertFalse(CodexHistoryReadback.complete(unrelated))
        XCTAssertFalse(CodexHistoryReadback.needsPartsRead(unrelated, id: "reply-u0"))
        _ = try CodexHistoryReadback.readState(
            unrelated, minimumRevision: 5, needsRead: { CodexHistoryReadback.needsPartsRead($0, id: "reply-u0") },
            fresh: { _, _ in
                XCTFail("Only the requested reply's native items determine its completeness")
                return try self.snapshot([])
            },
            hydrate: { _ in
                XCTFail("The requested reply is complete")
                return 6
            })
    }

    func testAvailableReplyAvoidsReadAndMissingCompleteReplyOrReadFailureCannotProduceParts() throws {
        let cached = replyState(includeUser: true)
        let current = try CodexHistoryReadback.readState(
            cached, minimumRevision: 4,
            needsRead: { CodexHistoryReadback.parts($0, id: "reply-u0", offset: 0) == nil },
            fresh: { _, _ in
                XCTFail("Available reply is already readable")
                return try self.snapshot([])
            },
            hydrate: { _ in
                XCTFail("No hydration is needed")
                return 5
            })
        XCTAssertNotNil(CodexHistoryReadback.parts(current, id: "reply-u0", offset: 0))

        var reads = 0
        var hydrations = 0
        let missing = try CodexHistoryReadback.readState(
            Self.state([3]), minimumRevision: 4,
            needsRead: { CodexHistoryReadback.parts($0, id: "reply-u0", offset: 0) == nil },
            fresh: { _, _ in
                reads += 1
                return try self.snapshot([3])
            },
            hydrate: { _ in
                hydrations += 1
                return 5
            })
        XCTAssertNil(CodexHistoryReadback.parts(missing, id: "reply-u0", offset: 0))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(hydrations, 0)
        XCTAssertThrowsError(
            try CodexHistoryReadback.readState(
                Self.state([3], complete: false), minimumRevision: 4,
                needsRead: { CodexHistoryReadback.parts($0, id: "reply-u0", offset: 0) == nil },
                fresh: { _, _ in
                    reads += 1
                    throw CLIError("Synthetic read failure")
                },
                hydrate: { _ in
                    hydrations += 1
                    return 5
                }))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(hydrations, 0)
    }

    func testReplyAliasRequiresUniqueNativePartAndExactReplyIDWins() throws {
        var state = replyState(includeUser: true)
        var store = state["turnHistory"] as! [String: Any]
        var history = store["history"] as! [String: Any]
        var entities = history["entitiesByKey"] as! [String: Any]
        entities["t1"] = [
            "turnId": "t1",
            "items": [
                ["id": "u1", "type": "userMessage", "text": "Synthetic second user"],
                ["id": "p0", "type": "agentMessage", "text": "Synthetic duplicate anchor"],
            ],
        ]
        history["entitiesByKey"] = entities
        history["islands"] = [["entries": [["value": "t0"], ["value": "t1"]]]]
        store["history"] = history
        state["turnHistory"] = store
        XCTAssertNil(
            CodexHistoryReadback.parts(state, id: "reply-p0", offset: 0), "Ambiguous native anchors fail closed")
        XCTAssertNotNil(
            CodexHistoryReadback.parts(state, id: "reply-u0", offset: 0), "The exact message is still valid")
        XCTAssertNil(CodexHistoryReadback.parts(state, id: "reply-missing", offset: 0))
        XCTAssertNil(CodexHistoryReadback.parts(state, id: "p0", offset: 0), "A raw part ID is not an aggregate alias")

        entities["t1"] = [
            "turnId": "t1", "items": [["id": "p0", "type": "agentMessage", "text": "Exact synthetic reply"]],
        ]
        history["entitiesByKey"] = entities
        store["history"] = history
        state["turnHistory"] = store
        XCTAssertEqual(CodexHistoryReadback.parts(state, id: "reply-p0", offset: 0)?["partCount"] as? Int, 1)
        XCTAssertEqual(CodexHistoryReadback.text(state, id: "reply-p0"), "Exact synthetic reply")
    }

    func testTailProseAnchorSurvivesNativeTextMergingAndUnknownOrSyntheticAnchorsRemainInvalid() throws {
        let user: [String: Any] = ["id": "u0", "type": "userMessage", "text": "Synthetic user"]
        let first: [String: Any] = ["id": "a", "type": "agentMessage", "text": "First synthetic paragraph"]
        let last: [String: Any] = ["id": "b", "type": "agentMessage", "text": "Second synthetic paragraph"]
        func state(_ items: [[String: Any]], complete: Bool) -> [String: Any] {
            var result = Self.state([0], complete: complete)
            var store = result["turnHistory"] as! [String: Any]
            var history = store["history"] as! [String: Any]
            history["entitiesByKey"] = [
                "t0": ["turnId": "t0", "items": items, "itemsPagination": ["hasLoadedOldest": complete]]
            ]
            store["history"] = history
            result["turnHistory"] = store
            return result
        }
        let tail = state([last], complete: false)
        let hydrated = state([user, first, last], complete: true)
        XCTAssertEqual(CodexConversation.messages(CodexConversation.turns(tail)[0]).first?["id"] as? String, "reply-b")
        let fullReply = try XCTUnwrap(CodexConversation.messages(CodexConversation.turns(hydrated)[0]).last)
        XCTAssertEqual((fullReply["parts"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["a"])

        var requests: [String] = []
        let current = try CodexHistoryReadback.readState(
            tail, minimumRevision: 4, needsRead: { CodexHistoryReadback.needsPartsRead($0, id: "reply-b") },
            fresh: { revision, _ in
                requests.append("fresh:\(revision)")
                return try self.snapshot(requests.count == 1 ? tail : hydrated, revision: revision)
            },
            hydrate: { _ in
                requests.append("hydrate")
                return 5
            })
        XCTAssertEqual(requests, ["fresh:4", "hydrate", "fresh:5"])
        XCTAssertFalse(CodexHistoryReadback.needsPartsRead(current, id: "reply-b"))
        let page = try XCTUnwrap(CodexHistoryReadback.parts(current, id: "reply-b", offset: 0, sequence: true))
        XCTAssertEqual(page["partCount"] as? Int, 1)
        XCTAssertEqual(
            (page["parts"] as? [[String: Any]])?.first?["text"] as? String,
            "First synthetic paragraph\n\nSecond synthetic paragraph")
        XCTAssertEqual(
            CodexHistoryReadback.text(current, id: "reply-b"), "First synthetic paragraph\n\nSecond synthetic paragraph"
        )
        XCTAssertNil(
            CodexHistoryReadback.parts(state([user, first, last, last], complete: true), id: "reply-b", offset: 0))
        XCTAssertNil(
            CodexHistoryReadback.parts(
                state([user, first, ["id": "unknown", "type": "future"]], complete: true), id: "reply-unknown",
                offset: 0))
        XCTAssertNil(
            CodexHistoryReadback.parts(
                state([user, first, ["type": "agentMessage", "text": "No native ID"]], complete: true),
                id: "reply-t0-2", offset: 0))

        func withEarlierTurn(_ native: [String: Any]) -> [String: Any] {
            var result = native
            var store = result["turnHistory"] as! [String: Any]
            var history = store["history"] as! [String: Any]
            var entities = history["entitiesByKey"] as! [String: Any]
            entities["earlier"] = [
                "turnId": "earlier",
                "items": [["id": "earlier-user", "type": "userMessage", "text": "Earlier synthetic turn"]],
            ]
            history["entitiesByKey"] = entities
            history["islands"] = [["entries": [["value": "earlier"], ["value": "t0"]]]]
            store["history"] = history
            result["turnHistory"] = store
            return result
        }
        let fullHistory = withEarlierTurn(hydrated)
        var historyRequests: [String] = []
        let earlier = try CodexHistoryReadback.older(
            tail, before: "reply-b", minimumRevision: 4,
            fresh: { revision, _ in
                historyRequests.append("fresh:\(revision)")
                return try self.snapshot(historyRequests.count == 1 ? tail : fullHistory, revision: revision)
            },
            hydrate: { _ in
                historyRequests.append("hydrate")
                return 5
            })
        XCTAssertEqual(historyRequests, ["fresh:4", "hydrate", "fresh:5"])
        XCTAssertEqual(earlier.rows.compactMap { $0["id"] as? String }, ["earlier-user"])
        XCTAssertFalse(earlier.hasOlder)
        for (before, native) in [
            ("reply-missing", fullHistory),
            ("reply-b", withEarlierTurn(state([user, first, last, last], complete: true))),
        ] {
            XCTAssertThrowsError(
                try CodexHistoryReadback.older(
                    native, before: before, minimumRevision: 5,
                    fresh: { revision, _ in try self.snapshot(native, revision: revision) },
                    hydrate: { _ in
                        XCTFail("Missing or ambiguous anchors cannot be guessed from complete history")
                        return 6
                    }))
        }
    }

    func testStaleCompleteBoundaryReadsSameRevisionSnapshotAndReturnsOlderMessagesWithoutHydration() throws {
        var reads = 0
        let page = try CodexHistoryReadback.older(
            Self.state([3]), before: "u3", minimumRevision: 4,
            fresh: { revision, timeout in
                reads += 1
                XCTAssertEqual(revision, 4)
                XCTAssertEqual(timeout, 3)
                return try self.snapshot([0, 1, 2, 3], revision: revision)
            },
            hydrate: { _ in
                XCTFail("The current complete snapshot already has the earlier messages")
                return 5
            })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(page.rows.compactMap { $0["id"] as? String }, ["u0", "u1", "u2"])
        XCTAssertFalse(page.hasOlder)
    }

    func testAnchorMissingFromCacheIsResolvedByOneCurrentRead() throws {
        let page = try CodexHistoryReadback.older(
            Self.state([3]), before: "u2", minimumRevision: 4,
            fresh: { revision, _ in try self.snapshot([0, 1, 2, 3], revision: revision) },
            hydrate: { _ in
                XCTFail("The current snapshot contains the anchor")
                return 5
            })
        XCTAssertEqual(page.rows.compactMap { $0["id"] as? String }, ["u0", "u1"])
        XCTAssertFalse(page.hasOlder)
    }

    func testCurrentIncompleteBoundaryHydratesOnceAndReadsAcknowledgedRevisionWithinOneDeadline() throws {
        var time = 100.0
        var requests: [String] = []
        let page = try CodexHistoryReadback.older(
            Self.state([3], complete: false), before: "u3", minimumRevision: 4, now: { time },
            fresh: { revision, timeout in
                requests.append("fresh:\(revision)")
                XCTAssertEqual(timeout, 3, accuracy: 0.0001)
                time += requests.count == 1 ? 2.6 : 3
                return try self.snapshot(
                    requests.count == 1 ? [3] : [0, 1, 2, 3], complete: requests.count != 1, revision: revision)
            },
            hydrate: { timeout in
                requests.append("hydrate")
                XCTAssertEqual(timeout, 18.4, accuracy: 0.0001)
                time += timeout + 1  // CodexIPC allows one extra second for its response semaphore.
                return 8
            })
        XCTAssertEqual(requests, ["fresh:4", "hydrate", "fresh:8"])
        XCTAssertEqual(time, 125, accuracy: 0.0001)
        XCTAssertEqual(page.rows.compactMap { $0["id"] as? String }, ["u0", "u1", "u2"])
        XCTAssertFalse(page.hasOlder)
    }

    func testCachedNonemptyPageAvoidsNativeReadsAndVerifiedOldestStopsWithoutHydration() throws {
        let cached = try CodexHistoryReadback.older(
            Self.state([0, 1, 2, 3, 4]), before: "u4", minimumRevision: 4,
            fresh: { _, _ in
                XCTFail("The cached window already has older messages")
                return try self.snapshot([])
            },
            hydrate: { _ in
                XCTFail("No hydration is needed")
                return 5
            })
        XCTAssertEqual(cached.rows.compactMap { $0["id"] as? String }, ["u1", "u2", "u3"])
        XCTAssertTrue(cached.hasOlder)

        var reads = 0
        let oldest = try CodexHistoryReadback.older(
            Self.state([0]), before: "u0", minimumRevision: 4,
            fresh: { _, _ in
                reads += 1
                return try self.snapshot([0])
            },
            hydrate: { _ in
                XCTFail("Only a current complete snapshot proves exhaustion")
                return 5
            })
        XCTAssertEqual(reads, 1)
        XCTAssertTrue(oldest.rows.isEmpty)
        XCTAssertFalse(oldest.hasOlder)
    }

    func testReadFailureUnknownAnchorAndExhaustedDeadlineNeverClaimExhaustionOrRetry() throws {
        var reads = 0
        var hydrations = 0
        XCTAssertThrowsError(
            try CodexHistoryReadback.older(
                Self.state([0]), before: "u0", minimumRevision: 4,
                fresh: { _, _ in
                    reads += 1
                    throw CLIError("Synthetic read failure")
                },
                hydrate: { _ in
                    hydrations += 1
                    return 5
                }))
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(hydrations, 0)

        XCTAssertThrowsError(
            try CodexHistoryReadback.older(
                Self.state([0]), before: "missing", minimumRevision: 4,
                fresh: { _, _ in
                    reads += 1
                    return try self.snapshot([0])
                },
                hydrate: { _ in
                    hydrations += 1
                    return 5
                }))
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(hydrations, 0)

        var time = 100.0
        XCTAssertThrowsError(
            try CodexHistoryReadback.older(
                Self.state([0], complete: false), before: "u0", minimumRevision: 4, now: { time },
                fresh: { _, _ in
                    reads += 1
                    time = 125
                    return try self.snapshot([0], complete: false)
                },
                hydrate: { _ in
                    hydrations += 1
                    return 5
                }))
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(hydrations, 0)
    }
    func testSnapshotRequiresExactOwnerThreadBodyVersionAndRevisionBarrier() throws {
        let good = Self.packet(state: Self.state([0, 1]))
        func checked(_ value: [String: Any]) throws -> CodexHistoryReadback.Snapshot? {
            CodexHistoryReadback.snapshot(
                try JSONSerialization.data(withJSONObject: value), thread: "native-thread", owner: "owner",
                minimumRevision: 4)
        }
        XCTAssertEqual(try checked(good)?.revision, 4)
        XCTAssertNotNil(try checked(Self.packet(state: Self.state([0, 1]), revision: 5)))
        for field in ["owner", "thread", "body", "host", "version", "patch", "stale", "boolean"] {
            var changed = good
            var params = changed["params"] as? [String: Any] ?? [:]
            var change = params["change"] as? [String: Any] ?? [:]
            switch field {
            case "owner": changed["sourceClientId"] = "another-owner"
            case "thread": params["conversationId"] = "another-thread"
            case "body": change["conversationState"] = ["id": "another-thread"]
            case "host": params["hostId"] = "another-host"
            case "version": changed["version"] = 12
            case "patch": change["type"] = "patch"
            case "stale": change["revision"] = 3
            default: change["revision"] = true
            }
            params["change"] = change
            changed["params"] = params
            XCTAssertNil(try checked(changed), field)
        }
        XCTAssertEqual(try CodexHistoryReadback.acknowledgedRevision(["result": ["revision": 4]]), 4)
        for invalid: Any in [true, 4.5, -1, NSNull(), "4"] {
            XCTAssertThrowsError(try CodexHistoryReadback.acknowledgedRevision(["result": ["revision": invalid]]))
        }
    }
}
