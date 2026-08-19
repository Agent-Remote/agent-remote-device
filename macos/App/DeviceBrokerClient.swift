import DeviceAppCore
import DeviceIPC
import DeviceSecurity
import Foundation

enum DeviceBrokerClientFailure: Error, Equatable, LocalizedError, DeviceAppErrorCodeProviding {
    case connectionUnavailable
    case serviceUnavailable
    case incompatibleVersion
    case invalidMessage
    case peerRejected
    case invalidResponse
    case bindingMismatch

    var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            localizedBrokerString(
                "error.xpc_connection_unavailable",
                defaultValue: "The secure device service is disconnected."
            )
        case .serviceUnavailable:
            localizedBrokerString(
                "error.network_broker_unavailable",
                defaultValue: "The device broker is temporarily unavailable."
            )
        case .incompatibleVersion:
            localizedBrokerString(
                "error.protocol_version_mismatch",
                defaultValue: "Device components use incompatible protocol versions."
            )
        case .invalidMessage:
            localizedBrokerString(
                "error.invalid_broker_response",
                defaultValue: "The device broker returned an invalid response."
            )
        case .peerRejected:
            localizedBrokerString(
                "error.xpc_peer_rejected",
                defaultValue: "A secure device component could not be authenticated."
            )
        case .invalidResponse:
            localizedBrokerString(
                "error.invalid_response",
                defaultValue: "The device service returned an incomplete response."
            )
        case .bindingMismatch:
            localizedBrokerString(
                "error.session_binding_changed",
                defaultValue: "The device session changed. Refresh the session list."
            )
        }
    }

    var deviceErrorCode: String {
        switch self {
        case .connectionUnavailable: "xpc_connection_interrupted"
        case .serviceUnavailable: "network_broker_unavailable"
        case .incompatibleVersion: "protocol_version_mismatch"
        case .invalidMessage: "invalid_broker_response"
        case .peerRejected: "xpc_peer_rejected"
        case .invalidResponse: "incomplete_broker_response"
        case .bindingMismatch: "session_binding_changed"
        }
    }
}

final class DeviceBrokerClient: @unchecked Sendable {
    private let lock = NSLock()
    private let eventReceiver: ApprovalUIEventReceiver
    private var guiConnection: NSXPCConnection?
    private var brokerConnection: NSXPCConnection?
    private var broker: NetworkBrokerXPCProtocol?
    private var connectionGeneration: UInt64 = 0
    private var pendingSession: BrokerPendingSession?
    private var activeBinding: DeviceSessionBinding?
    private var runtimeEventHandler: (@Sendable (BrokerRuntimeEventKind) async throws -> Void)?

    init() {
        eventReceiver = ApprovalUIEventReceiver()
        eventReceiver.handler = { [weak self] event in
            try await self?.receiveRuntimeEvent(event)
        }
        eventReceiver.activationHandler = { [weak self] request in
            try await self?.receiveApplicationActivation(request)
        }
    }

    func setRuntimeEventHandler(
        _ handler: @escaping @Sendable (BrokerRuntimeEventKind) async throws -> Void
    ) {
        lock.withLock { runtimeEventHandler = handler }
    }

    func connect() async -> Bool {
        let connected = lock.withLock { broker != nil }
        if connected { return true }

        return await withCheckedContinuation { continuation in
            let completion = OneShotConnectionReply(continuation)
            let gui = NSXPCConnection(serviceName: DeviceIPCServiceIdentifier.guiExecutor)
            gui.remoteObjectInterface = NSXPCInterface(with: GUIExecutorXPCProtocol.self)
            gui.interruptionHandler = { [weak self, weak gui] in
                if let gui {
                    self?.invalidate(ifGUIConnectionMatches: gui)
                }
                completion.resolve(false)
            }
            gui.invalidationHandler = { [weak self, weak gui] in
                if let gui {
                    self?.invalidate(ifGUIConnectionMatches: gui)
                }
                completion.resolve(false)
            }
            gui.activate()
            guard let executor = gui.remoteObjectProxyWithErrorHandler({ _ in
                completion.resolve(false)
            }) as? GUIExecutorXPCProtocol else {
                completion.resolve(false)
                return
            }
            executor.brokerEndpoint { [weak self] endpoint, error in
                guard let self, error == nil, let endpoint else {
                    completion.resolve(false)
                    return
                }
                self.configureBroker(gui: gui, endpoint: endpoint, completion: completion)
            }
        }
    }

    func connectedGeneration() -> UInt64? {
        lock.withLock { broker == nil ? nil : connectionGeneration }
    }

    func pollPendingSession() async throws -> BrokerPendingSession? {
        let broker = try brokerProxy()
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            broker.pollPendingSession { data, error in
                if error != nil {
                    continuation.resume(throwing: brokerFailure(error))
                } else {
                    continuation.resume(returning: data.map { Data(referencing: $0) })
                }
            }
        }
        guard let response else {
            setPendingSession(nil)
            return nil
        }
        let envelope = try DeviceIPCEnvelope.decode(response)
        let pending = try DeviceIPCDecoder.decode(BrokerPendingSession.self, from: envelope.payload)
        try pending.validate()
        setPendingSession(pending)
        return pending
    }

    func sessionCandidates() async throws -> [BrokerSessionCandidate] {
        let broker = try brokerProxy()
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            broker.listSessionCandidates { data, error in
                guard error == nil, let data else {
                    continuation.resume(throwing: brokerFailure(error))
                    return
                }
                continuation.resume(returning: Data(referencing: data))
            }
        }
        let envelope = try DeviceIPCEnvelope.decode(response)
        let candidates = try DeviceIPCDecoder.decode(
            BrokerSessionCandidateList.self,
            from: envelope.payload
        )
        try candidates.validate()
        return candidates.items
    }

    func claimSession(toolSessionID: UUID) async throws {
        let request = BrokerClaimRequest(toolSessionID: toolSessionID)
        try request.validate()
        let envelope = try DeviceIPCEnvelope(
            requestID: UUID(),
            payload: JSONEncoder().encode(request)
        ).encoded() as NSData
        let broker = try brokerProxy()
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data, Error>) in
            broker.claimSession(envelope) { data, error in
                guard error == nil, let data else {
                    continuation.resume(throwing: brokerFailure(error))
                    return
                }
                continuation.resume(returning: Data(referencing: data))
            }
        }
        let responseEnvelope = try DeviceIPCEnvelope.decode(response)
        let pending = try DeviceIPCDecoder.decode(
            BrokerPendingSession.self,
            from: responseEnvelope.payload
        )
        try pending.validate()
        setPendingSession(pending)
        setActiveBinding(nil)
    }

    func approve(_ approvals: [LocalApproval]) async throws {
        _ = try await decide(approvals, result: .allowed)
    }

    func deny(_ approvals: [LocalApproval]) async throws {
        _ = try await decide(approvals, result: .denied)
    }

    private func decide(
        _ approvals: [LocalApproval],
        result: BrokerApprovalResult
    ) async throws -> ExecutorSessionConfiguration? {
        let pending = try currentPendingSession()
        let decision = BrokerApprovalDecision(
            binding: pending.binding,
            approvals: approvals,
            result: result
        )
        try decision.validate()
        let envelope = try DeviceIPCEnvelope(
            requestID: UUID(),
            payload: JSONEncoder().encode(decision)
        ).encoded() as NSData
        let broker = try brokerProxy()
        let response: Data?
        do {
            response = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, Error>) in
                broker.approveSession(envelope) { data, error in
                    guard error == nil else {
                        continuation.resume(throwing: brokerFailure(error))
                        return
                    }
                    continuation.resume(returning: data.map { Data(referencing: $0) })
                }
            }
        } catch let failure as DeviceBrokerClientFailure {
            if failure == .serviceUnavailable {
                let refreshed = try? await pollPendingSession()
                if refreshed?.binding != pending.binding {
                    throw DeviceBrokerClientFailure.bindingMismatch
                }
            }
            throw failure
        }
        if result == .denied {
            guard response == nil else { throw DeviceBrokerClientFailure.invalidResponse }
            setPendingSession(nil)
            setActiveBinding(nil)
            return nil
        }
        guard let response else { throw DeviceBrokerClientFailure.invalidResponse }
        let responseEnvelope = try DeviceIPCEnvelope.decode(response)
        let configuration = try DeviceIPCDecoder.decode(
            ExecutorSessionConfiguration.self,
            from: responseEnvelope.payload
        )
        try configuration.validate()
        guard configuration.binding == pending.binding,
              configuration.approvals == approvals
        else {
            throw DeviceBrokerClientFailure.bindingMismatch
        }
        setPendingSession(nil)
        setActiveBinding(configuration.binding)
        return configuration
    }

    func abort(reason: BrokerAbortReason) async throws {
        let binding = try currentActiveBinding()
        let request = BrokerAbortRequest(binding: binding, reason: reason)
        try request.validate()
        let data = try DeviceIPCEnvelope(
            requestID: UUID(),
            payload: JSONEncoder().encode(request)
        ).encoded() as NSData
        let broker = try brokerProxy()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            broker.stopCurrentAction(data) { error in
                if error == nil {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: brokerFailure(error))
                }
            }
        }
        setActiveBinding(nil)
        _ = try await pollPendingSession()
    }

    func endSession() async throws {
        guard let binding = currentSessionBinding() else {
            setPendingSession(nil)
            return
        }
        let request = BrokerEndRequest(binding: binding)
        try request.validate()
        let data = try DeviceIPCEnvelope(
            requestID: UUID(),
            payload: JSONEncoder().encode(request)
        ).encoded() as NSData
        let broker = try brokerProxy()
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            broker.endSession(data) { error in
                if error == nil {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: brokerFailure(error))
                }
            }
        }
        setActiveBinding(nil)
        setPendingSession(nil)
    }

    private func configureBroker(
        gui: NSXPCConnection,
        endpoint: NSXPCListenerEndpoint,
        completion: OneShotConnectionReply
    ) {
        let connection = NSXPCConnection(serviceName: DeviceIPCServiceIdentifier.networkBroker)
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkBrokerXPCProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: ApprovalUIXPCProtocol.self)
        connection.exportedObject = eventReceiver
        connection.interruptionHandler = { [weak self, weak connection] in
            if let connection {
                self?.invalidate(ifBrokerConnectionMatches: connection)
            }
            completion.resolve(false)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            if let connection {
                self?.invalidate(ifBrokerConnectionMatches: connection)
            }
            completion.resolve(false)
        }
        connection.activate()
        guard let broker = connection.remoteObjectProxyWithErrorHandler({
            [weak self, weak connection] _ in
            if let connection {
                self?.invalidate(ifBrokerConnectionMatches: connection)
            }
            completion.resolve(false)
        }) as? NetworkBrokerXPCProtocol else {
            completion.resolve(false)
            return
        }
        broker.configureGUIExecutor(endpoint) { [weak self] error in
            guard let self, error == nil else {
                completion.resolve(false)
                return
            }
            broker.protocolVersion { version in
                guard version == DeviceIPCVersion.current else {
                    completion.resolve(false)
                    return
                }
                self.install(gui: gui, brokerConnection: connection, broker: broker)
                completion.resolve(true)
            }
        }
    }

    private func install(
        gui: NSXPCConnection,
        brokerConnection: NSXPCConnection,
        broker: NetworkBrokerXPCProtocol
    ) {
        lock.lock()
        let oldGUI = guiConnection
        let oldBroker = self.brokerConnection
        guiConnection = gui
        self.brokerConnection = brokerConnection
        self.broker = broker
        connectionGeneration &+= 1
        lock.unlock()
        oldGUI?.invalidate()
        oldBroker?.invalidate()
    }

    private func invalidate(ifGUIConnectionMatches expected: NSXPCConnection) {
        invalidateConnections { gui, _ in gui === expected }
    }

    private func invalidate(ifBrokerConnectionMatches expected: NSXPCConnection) {
        invalidateConnections { _, broker in broker === expected }
    }

    private func invalidateConnections(
        ifCurrent matches: (NSXPCConnection?, NSXPCConnection?) -> Bool
    ) {
        lock.lock()
        guard matches(guiConnection, brokerConnection) else {
            lock.unlock()
            return
        }
        let gui = guiConnection
        let brokerConnection = brokerConnection
        guiConnection = nil
        self.brokerConnection = nil
        broker = nil
        pendingSession = nil
        activeBinding = nil
        lock.unlock()
        gui?.invalidate()
        brokerConnection?.invalidate()
    }

    private func brokerProxy() throws -> NetworkBrokerXPCProtocol {
        lock.lock()
        let broker = broker
        lock.unlock()
        guard let broker else { throw DeviceBrokerClientFailure.connectionUnavailable }
        return broker
    }

    private func currentPendingSession() throws -> BrokerPendingSession {
        lock.lock()
        let pending = pendingSession
        lock.unlock()
        guard let pending else { throw DeviceBrokerClientFailure.bindingMismatch }
        return pending
    }

    private func setPendingSession(_ pending: BrokerPendingSession?) {
        lock.lock()
        pendingSession = pending
        lock.unlock()
    }

    private func currentActiveBinding() throws -> DeviceSessionBinding {
        lock.lock()
        let binding = activeBinding
        lock.unlock()
        guard let binding else { throw DeviceBrokerClientFailure.bindingMismatch }
        return binding
    }

    private func currentSessionBinding() -> DeviceSessionBinding? {
        lock.withLock { activeBinding ?? pendingSession?.binding }
    }

    private func setActiveBinding(_ binding: DeviceSessionBinding?) {
        lock.lock()
        activeBinding = binding
        lock.unlock()
    }

    private func receiveRuntimeEvent(_ event: BrokerRuntimeEvent) async throws {
        try event.validate()
        let values = lock.withLock { (activeBinding, runtimeEventHandler) }
        guard let activeBinding = values.0,
              event.binding.generation >= activeBinding.generation,
              event.binding.matchesSessionIdentity(activeBinding),
              let handler = values.1
        else {
            throw DeviceBrokerClientFailure.bindingMismatch
        }
        setActiveBinding(event.binding)
        try await handler(event.kind)
        if event.kind == .sessionEnded {
            setActiveBinding(nil)
        }
    }

    private func receiveApplicationActivation(
        _ request: BrokerApplicationActivationRequest
    ) async throws {
        try request.validate()
        guard let activeBinding = lock.withLock({ activeBinding }),
              request.binding.generation >= activeBinding.generation,
              request.binding.matchesSessionIdentity(activeBinding)
        else {
            throw DeviceBrokerClientFailure.bindingMismatch
        }
        // Older Brokers requested Approval UI activation before every screenshot.
        // Keep the callback compatible, but leave focus ownership to the Executor's
        // interactive-action path.
        setActiveBinding(request.binding)
    }
}

private func brokerFailure(_ error: NSError?) -> DeviceBrokerClientFailure {
    guard let error else { return .serviceUnavailable }
    guard error.domain == "dev.agentremote.device.ipc",
          let failure = DeviceIPCFailure(rawValue: error.code)
    else {
        return .connectionUnavailable
    }
    switch failure {
    case .incompatibleVersion:
        return .incompatibleVersion
    case .invalidMessage, .messageTooLarge:
        return .invalidMessage
    case .peerRejected:
        return .peerRejected
    case .serviceUnavailable:
        return .serviceUnavailable
    }
}

private func localizedBrokerString(_ key: String, defaultValue: String) -> String {
    NSLocalizedString(key, bundle: .main, value: defaultValue, comment: "")
}

private final class ApprovalUIEventReceiver: NSObject, ApprovalUIXPCProtocol, @unchecked Sendable {
    var handler: (@Sendable (BrokerRuntimeEvent) async throws -> Void)?
    var activationHandler: (@Sendable (BrokerApplicationActivationRequest) async throws -> Void)?

    func handleRuntimeEvent(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = OneShotEventReply(reply)
        let request = Data(referencing: request)
        let handler = handler
        Task {
            do {
                let envelope = try DeviceIPCEnvelope.decode(request)
                let event = try DeviceIPCDecoder.decode(
                    BrokerRuntimeEvent.self,
                    from: envelope.payload
                )
                guard let handler else { throw DeviceIPCFailure.serviceUnavailable }
                try await handler(event)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    func activateApplication(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = OneShotEventReply(reply)
        let request = Data(referencing: request)
        let handler = activationHandler
        Task {
            do {
                let envelope = try DeviceIPCEnvelope.decode(request)
                let activation = try DeviceIPCDecoder.decode(
                    BrokerApplicationActivationRequest.self,
                    from: envelope.payload
                )
                guard let handler else { throw DeviceIPCFailure.serviceUnavailable }
                try await handler(activation)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }
}

private final class OneShotEventReply: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: ((NSError?) -> Void)?

    init(_ reply: @escaping (NSError?) -> Void) {
        self.reply = reply
    }

    func resolve(_ error: NSError?) {
        let reply = lock.withLock {
            let reply = self.reply
            self.reply = nil
            return reply
        }
        reply?(error)
    }
}

private final class OneShotConnectionReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resolve(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: result)
    }
}
