import XCTest

@testable import VibePierCore

final class PhoneBindingsTests: XCTestCase {
    private func store() -> PhoneBindings {
        PhoneBindings(
            url: FileManager.default.temporaryDirectory.appendingPathComponent(
                "phone-tests-\(UUID().uuidString)/bindings.json"))
    }
    func testLabelsPersistInheritResetAndRejectConflicts() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-label-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PhoneBindings(url: url)
        let global = PhoneBindings.key("confirm")
        let app = PhoneBindings.key("confirm", app: "com.example.editor")
        try store.set(key: global, value: "return", label: "发送")
        XCTAssertEqual(store.resolvedLabel("confirm", app: "com.example.editor", fallback: "确认"), "发送")
        try store.set(key: app, value: "return", name: "Editor", label: "运行")
        XCTAssertEqual(
            PhoneBindings(url: url).resolvedLabel("confirm", app: "com.example.editor", fallback: "确认"), "运行")
        XCTAssertEqual(store.snapshot.entries[app]?.name, "Editor")
        XCTAssertFalse(try store.set(key: app, value: "return", label: "旧名称", expectedVersion: ""))
        XCTAssertThrowsError(try store.set(key: app, value: "return", label: String(repeating: "x", count: 201)))
        try store.set(key: app, value: nil)
        XCTAssertEqual(store.resolvedLabel("confirm", app: "com.example.editor", fallback: "确认"), "发送")
        try store.set(key: global, value: nil)
        XCTAssertEqual(store.resolvedLabel("confirm", fallback: "确认"), "确认")
    }
    func testOldEntryWithoutLabelStillDecodes() throws {
        let data = Data(#"{"value":"return","generation":1,"version":"v","operation":"o","name":"Editor"}"#.utf8)
        let entry = try JSONDecoder().decode(PhoneBindings.Entry.self, from: data)
        XCTAssertNil(entry.label)
        XCTAssertEqual(entry.name, "Editor")
    }
    func testMigrationTombstonesAndConflict() throws {
        let store = store()
        let key = PhoneBindings.key("talk", app: "com.example.editor")
        XCTAssertTrue(try store.set(key: key, value: "Command + Control", expectedVersion: "", operation: "first"))
        let version = try XCTUnwrap(store.snapshot.entries[key]?.version)
        XCTAssertEqual(store.resolved("talk", app: "com.example.editor"), "cmd+ctrl")
        XCTAssertFalse(try store.set(key: key, value: "fn", expectedVersion: ""))
        XCTAssertTrue(try store.set(key: key, value: nil, expectedVersion: version))
        XCTAssertEqual(store.resolved("talk", app: "com.example.editor"), "rcmd")
        XCTAssertFalse(try store.set(key: key, value: "fn", expectedVersion: ""))
        XCTAssertEqual(store.snapshot.generation, 2)
    }
    func testRetryIsIdempotentAndPersistence() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("phone-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = PhoneBindings(url: url)
        let key = PhoneBindings.key("confirm")
        XCTAssertTrue(try store.set(key: key, value: "cmd+return", expectedVersion: "", operation: "retry"))
        let revision = store.snapshot.revision
        XCTAssertTrue(try store.set(key: key, value: "cmd+return", expectedVersion: "", operation: "retry"))
        XCTAssertEqual(store.snapshot.revision, revision)
        XCTAssertEqual(PhoneBindings(url: url).resolved("confirm", app: "org.example"), "cmd+return")
        XCTAssertEqual(PhoneBindings(url: url).snapshot.server, store.snapshot.server)
    }
    func testBoundedSnapshotAndPeerValidation() throws {
        let store = store()
        for i in 0..<30 {
            try store.set(key: PhoneBindings.key("talk", app: "org.example.\(i)"), value: "rcmd", name: "应用 \(i)")
        }
        XCTAssertNil(store.reply(to: #"{"type":"vibepier-bindings-get1","sender":"other"}"#, sender: "phone"))
        let frames = try XCTUnwrap(
            store.reply(to: #"{"type":"vibepier-bindings-get1","sender":"phone"}"#, sender: "phone"))
        XCTAssertGreaterThan(frames.count, 1)
        var encoded = ""
        for frame in frames {
            XCTAssertLessThan(frame.count, 1400)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: frame) as? [String: Any])
            encoded += json["data"] as! String
        }
        let decoded = try JSONDecoder().decode(
            PhoneBindings.Snapshot.self, from: XCTUnwrap(Data(base64Encoded: encoded)))
        XCTAssertEqual(decoded.entries, store.snapshot.entries)
    }
    func testComposingModifiersAndPresets() throws {
        XCTAssertEqual(try PhoneBindings.choosingPreset("return", text: "cmd+ctrl"), "cmd+ctrl+return")
        XCTAssertEqual(try PhoneBindings.choosingPreset("cmd+v", text: "cmd+ctrl"), "cmd+v")
        XCTAssertEqual(try PhoneBindings.togglingModifier("cmd+ctrl", modifier: "ctrl", enabled: false), "cmd")
        XCTAssertTrue(PhoneBindings.hasModifier("Command + Control", modifier: "cmd"))
        XCTAssertEqual(PhoneBindings.label("rcmd"), L10n.text("control.right_4"))
    }
    func testInvalidEditsDoNotDamageSavedPreferences() throws {
        let store = store()
        XCTAssertThrowsError(try store.set(key: "hardware.talk", value: "rcmd"))
        XCTAssertThrowsError(try store.set(key: PhoneBindings.key("talk"), value: "nonsense"))
        XCTAssertTrue(store.snapshot.entries.isEmpty)
    }
}
