import Crypto
import DeviceIPC
import DeviceProtocol
import Foundation

private let outboundPolicySchemaVersion: UInt64 = 1
private let outboundPolicyMaximumPayloadBytes = 16 * 1_024
private let outboundPolicyMaximumClockSkew: TimeInterval = 5
private let outboundPolicyMaximumObservationAge: TimeInterval = 30
private let outboundPolicyMaximumLifetime: TimeInterval = 60

public enum OutboundNetworkPolicyFailure: Error, Equatable, Sendable {
    case unavailable
    case timedOut
    case malformed
    case invalidSignature
    case stale
    case identityMismatch
    case destinationMismatch
    case notEnforced
}

public struct OutboundPolicyChallenge: Codable, Equatable, Sendable {
    public let schemaVersion: UInt64
    public let nonce: Data
    public let teamIdentifier: String
    public let brokerBundleIdentifier: String
    public let policyIdentifier: String
    public let allowedHosts: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case nonce
        case teamIdentifier = "team_identifier"
        case brokerBundleIdentifier = "broker_bundle_identifier"
        case policyIdentifier = "policy_identifier"
        case allowedHosts = "allowed_hosts"
    }
}

public struct OutboundPolicyProof: Codable, Equatable, Sendable {
    public let schemaVersion: UInt64
    public let nonce: Data
    public let teamIdentifier: String
    public let brokerBundleIdentifier: String
    public let policyIdentifier: String
    public let allowedHosts: [String]
    public let enforcement: String
    public let policyEnabled: Bool
    public let allowedProbeSucceeded: Bool
    public let disallowedProbeBlocked: Bool
    public let anthropicProbeBlocked: Bool
    public let observedAt: Date
    public let expiresAt: Date

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case nonce
        case teamIdentifier = "team_identifier"
        case brokerBundleIdentifier = "broker_bundle_identifier"
        case policyIdentifier = "policy_identifier"
        case allowedHosts = "allowed_hosts"
        case enforcement
        case policyEnabled = "policy_enabled"
        case allowedProbeSucceeded = "allowed_probe_succeeded"
        case disallowedProbeBlocked = "disallowed_probe_blocked"
        case anthropicProbeBlocked = "anthropic_probe_blocked"
        case observedAt = "observed_at"
        case expiresAt = "expires_at"
    }

    public init(
        schemaVersion: UInt64 = 1,
        nonce: Data,
        teamIdentifier: String,
        brokerBundleIdentifier: String,
        policyIdentifier: String,
        allowedHosts: [String],
        enforcement: String,
        policyEnabled: Bool,
        allowedProbeSucceeded: Bool,
        disallowedProbeBlocked: Bool,
        anthropicProbeBlocked: Bool,
        observedAt: Date,
        expiresAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.nonce = nonce
        self.teamIdentifier = teamIdentifier
        self.brokerBundleIdentifier = brokerBundleIdentifier
        self.policyIdentifier = policyIdentifier
        self.allowedHosts = allowedHosts
        self.enforcement = enforcement
        self.policyEnabled = policyEnabled
        self.allowedProbeSucceeded = allowedProbeSucceeded
        self.disallowedProbeBlocked = disallowedProbeBlocked
        self.anthropicProbeBlocked = anthropicProbeBlocked
        self.observedAt = observedAt
        self.expiresAt = expiresAt
    }
}

public struct SignedOutboundPolicyProof: Codable, Equatable, Sendable {
    public let payload: Data
    public let signature: Data

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case payload, signature
    }

    public init(payload: Data, signature: Data) {
        self.payload = payload
        self.signature = signature
    }
}

public protocol OutboundPolicyAttestationLoading: Sendable {
    func loadAttestation(challenge: Data) async throws -> Data
}

public protocol OutboundNetworkPolicyChecking: Sendable {
    func verify(controlPlaneHost: String, now: Date) async throws
}

public struct UnavailableOutboundNetworkPolicyChecker: OutboundNetworkPolicyChecking {
    public init() {}

    public func verify(controlPlaneHost _: String, now _: Date) async throws {
        throw OutboundNetworkPolicyFailure.unavailable
    }
}

public struct ApplicationOutboundNetworkPolicyChecker: OutboundNetworkPolicyChecking {
    private static let deniedHostSuffixes = [
        "anthropic.com",
        "claude.ai",
    ]

    public init() {}

    public func verify(controlPlaneHost: String, now _: Date = Date()) async throws {
        let host = controlPlaneHost.lowercased()
        guard Self.isHost(host),
              !Self.deniedHostSuffixes.contains(where: { suffix in
                  host == suffix || host.hasSuffix(".\(suffix)")
              })
        else {
            throw OutboundNetworkPolicyFailure.destinationMismatch
        }
    }

    private static func isHost(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 253,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("*"),
              !value.contains(":"),
              value.contains("."),
              value.contains(where: { $0.isASCII && $0.isLetter })
        else { return false }
        return value.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
        }
    }
}

public struct SignedOutboundNetworkPolicyChecker: OutboundNetworkPolicyChecking {
    private let loader: any OutboundPolicyAttestationLoading
    private let publicKey: Curve25519.Signing.PublicKey
    private let teamIdentifier: String
    private let brokerBundleIdentifier: String
    private let policyIdentifier: String
    private let timeout: Duration

    public init(
        loader: any OutboundPolicyAttestationLoading,
        publicKey: Data,
        teamIdentifier: String,
        brokerBundleIdentifier: String = DeviceIPCServiceIdentifier.networkBroker,
        policyIdentifier: String,
        timeout: Duration = .seconds(5)
    ) throws {
        guard Self.isTeamIdentifier(teamIdentifier),
              Self.isIdentifier(brokerBundleIdentifier),
              Self.isIdentifier(policyIdentifier),
              timeout > .zero
        else {
            throw OutboundNetworkPolicyFailure.malformed
        }
        do {
            self.publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw OutboundNetworkPolicyFailure.malformed
        }
        self.loader = loader
        self.teamIdentifier = teamIdentifier
        self.brokerBundleIdentifier = brokerBundleIdentifier
        self.policyIdentifier = policyIdentifier
        self.timeout = timeout
    }

    public func verify(controlPlaneHost: String, now: Date = Date()) async throws {
        let expectedHost = controlPlaneHost.lowercased()
        guard Self.isHost(expectedHost) else {
            throw OutboundNetworkPolicyFailure.destinationMismatch
        }
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let challenge = OutboundPolicyChallenge(
            schemaVersion: outboundPolicySchemaVersion,
            nonce: nonce,
            teamIdentifier: teamIdentifier,
            brokerBundleIdentifier: brokerBundleIdentifier,
            policyIdentifier: policyIdentifier,
            allowedHosts: [expectedHost]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let request = try encoder.encode(challenge)
        let response = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await loader.loadAttestation(challenge: request) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw OutboundNetworkPolicyFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw OutboundNetworkPolicyFailure.unavailable
            }
            return first
        }
        try validate(response, challenge: challenge, now: now)
    }

    private func validate(
        _ response: Data,
        challenge: OutboundPolicyChallenge,
        now: Date
    ) throws {
        guard response.count <= outboundPolicyMaximumPayloadBytes else {
            throw OutboundNetworkPolicyFailure.invalidSignature
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(response, maximumDepth: 8)
        } catch {
            throw OutboundNetworkPolicyFailure.malformed
        }
        guard try Self.hasExactKeys(response, keys: ["payload", "signature"]),
              let signed = try? JSONDecoder().decode(SignedOutboundPolicyProof.self, from: response),
              signed.payload.count <= outboundPolicyMaximumPayloadBytes,
              publicKey.isValidSignature(signed.signature, for: signed.payload)
        else {
            throw OutboundNetworkPolicyFailure.invalidSignature
        }
        do {
            try StrictJSON.validateUniqueObjectKeys(signed.payload, maximumDepth: 8)
        } catch {
            throw OutboundNetworkPolicyFailure.malformed
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard try Self.hasExactKeys(signed.payload, keys: [
                  "schema_version", "nonce", "team_identifier", "broker_bundle_identifier",
                  "policy_identifier", "allowed_hosts", "enforcement", "policy_enabled",
                  "allowed_probe_succeeded", "disallowed_probe_blocked",
                  "anthropic_probe_blocked", "observed_at", "expires_at",
              ]),
              let proof = try? decoder.decode(OutboundPolicyProof.self, from: signed.payload),
              proof.schemaVersion == outboundPolicySchemaVersion,
              proof.nonce == challenge.nonce
        else {
            throw OutboundNetworkPolicyFailure.malformed
        }
        guard proof.teamIdentifier == challenge.teamIdentifier,
              proof.brokerBundleIdentifier == challenge.brokerBundleIdentifier,
              proof.policyIdentifier == challenge.policyIdentifier
        else {
            throw OutboundNetworkPolicyFailure.identityMismatch
        }
        guard proof.allowedHosts == challenge.allowedHosts else {
            throw OutboundNetworkPolicyFailure.destinationMismatch
        }
        guard proof.observedAt <= now.addingTimeInterval(outboundPolicyMaximumClockSkew),
              proof.observedAt >= now.addingTimeInterval(-outboundPolicyMaximumObservationAge),
              proof.expiresAt > now,
              proof.expiresAt > proof.observedAt,
              proof.expiresAt <= proof.observedAt.addingTimeInterval(outboundPolicyMaximumLifetime)
        else {
            throw OutboundNetworkPolicyFailure.stale
        }
        guard proof.enforcement == "network_extension",
              proof.policyEnabled,
              proof.allowedProbeSucceeded,
              proof.disallowedProbeBlocked,
              proof.anthropicProbeBlocked
        else {
            throw OutboundNetworkPolicyFailure.notEnforced
        }
    }

    private static func hasExactKeys(_ data: Data, keys: Set<String>) throws -> Bool {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return Set(object.keys) == keys
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        value.count == 10 && value.allSatisfy {
            $0.isASCII && ($0.isUppercase || $0.isNumber)
        }
    }

    private static func isIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= 255
        else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    private static func isHost(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty,
              value.utf8.count <= 253,
              !value.hasPrefix("."),
              !value.hasSuffix("."),
              !value.contains("*")
        else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }
}

@objc public protocol OutboundPolicyAttestorXPCProtocol {
    func attest(_ challenge: NSData, reply: @escaping (NSData?, NSError?) -> Void)
}

public final class XPCOutboundPolicyAttestationLoader: OutboundPolicyAttestationLoading,
    @unchecked Sendable
{
    private let machServiceName: String

    public init(machServiceName: String) throws {
        guard !machServiceName.isEmpty,
              machServiceName.utf8.count <= 255,
              machServiceName.allSatisfy({
                  $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-")
              })
        else {
            throw OutboundNetworkPolicyFailure.malformed
        }
        self.machServiceName = machServiceName
    }

    public func loadAttestation(challenge: Data) async throws -> Data {
        guard challenge.count <= outboundPolicyMaximumPayloadBytes else {
            throw OutboundNetworkPolicyFailure.malformed
        }
        let connection = NSXPCConnection(machServiceName: machServiceName, options: .privileged)
        let connectionBox = XPCConnectionBox(connection)
        connection.remoteObjectInterface = NSXPCInterface(with: OutboundPolicyAttestorXPCProtocol.self)
        connection.activate()
        defer { connection.invalidate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let reply = AttestationReply(continuation)
                connection.interruptionHandler = {
                    reply.resolve(.failure(OutboundNetworkPolicyFailure.unavailable))
                }
                connection.invalidationHandler = {
                    reply.resolve(.failure(OutboundNetworkPolicyFailure.unavailable))
                }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    reply.resolve(.failure(OutboundNetworkPolicyFailure.unavailable))
                }) as? OutboundPolicyAttestorXPCProtocol else {
                    reply.resolve(.failure(OutboundNetworkPolicyFailure.unavailable))
                    return
                }
                proxy.attest(challenge as NSData) { data, error in
                    guard error == nil,
                          let data,
                          data.length <= outboundPolicyMaximumPayloadBytes
                    else {
                        reply.resolve(.failure(OutboundNetworkPolicyFailure.unavailable))
                        return
                    }
                    reply.resolve(.success(data as Data))
                }
            }
        } onCancel: {
            connectionBox.connection.invalidate()
        }
    }
}

public enum ManagedOutboundNetworkPolicyChecker {
    public static func load(bundle: Bundle = .main) throws -> any OutboundNetworkPolicyChecking {
        if bundle.object(forInfoDictionaryKey: "AgentRemoteOutboundPolicyMode") as? String
            == "application"
        {
            return ApplicationOutboundNetworkPolicyChecker()
        }
        guard let teamIdentifier = bundle.object(
            forInfoDictionaryKey: "AgentRemoteTeamIdentifier"
        ) as? String,
            let serviceName = bundle.object(
                forInfoDictionaryKey: "AgentRemoteOutboundPolicyAttestorMachService"
            ) as? String,
            let encodedKey = bundle.object(
                forInfoDictionaryKey: "AgentRemoteOutboundPolicyAttestorPublicKey"
            ) as? String,
            let publicKey = Data(base64Encoded: encodedKey),
            let policyIdentifier = bundle.object(
                forInfoDictionaryKey: "AgentRemoteOutboundPolicyIdentifier"
            ) as? String
        else {
            throw OutboundNetworkPolicyFailure.unavailable
        }
        let loader = try XPCOutboundPolicyAttestationLoader(machServiceName: serviceName)
        return try SignedOutboundNetworkPolicyChecker(
            loader: loader,
            publicKey: publicKey,
            teamIdentifier: teamIdentifier,
            policyIdentifier: policyIdentifier
        )
    }
}

private final class AttestationReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = continuation
    }

    func resolve(_ result: Result<Data, any Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private final class XPCConnectionBox: @unchecked Sendable {
    let connection: NSXPCConnection

    init(_ connection: NSXPCConnection) {
        self.connection = connection
    }
}
