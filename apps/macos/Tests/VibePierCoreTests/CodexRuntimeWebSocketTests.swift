import XCTest

@testable import VibePierCore

final class CodexRuntimeWebSocketTests: XCTestCase {
    private func serverFrame(_ payload: Data, opcode: UInt8 = 1, final: Bool = true) -> Data {
        var frame = Data([(final ? 0x80 : 0) | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 65_535 {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 255))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((UInt64(payload.count) >> shift) & 255))
            }
        }
        frame.append(payload)
        return frame
    }

    private func upgrade(_ accept: String, extra: String = "") -> Data {
        Data(
            ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                + "Sec-WebSocket-Accept: " + accept + "\r\n" + extra + "\r\n").utf8)
    }

    func testRFCHandshakeChecksAcceptAndPreservesFirstFrameRemainder() throws {
        let handshake = try CodexRuntimeWebSocket.handshake(key: "dGhlIHNhbXBsZSBub25jZQ==")
        XCTAssertEqual(handshake.accept, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
        let frame = serverFrame(Data("{\"id\":1}".utf8))
        let response = upgrade(handshake.accept) + frame
        XCTAssertNil(try CodexRuntimeWebSocket.validateHandshake(Data(response.prefix(30)), accept: handshake.accept))
        XCTAssertEqual(try CodexRuntimeWebSocket.validateHandshake(response, accept: handshake.accept), frame)
        XCTAssertThrowsError(try CodexRuntimeWebSocket.validateHandshake(response, accept: "wrong"))
        XCTAssertThrowsError(
            try CodexRuntimeWebSocket.validateHandshake(
                upgrade(handshake.accept, extra: "Sec-WebSocket-Accept: " + handshake.accept + "\r\n"),
                accept: handshake.accept))
        XCTAssertThrowsError(
            try CodexRuntimeWebSocket.validateHandshake(
                upgrade(handshake.accept, extra: "Sec-WebSocket-Extensions: permessage-deflate\r\n"),
                accept: handshake.accept))
        XCTAssertThrowsError(
            try CodexRuntimeWebSocket.validateHandshake(Data(repeating: 65, count: 8193), accept: handshake.accept))
    }

    func testClientFramesAreMaskedWithCorrectLengthsAndPongOpcode() throws {
        let mask = Data([1, 2, 3, 4])
        for size in [0, 1, 125, 126, 65_535, 65_536, 300_000] {
            let payload = Data(repeating: 0x61, count: size)
            let frame = try CodexRuntimeWebSocket.frame(payload, mask: mask)
            XCTAssertEqual(frame[0], 0x81)
            XCTAssertNotEqual(frame[1] & 0x80, 0)
            let offset = size < 126 ? 2 : size <= 65_535 ? 4 : 10
            XCTAssertEqual(Data(frame.dropFirst(offset).prefix(4)), mask)
            let clear = frame.dropFirst(offset + 4).enumerated().map { $0.element ^ mask[$0.offset % 4] }
            XCTAssertEqual(Data(clear), payload)
        }
        XCTAssertEqual(try CodexRuntimeWebSocket.frame(Data("ping".utf8), opcode: 10, mask: mask)[0], 0x8a)
        XCTAssertThrowsError(try CodexRuntimeWebSocket.frame(Data(repeating: 0, count: 300_001)))
        XCTAssertThrowsError(try CodexRuntimeWebSocket.frame(Data(repeating: 0, count: 126), opcode: 10))
    }

    func testFragmentedUTF8SurvivesPingAndSplitPipeReads() throws {
        var decoder = CodexRuntimeWebSocket.Decoder()
        let wire =
            serverFrame(Data([0xc3]), final: false)
            + serverFrame(Data("ping".utf8), opcode: 9)
            + serverFrame(Data([0xa9]), opcode: 0)
        var events: [CodexRuntimeWebSocket.Incoming] = []
        for byte in wire { events.append(contentsOf: try decoder.append(Data([byte]))) }
        XCTAssertEqual(events.count, 2)
        guard case .ping(let ping) = events[0], case .text(let text) = events[1] else {
            return XCTFail("Expected an interleaved ping followed by one complete text message")
        }
        XCTAssertEqual(ping, Data("ping".utf8))
        XCTAssertEqual(String(data: text, encoding: .utf8), "é")
    }

    func testDecoderRejectsMaskedBinaryReservedAndInvalidControlFrames() throws {
        let malformed: [Data] = [
            try CodexRuntimeWebSocket.frame(Data("client".utf8)),
            serverFrame(Data("binary".utf8), opcode: 2),
            Data([0xc1, 0]),
            serverFrame(Data([1]), opcode: 9, final: false),
            serverFrame(Data([1]), opcode: 8),
            serverFrame(Data([0xff])),
            serverFrame(Data([0x03, 0xed]), opcode: 8),
            Data([0x81, 126, 0, 1, 65]),
            Data([0x81, 127, 0, 0, 0, 0, 0, 0x20, 0, 1]),
        ]
        for wire in malformed {
            var decoder = CodexRuntimeWebSocket.Decoder()
            XCTAssertThrowsError(try decoder.append(wire))
        }
    }

    func testDecoderRejectsContinuationMisuseAndOversizedAggregate() throws {
        var orphan = CodexRuntimeWebSocket.Decoder()
        XCTAssertThrowsError(try orphan.append(serverFrame(Data("x".utf8), opcode: 0)))
        var overlap = CodexRuntimeWebSocket.Decoder()
        _ = try overlap.append(serverFrame(Data("first".utf8), final: false))
        XCTAssertThrowsError(try overlap.append(serverFrame(Data("second".utf8))))
        var large = CodexRuntimeWebSocket.Decoder()
        _ = try large.append(
            serverFrame(Data(repeating: 65, count: CodexRuntimeWebSocket.maximumTextBytes), final: false))
        XCTAssertThrowsError(try large.append(serverFrame(Data([65]), opcode: 0)))
    }

    func testPongIsIgnoredAndValidCloseStopsFurtherMessages() throws {
        var decoder = CodexRuntimeWebSocket.Decoder()
        let events = try decoder.append(
            serverFrame(Data("pong".utf8), opcode: 10) + serverFrame(Data([0x03, 0xe8]), opcode: 8)
                + serverFrame(Data("late".utf8)))
        XCTAssertEqual(events.count, 1)
        guard case .close = events[0] else { return XCTFail("Expected close") }
    }
}
