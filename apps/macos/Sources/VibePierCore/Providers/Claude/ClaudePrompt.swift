import AppKit
import CryptoKit
import Foundation
import ImageIO

/// A bounded first message: images are actual vision blocks, files retain their managed local references.
/// Large images are normalized before encoding so neither stdin nor native receipt reads are unbounded.
struct ClaudePrompt: Sendable {
    struct Image: Sendable {
        let mime: String
        let bytes: Data
    }
    struct Proof: Sendable {
        let text: String
        let images: [String]
        var retainedBytes: Int { text.utf8.count + images.reduce(512) { $0 + $1.utf8.count } }

        func matches(_ content: Any) -> Bool {
            if let plain = content as? String {
                return images.isEmpty && plain.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }
            guard let blocks = content as? [[String: Any]], blocks.count <= 16 else { return false }
            var texts: [String] = []
            var hashes: [String] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    guard let value = block["text"] as? String else { return false }
                    texts.append(value)
                case "image":
                    guard let source = block["source"] as? [String: Any], source["type"] as? String == "base64",
                        let mime = source["media_type"] as? String, let encoded = source["data"] as? String,
                        encoded.utf8.count <= 700_000, let data = Data(base64Encoded: encoded), data.count <= 512 * 1024
                    else { return false }
                    hashes.append(mime + ":" + CodexConversation.dataHash(data))
                default: return false
                }
            }
            return texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) == text
                && hashes == images && (!text.isEmpty || !images.isEmpty)
        }
    }

    let text: String
    let images: [Image]
    var proof: Proof {
        Proof(text: text, images: images.map { $0.mime + ":" + CodexConversation.dataHash($0.bytes) })
    }

    init(text: String, images: [Image] = []) throws {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 128 * 1024, !text.isEmpty || !images.isEmpty, images.count <= 6,
            images.allSatisfy({ !$0.bytes.isEmpty && $0.bytes.count <= 512 * 1024 })
        else { throw CLIError(L10n.text("session.the_first_message_must_not_be_empty_or_exceed_32_kb")) }
        self.text = text
        self.images = images
    }

    /// Text-only requests keep the existing CLI mode. Images use the documented streaming user envelope.
    func streamInput(session: String) throws -> Data? {
        guard !images.isEmpty else { return nil }
        var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        content += images.map {
            [
                "type": "image",
                "source": ["type": "base64", "media_type": $0.mime, "data": $0.bytes.base64EncodedString()],
            ]
        }
        var data = try JSONSerialization.data(
            withJSONObject: [
                "type": "user", "session_id": session, "parent_tool_use_id": NSNull(),
                "message": ["role": "user", "content": content],
            ], options: [.withoutEscapingSlashes])
        guard data.count < 5 * 1024 * 1024 else { throw CLIError(L10n.text("core.invalid_request")) }
        data.append(10)
        return data
    }

    static func image(_ bytes: Data) throws -> Image {
        guard bytes.count <= 10 * 1024 * 1024,
            let source = CGImageSourceCreateWithData(
                bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let type = CGImageSourceGetType(source) as String?,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
            let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
            let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
            width > 0, height > 0, width <= 20_000, height <= 20_000, width * height <= 100_000_000
        else { throw CLIError(L10n.text("session.the_image_format_cannot_be_read")) }
        let native = [
            "public.png": "image/png", "public.jpeg": "image/jpeg", "com.compuserve.gif": "image/gif",
            "org.webmproject.webp": "image/webp",
        ]
        if bytes.count <= 512 * 1024, max(width, height) <= 2048, let mime = native[type] {
            return Image(mime: mime, bytes: bytes)
        }
        for size in [2048, 1536, 1024, 768, 512] {
            guard
                let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: size,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary),
                let canvas = CGContext(
                    data: nil, width: thumbnail.width, height: thumbnail.height, bitsPerComponent: 8,
                    bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { continue }
            let bounds = CGRect(x: 0, y: 0, width: thumbnail.width, height: thumbnail.height)
            canvas.setFillColor(CGColor(gray: 1, alpha: 1))
            canvas.fill(bounds)
            canvas.draw(thumbnail, in: bounds)
            guard let opaque = canvas.makeImage() else { continue }
            for quality in [0.85, 0.65, 0.45] {
                if let data = NSBitmapImageRep(cgImage: opaque).representation(
                    using: .jpeg, properties: [.compressionFactor: quality]),
                    data.count <= 512 * 1024
                {
                    return Image(mime: "image/jpeg", bytes: data)
                }
            }
        }
        throw CLIError(L10n.text("session.the_image_format_cannot_be_read"))
    }
}
