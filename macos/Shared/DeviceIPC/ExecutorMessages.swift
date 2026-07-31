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
