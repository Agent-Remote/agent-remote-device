import DeviceProtocol
import DeviceSecurity
import Foundation

public struct DeviceSessionBinding: Codable, Equatable, Sendable {
    public let userID: UUID
    public let deviceID: UUID
    public let toolSessionID: UUID
    public let deviceSessionID: UUID
    public let nodeID: UUID
    public let platform: Platform
    public let generation: UInt64

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case toolSessionID = "tool_session_id"
        case deviceSessionID = "device_session_id"
        case nodeID = "node_id"
        case platform, generation
    }

    public init(
        userID: UUID,
        deviceID: UUID,
        toolSessionID: UUID,
        deviceSessionID: UUID,
        nodeID: UUID,
        platform: Platform,
        generation: UInt64
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.toolSessionID = toolSessionID
        self.deviceSessionID = deviceSessionID
        self.nodeID = nodeID
        self.platform = platform
        self.generation = generation
    }

    public func matches(_ context: RequestContext) -> Bool {
        userID == context.userID
            && deviceID == context.deviceID
            && toolSessionID == context.toolSessionID
            && deviceSessionID == context.deviceSessionID
            && nodeID == context.nodeID
            && platform == context.platform
            && generation == context.generation
    }
}

public struct BrokerPendingSession: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding
    public let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case binding
        case expiresAt = "expires_at"
    }

    public init(binding: DeviceSessionBinding, expiresAt: Date) {
        self.binding = binding
        self.expiresAt = expiresAt
    }

    public func validate(now: Date = Date()) throws {
        guard binding.hasActiveGeneration,
              binding.platform == .macos,
              expiresAt > now
        else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

public enum BrokerRemoteSessionStatus: String, Codable, Sendable {
    case running
    case active
    case detached
}

public struct BrokerSessionCandidate: Codable, Equatable, Sendable {
    public let toolSessionID: UUID
    public let toolType: String
    public let toolAccountID: UUID
    public let workspaceID: UUID
    public let projectKey: String
    public let displayName: String
    public let status: BrokerRemoteSessionStatus
    public let nodeID: UUID
    public let runtimeBackend: String
    public let currentDeviceID: UUID?
    public let currentDeviceName: String?
    public let deviceSessionID: UUID?
    public let controllable: Bool

    enum CodingKeys: String, CodingKey {
        case toolSessionID = "tool_session_id"
        case toolType = "tool_type"
        case toolAccountID = "tool_account_id"
        case workspaceID = "workspace_id"
        case projectKey = "project_key"
        case displayName = "display_name"
        case status
        case nodeID = "node_id"
        case runtimeBackend = "runtime_backend"
        case currentDeviceID = "current_device_id"
        case currentDeviceName = "current_device_name"
        case deviceSessionID = "device_session_id"
        case controllable
    }

    public init(
        toolSessionID: UUID,
        toolType: String,
        toolAccountID: UUID,
        workspaceID: UUID,
        projectKey: String,
        displayName: String,
        status: BrokerRemoteSessionStatus,
        nodeID: UUID,
        runtimeBackend: String,
        currentDeviceID: UUID?,
        currentDeviceName: String?,
        deviceSessionID: UUID?,
        controllable: Bool
    ) {
        self.toolSessionID = toolSessionID
        self.toolType = toolType
        self.toolAccountID = toolAccountID
        self.workspaceID = workspaceID
        self.projectKey = projectKey
        self.displayName = displayName
        self.status = status
        self.nodeID = nodeID
        self.runtimeBackend = runtimeBackend
        self.currentDeviceID = currentDeviceID
        self.currentDeviceName = currentDeviceName
        self.deviceSessionID = deviceSessionID
        self.controllable = controllable
    }

    public func validate() throws {
        guard toolType == "claude",
              !projectKey.isEmpty,
              projectKey.utf8.count <= 256,
              !displayName.isEmpty,
              displayName.utf8.count <= 256,
              !runtimeBackend.isEmpty,
              runtimeBackend.utf8.count <= 64,
              controllable
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        if let currentDeviceName {
            guard !currentDeviceName.isEmpty, currentDeviceName.utf8.count <= 128 else {
                throw DeviceIPCFailure.invalidMessage
            }
        }
    }
}

public struct BrokerSessionCandidateList: Codable, Equatable, Sendable {
    public let items: [BrokerSessionCandidate]

    public init(items: [BrokerSessionCandidate]) {
        self.items = items
    }

    public func validate() throws {
        guard items.count <= 32 else { throw DeviceIPCFailure.invalidMessage }
        for item in items {
            try item.validate()
        }
    }
}

public struct BrokerClaimRequest: Codable, Equatable, Sendable {
    public let toolSessionID: UUID

    enum CodingKeys: String, CodingKey {
        case toolSessionID = "tool_session_id"
    }

    public init(toolSessionID: UUID) {
        self.toolSessionID = toolSessionID
    }

    public func validate() throws {
        guard toolSessionID != UUID() else { throw DeviceIPCFailure.invalidMessage }
    }
}

public enum BrokerApprovalResult: String, Codable, Sendable {
    case allowed
    case denied
}

public struct BrokerApprovalDecision: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding
    public let approvals: [LocalApproval]
    public let result: BrokerApprovalResult

    public init(
        binding: DeviceSessionBinding,
        approvals: [LocalApproval],
        result: BrokerApprovalResult
    ) {
        self.binding = binding
        self.approvals = approvals
        self.result = result
    }

    public func validate() throws {
        guard binding.hasActiveGeneration,
              binding.platform == .macos,
              !approvals.isEmpty,
              approvals.count <= 32,
              approvals.allSatisfy({ $0.generation == binding.generation }),
              Set(approvals.map(\.application.stableDigest)).count == approvals.count
        else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

public enum BrokerAbortReason: String, Codable, Sendable {
    case escape = "esc"
    case localStop = "local_stop"
    case disconnect
}

public struct BrokerAbortRequest: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding
    public let reason: BrokerAbortReason

    public init(binding: DeviceSessionBinding, reason: BrokerAbortReason) {
        self.binding = binding
        self.reason = reason
    }

    public func validate() throws {
        guard binding.hasActiveGeneration, binding.platform == .macos else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

public struct BrokerEndRequest: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding

    public init(binding: DeviceSessionBinding) {
        self.binding = binding
    }

    public func validate() throws {
        guard binding.hasActiveGeneration, binding.platform == .macos else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

public enum BrokerRuntimeEventKind: String, Codable, Sendable {
    case turnStarted = "turn_started"
    case turnStopped = "turn_stopped"
    case sessionEnded = "session_ended"
}

public struct BrokerRuntimeEvent: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding
    public let kind: BrokerRuntimeEventKind

    public init(binding: DeviceSessionBinding, kind: BrokerRuntimeEventKind) {
        self.binding = binding
        self.kind = kind
    }

    public func validate() throws {
        guard binding.hasActiveGeneration, binding.platform == .macos else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

public struct ExecutorSessionConfiguration: Codable, Equatable, Sendable {
    public let binding: DeviceSessionBinding
    public let leaseUntil: Date
    public let approvals: [LocalApproval]

    enum CodingKeys: String, CodingKey {
        case binding
        case leaseUntil = "lease_until"
        case approvals
    }

    public init(
        binding: DeviceSessionBinding,
        leaseUntil: Date,
        approvals: [LocalApproval]
    ) {
        self.binding = binding
        self.leaseUntil = leaseUntil
        self.approvals = approvals
    }

    public func validate(now: Date = Date()) throws {
        guard binding.hasActiveGeneration,
              leaseUntil > now,
              !approvals.isEmpty,
              approvals.count <= 32,
              approvals.allSatisfy({ $0.generation == binding.generation }),
              Set(approvals.map(\.application.stableDigest)).count == approvals.count
        else {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

private extension DeviceSessionBinding {
    var hasActiveGeneration: Bool {
        (1 ... maximumActiveDeviceSessionGeneration).contains(generation)
    }
}

public enum ExecutorActionStatus: String, Codable, Sendable {
    case success
    case failed
}

public struct ExecutorImagePayload: Codable, Equatable, Sendable {
    public let base64Data: String
    public let mimeType: String

    enum CodingKeys: String, CodingKey {
        case base64Data = "base64_data"
        case mimeType = "mime_type"
    }

    public init(base64Data: String, mimeType: String) {
        self.base64Data = base64Data
        self.mimeType = mimeType
    }
}

public struct ExecutorActionResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let monotonicSequence: UInt64
    public let screenshotGeneration: UInt64
    public let status: ExecutorActionStatus
    public let message: String
    public let image: ExecutorImagePayload?

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case monotonicSequence = "monotonic_sequence"
        case screenshotGeneration = "screenshot_generation"
        case status, message, image
    }

    public init(
        requestID: UUID,
        monotonicSequence: UInt64,
        screenshotGeneration: UInt64,
        status: ExecutorActionStatus,
        message: String,
        image: ExecutorImagePayload?
    ) {
        self.requestID = requestID
        self.monotonicSequence = monotonicSequence
        self.screenshotGeneration = screenshotGeneration
        self.status = status
        self.message = message
        self.image = image
    }
}
