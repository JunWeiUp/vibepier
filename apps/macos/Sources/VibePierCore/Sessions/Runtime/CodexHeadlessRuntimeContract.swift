import Foundation

/// Packaged CLI 0.160.0 was reviewed independently for the local background
/// provider. Its common schema bytes match 0.159.0; this does not widen the
/// separately configured managed runtime's version allowlist.
enum CodexHeadlessRuntimeContract {
    static let version = "0.160.0"
    private static let additionalSchemaHashes: [String: String] = [
        "v2/ThreadResumeParams.json": "c818e26d830ac4430791eab7d4a872d2384fa6006b14c505d8caf46e7e093527",
        "v2/ThreadResumeResponse.json": "e7751c8dba039fa5f55971307e89e8b8541f2853840650ea8968bad8c23698d6",
        "v2/TurnSteerParams.json": "857e7a2b061ae46ed6aedea6a5fddd3a6ce14f0334bf7eafaf10d4cbe68ec78b",
        "v2/TurnSteerResponse.json": "866ba9a77c12b5d570c837d58f73bf40b24e50fa93404bdf792dd984d313b1aa",
        "v2/ThreadSetNameParams.json": "8e334c816bbaeb80f807aca61bf659246f3f60c245c21b5cb7e3ca4ee3ce4820",
        "v2/ThreadSetNameResponse.json": "f8763716433feea94f7c1ebd59b6cea4c261432e83240c13a8d49ba8185aa567",
        "v2/ThreadArchiveParams.json": "dc2c0b133b814a5d9d543cc37afdb3f4f22feca35b7cea4272834b20a1e47705",
        "v2/ThreadArchiveResponse.json": "2e021dabd0930ae3e2beb68cd0ddbafc40fc20cfbf8dbcb5e2f9c0493d06a08c",
        "v2/ThreadUnarchiveParams.json": "a1d5d847b61ea16ab09d5b9d1c1461134a7829292aae02a7e11b0a69b00c76ca",
        "v2/ThreadUnarchiveResponse.json": "5f6b192c7161aa22831ec1a08d25b286c948a1f6078a9f7efeb371b38b0dabc8",
        "PermissionsRequestApprovalParams.json": "c11fbe632472ab0923aba5c0a53da3d6d86929bcd5c78e7c13c51c6b2db508ff",
        "PermissionsRequestApprovalResponse.json": "23f3f24e9dbf35db3e0b85703f0d934da5a1cff3cbb611fba8bcd41f3b4a04b0",
        "v2/ItemStartedNotification.json": "7574788d2a352747f50d44be3ef649011cb8de8069da4c655faff14d0aee32c4",
        "v2/ItemCompletedNotification.json": "d04b9153de38cd8302a2a418a44a65e8265d4c7586d46ea2cc801b594c6acf5b",
        "v2/TurnCompletedNotification.json": "016870158603b0f84bd9f8f65f927161c9fd5128e5ec632087616462dc44e085",
        "v2/ThreadStartedNotification.json": "db5cd48a1d33b787585e131f04f720300a929dc1dd2f978124e739ebaafffc8b",
        "v2/ThreadStatusChangedNotification.json": "26f3c60c1b73f7fa2d31c74429cdc36f8746c76c33e3d314b3fb61d3661f05f6",
        "v2/ServerRequestResolvedNotification.json": "4f03d586a5af04edd912cad08cc97eceb658e7e06744565e6d41a93e04a55966",
    ]
    private static let additionalExperimentalSchemaHashes: [String: String] = [
        "v2/ThreadStartParams.json": "80a40a7fac15b4bf70efb7f893fb353acc0a0d30c68f54aee4f01923deca85de",
        "v2/ThreadResumeParams.json": "cc5bb3b25f82073d24af5b6c09e4804ac307467f8400ba5f263fa86f9f0349e6",
        "v2/ThreadResumeResponse.json": "d841a3fc57d72033f21bad4816a1a1fbf52c912d23d0881f5de7fcf86c1f9a6e",
        "v2/TurnSteerParams.json": "99f7fdff8b090065b68f36420b70870b5eafed048c024b308230aaa02f15d891",
        "v2/ThreadUnarchiveResponse.json": "30a1689cd85e53a4dace230faf17c6a47114a8ebba10307400fec4d006169c4d",
        "CommandExecutionRequestApprovalParams.json":
            "c9728280b8f3204fd729d0fb3d1ca7bb05b1150de26b3653f7163e6a9bd941e7",
    ]
    static func validateSchemaDirectory(_ directory: URL, runtimeVersion: String) throws {
        guard runtimeVersion == version else { throw RuntimeDriverError.incompatibleVersion }
        try validate(
            directory,
            hashes: CodexManagedRuntimeContract.schemaHashes.merging(additionalSchemaHashes) {
                _, reviewed in reviewed
            })
    }
    static func validateExecutionModeSchemaDirectory(_ directory: URL, runtimeVersion: String) throws {
        guard runtimeVersion == version else { throw RuntimeDriverError.incompatibleVersion }
        try validate(
            directory,
            hashes: CodexManagedRuntimeContract.executionModeSchemaHashes.merging(additionalExperimentalSchemaHashes) {
                _, reviewed in reviewed
            })
    }
    private static func validate(_ directory: URL, hashes: [String: String]) throws {
        for (path, hash) in hashes {
            let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(path))
            defer { try? file.close() }
            let bytes = try file.read(upToCount: 2_097_153) ?? Data()
            guard bytes.count <= 2_097_152, RuntimeOperationLedger.hash(bytes) == hash else {
                throw RuntimeDriverError.incompatibleVersion
            }
        }
    }
}
