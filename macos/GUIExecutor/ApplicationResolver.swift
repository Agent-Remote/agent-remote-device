import AppKit
import DeviceSecurity
import Foundation

public struct InstalledApplicationTarget: Sendable {
    public let identity: ApplicationIdentity
    public let bundleURL: URL

    public init(identity: ApplicationIdentity, bundleURL: URL) {
        self.identity = identity
        self.bundleURL = bundleURL
    }
}

public enum ApplicationResolver {
    private static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.authorizationhost",
        "com.apple.coreservicesuiagent",
        "com.apple.loginwindow",
        "com.apple.securityagent",
        "com.apple.userconsentdialog",
    ]
    private static let maximumDiscoveredApplications = 1_024

    @MainActor
    public static func runningApplication(
        matching target: String?,
        excludedBundleIdentifiers: Set<String>
    ) throws -> ApplicationIdentity {
        let exclusions = normalizedExclusions(excludedBundleIdentifiers)
        let candidates: [NSRunningApplication]
        if let target {
            candidates = NSWorkspace.shared.runningApplications.filter { application in
                guard let bundleIdentifier = application.bundleIdentifier else { return false }
                return isEligible(application, exclusions: exclusions)
                    && ApplicationTargetMatching.matches(
                        target: target,
                        bundleIdentifier: bundleIdentifier,
                        displayNames: [application.localizedName].compactMap { $0 }
                    )
            }
        } else if let frontmost = NSWorkspace.shared.frontmostApplication,
                  isEligible(frontmost, exclusions: exclusions)
        {
            candidates = [frontmost]
        } else {
            candidates = []
        }

        let resolvedIdentities = candidates.compactMap(identity(for:))
        if resolvedIdentities.contains(where: { isExcluded($0, exclusions: exclusions) }) {
            throw CaptureFailure.protectedApplication
        }
        let identities = Set(resolvedIdentities)
        guard identities.count == 1, let identity = identities.first else {
            if identities.count > 1 { throw CaptureFailure.applicationAmbiguous }
            if target == nil { throw CaptureFailure.protectedApplication }
            throw CaptureFailure.applicationNotRunning
        }
        return identity
    }

    @MainActor
    public static func installedApplication(
        matching target: String,
        excludedBundleIdentifiers: Set<String>
    ) throws -> InstalledApplicationTarget {
        let exclusions = normalizedExclusions(excludedBundleIdentifiers)
        if isExcludedIdentifier(target, exclusions: exclusions) {
            throw CaptureFailure.protectedApplication
        }
        var candidates: [InstalledApplicationTarget] = []
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target),
           let candidate = installedTarget(at: bundleURL, exclusions: exclusions),
           candidate.identity.bundleIdentifier.caseInsensitiveCompare(target) == .orderedSame
        {
            return candidate
        }
        candidates.append(contentsOf: try installedApplicationURLs().compactMap {
            bundleURL in
            guard applicationMetadataMatches(target: target, at: bundleURL),
                  let candidate = installedTarget(at: bundleURL, exclusions: exclusions)
            else {
                return nil
            }
            return candidate
        })
        return try uniqueInstalledApplication(candidates)
    }

    static func uniqueInstalledApplication(
        _ candidates: [InstalledApplicationTarget]
    ) throws -> InstalledApplicationTarget {
        let unique = Dictionary(grouping: candidates, by: {
            $0.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        })
            .compactMap(\.value.first)
        guard unique.count == 1, let application = unique.first else {
            if unique.count > 1 { throw CaptureFailure.applicationAmbiguous }
            throw CaptureFailure.applicationNotFound
        }
        return application
    }

    @MainActor
    public static func validateRunningIdentity(
        _ application: NSRunningApplication,
        expected: ApplicationIdentity
    ) -> Bool {
        application.bundleIdentifier == expected.bundleIdentifier
            && RunningCodeIdentity.signingIdentifier(processID: application.processIdentifier)
                == expected.signingIdentifier
    }

    @MainActor
    public static func launch(_ target: InstalledApplicationTarget) async throws -> pid_t {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        let application: NSRunningApplication
        do {
            application = try await NSWorkspace.shared.openApplication(
                at: target.bundleURL,
                configuration: configuration
            )
        } catch {
            throw CaptureFailure.applicationActivationRejected
        }
        guard validateRunningIdentity(application, expected: target.identity) else {
            application.terminate()
            throw CaptureFailure.signingIdentifierMismatch
        }
        return application.processIdentifier
    }

    private static func identity(for application: NSRunningApplication) -> ApplicationIdentity? {
        guard let bundleIdentifier = application.bundleIdentifier,
              let signingIdentifier = RunningCodeIdentity.signingIdentifier(
                  processID: application.processIdentifier
              )
        else {
            return nil
        }
        return ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            signingIdentifier: signingIdentifier
        )
    }

    private static func isEligible(
        _ application: NSRunningApplication,
        exclusions: Set<String>
    ) -> Bool {
        guard !application.isTerminated,
              application.activationPolicy == .regular,
              let bundleIdentifier = application.bundleIdentifier?.lowercased(),
              !isExcludedIdentifier(bundleIdentifier, exclusions: exclusions),
              let bundleURL = application.bundleURL,
              bundleURL.pathExtension.lowercased() == "app"
        else {
            return false
        }
        return true
    }

    private static func installedTarget(
        at bundleURL: URL,
        exclusions: Set<String>
    ) -> InstalledApplicationTarget? {
        let resourceValues = try? bundleURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard bundleURL.isFileURL,
              bundleURL.pathExtension.lowercased() == "app",
              resourceValues?.isDirectory == true,
              resourceValues?.isSymbolicLink != true,
              let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true,
              bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
              let signingIdentifier = RunningCodeIdentity.signingIdentifier(bundleURL: bundleURL),
              !isExcluded(
                  ApplicationIdentity(
                      bundleIdentifier: bundleIdentifier,
                      signingIdentifier: signingIdentifier
                  ),
                  exclusions: exclusions
              )
        else {
            return nil
        }
        return InstalledApplicationTarget(
            identity: ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                signingIdentifier: signingIdentifier
            ),
            bundleURL: bundleURL
        )
    }

    private static func displayNames(for bundleURL: URL) -> [String] {
        let bundle = Bundle(url: bundleURL)
        return [
            bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
            bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String,
            bundleURL.deletingPathExtension().lastPathComponent,
        ].compactMap { $0 }
    }

    static func applicationMetadataMatches(target: String, at bundleURL: URL) -> Bool {
        guard let bundleIdentifier = Bundle(url: bundleURL)?.bundleIdentifier else {
            return false
        }
        return ApplicationTargetMatching.matches(
            target: target,
            bundleIdentifier: bundleIdentifier,
            displayNames: displayNames(for: bundleURL)
        )
    }

    private static func installedApplicationURLs() throws -> [URL] {
        let manager = FileManager.default
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices", isDirectory: true),
        ]
        if let userApplications = manager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(userApplications)
        }
        return try installedApplicationURLs(
            in: roots,
            maximumApplications: maximumDiscoveredApplications
        )
    }

    static func installedApplicationURLs(
        in roots: [URL],
        maximumApplications: Int
    ) throws -> [URL] {
        guard maximumApplications > 0 else { throw CaptureFailure.applicationAmbiguous }
        let manager = FileManager.default
        var applications: [URL] = []
        for root in roots {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let entry as URL in enumerator {
                guard entry.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                let keys: Set<URLResourceKey> = [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
                let values = try? entry.resourceValues(forKeys: keys)
                guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
                guard applications.count < maximumApplications else {
                    throw CaptureFailure.applicationAmbiguous
                }
                applications.append(entry)
            }
        }
        return applications
    }

    private static func normalizedExclusions(_ exclusions: Set<String>) -> Set<String> {
        protectedBundleIdentifiers.union(exclusions.map { $0.lowercased() })
    }

    static func isExcluded(
        _ identity: ApplicationIdentity,
        exclusions: Set<String>
    ) -> Bool {
        isExcludedIdentifier(identity.bundleIdentifier, exclusions: exclusions)
            || isExcludedIdentifier(identity.signingIdentifier, exclusions: exclusions)
    }

    private static func isExcludedIdentifier(
        _ identifier: String,
        exclusions: Set<String>
    ) -> Bool {
        let normalized = identifier.lowercased()
        return exclusions.contains {
            normalized == $0 || normalized.hasPrefix($0 + ".")
        }
    }
}
