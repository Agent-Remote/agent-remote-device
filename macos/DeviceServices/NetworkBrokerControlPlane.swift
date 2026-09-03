import DeviceIPC
import DeviceProtocol
import DeviceSecurity
import Foundation

private let maximumControlPlaneResponseBytes = 256 * 1_024
private let maximumInboxItems = 32
private let maximumControlPlaneClockSkewSeconds: TimeInterval = 5

public enum ControlPlaneSessionStatus: String, Codable, Sendable {
    case pendingDevice = "pending_device"
    case pendingUserApproval = "pending_user_approval"
    case active
    case stopping
    case stopped
    case denied
    case expired
    case failed

    public var isTerminal: Bool {
        switch self {
        case .stopped, .denied, .expired, .failed: true
        default: false
        }
    }
}

public enum ControlPlaneAuthorizationMode: String, Codable, Sendable {
    case perApplicationApproval = "per_application_approval"
    case sessionFullTrust = "session_full_trust"
}

public struct ControlPlaneDeviceSession: Codable, Equatable, Sendable {
    public let id: UUID
    public let userID: UUID
    public let deviceID: UUID
    public let toolSessionID: UUID
    public let nodeID: UUID
    public let platform: Platform
    public let status: ControlPlaneSessionStatus
    public let generation: UInt64
    public let authorizationMode: ControlPlaneAuthorizationMode
    public let authorizationPolicyVersion: UInt16
    public let authorizedAt: Date?
    public let leaseUntil: Date?
    public let expiresAt: Date
    public let lockAcquiredAt: Date?
    public let stoppedAt: Date?
    public let stopReason: String?
    public let createdAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case userID = "user_id"
        case deviceID = "device_id"
        case toolSessionID = "tool_session_id"
        case nodeID = "node_id"
        case platform, status, generation
        case authorizationMode = "authorization_mode"
        case authorizationPolicyVersion = "authorization_policy_version"
        case authorizedAt = "authorized_at"
        case leaseUntil = "lease_until"
        case expiresAt = "expires_at"
        case lockAcquiredAt = "lock_acquired_at"
        case stoppedAt = "stopped_at"
        case stopReason = "stop_reason"
        case createdAt = "created_at"
    }

    public var binding: DeviceSessionBinding {
        DeviceSessionBinding(
            userID: userID,
            deviceID: deviceID,
            toolSessionID: toolSessionID,
            deviceSessionID: id,
            nodeID: nodeID,
            platform: platform,
            generation: generation
        )
    }
}

public enum NetworkBrokerControlPlaneFailure: Error, Equatable, Sendable {
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case redirected
    case httpStatus(Int)
    case bindingMismatch
}

public enum DeviceRelayMaterialStatus: String, Codable, Sendable {
    case waiting
    case ready
}

public struct DeviceRelayMaterial: Codable, Equatable, Sendable {
    public let status: DeviceRelayMaterialStatus
    public let role: String
    public let generation: UInt64
    public let relayPath: String?
    public let relayTicket: String?
    public let peerSPKISHA256: String?
    public let exporterContext: String?
    public let expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case status, role, generation
        case relayPath = "relay_path"
        case relayTicket = "relay_ticket"
        case peerSPKISHA256 = "peer_spki_sha256"
        case exporterContext = "exporter_context"
        case expiresAt = "expires_at"
    }
}

public protocol NetworkBrokerHTTPTransport: Sendable {
    func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse)
}

public final class BoundedNetworkBrokerHTTPTransport: NSObject, NetworkBrokerHTTPTransport,
    URLSessionTaskDelegate, @unchecked Sendable
{
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv13
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv13
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    public func send(
        _ request: URLRequest,
        maximumResponseBytes: Int
    ) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        if let expectedLength = response.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(expectedLength),
           length > maximumResponseBytes
        {
            throw NetworkBrokerControlPlaneFailure.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 16 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw NetworkBrokerControlPlaneFailure.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }

    public func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct NetworkBrokerControlPlaneClient: Sendable {
    private let credential: NetworkBrokerCredential
    private let transport: any NetworkBrokerHTTPTransport
    private let nowProvider: @Sendable () -> Date

    public init(
        credential: NetworkBrokerCredential,
        transport: any NetworkBrokerHTTPTransport = BoundedNetworkBrokerHTTPTransport(),
        nowProvider: @escaping @Sendable () -> Date = { Date() },
        now: Date = Date()
    ) throws {
        try credential.validate(now: now)
        self.credential = credential
        self.transport = transport
        self.nowProvider = nowProvider
    }

    public func deviceInbox(now: Date = Date()) async throws -> [ControlPlaneDeviceSession] {
        let request = try makeRequest(path: "/api/v1/device-sessions/device-inbox")
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let payload = object["data"] as? [String: Any],
              exactKeys(payload, ["items"]),
              let items = payload["items"] as? [[String: Any]],
              items.count <= maximumInboxItems
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        for item in items {
            try validateSessionObject(item)
        }
        let envelope = try decoder().decode(DeviceSessionListEnvelope.self, from: data)
        guard envelope.data.items.count == items.count else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        var identifiers = Set<UUID>()
        for item in envelope.data.items {
            try validate(item, now: now)
            guard item.deviceID.uuidString.lowercased() == credential.deviceID,
                  identifiers.insert(item.id).inserted,
                  !item.status.isTerminal
            else {
                throw NetworkBrokerControlPlaneFailure.bindingMismatch
            }
        }
        return envelope.data.items.sorted { $0.createdAt < $1.createdAt }
    }

    public func sessionCandidates(now: Date = Date()) async throws -> [BrokerSessionCandidate] {
        let request = try makeRequest(path: "/api/v1/device-sessions/candidates")
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let payload = object["data"] as? [String: Any],
              exactKeys(payload, ["items"]),
              let items = payload["items"] as? [[String: Any]],
              items.count <= maximumInboxItems
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        for item in items {
            try validateCandidateObject(item)
        }
        let envelope = try decoder().decode(BrokerSessionCandidateListEnvelope.self, from: data)
        guard envelope.data.items.count == items.count else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        var identifiers = Set<UUID>()
        for item in envelope.data.items {
            try item.validate()
            guard identifiers.insert(item.toolSessionID).inserted else {
                throw NetworkBrokerControlPlaneFailure.invalidResponse
            }
        }
        return envelope.data.items
    }

    public func claim(
        _ candidate: BrokerSessionCandidate,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try candidate.validate()
        return try await claim(toolSessionID: candidate.toolSessionID, now: now)
    }

    public func claim(
        toolSessionID: UUID,
        deviceCapabilities: Set<String> = [capabilitySessionFullTrustV1],
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        let claim = BrokerClaimRequest(
            toolSessionID: toolSessionID,
            deviceCapabilities: deviceCapabilities
        )
        try claim.validate()
        let body = try JSONEncoder().encode(claim)
        let request = try makeRequest(
            path: "/api/v1/device-sessions/claim",
            method: "POST",
            body: body
        )
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let item = object["data"] as? [String: Any]
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        try validateSessionObject(item)
        let session = try decoder().decode(DeviceSessionEnvelope.self, from: data).data
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.toolSessionID == toolSessionID,
              !session.status.isTerminal
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return session
    }

    public func markDeviceConnected(
        _ session: ControlPlaneDeviceSession,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .pendingDevice
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: ["generation": session.generation])
        let request = try makeRequest(
            path: "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/device-connected",
            method: "POST",
            body: body
        )
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let item = object["data"] as? [String: Any]
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        try validateSessionObject(item)
        let envelope = try decoder().decode(DeviceSessionEnvelope.self, from: data)
        try validate(envelope.data, now: now)
        guard sameIdentity(envelope.data, session),
              (envelope.data.status == .pendingUserApproval
                  && session.authorizationMode == .perApplicationApproval
                  || envelope.data.status == .active
                  && session.authorizationMode == .sessionFullTrust
                  && envelope.data.leaseUntil.map({ $0 > now }) == true)
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return envelope.data
    }

    public func approve(
        _ session: ControlPlaneDeviceSession,
        approvals: [LocalApproval],
        result: BrokerApprovalResult,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .pendingUserApproval,
              session.authorizationMode == .perApplicationApproval,
              !approvals.isEmpty,
              approvals.count <= maximumInboxItems,
              approvals.allSatisfy({ $0.generation == session.generation }),
              Set(approvals.map(\.application.stableDigest)).count == approvals.count
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONEncoder().encode(ControlPlaneApprovalRequest(
            generation: session.generation,
            approvals: approvals.map {
                ControlPlaneApprovalItem(
                    applicationDigest: $0.application.stableDigest,
                    controlLevel: $0.controlLevel,
                    approvalResult: result.rawValue,
                    clipboardAllowed: result == .allowed && $0.clipboardAllowed
                )
            }
        ))
        let request = try makeRequest(
            path: "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/approve",
            method: "POST",
            body: body
        )
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let item = object["data"] as? [String: Any]
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        try validateSessionObject(item)
        let envelope = try decoder().decode(DeviceSessionEnvelope.self, from: data)
        try validate(envelope.data, now: now)
        guard sameIdentity(envelope.data, session) else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        switch result {
        case .allowed:
            guard envelope.data.status == .active,
                  let leaseUntil = envelope.data.leaseUntil,
                  leaseUntil > now
            else {
                throw NetworkBrokerControlPlaneFailure.bindingMismatch
            }
        case .denied:
            guard envelope.data.status == .denied,
                  envelope.data.leaseUntil == nil
            else {
                throw NetworkBrokerControlPlaneFailure.bindingMismatch
            }
        }
        return envelope.data
    }

    public func abort(
        _ session: ControlPlaneDeviceSession,
        reason: BrokerAbortReason,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .active,
              session.generation < maximumActiveDeviceSessionGeneration
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "generation": session.generation,
            "reason": reason.rawValue,
        ])
        let updated = try await mutate(
            session,
            suffix: "abort",
            body: body,
            now: now
        )
        guard sameIdentity(updated, session),
              updated.generation == session.generation + 1,
              updated.status == .pendingDevice,
              updated.leaseUntil == nil
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return updated
    }

    public func stop(
        _ session: ControlPlaneDeviceSession,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.generation < maximumDeviceSessionGeneration
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: ["reason": "session_end"])
        let updated = try await mutate(
            session,
            suffix: "stop",
            body: body,
            now: now,
            allowTerminal: true
        )
        guard sameIdentity(updated, session),
              updated.generation == session.generation + 1,
              updated.status == .stopped,
              updated.leaseUntil == nil
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return updated
    }

    public func registerRelayMaterial(
        _ session: ControlPlaneDeviceSession,
        spkiSHA256: String,
        now: Date = Date()
    ) async throws -> DeviceRelayMaterial {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .active,
              validHex32(spkiSHA256)
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "generation": session.generation,
            "spki_sha256": spkiSHA256,
        ])
        let request = try makeRequest(
            path: "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/relay-material",
            method: "POST",
            body: body
        )
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let item = object["data"] as? [String: Any],
              exactKeys(item, [
                  "status", "role", "generation", "relay_path", "relay_ticket",
                  "peer_spki_sha256", "exporter_context", "expires_at",
              ])
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        let material = try decoder().decode(DeviceRelayMaterialEnvelope.self, from: data).data
        guard material.role == "device", material.generation == session.generation else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        switch material.status {
        case .waiting:
            guard material.relayPath == nil,
                  material.relayTicket == nil,
                  material.peerSPKISHA256 == nil,
                  material.exporterContext == nil,
                  material.expiresAt == nil
            else {
                throw NetworkBrokerControlPlaneFailure.invalidResponse
            }
        case .ready:
            let expectedPath = "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/relay"
            guard material.relayPath == expectedPath,
                  let ticket = material.relayTicket,
                  (32 ... 4_096).contains(ticket.utf8.count),
                  ticket.utf8.allSatisfy({ (0x21 ... 0x7e).contains($0) }),
                  let peerSPKI = material.peerSPKISHA256,
                  validHex32(peerSPKI),
                  let exporterContext = material.exporterContext,
                  validHex32(exporterContext),
                  let expiresAt = material.expiresAt,
                  expiresAt > now,
                  expiresAt <= session.expiresAt
            else {
                throw NetworkBrokerControlPlaneFailure.invalidResponse
            }
        }
        return material
    }

    public func acquireLock(
        _ session: ControlPlaneDeviceSession,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .active
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "generation": session.generation,
        ])
        let updated = try await mutate(
            session,
            suffix: "lock",
            body: body,
            now: now
        )
        guard sameIdentity(updated, session),
              updated.status == .active,
              updated.lockAcquiredAt != nil,
              let leaseUntil = updated.leaseUntil,
              leaseUntil > now
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return updated
    }

    public func renew(
        _ session: ControlPlaneDeviceSession,
        now: Date = Date()
    ) async throws -> ControlPlaneDeviceSession {
        try validate(session, now: now)
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .active,
              let currentLease = session.leaseUntil,
              currentLease > now
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "generation": session.generation,
        ])
        let updated = try await mutate(
            session,
            suffix: "renew",
            body: body,
            now: now
        )
        guard sameIdentity(updated, session),
              updated.status == .active,
              updated.lockAcquiredAt == session.lockAcquiredAt,
              let leaseUntil = updated.leaseUntil,
              leaseUntil >= currentLease,
              leaseUntil > now
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        return updated
    }

    public func relayRequest(
        _ session: ControlPlaneDeviceSession,
        material: DeviceRelayMaterial,
        now: Date = Date()
    ) throws -> URLRequest {
        try validate(session, now: now)
        let expectedPath = "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/relay"
        guard session.deviceID.uuidString.lowercased() == credential.deviceID,
              session.status == .active,
              material.status == .ready,
              material.role == "device",
              material.generation == session.generation,
              material.relayPath == expectedPath,
              let ticket = material.relayTicket,
              (32 ... 4_096).contains(ticket.utf8.count),
              let expiresAt = material.expiresAt,
              expiresAt > now,
              let base = URLComponents(string: credential.serverURL),
              let host = base.host
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        var components = URLComponents()
        components.scheme = "wss"
        components.host = host
        components.port = base.port
        components.path = expectedPath
        guard let url = components.url else {
            throw NetworkBrokerControlPlaneFailure.invalidRequest
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func mutate(
        _ session: ControlPlaneDeviceSession,
        suffix: String,
        body: Data,
        now: Date,
        allowTerminal: Bool = false
    ) async throws -> ControlPlaneDeviceSession {
        let request = try makeRequest(
            path: "/api/v1/device-sessions/\(session.id.uuidString.lowercased())/\(suffix)",
            method: "POST",
            body: body
        )
        let data = try await send(request)
        let object = try strictObject(data)
        guard exactKeys(object, ["data", "request_id"]),
              boundedRequestID(object["request_id"]),
              let item = object["data"] as? [String: Any]
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        try validateSessionObject(item)
        let envelope = try decoder().decode(DeviceSessionEnvelope.self, from: data)
        if allowTerminal {
            // The server records stopped_at after the request begins and its
            // clock can be slightly ahead. Keep that tolerance small and bound.
            let responseTime = max(now, nowProvider())
                .addingTimeInterval(maximumControlPlaneClockSkewSeconds)
            try validateTerminal(envelope.data, now: responseTime)
        } else {
            try validate(envelope.data, now: now)
        }
        return envelope.data
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(
            request,
            maximumResponseBytes: maximumControlPlaneResponseBytes
        )
        guard response.url == request.url else {
            throw NetworkBrokerControlPlaneFailure.redirected
        }
        guard response.statusCode == 200 else {
            throw NetworkBrokerControlPlaneFailure.httpStatus(response.statusCode)
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().hasPrefix("application/json") == true
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        return data
    }

    private func makeRequest(
        path: String,
        method: String = "GET",
        body: Data? = nil
    ) throws -> URLRequest {
        guard path.hasPrefix("/api/v1/device-sessions/"),
              !path.contains(".."),
              let url = URL(string: credential.serverURL + path),
              url.scheme == "https"
        else {
            throw NetworkBrokerControlPlaneFailure.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 15
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

private struct DeviceSessionListEnvelope: Codable {
    let data: DeviceSessionListData
}

private struct BrokerSessionCandidateListEnvelope: Codable {
    let data: BrokerSessionCandidateList
}

private struct DeviceSessionListData: Codable {
    let items: [ControlPlaneDeviceSession]
}

private struct DeviceSessionEnvelope: Codable {
    let data: ControlPlaneDeviceSession
}

private struct DeviceRelayMaterialEnvelope: Codable {
    let data: DeviceRelayMaterial
}

private struct ControlPlaneApprovalRequest: Encodable {
    let generation: UInt64
    let approvals: [ControlPlaneApprovalItem]
}

private struct ControlPlaneApprovalItem: Encodable {
    let applicationDigest: String
    let controlLevel: ControlLevel
    let approvalResult: String
    let clipboardAllowed: Bool

    private enum CodingKeys: String, CodingKey {
        case applicationDigest = "application_digest"
        case controlLevel = "control_level"
        case approvalResult = "approval_result"
        case clipboardAllowed = "clipboard_allowed"
    }
}

private func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        guard let date = fractional.date(from: value) ?? plain.date(from: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "invalid ISO 8601 date"
            )
        }
        return date
    }
    return decoder
}

private func strictObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= maximumControlPlaneResponseBytes else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
    do {
        try StrictJSON.validateUniqueObjectKeys(data)
    } catch {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
    guard
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
    return object
}

private func exactKeys(_ object: [String: Any], _ expected: Set<String>) -> Bool {
    Set(object.keys) == expected
}

private func boundedRequestID(_ value: Any?) -> Bool {
    value is NSNull || (value as? String).map { !$0.isEmpty && $0.utf8.count <= 128 } == true
}

private func validHex32(_ value: String) -> Bool {
    value.utf8.count == 64
        && value.utf8.allSatisfy { byte in
            (48 ... 57).contains(byte) || (97 ... 102).contains(byte)
        }
}

private func validateSessionObject(_ object: [String: Any]) throws {
    let expected = Set([
        "id", "user_id", "device_id", "tool_session_id", "node_id", "platform", "status",
        "generation", "lease_until", "expires_at", "lock_acquired_at", "stopped_at",
        "stop_reason", "created_at", "authorization_mode", "authorization_policy_version",
        "authorized_at",
    ])
    guard exactKeys(object, expected) else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
    for key in ["id", "user_id", "device_id", "tool_session_id", "node_id"] {
        guard let value = object[key] as? String,
              let identifier = UUID(uuidString: value),
              identifier.uuidString.lowercased() == value
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
    }
}

private func validateCandidateObject(_ object: [String: Any]) throws {
    let expected = Set([
        "tool_session_id", "tool_type", "tool_account_id", "workspace_id", "project_key",
        "display_name", "status", "node_id", "runtime_backend", "current_device_id",
        "current_device_name", "device_session_id", "controllable",
    ])
    guard exactKeys(object, expected),
          let toolType = object["tool_type"] as? String,
          toolType == "claude",
          let projectKey = object["project_key"] as? String,
          !projectKey.isEmpty,
          projectKey.utf8.count <= 256,
          let displayName = object["display_name"] as? String,
          !displayName.isEmpty,
          displayName.utf8.count <= 256,
          let runtimeBackend = object["runtime_backend"] as? String,
          !runtimeBackend.isEmpty,
          runtimeBackend.utf8.count <= 64,
          object["controllable"] as? Bool == true
    else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
    for key in ["tool_session_id", "tool_account_id", "workspace_id", "node_id"] {
        guard let value = object[key] as? String,
              let identifier = UUID(uuidString: value),
              identifier.uuidString.lowercased() == value
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
    }
    for key in ["current_device_id", "device_session_id"] {
        guard object[key] is NSNull
            || ((object[key] as? String).flatMap(UUID.init(uuidString:)) != nil)
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
    }
    if let deviceName = object["current_device_name"] as? String,
       (deviceName.isEmpty || deviceName.utf8.count > 128)
    {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
}

private func validate(_ session: ControlPlaneDeviceSession, now: Date) throws {
    guard session.platform == .macos,
          (1 ... maximumActiveDeviceSessionGeneration).contains(session.generation),
          session.authorizationPolicyVersion == 1,
          (session.authorizationMode == .sessionFullTrust) == (session.authorizedAt != nil),
          session.authorizedAt.map({ $0 <= now.addingTimeInterval(maximumControlPlaneClockSkewSeconds) }) ?? true,
          session.expiresAt > now,
          session.createdAt <= session.expiresAt,
          session.stopReason.map({ $0.utf8.count <= 128 }) ?? true,
          session.leaseUntil.map({ $0 <= session.expiresAt }) ?? true
    else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
}

private func validateTerminal(_ session: ControlPlaneDeviceSession, now: Date) throws {
    guard session.platform == .macos,
          (1 ... maximumDeviceSessionGeneration).contains(session.generation),
          session.authorizationPolicyVersion == 1,
          (session.authorizationMode == .sessionFullTrust) == (session.authorizedAt != nil),
          session.createdAt <= session.expiresAt,
          session.stoppedAt.map({ $0 <= now }) ?? false,
          session.stopReason.map({ $0.utf8.count <= 128 }) ?? false
    else {
        throw NetworkBrokerControlPlaneFailure.invalidResponse
    }
}

private func sameIdentity(
    _ lhs: ControlPlaneDeviceSession,
    _ rhs: ControlPlaneDeviceSession
) -> Bool {
    lhs.id == rhs.id
        && lhs.userID == rhs.userID
        && lhs.deviceID == rhs.deviceID
        && lhs.toolSessionID == rhs.toolSessionID
        && lhs.nodeID == rhs.nodeID
        && lhs.platform == rhs.platform
        && lhs.authorizationMode == rhs.authorizationMode
        && lhs.authorizationPolicyVersion == rhs.authorizationPolicyVersion
        && lhs.authorizedAt == rhs.authorizedAt
}
