import DeviceIPC
import Foundation

public actor NetworkBrokerDiscoveryCoordinator {
    private let credentialLoader: any NetworkBrokerCredentialLoading
    private let transport: any NetworkBrokerHTTPTransport
    private let outboundPolicyChecker: any OutboundNetworkPolicyChecking
    private var pendingSession: ControlPlaneDeviceSession?
    private var activeSession: ControlPlaneDeviceSession?

    public init(
        credentialLoader: any NetworkBrokerCredentialLoading,
        transport: any NetworkBrokerHTTPTransport = BoundedNetworkBrokerHTTPTransport(),
        outboundPolicyChecker: any OutboundNetworkPolicyChecking =
            UnavailableOutboundNetworkPolicyChecker()
    ) {
        self.credentialLoader = credentialLoader
        self.transport = transport
        self.outboundPolicyChecker = outboundPolicyChecker
    }

    public func nextPendingSession(now: Date = Date()) async throws -> BrokerPendingSession? {
        let credential = try credentialLoader.loadCredential(now: now)
        let client = try NetworkBrokerControlPlaneClient(
            credential: credential,
            transport: transport,
            now: now
        )
        let inbox = try await client.deviceInbox(now: now)
        if let pendingSession,
           let refreshed = inbox.first(where: { $0.id == pendingSession.id })
        {
            guard refreshed.binding == pendingSession.binding,
                  refreshed.status == .pendingUserApproval
            else {
                self.pendingSession = nil
                throw NetworkBrokerControlPlaneFailure.bindingMismatch
            }
            self.pendingSession = refreshed
            return BrokerPendingSession(binding: refreshed.binding, expiresAt: refreshed.expiresAt)
        }

        self.pendingSession = nil
        if let active = inbox.first(where: { $0.status == .active }) {
            let pending = try await client.abort(active, reason: .disconnect, now: now)
            let connected = try await client.markDeviceConnected(pending, now: now)
            pendingSession = connected
            return BrokerPendingSession(binding: connected.binding, expiresAt: connected.expiresAt)
        }
        if let awaitingApproval = inbox.first(where: { $0.status == .pendingUserApproval }) {
            pendingSession = awaitingApproval
            return BrokerPendingSession(
                binding: awaitingApproval.binding,
                expiresAt: awaitingApproval.expiresAt
            )
        }
        guard let selected = inbox.first(where: { $0.status == .pendingDevice }) else { return nil }
        let connected = try await client.markDeviceConnected(selected, now: now)
        pendingSession = connected
        return BrokerPendingSession(binding: connected.binding, expiresAt: connected.expiresAt)
    }

    public func clearPendingSession(binding: DeviceSessionBinding) throws {
        guard let pendingSession, pendingSession.binding == binding else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        self.pendingSession = nil
    }

    public func approve(
        _ decision: BrokerApprovalDecision,
        now: Date = Date()
    ) async throws -> ExecutorSessionConfiguration? {
        try decision.validate()
        guard let pendingSession, pendingSession.binding == decision.binding else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let credential = try credentialLoader.loadCredential(now: now)
        if decision.result == .allowed {
            try await verifyOutboundPolicy(credential: credential, now: now)
        }
        let client = try NetworkBrokerControlPlaneClient(
            credential: credential,
            transport: transport,
            now: now
        )
        let active = try await client.approve(
            pendingSession,
            approvals: decision.approvals,
            result: decision.result,
            now: now
        )
        self.pendingSession = nil
        if decision.result == .denied {
            activeSession = nil
            return nil
        }
        guard let leaseUntil = active.leaseUntil else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        activeSession = active
        return ExecutorSessionConfiguration(
            binding: active.binding,
            leaseUntil: leaseUntil,
            approvals: decision.approvals
        )
    }

    public func abort(
        _ request: BrokerAbortRequest,
        now: Date = Date()
    ) async throws -> BrokerPendingSession {
        try request.validate()
        guard let activeSession, activeSession.binding == request.binding else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let client = try makeClient(now: now)
        let pending = try await client.abort(activeSession, reason: request.reason, now: now)
        self.activeSession = nil
        pendingSession = pending
        return BrokerPendingSession(binding: pending.binding, expiresAt: pending.expiresAt)
    }

    public func stop(_ request: BrokerEndRequest, now: Date = Date()) async throws {
        try request.validate()
        let session = activeSession ?? pendingSession
        guard let session, session.binding == request.binding else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let client = try makeClient(now: now)
        _ = try await client.stop(session, now: now)
        activeSession = nil
        pendingSession = nil
    }

    public func establishRelay(
        _ configuration: ExecutorSessionConfiguration,
        now: Date = Date()
    ) async throws -> NetworkBrokerNestedTLSRelay {
        try configuration.validate(now: now)
        guard let activeSession,
              activeSession.binding == configuration.binding,
              activeSession.leaseUntil == configuration.leaseUntil
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let credential = try credentialLoader.loadCredential(now: now)
        try await verifyOutboundPolicy(credential: credential, now: now)
        let identity = try NestedTLSGenerationIdentity.generate(now: now)
        let client = try NetworkBrokerControlPlaneClient(
            credential: credential,
            transport: transport,
            now: now
        )
        let deadline = min(
            configuration.leaseUntil,
            activeSession.expiresAt,
            now.addingTimeInterval(NestedTLSGenerationIdentity.maximumLifetime)
        )
        var material: DeviceRelayMaterial?
        while material == nil {
            let current = Date()
            guard current < deadline else {
                throw NetworkBrokerControlPlaneFailure.invalidResponse
            }
            let candidate = try await client.registerRelayMaterial(
                activeSession,
                spkiSHA256: identity.spkiSHA256,
                now: current
            )
            if candidate.status == .ready {
                material = candidate
            } else {
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        guard let material,
              let peerSPKI = material.peerSPKISHA256,
              let exporterContext = material.exporterContext
        else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        let request = try client.relayRequest(activeSession, material: material, now: Date())
        let websocket = try URLSessionNetworkBrokerRelayWebSocket(request: request)
        let nestedMaterial = try NestedTLSGenerationMaterial(
            generation: activeSession.generation,
            expectedPeerSPKISHA256Hex: peerSPKI,
            exporterContextHex: exporterContext
        )
        return try await NetworkBrokerNestedTLSRelay.establish(
            identity: identity,
            material: nestedMaterial,
            binding: activeSession.binding,
            websocket: websocket
        )
    }

    public func acquireLock(
        binding: DeviceSessionBinding,
        now: Date = Date()
    ) async throws {
        guard let activeSession, activeSession.binding == binding else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        if activeSession.lockAcquiredAt != nil { return }
        let client = try makeClient(now: now)
        self.activeSession = try await client.acquireLock(activeSession, now: now)
    }

    public func renew(
        _ configuration: ExecutorSessionConfiguration,
        now: Date = Date()
    ) async throws -> ExecutorSessionConfiguration {
        guard let activeSession,
              activeSession.binding == configuration.binding,
              activeSession.leaseUntil == configuration.leaseUntil
        else {
            throw NetworkBrokerControlPlaneFailure.bindingMismatch
        }
        let client = try makeClient(now: now)
        let renewed = try await client.renew(activeSession, now: now)
        guard let leaseUntil = renewed.leaseUntil else {
            throw NetworkBrokerControlPlaneFailure.invalidResponse
        }
        self.activeSession = renewed
        return ExecutorSessionConfiguration(
            binding: renewed.binding,
            leaseUntil: leaseUntil,
            approvals: configuration.approvals
        )
    }

    private func makeClient(now: Date) throws -> NetworkBrokerControlPlaneClient {
        let credential = try credentialLoader.loadCredential(now: now)
        return try NetworkBrokerControlPlaneClient(
            credential: credential,
            transport: transport,
            now: now
        )
    }

    private func verifyOutboundPolicy(
        credential: NetworkBrokerCredential,
        now: Date
    ) async throws {
        guard let host = URLComponents(string: credential.serverURL)?.host else {
            throw NetworkBrokerControlPlaneFailure.invalidRequest
        }
        try await outboundPolicyChecker.verify(controlPlaneHost: host, now: now)
    }
}
