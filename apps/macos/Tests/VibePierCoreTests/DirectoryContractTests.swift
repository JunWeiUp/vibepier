import Foundation
import XCTest

@testable import VibePierCore

final class DirectoryContractTests: XCTestCase {
    /// Explicitly opt in to reading an existing index. Never registers, publishes, or prints identities.
    func testExistingDirectoryReadOnlyInspection() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_EXISTING_DIRECTORY_INSPECTION"] else {
            throw XCTSkip("Current strict directory inspection requires explicit opt-in")
        }
        enum InspectionFailure: Error { case invalid }
        var activeSessions = 0
        var activeWorkspaces = 0
        do {
            guard path.hasPrefix("/") else { throw InspectionFailure.invalid }
            let file = URL(fileURLWithPath: path)
            let before = try Data(contentsOf: file)
            guard let object = try JSONSerialization.jsonObject(with: before) as? [String: Any],
                let host = object["hostRef"] as? String,
                let sessions = object["sessions"] as? [String: [String: Any]],
                let workspaces = object["workspaces"] as? [String: [String: Any]]
            else { throw InspectionFailure.invalid }
            let directory = try AgentSessionDirectory(file: file)
            guard directory.reliable, directory.hostRef == host else { throw InspectionFailure.invalid }
            let active = [
                "codex.currentV1": "codex", "claude.currentV1": "claude",
                "codex.managedAppServer": "codex", "claude.desktopMods": "claude",
            ]
            for (ref, row) in sessions {
                guard row["ref"] as? String == ref, let adapter = row["adapterID"] as? String,
                    let provider = row["provider"] as? String, let native = row["nativeID"] as? String,
                    let cwd = row["cwd"] as? String,
                    ref
                        == AgentSessionProfile.digest(
                            AgentSessionProfile.data(["host": host, "identity": ["session", adapter, native, cwd]]))
                else { throw InspectionFailure.invalid }
                if active[adapter] == provider {
                    guard let found = directory.session(ref), found.ref == ref, found.adapterID == adapter,
                        found.provider == provider, found.nativeID == native, found.cwd == cwd
                    else { throw InspectionFailure.invalid }
                    activeSessions += 1
                } else {
                    throw InspectionFailure.invalid  // Only the current schema is accepted.
                }
            }
            for (ref, row) in workspaces {
                guard row["ref"] as? String == ref, let adapter = row["adapterID"] as? String,
                    let provider = row["provider"] as? String, let cwd = row["cwd"] as? String,
                    ref
                        == AgentSessionProfile.digest(
                            AgentSessionProfile.data(["host": host, "identity": ["workspace", adapter, cwd]]))
                else { throw InspectionFailure.invalid }
                if active[adapter] == provider {
                    guard let found = directory.workspace(ref), found.ref == ref, found.adapterID == adapter,
                        found.provider == provider, found.cwd == cwd
                    else { throw InspectionFailure.invalid }
                    activeWorkspaces += 1
                } else {
                    throw InspectionFailure.invalid
                }
            }
            guard directory.hostRef == host, try Data(contentsOf: file) == before else {
                throw InspectionFailure.invalid
            }
            print(
                "EXISTING_DIRECTORY_INSPECTION PASS sessions_active=\(activeSessions) workspaces_active=\(activeWorkspaces)"
            )
        } catch {
            // Decoder and filesystem errors may contain paths/identity fields. Never forward their text.
            print("EXISTING_DIRECTORY_INSPECTION FAIL")
            XCTFail("Existing directory read-only inspection failed; details redacted")
        }
    }

    private static let activeAdapters: Set<String> = [
        "codex.currentV1", "claude.currentV1", "codex.managedAppServer", "claude.desktopMods",
    ]

    private final class Fixture {
        let root: URL
        let file: URL
        let host = "00000000-0000-4000-8000-000000000062"
        var sessions: [String: [String: Any]] = [:]
        var workspaces: [String: [String: Any]] = [:]
        var activeSessions: [String] = []
        var activeWorkspaces: [String] = []
        var hiddenSessions: [String] = []
        var hiddenWorkspaces: [String] = []

        init(unsupported: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            file = root.appendingPathComponent("synthetic-directory.json")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for (adapter, provider) in [
                ("codex.currentV1", "codex"), ("claude.currentV1", "claude"),
                ("codex.managedAppServer", "codex"), ("claude.desktopMods", "claude"),
            ] {
                add(adapter: adapter, provider: provider, active: provider != "zcode")
            }
            if unsupported {
                add(adapter: "zcode.currentV1", provider: "zcode", active: false)
                add(adapter: "future.runtime", provider: "future", active: false)
                add(adapter: "codex.future", provider: "codex", active: false)
            }
            try write()
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func reference(_ fields: [String]) -> String {
            AgentSessionProfile.digest(AgentSessionProfile.data(["host": host, "identity": fields]))
        }
        private func add(adapter: String, provider: String, active: Bool) {
            let cwd = "/synthetic/中文-é😀/" + adapter
            let native = "synthetic-thread-" + adapter
            let session = reference(["session", adapter, native, cwd])
            let workspace = reference(["workspace", adapter, cwd])
            sessions[session] = [
                "ref": session, "adapterID": adapter, "provider": provider, "nativeID": native, "cwd": cwd,
            ]
            workspaces[workspace] = ["ref": workspace, "adapterID": adapter, "provider": provider, "cwd": cwd]
            if active {
                activeSessions.append(session)
                activeWorkspaces.append(workspace)
            } else {
                hiddenSessions.append(session)
                hiddenWorkspaces.append(workspace)
            }
        }
        func write() throws {
            let bytes = try JSONSerialization.data(
                withJSONObject: [
                    "hostRef": host,
                    "sessions": sessions, "workspaces": workspaces,
                ],
                options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        func assertActive(_ directory: AgentSessionDirectory, file: StaticString = #filePath, line: UInt = #line) throws
        {
            XCTAssertEqual(directory.hostRef, host, file: file, line: line)
            XCTAssertTrue(directory.reliable, file: file, line: line)
            for ref in activeSessions {
                let expected = try XCTUnwrap(sessions[ref], file: file, line: line)
                let row = try XCTUnwrap(directory.session(ref), file: file, line: line)
                XCTAssertEqual(row.ref, ref, file: file, line: line)
                XCTAssertEqual(row.adapterID, expected["adapterID"] as? String, file: file, line: line)
                XCTAssertEqual(row.provider, expected["provider"] as? String, file: file, line: line)
                XCTAssertEqual(row.nativeID, expected["nativeID"] as? String, file: file, line: line)
                XCTAssertEqual(row.cwd, expected["cwd"] as? String, file: file, line: line)
            }
            for ref in activeWorkspaces {
                let expected = try XCTUnwrap(workspaces[ref], file: file, line: line)
                let row = try XCTUnwrap(directory.workspace(ref), file: file, line: line)
                XCTAssertEqual(row.ref, ref, file: file, line: line)
                XCTAssertEqual(row.adapterID, expected["adapterID"] as? String, file: file, line: line)
                XCTAssertEqual(row.provider, expected["provider"] as? String, file: file, line: line)
                XCTAssertEqual(row.cwd, expected["cwd"] as? String, file: file, line: line)
            }
        }
        func assertHidden(_ directory: AgentSessionDirectory, file: StaticString = #filePath, line: UInt = #line) throws
        {
            for ref in hiddenSessions {
                XCTAssertNil(directory.session(ref), file: file, line: line)
                let row = try XCTUnwrap(sessions[ref])
                XCTAssertThrowsError(
                    try directory.registerSession(
                        adapter: row["adapterID"] as! String, provider: row["provider"] as! String,
                        native: row["nativeID"] as! String, cwd: row["cwd"] as! String), file: file, line: line)
            }
            for ref in hiddenWorkspaces {
                XCTAssertNil(directory.workspace(ref), file: file, line: line)
                let row = try XCTUnwrap(workspaces[ref])
                XCTAssertThrowsError(
                    try directory.registerWorkspace(
                        adapter: row["adapterID"] as! String, provider: row["provider"] as! String,
                        cwd: row["cwd"] as! String), file: file, line: line)
            }
        }
    }

    func testStrictDirectoryRejectsEveryUnsupportedAdapterWithoutRewriting() throws {
        let fixture = try Fixture(unsupported: true)
        for hidden in fixture.hiddenSessions {
            let row = try XCTUnwrap(fixture.sessions[hidden])
            let unsupportedAdapter = try XCTUnwrap(row["adapterID"] as? String)
            let sessions = fixture.sessions.filter {
                Self.activeAdapters.contains($0.value["adapterID"] as? String ?? "")
                    || $0.value["adapterID"] as? String == unsupportedAdapter
            }
            let workspaces = fixture.workspaces.filter {
                Self.activeAdapters.contains($0.value["adapterID"] as? String ?? "")
                    || $0.value["adapterID"] as? String == unsupportedAdapter
            }
            let original = AgentSessionProfile.data([
                "hostRef": fixture.host, "sessions": sessions, "workspaces": workspaces,
            ])
            try original.write(to: fixture.file)
            XCTAssertThrowsError(try AgentSessionDirectory(file: fixture.file))
            XCTAssertEqual(try Data(contentsOf: fixture.file), original)
        }
        // New registrations use the same whitelist even without any on-disk index.
        try fixture.assertHidden(AgentSessionDirectory())
    }

    func testNewDirectoryAndCurrentPersistencePreserveHostAndReferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("current-index.json")
        let directory = try AgentSessionDirectory(file: file)
        let host = directory.hostRef
        XCTAssertNotNil(UUID(uuidString: host))
        XCTAssertTrue(directory.reliable)
        XCTAssertNil(directory.session("missing"))
        XCTAssertNil(directory.workspace("missing"))
        var sessions: [AgentSessionDirectory.Session] = []
        var workspaces: [AgentSessionDirectory.Workspace] = []
        for (adapter, provider) in [
            ("codex.currentV1", "codex"), ("claude.currentV1", "claude"),
            ("codex.managedAppServer", "codex"), ("claude.desktopMods", "claude"),
        ] {
            let cwd = "/synthetic/中文-é😀/" + adapter
            sessions.append(
                try directory.registerSession(
                    adapter: adapter, provider: provider, native: "fixture-" + adapter, cwd: cwd))
            workspaces.append(try directory.registerWorkspace(adapter: adapter, provider: provider, cwd: cwd))
        }
        let saved = try Data(contentsOf: file)
        let restored = try AgentSessionDirectory(file: file)
        XCTAssertEqual(restored.hostRef, host)
        for row in sessions {
            let read = try XCTUnwrap(restored.session(row.ref))
            XCTAssertEqual(read.adapterID, row.adapterID)
            XCTAssertEqual(read.provider, row.provider)
            XCTAssertEqual(read.nativeID, row.nativeID)
            XCTAssertEqual(read.cwd, row.cwd)
            XCTAssertEqual(
                try restored.registerSession(
                    adapter: row.adapterID, provider: row.provider, native: row.nativeID, cwd: row.cwd
                ).ref, row.ref)
        }
        for row in workspaces {
            let read = try XCTUnwrap(restored.workspace(row.ref))
            XCTAssertEqual(read.adapterID, row.adapterID)
            XCTAssertEqual(read.provider, row.provider)
            XCTAssertEqual(read.cwd, row.cwd)
            XCTAssertEqual(
                try restored.registerWorkspace(adapter: row.adapterID, provider: row.provider, cwd: row.cwd).ref,
                row.ref)
        }
        XCTAssertEqual(
            try Data(contentsOf: file), saved, "Reads and idempotent registration must not rewrite current storage")
    }

    func testStrictActiveIndexRejectsHashAndProviderBindingTampering() throws {
        for kind in ["session", "workspace"] {
            for tamper in ["hash", "provider"] {
                let fixture = try Fixture()
                if kind == "session" {
                    let key = fixture.activeSessions[0]
                    var row = try XCTUnwrap(fixture.sessions.removeValue(forKey: key))
                    let replacement = tamper == "hash" ? String(repeating: "0", count: 64) : key
                    row["ref"] = replacement
                    if tamper == "provider" { row["provider"] = "claude" }
                    fixture.sessions[replacement] = row
                } else {
                    let key = fixture.activeWorkspaces[0]
                    var row = try XCTUnwrap(fixture.workspaces.removeValue(forKey: key))
                    let replacement = tamper == "hash" ? String(repeating: "0", count: 64) : key
                    row["ref"] = replacement
                    if tamper == "provider" { row["provider"] = "claude" }
                    fixture.workspaces[replacement] = row
                }
                try fixture.write()  // No unsupported row can mask the actual corruption.
                let original = try Data(contentsOf: fixture.file)
                XCTAssertThrowsError(try AgentSessionDirectory(file: fixture.file))
                XCTAssertEqual(try Data(contentsOf: fixture.file), original)
            }
        }
    }

    func testCurrentDirectoryPreservesCompareAndSwap() throws {
        let fixture = try Fixture()
        try fixture.write()
        let first = try AgentSessionDirectory(file: fixture.file)
        let stale = try AgentSessionDirectory(file: fixture.file)
        _ = try first.registerWorkspace(adapter: "codex.currentV1", provider: "codex", cwd: "/synthetic/first")
        let latest = try Data(contentsOf: fixture.file)
        XCTAssertThrowsError(
            try stale.registerWorkspace(adapter: "codex.currentV1", provider: "codex", cwd: "/synthetic/stale"))
        XCTAssertFalse(stale.reliable)
        XCTAssertEqual(try Data(contentsOf: fixture.file), latest)
    }
}
