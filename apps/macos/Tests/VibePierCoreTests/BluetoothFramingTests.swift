import XCTest

@testable import VibePierCore

final class BluetoothFramingTests: XCTestCase {
    func testFragmentedUTF8AndMultipleCommands() {
        var buffer = RemoteLineBuffer()
        let bytes = Array("当前应用\nvibepier1 phone 1 talk down rcmd\n".utf8)
        var lines: [String] = []
        for byte in bytes { lines += buffer.append(Data([byte])) }
        XCTAssertEqual(lines, ["当前应用", "vibepier1 phone 1 talk down rcmd"])
        XCTAssertEqual(buffer.append(Data("a\nb\npartial".utf8)), ["a", "b"])
        XCTAssertEqual(buffer.append(Data("-end\n".utf8)), ["partial-end"])
    }
    func testOversizedFragmentIsDiscardedAndNextFrameRecovers() {
        var buffer = RemoteLineBuffer()
        XCTAssertTrue(buffer.append(Data(repeating: 65, count: 16385)).isEmpty)
        XCTAssertEqual(buffer.append(Data("hello\n".utf8)), ["hello"])
    }
}
