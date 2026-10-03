import XCTest

@testable import VibePierCore

final class ClaudeProcessOutputTests: XCTestCase {
    private let success = Data("{\"type\":\"result\",\"is_error\":false}\n".utf8)
    private func end(_ box: ClaudeProcessOutput) {
        box.append(Data(), error: false)
        box.append(Data(), error: true)
    }

    func testRealPipeReaderDrainsAQuickSyntheticProcessBeforeDetaching() throws {
        let output = Pipe()
        let errors = Pipe()
        let box = ClaudeProcessOutput()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/printf")
        process.arguments = ["%s", "{\"type\":\"result\",\"is_error\":false}"]
        process.standardOutput = output
        process.standardError = errors
        box.startReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
        defer { box.stopReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading) }
        try process.run()
        try? output.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertNil(box.failure(status: process.terminationStatus, interrupted: false))
    }

    func testAbandonedReadersCannotTurnIncompleteOutputIntoSuccess() {
        let output = Pipe()
        let errors = Pipe()
        let box = ClaudeProcessOutput()
        box.append(success, error: false)
        box.stopReading(stdout: output.fileHandleForReading, stderr: errors.fileHandleForReading)
        XCTAssertEqual(
            box.failure(status: 0, interrupted: false, wait: 0), L10n.text("provider.claude_output_unconfirmed"))
    }

    func testChunkedJSONAndFinalRecordWithoutNewlineAreReadCompletely() {
        let box = ClaudeProcessOutput()
        for byte in Data("{\"type\":\"assistant\",\"text\":\"完整\"}\n".utf8) { box.append(Data([byte]), error: false) }
        box.append(success.dropLast(), error: false)
        XCTAssertNotNil(box.failure(status: 0, interrupted: false, wait: 0))
        end(box)
        XCTAssertNil(box.failure(status: 0, interrupted: false, wait: 0))
    }

    func testOversizedUnterminatedOutputIsDrainedWithBoundedMemory() {
        let box = ClaudeProcessOutput(lineLimit: 128)
        for _ in 0..<40 {
            box.append(Data(repeating: 120, count: 8192), error: false)
            XCTAssertLessThanOrEqual(box.bufferedBytes, 128)
        }
        box.append(Data([10]) + success, error: false)
        end(box)
        XCTAssertEqual(box.failure(status: 0, interrupted: false, wait: 0), L10n.text("provider.claude_output_limit"))
    }

    func testStderrAndErrorDetailsStayBoundedWithoutRetainingResultBody() {
        let box = ClaudeProcessOutput()
        box.append(Data(repeating: 120, count: 100_000), error: true)
        let object: [String: Any] = [
            "type": "result", "is_error": true, "result": String(repeating: "failure", count: 20_000),
        ]
        box.append(try! JSONSerialization.data(withJSONObject: object) + Data([10]), error: false)
        end(box)
        XCTAssertLessThanOrEqual(box.bufferedBytes, 4096 + 600)
        XCTAssertTrue(box.failure(status: 0, interrupted: false, wait: 0)?.contains("failure") == true)
    }

    func testCombiningScalarsCannotBypassDiagnosticByteLimit() throws {
        let box = ClaudeProcessOutput()
        let text = "e" + String(repeating: "\u{301}", count: 8000)
        box.append(
            try JSONSerialization.data(withJSONObject: ["type": "result", "is_error": true, "result": text])
                + Data([10]), error: false)
        end(box)
        XCTAssertLessThanOrEqual(box.bufferedBytes, 2400)
        XCTAssertNotNil(box.failure(status: 0, interrupted: false, wait: 0))
    }

    func testMissingMalformedOrConflictingResultsCannotConfirmSuccessfulExit() {
        for bytes in [
            Data(), Data("{\"type\":\"result\",\"is_error\":0}\n".utf8), Data("partial".utf8), success + success,
            Data([255, 10]) + success,
        ] {
            let box = ClaudeProcessOutput()
            if !bytes.isEmpty { box.append(bytes, error: false) }
            end(box)
            XCTAssertEqual(
                box.failure(status: 0, interrupted: false, wait: 0), L10n.text("provider.claude_output_unconfirmed"))
        }
    }

    func testTerminationWaitsForDelayedPipeEndAndRepeatedEOFIsSafe() {
        let box = ClaudeProcessOutput()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) {
            box.append(
                Data("{\"type\":\"result\",\"is_error\":true,\"result\":\"late native failure\"}\n".utf8), error: false)
            box.append(Data(), error: false)
            box.append(Data(), error: false)
            box.append(Data(), error: true)
        }
        XCTAssertTrue(box.failure(status: 0, interrupted: false)?.contains("late native failure") == true)
    }

    func testInterruptedAndNonzeroExitKeepTheirOwnMeaning() {
        let box = ClaudeProcessOutput()
        box.append(Data("synthetic stderr".utf8), error: true)
        end(box)
        XCTAssertEqual(
            box.failure(status: 130, interrupted: false, wait: 0), L10n.text("provider.current_task_stopped"))
        XCTAssertTrue(box.failure(status: 1, interrupted: false, wait: 0)?.contains("synthetic stderr") == true)
    }
}
