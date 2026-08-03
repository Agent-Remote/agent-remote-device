import DeviceIPC
import DeviceSecurity
import Foundation

enum DeviceBrokerClientFailure: Error {
    case unavailable
    case invalidResponse
    case bindingMismatch
}

final class DeviceBrokerClient: @unchecked Sendable {
    private let lock = NSLock()
    private let eventReceiver: ApprovalUIEventReceiver
    private var guiConnection: NSXPCConnection?
    private var brokerConnection: NSXPCConnection?
    private var broker: NetworkBrokerXPCProtocol?
    private var pendingSession: BrokerPendingSession?
    private var activeBinding: DeviceSessionBinding?
    private var runtimeEventHandler: (@Sendable (BrokerRuntimeEventKind) async throws -> Void)?

    init() {
        eventReceiver = ApprovalUIEventReceiver()
        eventReceiver.handler = { [weak self] event in
            try await self?.receiveRuntimeEvent(event)
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
            gui.interruptionHandler = { completion.resolve(false) }
            gui.invalidationHandler = { completion.resolve(false) }
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

    func pollPendingSession() async throws -> BrokerPendingSession? {
        let broker = try brokerProxy()
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            broker.pollPendingSession { data, error in
                if error != nil {
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
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
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
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
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
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
        let response = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Data?, Error>) in
            broker.approveSession(envelope) { data, error in
                guard error == nil else {
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
                    return
                }
                continuation.resume(returning: data.map { Data(referencing: $0) })
            }
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
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
                }
            }
        }
        setActiveBinding(nil)
    }

    func endSession() async throws {
        let binding = try currentActiveBinding()
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
                    continuation.resume(throwing: DeviceBrokerClientFailure.unavailable)
                }
            }
        }
        setActiveBinding(nil)
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
        connection.interruptionHandler = { [weak self] in
            self?.invalidate()
            completion.resolve(false)
        }
        connection.invalidationHandler = { [weak self] in
            self?.invalidate()
            completion.resolve(false)
        }
        connection.activate()
        guard let broker = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
            self?.invalidate()
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
        lock.unlock()
        oldGUI?.invalidate()
        oldBroker?.invalidate()
    }

    private func invalidate() {
        lock.lock()
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
        guard let broker else { throw DeviceBrokerClientFailure.unavailable }
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

    private func setActiveBinding(_ binding: DeviceSessionBinding?) {
        lock.lock()
        activeBinding = binding
        lock.unlock()
    }

    private func receiveRuntimeEvent(_ event: BrokerRuntimeEvent) async throws {
        try event.validate()
        let values = lock.withLock { (activeBinding, runtimeEventHandler) }
        guard values.0 == event.binding, let handler = values.1 else {
            throw DeviceBrokerClientFailure.bindingMismatch
        }
        try await handler(event.kind)
        if event.kind == .sessionEnded {
            setActiveBinding(nil)
        }
    }
}

private final class ApprovalUIEventReceiver: NSObject, ApprovalUIXPCProtocol, @unchecked Sendable {
    var handler: (@Sendable (BrokerRuntimeEvent) async throws -> Void)?

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
