import CryptoKit
import Foundation
import Security

/// The reviewed native Unix listener speaks RFC 6455. The CLI proxy is a raw
/// tunnel; it does not translate JSON lines into WebSocket messages.
enum CodexRuntimeWebSocket {
    static let maximumTextBytes = 2_097_152
    enum Incoming {
        case text(Data)
        case ping(Data)
        case close
    }
    static func handshake(key: String? = nil) throws -> (request: Data, accept: String) {
        let key = try key ?? randomBytes(16).base64EncodedString()
        guard Data(base64Encoded: key)?.count == 16 else { throw RuntimeDriverError.invalidRequest }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let request =
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
        return (Data(request.utf8), Data(digest).base64EncodedString())
    }
    /// Returns nil while the bounded HTTP header is incomplete; preserves any
    /// first frame bytes that arrived in the same read as the upgrade response.
    static func validateHandshake(_ bytes: Data, accept: String) throws -> Data? {
        guard let end = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            guard bytes.count <= 8192 else { throw RuntimeDriverError.unavailable }
            return nil
        }
        let header = bytes[..<end.lowerBound]
        guard header.count <= 8192, header.allSatisfy({ $0 < 128 }),
            let text = String(data: header, encoding: .ascii)
        else { throw RuntimeDriverError.unavailable }
        let lines = text.components(separatedBy: "\r\n")
        let status = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
        guard status.count >= 2, status[0] == "HTTP/1.1", status[1] == "101" else {
            throw RuntimeDriverError.unavailable
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty, line.first != " ", line.first != "\t", let colon = line.firstIndex(of: ":") else {
                throw RuntimeDriverError.unavailable
            }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty,
                name.utf8.allSatisfy({
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }), headers[name] == nil
            else { throw RuntimeDriverError.unavailable }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let connection =
            headers["connection"]?.lowercased().split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            } ?? []
        guard headers["upgrade"]?.lowercased() == "websocket", connection.contains("upgrade"),
            headers["sec-websocket-accept"] == accept,
            headers["sec-websocket-extensions"] == nil, headers["sec-websocket-protocol"] == nil
        else { throw RuntimeDriverError.unavailable }
        return Data(bytes[end.upperBound...])
    }
    static func frame(_ payload: Data, opcode: UInt8 = 1, mask: Data? = nil) throws -> Data {
        guard (opcode == 1 && payload.count <= 300_000) || (opcode == 10 && payload.count <= 125) else {
            throw RuntimeDriverError.invalidRequest
        }
        let mask = try mask ?? randomBytes(4)
        guard mask.count == 4 else { throw RuntimeDriverError.invalidRequest }
        let maskBytes = Array(mask)
        var bytes = Data([0x80 | opcode])
        if payload.count < 126 {
            bytes.append(0x80 | UInt8(payload.count))
        } else if payload.count <= 65_535 {
            bytes.append(0x80 | 126)
            bytes.append(UInt8(payload.count >> 8))
            bytes.append(UInt8(payload.count & 255))
        } else {
            bytes.append(0x80 | 127)
            let size = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((size >> shift) & 255)) }
        }
        bytes.append(mask)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ maskBytes[$0.offset % 4] })
        return bytes
    }
    private static func randomBytes(_ count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw RuntimeDriverError.unavailable
        }
        return Data(bytes)
    }
    struct Decoder {
        private var buffer = Data()
        private var fragments = Data()
        private var continuing = false
        mutating func append(_ bytes: Data) throws -> [Incoming] {
            guard buffer.count + bytes.count <= maximumTextBytes + 65_550 else {
                throw RuntimeDriverError.unavailable
            }
            buffer.append(bytes)
            var events: [Incoming] = []
            while buffer.count >= 2 {
                let prefix = Array(buffer.prefix(10))
                let final = prefix[0] & 0x80 != 0
                let opcode = prefix[0] & 0x0f
                let shortSize = prefix[1] & 0x7f
                guard prefix[0] & 0x70 == 0, prefix[1] & 0x80 == 0,
                    [UInt8(0), 1, 8, 9, 10].contains(opcode)
                else { throw RuntimeDriverError.unavailable }
                let control = opcode >= 8
                guard !control || (final && shortSize <= 125) else { throw RuntimeDriverError.unavailable }
                let offset: Int
                let size: Int
                if shortSize == 126 {
                    guard prefix.count >= 4 else { break }
                    offset = 4
                    size = Int(prefix[2]) << 8 | Int(prefix[3])
                    guard size >= 126 else { throw RuntimeDriverError.unavailable }
                } else if shortSize == 127 {
                    guard prefix.count >= 10 else { break }
                    offset = 10
                    let wide = prefix[2..<10].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                    guard wide >= 65_536, wide <= UInt64(maximumTextBytes) else {
                        throw RuntimeDriverError.unavailable
                    }
                    size = Int(wide)
                } else {
                    offset = 2
                    size = Int(shortSize)
                }
                guard size <= maximumTextBytes else { throw RuntimeDriverError.unavailable }
                guard buffer.count >= offset + size else { break }
                let payload = Data(buffer.dropFirst(offset).prefix(size))
                buffer.removeSubrange(buffer.startIndex..<buffer.index(buffer.startIndex, offsetBy: offset + size))
                if opcode == 9 {
                    events.append(.ping(payload))
                    continue
                }
                if opcode == 10 { continue }
                if opcode == 8 {
                    guard payload.count != 1 else { throw RuntimeDriverError.unavailable }
                    if payload.count >= 2 {
                        let code =
                            Int(payload[payload.startIndex]) << 8
                            | Int(payload[payload.index(after: payload.startIndex)])
                        guard
                            ((1000...1014).contains(code) && ![1004, 1005, 1006].contains(code))
                                || (3000...4999).contains(code),
                            String(data: payload.dropFirst(2), encoding: .utf8) != nil
                        else { throw RuntimeDriverError.unavailable }
                    }
                    events.append(.close)
                    return events
                }
                if opcode == 1 {
                    guard !continuing else { throw RuntimeDriverError.unavailable }
                    if final {
                        guard String(data: payload, encoding: .utf8) != nil else {
                            throw RuntimeDriverError.unavailable
                        }
                        events.append(.text(payload))
                    } else {
                        fragments = payload
                        continuing = true
                    }
                } else {
                    guard continuing, fragments.count + payload.count <= maximumTextBytes else {
                        throw RuntimeDriverError.unavailable
                    }
                    fragments.append(payload)
                    if final {
                        guard String(data: fragments, encoding: .utf8) != nil else {
                            throw RuntimeDriverError.unavailable
                        }
                        events.append(.text(fragments))
                        fragments.removeAll(keepingCapacity: true)
                        continuing = false
                    }
                }
            }
            return events
        }
    }
}
