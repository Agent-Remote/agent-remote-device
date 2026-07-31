import Foundation

public enum DeviceXPCHealth {
    public static func brokerExecutorChainIsReady() async -> Bool {
        await withCheckedContinuation { continuation in
            let bootstrap = XPCChainBootstrap(continuation: continuation)
            bootstrap.start()
        }
    }
}

private final class XPCChainBootstrap: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var guiConnection: NSXPCConnection?
    private var brokerConnection: NSXPCConnection?
    private var keepAlive: XPCChainBootstrap?

    init(continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func start() {
        lock.lock()
        keepAlive = self
        lock.unlock()

        let connection = NSXPCConnection(serviceName: DeviceIPCServiceIdentifier.guiExecutor)
        guiConnection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: GUIExecutorXPCProtocol.self)
        connection.interruptionHandler = { [weak self] in self?.resolve(false) }
        connection.invalidationHandler = { [weak self] in self?.resolve(false) }
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.resolve(false)
        }
        guard let executor = proxy as? GUIExecutorXPCProtocol else {
            resolve(false)
            return
        }
        executor.brokerEndpoint { [weak self] endpoint, error in
            guard let self, error == nil, let endpoint else {
                self?.resolve(false)
                return
            }
            self.configureBroker(endpoint: endpoint)
        }
    }

    private func configureBroker(endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(serviceName: DeviceIPCServiceIdentifier.networkBroker)
        brokerConnection = connection
        connection.remoteObjectInterface = NSXPCInterface(with: NetworkBrokerXPCProtocol.self)
        connection.interruptionHandler = { [weak self] in self?.resolve(false) }
        connection.invalidationHandler = { [weak self] in self?.resolve(false) }
        connection.activate()
        let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            self?.resolve(false)
        }
        guard let broker = proxy as? NetworkBrokerXPCProtocol else {
            resolve(false)
            return
        }
        broker.configureGUIExecutor(endpoint) { [weak self] error in
            guard error == nil else {
                self?.resolve(false)
                return
            }
            broker.protocolVersion { version in
                self?.resolve(version == DeviceIPCVersion.current)
            }
        }
    }

    private func resolve(_ result: Bool) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let guiConnection = self.guiConnection
        let brokerConnection = self.brokerConnection
        self.guiConnection = nil
        self.brokerConnection = nil
        keepAlive = nil
        lock.unlock()
        continuation.resume(returning: result)
        guiConnection?.invalidate()
        brokerConnection?.invalidate()
    }
}
