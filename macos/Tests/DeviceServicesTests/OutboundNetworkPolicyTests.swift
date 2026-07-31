import Crypto
import DeviceIPC
import DeviceServices
import Foundation
import Testing

private let policyNow = Date(timeIntervalSince1970: 4_000_000_000)
private let policyTeamIdentifier = "AB12CD34EF"

@Test func applicationPolicyAllowsOnlyNormalizedNonAnthropicDNSHosts() async throws {
    let checker = ApplicationOutboundNetworkPolicyChecker()
    try await checker.verify(controlPlaneHost: "control.example.com", now: Date())

    for host in [
        "api.anthropic.com",
        "claude.ai",
        "127.0.0.1",
        "control.example.com:443",
        "*.example.com",
        "LOCALHOST",
    ] {
        await #expect(throws: OutboundNetworkPolicyFailure.destinationMismatch) {
            try await checker.verify(controlPlaneHost: host, now: Date())
        }
    }
}
private let policyIdentifier = "dev.agentremote.outbound-policy.production"

private enum ProofMutation: Sendable {
    case none
    case teamIdentifier(String)
    case allowedHosts([String])
    case observedAt(Date)
    case expiresAt(Date)
    case policyDisabled
    case duplicateKey
    case invalidSignature
}

private struct SigningAttestationLoader: OutboundPolicyAttestationLoading {
    let privateKey: Curve25519.Signing.PrivateKey
    let mutation: ProofMutation

    func loadAttestation(challenge data: Data) async throws -> Data {
        let challenge = try JSONDecoder().decode(OutboundPolicyChallenge.self, from: data)
        let teamIdentifier: String
        let allowedHosts: [String]
        let observedAt: Date
        let policyEnabled: Bool
        switch mutation {
        case .none, .duplicateKey, .invalidSignature, .expiresAt:
            teamIdentifier = challenge.teamIdentifier
            allowedHosts = challenge.allowedHosts
            observedAt = policyNow
            policyEnabled = true
        case let .teamIdentifier(value):
            teamIdentifier = value
            allowedHosts = challenge.allowedHosts
            observedAt = policyNow
            policyEnabled = true
        case let .allowedHosts(value):
            teamIdentifier = challenge.teamIdentifier
            allowedHosts = value
            observedAt = policyNow
            policyEnabled = true
        case let .observedAt(value):
            teamIdentifier = challenge.teamIdentifier
            allowedHosts = challenge.allowedHosts
            observedAt = value
            policyEnabled = true
        case .policyDisabled:
            teamIdentifier = challenge.teamIdentifier
            allowedHosts = challenge.allowedHosts
            observedAt = policyNow
            policyEnabled = false
        }
        let proof = OutboundPolicyProof(
            nonce: challenge.nonce,
            teamIdentifier: teamIdentifier,
            brokerBundleIdentifier: challenge.brokerBundleIdentifier,
            policyIdentifier: challenge.policyIdentifier,
            allowedHosts: allowedHosts,
            enforcement: "network_extension",
            policyEnabled: policyEnabled,
            allowedProbeSucceeded: true,
            disallowedProbeBlocked: true,
            anthropicProbeBlocked: true,
            observedAt: observedAt,
            expiresAt: {
                if case let .expiresAt(value) = mutation { return value }
                return observedAt.addingTimeInterval(45)
            }()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var payload = try encoder.encode(proof)
        if case .duplicateKey = mutation {
            var text = try #require(String(data: payload, encoding: .utf8))
            text.removeLast()
            text += ",\"policy_enabled\":true}"
            payload = Data(text.utf8)
        }
        let signingKey: Curve25519.Signing.PrivateKey
        if case .invalidSignature = mutation {
            signingKey = Curve25519.Signing.PrivateKey()
        } else {
            signingKey = privateKey
        }
        let signed = SignedOutboundPolicyProof(
            payload: payload,
            signature: try signingKey.signature(for: payload)
        )
        return try encoder.encode(signed)
    }
}

private struct HangingAttestationLoader: OutboundPolicyAttestationLoading {
    func loadAttestation(challenge _: Data) async throws -> Data {
        try await Task.sleep(for: .seconds(60))
        return Data()
    }
}

private func policyChecker(
    mutation: ProofMutation = .none
) throws -> SignedOutboundNetworkPolicyChecker {
    let key = Curve25519.Signing.PrivateKey()
    return try SignedOutboundNetworkPolicyChecker(
        loader: SigningAttestationLoader(privateKey: key, mutation: mutation),
        publicKey: key.publicKey.rawRepresentation,
        teamIdentifier: policyTeamIdentifier,
        policyIdentifier: policyIdentifier
    )
}

@Test func signedOutboundPolicyAcceptsOnlyFreshActiveNetworkExtensionProof() async throws {
    let checker = try policyChecker()
    try await checker.verify(controlPlaneHost: "control.example.test", now: policyNow)
}

@Test func signedOutboundPolicyRejectsMissingAndInvalidAttestors() async throws {
    await #expect(throws: OutboundNetworkPolicyFailure.unavailable) {
        try await UnavailableOutboundNetworkPolicyChecker().verify(
            controlPlaneHost: "control.example.test",
            now: policyNow
        )
    }
    await #expect(throws: OutboundNetworkPolicyFailure.invalidSignature) {
        try await policyChecker(mutation: .invalidSignature).verify(
            controlPlaneHost: "control.example.test",
            now: policyNow
        )
    }
    await #expect(throws: OutboundNetworkPolicyFailure.malformed) {
        try await policyChecker(mutation: .duplicateKey).verify(
            controlPlaneHost: "control.example.test",
            now: policyNow
        )
    }
}

@Test func signedOutboundPolicyRejectsStaleAndWrongProcessIdentityProofs() async throws {
    await #expect(throws: OutboundNetworkPolicyFailure.stale) {
        try await policyChecker(
            mutation: .observedAt(policyNow.addingTimeInterval(-31))
        ).verify(controlPlaneHost: "control.example.test", now: policyNow)
    }
    await #expect(throws: OutboundNetworkPolicyFailure.stale) {
        try await policyChecker(
            mutation: .expiresAt(policyNow.addingTimeInterval(-1))
        ).verify(controlPlaneHost: "control.example.test", now: policyNow)
    }
    await #expect(throws: OutboundNetworkPolicyFailure.identityMismatch) {
        try await policyChecker(mutation: .teamIdentifier("ZZ12CD34EF")).verify(
            controlPlaneHost: "control.example.test",
            now: policyNow
        )
    }
}

@Test func signedOutboundPolicyRejectsAnthropicAndAdditionalDestinations() async throws {
    for hosts in [
        ["control.example.test", "api.anthropic.com"],
        ["control.example.test", "extra.example.test"],
    ] {
        await #expect(throws: OutboundNetworkPolicyFailure.destinationMismatch) {
            try await policyChecker(mutation: .allowedHosts(hosts)).verify(
                controlPlaneHost: "control.example.test",
                now: policyNow
            )
        }
    }
}

@Test func signedOutboundPolicyRejectsDisabledEnforcementAndTimeout() async throws {
    await #expect(throws: OutboundNetworkPolicyFailure.notEnforced) {
        try await policyChecker(mutation: .policyDisabled).verify(
            controlPlaneHost: "control.example.test",
            now: policyNow
        )
    }
    let key = Curve25519.Signing.PrivateKey()
    let checker = try SignedOutboundNetworkPolicyChecker(
        loader: HangingAttestationLoader(),
        publicKey: key.publicKey.rawRepresentation,
        teamIdentifier: policyTeamIdentifier,
        policyIdentifier: policyIdentifier,
        timeout: .milliseconds(10)
    )
    await #expect(throws: OutboundNetworkPolicyFailure.timedOut) {
        try await checker.verify(controlPlaneHost: "control.example.test", now: policyNow)
    }
}
