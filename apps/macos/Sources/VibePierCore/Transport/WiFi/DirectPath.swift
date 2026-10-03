// SPDX-License-Identifier: MIT
//
// Direct phone↔Mac UDP across networks (docs/relay-protocol.md, "Direct path").
// The authenticated relay carries only the signalling: the phone offers its
// candidates and a random token, the Mac answers with its own, and both sides
// send `vibepier-punch1 <sender> <token>` at each other until a NAT hole opens.
// Internet sources are accepted by RemoteListener only after a valid punch.

import Darwin
import Foundation

/// A numeric UDP address of either family plus the socket that reaches it.
struct UDPEndpoint {
    var fd: Int32
    var storage: sockaddr_storage
    var length: socklen_t
    var host: String
    var port: UInt16

    var id: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
    /// Same-LAN (and loopback) sources keep the original unauthenticated UDP behaviour.
    var isLocal: Bool { Self.isLocal(host) }

    init?(fd: Int32, storage: sockaddr_storage, length: socklen_t) {
        var copy = storage
        var bytes = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch Int32(storage.ss_family) {
        case AF_INET:
            let (address, port) = withUnsafePointer(to: &copy) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ($0.pointee.sin_addr, $0.pointee.sin_port) }
            }
            var a = address
            guard inet_ntop(AF_INET, &a, &bytes, socklen_t(bytes.count)) != nil else { return nil }
            self.port = UInt16(bigEndian: port)
        case AF_INET6:
            let (address, port) = withUnsafePointer(to: &copy) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    ($0.pointee.sin6_addr, $0.pointee.sin6_port)
                }
            }
            var a = address
            guard inet_ntop(AF_INET6, &a, &bytes, socklen_t(bytes.count)) != nil else { return nil }
            self.port = UInt16(bigEndian: port)
        default:
            return nil
        }
        self.fd = fd
        self.storage = storage
        self.length = length
        self.host = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Parses a candidate `1.2.3.4:5` or `[2408::1]:5`; picks the socket of the matching family.
    init?(candidate: String, fd4: Int32, fd6: Int32) {
        guard candidate.count <= 64, let colon = candidate.lastIndex(of: ":"),
            let port = UInt16(candidate[candidate.index(after: colon)...]), port > 0
        else { return nil }
        var host = String(candidate[..<colon])
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_socktype = SOCK_DGRAM
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }
        let family = first.pointee.ai_family
        let fd = family == AF_INET6 ? fd6 : fd4
        guard fd >= 0, family == AF_INET || family == AF_INET6 else { return nil }
        var storage = sockaddr_storage()
        let length = first.pointee.ai_addrlen
        withUnsafeMutableBytes(of: &storage) {
            $0.copyMemory(from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(length)))
        }
        self.init(fd: fd, storage: storage, length: length)
        // Link-local candidates carry no usable scope across machines.
        if self.host.lowercased().hasPrefix("fe80") || self.host == "::1" || self.host.hasPrefix("127.")
            || self.host == "0.0.0.0"
        {
            return nil
        }
    }

    func send(_ data: Data) {
        var target = storage
        data.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, data.count, 0, $0, length)
                }
            }
        }
    }

    static func isLocal(_ host: String) -> Bool {
        if host.contains(":") {
            let h = host.lowercased()
            return h == "::1" || h.hasPrefix("fe8") || h.hasPrefix("fe9") || h.hasPrefix("fea") || h.hasPrefix("feb")
                || h.hasPrefix("fc") || h.hasPrefix("fd")
        }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }
        return p[0] == 10 || p[0] == 127 || (p[0] == 172 && (16...31).contains(p[1]))
            || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }

    /// This Mac's own addresses worth offering: private IPv4 (same-LAN shortcut) and global IPv6.
    static func interfaceCandidates(port: UInt16, includeIPv6: Bool) -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var v4: [String] = []
        var v6: [String] = []
        var cursor = list
        while let item = cursor {
            defer { cursor = item.pointee.ifa_next }
            let flags = Int32(item.pointee.ifa_flags)
            let name = String(cString: item.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, !name.hasPrefix("utun"),
                let address = item.pointee.ifa_addr
            else { continue }
            var storage = sockaddr_storage()
            let length = Int(address.pointee.sa_len)
            guard length <= MemoryLayout<sockaddr_storage>.size else { continue }
            withUnsafeMutableBytes(of: &storage) {
                $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: length))
            }
            guard let endpoint = UDPEndpoint(fd: -1, storage: storage, length: socklen_t(length)) else { continue }
            if Int32(address.pointee.sa_family) == AF_INET, isLocal(endpoint.host), !endpoint.host.hasPrefix("169.254")
            {
                v4.append("\(endpoint.host):\(port)")
            } else if includeIPv6, Int32(address.pointee.sa_family) == AF_INET6,
                let first = endpoint.host.first, first == "2" || first == "3"
            {
                v6.append("[\(endpoint.host)]:\(port)")
            }
        }
        return Array(v6.prefix(3)) + Array(v4.prefix(3))
    }
}

/// Minimal RFC 5389 Binding request/response, enough to learn the public IPv4 mapping.
enum STUN {
    static let cookie: UInt32 = 0x2112_A442
    /// Public servers reachable from mainland China first; any one answering is enough.
    static let servers = ["stun.miwifi.com:3478", "stun.chat.bilibili.com:3478", "stun.l.google.com:19302"]

    static func request(transaction: [UInt8]) -> Data {
        var data = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42])
        data.append(contentsOf: transaction.prefix(12))
        return data
    }

    static func isResponse(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 20 && bytes[0] == 0x01 && bytes[1] == 0x01 && Array(bytes[4..<8]) == [0x21, 0x12, 0xA4, 0x42]
    }

    static func transaction(_ bytes: [UInt8]) -> [UInt8] { Array(bytes[8..<20]) }

    /// `host:port` from XOR-MAPPED-ADDRESS (or legacy MAPPED-ADDRESS); IPv4 only.
    static func mappedAddress(_ bytes: [UInt8]) -> String? {
        guard isResponse(bytes) else { return nil }
        var i = 20
        var fallback: String?
        while i + 4 <= bytes.count {
            let type = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            let value = i + 4
            guard value + length <= bytes.count else { break }
            if type == 0x0020 || type == 0x0001, length >= 8, bytes[value + 1] == 0x01 {
                var port = Int(bytes[value + 2]) << 8 | Int(bytes[value + 3])
                var octets = Array(bytes[(value + 4)..<(value + 8)])
                if type == 0x0020 {
                    port ^= 0x2112
                    octets = zip(octets, [0x21, 0x12, 0xA4, 0x42] as [UInt8]).map { $0 ^ $1 }
                }
                let text = "\(octets.map(String.init).joined(separator: ".")):\(port)"
                if type == 0x0020 { return text }
                fallback = text
            }
            i = value + length + (4 - length % 4) % 4
        }
        return fallback
    }

    /// Resolves the servers off the calling queue (DNS blocks).
    static func resolve(_ done: @escaping @Sendable ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: [String] = []
            for server in servers {
                let parts = server.split(separator: ":")
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_DGRAM
                var info: UnsafeMutablePointer<addrinfo>?
                guard getaddrinfo(String(parts[0]), String(parts[1]), &hints, &info) == 0, let first = info else {
                    continue
                }
                defer { freeaddrinfo(info) }
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) {
                    $0.copyMemory(
                        from: UnsafeRawBufferPointer(start: first.pointee.ai_addr, count: Int(first.pointee.ai_addrlen))
                    )
                }
                if let endpoint = UDPEndpoint(fd: -1, storage: storage, length: first.pointee.ai_addrlen) {
                    result.append("\(endpoint.host):\(endpoint.port)")
                }
            }
            done(result)
        }
    }
}
