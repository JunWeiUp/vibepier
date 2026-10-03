import Foundation
import XCTest

@testable import VibePierCore

final class DeviceTrustStoreTests: XCTestCase {
    private let id = "00000000-0000-4000-8000-000000000001"
    private let key = Data(repeating: 0x31, count: 32)

    private final class Persistence: @unchecked Sendable {
        var data: Data?
        var fail = false
        func write(_ bytes: Data) throws {
            if fail { throw CocoaError(.fileWriteNoPermission) }
            data = bytes
        }
    }

    func testGrantAndRevokeCommitOnlyAfterPersistenceSucceeds() throws {
        let persistence = Persistence()
        let store = DeviceTrustStore(read: { nil }, write: { try persistence.write($0) })
        persistence.fail = true
        XCTAssertThrowsError(try store.authorize(id: id, name: "Phone", key: key))
        XCTAssertNil(store.key(for: id))
        persistence.fail = false
        try store.authorize(id: id, name: "Phone", key: key)
        XCTAssertEqual(store.key(for: id), key)
        persistence.fail = true
        XCTAssertThrowsError(try store.revoke(id))
        XCTAssertEqual(store.key(for: id), key)
        persistence.fail = false
        try store.revoke(id)
        XCTAssertNil(store.key(for: id))
        XCTAssertTrue(store.phones.isEmpty)
    }

    func testCorruptStoreCannotBeOverwrittenByAGrant() {
        let persistence = Persistence()
        let store = DeviceTrustStore(read: { Data("corrupt".utf8) }, write: { try persistence.write($0) })
        XCTAssertThrowsError(try store.authorize(id: id, name: "Phone", key: key))
        XCTAssertNil(persistence.data)
        XCTAssertNil(store.key(for: id))
    }

    func testReloadAndRevocationImmediatelyAffectTransportKeyLookup() throws {
        let persistence = Persistence()
        let store = DeviceTrustStore(read: { nil }, write: { try persistence.write($0) })
        try store.authorize(id: id, name: "Phone", key: key)
        let restored = DeviceTrustStore(read: { persistence.data }, write: { try persistence.write($0) })
        XCTAssertEqual(restored.phones.first?.id, id)
        let server = SecureControlServer(keyForDevice: { restored.key(for: $0) }, clock: { 1_700_000_000 })
        let keys = try SecureControlEnvelope.Keys(root: key)
        let fields = [SecureControlEnvelope.hello, id, UUID().uuidString, "1700000000", "1", "15"]
        let hello = Data(
            (fields + [SecureControlEnvelope.signature(fields, key: keys.handshake)]).joined(separator: " ").utf8)
        guard case .handshake = server.receive(hello, peer: "phone") else {
            return XCTFail("authorized handshake rejected")
        }
        XCTAssertNotNil(server.device(for: "phone"))
        try restored.revoke(id)
        XCTAssertNil(server.device(for: "phone"))
        XCTAssertNil(server.seal(Data("private state".utf8), peer: "phone"))
        guard case .rejected = server.receive(hello, peer: "phone") else {
            return XCTFail("revoked device reconnected")
        }
    }
}
