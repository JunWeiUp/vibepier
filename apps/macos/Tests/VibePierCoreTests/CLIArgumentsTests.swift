import XCTest

@testable import VibePierCore

final class CLIArgumentsTests: XCTestCase {
    func testDurationSuffixesRejectOverflowWithoutTrapping() throws {
        XCTAssertEqual(try parseDuration("1193046h"), 4_294_965_600)
        XCTAssertEqual(try parseDuration("71582788m"), 4_294_967_280)
        XCTAssertEqual(try parseDuration("4294967295s"), UInt32.max)
        XCTAssertEqual(try parseDuration("0xFFFFFFFF"), UInt32.max)
        for value in ["1193047h", "71582789m", "4294967295h", "4294967295m", "4294967296s", "-1h"] {
            XCTAssertThrowsError(try parseDuration(value), value)
        }
        XCTAssertEqual(try parseDuration("off"), 0)
        XCTAssertEqual(try parseDuration("never"), 0)
        XCTAssertEqual(try parseDuration("2H"), 7200)
    }

    func testDelaysRejectNonFiniteNegativeAndOverflowingInput() throws {
        for unit in [1_000_000.0, 1_000_000_000.0] {
            for value in ["-1", "nan", "NaN", "inf", "-inf", "1e999", "1e30", "invalid", ""] {
                XCTAssertThrowsError(
                    try parseDelayNanoseconds(value, nanosecondsPerUnit: unit, option: "--delay"), value)
            }
            XCTAssertThrowsError(
                try parseDelayNanoseconds(
                    String(Double(UInt64.max) / unit), nanosecondsPerUnit: unit, option: "--delay"))
        }
    }

    func testDelaysPreserveFractionalUnitsAndAllowZero() throws {
        XCTAssertEqual(
            try parseDelayNanoseconds("1.5", nanosecondsPerUnit: 1_000_000_000, option: "--seconds"), 1_500_000_000)
        XCTAssertEqual(try parseDelayNanoseconds("500", nanosecondsPerUnit: 1_000_000, option: "--wait"), 500_000_000)
        XCTAssertEqual(try parseDelayNanoseconds("0", nanosecondsPerUnit: 1_000_000, option: "--wait"), 0)
    }
}
