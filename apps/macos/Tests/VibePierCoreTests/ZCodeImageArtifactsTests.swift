import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import VibePierCore

final class ZCodeImageArtifactsTests: XCTestCase {
    private let session = "sess_fixture"
    private let artifact = "tool-result-12345678-1234-1234-1234-123456789abc"
    private var source: String { "zcode-artifact://\(session)/\(artifact)" }

    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent(session)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root, folder)
    }

    private func dataURL() throws -> String {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return "data:image/png;base64," + (bytes as Data).base64EncodedString()
    }

    private func read(_ root: URL, source: String? = nil, maxPixel: Int = 480) throws -> Data {
        try ZCodeImageArtifacts.jpeg(
            source ?? self.source, session: session, root: root.path, maxPixel: maxPixel, maximumBytes: 200_000)
    }

    func testNativeAttachmentDataURLSupportsThumbnailAndLargePreview() throws {
        try fixture { root, folder in
            try dataURL().write(
                to: folder.appendingPathComponent("prompt-attachment-upload-opaque-\(artifact).txt"),
                atomically: true, encoding: .utf8)
            for maxPixel in [480, 2048] {
                XCTAssertEqual(Array(try read(root, maxPixel: maxPixel).prefix(2)), [0xff, 0xd8])
            }
            let part: [String: Any] = ["type": "file", "mime": "image/jpeg", "url": source]
            XCTAssertEqual(ZCodeConversation.imageSources(part), [source])
            XCTAssertEqual(
                ZCodeConversation.imageSources([
                    "type": "file", "mime": "image/jpeg", "url": "unavailable",
                    "metadata": ["artifactUri": source],
                ]), [source])
        }
    }

    func testRejectsOtherSessionMalformedURIAndTraversal() throws {
        try fixture { root, folder in
            try dataURL().write(to: folder.appendingPathComponent(artifact + ".txt"), atomically: true, encoding: .utf8)
            for invalid in [
                "zcode-artifact://sess_other/\(artifact)", source + "?path=elsewhere", source + "#fragment",
                "zcode-artifact://\(session)/../\(artifact)", "zcode-artifact://\(session)/%2e%2e/\(artifact)",
                "zcode-artifact://user@\(session)/\(artifact)", "zcode-artifact://\(session):80/\(artifact)",
                "zcode-artifact://\(session)/tool-result-not-a-uuid",
            ] { XCTAssertThrowsError(try read(root, source: invalid)) }
        }
    }

    func testRejectsMissingAmbiguousAndNonImageArtifacts() throws {
        try fixture { root, folder in
            XCTAssertThrowsError(try read(root))
            let first = folder.appendingPathComponent("one-\(artifact).txt")
            try "ordinary tool output".write(to: first, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try read(root))
            try dataURL().write(to: first, atomically: true, encoding: .utf8)
            try dataURL().write(
                to: folder.appendingPathComponent("two-\(artifact).txt"), atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try read(root))
        }
    }

    func testRejectsArtifactAndSessionSymlinks() throws {
        try fixture { root, folder in
            let other = root.appendingPathComponent("sess_other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let file = other.appendingPathComponent(artifact + ".txt")
            try dataURL().write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(
                at: folder.appendingPathComponent(artifact + ".txt"), withDestinationURL: file)
            XCTAssertThrowsError(try read(root))
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: other)
            XCTAssertThrowsError(try read(root))
        }
    }
}
