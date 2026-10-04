import CryptoKit
import Darwin
import Foundation
import XCTest

@testable import VibePierCore

/// Explicit emulator-only host; private synthetic storage, loopback, no providers or desktop actions.
final class AttachmentNetworkProbeTests: XCTestCase {
    func testEmulatorUploadHost() throws {
        guard ProcessInfo.processInfo.environment["VIBEPIER_UPLOAD_NETWORK_PROBE"] == "1" else {
            throw XCTSkip("Requires explicit Android emulator network probe")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try CodexAttachments(root: root)
        let key = Data(repeating: 0x31, count: 32)
        let security = SecureControlServer(keyForDevice: { _ in key })
        var inbox = SessionPacketInbox()
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var bufferSize: Int32 = 4 * 1024 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout.size(ofValue: bufferSize)))
        var timeout = timeval(tv_sec: 0, tv_usec: 20000)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        XCTAssertEqual(
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }, 0)
        var addressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &addressLength) }
        }
        guard let marker = ProcessInfo.processInfo.environment["VIBEPIER_UPLOAD_NETWORK_PORT"] else {
            return XCTFail("Missing private port marker")
        }
        try String(UInt16(bigEndian: address.sin_port)).write(toFile: marker, atomically: true, encoding: .utf8)
        func reply(_ response: [String: Any], device: String, endpoint: sockaddr_in, peer: String) throws {
            var endpoint = endpoint
            let packet = UUID().uuidString
            let sealed = try SessionEnvelope.seal(
                try JSONSerialization.data(withJSONObject: response), key: key, device: device, packet: packet,
                direction: "mac")
            for frame in SessionEnvelope.frames(sealed, device: device, packet: packet, sender: device) {
                guard let wire = security.seal(frame, peer: peer) else { continue }
                _ = wire.withUnsafeBytes { raw in
                    withUnsafePointer(to: &endpoint) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        var completed = 0
        var bulk = 0
        var rejectedBulk = 0
        var dropped = false
        var missingSent = 0
        var recovery: [String: (device: String, endpoint: sockaddr_in, peer: String, next: Double)] = [:]
        while ProcessInfo.processInfo.systemUptime < deadline {
            let now = ProcessInfo.processInfo.systemUptime
            for (packet, item) in recovery where now >= item.next {
                guard let missing = inbox.missingUpload(sender: item.device, packet: packet) else {
                    recovery.removeValue(forKey: packet)
                    continue
                }
                try reply(missing, device: item.device, endpoint: item.endpoint, peer: item.peer)
                missingSent += 1
                recovery[packet]?.next = now + 0.15
            }
            var peerAddress = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            var bytes = [UInt8](repeating: 0, count: 16385)
            let count = withUnsafeMutablePointer(to: &peerAddress) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &bytes, bytes.count, 0, $0, &length)
                }
            }
            if count < 0 { continue }
            let data = Data(bytes.prefix(count))
            let peer = "probe:\(peerAddress.sin_port)"
            func send(_ data: Data) {
                _ = data.withUnsafeBytes { raw in
                    withUnsafePointer(to: &peerAddress) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
                        }
                    }
                }
            }
            switch security.receive(data, peer: peer) {
            case .handshake(let reply): send(reply)
            case .rejected:
                if data.starts(with: Data("vibepier-bulk1 ".utf8)) { rejectedBulk += 1 }
                continue
            case .message(let device, let payload):
                if payload == Data("probe-finish".utf8) {
                    XCTAssertEqual(completed, 2)
                    XCTAssertGreaterThan(bulk, 0)
                    XCTAssertGreaterThan(missingSent, 0)
                    try JSONSerialization.data(withJSONObject: [
                        "completed": completed, "bulkFrames": bulk, "rejectedBulkFrames": rejectedBulk,
                        "missingReceipts": missingSent, "forcedLossRecovered": dropped,
                    ]).write(to: URL(fileURLWithPath: marker + ".json"))
                    return
                }
                if data.starts(with: Data("vibepier-bulk1 ".utf8)) { bulk += 1 }
                if !dropped, let frame = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                    frame["upload"] != nil
                {
                    dropped = true
                    continue
                }
                guard let message = inbox.receive(payload, sender: device, key: key, allowsUploads: true) else {
                    if let packet = inbox.recoveryPacket(payload, sender: device) {
                        recovery[packet] = (device, peerAddress, peer, ProcessInfo.processInfo.systemUptime + 0.15)
                    }
                    continue
                }
                var request = message.request
                let id = try XCTUnwrap(request["id"] as? String)
                let thread = try XCTUnwrap(request["threadId"] as? String)
                var response: [String: Any]
                do {
                    switch request["op"] as? String {
                    case "attachmentStart":
                        if request["name"] as? String == "legacy.bin" { request.removeValue(forKey: "uploadVersion") }
                        response = try storage.start(request, device: device, thread: thread)
                    case "attachmentChunk": response = try storage.chunk(request, device: device, thread: thread)
                    case "attachmentComplete":
                        response = try storage.complete(request, device: device, thread: thread)
                        completed += 1
                    case "attachmentRemove":
                        try storage.remove(request["attachmentId"] as? String ?? "", device: device, thread: thread)
                        response = [:]
                    default: throw SecureControlEnvelope.Failure.invalidFrame
                    }
                    response["ok"] = true
                } catch { response = ["ok": false, "error": String(describing: error)] }
                response["id"] = id
                try reply(response, device: device, endpoint: peerAddress, peer: peer)
            }
        }
        XCTFail("Emulator upload probe timed out")
    }
}
