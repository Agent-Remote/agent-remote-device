import Darwin
import Foundation

public enum XPCPeerPolicyFailure: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidTeamIdentifier
    case invalidCertificateSHA1
}

public enum XPCSignerIdentity: Equatable, Sendable {
    case appleTeam(String)
    case certificateSHA1(String)
    case development

    fileprivate var codeSigningConstraint: String {
        switch self {
        case let .appleTeam(teamIdentifier):
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
        case let .certificateSHA1(fingerprint):
            return "certificate leaf = H\"\(fingerprint)\""
        case .development:
            return ""
        }
    }
}

public struct XPCPeerPolicy: Equatable, Sendable {
    public let bundleIdentifier: String
    public let signerIdentity: XPCSignerIdentity

    public init(bundleIdentifier: String, teamIdentifier: String) throws {
        guard Self.isIdentifier(bundleIdentifier) else {
            throw XPCPeerPolicyFailure.invalidIdentifier
        }
        guard Self.isTeamIdentifier(teamIdentifier) else {
            throw XPCPeerPolicyFailure.invalidTeamIdentifier
        }
        self.bundleIdentifier = bundleIdentifier
        signerIdentity = teamIdentifier == "DEVELOPMENT"
            ? .development
            : .appleTeam(teamIdentifier)
    }

    public init(bundleIdentifier: String, certificateSHA1: String) throws {
        guard Self.isIdentifier(bundleIdentifier) else {
            throw XPCPeerPolicyFailure.invalidIdentifier
        }
        guard Self.isCertificateSHA1(certificateSHA1) else {
            throw XPCPeerPolicyFailure.invalidCertificateSHA1
        }
        self.bundleIdentifier = bundleIdentifier
        signerIdentity = .certificateSHA1(certificateSHA1)
    }

    public init(bundleIdentifier: String, signerIdentity: XPCSignerIdentity) throws {
        switch signerIdentity {
        case let .appleTeam(teamIdentifier):
            try self.init(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)
        case let .certificateSHA1(fingerprint):
            try self.init(bundleIdentifier: bundleIdentifier, certificateSHA1: fingerprint)
        case .development:
            try self.init(bundleIdentifier: bundleIdentifier, teamIdentifier: "DEVELOPMENT")
        }
    }

    public var codeSigningRequirement: String {
        let constraint = signerIdentity.codeSigningConstraint
        if constraint.isEmpty {
            return "identifier \"\(bundleIdentifier)\""
        }
        return "identifier \"\(bundleIdentifier)\" and \(constraint)"
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

    private static func isCertificateSHA1(_ value: String) -> Bool {
        value.count == 40 && value.allSatisfy {
            $0.isASCII && ($0.isNumber || ("A" ... "F").contains(String($0)))
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

    public static func signerIdentity(bundle: Bundle = .main) -> XPCSignerIdentity? {
        if let fingerprint = bundle.object(
            forInfoDictionaryKey: "AgentRemoteSignerCertificateSHA1"
        ) as? String {
            return .certificateSHA1(fingerprint)
        }
        if let teamIdentifier = teamIdentifier(bundle: bundle) {
            return teamIdentifier == "DEVELOPMENT"
                ? .development
                : .appleTeam(teamIdentifier)
        }
        return nil
    }
}
