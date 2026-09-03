import DeviceIPC
@testable import DeviceServices
import Foundation
import Network
import Testing

private enum NestedRelayTestFailure: Error {
    case unavailable
}

@Test(.timeLimit(.minutes(1)))
func nestedTLSRelayCarriesActionsOnlyThroughOpaqueWebSocketBytes() async throws {
    let deviceIdentity = try NestedTLSGenerationIdentity.generate()
    let proxyIdentity = try NestedTLSGenerationIdentity.generate()
    let context = String(repeating: "ab", count: 32)
    let generation: UInt64 = 7
    let binding = DeviceSessionBinding(
        userID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
        deviceID: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
        toolSessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
        deviceSessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
        nodeID: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
        platform: .macos,
        generation: generation
    )
    let deviceMaterial = try NestedTLSGenerationMaterial(
        generation: generation,
        expectedPeerSPKISHA256Hex: proxyIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let proxyMaterial = try NestedTLSGenerationMaterial(
        generation: generation,
        expectedPeerSPKISHA256Hex: deviceIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let deviceInbox = MemoryWebSocketInbox()
    let proxyInbox = MemoryWebSocketInbox()
    let deviceWebSocket = MemoryWebSocket(
        inbox: deviceInbox,
        peerInbox: proxyInbox,
        sendDelay: .milliseconds(100)
    )
    let proxyWebSocket = MemoryWebSocket(inbox: proxyInbox, peerInbox: deviceInbox)

    async let establishedRelay = NetworkBrokerNestedTLSRelay.establish(
        identity: deviceIdentity,
        material: deviceMaterial,
        binding: binding,
        websocket: deviceWebSocket
    )
    let proxyConnection = try await makeProxyTLSConnection(
        identity: proxyIdentity,
        material: proxyMaterial,
        websocket: proxyWebSocket
    )
    try await confirmProxy(
        proxyConnection,
        material: proxyMaterial,
        binding: binding
    )
    let relay = try await establishedRelay
    let handled = TestRelayRecorder()
    let expectedResponse = Data(repeating: 0xA5, count: 6 * 1_024 * 1_024)
    let relayTask = Task {
        try await relay.run(
            actionHandler: { envelopeData in
                let envelope = try DeviceIPCEnvelope.decode(envelopeData)
                await handled.record(envelope)
                return expectedResponse
            },
            lifecycleHandler: { event in await handled.record(event) }
        )
    }

    let requestID = "20000000-0000-4000-8000-000000000001"
    let request = Data(
        """
        {"request":{"version":1,"request_id":"\(requestID)","context":{
        "user_id":"10000000-0000-4000-8000-000000000001",
        "device_id":"10000000-0000-4000-8000-000000000002",
        "tool_session_id":"10000000-0000-4000-8000-000000000003",
        "device_session_id":"10000000-0000-4000-8000-000000000004",
        "node_id":"10000000-0000-4000-8000-000000000005","platform":"macos",
        "generation":7,"monotonic_sequence":1,"current_screenshot_generation":0},
        "lease_until":"2099-12-30T23:59:00Z","action":{"type":"screenshot"}}}
        """.utf8
    )
    try await sendTestFrame(request, over: proxyConnection)
    let response = try await receiveTestFrame(from: proxyConnection)

    #expect(response == expectedResponse)
    let pushedFrameCount = await proxyInbox.pushedFrameCount
    #expect(pushedFrameCount <= 5, "sent \(pushedFrameCount) WebSocket frames")
    let envelope = try #require(await handled.envelope)
    #expect(envelope.requestID.uuidString.lowercased() == requestID)

    let lifecycleID = "20000000-0000-4000-8000-000000000002"
    let lifecycle = Data(
        """
        {"lifecycle":{"version":1,"request_id":"\(lifecycleID)","context":{
        "user_id":"10000000-0000-4000-8000-000000000001",
        "device_id":"10000000-0000-4000-8000-000000000002",
        "tool_session_id":"10000000-0000-4000-8000-000000000003",
        "device_session_id":"10000000-0000-4000-8000-000000000004",
        "node_id":"10000000-0000-4000-8000-000000000005","platform":"macos",
        "generation":7},"event":"turn_stop"}}
        """.utf8
    )
    try await sendTestFrame(lifecycle, over: proxyConnection)
    let lifecycleResponse = try await receiveTestFrame(from: proxyConnection)
    let responseObject = try #require(
        JSONSerialization.jsonObject(with: lifecycleResponse) as? [String: String]
    )
    #expect(responseObject["request_id"]?.lowercased() == lifecycleID)
    #expect(responseObject["status"] == "success")
    #expect(await handled.lifecycleEvent == .turnStop)
    proxyConnection.cancel()
    relay.cancel()
    relayTask.cancel()
}

@Test(.timeLimit(.minutes(1)))
func relayDisconnectCancelsAnInFlightActionWithoutWaitingForItsReply() async throws {
    let actionStarted = TestOneShot<Void>()
    let actionCancelled = TestOneShot<Void>()
    let disconnect = TestOneShot<Void>()
    let bridgeTask = Task<Void, Error> {
        try await disconnect.value()
    }
    let operation = Task {
        try await NetworkBrokerNestedTLSRelay.raceActionAgainstRelayDisconnect(
            Data("request".utf8),
            bridgeTask: bridgeTask,
            actionHandler: { _ in
                await actionStarted.resolve(.success(()))
                do {
                    try await Task.sleep(for: .seconds(60))
                    return Data("late".utf8)
                } catch {
                    await actionCancelled.resolve(.success(()))
                    throw error
                }
            }
        )
    }

    try await actionStarted.value()
    await disconnect.resolve(
        .failure(NetworkBrokerNestedTLSRelayFailure.connectionFailed)
    )
    do {
        _ = try await operation.value
        Issue.record("Relay disconnect unexpectedly returned an action response")
    } catch let failure as NetworkBrokerNestedTLSRelayFailure {
        #expect(failure == .connectionFailed)
    }
    try await actionCancelled.value()
}

@Test(.timeLimit(.minutes(1)))
func idleRelayReturnsConnectionFailureWhenItsWebSocketDisconnects() async throws {
    let deviceIdentity = try NestedTLSGenerationIdentity.generate()
    let proxyIdentity = try NestedTLSGenerationIdentity.generate()
    let context = String(repeating: "cd", count: 32)
    let generation: UInt64 = 8
    let binding = DeviceSessionBinding(
        userID: UUID(uuidString: "30000000-0000-4000-8000-000000000001")!,
        deviceID: UUID(uuidString: "30000000-0000-4000-8000-000000000002")!,
        toolSessionID: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!,
        deviceSessionID: UUID(uuidString: "30000000-0000-4000-8000-000000000004")!,
        nodeID: UUID(uuidString: "30000000-0000-4000-8000-000000000005")!,
        platform: .macos,
        generation: generation
    )
    let deviceMaterial = try NestedTLSGenerationMaterial(
        generation: generation,
        expectedPeerSPKISHA256Hex: proxyIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let proxyMaterial = try NestedTLSGenerationMaterial(
        generation: generation,
        expectedPeerSPKISHA256Hex: deviceIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let deviceInbox = MemoryWebSocketInbox()
    let proxyInbox = MemoryWebSocketInbox()
    let deviceWebSocket = MemoryWebSocket(inbox: deviceInbox, peerInbox: proxyInbox)
    let proxyWebSocket = MemoryWebSocket(inbox: proxyInbox, peerInbox: deviceInbox)

    async let establishedRelay = NetworkBrokerNestedTLSRelay.establish(
        identity: deviceIdentity,
        material: deviceMaterial,
        binding: binding,
        websocket: deviceWebSocket
    )
    let proxyConnection = try await makeProxyTLSConnection(
        identity: proxyIdentity,
        material: proxyMaterial,
        websocket: proxyWebSocket
    )
    try await confirmProxy(proxyConnection, material: proxyMaterial, binding: binding)
    let relay = try await establishedRelay
    let relayTask = Task {
        try await relay.run(actionHandler: { _ in Data() }, lifecycleHandler: { _ in })
    }

    await deviceInbox.close()
    do {
        try await relayTask.value
        Issue.record("Disconnected idle relay unexpectedly returned successfully")
    } catch let failure as NetworkBrokerNestedTLSRelayFailure {
        #expect(failure == .connectionFailed)
    }
    proxyConnection.cancel()
    relay.cancel()
}

private func makeProxyTLSConnection(
    identity: NestedTLSGenerationIdentity,
    material: NestedTLSGenerationMaterial,
    websocket: any NetworkBrokerRelayWebSocket
) async throws -> NWConnection {
    let queue = DispatchQueue(label: "dev.agentremote.device.tests.proxy-relay")
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let ready = TestOneShot<NWEndpoint.Port>()
    let accepted = TestOneShot<NWConnection>()
    listener.newConnectionHandler = { connection in
        Task { await accepted.resolve(.success(connection)) }
    }
    listener.stateUpdateHandler = { state in
        if case .ready = state, let port = listener.port {
            Task { await ready.resolve(.success(port)) }
        } else if case .failed = state {
            Task { await ready.resolve(.failure(NestedRelayTestFailure.unavailable)) }
        }
    }
    listener.start(queue: queue)
    let port = try await ready.value()
    let tlsParameters = try NestedTLSParameters.make(
        identity: identity,
        material: material,
        verificationQueue: queue
    )
    let client = NWConnection(host: "127.0.0.1", port: port, using: tlsParameters)
    async let clientReady: Void = startTestConnection(client, queue: queue)
    let rawServer = try await accepted.value()
    try await startTestConnection(rawServer, queue: queue)
    Task {
        try? await bridgeTestConnection(rawServer, websocket: websocket)
    }
    try await clientReady
    listener.cancel()
    return client
}

private func confirmProxy(
    _ connection: NWConnection,
    material: NestedTLSGenerationMaterial,
    binding: DeviceSessionBinding
) async throws {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else {
        throw NestedRelayTestFailure.unavailable
    }
    let exporter = try NestedTLSParameters.exporterBinding(
        metadata: metadata.securityProtocolMetadata,
        material: material
    )
    let confirmation = try NestedTLSParameters.confirmationRecord(
        exporterBinding: exporter,
        role: .proxy,
        generation: binding.generation,
        deviceSessionID: binding.deviceSessionID
    )
    try await sendTestData(confirmation, over: connection)
    let peer = try await receiveTestExact(
        NestedTLSParameters.confirmationRecordBytes,
        from: connection
    )
    try NestedTLSParameters.verifyPeerConfirmation(
        peer,
        exporterBinding: exporter,
        localRole: .proxy,
        generation: binding.generation,
        deviceSessionID: binding.deviceSessionID
    )
}

private func bridgeTestConnection(
    _ connection: NWConnection,
    websocket: any NetworkBrokerRelayWebSocket
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while true {
                let data = try await receiveTestChunk(from: connection, maximumLength: 65_536)
                try await websocket.send(data)
            }
        }
        group.addTask {
            while true {
                try await sendTestData(try await websocket.receive(), over: connection)
            }
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private func startTestConnection(_ connection: NWConnection, queue: DispatchQueue) async throws {
    let ready = TestOneShot<Void>()
    connection.stateUpdateHandler = { state in
        if case .ready = state {
            Task { await ready.resolve(.success(())) }
        } else if case .failed = state {
            Task { await ready.resolve(.failure(NestedRelayTestFailure.unavailable)) }
        }
    }
    connection.start(queue: queue)
    try await ready.value()
}

private func sendTestFrame(_ data: Data, over connection: NWConnection) async throws {
    var length = UInt32(data.count).bigEndian
    var frame = Data(bytes: &length, count: 4)
    frame.append(data)
    try await sendTestData(frame, over: connection)
}

private func receiveTestFrame(from connection: NWConnection) async throws -> Data {
    let header = try await receiveTestExact(4, from: connection)
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    guard length > 0, length <= 16 * 1_024 * 1_024 else {
        throw NestedRelayTestFailure.unavailable
    }
    return try await receiveTestExact(Int(length), from: connection)
}

private func sendTestData(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
        })
    }
}

private func receiveTestExact(_ count: Int, from connection: NWConnection) async throws -> Data {
    var result = Data()
    while result.count < count {
        result.append(try await receiveTestChunk(
            from: connection,
            maximumLength: count - result.count
        ))
    }
    return result
}

private func receiveTestChunk(
    from connection: NWConnection,
    maximumLength: Int
) async throws -> Data {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            content, _, _, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let content, !content.isEmpty {
                continuation.resume(returning: content)
            } else {
                continuation.resume(throwing: NestedRelayTestFailure.unavailable)
            }
        }
    }
}

private final class MemoryWebSocket: NetworkBrokerRelayWebSocket, @unchecked Sendable {
    private let inbox: MemoryWebSocketInbox
    private let peerInbox: MemoryWebSocketInbox
    private let sendDelay: Duration?

    init(
        inbox: MemoryWebSocketInbox,
        peerInbox: MemoryWebSocketInbox,
        sendDelay: Duration? = nil
    ) {
        self.inbox = inbox
        self.peerInbox = peerInbox
        self.sendDelay = sendDelay
    }

    func send(_ data: Data) async throws {
        if let sendDelay {
            try await Task.sleep(for: sendDelay)
        }
        await peerInbox.push(data)
    }

    func receive() async throws -> Data {
        try await inbox.pop()
    }

    func cancel() {
        Task {
            await inbox.close()
            await peerInbox.close()
        }
    }
}

private actor MemoryWebSocketInbox {
    private var values: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false
    private(set) var pushedFrameCount = 0

    func push(_ data: Data) {
        guard !closed else { return }
        pushedFrameCount += 1
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            values.append(data)
        }
    }

    func pop() async throws -> Data {
        if let value = values.first {
            values.removeFirst()
            return value
        }
        guard !closed else { throw NestedRelayTestFailure.unavailable }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func close() {
        closed = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters {
            waiter.resume(throwing: NestedRelayTestFailure.unavailable)
        }
    }
}

private actor TestRelayRecorder {
    private(set) var envelope: DeviceIPCEnvelope?
    private(set) var lifecycleEvent: RemoteLifecycleEvent?

    func record(_ envelope: DeviceIPCEnvelope) {
        self.envelope = envelope
    }

    func record(_ event: RemoteLifecycleEvent) {
        lifecycleEvent = event
    }
}

private actor TestOneShot<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws -> Value {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
