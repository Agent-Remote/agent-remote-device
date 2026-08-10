import Foundation
import Testing
import DeviceProtocol
import DeviceSecurity
@testable import DeviceIPC

@Test func ipcEnvelopeRoundTripsWithExactVersionAndRequestID() throws {
    let requestID = UUID()
    let envelope = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: Data("bounded payload".utf8)
    )
    let decoded = try DeviceIPCEnvelope.decode(envelope.encoded())

    #expect(decoded == envelope)
    #expect(decoded.requestID == requestID)
    #expect(decoded.version == DeviceIPCVersion.current)
}

@Test func ipcEnvelopeRejectsUnsupportedVersionsAndOversizedFrames() {
    #expect(throws: DeviceIPCFailure.incompatibleVersion) {
        try DeviceIPCEnvelope(version: 2, requestID: UUID(), payload: Data())
    }
    #expect(throws: DeviceIPCFailure.messageTooLarge) {
        try DeviceIPCEnvelope(
            requestID: UUID(),
            payload: Data(repeating: 0, count: DeviceIPCVersion.maximumMessageBytes + 1)
        )
    }
}

@Test func sessionBindingMatchesV1AndV2RequestContextsExactly() {
    let value = binding(generation: 7)
    let v1 = RequestContext(
        userID: value.userID,
        deviceID: value.deviceID,
        toolSessionID: value.toolSessionID,
        deviceSessionID: value.deviceSessionID,
        nodeID: value.nodeID,
        platform: value.platform,
        generation: value.generation,
        monotonicSequence: 1,
        currentScreenshotGeneration: 0
    )
    let v2 = RequestContextV2(
        userID: value.userID,
        deviceID: value.deviceID,
        toolSessionID: value.toolSessionID,
        deviceSessionID: value.deviceSessionID,
        nodeID: value.nodeID,
        platform: value.platform,
        generation: value.generation,
        monotonicSequence: 1,
        currentStateGeneration: 0,
        currentScreenshotGeneration: 0,
        baseStateID: nil
    )

    #expect(value.matches(v1))
    #expect(value.matches(v2))
    #expect(!binding(generation: 8).matches(v2))
    let nextGeneration = DeviceSessionBinding(
        userID: value.userID,
        deviceID: value.deviceID,
        toolSessionID: value.toolSessionID,
        deviceSessionID: value.deviceSessionID,
        nodeID: value.nodeID,
        platform: value.platform,
        generation: 8
    )
    #expect(value.matchesSessionIdentity(nextGeneration))
    let differentSession = DeviceSessionBinding(
        userID: value.userID,
        deviceID: value.deviceID,
        toolSessionID: value.toolSessionID,
        deviceSessionID: UUID(),
        nodeID: value.nodeID,
        platform: value.platform,
        generation: value.generation
    )
    #expect(!value.matchesSessionIdentity(differentSession))
}

@Test func ipcDecoderRejectsDuplicateAndUnknownFieldsAtEveryLevel() throws {
    let requestID = UUID()
    let encoded = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: Data("payload".utf8)
    ).encoded()
    var object = try #require(
        JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    object["endpoint"] = "https://unexpected.example"
    let unknownEnvelope = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try DeviceIPCEnvelope.decode(unknownEnvelope)
    }

    let duplicateEnvelope = Data(
        "{\"version\":1,\"version\":1,\"requestID\":\"\(requestID.uuidString)\",\"payload\":\"\"}"
            .utf8
    )
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try DeviceIPCEnvelope.decode(duplicateEnvelope)
    }

    let request = BrokerAbortRequest(binding: binding(generation: 1), reason: .disconnect)
    var requestObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    var bindingObject = try #require(requestObject["binding"] as? [String: Any])
    bindingObject["pid"] = 42
    requestObject["binding"] = bindingObject
    let unknownBinding = try JSONSerialization.data(withJSONObject: requestObject)
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try DeviceIPCDecoder.decode(BrokerAbortRequest.self, from: unknownBinding)
    }
}

@Test func peerPolicyBuildsAnExactNonWildcardRequirement() throws {
    let policy = try XPCPeerPolicy(
        bundleIdentifier: "dev.agentremote.device.network-broker",
        teamIdentifier: "AB12CD34EF"
    )

    #expect(policy.codeSigningRequirement.contains("identifier \"dev.agentremote.device.network-broker\""))
    #expect(policy.codeSigningRequirement.contains("subject.OU] = \"AB12CD34EF\""))
    #expect(!policy.codeSigningRequirement.contains("*"))
}

@Test func peerPolicyRejectsRequirementInjection() {
    #expect(throws: XPCPeerPolicyFailure.invalidIdentifier) {
        try XPCPeerPolicy(
            bundleIdentifier: "dev.agentremote.device\" or true",
            teamIdentifier: "AB12CD34EF"
        )
    }
    #expect(throws: XPCPeerPolicyFailure.invalidTeamIdentifier) {
        try XPCPeerPolicy(
            bundleIdentifier: "dev.agentremote.device",
            teamIdentifier: "not-a-team"
        )
    }
}

@Test func developmentPeerPolicyRemainsBoundToAnExactIdentifier() throws {
    let policy = try XPCPeerPolicy(
        bundleIdentifier: "dev.agentremote.device",
        teamIdentifier: "DEVELOPMENT"
    )

    #expect(policy.codeSigningRequirement == "identifier \"dev.agentremote.device\"")
}

@Test func communityPeerPolicyPinsTheExactCertificateAndIdentifier() throws {
    let fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567"
    let policy = try XPCPeerPolicy(
        bundleIdentifier: "dev.agentremote.device.network-broker",
        certificateSHA1: fingerprint
    )

    #expect(
        policy.codeSigningRequirement
            == "identifier \"dev.agentremote.device.network-broker\" and certificate leaf = H\"\(fingerprint)\""
    )
    #expect(!policy.codeSigningRequirement.contains("anchor apple"))
}

@Test func communityPeerPolicyRejectsMalformedCertificateFingerprints() {
    for fingerprint in [
        "0123456789ABCDEF",
        "0123456789abcdef0123456789abcdef01234567",
        "0123456789ABCDEF0123456789ABCDEF0123456G",
    ] {
        #expect(throws: XPCPeerPolicyFailure.invalidCertificateSHA1) {
            try XPCPeerPolicy(
                bundleIdentifier: "dev.agentremote.device.network-broker",
                certificateSHA1: fingerprint
            )
        }
    }
}

@Test func ipcMessagesRejectTheTerminalOnlyGeneration() {
    let binding = binding(generation: maximumDeviceSessionGeneration)
    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari",
        signingIdentifier: "com.apple.Safari"
    )
    let approval = LocalApproval(
        application: application,
        controlLevel: .viewOnly,
        clipboardAllowed: false,
        generation: maximumDeviceSessionGeneration
    )

    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try BrokerPendingSession(
            binding: binding,
            expiresAt: Date().addingTimeInterval(60)
        ).validate()
    }
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try BrokerApprovalDecision(
            binding: binding,
            approvals: [approval],
            result: .allowed
        ).validate()
    }
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try ExecutorSessionConfiguration(
            binding: binding,
            leaseUntil: Date().addingTimeInterval(60),
            approvals: [approval]
        ).validate()
    }
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try BrokerAbortRequest(binding: binding, reason: .disconnect).validate()
    }
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try BrokerEndRequest(binding: binding).validate()
    }
    #expect(throws: DeviceIPCFailure.invalidMessage) {
        try BrokerRuntimeEvent(binding: binding, kind: .sessionEnded).validate()
    }
}

@Test func ipcMessagesAcceptTheMaximumActiveGeneration() throws {
    try BrokerPendingSession(
        binding: binding(generation: maximumActiveDeviceSessionGeneration),
        expiresAt: Date().addingTimeInterval(60)
    ).validate()
}

private func binding(generation: UInt64) -> DeviceSessionBinding {
    DeviceSessionBinding(
        userID: UUID(),
        deviceID: UUID(),
        toolSessionID: UUID(),
        deviceSessionID: UUID(),
        nodeID: UUID(),
        platform: .macos,
        generation: generation
    )
}
