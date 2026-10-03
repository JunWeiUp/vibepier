// SPDX-License-Identifier: MIT
//
// TEA (Tiny Encryption Algorithm) as used by the Ulanzi / Kehwin HID protocol.
//
// Every 64-byte message on the vendor HID interface (usage page 0xFFFC) is
// encrypted with standard 32-round TEA in ECB mode, 8 bytes at a time, with
// both 32-bit halves read little-endian. The key is a constant compiled into
// the vendor library (`gaui_custom_encrypt_keys` in kwdm.dylib).

public enum TEA {
    /// Key recovered from kwdm.dylib at vmaddr 0x4a580.
    public static let key: [UInt32] = [0xCAA5_BACA, 0xBC2A_8A6D, 0xCA5A_9EBA, 0x9BB8_8BCA]

    static let delta: UInt32 = 0x9E37_79B9
    static let rounds = 32

    /// Encrypts one 8-byte block in place.
    public static func encryptBlock(_ v0: inout UInt32, _ v1: inout UInt32, key k: [UInt32] = key) {
        var sum: UInt32 = 0
        for _ in 0..<rounds {
            sum &+= delta
            v0 &+= ((v1 << 4) &+ k[0]) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k[1])
            v1 &+= ((v0 << 4) &+ k[2]) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k[3])
        }
    }

    /// Decrypts one 8-byte block in place.
    public static func decryptBlock(_ v0: inout UInt32, _ v1: inout UInt32, key k: [UInt32] = key) {
        var sum: UInt32 = delta &* UInt32(rounds)
        for _ in 0..<rounds {
            v1 &-= ((v0 << 4) &+ k[2]) ^ (v0 &+ sum) ^ ((v0 >> 5) &+ k[3])
            v0 &-= ((v1 << 4) &+ k[0]) ^ (v1 &+ sum) ^ ((v1 >> 5) &+ k[1])
            sum &-= delta
        }
    }

    /// Encrypts every complete 8-byte block. A trailing partial block is left as is,
    /// which matches `encrypt_data` in the vendor library.
    public static func encrypt(_ bytes: [UInt8]) -> [UInt8] {
        transform(bytes, encrypt: true)
    }

    /// Decrypts every complete 8-byte block. A trailing partial block is left as is.
    public static func decrypt(_ bytes: [UInt8]) -> [UInt8] {
        transform(bytes, encrypt: false)
    }

    private static func transform(_ bytes: [UInt8], encrypt: Bool) -> [UInt8] {
        var out = bytes
        var offset = 0
        while offset + 8 <= out.count {
            var v0 = readLE32(out, offset)
            var v1 = readLE32(out, offset + 4)
            if encrypt {
                encryptBlock(&v0, &v1)
            } else {
                decryptBlock(&v0, &v1)
            }
            writeLE32(&out, offset, v0)
            writeLE32(&out, offset + 4, v1)
            offset += 8
        }
        return out
    }
}

@inline(__always)
func readLE32(_ b: [UInt8], _ i: Int) -> UInt32 {
    UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
}

@inline(__always)
func readLE16(_ b: [UInt8], _ i: Int) -> UInt16 {
    UInt16(b[i]) | UInt16(b[i + 1]) << 8
}

@inline(__always)
func writeLE32(_ b: inout [UInt8], _ i: Int, _ v: UInt32) {
    b[i] = UInt8(truncatingIfNeeded: v)
    b[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
    b[i + 2] = UInt8(truncatingIfNeeded: v >> 16)
    b[i + 3] = UInt8(truncatingIfNeeded: v >> 24)
}

@inline(__always)
func writeLE16(_ b: inout [UInt8], _ i: Int, _ v: UInt16) {
    b[i] = UInt8(truncatingIfNeeded: v)
    b[i + 1] = UInt8(truncatingIfNeeded: v >> 8)
}
