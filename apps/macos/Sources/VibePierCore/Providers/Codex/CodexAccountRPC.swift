import Foundation

protocol CodexAccountRequesting: AnyObject {
    func request(_ method: String, params: [String: Any], mutable: Bool) throws -> [String: Any]
    func close()
}

/// Account-only facade. It cannot create threads or execute model turns.
final class CodexAccountRPC: CodexAccountRequesting {
    private let connection: CodexStdioRPC
    init(executable: URL? = nil) throws {
        connection = try CodexStdioRPC(executable: executable, purpose: .account)
    }
    func request(_ method: String, params: [String: Any], mutable: Bool = false) throws -> [String: Any] {
        try connection.request(method, params: params, mutable: mutable)
    }
    func close() { connection.close() }
}
