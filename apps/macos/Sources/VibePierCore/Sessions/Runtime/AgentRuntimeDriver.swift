import Foundation

/// Internal Mac-only API. A driver never accepts arbitrary upstream RPC from a phone.
public protocol AgentRuntimeDriver: AnyObject {
    var adapterID: String { get }
    func describe() -> RuntimeDriverDescriptor
    func discover() throws -> [RuntimeSession]
    func snapshot(_ session: RuntimeSessionReference) throws -> RuntimeSnapshot
    func execute(_ command: RuntimeCommand, context: RuntimeOperationContext) throws -> RuntimeReceipt
    /// Read-only: never submits a command, including after reconnect or process reload.
    func reconcile(_ context: RuntimeOperationContext) throws -> RuntimeReceipt
    func replay(_ session: RuntimeSessionReference, after: RuntimeCursor?) -> RuntimeReplay
    /// Disconnect observation only. Runtime tasks and durable operation records survive.
    func disconnect()
}

public struct RuntimeDriverDescriptor: Codable, Sendable {
    public let adapterID: String
    public let backendKind: String
    public let enabled: Bool
    public let available: Bool
    public let reason: String
    public let capabilities: [String]
    public init(
        adapterID: String, backendKind: String, enabled: Bool, available: Bool,
        reason: String, capabilities: [String]
    ) {
        self.adapterID = adapterID
        self.backendKind = backendKind
        self.enabled = enabled
        self.available = available
        self.reason = reason
        self.capabilities = capabilities
    }
}

public struct RuntimeSessionReference: Codable, Hashable, Sendable {
    public let adapterID: String
    public let instanceID: String
    public let nativeSessionID: String
    public let ownershipEpoch: String
    public init(adapterID: String, instanceID: String, nativeSessionID: String, ownershipEpoch: String) {
        self.adapterID = adapterID
        self.instanceID = instanceID
        self.nativeSessionID = nativeSessionID
        self.ownershipEpoch = ownershipEpoch
    }
}

public struct RuntimeSession: Codable, Sendable {
    public let reference: RuntimeSessionReference
    public let cwd: String
    public let runtimeVersion: String
    public let activeTurnID: String?
    public let writable: Bool
    public init(
        reference: RuntimeSessionReference, cwd: String, runtimeVersion: String,
        activeTurnID: String?, writable: Bool
    ) {
        self.reference = reference
        self.cwd = cwd
        self.runtimeVersion = runtimeVersion
        self.activeTurnID = activeTurnID
        self.writable = writable
    }
}

public enum RuntimeCommand: Codable, Equatable, Sendable {
    case create(cwd: String)
    case submit(text: String)
    /// A composite create must retain its requested mode even if another desktop
    /// client changes the shared runtime before the initial message is dispatched.
    case submitConfigured(text: String, executionMode: String)
    case configureExecutionMode(mode: String)
    case interrupt(turnID: String)
    case resolveApproval(requestID: String, fingerprint: String, decision: String)
    case answerQuestion(requestID: String, fingerprint: String, answers: [String: [String]])
}

/// Construct this only after SessionRemote authorization, lease validation, quota
/// admission and persistent journal reservation. It remains independent of a page.
public struct RuntimeOperationContext: Codable, Sendable {
    public let trustedDeviceID: String
    public let operationID: String
    public let requestFingerprint: String
    public let journalReservationID: String
    public let session: RuntimeSessionReference?
    public init(
        trustedDeviceID: String, operationID: String, requestFingerprint: String,
        journalReservationID: String, session: RuntimeSessionReference?
    ) {
        self.trustedDeviceID = trustedDeviceID
        self.operationID = operationID
        self.requestFingerprint = requestFingerprint
        self.journalReservationID = journalReservationID
        self.session = session
    }
}

public struct RuntimeReceipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case confirmed, unknown, rejected }
    public let operationID: String
    public let status: Status
    public let session: RuntimeSessionReference?
    public let nativeTurnID: String?
    public let nativeMessageID: String?
    public let reason: String
    public let executionMode: String?
    /// Exact native thread/settings/updated evidence, never a synthesized acknowledgement.
    public let nativeSettingsJSON: Data?
    public init(
        operationID: String, status: Status, session: RuntimeSessionReference? = nil,
        nativeTurnID: String? = nil, nativeMessageID: String? = nil, reason: String = "",
        executionMode: String? = nil, nativeSettingsJSON: Data? = nil
    ) {
        self.operationID = operationID
        self.status = status
        self.session = session
        self.nativeTurnID = nativeTurnID
        self.nativeMessageID = nativeMessageID
        self.reason = reason
        self.executionMode = executionMode
        self.nativeSettingsJSON = nativeSettingsJSON
    }
}

public struct RuntimeCursor: Codable, Equatable, Sendable {
    public let epoch: String
    public let sequence: UInt64
    public init(epoch: String, sequence: UInt64) {
        self.epoch = epoch
        self.sequence = sequence
    }
}

public struct RuntimeEvent: Codable, Sendable {
    public let cursor: RuntimeCursor
    public let nativeMethod: String
    public let payload: Data
}

public struct RuntimeReplay: Codable, Sendable {
    public let cursor: RuntimeCursor
    public let events: [RuntimeEvent]
    public let requiresResync: Bool
}

public struct RuntimeSnapshot: Codable, Sendable {
    public let session: RuntimeSession
    public let cursor: RuntimeCursor
    /// Provider-native JSON; the coordinator projects this into the phone protocol.
    public let nativeJSON: Data
    /// No native revision barrier exists on these prototypes; callers merge by IDs.
    public let partial: Bool
}

public enum RuntimeDriverError: Error, Equatable {
    case disabled, incompatibleVersion, invalidRequest, unauthorized, staleOwner
    case unavailable, timeout, quotaExceeded, storageUnavailable, operationConflict
}
