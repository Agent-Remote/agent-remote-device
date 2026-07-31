import DeviceIPC
import DeviceProtocol
import DeviceServices
import Foundation
import Network
import Testing

private enum LoopbackTLSFailure: Error {
    case listenerFailed
    case connectionFailed
    case missingTLSMetadata
}

@Test(.timeLimit(.minutes(1)))
func nestedTLSSwiftPeersCompleteMutualHandshakeAndMatchExporter() async throws {
    let serverIdentity = try NestedTLSGenerationIdentity.generate()
    let clientIdentity = try NestedTLSGenerationIdentity.generate()
    let context = String(repeating: "ef", count: 32)
    let deviceSessionID = UUID()
    let serverMaterial = try NestedTLSGenerationMaterial(
        generation: 9,
        expectedPeerSPKISHA256Hex: clientIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let clientMaterial = try NestedTLSGenerationMaterial(
        generation: 9,
        expectedPeerSPKISHA256Hex: serverIdentity.spkiSHA256,
        exporterContextHex: context
    )
    let queue = DispatchQueue(label: "dev.agentremote.device.tests.nested-tls")
    let serverParameters = try NestedTLSParameters.make(
        identity: serverIdentity,
        material: serverMaterial,
        verificationQueue: queue
    )
    let clientParameters = try NestedTLSParameters.make(
        identity: clientIdentity,
        material: clientMaterial,
        verificationQueue: queue
    )
    let listener = try NWListener(using: serverParameters, on: .any)
    let listenerReady = AsyncOneShot<NWEndpoint.Port>()
    let acceptedConnection = AsyncOneShot<NWConnection>()
    listener.newConnectionHandler = { connection in
        Task { await acceptedConnection.resolve(.success(connection)) }
    }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready:
            guard let port = listener.port else {
                Task {
                    await listenerReady.resolve(.failure(LoopbackTLSFailure.listenerFailed))
                }
                return
            }
            Task { await listenerReady.resolve(.success(port)) }
        case .failed, .cancelled:
            Task { await listenerReady.resolve(.failure(LoopbackTLSFailure.listenerFailed)) }
        default:
            break
        }
    }
    listener.start(queue: queue)
    defer { listener.cancel() }

    let port = try await listenerReady.value()
    let client = NWConnection(host: "127.0.0.1", port: port, using: clientParameters)
    async let clientExporter = readyAndConfirm(
        connection: client,
        material: clientMaterial,
        role: .device,
        deviceSessionID: deviceSessionID,
        queue: queue
    )
    let server = try await acceptedConnection.value()
    async let serverExporter = readyAndConfirm(
        connection: server,
        material: serverMaterial,
        role: .proxy,
        deviceSessionID: deviceSessionID,
        queue: queue
    )
    let bindings = try await (clientExporter, serverExporter)
    client.cancel()
    server.cancel()

    #expect(bindings.0.count == NestedTLSParameters.exporterOutputBytes)
    #expect(bindings.0 == bindings.1)
}

@Test(.timeLimit(.minutes(2)))
func rustlsAndNetworkFrameworkExchangeAuthenticatedActionFrames() async throws {
    let identity = try NestedTLSGenerationIdentity.generate()
    let exporterContext = String(repeating: "3c", count: 32)
    let generation: UInt64 = 11
    let binding = DeviceSessionBinding(
        userID: UUID(),
        deviceID: UUID(),
        toolSessionID: UUID(),
        deviceSessionID: UUID(),
        nodeID: UUID(),
        platform: .macos,
        generation: generation
    )
    let temporaryDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
        at: temporaryDirectory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
    let readyFile = temporaryDirectory.appendingPathComponent("ready.json")
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.currentDirectoryURL = repositoryRoot
    process.standardError = errors
    process.arguments = [
        "cargo", "run", "--quiet", "--manifest-path", "proxy/Cargo.toml",
        "--example", "swift_interop_peer", "--",
        "--peer-spki", identity.spkiSHA256,
        "--exporter-context", exporterContext,
        "--generation", String(generation),
        "--user-id", binding.userID.uuidString.lowercased(),
        "--device-id", binding.deviceID.uuidString.lowercased(),
        "--tool-session-id", binding.toolSessionID.uuidString.lowercased(),
        "--device-session-id", binding.deviceSessionID.uuidString.lowercased(),
        "--node-id", binding.nodeID.uuidString.lowercased(),
        "--ready-file", readyFile.path,
    ]
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    let ready = try await waitForInteropReadyFile(readyFile, process: process)
    let material = try NestedTLSGenerationMaterial(
        generation: generation,
        expectedPeerSPKISHA256Hex: ready.spkiSHA256,
        exporterContextHex: exporterContext
    )
    let queue = DispatchQueue(label: "dev.agentremote.device.tests.rust-interop")
    let parameters = try NestedTLSParameters.make(
        identity: identity,
        material: material,
        verificationQueue: queue
    )
    let connection = NWConnection(
        host: "127.0.0.1",
        port: NWEndpoint.Port(rawValue: ready.port)!,
        using: parameters
    )
    defer { connection.cancel() }
    _ = try await readyAndConfirm(
        connection: connection,
        material: material,
        role: .device,
        deviceSessionID: binding.deviceSessionID,
        queue: queue
    )

    let header = try await receiveExact(4, from: connection)
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    let framedRequest = try await receiveExact(Int(length), from: connection)
    try StrictJSON.validateUniqueObjectKeys(framedRequest)
    let object = try #require(
        JSONSerialization.jsonObject(with: framedRequest) as? [String: Any]
    )
    #expect(Set(object.keys) == ["request"])
    let requestObject = try #require(object["request"] as? [String: Any])
    let requestData = try JSONSerialization.data(
        withJSONObject: requestObject,
        options: [.sortedKeys]
    )
    let request = try ActionRequest.decodeStrict(
        requestData,
        requiresLowercaseIdentifiers: true
    )
    #expect(binding.matches(request.context))
    #expect(request.action == .screenshot)

    let response = try JSONEncoder().encode(ExecutorActionResponse(
        requestID: request.requestID,
        monotonicSequence: request.context.monotonicSequence,
        screenshotGeneration: 1,
        status: .success,
        message: "swift-network-framework-ok",
        image: nil
    ))
    var responseLength = UInt32(response.count).bigEndian
    var frame = Data(bytes: &responseLength, count: 4)
    frame.append(response)
    try await send(frame, over: connection)
    process.waitUntilExit()
    let stderr = errors.fileHandleForReading.readDataToEndOfFile()
    #expect(process.terminationStatus == 0, Comment(rawValue: String(decoding: stderr, as: UTF8.self)))
}

private struct RustInteropReady: Decodable {
    let port: UInt16
    let spkiSHA256: String

    enum CodingKeys: String, CodingKey {
        case port
        case spkiSHA256 = "spki_sha256"
    }
}

private func waitForInteropReadyFile(
    _ url: URL,
    process: Process
) async throws -> RustInteropReady {
    for _ in 0 ..< 600 {
        if let data = try? Data(contentsOf: url),
           let ready = try? JSONDecoder().decode(RustInteropReady.self, from: data)
        {
            return ready
        }
        guard process.isRunning else { throw LoopbackTLSFailure.connectionFailed }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw LoopbackTLSFailure.connectionFailed
}

private func readyAndConfirm(
    connection: NWConnection,
    material: NestedTLSGenerationMaterial,
    role: NestedTLSRole,
    deviceSessionID: UUID,
    queue: DispatchQueue
) async throws -> Data {
    let ready = AsyncOneShot<Void>()
    connection.stateUpdateHandler = { state in
        switch state {
        case .ready:
            Task { await ready.resolve(.success(())) }
        case .failed, .cancelled:
            Task { await ready.resolve(.failure(LoopbackTLSFailure.connectionFailed)) }
        default:
            break
        }
    }
    connection.start(queue: queue)
    try await ready.value()
    guard let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata
    else {
        throw LoopbackTLSFailure.missingTLSMetadata
    }
    let exporter = try NestedTLSParameters.exporterBinding(
        metadata: metadata.securityProtocolMetadata,
        material: material
    )
    let confirmation = try NestedTLSParameters.confirmationRecord(
        exporterBinding: exporter,
        role: role,
        generation: material.generation,
        deviceSessionID: deviceSessionID
    )
    try await send(confirmation, over: connection)
    let peerConfirmation = try await receiveExact(
        NestedTLSParameters.confirmationRecordBytes,
        from: connection
    )
    try NestedTLSParameters.verifyPeerConfirmation(
        peerConfirmation,
        exporterBinding: exporter,
        localRole: role,
        generation: material.generation,
        deviceSessionID: deviceSessionID
    )
    return exporter
}

private func send(_ data: Data, over connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        })
    }
}

private func receiveExact(_ count: Int, from connection: NWConnection) async throws -> Data {
    var result = Data()
    while result.count < count {
        let remaining = count - result.count
        let chunk = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: remaining) {
                content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(throwing: LoopbackTLSFailure.connectionFailed)
                } else {
                    continuation.resume(throwing: LoopbackTLSFailure.connectionFailed)
                }
            }
        }
        result.append(chunk)
    }
    return result
}

private actor AsyncOneShot<Value: Sendable> {
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?

    func resolve(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result
        continuation?.resume(with: result)
        continuation = nil
    }

    func value() async throws -> Value {
        if let result {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}
