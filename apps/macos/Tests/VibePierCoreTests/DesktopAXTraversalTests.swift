import AppKit
import ApplicationServices
import XCTest

@testable import VibePierCore

final class DesktopAXTraversalTests: XCTestCase {
    func testDepthFirstMenuOrderIsBoundedAndDoesNotRepeatCyclesOrDescendIntoChoices() {
        let tree = [0: [1, 2], 1: [3], 2: [4], 3: [0], 4: [5], 5: []]
        let result = DesktopAXTraversal.collect(
            0, limit: 10, withinDeadline: { true }, depthFirst: true,
            identity: { $0 }, children: { node, _ in tree[node] }, descend: { $0 != 4 })
        XCTAssertEqual(result, [0, 1, 3, 2, 4])
        XCTAssertNil(
            DesktopAXTraversal.collect(
                0, limit: 2, withinDeadline: { true }, depthFirst: true,
                identity: { $0 }, children: { node, _ in tree[node] }))
        XCTAssertNil(
            DesktopAXTraversal.collect(
                0, limit: 10, withinDeadline: { false }, depthFirst: true,
                identity: { $0 }, children: { node, _ in tree[node] }))
    }
    func testIncompleteScopeNeverReturnsAnApparentlyUniqueControl() {
        var requestedCapacity = -1
        let result = DesktopAXTraversal.collect(
            0, limit: 3, withinDeadline: { true }, identity: { $0 },
            children: { node, capacity in
                if node == 0 { return [1, 2] }
                if node == 1 { return [] }  // First apparent composer.
                requestedCapacity = capacity
                return nil  // Another subtree cannot be inspected within its zero remaining slots.
            })
        XCTAssertNil(result)
        XCTAssertEqual(requestedCapacity, 0)
    }
    func testCompleteTreeIncludesEveryCandidateAndDeduplicatesCycles() {
        let tree = [0: [1, 2], 1: [0], 2: [3], 3: [2]]
        let result = DesktopAXTraversal.collect(
            0, limit: 8, withinDeadline: { true }, identity: { $0 }, children: { node, _ in tree[node] })
        XCTAssertEqual(result, [0, 1, 2, 3])
    }
    func testChildOverflowReadFailureAndDeadlineFailClosed() {
        XCTAssertNil(
            DesktopAXTraversal.collect(
                0, limit: 2, withinDeadline: { true }, identity: { $0 }, children: { _, _ in [1, 2] }))
        XCTAssertNil(
            DesktopAXTraversal.collect(
                0, limit: 2, withinDeadline: { true }, identity: { $0 }, children: { _, _ in nil }))
        var checks = 0
        XCTAssertNil(
            DesktopAXTraversal.collect(
                0, limit: 2,
                withinDeadline: {
                    checks += 1
                    return checks < 2
                }, identity: { $0 }, children: { _, _ in [] }))
    }
    func testRouteScopeCanPruneTranscriptDescendantsWithoutDroppingOtherWebAreas() {
        var visited: [Int] = []
        let result = DesktopAXTraversal.collect(
            0, limit: 4, withinDeadline: { true }, identity: { $0 },
            children: { node, _ in
                visited.append(node)
                return node == 0 ? [1, 2] : [3]
            }, descend: { $0 == 0 })
        XCTAssertEqual(result, [0, 1, 2])
        XCTAssertEqual(visited, [0])
    }
    @MainActor
    func testNativeWindowTraversalReadOnlySmoke() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_NATIVE_AX_SMOKE"] == "1" else {
            throw XCTSkip("Opt-in native read-only AX smoke")
        }
        guard AXIsProcessTrusted() else { throw XCTSkip("Native accessibility read access unavailable") }
        var inspected = 0
        for id in ["com.openai.codex", "com.anthropic.claudefordesktop", "dev.zcode.app"] {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first else { continue }
            let root = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.1)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { continue }
            let start = ProcessInfo.processInfo.systemUptime
            let nodes = DesktopAXTraversal.elements(value as! AXUIElement, limit: 6000, timeout: 3)
            print(
                "AX_READ_ONLY bundle=\(id) complete=\(nodes != nil) nodes=\(nodes?.count ?? 0) seconds=\(ProcessInfo.processInfo.systemUptime - start)"
            )
            XCTAssertNotNil(nodes, "Native focused window could not be inspected completely: " + id)
            inspected += 1
        }
        XCTAssertGreaterThan(inspected, 0)
    }

}
