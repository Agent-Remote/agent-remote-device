import DeviceIPC
import Foundation
import OSLog

public final class GUIExecutorService: NSObject, GUIExecutorXPCProtocol, @unchecked Sendable {
    private let logger = Logger(subsystem: "dev.agentremote.device", category: "executor")
    private let signerIdentity: XPCSignerIdentity
    private let controller: GUIExecutorSessionController
    private var brokerListener: NSXPCListener?
    private var brokerDelegate: AuthenticatedXPCListenerDelegate?

    public init(
        signerIdentity: XPCSignerIdentity,
        controller: GUIExecutorSessionController = GUIExecutorSessionController()
    ) {
        self.signerIdentity = signerIdentity
        self.controller = controller
    }

    public func protocolVersion(reply: @escaping (UInt64) -> Void) {
        reply(DeviceIPCVersion.current)
    }

    public func brokerEndpoint(reply: @escaping (NSXPCListenerEndpoint?, NSError?) -> Void) {
        if let brokerListener {
            reply(brokerListener.endpoint, nil)
            return
        }
        guard let policy = try? XPCPeerPolicy(
            bundleIdentifier: DeviceIPCServiceIdentifier.networkBroker,
            signerIdentity: signerIdentity
        ) else {
            reply(nil, DeviceIPCFailure.peerRejected.nsError)
            return
        }
        let listener = NSXPCListener.anonymous()
        let delegate = AuthenticatedXPCListenerDelegate(
            exportedInterface: NSXPCInterface(with: GUIExecutorXPCProtocol.self),
            exportedObject: self,
            peerPolicy: policy
        )
        listener.delegate = delegate
        listener.resume()
        brokerListener = listener
        brokerDelegate = delegate
        reply(listener.endpoint, nil)
    }

    public func updateSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.updateSession(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func performAction(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void) {
        let reply = DataReply(reply)
        let data = request as Data
        Task {
            do {
                let response = try await controller.performAction(data)
                reply.resolve(data: response as NSData, error: nil)
            } catch {
                logger.error("Executor action failed")
                reply.resolve(data: nil, error: DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func renewSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.renewSession(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func pauseTurn(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.pauseTurn(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func resumeTurn(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.resumeTurn(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func stopCurrentAction(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.stopCurrentAction(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }

    public func endSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        let reply = ErrorReply(reply)
        let data = request as Data
        Task {
            do {
                try await controller.endSession(data)
                reply.resolve(nil)
            } catch {
                reply.resolve(DeviceIPCFailure.invalidMessage.nsError)
            }
        }
    }
}
