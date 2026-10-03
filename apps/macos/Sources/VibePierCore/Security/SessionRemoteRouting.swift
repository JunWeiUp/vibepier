import Foundation

/// Transport lifetime and encrypted RPC routing; production resolution is lazy.
/// Tests supply a synthetic router without initializing providers or reading the user's Keychain.
protocol SessionRemoteRouting: Sendable {
    func touch(_ peer: String)
    func disconnected(_ peer: String)
    func receive(_ data: Data, peer: String, sender: String, send: @escaping @Sendable ([Data]) -> Void)
    func requestPair(_ data: Data, peer: String)
    func pairResult(_ peer: String) -> Data
}

extension SessionRemote: SessionRemoteRouting {}
