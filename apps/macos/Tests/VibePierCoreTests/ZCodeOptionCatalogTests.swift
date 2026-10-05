import Foundation
import XCTest

@testable import VibePierCore

final class ZCodeOptionCatalogTests: XCTestCase {
    private func entry(_ model: String = "model-a") -> ZCodeDesktop.Entry {
        var result = ZCodeDesktop.Entry()
        result.models = [.init(id: model, title: model, label: model, ordinal: 0, signature: "models")]
        result.modes = [.init(id: "build", title: "Confirm", label: "Confirm", ordinal: 0, signature: "modes")]
        result.composer = ["model": model, "mode": "build", "executionMode": "default", "password": "do-not-save"]
        result.title = "Private task"
        result.verified = true
        return result
    }
    func testLockedStartupDoesNotReadNativeMenusOrConsumeFirstUnlockedWarm() throws {
        let catalog = ZCodeDesktop.OptionCatalog()
        var reads = 0
        catalog.warm(canReadNative: false) {
            reads += 1
            return entry()
        }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(catalog.cached())
        catalog.warm(canReadNative: true) {
            reads += 1
            return entry()
        }
        XCTAssertEqual(reads, 1)
        catalog.warm(canReadNative: false) {
            XCTFail("Must not unlock for startup presentation")
            return entry()
        }
        XCTAssertEqual(catalog.cached()?.models.first?.id, "model-a")
    }
    func testRepeatedDraftAndDetailLoadsDoNotReadAgentAgain() throws {
        let catalog = ZCodeDesktop.OptionCatalog()
        var reads = 0
        catalog.warm {
            reads += 1
            return entry()
        }
        catalog.warm {
            XCTFail("Only once per launch")
            return entry()
        }
        for _ in 0..<10 {
            _ = try catalog.load {
                XCTFail("Cached options must not open menus")
                return entry()
            }
        }
        XCTAssertEqual(reads, 1)
        let refreshed = try catalog.load(refresh: true) {
            reads += 1
            return entry("model-b")
        }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(refreshed.models.first?.id, "model-b")
        XCTAssertThrowsError(try catalog.load(refresh: true) { throw CLIError("Unavailable") })
        XCTAssertEqual(catalog.cached()?.models.first?.id, "model-b")
    }
    func testCachedReadDoesNotWaitForStartupRefresh() throws {
        let catalog = ZCodeDesktop.OptionCatalog()
        _ = try catalog.load { entry() }
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "refresh complete")
        DispatchQueue.global().async {
            _ = try? catalog.load(refresh: true) {
                started.signal()
                _ = release.wait(timeout: .now() + 2)
                var fresh = ZCodeDesktop.Entry()
                fresh.models = [.init(id: "model-b", title: "B", label: "B", ordinal: 0, signature: "models")]
                fresh.modes = [.init(id: "build", title: "Confirm", label: "Confirm", ordinal: 0, signature: "modes")]
                fresh.composer = ["model": "model-b", "mode": "build", "executionMode": "plan"]
                return fresh
            }
            finished.fulfill()
        }
        defer { release.signal() }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let begin = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(
            try catalog.load {
                XCTFail("Must use last valid catalog")
                return entry()
            }.models.first?.id, "model-a")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - begin, 0.5)
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(catalog.cached()?.models.first?.id, "model-b")
    }
    func testPrivatePersistenceRestoresChoicesWithoutDraftOrAuthority() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("options.json")
        let catalog = ZCodeDesktop.OptionCatalog(file: file)
        _ = try catalog.load { entry() }
        let bytes = try Data(contentsOf: file)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("do-not-save"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Private task"))
        let restored = ZCodeDesktop.OptionCatalog(file: file)
        let cached = try restored.load {
            XCTFail("Restore must use disk catalog")
            return entry()
        }
        XCTAssertEqual(cached.models.first?.id, "model-a")
        XCTAssertFalse(cached.verified)
        XCTAssertTrue(cached.title.isEmpty)
        XCTAssertNil(cached.draftEmpty)
        XCTAssertNil(cached.composer["password"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testInvalidOrIncompleteCatalogCannotReplaceLastValidOptions() throws {
        let catalog = ZCodeDesktop.OptionCatalog()
        _ = try catalog.load { entry() }
        XCTAssertThrowsError(try catalog.load(refresh: true) { ZCodeDesktop.Entry() })
        XCTAssertEqual(catalog.cached()?.models.first?.id, "model-a")
    }
}
