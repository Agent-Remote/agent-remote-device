import DeviceIPC
import Foundation

public final class NetworkBrokerService: NSObject, NetworkBrokerXPCProtocol, @unchecked Sendable {
    public typealias PendingSessionProvider = @Sendable () async throws -> BrokerPendingSession?
    public typealias ApprovalProvider = @Sendable (BrokerApprovalDecision) async throws
        -> ExecutorSessionConfiguration?
    public typealias AbortProvider = @Sendable (BrokerAbortRequest) async throws
        -> BrokerPendingSession
    public typealias EndProvider = @Sendable (BrokerEndRequest) async throws -> Void
    public typealias RelayProvider = @Sendable (ExecutorSessionConfiguration) async throws
        -> any NetworkBrokerRelayRunning
    public typealias LockProvider = @Sendable (DeviceSessionBinding) async throws -> Void
    public typealias RenewProvider = @Sendable (ExecutorSessionConfiguration) async throws
        -> ExecutorSessionConfiguration

    private let lock = NSLock()
    private let executorOverride: GUIExecutorXPCProtocol?
    private let pendingSessionProvider: PendingSessionProvider
    private let approvalProvider: ApprovalProvider
    private let abortProvider: AbortProvider
    private let endProvider: EndProvider
    private let relayProvider: RelayProvider
    private let lockProvider: LockProvider
    private let renewProvider: RenewProvider
    private let generationRotationInterval: Duration
    private let xpcReplyTimeout: Duration
    private var executorConnection: NSXPCConnection?
    private var relay: (any NetworkBrokerRelayRunning)?
    private var relayTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var relayBinding: DeviceSessionBinding?
    private var pendingActivation: (binding: DeviceSessionBinding, identifier: UUID)?
    private var approvalUI: ApprovalUIXPCProtocol?
    private var turnPaused = false

    public init(
        executorOverride: GUIExecutorXPCProtocol? = nil,
        pendingSessionProvider: @escaping PendingSessionProvider = {
            throw DeviceIPCFailure.serviceUnavailable
        },
        approvalProvider: @escaping ApprovalProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        abortProvider: @escaping AbortProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        endProvider: @escaping EndProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        relayProvider: @escaping RelayProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        lockProvider: @escaping LockProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        renewProvider: @escaping RenewProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        generationRotationInterval: Duration = .seconds(14 * 60),
        xpcReplyTimeout: Duration = .seconds(15)
    ) {
        self.executorOverride = executorOverride
        self.pendingSessionProvider = pendingSessionProvider
        self.approvalProvider = approvalProvider
        self.abortProvider = abortProvider
        self.endProvider = endProvider
        self.relayProvider = relayProvider
        self.lockProvider = lockProvider
        self.renewProvider = renewProvider
        self.generationRotationInterval = generationRotationInterval
        self.xpcReplyTimeout = xpcReplyTimeout
    }

    public func pollPendingSession(reply: @escaping (NSData?, NSError?) -> Void) {
        let reply = DataReply(reply)
        Task {
            do {
                guard let pending = try await pendingSessionProvider() else {
                    reply.resolve(data: nil, error: nil)
                    return
                }
                try pending.validate()
                let payload = try JSONEncoder().encode(pending)
                let envelope = try DeviceIPCEnvelope(
                    requestID: UUID(),
                    payload: payload
                ).encoded()
                reply.resolve(data: envelope as NSData, error: nil)
            } catch {
                reply.resolve(data: nil, error: DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func protocolVersion(reply: @escaping (UInt64) -> Void) {
        guard let executor = executorProxy(errorHandler: { _ in reply(0) }) else {
            reply(0)
            return
        }
        executor.protocolVersion { version in
            reply(version == DeviceIPCVersion.current ? DeviceIPCVersion.current : 0)
        }
    }

    public func configureGUIExecutor(
        _ endpoint: NSXPCListenerEndpoint,
        reply: @escaping (NSError?) -> Void
    ) {
        let reply = ErrorReply(reply)
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: GUIExecutorXPCProtocol.self)
        connection.interruptionHandler = { [weak self, weak connection] in
            self?.clear(connection)
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            self?.clear(connection)
        }
        replaceExecutorConnection(with: connection)
        connection.activate()
        guard let executor = executorProxy(errorHandler: { [weak self, weak connection] error in
            self?.clear(connection)
            reply.resolve(error as NSError)
        }) else {
            clear(connection)
            reply.resolve(DeviceIPCFailure.serviceUnavailable.nsError)
            return
        }
        executor.protocolVersion { [weak self, weak connection] version in
            guard version == DeviceIPCVersion.current else {
                self?.clear(connection)
                reply.resolve(DeviceIPCFailure.incompatibleVersion.nsError)
                return
            }
            reply.resolve(nil)
        }
    }

    public func approveSession(
        _ request: NSData,
        reply: @escaping (NSData?, NSError?) -> Void
    ) {
        let reply = DataReply(reply)
        let requestData = request as Data
        let envelope: DeviceIPCEnvelope
        let decision: BrokerApprovalDecision
        do {
            envelope = try DeviceIPCEnvelope.decode(requestData)
            decision = try DeviceIPCDecoder.decode(
                BrokerApprovalDecision.self,
                from: envelope.payload
            )
            try decision.validate()
        } catch {
            reply.resolve(data: nil, error: DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        let activationIdentifier: UUID?
        if decision.result == .allowed {
            guard let identifier = beginActivation(decision.binding) else {
                reply.resolve(data: nil, error: DeviceIPCFailure.invalidMessage.nsError)
                return
            }
            activationIdentifier = identifier
        } else {
            activationIdentifier = nil
        }
        Task {
            do {
                let configuration = try await approvalProvider(decision)
                if decision.result == .denied {
                    guard configuration == nil else {
                        throw DeviceIPCFailure.invalidMessage
                    }
                    reply.resolve(data: nil, error: nil)
                    return
                }
                guard let configuration else {
                    throw DeviceIPCFailure.invalidMessage
                }
                guard let activationIdentifier,
                      isPendingActivation(
                          activationIdentifier,
                          binding: decision.binding
                      )
                else {
                    throw DeviceIPCFailure.invalidMessage
                }
                try configuration.validate()
                guard configuration.binding == decision.binding,
                      configuration.approvals == decision.approvals
                else {
                    throw DeviceIPCFailure.invalidMessage
                }
                let executorPayload = try JSONEncoder().encode(configuration)
                let executorRequest = try DeviceIPCEnvelope(
                    requestID: envelope.requestID,
                    payload: executorPayload
                ).encoded() as NSData
                let executorResponse = Data(referencing: executorRequest)
                guard let executor = executorProxy(errorHandler: { [weak self] error in
                    self?.clearPendingActivation(activationIdentifier)
                    reply.resolve(data: nil, error: error as NSError)
                }) else {
                    throw DeviceIPCFailure.serviceUnavailable
                }
                executor.updateSession(executorRequest) { error in
                    guard error == nil else {
                        self.clearPendingActivation(activationIdentifier)
                        reply.resolve(data: nil, error: error)
                        return
                    }
                    Task { [weak self] in
                        guard let self else {
                            reply.resolve(
                                data: nil,
                                error: DeviceIPCFailure.serviceUnavailable.nsError
                            )
                            return
                        }
                        do {
                            guard self.isPendingActivation(
                                activationIdentifier,
                                binding: configuration.binding
                            ) else {
                                throw DeviceIPCFailure.invalidMessage
                            }
                            let relay = try await relayProvider(configuration)
                            guard self.startRelay(
                                relay,
                                configuration: configuration,
                                activationIdentifier: activationIdentifier
                            ) else {
                                relay.cancel()
                                throw DeviceIPCFailure.invalidMessage
                            }
                            reply.resolve(data: executorResponse as NSData, error: nil)
                        } catch {
                            if self.clearPendingActivation(activationIdentifier) {
                                await self.failExecutorAfterRelaySetup(configuration.binding)
                            }
                            reply.resolve(
                                data: nil,
                                error: DeviceIPCFailure.serviceUnavailable.nsError
                            )
                        }
                    }
                }
            } catch let failure as DeviceIPCFailure {
                if let activationIdentifier {
                    clearPendingActivation(activationIdentifier)
                }
                reply.resolve(data: nil, error: failure.nsError)
            } catch {
                if let activationIdentifier {
                    clearPendingActivation(activationIdentifier)
                }
                reply.resolve(data: nil, error: DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func stopCurrentAction(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let requestData = request as Data
        let abortRequest: BrokerAbortRequest
        do {
            let envelope = try DeviceIPCEnvelope.decode(requestData)
            abortRequest = try DeviceIPCDecoder.decode(
                BrokerAbortRequest.self,
                from: envelope.payload
            )
            try abortRequest.validate()
        } catch {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        guard cancelRelay(matching: abortRequest.binding) else {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        Task {
            try? await stopExecutor(
                abortRequest.binding,
                reason: abortRequest.reason,
                encodedRequest: requestData
            )
            do {
                _ = try await abortProvider(abortRequest)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func endSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let requestData = request as Data
        let endRequest: BrokerEndRequest
        do {
            let envelope = try DeviceIPCEnvelope.decode(requestData)
            endRequest = try DeviceIPCDecoder.decode(BrokerEndRequest.self, from: envelope.payload)
            try endRequest.validate()
        } catch {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        guard cancelRelay(matching: endRequest.binding) else {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        Task {
            try? await endExecutor(endRequest.binding, encodedRequest: requestData)
            do {
                try await endProvider(endRequest)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func approvalUIConnectionInvalidated() {
        lock.withLock { approvalUI = nil }
        guard let binding = cancelRelay() else { return }
        Task { [weak self] in
            await self?.sendAbort(binding: binding, reason: .disconnect)
        }
    }

    public func installApprovalUI(_ approvalUI: ApprovalUIXPCProtocol) {
        lock.withLock { self.approvalUI = approvalUI }
    }

    private func startRelay(
        _ relay: any NetworkBrokerRelayRunning,
        configuration: ExecutorSessionConfiguration,
        activationIdentifier: UUID
    ) -> Bool {
        lock.lock()
        guard let pendingActivation,
              pendingActivation.identifier == activationIdentifier,
              pendingActivation.binding == configuration.binding,
              self.relay == nil,
              relayBinding == nil
        else {
            lock.unlock()
            return false
        }
        self.pendingActivation = nil
        self.relay = relay
        relayBinding = configuration.binding
        turnPaused = false
        lock.unlock()
        let lockAcquirer = RelayLockAcquirer(provider: lockProvider)
        let task = Task { [weak self, weak relay] in
            guard let self, let relay else { return }
            do {
                try await relay.run(
                    actionHandler: { [weak self] request in
                        guard let self else { throw DeviceIPCFailure.serviceUnavailable }
                        try await resumeTurnIfNeeded(configuration.binding)
                        let response = try await performExecutorAction(request)
                        try await lockAcquirer.acquire(configuration.binding)
                        return response
                    },
                    lifecycleHandler: { [weak self] event in
                        guard let self else { throw DeviceIPCFailure.serviceUnavailable }
                        try await handleRemoteLifecycle(
                            event,
                            binding: configuration.binding,
                            relay: relay
                        )
                    }
                )
                completeRelay(relay)
            } catch {
                guard !Task.isCancelled else { return }
                await abortAfterRelayFailure(configuration.binding, relay: relay)
            }
        }
        let renewalTask = makeRenewalTask(configuration, relay: relay)
        let rotationTask = makeRotationTask(configuration, relay: relay)
        lock.lock()
        guard self.relay === relay else {
            lock.unlock()
            task.cancel()
            renewalTask.cancel()
            rotationTask.cancel()
            relay.cancel()
            return false
        }
        relayTask = task
        self.renewalTask = renewalTask
        self.rotationTask = rotationTask
        lock.unlock()
        return true
    }

    private func beginActivation(_ binding: DeviceSessionBinding) -> UUID? {
        lock.withLock {
            guard pendingActivation == nil, relayBinding == nil, relay == nil else { return nil }
            let identifier = UUID()
            pendingActivation = (binding, identifier)
            return identifier
        }
    }

    private func isPendingActivation(
        _ identifier: UUID,
        binding: DeviceSessionBinding
    ) -> Bool {
        lock.withLock {
            pendingActivation?.identifier == identifier
                && pendingActivation?.binding == binding
        }
    }

    @discardableResult
    private func clearPendingActivation(_ identifier: UUID) -> Bool {
        lock.withLock {
            guard pendingActivation?.identifier == identifier else { return false }
            pendingActivation = nil
            return true
        }
    }

    private func makeRotationTask(
        _ configuration: ExecutorSessionConfiguration,
        relay: any NetworkBrokerRelayRunning
    ) -> Task<Void, Never> {
        Task { [weak self, weak relay] in
            guard let self, let relay else { return }
            do {
                try await Task.sleep(for: generationRotationInterval)
                guard !Task.isCancelled else { return }
                await abortAfterRelayFailure(configuration.binding, relay: relay)
            } catch {}
        }
    }

    private func makeRenewalTask(
        _ initialConfiguration: ExecutorSessionConfiguration,
        relay: any NetworkBrokerRelayRunning
    ) -> Task<Void, Never> {
        Task { [weak self, weak relay] in
            guard let self, let relay else { return }
            var configuration = initialConfiguration
            do {
                while true {
                    let remaining = configuration.leaseUntil.timeIntervalSinceNow
                    guard remaining > 1 else { throw DeviceIPCFailure.serviceUnavailable }
                    let delay = min(10, max(1, remaining / 2))
                    try await Task.sleep(for: .seconds(delay))
                    configuration = try await renewProvider(configuration)
                    try await renewExecutor(configuration)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await abortAfterRelayFailure(configuration.binding, relay: relay)
            }
        }
    }

    private func renewExecutor(_ configuration: ExecutorSessionConfiguration) async throws {
        let payload = try JSONEncoder().encode(configuration)
        let request = try DeviceIPCEnvelope(requestID: UUID(), payload: payload).encoded()
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.renewSession(request as NSData) { error in
                if error == nil {
                    callback(.success(()))
                } else {
                    callback(.failure(DeviceIPCFailure.invalidMessage))
                }
            }
        }
    }

    private func performExecutorAction(_ request: Data) async throws -> Data {
        let continuation = XPCActionContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        return try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.performAction(request as NSData) { response, error in
                guard error == nil,
                      let response,
                      response.length <= DeviceIPCVersion.maximumMessageBytes
                else {
                    callback(.failure(DeviceIPCFailure.invalidMessage))
                    return
                }
                callback(.success(Data(referencing: response)))
            }
        }
    }

    private func handleRemoteLifecycle(
        _ event: RemoteLifecycleEvent,
        binding: DeviceSessionBinding,
        relay: any NetworkBrokerRelayRunning
    ) async throws {
        switch event {
        case .turnStop:
            try await pauseExecutorTurn(binding)
            setTurnPaused(true, binding: binding)
            do {
                try await notifyApprovalUI(kind: .turnStopped, binding: binding)
            } catch {
                setTurnPaused(false, binding: binding)
                throw error
            }
        case .sessionEnd:
            cancelBackgroundLeaseTasks()
            try await endExecutorAndControlPlane(binding)
            try await notifyApprovalUI(kind: .sessionEnded, binding: binding)
            completeRelay(relay)
        }
    }

    private func pauseExecutorTurn(_ binding: DeviceSessionBinding) async throws {
        let payload = try JSONEncoder().encode(
            BrokerRuntimeEvent(binding: binding, kind: .turnStopped)
        )
        let request = try DeviceIPCEnvelope(requestID: UUID(), payload: payload).encoded()
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.pauseTurn(request as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
    }

    private func resumeTurnIfNeeded(_ binding: DeviceSessionBinding) async throws {
        guard isTurnPaused(binding: binding) else { return }
        do {
            try await notifyApprovalUI(kind: .turnStarted, binding: binding)
            try await resumeExecutorTurn(binding)
            setTurnPaused(false, binding: binding)
        } catch {
            try? await notifyApprovalUI(kind: .turnStopped, binding: binding)
            throw error
        }
    }

    private func resumeExecutorTurn(_ binding: DeviceSessionBinding) async throws {
        let payload = try JSONEncoder().encode(
            BrokerRuntimeEvent(binding: binding, kind: .turnStarted)
        )
        let request = try DeviceIPCEnvelope(requestID: UUID(), payload: payload).encoded()
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.resumeTurn(request as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
    }

    private func notifyApprovalUI(
        kind: BrokerRuntimeEventKind,
        binding: DeviceSessionBinding
    ) async throws {
        let event = BrokerRuntimeEvent(binding: binding, kind: kind)
        try event.validate()
        let payload = try JSONEncoder().encode(event)
        let request = try DeviceIPCEnvelope(requestID: UUID(), payload: payload).encoded()
        let continuation = XPCVoidContinuation()
        let approvalUI = lock.withLock { self.approvalUI }
        guard let approvalUI else { throw DeviceIPCFailure.serviceUnavailable }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            approvalUI.handleRuntimeEvent(request as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
    }

    private func isTurnPaused(binding: DeviceSessionBinding) -> Bool {
        lock.withLock { relayBinding == binding && turnPaused }
    }

    private func setTurnPaused(_ paused: Bool, binding: DeviceSessionBinding) {
        lock.withLock {
            guard relayBinding == binding else { return }
            turnPaused = paused
        }
    }

    private func endExecutorAndControlPlane(_ binding: DeviceSessionBinding) async throws {
        try? await endExecutor(binding)
        try await endProvider(BrokerEndRequest(binding: binding))
    }

    private func endExecutor(
        _ binding: DeviceSessionBinding,
        encodedRequest: Data? = nil
    ) async throws {
        let endRequest = BrokerEndRequest(binding: binding)
        let request: Data
        if let encodedRequest {
            request = encodedRequest
        } else {
            let payload = try JSONEncoder().encode(endRequest)
            request = try DeviceIPCEnvelope(requestID: UUID(), payload: payload).encoded()
        }
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.endSession(request as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
    }

    private func failExecutorAfterRelaySetup(_ binding: DeviceSessionBinding) async {
        await sendAbort(binding: binding, reason: .disconnect)
    }

    private func abortAfterRelayFailure(
        _ binding: DeviceSessionBinding,
        relay: any NetworkBrokerRelayRunning
    ) async {
        guard cancelRelay(ifCurrent: relay) else { return }
        await Task.detached { [weak self] in
            await self?.sendAbort(
                binding: binding,
                reason: .disconnect,
                notifyApprovalUI: true
            )
        }.value
    }

    private func sendAbort(
        binding: DeviceSessionBinding,
        reason: BrokerAbortReason,
        notifyApprovalUI: Bool = false
    ) async {
        let request = BrokerAbortRequest(binding: binding, reason: reason)
        async let executorCleanup: Void = stopExecutorBestEffort(binding, reason: reason)
        async let approvalCleanup: Void = notifyApprovalUI
            ? notifyApprovalUIBestEffort(binding)
            : ()
        _ = await (executorCleanup, approvalCleanup)
        _ = try? await abortProvider(request)
    }

    private func stopExecutorBestEffort(
        _ binding: DeviceSessionBinding,
        reason: BrokerAbortReason
    ) async {
        try? await stopExecutor(binding, reason: reason)
    }

    private func notifyApprovalUIBestEffort(_ binding: DeviceSessionBinding) async {
        try? await notifyApprovalUI(kind: .sessionEnded, binding: binding)
    }

    private func stopExecutor(
        _ binding: DeviceSessionBinding,
        reason: BrokerAbortReason,
        encodedRequest: Data? = nil
    ) async throws {
        let data: Data
        if let encodedRequest {
            data = encodedRequest
        } else {
            let request = BrokerAbortRequest(binding: binding, reason: reason)
            data = try DeviceIPCEnvelope(
                requestID: UUID(),
                payload: JSONEncoder().encode(request)
            ).encoded()
        }
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { _ in
            continuation.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.stopCurrentAction(data as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
    }

    @discardableResult
    private func cancelRelay() -> DeviceSessionBinding? {
        lock.lock()
        let relay = relay
        let task = relayTask
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        let binding = relayBinding ?? pendingActivation?.binding
        self.relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        pendingActivation = nil
        turnPaused = false
        lock.unlock()
        task?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        return binding
    }

    private func cancelRelay(matching expectedBinding: DeviceSessionBinding) -> Bool {
        lock.lock()
        if let relayBinding, relayBinding != expectedBinding {
            lock.unlock()
            return false
        }
        if let pendingActivation, pendingActivation.binding != expectedBinding {
            lock.unlock()
            return false
        }
        let relay = relay
        let task = relayTask
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        self.relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        pendingActivation = nil
        turnPaused = false
        lock.unlock()
        task?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        return true
    }

    private func cancelRelay(ifCurrent expectedRelay: any NetworkBrokerRelayRunning) -> Bool {
        lock.lock()
        guard relay === expectedRelay else {
            lock.unlock()
            return false
        }
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        turnPaused = false
        lock.unlock()
        renewalTask?.cancel()
        rotationTask?.cancel()
        expectedRelay.cancel()
        return true
    }

    private func cancelBackgroundLeaseTasks() {
        lock.lock()
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        self.renewalTask = nil
        self.rotationTask = nil
        lock.unlock()
        renewalTask?.cancel()
        rotationTask?.cancel()
    }

    private func completeRelay(_ completedRelay: any NetworkBrokerRelayRunning) {
        lock.lock()
        guard relay === completedRelay else {
            lock.unlock()
            return
        }
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        turnPaused = false
        lock.unlock()
        renewalTask?.cancel()
        rotationTask?.cancel()
        completedRelay.cancel()
    }

    private func executorProxy(
        errorHandler: @escaping (Error) -> Void
    ) -> GUIExecutorXPCProtocol? {
        if let executorOverride {
            return executorOverride
        }
        lock.lock()
        let connection = executorConnection
        lock.unlock()
        return connection?.remoteObjectProxyWithErrorHandler(errorHandler)
            as? GUIExecutorXPCProtocol
    }

    private func replaceExecutorConnection(with connection: NSXPCConnection) {
        lock.lock()
        let previous = executorConnection
        executorConnection = connection
        lock.unlock()
        previous?.invalidate()
    }

    private func clear(_ connection: NSXPCConnection?) {
        lock.lock()
        guard executorConnection === connection else {
            lock.unlock()
            connection?.invalidate()
            return
        }
        executorConnection = nil
        let binding = relayBinding ?? pendingActivation?.binding
        let relay = relay
        let task = relayTask
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        self.relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        pendingActivation = nil
        turnPaused = false
        lock.unlock()
        connection?.invalidate()
        task?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        guard let binding else { return }
        Task { [weak self] in
            await self?.sendAbort(
                binding: binding,
                reason: .disconnect,
                notifyApprovalUI: true
            )
        }
    }
}

private final class XPCActionContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error>?
    private var continuation: CheckedContinuation<Data, Error>?

    func wait(
        timeout: Duration,
        _ register: (@escaping (Result<Data, Error>) -> Void) -> Void
    ) async throws -> Data {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
            } catch {}
        }
        defer { timeoutTask.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                register { [weak self] result in self?.resolve(result) }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ result: Result<Data, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private actor RelayLockAcquirer {
    private let provider: NetworkBrokerService.LockProvider
    private var acquired = false

    init(provider: @escaping NetworkBrokerService.LockProvider) {
        self.provider = provider
    }

    func acquire(_ binding: DeviceSessionBinding) async throws {
        guard !acquired else { return }
        try await provider(binding)
        acquired = true
    }
}

private final class XPCVoidContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?

    func wait(
        timeout: Duration,
        _ register: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
                self?.resolve(.failure(DeviceIPCFailure.serviceUnavailable))
            } catch {}
        }
        defer { timeoutTask.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                    return
                }
                self.continuation = continuation
                lock.unlock()
                register { [weak self] result in self?.resolve(result) }
            }
        } onCancel: {
            resolve(.failure(CancellationError()))
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
