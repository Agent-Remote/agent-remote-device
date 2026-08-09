import AppKit
import ApplicationServices
import DeviceAppCore
import DeviceIPC
import DeviceSecurity
import Foundation
import Security

enum LocalApplicationDiscovery {
    static func approvalPresentation(generation: UInt64) throws -> ApprovalPresentation {
        let ownIdentifier = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        let applications = NSWorkspace.shared.runningApplications.compactMap {
            application -> ApprovalCandidate? in
            guard application.activationPolicy == .regular,
                  !application.isTerminated,
                  let bundleIdentifier = application.bundleIdentifier,
                  bundleIdentifier != ownIdentifier,
                  isBoundedIdentifier(bundleIdentifier),
                  let signingIdentifier = signingIdentifier(for: application),
                  isBoundedIdentifier(signingIdentifier)
            else {
                return nil
            }
            let identity = ApplicationIdentity(
                bundleIdentifier: bundleIdentifier,
                signingIdentifier: signingIdentifier
            )
            guard seen.insert(identity.stableDigest).inserted else { return nil }
            let classification = ApplicationPolicy.classify(bundleIdentifier: bundleIdentifier)
            let displayName = String(
                (application.localizedName ?? bundleIdentifier).prefix(128)
            )
            return ApprovalCandidate(
                application: identity,
                displayName: displayName,
                requestedControlLevel: classification.controlLevel ?? .viewOnly,
                classification: classification,
                clipboardRequested: true
            )
        }
        .sorted {
            if $0.displayName == $1.displayName { return $0.id < $1.id }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return try ApprovalPresentation(
            generation: generation,
            applications: Array(applications.prefix(32)),
            hiddenApplicationCount: 0
        )
    }

    @MainActor
    static func activate(
        target: String,
        approvals: [LocalApproval]
    ) async throws {
        let matches = approvals.compactMap { approval -> NSRunningApplication? in
            let applications = NSRunningApplication.runningApplications(
                withBundleIdentifier: approval.application.bundleIdentifier
            )
            return applications.first(where: { application in
                guard approval.application.bundleIdentifier.caseInsensitiveCompare(target)
                        == .orderedSame
                        || application.localizedName?.caseInsensitiveCompare(target)
                        == .orderedSame
                else {
                    return false
                }
                return signingIdentifier(for: application)
                    == approval.application.signingIdentifier
            })
        }
        guard matches.count == 1, let application = matches.first,
              let bundleURL = application.bundleURL
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        requestWorkspaceActivation(at: bundleURL)
        for attempt in 0 ..< 20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
            {
                return
            }
            if attempt == 10 {
                requestAccessibilityActivation(application)
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        // Reissue the non-blocking workspace request before the longer fallback window.
        requestWorkspaceActivation(at: bundleURL)
        for attempt in 0 ..< 80 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier
                == application.processIdentifier
            {
                return
            }
            if attempt.isMultiple(of: 10) {
                requestAccessibilityActivation(application)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw DeviceIPCFailure.serviceUnavailable
    }

    @MainActor
    private static func requestWorkspaceActivation(at bundleURL: URL) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        ) { _, _ in }
    }

    @MainActor
    private static func requestAccessibilityActivation(_ application: NSRunningApplication) {
        _ = application.unhide()

        let accessibilityApplication = AXUIElementCreateApplication(
            application.processIdentifier
        )
        _ = AXUIElementSetAttributeValue(
            accessibilityApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            accessibilityApplication,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
            let windows = rawWindows as? [AXUIElement]
        else { return }
        for window in windows.prefix(8) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func isBoundedIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && value.utf8.allSatisfy { (0x21 ... 0x7e).contains($0) }
    }

    private static func signingIdentifier(for application: NSRunningApplication) -> String? {
        guard let bundleURL = application.bundleURL else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        let validationFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures
        )
        guard SecStaticCodeCheckValidity(staticCode, validationFlags, nil) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any]
        else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }
}
