import Darwin
import XCTest

@testable import VibePierCore

final class CodexRuntimeTransportTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vp-t-" + String(UUID().uuidString.prefix(12)))
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUnlinkedExecutableRequiresOriginalBirthAndKernelSocketPeer() throws {
        let folder = try directory()
        let url = folder.appendingPathComponent("peer.sock")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(url.path.utf8) + [UInt8(0)]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
        XCTAssertEqual(Darwin.listen(fd, 8), 0)
        var info = stat()
        XCTAssertEqual(lstat(url.path, &info), 0)
        var birth = proc_bsdinfo()
        XCTAssertEqual(
            proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &birth, Int32(MemoryLayout<proc_bsdinfo>.size)),
            Int32(MemoryLayout<proc_bsdinfo>.size))
        func known(birthSeconds: UInt64? = nil, inode: UInt64? = nil) -> CodexSocketRuntimeConnection.Metadata {
            .init(
                version: CodexHeadlessRuntimeContract.version, instanceID: "fixture",
                executablePath: "/synthetic/old-codex", processID: getpid(),
                processBirthSeconds: birthSeconds ?? birth.pbi_start_tvsec,
                processBirthMicroseconds: birth.pbi_start_tvusec,
                socketDevice: info.st_dev, socketInode: inode ?? info.st_ino, codexHomePath: folder.path)
        }
        let absent: (Int32) -> (path: String?, error: Int32) = { _ in (nil, ENOENT) }
        XCTAssertTrue(
            CodexSocketRuntimeConnection.matchesProcess(
                known(), socketURL: url, allowUnlinkedExecutable: true, readExecutable: absent))
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesProcess(
                known(), socketURL: url, readExecutable: absent))
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesProcess(
                known(birthSeconds: birth.pbi_start_tvsec + 1), socketURL: url,
                allowUnlinkedExecutable: true, readExecutable: absent))
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesProcess(
                known(inode: info.st_ino + 1), socketURL: url, allowUnlinkedExecutable: true, readExecutable: absent))
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesProcess(
                known(), socketURL: url, allowUnlinkedExecutable: true, readExecutable: { _ in (nil, EACCES) }))
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesProcess(
                known(), socketURL: url, allowUnlinkedExecutable: true, readExecutable: { _ in ("/other/process", 0) }))
    }

    func testManagedTransportRetainsItsControlBoundary() {
        for method in ["thread/resume", "thread/name/set", "thread/archive", "thread/unarchive", "turn/steer"] {
            XCTAssertFalse(CodexSocketRuntimeConnection.allowsRequest(method, usesNativeHome: false))
            XCTAssertTrue(CodexSocketRuntimeConnection.allowsRequest(method, usesNativeHome: true))
        }
        for nativeHome in [false, true] {
            XCTAssertTrue(CodexSocketRuntimeConnection.allowsRequest("thread/read", usesNativeHome: nativeHome))
            XCTAssertTrue(CodexSocketRuntimeConnection.allowsRequest("turn/start", usesNativeHome: nativeHome))
            XCTAssertFalse(CodexSocketRuntimeConnection.allowsRequest("command/exec", usesNativeHome: nativeHome))
            XCTAssertFalse(CodexSocketRuntimeConnection.allowsRequest("config/write", usesNativeHome: nativeHome))
        }
    }

    func testAdditionalPermissionRequestsRequireTheBackgroundChannel() {
        XCTAssertFalse(
            CodexSocketRuntimeConnection.allowsServerRequest("item/permissions/requestApproval", usesNativeHome: false))
        XCTAssertTrue(
            CodexSocketRuntimeConnection.allowsServerRequest("item/permissions/requestApproval", usesNativeHome: true))
        for nativeHome in [false, true] {
            XCTAssertTrue(
                CodexSocketRuntimeConnection.allowsServerRequest(
                    "item/tool/requestUserInput", usesNativeHome: nativeHome))
            XCTAssertFalse(
                CodexSocketRuntimeConnection.allowsServerRequest("item/tool/call", usesNativeHome: nativeHome))
        }
    }

    func testNativeHomeValidationPreservesExistingSyntheticConfiguration() throws {
        let folder = try directory()
        let home = folder.appendingPathComponent("home")
        try FileManager.default.createDirectory(
            at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let config = home.appendingPathComponent("config.toml")
        let synthetic = Data("synthetic fixture\n".utf8)
        try synthetic.write(to: config)
        let before = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(
            try CodexSocketRuntimeConnection.validatedNativeHome(home),
            try XCTUnwrap(CodexSocketRuntimeConnection.nativeCanonicalURL(home)))
        XCTAssertEqual(try Data(contentsOf: config), synthetic)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions] as? NSNumber, before)
        let link = folder.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home)
        XCTAssertEqual(
            try CodexSocketRuntimeConnection.validatedNativeHome(link),
            try XCTUnwrap(CodexSocketRuntimeConnection.nativeCanonicalURL(home)))
    }

    func testNativeHomeValidationRejectsMissingAndNonDirectoryInputs() throws {
        let folder = try directory()
        let missing = folder.appendingPathComponent("missing")
        XCTAssertThrowsError(try CodexSocketRuntimeConnection.validatedNativeHome(missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let file = folder.appendingPathComponent("file")
        try Data("fixture".utf8).write(to: file)
        XCTAssertThrowsError(try CodexSocketRuntimeConnection.validatedNativeHome(file))
        XCTAssertThrowsError(try CodexSocketRuntimeConnection.validatedNativeHome(URL(string: "https://example.test")!))
    }

    func testBackgroundContractDoesNotWidenTheManagedReleaseGate() throws {
        let folder = try directory()
        XCTAssertThrowsError(
            try CodexHeadlessRuntimeContract.validateSchemaDirectory(folder, runtimeVersion: "0.159.0")
        ) { error in
            XCTAssertEqual(error as? RuntimeDriverError, .incompatibleVersion)
        }
        XCTAssertThrowsError(
            try CodexHeadlessRuntimeContract.validateExecutionModeSchemaDirectory(folder, runtimeVersion: "0.161.0")
        ) {
            error in XCTAssertEqual(error as? RuntimeDriverError, .incompatibleVersion)
        }
        XCTAssertThrowsError(
            try CodexManagedRuntimeContract.validateSchemaDirectory(folder, runtimeVersion: "0.160.0")
        ) { error in
            XCTAssertEqual(error as? RuntimeDriverError, .incompatibleVersion)
        }
        XCTAssertThrowsError(
            try CodexHeadlessRuntimeContract.validateSchemaDirectory(folder, runtimeVersion: "0.160.0"))
    }

    func testWrongReleaseStopsBeforeStartingOrRecordingAServer() throws {
        let folder = try directory()
        let executable = folder.appendingPathComponent("codex-fixture")
        try Data("#!/bin/sh\nprintf '%s\\n' 'codex-cli 0.159.0'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let storage = folder.appendingPathComponent("runtime")
        XCTAssertThrowsError(
            try CodexSocketRuntimeConnection(
                configuration: .init(enabled: true, executablePath: executable.path, directoryPath: storage.path),
                nativeHome: folder)
        ) { error in XCTAssertEqual(error as? RuntimeDriverError, .incompatibleVersion) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("server.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("control.sock").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.appendingPathComponent("codex-home").path))
    }

    private func deadProcessID() throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        process.waitUntilExit()
        return process.processIdentifier
    }

    private func syntheticSocket(_ url: URL) throws -> stat {
        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw RuntimeDriverError.unavailable }
        defer { Darwin.close(socketFD) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8) + [UInt8(0)]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw RuntimeDriverError.invalidRequest
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0 else { throw RuntimeDriverError.unavailable }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw RuntimeDriverError.unavailable }
        return info
    }

    private func metadata(processID: Int32, socket: stat = stat()) -> CodexSocketRuntimeConnection.Metadata {
        .init(
            version: CodexHeadlessRuntimeContract.version, instanceID: "synthetic-instance",
            executablePath: "/synthetic/codex", processID: processID, processBirthSeconds: 1,
            processBirthMicroseconds: 2, socketDevice: socket.st_dev, socketInode: socket.st_ino,
            codexHomePath: "/synthetic/home")
    }

    func testVerifiedDeadServerSocketIsRemovedAndMetadataIsArchived() throws {
        let folder = try directory()
        let socketURL = folder.appendingPathComponent("control.sock")
        let info = try syntheticSocket(socketURL)
        let known = metadata(processID: try deadProcessID(), socket: info)
        let metadataURL = folder.appendingPathComponent("server.json")
        let original = try JSONEncoder().encode(known)
        try RuntimePrivateStorage.write(original, to: metadataURL)
        try CodexSocketRuntimeConnection.retireDeadServer(known, metadataURL: metadataURL, socketURL: socketURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
        let archived = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".retired-server-") }
        XCTAssertEqual(archived.count, 1)
        XCTAssertEqual(try RuntimePrivateStorage.read(XCTUnwrap(archived.first), limit: 4096), original)
    }

    func testVerifiedDeadServerWithMissingSocketCanBeRetired() throws {
        let folder = try directory()
        let known = metadata(processID: try deadProcessID())
        let metadataURL = folder.appendingPathComponent("server.json")
        try RuntimePrivateStorage.write(try JSONEncoder().encode(known), to: metadataURL)
        try CodexSocketRuntimeConnection.retireDeadServer(
            known, metadataURL: metadataURL, socketURL: folder.appendingPathComponent("missing.sock"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }

    func testLiveProcessAndReplacedSocketNeverAuthorizeRetirement() throws {
        let folder = try directory()
        let socketURL = folder.appendingPathComponent("control.sock")
        let info = try syntheticSocket(socketURL)
        let metadataURL = folder.appendingPathComponent("server.json")
        let live = metadata(processID: getpid(), socket: info)
        try RuntimePrivateStorage.write(try JSONEncoder().encode(live), to: metadataURL)
        XCTAssertThrowsError(
            try CodexSocketRuntimeConnection.retireDeadServer(live, metadataURL: metadataURL, socketURL: socketURL))
        var replaced = info
        replaced.st_ino += 1
        let dead = metadata(processID: try deadProcessID(), socket: replaced)
        try RuntimePrivateStorage.write(try JSONEncoder().encode(dead), to: metadataURL)
        XCTAssertThrowsError(
            try CodexSocketRuntimeConnection.retireDeadServer(dead, metadataURL: metadataURL, socketURL: socketURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertEqual(
            try JSONDecoder().decode(
                CodexSocketRuntimeConnection.Metadata.self,
                from: RuntimePrivateStorage.read(metadataURL, limit: 4096)), dead)
    }

    private func aliasFixture() throws -> (folder: URL, alias: URL, root: URL, endpoint: URL) {
        let folder = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "vp-a-" + String(UUID().uuidString.prefix(8)))
        try RuntimePrivateStorage.ensureDirectory(folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let root = folder.appendingPathComponent("uds")
        let advertised = folder.appendingPathComponent("r")
        try RuntimePrivateStorage.ensureDirectory(root)
        try RuntimePrivateStorage.ensureDirectory(advertised)
        let alias = advertised.appendingPathComponent("control.sock")
        let endpoint = try XCTUnwrap(CodexSocketRuntimeConnection.nativeEndpoint(alias, aliasRoot: root))
        _ = try syntheticSocket(endpoint)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: endpoint)
        return (folder, alias, root, endpoint)
    }

    private func aliasMetadata(
        _ fixture: (folder: URL, alias: URL, root: URL, endpoint: URL), processID: Int32
    ) throws -> CodexSocketRuntimeConnection.Metadata {
        let identity = try XCTUnwrap(
            CodexSocketRuntimeConnection.socketIdentity(fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root))
        var known = metadata(processID: processID, socket: identity.advertised)
        known.endpointPath = identity.endpointPath
        known.endpointDevice = identity.endpointDevice
        known.endpointInode = identity.endpointInode
        return known
    }

    func testReviewedNativeAliasRequiresBothPrivateSocketAndMatchingMetadata() throws {
        let fixture = try aliasFixture()
        XCTAssertNil(CodexSocketRuntimeConnection.socketIdentity(fixture.alias))
        let known = try aliasMetadata(fixture, processID: getpid())
        XCTAssertTrue(
            CodexSocketRuntimeConnection.matchesSocket(
                fixture.alias, metadata: known, allowNativeAlias: true, aliasRoot: fixture.root))
        var changed = known
        changed.endpointInode = (known.endpointInode ?? 0) + 1
        XCTAssertFalse(
            CodexSocketRuntimeConnection.matchesSocket(
                fixture.alias, metadata: changed, allowNativeAlias: true, aliasRoot: fixture.root))
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: fixture.endpoint.path)
        XCTAssertNil(
            CodexSocketRuntimeConnection.socketIdentity(fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root))
    }

    func testNativeAliasRejectsUnexpectedTargetAndNonprivateParents() throws {
        let fixture = try aliasFixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        XCTAssertNil(
            CodexSocketRuntimeConnection.socketIdentity(fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        try FileManager.default.removeItem(at: fixture.alias)
        try FileManager.default.createSymbolicLink(
            at: fixture.alias,
            withDestinationURL: fixture.root.appendingPathComponent(String(repeating: "f", count: 64)))
        XCTAssertNil(
            CodexSocketRuntimeConnection.socketIdentity(fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root))
    }

    func testDeadAliasRetirementNeverRemovesTheNativeEndpoint() throws {
        let fixture = try aliasFixture()
        let known = try aliasMetadata(fixture, processID: deadProcessID())
        let metadataURL = fixture.alias.deletingLastPathComponent().appendingPathComponent("server.json")
        try RuntimePrivateStorage.write(try JSONEncoder().encode(known), to: metadataURL)
        try CodexSocketRuntimeConnection.retireDeadServer(
            known, metadataURL: metadataURL, socketURL: fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root)
        var info = stat()
        XCTAssertEqual(lstat(fixture.alias.path, &info), -1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.endpoint.path))
    }

    func testDeadVerifiedAliasSurvivesMissingNativeEndpointAfterReboot() throws {
        let fixture = try aliasFixture()
        let known = try aliasMetadata(fixture, processID: deadProcessID())
        let metadataURL = fixture.alias.deletingLastPathComponent().appendingPathComponent("server.json")
        try RuntimePrivateStorage.write(try JSONEncoder().encode(known), to: metadataURL)
        try FileManager.default.removeItem(at: fixture.endpoint)
        try CodexSocketRuntimeConnection.retireDeadServer(
            known, metadataURL: metadataURL, socketURL: fixture.alias, allowNativeAlias: true, aliasRoot: fixture.root)
        var info = stat()
        XCTAssertEqual(lstat(fixture.alias.path, &info), -1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadataURL.path))
    }
}
