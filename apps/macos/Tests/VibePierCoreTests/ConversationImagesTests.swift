import ImageIO
import XCTest

@testable import VibePierCore

final class ConversationImagesTests: XCTestCase {
    private func png() throws -> Data {
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 32, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.3, green: 0.7, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }
    func testMarkdownImageLinksStayDistinctFromCodeAndRemoteLinks() {
        let text = #"""
            ![A](/project/one.png) ![B](<docs/second image.PNG>)
            ![C](docs/a(b).jpg "caption") ![D](docs/a\(b\).jpg)
            ![E](docs/encoded%20name.webp)
            [ordinary](/outside/private.png) ![remote](https://example.com/a.png)
            ![protocol relative](//example.com/a.png) ![svg](docs/script.svg)
            `![inline](/outside/code.png)` \![escaped](/outside/escape.png)
            ```md
            ![fenced](/outside/fence.png)
            ```
            ![F](file:///project/file.png)
            """#
        XCTAssertEqual(
            ConversationReply.localImageReferences(text),
            [
                "/project/one.png", "docs/second image.PNG", "docs/a(b).jpg", "docs/encoded name.webp",
                "/project/file.png",
            ])
    }
    func testConsecutiveProseKeepsEveryPictureUnderTheMergedOwner() throws {
        let rows = CodexConversation.messages([
            "id": "turn",
            "items": [
                ["id": "u", "type": "userMessage", "text": "用户图片 ![photo](docs/photo.png)"],
                ["id": "a", "type": "agentMessage", "text": "方案一 ![first](/outside/one.png)"],
                ["id": "b", "type": "agentMessage", "text": "方案二 ![second](<docs/two picture.png>)"],
                [
                    "id": "g", "type": "imageGeneration", "savedPath": "/outside/generated.png",
                    "result": String(repeating: "BASE64", count: 1000),
                ],
            ],
        ])
        XCTAssertEqual(ConversationReply.image(rows, id: "u#0"), "docs/photo.png")
        XCTAssertEqual(ConversationReply.image(rows, id: "a#0"), "/outside/one.png")
        XCTAssertEqual(ConversationReply.image(rows, id: "a#1"), "docs/two picture.png")
        XCTAssertEqual(ConversationReply.image(rows, id: "g#0"), "/outside/generated.png")
        XCTAssertNil(ConversationReply.image(rows, id: "b#0"))
        let page = ConversationReply.preview(rows)
        let sequence = try XCTUnwrap(page.last?["sequence"] as? [[String: Any]])
        XCTAssertEqual(sequence.first?["images"] as? [[String: String]], [["id": "a#0"], ["id": "a#1"]])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: page), as: UTF8.self)
        XCTAssertFalse(json.contains("BASE64"))
        XCTAssertFalse(json.contains("imageSources"))
    }
    func testMCPAndFunctionOutputImagesUseExistingOpaqueIDsWithoutDumpingBase64() throws {
        let encoded = try png().base64EncodedString()
        let block: [String: Any] = ["type": "image", "mimeType": "image/png", "data": encoded]
        let rows = CodexConversation.messages([
            "id": "t",
            "items": [
                [
                    "id": "m", "type": "mcpToolCall", "server": "images", "tool": "render",
                    "result": ["content": [block]],
                ],
                [
                    "id": "f", "type": "functionCallOutput", "namespace": "functions", "name": "exec",
                    "output": [
                        ["type": "input_text", "text": "two pictures"],
                        ["type": "input_image", "image_url": "data:image/png;base64," + encoded],
                    ],
                ],
            ],
        ])
        XCTAssertEqual(ConversationReply.image(rows, id: "m#0"), "data:image/png;base64," + encoded)
        XCTAssertEqual(ConversationReply.image(rows, id: "f#0"), "data:image/png;base64," + encoded)
        XCTAssertTrue(ConversationReply.fullText(rows, id: "m")?.contains(L10n.text("session.images_0", 1)) == true)
        XCTAssertEqual(ConversationReply.fullText(rows, id: "f"), "two pictures")
        let json = String(
            decoding: try JSONSerialization.data(withJSONObject: ConversationReply.preview(rows)), as: UTF8.self)
        XCTAssertFalse(json.contains(encoded))
    }
    func testSessionSourceReadsExactExternalAndRelativeImagesWithNoNetworkFetch() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = parent.appendingPathComponent("project")
        let external = parent.appendingPathComponent("generated.png")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let bytes = try png()
        try bytes.write(to: external)
        try bytes.write(to: project.appendingPathComponent("inside.png"))
        for source in ["inside.png", external.path, external.absoluteString] {
            let jpeg = try ConversationReply.jpeg(source, cwd: project.path, maxPixel: 480)
            XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
            XCTAssertNotNil(CGImageSourceCreateWithData(jpeg as CFData, nil))
        }
        XCTAssertThrowsError(
            try SessionMarkdownFiles.readReferencedFile(
                external.path, cwd: project.path, referencedPaths: [], maximumBytes: 1024))
        XCTAssertThrowsError(
            try ConversationReply.jpeg("https://example.com/image.png", cwd: project.path, maxPixel: 480))
        XCTAssertThrowsError(
            try ConversationReply.jpeg("file://example.com/image.png", cwd: project.path, maxPixel: 480))
        XCTAssertThrowsError(try ConversationReply.jpeg("missing.png", cwd: project.path, maxPixel: 480))
    }
    func testClaudeServesReferencedExternalImageOnlyForTheOpenSessionAndOpaqueID() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        let sessions = root.appendingPathComponent("sessions/project")
        let external = root.appendingPathComponent("generated.png")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try png().write(to: external)
        let first = UUID().uuidString
        let second = UUID().uuidString
        for (thread, text) in [(first, "![方案](\(external.path))"), (second, "没有图片")] {
            let entries: [[String: Any]] = [
                ["type": "user", "uuid": "u", "cwd": project.path, "message": ["content": "hello"]],
                [
                    "type": "assistant", "uuid": "a", "cwd": project.path,
                    "message": ["content": [["type": "text", "text": text]]],
                ],
            ]
            var bytes = Data()
            for entry in entries {
                bytes.append(try JSONSerialization.data(withJSONObject: entry))
                bytes.append(10)
            }
            try bytes.write(to: sessions.appendingPathComponent(thread + ".jsonl"))
        }
        let bridge = ClaudeBridge(root: root.appendingPathComponent("sessions"))
        defer { bridge.stopAll() }
        final class Reply: @unchecked Sendable {
            let lock = NSLock()
            var data = Data()
        }
        func request(_ params: [String: Any]) throws -> [String: Any] {
            let reply = Reply()
            let complete = expectation(description: "image bridge")
            bridge.perform(try JSONSerialization.data(withJSONObject: params), client: "image-phone") { data in
                reply.lock.withLock { reply.data = data }
                complete.fulfill()
            }
            wait(for: [complete], timeout: 3)
            return try XCTUnwrap(
                JSONSerialization.jsonObject(with: reply.lock.withLock { reply.data }) as? [String: Any])
        }
        let imageRequest: [String: Any] = [
            "op": "image", "threadId": first, "viewVersion": 1, "imageId": "a-0#0", "path": "/ignored.png", "cwd": "/",
        ]
        XCTAssertEqual(try request(imageRequest)["ok"] as? Bool, false)
        _ = try request(["op": "open", "threadId": first, "viewVersion": 1])
        let result = try request(imageRequest)
        let jpeg = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(result["image"] as? String)))
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xff, 0xd8])
        var invalid = imageRequest
        invalid["imageId"] = external.path
        XCTAssertEqual(try request(invalid)["ok"] as? Bool, false, "a caller path cannot replace an image ID")
        _ = try request(["op": "open", "threadId": second, "viewVersion": 2])
        var other = imageRequest
        other["threadId"] = second
        other["viewVersion"] = 2
        XCTAssertEqual(try request(other)["ok"] as? Bool, false, "an image ID never carries into another session")
        XCTAssertEqual(try request(imageRequest)["ok"] as? Bool, false)
    }
    func testAllThreeRealNativeDesignImagesProjectAndEncodeWhenSnapshotIsProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["VIBEPIER_IMAGE_SNAPSHOT"] else {
            throw XCTSkip("Real desktop image snapshot probe is opt-in")
        }
        let state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let expected = Set([
            "exec-01382031-65ad-44cd-99d1-e9d48844eb15", "exec-71185174-80ef-45bc-ad78-3ca766599a8c",
            "exec-27e3cb14-ec75-499e-a47a-84bb5d8844b4",
        ])
        let rows = CodexConversation.turns(state).flatMap(CodexConversation.messages)
        let native = CodexConversation.turns(state).flatMap { $0["items"] as? [[String: Any]] ?? [] }.filter {
            expected.contains($0["id"] as? String ?? "")
        }
        XCTAssertEqual(native.count, 3)
        for item in native {
            let id = try XCTUnwrap(item["id"] as? String)
            let source = try XCTUnwrap(ConversationReply.image(rows, id: id + "#0"))
            XCTAssertEqual(source, item["savedPath"] as? String)
            let part = try XCTUnwrap(ConversationReply.partDetails(rows, id: id))
            XCTAssertEqual(part["images"] as? [[String: String]], [["id": id + "#0"]])
            for size in [480, 1280] {
                let jpeg = try ConversationReply.jpeg(
                    source, cwd: try XCTUnwrap(state["cwd"] as? String), maxPixel: size)
                XCTAssertFalse(jpeg.isEmpty)
                XCTAssertLessThanOrEqual(jpeg.count, 240_000)
                let image = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
                XCTAssertLessThanOrEqual(
                    max(
                        properties[kCGImagePropertyPixelWidth as String] as? Int ?? 0,
                        properties[kCGImagePropertyPixelHeight as String] as? Int ?? 0), size)
                print("Native design image \(id) JPEG \(size): \(jpeg.count) bytes")
            }
        }
    }
}
