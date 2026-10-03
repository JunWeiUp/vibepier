import AppKit
import Foundation
import XCTest

@testable import VibePierCore

final class ClaudePromptTests: XCTestCase {
    static func png(width: Int = 32, height: Int = 24) throws -> Data {
        let image = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0))
        image.bitmapData?.initialize(repeating: 255, count: image.bytesPerRow * image.pixelsHigh)
        return try XCTUnwrap(image.representation(using: .png, properties: [:]))
    }

    func testOneStreamingMessageContainsExactTextImagesAndSession() throws {
        let image = try ClaudePrompt.image(Self.png())
        let prompt = try ClaudePrompt(text: "Inspect the selected image", images: [image])
        let input = try XCTUnwrap(prompt.streamInput(session: "native-session"))
        XCTAssertEqual(input.last, 10)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
        XCTAssertEqual(value["type"] as? String, "user")
        XCTAssertEqual(value["session_id"] as? String, "native-session")
        let message = try XCTUnwrap(value["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "user")
        var content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertTrue(prompt.proof.matches(content))
        XCTAssertFalse(
            prompt.proof.matches("Inspect the selected image"), "A text-only receipt cannot prove an image was sent")
        content[0]["text"] = "different"
        XCTAssertFalse(prompt.proof.matches(content))
        XCTAssertLessThan(prompt.proof.retainedBytes, 1024, "Late observers retain hashes, never encoded image bodies")
    }

    func testImageOnlyNativeReceiptRequiresExactFirstHumanContent() throws {
        let prompt = try ClaudePrompt(text: "", images: [ClaudePrompt.image(Self.png())])
        let wire = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(prompt.streamInput(session: "session"))) as? [String: Any])
        let content = try XCTUnwrap((wire["message"] as? [String: Any])?["content"])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("session.jsonl")
        var row: [String: Any] = [
            "type": "user", "uuid": "native-human", "sessionId": "session", "cwd": "/fixture",
            "message": ["content": content],
        ]
        func encode(_ value: [String: Any]) throws -> Data {
            var bytes = try JSONSerialization.data(withJSONObject: value)
            bytes.append(10)
            return bytes
        }
        let correct = try encode(row)
        try correct.write(to: file)
        XCTAssertEqual(
            ClaudeCreationReceipt.read(file, session: "session", cwd: "/fixture", proof: prompt.proof)?[
                "nativeMessageId"] as? String, "native-human")
        XCTAssertNil(ClaudeCreationReceipt.read(file, session: "other-session", cwd: "/fixture", proof: prompt.proof))
        row["message"] = ["content": "different first prompt"]
        try (encode(row) + correct).write(to: file)
        XCTAssertNil(ClaudeCreationReceipt.read(file, session: "session", cwd: "/fixture", proof: prompt.proof))
    }

    func testLargeImageIsBoundedBeforeEncodingAndInvalidInputsAreRejected() throws {
        let image = try ClaudePrompt.image(Self.png(width: 4096, height: 1024))
        XCTAssertEqual(image.mime, "image/jpeg")
        XCTAssertLessThanOrEqual(image.bytes.count, 512 * 1024)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: image.bytes))
        XCTAssertLessThanOrEqual(max(decoded.pixelsWide, decoded.pixelsHigh), 2048)
        let prompt = try ClaudePrompt(text: "", images: Array(repeating: image, count: 6))
        XCTAssertLessThan(try XCTUnwrap(prompt.streamInput(session: "session")).count, 5 * 1024 * 1024)
        XCTAssertThrowsError(try ClaudePrompt(text: "", images: Array(repeating: image, count: 7)))
        XCTAssertThrowsError(try ClaudePrompt.image(Data("not an image".utf8)))
        XCTAssertNil(try ClaudePrompt(text: "text only").streamInput(session: "session"))
    }

    func testPipeInputIsAsynchronousBoundedAndClosesAfterExactBytes() {
        let blocked = Pipe()
        let timeout = expectation(description: "Child that never reads cannot block provider forever")
        ClaudeProcessInput.write(
            Data(repeating: 7, count: 2 * 1024 * 1024), to: blocked.fileHandleForWriting, timeout: 0.05
        ) {
            XCTAssertFalse($0)
            timeout.fulfill()
        }
        let normal = Pipe()
        let written = expectation(description: "Healthy input completes independently")
        let read = expectation(description: "Reader receives exact data and EOF")
        let data = Data(repeating: 3, count: 128 * 1024)
        DispatchQueue.global().async {
            XCTAssertEqual(normal.fileHandleForReading.readDataToEndOfFile(), data)
            try? normal.fileHandleForReading.close()
            read.fulfill()
        }
        ClaudeProcessInput.write(data, to: normal.fileHandleForWriting) {
            XCTAssertTrue($0)
            written.fulfill()
        }
        wait(for: [timeout, written, read], timeout: 3)
        try? blocked.fileHandleForReading.close()
    }

    func testClosedChildPipeDoesNotRaiseSIGPIPEOrReportSuccess() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        let done = expectation(description: "Closed child is a bounded write failure")
        ClaudeProcessInput.write(Data("fixture".utf8), to: pipe.fileHandleForWriting) {
            XCTAssertFalse($0)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
