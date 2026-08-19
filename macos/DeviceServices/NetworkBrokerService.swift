import DeviceIPC
import DeviceProtocol
import Foundation
import OSLog

public final class NetworkBrokerService: NSObject, NetworkBrokerXPCProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.agentremote.device", category: "relay")
    public typealias PendingSessionProvider = @Sendable () async throws -> BrokerPendingSession?
    public typealias CandidateProvider = @Sendable () async throws -> [BrokerSessionCandidate]
    public typealias ClaimProvider = @Sendable (BrokerClaimRequest) async throws
        -> BrokerPendingSession
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
    public typealias RotationProvider = @Sendable (ExecutorSessionConfiguration) async throws
        -> ExecutorSessionConfiguration

    private let lock = NSLock()
    private let executorOverride: GUIExecutorXPCProtocol?
    private let pendingSessionProvider: PendingSessionProvider
    private let candidateProvider: CandidateProvider
    private let claimProvider: ClaimProvider
    private let approvalProvider: ApprovalProvider
    private let abortProvider: AbortProvider
    private let endProvider: EndProvider
    private let relayProvider: RelayProvider
    private let lockProvider: LockProvider
    private let renewProvider: RenewProvider
    private let rotationProvider: RotationProvider
    private let generationRotationInterval: Duration
    private let generationRotationQuietPeriod: Duration
    private let xpcReplyTimeout: Duration
    private let actionReplyTimeout: Duration
    private let renewalRetryDelaySeconds: TimeInterval
    private let renewalRecoveryWindowSeconds: TimeInterval
    private let automaticTerminationHandler: @Sendable (Bool) -> Void
    private var executorConnection: NSXPCConnection?
    private var relay: (any NetworkBrokerRelayRunning)?
    private var relayTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var relayBinding: DeviceSessionBinding?
    private var relayConfiguration: ExecutorSessionConfiguration?
    private var relayTargetApplication: String?
    private var relayActionsInFlight = 0
    private var relayActionActivityVersion: UInt64 = 0
    private var relayRenewalInFlight = false
    private var pendingActivation: (binding: DeviceSessionBinding, identifier: UUID)?
    private var approvalUI: ApprovalUIXPCProtocol?
    private var turnPaused = false
    private var automaticTerminationDisabled = false

    public init(
        executorOverride: GUIExecutorXPCProtocol? = nil,
        pendingSessionProvider: @escaping PendingSessionProvider = {
            throw DeviceIPCFailure.serviceUnavailable
        },
        candidateProvider: @escaping CandidateProvider = {
            throw DeviceIPCFailure.serviceUnavailable
        },
        claimProvider: @escaping ClaimProvider = { _ in
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
        rotationProvider: @escaping RotationProvider = { _ in
            throw DeviceIPCFailure.serviceUnavailable
        },
        generationRotationInterval: Duration = .seconds(14 * 60),
        generationRotationQuietPeriod: Duration = .seconds(2),
        xpcReplyTimeout: Duration = .seconds(15),
        actionReplyTimeout: Duration = .seconds(60),
        renewalRetryDelaySeconds: TimeInterval = 1,
        renewalRecoveryWindowSeconds: TimeInterval = 5,
        automaticTerminationHandler: @escaping @Sendable (Bool) -> Void = { disabled in
            if disabled {
                ProcessInfo.processInfo.disableAutomaticTermination(
                    "Active Agent Remote device control"
                )
            } else {
                ProcessInfo.processInfo.enableAutomaticTermination(
                    "Active Agent Remote device control"
                )
            }
        }
    ) {
        self.executorOverride = executorOverride
        self.pendingSessionProvider = pendingSessionProvider
        self.candidateProvider = candidateProvider
        self.claimProvider = claimProvider
        self.approvalProvider = approvalProvider
        self.abortProvider = abortProvider
        self.endProvider = endProvider
        self.relayProvider = relayProvider
        self.lockProvider = lockProvider
        self.renewProvider = renewProvider
        self.rotationProvider = rotationProvider
        self.generationRotationInterval = generationRotationInterval
        self.generationRotationQuietPeriod = max(.zero, generationRotationQuietPeriod)
        self.xpcReplyTimeout = xpcReplyTimeout
        self.actionReplyTimeout = actionReplyTimeout
        self.renewalRetryDelaySeconds = renewalRetryDelaySeconds
        self.renewalRecoveryWindowSeconds = max(1, renewalRecoveryWindowSeconds)
        self.automaticTerminationHandler = automaticTerminationHandler
    }

    deinit {
        relayTask?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        executorConnection?.invalidate()
        if automaticTerminationDisabled {
            automaticTerminationHandler(false)
        }
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
                logger.error("Pending session discovery failed")
                reply.resolve(data: nil, error: DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func listSessionCandidates(reply: @escaping (NSData?, NSError?) -> Void) {
        let reply = DataReply(reply)
        Task {
            do {
                let candidates = try await candidateProvider()
                let list = BrokerSessionCandidateList(items: candidates)
                try list.validate()
                let payload = try JSONEncoder().encode(list)
                let envelope = try DeviceIPCEnvelope(
                    requestID: UUID(),
                    payload: payload
                ).encoded()
                reply.resolve(data: envelope as NSData, error: nil)
            } catch let failure as DeviceIPCFailure {
                reply.resolve(data: nil, error: failure.nsError)
            } catch {
                logger.error("Session candidate discovery failed")
                reply.resolve(data: nil, error: DeviceIPCFailure.serviceUnavailable.nsError)
            }
        }
    }

    public func claimSession(
        _ request: NSData,
        reply: @escaping (NSData?, NSError?) -> Void
    ) {
        let reply = DataReply(reply)
        let claimRequest: BrokerClaimRequest
        do {
            let envelope = try DeviceIPCEnvelope.decode(request as Data)
            claimRequest = try DeviceIPCDecoder.decode(
                BrokerClaimRequest.self,
                from: envelope.payload
            )
            try claimRequest.validate()
        } catch {
            reply.resolve(data: nil, error: DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        Task {
            do {
                let pending = try await claimProvider(claimRequest)
                try pending.validate()
                let payload = try JSONEncoder().encode(pending)
                let envelope = try DeviceIPCEnvelope(
                    requestID: UUID(),
                    payload: payload
                ).encoded()
                reply.resolve(data: envelope as NSData, error: nil)
            } catch let failure as DeviceIPCFailure {
                reply.resolve(data: nil, error: failure.nsError)
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
                var activeConfiguration = configuration
                var activationStage = "executor_update"
                do {
                    var executorResponse = try await updateExecutorSession(
                        configuration,
                        requestID: envelope.requestID
                    )
                    let relay: any NetworkBrokerRelayRunning
                    activationStage = "initial_relay_establishment"
                    guard isPendingActivation(
                        activationIdentifier,
                        binding: configuration.binding
                    ) else {
                        throw DeviceIPCFailure.serviceUnavailable
                    }
                    do {
                        relay = try await relayProvider(configuration)
                    } catch {
                        logger.notice(
                            "Initial relay establishment failed; attempting one generation rotation"
                        )
                        guard isPendingActivation(
                            activationIdentifier,
                            binding: configuration.binding
                        ) else {
                            throw DeviceIPCFailure.serviceUnavailable
                        }
                        activationStage = "initial_relay_executor_stop"
                        await stopExecutorBestEffort(
                            configuration.binding,
                            reason: .disconnect
                        )
                        activationStage = "initial_relay_generation_rotation"
                        let replacement = try await rotationProvider(configuration)
                        activationStage = "replacement_validation"
                        try validateRotation(replacement, after: configuration)
                        activeConfiguration = replacement
                        activationStage = "replacement_activation_reservation"
                        guard replacePendingActivation(
                            activationIdentifier,
                            from: configuration.binding,
                            with: replacement.binding
                        ) else {
                            throw DeviceIPCFailure.serviceUnavailable
                        }
                        activationStage = "replacement_executor_update"
                        executorResponse = try await updateExecutorSession(
                            replacement,
                            requestID: envelope.requestID
                        )
                        activationStage = "replacement_relay_establishment"
                        relay = try await relayProvider(replacement)
                    }
                    activationStage = "relay_activation"
                    guard startRelay(
                        relay,
                        configuration: activeConfiguration,
                        activationIdentifier: activationIdentifier
                    ) else {
                        relay.cancel()
                        throw DeviceIPCFailure.serviceUnavailable
                    }
                    reply.resolve(data: executorResponse as NSData, error: nil)
                } catch let failure as DeviceIPCFailure {
                    clearPendingActivation(activationIdentifier)
                    logApprovalFailure(stage: activationStage)
                    await sendAbort(binding: activeConfiguration.binding, reason: .disconnect)
                    reply.resolve(data: nil, error: failure.nsError)
                    return
                } catch {
                    clearPendingActivation(activationIdentifier)
                    logApprovalFailure(stage: activationStage)
                    await sendAbort(binding: activeConfiguration.binding, reason: .disconnect)
                    reply.resolve(
                        data: nil,
                        error: DeviceIPCFailure.serviceUnavailable.nsError
                    )
                    return
                }
            } catch let failure as DeviceIPCFailure {
                logger.error("Session approval failed before relay setup")
                if let activationIdentifier {
                    clearPendingActivation(activationIdentifier)
                }
                reply.resolve(data: nil, error: failure.nsError)
            } catch {
                logger.error("Session approval failed before relay setup")
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
        guard let currentBinding = cancelRelay(matching: abortRequest.binding) else {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        let currentRequest = BrokerAbortRequest(
            binding: currentBinding,
            reason: abortRequest.reason
        )
        Task {
            try? await stopExecutor(
                currentBinding,
                reason: abortRequest.reason,
                encodedRequest: currentBinding == abortRequest.binding ? requestData : nil
            )
            do {
                _ = try await abortProvider(currentRequest)
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
        guard let currentBinding = cancelRelay(matching: endRequest.binding) else {
            reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            return
        }
        let currentRequest = BrokerEndRequest(binding: currentBinding)
        Task {
            try? await endExecutor(
                currentBinding,
                encodedRequest: currentBinding == endRequest.binding ? requestData : nil
            )
            do {
                try await endProvider(currentRequest)
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
        relayConfiguration = configuration
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayActionActivityVersion &+= 1
        relayRenewalInFlight = false
        turnPaused = false
        disableAutomaticTerminationLocked()
        lock.unlock()
        let lockAcquirer = RelayLockAcquirer(provider: lockProvider)
        let task = Task { [weak self, weak relay] in
            guard let relay else { return }
            do {
                try await relay.run(
                    actionHandler: { [weak self] request in
                        guard let self else { throw DeviceIPCFailure.serviceUnavailable }
                        guard self.beginRelayAction(relay, binding: configuration.binding) else {
                            throw DeviceIPCFailure.serviceUnavailable
                        }
                        defer { self.finishRelayAction(relay, binding: configuration.binding) }
                        try await self.resumeTurnIfNeeded(configuration.binding)
                        let selection = try self.applicationSelection(
                            for: request,
                            configuration: configuration
                        )
                        let response = try await self.performExecutorAction(request)
                        if selection.updatesTarget, let target = selection.target {
                            self.setRelayTargetApplication(target, binding: configuration.binding)
                        }
                        try await lockAcquirer.acquire(configuration.binding)
                        return response
                    },
                    lifecycleHandler: { [weak self] event in
                        guard let self else { throw DeviceIPCFailure.serviceUnavailable }
                        try await self.handleRemoteLifecycle(
                            event,
                            binding: configuration.binding,
                            relay: relay
                        )
                    }
                )
                // A peer can close its WebSocket with a normal close code without
                // sending session_end. That still disconnects the generation and
                // must rotate; otherwise renewal stops while the control-plane
                // session remains active until its lease expires.
                await self?.rotateAfterRelayDisconnect(configuration, relay: relay)
            } catch {
                guard !Task.isCancelled else { return }
                self?.logger.error("Relay failed")
                if let failure = error as? NetworkBrokerNestedTLSRelayFailure,
                   failure == .connectionFailed
                {
                    await self?.rotateAfterRelayDisconnect(configuration, relay: relay)
                } else {
                    await self?.abortAfterRelayFailure(configuration.binding, relay: relay)
                }
            }
        }
        let renewalTask = makeRenewalTask(configuration, relay: relay)
        let rotationTask = makeRotationTask(relay: relay)
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

    private func replacePendingActivation(
        _ identifier: UUID,
        from previous: DeviceSessionBinding,
        with replacement: DeviceSessionBinding
    ) -> Bool {
        lock.withLock {
            guard pendingActivation?.identifier == identifier,
                  pendingActivation?.binding == previous,
                  relayBinding == nil,
                  relay == nil
            else {
                return false
            }
            pendingActivation = (replacement, identifier)
            return true
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
        relay: any NetworkBrokerRelayRunning
    ) -> Task<Void, Never> {
        let rotationInterval = generationRotationInterval
        return Task { [weak self, weak relay] in
            do {
                try await Task.sleep(for: rotationInterval)
                guard !Task.isCancelled, let self, let relay else { return }
                await self.rotateWhenIdle(relay: relay)
            } catch {}
        }
    }

    private func rotateWhenIdle(
        relay: any NetworkBrokerRelayRunning
    ) async {
        let clock = ContinuousClock()
        var quietSince = clock.now
        var observedActivityVersion = relayRotationSnapshot(relay)?.activityVersion
        while !Task.isCancelled {
            guard let snapshot = relayRotationSnapshot(relay) else { return }
            if snapshot.activityVersion != observedActivityVersion {
                observedActivityVersion = snapshot.activityVersion
                quietSince = clock.now
            }
            if snapshot.actionsInFlight == 0,
               quietSince.duration(to: clock.now) >= generationRotationQuietPeriod,
               let configuration = takeRelayForRotationIfIdle(relay)
            {
                await performGenerationRotation(configuration)
                return
            }
            do {
                try await Task.sleep(for: .milliseconds(25))
            } catch {
                return
            }
        }
    }

    private func performGenerationRotation(
        _ previous: ExecutorSessionConfiguration
    ) async {
        var replacement: ExecutorSessionConfiguration?
        var activationIdentifier: UUID?
        var stage = "stop_executor"
        do {
            await stopExecutorBestEffort(previous.binding, reason: .disconnect)
            stage = "control_plane_rotation"
            let next = try await rotationProvider(previous)
            stage = "replacement_validation"
            try validateRotation(next, after: previous)
            replacement = next
            stage = "activation_reservation"
            guard let identifier = beginActivation(next.binding) else {
                throw DeviceIPCFailure.invalidMessage
            }
            activationIdentifier = identifier
            stage = "executor_update"
            _ = try await updateExecutorSession(next, requestID: UUID())
            stage = "relay_establishment"
            let relay = try await relayProvider(next)
            stage = "relay_activation"
            guard startRelay(
                relay,
                configuration: next,
                activationIdentifier: identifier
            ) else {
                relay.cancel()
                throw DeviceIPCFailure.invalidMessage
            }
        } catch {
            if let activationIdentifier {
                clearPendingActivation(activationIdentifier)
            }
            logGenerationRotationFailure(stage: stage)
            if let replacement {
                await sendAbort(
                    binding: replacement.binding,
                    reason: .disconnect,
                    notifyApprovalUI: true
                )
            } else {
                await sendAbort(
                    binding: previous.binding,
                    reason: .disconnect,
                    notifyApprovalUI: true
                )
            }
            enableAutomaticTerminationIfIdle()
        }
    }

    private func disableAutomaticTerminationLocked() {
        guard !automaticTerminationDisabled else { return }
        automaticTerminationDisabled = true
        automaticTerminationHandler(true)
    }

    private func enableAutomaticTerminationLocked() {
        guard automaticTerminationDisabled else { return }
        automaticTerminationDisabled = false
        automaticTerminationHandler(false)
    }

    private func enableAutomaticTerminationIfIdle() {
        lock.withLock {
            guard relay == nil, pendingActivation == nil else { return }
            enableAutomaticTerminationLocked()
        }
    }

    private func validateRotation(
        _ replacement: ExecutorSessionConfiguration,
        after previous: ExecutorSessionConfiguration
    ) throws {
        try replacement.validate()
        guard replacement.binding.userID == previous.binding.userID,
              replacement.binding.deviceID == previous.binding.deviceID,
              replacement.binding.toolSessionID == previous.binding.toolSessionID,
              replacement.binding.deviceSessionID == previous.binding.deviceSessionID,
              replacement.binding.nodeID == previous.binding.nodeID,
              replacement.binding.platform == previous.binding.platform,
              replacement.binding.generation == previous.binding.generation + 1,
              replacement.capabilities == previous.capabilities
        else {
            throw DeviceIPCFailure.invalidMessage
        }
    }

    private func logApprovalFailure(stage: String) {
        switch stage {
        case "executor_update":
            logger.error("Session approval failed during executor update")
        case "initial_relay_establishment":
            logger.error("Session approval failed during initial relay establishment")
        case "initial_relay_executor_stop":
            logger.error("Session approval failed while stopping the initial executor")
        case "initial_relay_generation_rotation":
            logger.error("Session approval failed during initial generation rotation")
        case "replacement_validation":
            logger.error("Session approval failed during replacement validation")
        case "replacement_activation_reservation":
            logger.error("Session approval failed during replacement activation reservation")
        case "replacement_executor_update":
            logger.error("Session approval failed during replacement executor update")
        case "replacement_relay_establishment":
            logger.error("Session approval failed during replacement relay establishment")
        case "relay_activation":
            logger.error("Session approval failed during relay activation")
        default:
            logger.error("Session approval failed at an unknown stage")
        }
    }

    private func logGenerationRotationFailure(stage: String) {
        switch stage {
        case "stop_executor":
            logger.error("Relay generation rotation failed while stopping the executor")
        case "control_plane_rotation":
            logger.error("Relay generation rotation failed in the control plane")
        case "replacement_validation":
            logger.error("Relay generation rotation failed during replacement validation")
        case "activation_reservation":
            logger.error("Relay generation rotation failed during activation reservation")
        case "executor_update":
            logger.error("Relay generation rotation failed during executor update")
        case "relay_establishment":
            logger.error("Relay generation rotation failed during relay establishment")
        case "relay_activation":
            logger.error("Relay generation rotation failed during relay activation")
        default:
            logger.error("Relay generation rotation failed at an unknown stage")
        }
    }

    private func updateExecutorSession(
        _ configuration: ExecutorSessionConfiguration,
        requestID: UUID
    ) async throws -> Data {
        let request = try DeviceIPCEnvelope(
            requestID: requestID,
            payload: JSONEncoder().encode(configuration)
        ).encoded()
        let continuation = XPCVoidContinuation()
        guard let executor = executorProxy(errorHandler: { error in
            continuation.resolve(.failure(error))
        }) else {
            throw DeviceIPCFailure.serviceUnavailable
        }
        try await continuation.wait(timeout: xpcReplyTimeout) { callback in
            executor.updateSession(request as NSData) { error in
                callback(error == nil
                    ? .success(())
                    : .failure(DeviceIPCFailure.invalidMessage))
            }
        }
        return request
    }

    private func beginRelayAction(
        _ expectedRelay: any NetworkBrokerRelayRunning,
        binding: DeviceSessionBinding
    ) -> Bool {
        lock.withLock {
            guard relay === expectedRelay, relayBinding == binding else { return false }
            relayActionsInFlight += 1
            relayActionActivityVersion &+= 1
            return true
        }
    }

    private func finishRelayAction(
        _ expectedRelay: any NetworkBrokerRelayRunning,
        binding: DeviceSessionBinding
    ) {
        lock.withLock {
            guard relay === expectedRelay, relayBinding == binding else { return }
            relayActionsInFlight = max(0, relayActionsInFlight - 1)
            relayActionActivityVersion &+= 1
        }
    }

    private func relayRotationSnapshot(
        _ expectedRelay: any NetworkBrokerRelayRunning
    ) -> (actionsInFlight: Int, activityVersion: UInt64)? {
        lock.withLock {
            guard relay === expectedRelay else { return nil }
            return (relayActionsInFlight, relayActionActivityVersion)
        }
    }

    private func beginRelayRenewal(
        relay expectedRelay: any NetworkBrokerRelayRunning
    ) -> Bool {
        lock.withLock {
            guard relay === expectedRelay,
                  relayConfiguration != nil,
                  !relayRenewalInFlight
            else {
                return false
            }
            relayRenewalInFlight = true
            return true
        }
    }

    @discardableResult
    private func finishRelayRenewal(
        _ configuration: ExecutorSessionConfiguration,
        relay expectedRelay: any NetworkBrokerRelayRunning
    ) -> Bool {
        lock.withLock {
            guard relay === expectedRelay,
                  relayBinding == configuration.binding,
                  relayConfiguration?.binding == configuration.binding,
                  relayRenewalInFlight
            else {
                return false
            }
            relayConfiguration = configuration
            relayRenewalInFlight = false
            return true
        }
    }

    private func takeRelayForRotationIfIdle(
        _ expectedRelay: any NetworkBrokerRelayRunning
    ) -> ExecutorSessionConfiguration? {
        lock.lock()
        guard relay === expectedRelay,
              relayActionsInFlight == 0,
              !relayRenewalInFlight,
              let configuration = relayConfiguration
        else {
            lock.unlock()
            return nil
        }
        let activeRelayTask = relayTask
        let renewalTask = renewalTask
        relay = nil
        relayTask = nil
        self.renewalTask = nil
        rotationTask = nil
        relayBinding = nil
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayActionActivityVersion &+= 1
        relayRenewalInFlight = false
        turnPaused = false
        lock.unlock()
        activeRelayTask?.cancel()
        renewalTask?.cancel()
        expectedRelay.cancel()
        return configuration
    }

    private func makeRenewalTask(
        _ initialConfiguration: ExecutorSessionConfiguration,
        relay: any NetworkBrokerRelayRunning
    ) -> Task<Void, Never> {
        Task { [weak self, weak relay] in
            guard let relay else { return }
            var configuration = initialConfiguration
            var executorLeaseUntil = initialConfiguration.leaseUntil
            do {
                while true {
                    let remaining = configuration.leaseUntil.timeIntervalSinceNow
                    guard remaining > 1 else { throw DeviceIPCFailure.serviceUnavailable }
                    let delay = min(10, max(1, remaining / 2))
                    try await Task.sleep(for: .seconds(delay))
                    guard let self else { return }
                    guard self.beginRelayRenewal(relay: relay) else { return }
                    do {
                        configuration = try await self.renewControlPlaneWithRetry(configuration)
                        try Task.checkCancellation()
                        try await self.renewExecutorWithRetry(
                            configuration,
                            currentLeaseUntil: executorLeaseUntil
                        )
                        try Task.checkCancellation()
                    } catch {
                        self.finishRelayRenewal(configuration, relay: relay)
                        throw error
                    }
                    guard self.finishRelayRenewal(configuration, relay: relay) else { return }
                    executorLeaseUntil = configuration.leaseUntil
                }
            } catch {
                guard !Task.isCancelled else { return }
                if configuration.leaseUntil.timeIntervalSinceNow
                    > (self?.renewalRecoveryWindowSeconds ?? 0)
                {
                    await self?.rotateAfterRenewalFailure(configuration, relay: relay)
                } else {
                    await self?.abortAfterRelayFailure(configuration.binding, relay: relay)
                }
            }
        }
    }

    private func renewControlPlaneWithRetry(
        _ configuration: ExecutorSessionConfiguration
    ) async throws -> ExecutorSessionConfiguration {
        let retryDeadline = min(
            configuration.leaseUntil,
            Date().addingTimeInterval(renewalRecoveryWindowSeconds)
        )
        while true {
            do {
                return try await renewProvider(configuration)
            } catch {
                try await waitForRenewalRetry(before: retryDeadline, error: error)
            }
        }
    }

    private func renewExecutorWithRetry(
        _ configuration: ExecutorSessionConfiguration,
        currentLeaseUntil: Date
    ) async throws {
        let retryDeadline = min(
            currentLeaseUntil,
            Date().addingTimeInterval(renewalRecoveryWindowSeconds)
        )
        while true {
            do {
                try await renewExecutor(configuration)
                return
            } catch {
                try await waitForRenewalRetry(before: retryDeadline, error: error)
            }
        }
    }

    private func rotateAfterRenewalFailure(
        _: ExecutorSessionConfiguration,
        relay: any NetworkBrokerRelayRunning
    ) async {
        await rotateWhenIdle(relay: relay)
    }

    private func waitForRenewalRetry(before deadline: Date, error: Error) async throws {
        let retryWindow = deadline.timeIntervalSinceNow - 1
        guard retryWindow > 0 else { throw error }
        try await Task.sleep(for: .seconds(min(renewalRetryDelaySeconds, retryWindow)))
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
        return try await continuation.wait(timeout: actionReplyTimeout) { callback in
            executor.performAction(request as NSData) { response, error in
                if error != nil {
                    self.logger.error("Executor action returned XPC error")
                    callback(.failure(DeviceIPCFailure.invalidMessage))
                    return
                }
                guard let response else {
                    self.logger.error("Executor action returned no response")
                    callback(.failure(DeviceIPCFailure.invalidMessage))
                    return
                }
                guard response.length <= DeviceIPCVersion.maximumMessageBytes else {
                    self.logger.error("Executor action response exceeded limit")
                    callback(.failure(DeviceIPCFailure.invalidMessage))
                    return
                }
                callback(.success(Data(referencing: response)))
            }
        }
    }

    private func applicationSelection(
        for data: Data,
        configuration: ExecutorSessionConfiguration
    ) throws -> (
        target: String?,
        updatesTarget: Bool
    ) {
        let envelope = try DeviceIPCEnvelope.decode(data)
        guard let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              let version = object["version"] as? NSNumber
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        let singleApprovedTarget = configuration.approvals.count == 1
            ? configuration.approvals.first?.application.bundleIdentifier
            : nil
        switch version.uint8Value {
        case DeviceProtocol.protocolVersion:
            let request = try ActionRequest.decodeStrict(envelope.payload)
            switch request.action {
            case let .screenshotApplication(application):
                return (application, true)
            case .screenshot:
                return (singleApprovedTarget, true)
            default:
                break
            }
        case DeviceProtocol.protocolVersionV2:
            let request = try ActionRequestV2.decodeStrict(envelope.payload)
            if case let .observe(application) = request.action {
                return (application ?? singleApprovedTarget, true)
            }
        default:
            throw DeviceIPCFailure.invalidMessage
        }
        return (
            lock.withLock {
                relayBinding == configuration.binding ? relayTargetApplication : nil
            },
            false
        )
    }

    private func setRelayTargetApplication(
        _ target: String,
        binding: DeviceSessionBinding
    ) {
        lock.withLock {
            guard relayBinding == binding else { return }
            relayTargetApplication = target
        }
    }

    private func handleRemoteLifecycle(
        _ event: RemoteLifecycleEvent,
        binding: DeviceSessionBinding,
        relay: any NetworkBrokerRelayRunning
    ) async throws {
        switch event {
        case .turnStop:
            guard !isTurnPaused(binding: binding) else { return }
            try await pauseExecutorTurn(binding)
            setTurnPaused(true, binding: binding)
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
        try await resumeExecutorTurn(binding)
        setTurnPaused(false, binding: binding)
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

    private func rotateAfterRelayDisconnect(
        _: ExecutorSessionConfiguration,
        relay: any NetworkBrokerRelayRunning
    ) async {
        guard let configuration = completeRelay(relay) else { return }
        await Task.detached { [weak self] in
            await self?.performGenerationRotation(configuration)
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
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayRenewalInFlight = false
        pendingActivation = nil
        turnPaused = false
        enableAutomaticTerminationLocked()
        lock.unlock()
        task?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        return binding
    }

    private func cancelRelay(
        matching expectedBinding: DeviceSessionBinding
    ) -> DeviceSessionBinding? {
        lock.lock()
        let currentBinding = relayBinding ?? pendingActivation?.binding
        if let currentBinding,
           currentBinding != expectedBinding,
           !(expectedBinding.generation < currentBinding.generation
               && expectedBinding.matchesSessionIdentity(currentBinding))
        {
            lock.unlock()
            return nil
        }
        let resolvedBinding = currentBinding ?? expectedBinding
        let relay = relay
        let task = relayTask
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        self.relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayRenewalInFlight = false
        pendingActivation = nil
        turnPaused = false
        enableAutomaticTerminationLocked()
        lock.unlock()
        task?.cancel()
        renewalTask?.cancel()
        rotationTask?.cancel()
        relay?.cancel()
        return resolvedBinding
    }

    private func cancelRelay(ifCurrent expectedRelay: any NetworkBrokerRelayRunning) -> Bool {
        lock.lock()
        guard relay === expectedRelay else {
            lock.unlock()
            return false
        }
        let task = relayTask
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayRenewalInFlight = false
        turnPaused = false
        enableAutomaticTerminationLocked()
        lock.unlock()
        task?.cancel()
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

    @discardableResult
    private func completeRelay(
        _ completedRelay: any NetworkBrokerRelayRunning
    ) -> ExecutorSessionConfiguration? {
        lock.lock()
        guard relay === completedRelay, let configuration = relayConfiguration else {
            lock.unlock()
            return nil
        }
        let renewalTask = renewalTask
        let rotationTask = rotationTask
        relay = nil
        relayTask = nil
        self.renewalTask = nil
        self.rotationTask = nil
        relayBinding = nil
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayRenewalInFlight = false
        turnPaused = false
        lock.unlock()
        renewalTask?.cancel()
        rotationTask?.cancel()
        completedRelay.cancel()
        return configuration
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
        relayConfiguration = nil
        relayTargetApplication = nil
        relayActionsInFlight = 0
        relayRenewalInFlight = false
        pendingActivation = nil
        turnPaused = false
        enableAutomaticTerminationLocked()
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
