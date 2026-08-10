import Crypto
import DeviceServices
import DeviceIPC
import DeviceSecurity
import Foundation
import Testing

private actor RecordingHTTPTransport: NetworkBrokerHTTPTransport {
    private var responses: [(Data, Int)]
    private(set) var requests: [URLRequest] = []

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes _: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (data, status) = responses.removeFirst()
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor ApprovalRecoveryHTTPTransport: NetworkBrokerHTTPTransport {
    enum Step {
        case response(Data, Int)
        case failure(URLError)
    }

    private var steps: [Step]
    private(set) var requests: [URLRequest] = []

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes _: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        switch steps.removeFirst() {
        case let .failure(error):
            throw error
        case let .response(data, status):
            let response = try #require(HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ))
            return (data, response)
        }
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor AsyncTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor RotationRaceHTTPTransport: NetworkBrokerHTTPTransport {
    private var responses: [(Data, Int)]
    private var requests: [URLRequest] = []
    private let deviceConnectedStarted = AsyncTestGate()
    private let releaseDeviceConnected = AsyncTestGate()

    init(responses: [(Data, Int)]) {
        self.responses = responses
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes _: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if request.url?.path.hasSuffix("/device-connected") == true,
           requests.filter({ $0.url?.path.hasSuffix("/device-connected") == true }).count == 2
        {
            await deviceConnectedStarted.open()
            await releaseDeviceConnected.wait()
        }
        let (data, status) = responses.removeFirst()
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    func waitUntilRotatedDeviceConnectedStarts() async {
        await deviceConnectedStarted.wait()
    }

    func resumeRotatedDeviceConnected() async {
        await releaseDeviceConnected.open()
    }

    func recordedRequests() -> [URLRequest] { requests }
}

private actor RenewalRotationRaceHTTPTransport: NetworkBrokerHTTPTransport {
    private var responses: [String: [(Data, Int)]]
    private var requests: [URLRequest] = []
    private let firstRenewalStarted = AsyncTestGate()
    private let releaseFirstRenewal = AsyncTestGate()
    private var renewalCount = 0

    init(responses: [String: [(Data, Int)]]) {
        self.responses = responses
    }

    func send(
        _ request: URLRequest,
        maximumResponseBytes _: Int
    ) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let path = try #require(request.url?.path)
        let route = try #require(Self.route(for: path))
        var queued = try #require(responses[route])
        let (data, status) = queued.removeFirst()
        responses[route] = queued
        if route == "renew" {
            renewalCount += 1
            if renewalCount == 1 {
                await firstRenewalStarted.open()
                await releaseFirstRenewal.wait()
            }
        }
        let response = try #require(HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        ))
        return (data, response)
    }

    func waitUntilFirstRenewalStarts() async {
        await firstRenewalStarted.wait()
    }

    func resumeFirstRenewal() async {
        await releaseFirstRenewal.open()
    }

    func recordedRequests() -> [URLRequest] { requests }

    private static func route(for path: String) -> String? {
        if path.hasSuffix("/device-inbox") { return "inbox" }
        if path.hasSuffix("/device-connected") { return "device-connected" }
        if path.hasSuffix("/approve") { return "approve" }
        if path.hasSuffix("/abort") { return "abort" }
        if path.hasSuffix("/renew") { return "renew" }
        return nil
    }
}

private let controlPlaneDeviceID = "2cb933ce-b922-4ed7-b479-6ded90f09d2d"
private let controlPlaneToken = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

private struct StaticCredentialLoader: NetworkBrokerCredentialLoading {
    let credential: NetworkBrokerCredential

    func loadCredential(now _: Date) throws -> NetworkBrokerCredential {
        credential
    }
}

private actor SequencedOutboundPolicyChecker: OutboundNetworkPolicyChecking {
    private let failingCall: Int?
    private var calls = 0

    init(failingCall: Int? = nil) {
        self.failingCall = failingCall
    }

    func verify(controlPlaneHost _: String, now _: Date) async throws {
        calls += 1
        if calls == failingCall {
            throw OutboundNetworkPolicyFailure.notEnforced
        }
    }

    func callCount() -> Int { calls }
}

private func brokerCredential() throws -> NetworkBrokerCredential {
    try NetworkBrokerCredential(
        schemaVersion: 1,
        serverURL: "https://control.example.test",
        deviceID: controlPlaneDeviceID,
        accessToken: controlPlaneToken,
        expiresAtUnix: 4_000_100_000,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
}

private func sessionJSON(
    status: String = "pending_device",
    deviceID: String = controlPlaneDeviceID,
    generation: UInt64 = 1,
    leaseUntil: String = "null",
    lockAcquiredAt: String = "null",
    stoppedAt: String = "null",
    stopReason: String = "null",
    extra: String = ""
) -> String {
    """
    {
      "id":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      "user_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      "device_id":"\(deviceID)",
      "tool_session_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "node_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      "platform":"macos",
      "status":"\(status)",
      "generation":\(generation),
      "lease_until":\(leaseUntil),
      "expires_at":"2099-12-31T00:00:00Z",
      "lock_acquired_at":\(lockAcquiredAt),
      "stopped_at":\(stoppedAt),
      "stop_reason":\(stopReason),
      "created_at":"2099-01-01T00:00:00Z"\(extra)
    }
    """
}

private func candidateJSON(currentDevice: String = "null") -> String {
    """
    {
      "tool_session_id":"cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "tool_type":"claude",
      "tool_account_id":"eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
      "workspace_id":"ffffffff-ffff-4fff-8fff-ffffffffffff",
      "project_key":"Workspace",
      "display_name":"Workspace",
      "status":"running",
      "node_id":"dddddddd-dddd-4ddd-8ddd-dddddddddddd",
      "runtime_backend":"native",
      "current_device_id":\(currentDevice),
      "current_device_name":null,
      "device_session_id":null,
      "controllable":true
    }
    """
}

private func approval(for session: ControlPlaneDeviceSession) -> LocalApproval {
    LocalApproval(
        application: ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari",
            signingIdentifier: "com.apple.Safari"
        ),
        controlLevel: .viewOnly,
        clipboardAllowed: false,
        generation: session.generation
    )
}

private func relayMaterialJSON(
    status: String,
    relayPath: String = "null",
    relayTicket: String = "null",
    peerSPKI: String = "null",
    exporterContext: String = "null",
    expiresAt: String = "null"
) -> String {
    """
    {"data":{
      "status":"\(status)","role":"device","generation":1,
      "relay_path":\(relayPath),"relay_ticket":\(relayTicket),
      "peer_spki_sha256":\(peerSPKI),"exporter_context":\(exporterContext),
      "expires_at":\(expiresAt)
    },"request_id":null}
    """
}

@Test func deviceInboxUsesOnlyTheFixedAuthenticatedPathAndBinding() async throws {
    let body = try #require(
        """
        {"data":{"items":[\(sessionJSON())]},"request_id":"request-1"}
        """.data(using: .utf8)
    )
    let transport = RecordingHTTPTransport(responses: [(body, 200)])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let sessions = try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000))
    #expect(sessions.count == 1)
    #expect(sessions[0].deviceID.uuidString.lowercased() == controlPlaneDeviceID)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests[0].url?.absoluteString == "https://control.example.test/api/v1/device-sessions/device-inbox")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer \(controlPlaneToken)")
}

@Test func candidatesAreStrictlyDecodedAndClaimUsesOnlyToolSessionID() async throws {
    let candidatesBody = try #require(
        "{\"data\":{\"items\":[\(candidateJSON())]},\"request_id\":null}"
            .data(using: .utf8)
    )
    let pendingSession = sessionJSON(status: "pending_device")
    let claimedBody = try #require(
        "{\"data\":\(pendingSession),\"request_id\":null}".data(using: .utf8)
    )
    let transport = RecordingHTTPTransport(responses: [
        (candidatesBody, 200),
        (claimedBody, 200),
    ])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let candidates = try await client.sessionCandidates(
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(candidates.count == 1)
    let claimed = try await client.claim(
        toolSessionID: candidates[0].toolSessionID,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(claimed.toolSessionID == candidates[0].toolSessionID)
    let requests = await transport.recordedRequests()
    #expect(requests[0].url?.path.hasSuffix("/device-sessions/candidates") == true)
    #expect(requests[1].url?.path.hasSuffix("/device-sessions/claim") == true)
    let claimBody = try #require(requests[1].httpBody)
    let claimObject = try #require(
        JSONSerialization.jsonObject(with: claimBody) as? [String: Any]
    )
    #expect(claimObject.count == 1)
    #expect((claimObject["tool_session_id"] as? String)?.lowercased()
        == "cccccccc-cccc-4ccc-8ccc-cccccccccccc")
}

@Test func markConnectedRequiresTheExactReturnedBindingAndStatus() async throws {
    let inbox = try #require(
        "{\"data\":{\"items\":[\(sessionJSON())]},\"request_id\":null}".data(using: .utf8)
    )
    let connected = try #require(
        "{\"data\":\(sessionJSON(status: "pending_user_approval")),\"request_id\":null}"
            .data(using: .utf8)
    )
    let transport = RecordingHTTPTransport(responses: [(inbox, 200), (connected, 200)])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let session = try #require(
        try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000)).first
    )
    let result = try await client.markDeviceConnected(
        session,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(result.status == .pendingUserApproval)
    let requests = await transport.recordedRequests()
    #expect(requests[1].httpMethod == "POST")
    #expect(requests[1].url?.path.hasSuffix("/device-connected") == true)
    #expect(String(data: requests[1].httpBody!, encoding: .utf8)?.contains("\"generation\":1") == true)
}

@Test func inboxRejectsCrossDeviceTerminalAndUnknownFieldResponses() async throws {
    let otherDevice = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
    for item in [
        sessionJSON(deviceID: otherDevice),
        sessionJSON(status: "stopped"),
        sessionJSON(extra: ",\"endpoint\":\"https://evil.test\""),
    ] {
        let body = try #require(
            "{\"data\":{\"items\":[\(item)]},\"request_id\":null}".data(using: .utf8)
        )
        let transport = RecordingHTTPTransport(responses: [(body, 200)])
        let client = try NetworkBrokerControlPlaneClient(
            credential: brokerCredential(),
            transport: transport,
            now: Date(timeIntervalSince1970: 4_000_000_000)
        )
        await #expect(throws: Error.self) {
            try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000))
        }
    }
}

@Test func approveSendsOnlyLocalApprovalDigestsAndRequiresServerLease() async throws {
    let pendingBody = try #require(
        "{\"data\":{\"items\":[\(sessionJSON(status: "pending_user_approval"))]},\"request_id\":null}"
            .data(using: .utf8)
    )
    let activeBody = try #require(
        "{\"data\":\(sessionJSON(status: "active", leaseUntil: "\"2099-12-30T23:59:00Z\"")),\"request_id\":null}"
            .data(using: .utf8)
    )
    let transport = RecordingHTTPTransport(responses: [(pendingBody, 200), (activeBody, 200)])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let session = try #require(
        try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000)).first
    )
    let localApproval = approval(for: session)
    let active = try await client.approve(
        session,
        approvals: [localApproval],
        result: .allowed,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )

    #expect(active.status == .active)
    #expect(active.leaseUntil != nil)
    let requests = await transport.recordedRequests()
    let body = try #require(requests[1].httpBody)
    let object = try #require(
        JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    #expect(Set(object.keys) == ["generation", "approvals"])
    let items = try #require(object["approvals"] as? [[String: Any]])
    #expect(Set(try #require(items.first).keys) == [
        "application_digest", "control_level", "approval_result", "clipboard_allowed",
    ])
    #expect(items[0]["application_digest"] as? String == localApproval.application.stableDigest)
    #expect(!String(data: body, encoding: .utf8)!.contains("com.apple.Safari"))
}

@Test func denialSendsAClosedApprovalAndRequiresDeniedWithoutLease() async throws {
    let pending = sessionJSON(status: "pending_user_approval")
    let denied = sessionJSON(status: "denied", stopReason: "\"user_denied\"")
    let transport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(pending)]},\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(denied),\"request_id\":null}".utf8), 200),
    ])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let session = try #require(
        try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000)).first
    )
    let result = try await client.approve(
        session,
        approvals: [approval(for: session)],
        result: .denied,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )

    #expect(result.status == .denied)
    #expect(result.leaseUntil == nil)
    let requests = await transport.recordedRequests()
    let body = try #require(requests[1].httpBody)
    let text = try #require(String(data: body, encoding: .utf8))
    #expect(requests[1].url?.path.hasSuffix("/approve") == true)
    #expect(text.contains("\"approval_result\":\"denied\""))
    #expect(text.contains("\"clipboard_allowed\":false"))
}

@Test func lockRenewAbortAndStopEnforceLifecycleBindings() async throws {
    let initialLease = "\"2099-12-30T23:57:00Z\""
    let renewedLease = "\"2099-12-30T23:59:00Z\""
    let lockTime = "\"2096-10-02T07:06:40Z\""
    let active = sessionJSON(status: "active", leaseUntil: initialLease)
    let locked = sessionJSON(
        status: "active",
        leaseUntil: initialLease,
        lockAcquiredAt: lockTime
    )
    let renewed = sessionJSON(
        status: "active",
        leaseUntil: renewedLease,
        lockAcquiredAt: lockTime
    )
    let rotated = sessionJSON(status: "pending_device", generation: 2)
    let stopped = sessionJSON(
        status: "stopped",
        generation: 3,
        stoppedAt: "\"2090-01-01T00:00:00Z\"",
        stopReason: "\"session_end\""
    )
    let transport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(active)]},\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(locked),\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(renewed),\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(rotated),\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(stopped),\"request_id\":null}".utf8), 200),
    ])
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: now
    )
    let session = try #require(try await client.deviceInbox(now: now).first)
    let withLock = try await client.acquireLock(session, now: now)
    let withRenewedLease = try await client.renew(withLock, now: now)
    let nextGeneration = try await client.abort(
        withRenewedLease,
        reason: .disconnect,
        now: now
    )
    let terminal = try await client.stop(nextGeneration, now: now)

    #expect(withLock.lockAcquiredAt != nil)
    #expect(try #require(withRenewedLease.leaseUntil) >= #require(withLock.leaseUntil))
    #expect(nextGeneration.generation == session.generation + 1)
    #expect(nextGeneration.status == .pendingDevice)
    #expect(terminal.status == .stopped)
    let requests = await transport.recordedRequests()
    #expect(requests.map { $0.url?.lastPathComponent } == [
        "device-inbox", "lock", "renew", "abort", "stop",
    ])
    for index in 1 ... 3 {
        let body = try #require(requests[index].httpBody)
        let object = try #require(JSONSerialization.jsonObject(
            with: body
        ) as? [String: Any])
        let expected = index == 3 ? Set(["generation", "reason"]) : Set(["generation"])
        #expect(Set(object.keys) == expected)
    }
    let encodedStopBody = try #require(requests[4].httpBody)
    let stopBody = try #require(JSONSerialization.jsonObject(
        with: encodedStopBody
    ) as? [String: Any])
    #expect(stopBody as? [String: String] == ["reason": "session_end"])
}

@Test func stopAcceptsServerTimestampRecordedAfterRequestStarted() async throws {
    let requestTime = Date(timeIntervalSince1970: 4_000_000_000)
    let responseTime = requestTime.addingTimeInterval(1)
    let serverStopTime = responseTime.addingTimeInterval(1)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let stopped = sessionJSON(
        status: "stopped",
        generation: 2,
        stoppedAt: "\"\(formatter.string(from: serverStopTime))\"",
        stopReason: "\"session_end\""
    )
    let transport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(active)]},\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(stopped),\"request_id\":null}".utf8), 200),
    ])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        nowProvider: { responseTime },
        now: requestTime
    )
    let session = try #require(try await client.deviceInbox(now: requestTime).first)

    let terminal = try await client.stop(session, now: requestTime)

    #expect(terminal.status == .stopped)
    #expect(terminal.stoppedAt == serverStopTime)
}

@Test func controlPlaneRejectsOutOfRangeAndExhaustedGenerationsBeforeMutation() async throws {
    let maximumActive = UInt64(Int64.max) - 1
    let outOfRange = sessionJSON(generation: UInt64(Int64.max) + 1)
    let transport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(outOfRange)]},\"request_id\":null}".utf8), 200),
    ])
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: now
    )
    await #expect(throws: NetworkBrokerControlPlaneFailure.invalidResponse) {
        try await client.deviceInbox(now: now)
    }

    let exhausted = sessionJSON(
        status: "active",
        generation: maximumActive,
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let stopped = sessionJSON(
        status: "stopped",
        generation: UInt64(Int64.max),
        stoppedAt: "\"2090-01-01T00:00:00Z\"",
        stopReason: "\"session_end\""
    )
    let exhaustedTransport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(exhausted)]},\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(stopped),\"request_id\":null}".utf8), 200),
    ])
    let exhaustedClient = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: exhaustedTransport,
        now: now
    )
    let session = try #require(try await exhaustedClient.deviceInbox(now: now).first)
    await #expect(throws: NetworkBrokerControlPlaneFailure.bindingMismatch) {
        try await exhaustedClient.abort(session, reason: .disconnect, now: now)
    }
    #expect(await exhaustedTransport.recordedRequests().count == 1)
    let terminal = try await exhaustedClient.stop(session, now: now)
    #expect(terminal.generation == UInt64(Int64.max))
    #expect(terminal.status == .stopped)
}

@Test func discoveryCrossChecksPendingBindingBeforeApproving() async throws {
    let inboxBody = try #require(
        "{\"data\":{\"items\":[\(sessionJSON())]},\"request_id\":null}"
            .data(using: .utf8)
    )
    let connectedBody = try #require(
        "{\"data\":\(sessionJSON(status: "pending_user_approval")),\"request_id\":null}"
            .data(using: .utf8)
    )
    let activeBody = try #require(
        "{\"data\":\(sessionJSON(status: "active", leaseUntil: "\"2099-12-30T23:59:00Z\"")),\"request_id\":null}"
            .data(using: .utf8)
    )
    let transport = RecordingHTTPTransport(
        responses: [(inboxBody, 200), (connectedBody, 200), (activeBody, 200)]
    )
    let policyChecker = SequencedOutboundPolicyChecker(failingCall: 2)
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: policyChecker
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let pending = try #require(try await coordinator.nextPendingSession(now: now))
    let decision = BrokerApprovalDecision(
        binding: pending.binding,
        approvals: [LocalApproval(
            application: ApplicationIdentity(
                bundleIdentifier: "com.apple.Safari",
                signingIdentifier: "com.apple.Safari"
            ),
            controlLevel: .viewOnly,
            clipboardAllowed: false,
            generation: pending.binding.generation
        )],
        result: .allowed
    )
    var wrongBinding = pending.binding
    wrongBinding = DeviceSessionBinding(
        userID: wrongBinding.userID,
        deviceID: UUID(),
        toolSessionID: wrongBinding.toolSessionID,
        deviceSessionID: wrongBinding.deviceSessionID,
        nodeID: wrongBinding.nodeID,
        platform: wrongBinding.platform,
        generation: wrongBinding.generation
    )
    await #expect(throws: NetworkBrokerControlPlaneFailure.bindingMismatch) {
        try await coordinator.approve(
            BrokerApprovalDecision(
                binding: wrongBinding,
                approvals: decision.approvals,
                result: .allowed
            ),
            now: now
        )
    }
    let configuration = try #require(try await coordinator.approve(decision, now: now))
    #expect(configuration.binding == pending.binding)
    #expect(configuration.approvals == decision.approvals)
    #expect(configuration.leaseUntil > now)
    #expect(await policyChecker.callCount() == 1)
    await #expect(throws: OutboundNetworkPolicyFailure.notEnforced) {
        try await coordinator.establishRelay(configuration, now: now)
    }
    #expect(await policyChecker.callCount() == 2)
    #expect(await transport.recordedRequests().count == 3)
}

@Test func discoveryReconcilesApprovalAfterResponseTimeout() async throws {
    let pending = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let transport = ApprovalRecoveryHTTPTransport(steps: [
        .response(inbox(pending), 200),
        .failure(URLError(.timedOut)),
        .response(inbox(active), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let approval = LocalApproval(
        application: ApplicationIdentity(
            bundleIdentifier: "com.openai.codex",
            signingIdentifier: "com.openai.codex"
        ),
        controlLevel: .fullControl,
        clipboardAllowed: false,
        generation: 1
    )
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    let configuration = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [approval],
            result: .allowed
        ),
        now: now
    ))

    #expect(configuration.binding == discovered.binding)
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.url?.path) == [
        "/api/v1/device-sessions/device-inbox",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/approve",
        "/api/v1/device-sessions/device-inbox",
    ])
}

@Test func discoveryRetriesApprovalOnceWhenTimeoutDidNotCommit() async throws {
    let pending = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = ApprovalRecoveryHTTPTransport(steps: [
        .response(inbox(pending), 200),
        .failure(URLError(.networkConnectionLost)),
        .response(inbox(pending), 200),
        .response(response(active), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    _ = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    signingIdentifier: "com.google.Chrome"
                ),
                controlLevel: .fullControl,
                clipboardAllowed: false,
                generation: 1
            )],
            result: .allowed
        ),
        now: now
    ))

    let requests = await transport.recordedRequests()
    #expect(requests.filter { $0.url?.path.hasSuffix("/approve") == true }.count == 2)
}

@Test func discoveryDoesNotPollWhileLocalBindingIsActive() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-31T00:00:00Z\""
    )
    let rotated = sessionJSON(status: "pending_device", generation: 2)
    let rotatedConnected = sessionJSON(status: "pending_user_approval", generation: 2)
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RecordingHTTPTransport(responses: [
        (inbox(pending), 200),
        (response(connected), 200),
        (response(active), 200),
        (inbox(active), 200),
        (response(rotated), 200),
        (response(rotatedConnected), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let original = try #require(try await coordinator.nextPendingSession(now: now))
    let localApproval = LocalApproval(
        application: ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari",
            signingIdentifier: "com.apple.Safari"
        ),
        controlLevel: .viewOnly,
        clipboardAllowed: false,
        generation: original.binding.generation
    )
    _ = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: original.binding,
            approvals: [localApproval],
            result: .allowed
        ),
        now: now
    ))

    let polled = try await coordinator.nextPendingSession(now: now)

    #expect(polled == nil)
    #expect(await transport.recordedRequests().count == 3)
}

@Test func discoveryReconnectsPendingGenerationAfterRelayFailureAbort() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let rotatedPending = sessionJSON(status: "pending_device", generation: 2)
    let rotatedConnected = sessionJSON(status: "pending_user_approval", generation: 2)
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RecordingHTTPTransport(responses: [
        (inbox(pending), 200),
        (response(connected), 200),
        (response(active), 200),
        (response(rotatedPending), 200),
        (inbox(rotatedPending), 200),
        (response(rotatedConnected), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    let configuration = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    signingIdentifier: "com.google.Chrome"
                ),
                controlLevel: .fullControl,
                clipboardAllowed: true,
                generation: 1
            )],
            result: .allowed
        ),
        now: now
    ))

    let aborted = try await coordinator.abort(
        BrokerAbortRequest(binding: configuration.binding, reason: .disconnect),
        now: now
    )
    let recovered = try #require(try await coordinator.nextPendingSession(now: now))

    #expect(aborted.binding.generation == 2)
    #expect(recovered.binding.generation == 2)
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.url?.path) == [
        "/api/v1/device-sessions/device-inbox",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/device-connected",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/approve",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/abort",
        "/api/v1/device-sessions/device-inbox",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/device-connected",
    ])
}

@Test func discoveryRotatesAnActiveGenerationWithoutNewUserApproval() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let rotatedPending = sessionJSON(status: "pending_device", generation: 2)
    let rotatedConnected = sessionJSON(status: "pending_user_approval", generation: 2)
    let rotatedActive = sessionJSON(
        status: "active",
        generation: 2,
        leaseUntil: "\"2099-12-30T23:59:30Z\""
    )
    let inbox = Data("{\"data\":{\"items\":[\(pending)]},\"request_id\":null}".utf8)
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RecordingHTTPTransport(responses: [
        (inbox, 200),
        (response(connected), 200),
        (response(active), 200),
        (response(rotatedPending), 200),
        (response(rotatedConnected), 200),
        (response(rotatedActive), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    let configuration = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    signingIdentifier: "com.google.Chrome"
                ),
                controlLevel: .fullControl,
                clipboardAllowed: true,
                generation: 1
            )],
            result: .allowed
        ),
        now: now
    ))

    let rotated = try await coordinator.rotate(configuration, now: now)

    #expect(rotated.binding.generation == 2)
    #expect(rotated.approvals.count == 1)
    #expect(rotated.approvals[0].generation == 2)
    #expect(rotated.approvals[0].application == configuration.approvals[0].application)
    #expect(rotated.approvals[0].clipboardAllowed)
    let requests = await transport.recordedRequests()
    #expect(requests.map(\.url?.path).compactMap { $0 }.suffix(3) == [
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/abort",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/device-connected",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/approve",
    ])
    let approvalBody = try #require(requests.last?.httpBody)
    let approvalObject = try #require(
        JSONSerialization.jsonObject(with: approvalBody) as? [String: Any]
    )
    #expect(approvalObject["generation"] as? UInt64 == 2)
}

@Test func discoveryPollingCannotConsumeGenerationOwnedByRotation() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let rotatedPending = sessionJSON(status: "pending_device", generation: 2)
    let rotatedConnected = sessionJSON(status: "pending_user_approval", generation: 2)
    let rotatedActive = sessionJSON(
        status: "active",
        generation: 2,
        leaseUntil: "\"2099-12-30T23:59:30Z\""
    )
    let inbox = Data("{\"data\":{\"items\":[\(pending)]},\"request_id\":null}".utf8)
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RotationRaceHTTPTransport(responses: [
        (inbox, 200),
        (response(connected), 200),
        (response(active), 200),
        (response(rotatedPending), 200),
        (response(rotatedConnected), 200),
        (response(rotatedActive), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    let configuration = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    signingIdentifier: "com.google.Chrome"
                ),
                controlLevel: .fullControl,
                clipboardAllowed: true,
                generation: 1
            )],
            result: .allowed
        ),
        now: now
    ))

    let rotation = Task { try await coordinator.rotate(configuration, now: now) }
    await transport.waitUntilRotatedDeviceConnectedStarts()

    let polledDuringRotation = try await coordinator.nextPendingSession(now: now)
    #expect(polledDuringRotation == nil)

    await transport.resumeRotatedDeviceConnected()
    let rotated = try await rotation.value
    #expect(rotated.binding.generation == 2)
    #expect(rotated.approvals.map(\.generation) == [2])
    let requests = await transport.recordedRequests()
    #expect(requests.count == 6)
    #expect(requests.filter { $0.url?.path.hasSuffix("/device-inbox") == true }.count == 1)
    #expect(requests.filter { $0.url?.path.hasSuffix("/device-connected") == true }.count == 2)
}

@Test func staleSlowRenewalCannotOverwriteARotatedGeneration() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let staleRenewed = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:10Z\""
    )
    let rotatedPending = sessionJSON(status: "pending_device", generation: 2)
    let rotatedConnected = sessionJSON(status: "pending_user_approval", generation: 2)
    let rotatedActive = sessionJSON(
        status: "active",
        generation: 2,
        leaseUntil: "\"2099-12-30T23:59:30Z\""
    )
    let rotatedRenewed = sessionJSON(
        status: "active",
        generation: 2,
        leaseUntil: "\"2099-12-30T23:59:40Z\""
    )
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RenewalRotationRaceHTTPTransport(responses: [
        "inbox": [(inbox(pending), 200)],
        "device-connected": [(response(connected), 200), (response(rotatedConnected), 200)],
        "approve": [(response(active), 200), (response(rotatedActive), 200)],
        "abort": [(response(rotatedPending), 200)],
        "renew": [(response(staleRenewed), 200), (response(rotatedRenewed), 200)],
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let discovered = try #require(try await coordinator.nextPendingSession(now: now))
    let configuration = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: discovered.binding,
            approvals: [LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.google.Chrome",
                    signingIdentifier: "com.google.Chrome"
                ),
                controlLevel: .fullControl,
                clipboardAllowed: true,
                generation: 1
            )],
            result: .allowed
        ),
        now: now
    ))

    let staleRenewal = Task { try await coordinator.renew(configuration, now: now) }
    await transport.waitUntilFirstRenewalStarts()
    let rotated = try await coordinator.rotate(configuration, now: now)
    #expect(rotated.binding.generation == 2)
    await transport.resumeFirstRenewal()
    do {
        _ = try await staleRenewal.value
        Issue.record("stale generation renewal unexpectedly succeeded")
    } catch let failure as NetworkBrokerControlPlaneFailure {
        #expect(failure == .bindingMismatch)
    }

    let renewedRotation = try await coordinator.renew(rotated, now: now)
    #expect(renewedRotation.binding.generation == 2)
    #expect(renewedRotation.leaseUntil > rotated.leaseUntil)
    let requests = await transport.recordedRequests()
    #expect(requests.filter { $0.url?.path.hasSuffix("/renew") == true }.count == 2)
}

@Test func discoveryRotatesAnActiveGenerationAfterBrokerRestart() async throws {
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let pending = sessionJSON(status: "pending_device", generation: 2)
    let connected = sessionJSON(status: "pending_user_approval", generation: 2)
    let transport = RecordingHTTPTransport(responses: [
        (Data("{\"data\":{\"items\":[\(active)]},\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(pending),\"request_id\":null}".utf8), 200),
        (Data("{\"data\":\(connected),\"request_id\":null}".utf8), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let recovered = try #require(try await coordinator.nextPendingSession(now: now))
    #expect(recovered.binding.generation == 2)
    let requests = await transport.recordedRequests()
    #expect(requests.count == 3)
    #expect(requests[0].url?.path.hasSuffix("/device-inbox") == true)
    #expect(requests[1].url?.path.hasSuffix("/abort") == true)
    #expect(requests[2].url?.path.hasSuffix("/device-connected") == true)
}

@Test func discoveryStopsLocalActiveBindingBeforeClaimingReplacement() async throws {
    let pending = sessionJSON(status: "pending_device")
    let connected = sessionJSON(status: "pending_user_approval")
    let active = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let stopped = sessionJSON(
        status: "stopped",
        generation: 2,
        stoppedAt: "\"2096-01-01T00:00:00Z\"",
        stopReason: "\"session_end\""
    )
    let inbox = { (session: String) in
        Data("{\"data\":{\"items\":[\(session)]},\"request_id\":null}".utf8)
    }
    let response = { (session: String) in
        Data("{\"data\":\(session),\"request_id\":null}".utf8)
    }
    let transport = RecordingHTTPTransport(responses: [
        (inbox(pending), 200),
        (response(connected), 200),
        (response(active), 200),
        (response(stopped), 200),
        (response(pending), 200),
        (inbox(pending), 200),
        (response(connected), 200),
    ])
    let coordinator = NetworkBrokerDiscoveryCoordinator(
        credentialLoader: StaticCredentialLoader(credential: try brokerCredential()),
        transport: transport,
        outboundPolicyChecker: SequencedOutboundPolicyChecker()
    )
    let now = Date(timeIntervalSince1970: 4_000_000_000)
    let original = try #require(try await coordinator.nextPendingSession(now: now))
    let approval = LocalApproval(
        application: ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari",
            signingIdentifier: "com.apple.Safari"
        ),
        controlLevel: .viewOnly,
        clipboardAllowed: false,
        generation: original.binding.generation
    )
    _ = try #require(try await coordinator.approve(
        BrokerApprovalDecision(
            binding: original.binding,
            approvals: [approval],
            result: .allowed
        ),
        now: now
    ))
    _ = try await coordinator.claim(
        BrokerClaimRequest(toolSessionID: original.binding.toolSessionID),
        now: now
    )

    let requests = await transport.recordedRequests()
    #expect(requests.map(\.url?.path).compactMap { $0 }.suffix(4) == [
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/stop",
        "/api/v1/device-sessions/claim",
        "/api/v1/device-sessions/device-inbox",
        "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/device-connected",
    ])
}

@Test func relayMaterialRequiresTheFixedPathAndCompleteOneTimeValues() async throws {
    let activeSession = sessionJSON(
        status: "active",
        leaseUntil: "\"2099-12-30T23:59:00Z\""
    )
    let inbox = try #require(
        "{\"data\":{\"items\":[\(activeSession)]},\"request_id\":null}"
            .data(using: .utf8)
    )
    let waiting = try #require(relayMaterialJSON(status: "waiting").data(using: .utf8))
    let digest = String(repeating: "ab", count: 32)
    let context = String(repeating: "cd", count: 32)
    let expectedPath = "/api/v1/device-sessions/aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/relay"
    let ready = try #require(relayMaterialJSON(
        status: "ready",
        relayPath: "\"\(expectedPath)\"",
        relayTicket: "\"drelay_abcdefghijklmnopqrstuvwxyz0123456789\"",
        peerSPKI: "\"\(digest)\"",
        exporterContext: "\"\(context)\"",
        expiresAt: "\"2099-12-30T23:59:00Z\""
    ).data(using: .utf8))
    let transport = RecordingHTTPTransport(responses: [
        (inbox, 200), (waiting, 200), (ready, 200),
    ])
    let client = try NetworkBrokerControlPlaneClient(
        credential: brokerCredential(),
        transport: transport,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    let session = try #require(
        try await client.deviceInbox(now: Date(timeIntervalSince1970: 4_000_000_000)).first
    )
    let first = try await client.registerRelayMaterial(
        session,
        spkiSHA256: digest,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(first.status == .waiting)
    let second = try await client.registerRelayMaterial(
        session,
        spkiSHA256: digest,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(second.status == .ready)
    #expect(second.relayPath == expectedPath)
    #expect(second.peerSPKISHA256 == digest)
    #expect(second.exporterContext == context)
    let relayRequest = try client.relayRequest(
        session,
        material: second,
        now: Date(timeIntervalSince1970: 4_000_000_000)
    )
    #expect(relayRequest.url?.absoluteString == "wss://control.example.test\(expectedPath)")
    #expect(relayRequest.value(forHTTPHeaderField: "Authorization")
        == "Bearer drelay_abcdefghijklmnopqrstuvwxyz0123456789")
    #expect(relayRequest.value(forHTTPHeaderField: "Authorization")
        != "Bearer \(controlPlaneToken)")
    let requests = await transport.recordedRequests()
    #expect(requests[1].url?.path.hasSuffix("/relay-material") == true)
    #expect(requests[2].url?.path.hasSuffix("/relay-material") == true)
    #expect(String(data: try #require(requests[1].httpBody), encoding: .utf8)?
        .contains("\"spki_sha256\":\"\(digest)\"") == true)
}
