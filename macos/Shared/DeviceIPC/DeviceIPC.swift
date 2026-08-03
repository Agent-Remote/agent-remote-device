import DeviceProtocol
import Foundation

public enum DeviceIPCVersion {
    public static let current: UInt64 = 1
    public static let maximumMessageBytes = 16 * 1024 * 1024
}

public enum DeviceIPCServiceIdentifier {
    public static let approvalUI = "dev.agentremote.device"
    public static let networkBroker = "dev.agentremote.device.network-broker"
    public static let guiExecutor = "dev.agentremote.device.gui-executor"
}

public enum DeviceIPCFailure: Int, Error, Equatable, Sendable {
    case incompatibleVersion = 1
    case messageTooLarge = 2
    case invalidMessage = 3
    case peerRejected = 4
    case serviceUnavailable = 5

    public var nsError: NSError {
        NSError(
            domain: "dev.agentremote.device.ipc",
            code: rawValue,
            userInfo: [NSLocalizedDescriptionKey: String(describing: self)]
        )
    }
}

public struct DeviceIPCEnvelope: Codable, Equatable, Sendable {
    public let version: UInt64
    public let requestID: UUID
    public let payload: Data

    public init(
        version: UInt64 = DeviceIPCVersion.current,
        requestID: UUID,
        payload: Data
    ) throws {
        guard version == DeviceIPCVersion.current else {
            throw DeviceIPCFailure.incompatibleVersion
        }
        guard payload.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        self.version = version
        self.requestID = requestID
        self.payload = payload
    }

    public static func decode(_ data: Data) throws -> DeviceIPCEnvelope {
        guard data.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        let envelope = try DeviceIPCDecoder.decode(DeviceIPCEnvelope.self, from: data)
        guard envelope.version == DeviceIPCVersion.current else {
            throw DeviceIPCFailure.incompatibleVersion
        }
        guard envelope.payload.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        return envelope
    }

    public func encoded() throws -> Data {
        let data = try JSONEncoder().encode(self)
        guard data.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        return data
    }
}

public enum DeviceIPCDecoder {
    public static func decode<Value: Codable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(data)
            let original = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let decoded = try JSONDecoder().decode(type, from: data)
            let canonicalData = try JSONEncoder().encode(decoded)
            let canonical = try JSONSerialization.jsonObject(
                with: canonicalData,
                options: [.fragmentsAllowed]
            )
            guard hasIdenticalJSONStructure(original, canonical) else {
                throw DeviceIPCFailure.invalidMessage
            }
            return decoded
        } catch let failure as DeviceIPCFailure {
            throw failure
        } catch {
            throw DeviceIPCFailure.invalidMessage
        }
    }
}

private func hasIdenticalJSONStructure(_ lhs: Any, _ rhs: Any) -> Bool {
    if let lhs = lhs as? [String: Any], let rhs = rhs as? [String: Any] {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        return lhs.allSatisfy { key, value in
            guard let other = rhs[key] else { return false }
            return hasIdenticalJSONStructure(value, other)
        }
    }
    if let lhs = lhs as? [Any], let rhs = rhs as? [Any] {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { hasIdenticalJSONStructure($0, $1) }
    }
    return !(lhs is [String: Any]) && !(rhs is [String: Any])
        && !(lhs is [Any]) && !(rhs is [Any])
}

@objc public protocol NetworkBrokerXPCProtocol {
    func protocolVersion(reply: @escaping (UInt64) -> Void)
    func configureGUIExecutor(
        _ endpoint: NSXPCListenerEndpoint,
        reply: @escaping (NSError?) -> Void
    )
    func listSessionCandidates(reply: @escaping (NSData?, NSError?) -> Void)
    func claimSession(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void)
    func pollPendingSession(reply: @escaping (NSData?, NSError?) -> Void)
    func approveSession(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void)
    func stopCurrentAction(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func endSession(_ request: NSData, reply: @escaping (NSError?) -> Void)
}

@objc public protocol ApprovalUIXPCProtocol {
    func handleRuntimeEvent(_ request: NSData, reply: @escaping (NSError?) -> Void)
}

@objc public protocol GUIExecutorXPCProtocol {
    func protocolVersion(reply: @escaping (UInt64) -> Void)
    func brokerEndpoint(reply: @escaping (NSXPCListenerEndpoint?, NSError?) -> Void)
    func updateSession(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func renewSession(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func performAction(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void)
    func pauseTurn(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func resumeTurn(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func stopCurrentAction(_ request: NSData, reply: @escaping (NSError?) -> Void)
    func endSession(_ request: NSData, reply: @escaping (NSError?) -> Void)
}
