import DeviceIPC
import DeviceServices
import Darwin
import Foundation

guard DeviceProcessHardening.disableCoreDumps(),
      let signerIdentity = XPCServiceBootstrap.signerIdentity(),
      let policy = try? XPCPeerPolicy(
          bundleIdentifier: DeviceIPCServiceIdentifier.approvalUI,
          signerIdentity: signerIdentity
      )
else {
    exit(EXIT_FAILURE)
}

private let discovery: NetworkBrokerDiscoveryCoordinator? = {
    let credentialStore: any NetworkBrokerCredentialLoading
    if Bundle.main.object(forInfoDictionaryKey: "AgentRemoteCredentialMode") as? String
        == "community-file"
    {
        credentialStore = CommunityFileNetworkBrokerCredentialStore()
    } else {
        guard let keychainStore = try? KeychainNetworkBrokerCredentialStore() else {
            return nil
        }
        credentialStore = keychainStore
    }
    let policyChecker = (try? ManagedOutboundNetworkPolicyChecker.load())
        ?? UnavailableOutboundNetworkPolicyChecker()
    return NetworkBrokerDiscoveryCoordinator(
        credentialLoader: credentialStore,
        outboundPolicyChecker: policyChecker
    )
}()
private let service = NetworkBrokerService(pendingSessionProvider: {
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.nextPendingSession()
}, candidateProvider: {
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.sessionCandidates()
}, claimProvider: { request in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.claim(request)
}, approvalProvider: { decision in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.approve(decision)
}, abortProvider: { request in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.abort(request)
}, endProvider: { request in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    try await discovery.stop(request)
}, relayProvider: { configuration in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.establishRelay(configuration)
}, lockProvider: { binding in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    try await discovery.acquireLock(binding: binding)
}, renewProvider: { configuration in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.renew(configuration)
}, rotationProvider: { configuration in
    guard let discovery else {
        throw DeviceIPCFailure.serviceUnavailable
    }
    return try await discovery.rotate(configuration)
})
private let delegate = AuthenticatedXPCListenerDelegate(
    exportedInterface: NSXPCInterface(with: NetworkBrokerXPCProtocol.self),
    exportedObject: service,
    peerPolicy: policy,
    onConnectionInvalidated: {
        service.approvalUIConnectionInvalidated()
    },
    remoteInterface: NSXPCInterface(with: ApprovalUIXPCProtocol.self),
    onConnectionAccepted: { connection in
        guard let approvalUI = connection.remoteObjectProxyWithErrorHandler({ _ in
            service.approvalUIConnectionInvalidated()
        }) as? ApprovalUIXPCProtocol else {
            service.approvalUIConnectionInvalidated()
            return
        }
        service.installApprovalUI(approvalUI)
    }
)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
