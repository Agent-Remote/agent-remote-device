import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Foundation

@MainActor
public final class PermissionController: ObservableObject {
    @Published public private(set) var accessibilityGranted = false
    @Published public private(set) var screenRecordingGranted = false
    @Published public private(set) var restartRequired = false

    public var allGranted: Bool {
        accessibilityGranted && screenRecordingGranted && !restartRequired
    }

    public init() {
        refresh()
    }

    public func refresh() {
        accessibilityGranted = AXIsProcessTrusted()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    public func requestAccessibility() {
        let options = [
            "AXTrustedCheckOptionPrompt": true,
        ] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
    }

    public func requestScreenRecording() {
        let previouslyGranted = screenRecordingGranted
        screenRecordingGranted = CGRequestScreenCaptureAccess()
        restartRequired = !previouslyGranted && screenRecordingGranted
    }

    public func openAccessibilitySettings() {
        openPrivacySettings(anchor: "Privacy_Accessibility")
    }

    public func openScreenRecordingSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
