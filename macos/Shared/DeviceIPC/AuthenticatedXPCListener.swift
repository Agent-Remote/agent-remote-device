import Darwin
import Foundation

public enum XPCPeerPolicyFailure: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidTeamIdentifier
}

public struct XPCPeerPolicy: Equatable, Sendable {
    public let bundleIdentifier: String
    public let teamIdentifier: String

    public init(bundleIdentifier: String, teamIdentifier: String) throws {
        guard Self.isIdentifier(bundleIdentifier) else {
            throw XPCPeerPolicyFailure.invalidIdentifier
        }
        guard Self.isTeamIdentifier(teamIdentifier) else {
            throw XPCPeerPolicyFailure.invalidTeamIdentifier
        }
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
    }

    public var codeSigningRequirement: String {
        if teamIdentifier == "DEVELOPMENT" {
            return "identifier \"\(bundleIdentifier)\""
        }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" "
            + "and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    private static func isIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || ".-_".contains(character))
        }
    }

    private static func isTeamIdentifier(_ value: String) -> Bool {
        (1 ... 32).contains(value.count) && value.allSatisfy { character in
            character.isASCII && (character.isUppercase || character.isNumber)
        }
    }
}

public final class AuthenticatedXPCListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let exportedInterface: NSXPCInterface
    private let exportedObject: Any
    private let peerPolicy: XPCPeerPolicy
    private let onConnectionInvalidated: (@Sendable () -> Void)?
    private let remoteInterface: NSXPCInterface?
    private let onConnectionAccepted: ((NSXPCConnection) -> Void)?

    public init(
        exportedInterface: NSXPCInterface,
        exportedObject: Any,
        peerPolicy: XPCPeerPolicy,
        onConnectionInvalidated: (@Sendable () -> Void)? = nil,
        remoteInterface: NSXPCInterface? = nil,
        onConnectionAccepted: ((NSXPCConnection) -> Void)? = nil
    ) {
        self.exportedInterface = exportedInterface
        self.exportedObject = exportedObject
        self.peerPolicy = peerPolicy
        self.onConnectionInvalidated = onConnectionInvalidated
        self.remoteInterface = remoteInterface
        self.onConnectionAccepted = onConnectionAccepted
    }

    public func listener(
        _: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard connection.effectiveUserIdentifier == getuid(),
              connection.processIdentifier > 0
        else {
            return false
        }
        connection.setCodeSigningRequirement(peerPolicy.codeSigningRequirement)
        connection.exportedInterface = exportedInterface
        connection.exportedObject = exportedObject
        connection.remoteObjectInterface = remoteInterface
        if let onConnectionInvalidated {
            let callback = OneShotInvalidationCallback(onConnectionInvalidated)
            connection.interruptionHandler = { callback.call() }
            connection.invalidationHandler = { callback.call() }
        }
        connection.activate()
        onConnectionAccepted?(connection)
        return true
    }
}

private final class OneShotInvalidationCallback: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?

    init(_ callback: @escaping @Sendable () -> Void) {
        self.callback = callback
    }

    func call() {
        let callback = lock.withLock {
            let callback = self.callback
            self.callback = nil
            return callback
        }
        callback?()
    }
}

public enum XPCServiceBootstrap {
    public static func teamIdentifier(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: "AgentRemoteTeamIdentifier") as? String
    }
}
