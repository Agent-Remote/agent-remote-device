import DeviceIPC
import DeviceProtocol
import Foundation
import Network

public enum NetworkBrokerNestedTLSRelayFailure: Error, Equatable, Sendable {
    case listenerFailed
    case connectionFailed
    case missingTLSMetadata
    case invalidFrame
    case bindingMismatch
}

public protocol NetworkBrokerRelayRunning: AnyObject, Sendable {
    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws
    func cancel()
}

public enum RemoteLifecycleEvent: String, Codable, Equatable, Sendable {
    case turnStop = "turn_stop"
    case sessionEnd = "session_end"
}

public final class NetworkBrokerNestedTLSRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    public typealias ActionHandler = @Sendable (Data) async throws -> Data

    fileprivate static let transportChunkBytes = 64 * 1_024

    private let listener: NWListener
    private let rawConnection: NWConnection
    private let secureConnection: NWConnection
    private let websocket: any NetworkBrokerRelayWebSocket
    private let bridgeTask: Task<Void, Never>
    private let binding: DeviceSessionBinding

    public static func establish(
        identity: NestedTLSGenerationIdentity,
        material: NestedTLSGenerationMaterial,
        binding: DeviceSessionBinding,
        websocket: any NetworkBrokerRelayWebSocket
    ) async throws -> NetworkBrokerNestedTLSRelay {
        guard material.generation == binding.generation else {
            throw NetworkBrokerNestedTLSRelayFailure.bindingMismatch
        }
        let queue = DispatchQueue(label: "dev.agentremote.device.nested-relay")
        let parameters = try NestedTLSParameters.make(
            identity: identity,
            material: material,
            verificationQueue: queue
        )
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let listenerReady = RelayOneShot<NWEndpoint.Port>()
        let acceptedConnection = RelayOneShot<NWConnection>()
        listener.newConnectionHandler = { connection in
            Task { await acceptedConnection.resolve(.success(connection)) }
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port {
                    Task { await listenerReady.resolve(.success(port)) }
                } else {
                    Task {
                        await listenerReady.resolve(.failure(
                            NetworkBrokerNestedTLSRelayFailure.listenerFailed
                        ))
                    }
                }
            case .failed, .cancelled:
                Task {
                    await listenerReady.resolve(.failure(
                        NetworkBrokerNestedTLSRelayFailure.listenerFailed
                    ))
                }
            default:
                break
            }
        }
        listener.start(queue: queue)

        do {
            let port = try await listenerReady.value()
            let rawConnection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            try await startAndWait(rawConnection, queue: queue)
            let bridgeTask = Task {
                do {
                    try await bridge(rawConnection, websocket: websocket)
                } catch {
                    rawConnection.cancel()
                    websocket.cancel()
                }
            }
            let secureConnection = try await acceptedConnection.value()
            try await startAndWait(secureConnection, queue: queue)
            try await confirm(
                secureConnection,
                material: material,
                binding: binding
            )
            return NetworkBrokerNestedTLSRelay(
                listener: listener,
                rawConnection: rawConnection,
                secureConnection: secureConnection,
                websocket: websocket,
                bridgeTask: bridgeTask,
                binding: binding
            )
        } catch {
            listener.cancel()
            websocket.cancel()
            throw error
        }
    }

    private init(
        listener: NWListener,
        rawConnection: NWConnection,
        secureConnection: NWConnection,
        websocket: any NetworkBrokerRelayWebSocket,
        bridgeTask: Task<Void, Never>,
        binding: DeviceSessionBinding
    ) {
        self.listener = listener
        self.rawConnection = rawConnection
        self.secureConnection = secureConnection
        self.websocket = websocket
        self.bridgeTask = bridgeTask
        self.binding = binding
    }

    public func run(
        actionHandler: @escaping ActionHandler,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        while true {
            let header = try await receiveExact(4, from: secureConnection)
            let length = header.withUnsafeBytes { bytes -> UInt32 in
                bytes.loadUnaligned(as: UInt32.self).bigEndian
            }
            guard length > 0, length <= UInt32(maximumFrameBytes) else {
                throw NetworkBrokerNestedTLSRelayFailure.invalidFrame
            }
            let framedData = try await receiveExact(Int(length), from: secureConnection)
            let framedRequest = try strictFramedRequest(framedData, binding: binding)
            let response: Data
            let shouldEnd: Bool
            switch framedRequest {
            case let .action(requestData, requestID):
                let envelope = try DeviceIPCEnvelope(
                    requestID: requestID,
                    payload: requestData
                ).encoded()
                response = try await actionHandler(envelope)
                shouldEnd = false
            case let .lifecycle(request):
                try await lifecycleHandler(request.event)
                response = try JSONEncoder().encode(
                    RemoteLifecycleResponse(requestID: request.requestID, status: "success")
                )
                shouldEnd = request.event == .sessionEnd
            }
            guard !response.isEmpty, response.count <= maximumFrameBytes else {
                throw NetworkBrokerNestedTLSRelayFailure.invalidFrame
            }
            var responseLength = UInt32(response.count).bigEndian
            var framedResponse = Data(bytes: &responseLength, count: 4)
            framedResponse.append(response)
            try await send(framedResponse, over: secureConnection)
            if shouldEnd { return }
        }
    }

    public func cancel() {
        bridgeTask.cancel()
        secureConnection.cancel()
        rawConnection.cancel()
        listener.cancel()
        websocket.cancel()
    }
}

private struct RemoteLifecycleRequest: Codable, Equatable, Sendable {
    let version: UInt8
    let requestID: UUID
    let context: DeviceSessionBinding
    let event: RemoteLifecycleEvent

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case context, event
    }
}

private struct RemoteLifecycleResponse: Encodable {
    let requestID: UUID
    let status: String

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
    }
}

private enum FramedRelayRequest {
    case action(Data, UUID)
    case lifecycle(RemoteLifecycleRequest)
}

private func strictFramedRequest(
    _ data: Data,
    binding: DeviceSessionBinding
) throws -> FramedRelayRequest {
    do {
        try StrictJSON.validateUniqueObjectKeys(data)
    } catch {
        throw NetworkBrokerNestedTLSRelayFailure.invalidFrame
    }
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object.count == 1
    else {
        throw NetworkBrokerNestedTLSRelayFailure.invalidFrame
    }
    if let request = object["request"] as? [String: Any] {
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        let decoded = try ActionRequest.decodeStrict(
            requestData,
            requiresLowercaseIdentifiers: true
        )
        return .action(requestData, decoded.requestID)
    }
    guard let lifecycle = object["lifecycle"] as? [String: Any],
          Set(lifecycle.keys) == ["version", "request_id", "context", "event"],
          let context = lifecycle["context"] as? [String: Any],
          Set(context.keys) == [
              "user_id", "device_id", "tool_session_id", "device_session_id", "node_id",
              "platform", "generation",
          ],
          canonicalLowercaseUUID(lifecycle["request_id"]),
          ["user_id", "device_id", "tool_session_id", "device_session_id", "node_id"]
              .allSatisfy({ canonicalLowercaseUUID(context[$0]) })
    else {
        throw NetworkBrokerNestedTLSRelayFailure.invalidFrame
    }
    let lifecycleData = try JSONSerialization.data(withJSONObject: lifecycle, options: [.sortedKeys])
    let decoded = try JSONDecoder().decode(RemoteLifecycleRequest.self, from: lifecycleData)
    guard decoded.version == protocolVersion, decoded.context == binding else {
        throw NetworkBrokerNestedTLSRelayFailure.bindingMismatch
    }
    return .lifecycle(decoded)
}

private func canonicalLowercaseUUID(_ value: Any?) -> Bool {
    guard let value = value as? String,
          value == value.lowercased(),
          let identifier = UUID(uuidString: value)
    else { return false }
    return identifier.uuidString.lowercased() == value
}

private func bridge(
    _ rawConnection: NWConnection,
    websocket: any NetworkBrokerRelayWebSocket
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            while true {
                let data = try await receiveChunk(
                    from: rawConnection,
                    maximumLength: NetworkBrokerNestedTLSRelay.transportChunkBytes
                )
                try await websocket.send(data)
            }
        }
        group.addTask {
            while true {
                let data = try await websocket.receive()
                try await send(data, over: rawConnection)
            }
        }
        _ = try await group.next()
        group.cancelAll()
    }
}

private func confirm(
    _ connection: NWConnection,
    material: NestedTLSGenerationMaterial,
    binding: DeviceSessionBinding
) async throws {
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else {
        throw NetworkBrokerNestedTLSRelayFailure.missingTLSMetadata
    }
    let exporter = try NestedTLSParameters.exporterBinding(
        metadata: metadata.securityProtocolMetadata,
        material: material
    )
    let confirmation = try NestedTLSParameters.confirmationRecord(
        exporterBinding: exporter,
        role: .device,
        generation: binding.generation,
        deviceSessionID: binding.deviceSessionID
    )
    try await send(confirmation, over: connection)
    let peerConfirmation = try await receiveExact(
        NestedTLSParameters.confirmationRecordBytes,
        from: connection
    )
    try NestedTLSParameters.verifyPeerConfirmation(
        peerConfirmation,
        exporterBinding: exporter,
        localRole: .device,
        generation: binding.generation,
        deviceSessionID: binding.deviceSessionID
    )
}

private func startAndWait(_ connection: NWConnection, queue: DispatchQueue) async throws {
    let ready = RelayOneShot<Void>()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            Task { await ready.resolve(.success(())) }
        case .failed, .cancelled:
            Task {
                await ready.resolve(.failure(
                    NetworkBrokerNestedTLSRelayFailure.connectionFailed
                ))
            }
        default:
            break
        }
    }
    connection.start(queue: queue)
    try await ready.value()
}

private func send(_ data: Data, over connection: NWConnection) async throws {
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

private func receiveExact(_ count: Int, from connection: NWConnection) async throws -> Data {
    var result = Data()
    while result.count < count {
        result.append(try await receiveChunk(
            from: connection,
            maximumLength: count - result.count
        ))
    }
    return result
}

private func receiveChunk(
    from connection: NWConnection,
    maximumLength: Int
) async throws -> Data {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, Error>) in
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
            content, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
            } else if let content, !content.isEmpty {
                continuation.resume(returning: content)
            } else if isComplete {
                continuation.resume(throwing: NetworkBrokerNestedTLSRelayFailure.connectionFailed)
            } else {
                continuation.resume(throwing: NetworkBrokerNestedTLSRelayFailure.connectionFailed)
            }
        }
    }
}

private actor RelayOneShot<Value: Sendable> {
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
