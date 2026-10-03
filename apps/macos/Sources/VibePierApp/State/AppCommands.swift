import Foundation
import VibePierCore

/// Compatibility facade for the views; commands now execute within VibePier.
@MainActor
enum AppCommands {
    typealias Result = DriverResult
    static func run(_ arguments: [String]) async -> Result {
        await EmbeddedDriver.shared.run(arguments)
    }
    @discardableResult
    static func runQuiet(_ arguments: [String]) async -> Result {
        let result = await run(arguments)
        if !result.success { lastError = result.stderr.isEmpty ? result.stdout : result.stderr }
        return result
    }
    static var lastError: String?
}
