import CryptoKit
import Foundation

public enum ControlLevel: String, Codable, Sendable, Comparable {
    case viewOnly = "view_only"
    case clickOnly = "click_only"
    case fullControl = "full_control"

    public static func < (lhs: ControlLevel, rhs: ControlLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: UInt8 {
        switch self {
        case .viewOnly: 0
        case .clickOnly: 1
        case .fullControl: 2
        }
    }
}

public enum ApplicationWarning: String, Codable, Sendable {
    case shellAccess = "equivalent_to_shell_access"
    case fileAccess = "can_read_or_write_any_file"
    case systemSettings = "can_change_system_settings"
}

public enum ClassificationSource: String, Codable, Sendable {
    case publicExample = "public_example"
    case pendingConfirmation = "pending_confirmation"
}

public struct ApplicationClassification: Equatable, Sendable {
    public let controlLevel: ControlLevel?
    public let warnings: Set<ApplicationWarning>
    public let source: ClassificationSource
}

public struct ApplicationIdentity: Codable, Hashable, Sendable {
    public let bundleIdentifier: String
    public let signingIdentifier: String

    public init(bundleIdentifier: String, signingIdentifier: String) {
        self.bundleIdentifier = bundleIdentifier
        self.signingIdentifier = signingIdentifier
    }

    public var stableDigest: String {
        let normalized = "\(bundleIdentifier.lowercased())\u{0}\(signingIdentifier.lowercased())"
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ApplicationPolicy {
    public static let mappingVersion = 2

    public static func classify(bundleIdentifier: String) -> ApplicationClassification {
        let identifier = bundleIdentifier.lowercased()
        if viewOnlyIdentifiers.contains(identifier) {
            return ApplicationClassification(
                controlLevel: .viewOnly,
                warnings: [],
                source: .publicExample
            )
        }
        if shellIdentifiers.contains(identifier) {
            return ApplicationClassification(
                controlLevel: .clickOnly,
                warnings: [.shellAccess],
                source: .publicExample
            )
        }
        if identifier == "com.apple.finder" {
            return ApplicationClassification(
                controlLevel: .fullControl,
                warnings: [.fileAccess],
                source: .publicExample
            )
        }
        if identifier == "com.apple.systempreferences" {
            return ApplicationClassification(
                controlLevel: .fullControl,
                warnings: [.systemSettings],
                source: .publicExample
            )
        }
        return ApplicationClassification(
            controlLevel: nil,
            warnings: [],
            source: .pendingConfirmation
        )
    }

    private static let viewOnlyIdentifiers: Set<String> = [
        "com.apple.safari",
        "org.mozilla.firefox",
    ]

    private static let shellIdentifiers: Set<String> = [
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "com.microsoft.vscode",
        "dev.warp.warp-stable",
    ]
}
