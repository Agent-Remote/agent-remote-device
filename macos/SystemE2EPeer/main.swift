import DeviceIPC
import DeviceProtocol
import DeviceServices
import Foundation

private struct Configuration: Decodable {
    let serverURL: String
    let deviceToken: String
    let userID: UUID
    let deviceID: UUID
    let toolSessionID: UUID
    let deviceSessionID: UUID
    let nodeID: UUID
    let generation: UInt64

    enum CodingKeys: String, CodingKey {
        case serverURL = "server_url"
        case deviceToken = "device_token"
        case userID = "user_id"
        case deviceID = "device_id"
        case toolSessionID = "tool_session_id"
        case deviceSessionID = "device_session_id"
        case nodeID = "node_id"
        case generation
    }
}

private struct RelayMaterialEnvelope: Decodable {
    let data: RelayMaterial
}

private struct RelayMaterial: Decodable {
    let status: String
    let role: String
    let generation: UInt64
    let relayPath: String?
    let relayTicket: String?
    let peerSPKISHA256: String?
    let exporterContext: String?

    enum CodingKeys: String, CodingKey {
        case status, role, generation
        case relayPath = "relay_path"
        case relayTicket = "relay_ticket"
        case peerSPKISHA256 = "peer_spki_sha256"
        case exporterContext = "exporter_context"
    }
}

private enum SystemE2EFailure: Error {
    case invalidConfiguration
    case invalidControlPlaneResponse
    case bindingMismatch
}

private final class LoopbackWebSocket: NetworkBrokerRelayWebSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(url: URL, ticket: String) throws {
        guard url.scheme == "ws",
              ["127.0.0.1", "localhost"].contains(url.host ?? ""),
              url.query == nil,
              url.fragment == nil,
              !ticket.isEmpty
        else {
            throw SystemE2EFailure.invalidConfiguration
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        task = session.webSocketTask(with: request)
        task.resume()
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty,
              data.count <= URLSessionNetworkBrokerRelayWebSocket.maximumFrameBytes
        else {
            throw SystemE2EFailure.invalidControlPlaneResponse
        }
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        guard case let .data(data) = try await task.receive(),
              !data.isEmpty,
              data.count <= URLSessionNetworkBrokerRelayWebSocket.maximumFrameBytes
        else {
            throw SystemE2EFailure.invalidControlPlaneResponse
        }
        return data
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}

private actor Completion {
    private var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func resolve() {
        guard !finished else { return }
        finished = true
        let current = waiters
        waiters.removeAll()
        current.forEach { $0.resume() }
    }

    func wait() async {
        if finished { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}

@main
private enum SystemE2EPeer {
    static func main() async throws {
        let configuration = try loadConfiguration()
        let binding = DeviceSessionBinding(
            userID: configuration.userID,
            deviceID: configuration.deviceID,
            toolSessionID: configuration.toolSessionID,
            deviceSessionID: configuration.deviceSessionID,
            nodeID: configuration.nodeID,
            platform: .macos,
            generation: configuration.generation
        )
        let identity = try NestedTLSGenerationIdentity.generate()
        let material = try await waitForRelayMaterial(configuration, identity: identity)
        guard material.role == "device",
              material.generation == configuration.generation,
              let relayPath = material.relayPath,
              let ticket = material.relayTicket,
              let peerSPKI = material.peerSPKISHA256,
              let exporterContext = material.exporterContext,
              let baseURL = URL(string: configuration.serverURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        else {
            throw SystemE2EFailure.invalidControlPlaneResponse
        }
        components.scheme = "ws"
        components.path = relayPath
        guard let relayURL = components.url else {
            throw SystemE2EFailure.invalidControlPlaneResponse
        }
        let websocket = try LoopbackWebSocket(url: relayURL, ticket: ticket)
        let nestedMaterial = try NestedTLSGenerationMaterial(
            generation: configuration.generation,
            expectedPeerSPKISHA256Hex: peerSPKI,
            exporterContextHex: exporterContext
        )
        let relay = try await NetworkBrokerNestedTLSRelay.establish(
            identity: identity,
            material: nestedMaterial,
            binding: binding,
            websocket: websocket
        )
        let completion = Completion()
        let relayTask = Task {
            try await relay.run(
                actionHandler: { data in
                    let envelope = try DeviceIPCEnvelope.decode(data)
                    let request = try ActionRequestV2.decodeStrict(
                        envelope.payload,
                        requiresLowercaseIdentifiers: true
                    )
                    guard binding.matches(request.context),
                          request.action == .observe(application: nil),
                          request.context.currentStateGeneration == 0,
                          request.context.currentScreenshotGeneration == 0
                    else {
                        throw SystemE2EFailure.bindingMismatch
                    }
                    let response = ActionResponseV2(
                        requestID: request.requestID,
                        monotonicSequence: request.context.monotonicSequence,
                        stateGeneration: request.context.currentStateGeneration + 1,
                        screenshotGeneration: request.context.currentScreenshotGeneration,
                        stateID: UUID(uuidString: "20000000-0000-4000-8000-000000000001"),
                        applicationDigest: String(repeating: "a", count: 64),
                        windowID: 1,
                        displayFingerprint: "system-e2e-display",
                        baseStateID: nil,
                        status: .success,
                        message: "system-e2e-v2-ok",
                        observation: AccessibilityObservation(
                            kind: .full,
                            reset: true,
                            truncated: false,
                            nodes: [],
                            removed: []
                        ),
                        settle: SettleResult(status: .settled, elapsedMilliseconds: 1),
                        image: nil
                    )
                    let encoded = try JSONEncoder().encode(response)
                    await completion.resolve()
                    return encoded
                },
                lifecycleHandler: { _ in }
            )
        }
        await completion.wait()
        try await Task.sleep(for: .milliseconds(250))
        relay.cancel()
        relayTask.cancel()
        print("Swift device peer handled the E2E action")
    }
}

private func loadConfiguration() throws -> Configuration {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["AGENT_REMOTE_DEVICE_E2E_CONFIG"],
          path.hasPrefix("/"),
          let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? NSNumber,
          size.intValue <= 16 * 1_024
    else {
        throw SystemE2EFailure.invalidConfiguration
    }
    let configuration = try JSONDecoder().decode(
        Configuration.self,
        from: Data(contentsOf: URL(fileURLWithPath: path))
    )
    guard let url = URL(string: configuration.serverURL),
          url.scheme == "http",
          ["127.0.0.1", "localhost"].contains(url.host ?? ""),
          configuration.deviceToken.utf8.count >= 32,
          configuration.generation > 0
    else {
        throw SystemE2EFailure.invalidConfiguration
    }
    return configuration
}

private func waitForRelayMaterial(
    _ configuration: Configuration,
    identity: NestedTLSGenerationIdentity
) async throws -> RelayMaterial {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        let material = try await registerRelayMaterial(configuration, identity: identity)
        if material.status == "ready" { return material }
        guard material.status == "waiting" else {
            throw SystemE2EFailure.invalidControlPlaneResponse
        }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw SystemE2EFailure.invalidControlPlaneResponse
}

private func registerRelayMaterial(
    _ configuration: Configuration,
    identity: NestedTLSGenerationIdentity
) async throws -> RelayMaterial {
    let path = "/api/v1/device-sessions/\(configuration.deviceSessionID.uuidString.lowercased())/relay-material"
    guard let url = URL(string: configuration.serverURL + path) else {
        throw SystemE2EFailure.invalidConfiguration
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(configuration.deviceToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "generation": configuration.generation,
        "spki_sha256": identity.spkiSHA256,
    ])
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let response = response as? HTTPURLResponse,
          response.statusCode == 200,
          data.count <= 256 * 1_024
    else {
        throw SystemE2EFailure.invalidControlPlaneResponse
    }
    return try JSONDecoder().decode(RelayMaterialEnvelope.self, from: data).data
}
