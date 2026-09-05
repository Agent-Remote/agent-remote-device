import AppKit
import CoreGraphics
import CryptoKit
import DeviceProtocol
import DeviceSecurity
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import Security
import UniformTypeIdentifiers

public enum CaptureImageEncoding: Equatable, Sendable {
    case png
    case jpeg(quality: Double)

    public var mimeType: String {
        switch self {
        case .png: "image/png"
        case .jpeg: "image/jpeg"
        }
    }
}

public struct CaptureProfile: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int
    public let encoding: CaptureImageEncoding

    public init(
        maximumWidth: Int,
        maximumHeight: Int,
        encoding: CaptureImageEncoding = .png
    ) {
        precondition(maximumWidth > 0 && maximumHeight > 0)
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
        self.encoding = encoding
    }
}

public struct CapturedWindow: @unchecked Sendable {
    public let pngData: Data
    public let encoding: CaptureImageEncoding
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let coordinateFrame: CGRect
    public let processID: pid_t
    public let application: ApplicationIdentity
    public let applicationWindowIDs: Set<CGWindowID>
    public let displayFingerprint: String
    public let windowTitle: String?

    public init(
        pngData: Data,
        encoding: CaptureImageEncoding = .png,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        windowID: CGWindowID,
        windowFrame: CGRect,
        coordinateFrame: CGRect,
        processID: pid_t,
        application: ApplicationIdentity,
        applicationWindowIDs: Set<CGWindowID>? = nil,
        displayFingerprint: String,
        windowTitle: String? = nil
    ) {
        self.pngData = pngData
        self.encoding = encoding
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.coordinateFrame = coordinateFrame
        self.processID = processID
        self.application = application
        self.applicationWindowIDs = applicationWindowIDs ?? [windowID]
        self.displayFingerprint = displayFingerprint
        self.windowTitle = windowTitle
    }
}

public struct WindowContext: Equatable, Sendable {
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let processID: pid_t
    public let application: ApplicationIdentity
    public let applicationWindowIDs: Set<CGWindowID>
    public let displayFingerprint: String
    public let windowTitle: String?

    public init(
        windowID: CGWindowID,
        windowFrame: CGRect,
        processID: pid_t,
        application: ApplicationIdentity,
        applicationWindowIDs: Set<CGWindowID>? = nil,
        displayFingerprint: String,
        windowTitle: String? = nil
    ) {
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.processID = processID
        self.application = application
        self.applicationWindowIDs = applicationWindowIDs ?? [windowID]
        self.displayFingerprint = displayFingerprint
        self.windowTitle = windowTitle
    }
}

struct WindowCandidate: Equatable, Sendable {
    let windowID: CGWindowID
    let frame: CGRect
    let processID: pid_t
    let isOnScreen: Bool
    let isActive: Bool

    init(
        windowID: CGWindowID,
        frame: CGRect,
        processID: pid_t,
        isOnScreen: Bool = false,
        isActive: Bool = false
    ) {
        self.windowID = windowID
        self.frame = frame
        self.processID = processID
        self.isOnScreen = isOnScreen
        self.isActive = isActive
    }
}

private struct ResolvedWindow {
    let processID: pid_t
    let content: SCShareableContent
    let window: SCWindow?
    let windowID: CGWindowID
    let windowFrame: CGRect
    let windowTitle: String?
    let applicationWindowIDs: Set<CGWindowID>
    let display: SCDisplay
    let captureFrame: CGRect
}

public extension CapturedWindow {
    var windowContext: WindowContext {
        WindowContext(
            windowID: windowID,
            windowFrame: windowFrame,
            processID: processID,
            application: application,
            applicationWindowIDs: applicationWindowIDs,
            displayFingerprint: displayFingerprint,
            windowTitle: windowTitle
        )
    }
}

public enum CaptureFailure: Error, Equatable, Sendable {
    case screenRecordingPermissionMissing
    case approvedApplicationNotFrontmost
    case requestedApplicationNotApprovedOrAmbiguous
    case approvedApplicationNotRunning
    case applicationActivationRejected
    case applicationActivationTimedOut
    case signingIdentifierMismatch
    case approvedWindowMissing
    case displayMissing
    case operationTimedOut
    case invalidCaptureSize
    case encodingFailed
    case cropOutOfBounds
    case applicationAmbiguous
    case applicationNotFound
    case applicationNotRunning
    case protectedApplication
    case applicationLaunchTimeout
    case applicationLaunchResultUnknown

    public var diagnosticCode: String {
        switch self {
        case .screenRecordingPermissionMissing: "screen_recording_permission_missing"
        case .approvedApplicationNotFrontmost: "approved_application_not_frontmost"
        case .requestedApplicationNotApprovedOrAmbiguous:
            "requested_application_not_approved_or_ambiguous"
        case .approvedApplicationNotRunning: "approved_application_not_running"
        case .applicationActivationRejected: "approved_application_activation_rejected"
        case .applicationActivationTimedOut: "approved_application_activation_timed_out"
        case .signingIdentifierMismatch: "application_identity_mismatch"
        case .approvedWindowMissing: "approved_window_not_visible"
        case .displayMissing: "window_display_not_found"
        case .operationTimedOut: "screenshot_capture_timed_out"
        case .invalidCaptureSize: "invalid_capture_size"
        case .encodingFailed: "screenshot_png_encoding_failed"
        case .cropOutOfBounds: "zoom_region_out_of_bounds"
        case .applicationAmbiguous: "ambiguous_application"
        case .applicationNotFound: "application_not_found"
        case .applicationNotRunning: "application_not_running"
        case .protectedApplication: "protected_application"
        case .applicationLaunchTimeout: "application_launch_timeout"
        case .applicationLaunchResultUnknown: "application_launch_result_unknown"
        }
    }

    public var userMessage: String {
        switch self {
        case .screenRecordingPermissionMissing:
            "Mac screen recording permission is missing for Agent Remote Device."
        case .approvedApplicationNotFrontmost:
            "The target application is not the frontmost Mac application."
        case .requestedApplicationNotApprovedOrAmbiguous:
            "The requested application does not uniquely match a running eligible application."
        case .approvedApplicationNotRunning:
            "The target application is not currently running on the Mac."
        case .applicationActivationRejected:
            "macOS rejected the request to bring the target application to the foreground."
        case .applicationActivationTimedOut:
            "The target application did not become frontmost within five seconds."
        case .signingIdentifierMismatch:
            "The frontmost application does not match the approved code identity."
        case .approvedWindowMissing:
            "No visible window was found for the target application."
        case .displayMissing:
            "The approved window is not attached to an active display."
        case .operationTimedOut:
            "macOS did not complete the screenshot operation within eight seconds."
        case .invalidCaptureSize:
            "The approved window has an invalid screenshot size."
        case .encodingFailed:
            "The Mac screenshot could not be encoded as PNG."
        case .cropOutOfBounds:
            "The requested zoom region is outside the latest screenshot."
        case .applicationAmbiguous:
            "The application name matches more than one eligible GUI application. Use a Bundle ID."
        case .applicationNotFound:
            "No eligible installed GUI application matches the requested Bundle ID or name."
        case .applicationNotRunning:
            "The requested application is installed but is not currently running."
        case .protectedApplication:
            "The requested application is excluded from this device session."
        case .applicationLaunchTimeout:
            "The application did not expose an eligible window before the launch deadline."
        case .applicationLaunchResultUnknown:
            "macOS accepted the launch request, but the resulting application state could not be verified."
        }
    }
}

public struct WindowCapture: Sendable {
    public static let operationTimeout: Duration = .seconds(8)
    private static let lightweightActivationAttempts = 20
    private static let workspaceActivationAttempts = 80

    private let profile: CaptureProfile
    private let excludedBundleIdentifier: String

    public init(profile: CaptureProfile, excludedBundleIdentifier: String = "dev.agentremote.device") {
        self.profile = profile
        self.excludedBundleIdentifier = excludedBundleIdentifier
    }

    @MainActor
    public func capture(
        application: ApplicationIdentity,
        requiredWindowID: CGWindowID? = nil,
        requiredProcessID: pid_t? = nil
    ) async throws -> CapturedWindow {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingPermissionMissing
        }
        let resolved = try await resolve(
            application: application,
            requiredWindowID: requiredWindowID,
            requiredProcessID: requiredProcessID,
            preferFocusedWindow: false
        )
        let size = Self.scaledSize(
            sourceWidth: resolved.captureFrame.width,
            sourceHeight: resolved.captureFrame.height,
            maximumWidth: profile.maximumWidth,
            maximumHeight: profile.maximumHeight
        )
        guard size.width > 0, size.height > 0,
              size.width <= Int(UInt16.max), size.height <= Int(UInt16.max)
        else {
            throw CaptureFailure.invalidCaptureSize
        }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.ignoreShadowsSingleWindow = true
        let filter: SCContentFilter
        if let window = resolved.window {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            guard let approvedApplication = resolved.content.applications.first(where: {
                $0.processID == resolved.processID
            }) else {
                throw CaptureFailure.approvedWindowMissing
            }
            filter = SCContentFilter(
                display: resolved.display,
                including: [approvedApplication],
                exceptingWindows: []
            )
            configuration.sourceRect = Self.displayLocalRect(
                resolved.captureFrame,
                displayFrame: resolved.display.frame
            )
        }
        let image = try await Self.withOperationTimeout {
            try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }
        guard let imageData = Self.encodedData(image, encoding: profile.encoding) else {
            throw CaptureFailure.encodingFailed
        }
        return CapturedWindow(
            pngData: imageData,
            encoding: profile.encoding,
            pixelWidth: UInt16(size.width),
            pixelHeight: UInt16(size.height),
            windowID: resolved.windowID,
            windowFrame: resolved.windowFrame,
            coordinateFrame: resolved.captureFrame,
            processID: resolved.processID,
            application: application,
            applicationWindowIDs: resolved.applicationWindowIDs,
            displayFingerprint: Self.displayFingerprint(
                resolved.content.displays,
                selected: resolved.display
            ),
            windowTitle: resolved.windowTitle
        )
    }

    @MainActor
    public func context(
        application: ApplicationIdentity,
        requiredWindowID: CGWindowID? = nil,
        requiredProcessID: pid_t? = nil,
        preferFocusedWindow: Bool = false,
        excludedWindowIDs: Set<CGWindowID> = []
    ) async throws -> WindowContext {
        let resolved = try await resolve(
            application: application,
            requiredWindowID: requiredWindowID,
            requiredProcessID: requiredProcessID,
            preferFocusedWindow: preferFocusedWindow,
            excludedWindowIDs: excludedWindowIDs
        )
        return WindowContext(
            windowID: resolved.windowID,
            windowFrame: resolved.windowFrame,
            processID: resolved.processID,
            application: application,
            applicationWindowIDs: resolved.applicationWindowIDs,
            displayFingerprint: Self.displayFingerprint(
                resolved.content.displays,
                selected: resolved.display
            ),
            windowTitle: resolved.windowTitle
        )
    }

    @MainActor
    private func resolve(
        application: ApplicationIdentity,
        requiredWindowID: CGWindowID?,
        requiredProcessID: pid_t? = nil,
        preferFocusedWindow: Bool,
        excludedWindowIDs: Set<CGWindowID> = []
    ) async throws -> ResolvedWindow {
        guard application.bundleIdentifier != excludedBundleIdentifier else {
            throw CaptureFailure.applicationActivationRejected
        }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard !running.isEmpty else {
            throw CaptureFailure.approvedApplicationNotRunning
        }
        let matchingProcessIDs = try Self.matchingProcessIDs(
            running.map {
                (
                    processID: $0.processIdentifier,
                    signingIdentifier: Self.signingIdentifier(for: $0)
                )
            },
            expectedSigningIdentifier: application.signingIdentifier,
            requiredProcessID: requiredProcessID
        )
        let content = try await Self.withOperationTimeout {
            // Approved full-screen windows can live on another Space while the user
            // keeps a terminal frontmost.
            try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: false
            )
        }
        let shareableCandidates = Self.matchingWindowCandidates(
            content.windows.compactMap { window in
                guard let processID = window.owningApplication?.processID else { return nil }
                return WindowCandidate(
                    windowID: window.windowID,
                    frame: window.frame,
                    processID: processID,
                    isOnScreen: window.isOnScreen,
                    isActive: window.isActive
                )
            },
            processIDs: matchingProcessIDs
        )
        let visibleCandidates = Self.frontToBackWindowCandidates(
            processIDs: matchingProcessIDs
        )
        let candidates = Self.selectionCandidates(
            shareable: shareableCandidates,
            visible: visibleCandidates
        )
        let frontmostProcessID: pid_t? = if requiredWindowID == nil {
            try await Self.frontmostShareableProcessID(content: content)
        } else {
            nil
        }
        let selectionProcessIDs = try Self.windowSelectionProcessIDs(
            matchingProcessIDs: matchingProcessIDs,
            candidates: candidates,
            frontmostProcessID: frontmostProcessID,
            hasRequiredWindow: requiredWindowID != nil
        )
        let selectionCandidates = candidates.filter {
            selectionProcessIDs.contains($0.processID)
        }
        let selectionVisibleCandidates = visibleCandidates.filter {
            selectionProcessIDs.contains($0.processID)
        }
        let selectionShareableCandidates = shareableCandidates.filter {
            selectionProcessIDs.contains($0.processID)
        }
        let focusedWindowID = Self.focusedWindowID(processIDs: selectionProcessIDs)
        let selectedWindowID = Self.preferredWindowID(
            candidates: selectionCandidates.map { ($0.windowID, $0.frame) },
            frontToBackWindowIDs: selectionVisibleCandidates.map(\.windowID),
            activeWindowIDs: selectionShareableCandidates.filter(\.isActive).map(\.windowID),
            shareableWindowIDs: selectionShareableCandidates.map(\.windowID),
            focusedWindowID: focusedWindowID,
            requiredWindowID: requiredWindowID,
            preferFocusedWindow: preferFocusedWindow,
            excludedWindowIDs: excludedWindowIDs
        )
        guard let selectedWindowID,
              let selectedCandidate = selectionCandidates.first(where: {
                  $0.windowID == selectedWindowID
              })
        else {
            throw CaptureFailure.approvedWindowMissing
        }
        let window = content.windows.first(where: {
            $0.windowID == selectedWindowID
                && $0.owningApplication?.processID == selectedCandidate.processID
        })
        if window == nil {
            guard visibleCandidates.contains(where: {
                $0.windowID == selectedWindowID
                    && $0.processID == selectedCandidate.processID
                    && $0.frame.width >= 100
                    && $0.frame.height >= 100
            }) else {
                throw CaptureFailure.approvedWindowMissing
            }
        }
        guard let display = Self.selectedDisplay(
            for: selectedCandidate.frame,
            from: content.displays
        ) else {
            throw CaptureFailure.displayMissing
        }
        let captureFrame = selectedCandidate.frame
        guard !captureFrame.isNull, !captureFrame.isInfinite,
              captureFrame.width > 0, captureFrame.height > 0
        else {
            throw CaptureFailure.displayMissing
        }
        return ResolvedWindow(
            processID: selectedCandidate.processID,
            content: content,
            window: window,
            windowID: selectedWindowID,
            windowFrame: selectedCandidate.frame,
            windowTitle: window?.title,
            applicationWindowIDs: Set(selectionCandidates.map(\.windowID)),
            display: display,
            captureFrame: captureFrame
        )
    }

    @discardableResult
    public func activate(
        application: ApplicationIdentity,
        processID requiredProcessID: pid_t? = nil,
        windowID requiredWindowID: CGWindowID? = nil
    ) async throws -> pid_t {
        guard application.bundleIdentifier != excludedBundleIdentifier else {
            throw CaptureFailure.applicationActivationRejected
        }
        let target = try await Self.activationTarget(
            application: application,
            requiredProcessID: requiredProcessID
        )
        let isAlreadyFrontmost = await MainActor.run {
            if let requiredWindowID {
                Self.isWindowFrontmost(
                    processID: target.processID,
                    windowID: requiredWindowID
                )
            } else {
                Self.isProcessFrontmost(target.processID)
            }
        }
        if isAlreadyFrontmost { return target.processID }

        await MainActor.run {
            Self.requestActivation(
                processID: target.processID,
                windowID: requiredWindowID
            )
        }
        if let bundleURL = target.bundleURL {
            await Self.requestWorkspaceActivation(at: bundleURL)
        }
        if try await Self.waitUntilFrontmost(
            processID: target.processID,
            windowID: requiredWindowID,
            attempts: Self.lightweightActivationAttempts
        ) {
            return target.processID
        }

        if let bundleURL = target.bundleURL {
            await Self.requestWorkspaceActivation(at: bundleURL)
        }
        await MainActor.run {
            Self.requestActivation(
                processID: target.processID,
                windowID: requiredWindowID
            )
        }

        if try await Self.waitUntilFrontmost(
            processID: target.processID,
            windowID: requiredWindowID,
            attempts: Self.workspaceActivationAttempts
        ) {
            return target.processID
        }
        throw CaptureFailure.applicationActivationTimedOut
    }

    private struct ActivationTarget: Sendable {
        let processID: pid_t
        let bundleURL: URL?
    }

    @MainActor
    private static func activationTarget(
        application: ApplicationIdentity,
        requiredProcessID: pid_t?
    ) throws -> ActivationTarget {
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).filter {
            !$0.isTerminated
                && (requiredProcessID == nil || $0.processIdentifier == requiredProcessID)
        }
        guard !running.isEmpty else {
            throw CaptureFailure.approvedApplicationNotRunning
        }
        guard let candidate = running.first(where: {
            signingIdentifier(for: $0) == application.signingIdentifier
        }) else {
            throw CaptureFailure.signingIdentifierMismatch
        }
        return ActivationTarget(
            processID: candidate.processIdentifier,
            bundleURL: candidate.bundleURL
        )
    }

    private static func waitUntilFrontmost(
        processID: pid_t,
        windowID: CGWindowID?,
        attempts: Int
    ) async throws -> Bool {
        for attempt in 0 ..< attempts {
            let isFrontmost = await MainActor.run {
                if let windowID {
                    Self.isWindowFrontmost(processID: processID, windowID: windowID)
                } else {
                    Self.isProcessFrontmost(processID)
                }
            }
            if isFrontmost { return true }
            if attempt > 0, attempt.isMultiple(of: 10) {
                await MainActor.run {
                    requestActivation(processID: processID, windowID: windowID)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @MainActor
    private static func requestWorkspaceActivation(at bundleURL: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        _ = try? await NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        )
    }

    @MainActor
    static func isFrontmost(
        application: ApplicationIdentity,
        requiredProcessID: pid_t?
    ) -> Bool {
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).filter {
            !$0.isTerminated
                && (requiredProcessID == nil || $0.processIdentifier == requiredProcessID)
                && signingIdentifier(for: $0) == application.signingIdentifier
        }
        guard candidates.count == 1, let candidate = candidates.first else { return false }
        return isProcessFrontmost(candidate.processIdentifier)
    }

    @MainActor
    private static func isProcessFrontmost(_ processID: pid_t) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processID),
              !application.isTerminated
        else {
            return false
        }
        return frontmostProcessID() == processID
    }

    @MainActor
    public static func frontmostProcessID() -> pid_t? {
        preferredFrontmostProcessID(
            windowServerProcessID: frontmostWindowProcessID(),
            accessibilityProcessID: accessibilityFocusedApplicationProcessID(),
            activeProcessID: NSWorkspace.shared.runningApplications.first(where: { $0.isActive })?
                .processIdentifier,
            workspaceProcessID: NSWorkspace.shared.frontmostApplication?.processIdentifier
        )
    }

    @MainActor
    public static func frontmostShareableProcessID() async throws -> pid_t? {
        let content = try await withOperationTimeout {
            try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        }
        return try await frontmostShareableProcessID(content: content)
    }

    @MainActor
    private static func frontmostShareableProcessID(
        content: SCShareableContent
    ) async throws -> pid_t? {
        guard var candidate = content.windows.first(where: { isSubstantialLayerZeroWindow($0) })
        else {
            return frontmostProcessID()
        }
        var visitedWindowIDs: Set<CGWindowID> = [candidate.windowID]
        for _ in 0 ..< min(content.windows.count, 128) {
            let lowerWindow = candidate
            let windowsAbove = try await withOperationTimeout(.seconds(2)) {
                try await SCShareableContent.excludingDesktopWindows(
                    true,
                    onScreenWindowsOnlyAbove: lowerWindow
                )
            }
            guard let next = windowsAbove.windows.first(where: {
                isSubstantialLayerZeroWindow($0) && !visitedWindowIDs.contains($0.windowID)
            }) else {
                return candidate.owningApplication?.processID
            }
            candidate = next
            visitedWindowIDs.insert(next.windowID)
        }
        return nil
    }

    private static func isSubstantialLayerZeroWindow(_ window: SCWindow) -> Bool {
        window.windowLayer == 0
            && window.frame.width >= 100
            && window.frame.height >= 100
            && window.owningApplication != nil
    }

    static func preferredFrontmostProcessID(
        windowServerProcessID: pid_t?,
        accessibilityProcessID: pid_t?,
        activeProcessID: pid_t?,
        workspaceProcessID: pid_t?
    ) -> pid_t? {
        windowServerProcessID ?? accessibilityProcessID ?? activeProcessID ?? workspaceProcessID
    }

    @MainActor
    public static func isWindowFrontmost(processID: pid_t, windowID: CGWindowID) -> Bool {
        guard isProcessFrontmost(processID) else { return false }
        let frontToBackWindowIDs = frontToBackWindowCandidates(
            processIDs: [processID]
        ).filter {
            $0.frame.width >= 100 && $0.frame.height >= 100
        }.map(\.windowID)
        return windowIsFrontmost(
            processIsFrontmost: true,
            frontToBackWindowIDs: frontToBackWindowIDs,
            focusedWindowID: focusedWindowID(processIDs: [processID]),
            requiredWindowID: windowID
        )
    }

    static func windowIsFrontmost(
        processIsFrontmost: Bool,
        frontToBackWindowIDs: [CGWindowID],
        focusedWindowID: CGWindowID?,
        requiredWindowID: CGWindowID
    ) -> Bool {
        guard processIsFrontmost else { return false }
        if let visibleFrontmost = frontToBackWindowIDs.first {
            return visibleFrontmost == requiredWindowID
        }
        return focusedWindowID == requiredWindowID
    }

    private static func frontmostWindowProcessID() -> pid_t? {
        guard let values = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        return values.lazy.compactMap { value -> pid_t? in
            guard (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let owner = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds),
                  frame.width >= 100, frame.height >= 100
            else { return nil }
            return owner
        }.first
    }

    private static func accessibilityFocusedApplicationProcessID() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.2)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return nil
        }
        let focusedApplication = unsafeDowncast(focusedValue, to: AXUIElement.self)
        var processID: pid_t = 0
        guard AXUIElementGetPid(focusedApplication, &processID) == .success,
              processID > 0
        else {
            return nil
        }
        return processID
    }

    @MainActor
    private static func requestProcessActivation(processID: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return }
        _ = application.unhide()
        _ = application.activate(options: [])
        requestAccessibilityActivation(processID: processID)
    }

    @MainActor
    private static func requestActivation(processID: pid_t, windowID: CGWindowID?) {
        requestProcessActivation(processID: processID)
        guard let windowID,
              let window = accessibilityWindow(processID: processID, windowID: windowID)
        else { return }
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            window
        )
        _ = AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }

    @MainActor
    private static func accessibilityWindow(
        processID: pid_t,
        windowID: CGWindowID
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.2)
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
            let windows = rawWindows as? [AXUIElement]
        else { return nil }
        return windows.first { accessibilityWindowID($0) == windowID }
    }

    @MainActor
    private static func requestAccessibilityActivation(processID: pid_t) {
        let accessibilityApplication = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetAttributeValue(
            accessibilityApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
    }

    public static func restoreUserApplication(
        processID: pid_t,
        whileFrontmostProcessIsOneOf remotelyActivatedProcessIDs: Set<pid_t>
    ) async {
        let bundleURL = await MainActor.run { () -> URL? in
            guard let application = NSRunningApplication(processIdentifier: processID),
                  !application.isTerminated
            else { return nil }
            return application.bundleURL
        }
        guard bundleURL != nil else { return }

        for attempt in 0 ..< 20 {
            let status = await MainActor.run { () -> Int in
                if isProcessFrontmost(processID) { return 1 }
                guard remotelyActivatedProcessIDs.contains(where: isProcessFrontmost) else {
                    return 0
                }
                requestProcessActivation(processID: processID)
                return 2
            }
            if status != 2 { return }
            if attempt == 9, let bundleURL {
                await requestWorkspaceActivation(at: bundleURL)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public static func cropped(_ capture: CapturedWindow, to region: Region) throws -> CapturedWindow {
        let maximumX = UInt32(region.x) + UInt32(region.width)
        let maximumY = UInt32(region.y) + UInt32(region.height)
        guard region.width > 0, region.height > 0,
              maximumX <= UInt32(capture.pixelWidth),
              maximumY <= UInt32(capture.pixelHeight),
              let source = CGImageSourceCreateWithData(capture.pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let croppedImage = image.cropping(to: CGRect(
                  x: Int(region.x),
                  y: Int(region.y),
                  width: Int(region.width),
                  height: Int(region.height)
              )),
              let imageData = encodedData(croppedImage, encoding: capture.encoding)
        else {
            throw CaptureFailure.cropOutOfBounds
        }

        let xScale = capture.coordinateFrame.width / CGFloat(capture.pixelWidth)
        let yScale = capture.coordinateFrame.height / CGFloat(capture.pixelHeight)
        let coordinateFrame = CGRect(
            x: capture.coordinateFrame.minX + CGFloat(region.x) * xScale,
            y: capture.coordinateFrame.minY + CGFloat(region.y) * yScale,
            width: CGFloat(region.width) * xScale,
            height: CGFloat(region.height) * yScale
        )
        return CapturedWindow(
            pngData: imageData,
            encoding: capture.encoding,
            pixelWidth: region.width,
            pixelHeight: region.height,
            windowID: capture.windowID,
            windowFrame: capture.windowFrame,
            coordinateFrame: coordinateFrame,
            processID: capture.processID,
            application: capture.application,
            applicationWindowIDs: capture.applicationWindowIDs,
            displayFingerprint: capture.displayFingerprint,
            windowTitle: capture.windowTitle
        )
    }

    public static func scaledSize(
        sourceWidth: CGFloat,
        sourceHeight: CGFloat,
        maximumWidth: Int,
        maximumHeight: Int
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, maximumWidth > 0, maximumHeight > 0 else {
            return (0, 0)
        }
        let scale = min(
            CGFloat(maximumWidth) / sourceWidth,
            CGFloat(maximumHeight) / sourceHeight,
            1
        )
        return (
            max(1, Int((sourceWidth * scale).rounded(.down))),
            max(1, Int((sourceHeight * scale).rounded(.down)))
        )
    }

    static func encodedData(
        _ image: CGImage,
        encoding: CaptureImageEncoding
    ) -> Data? {
        let data = NSMutableData()
        let type: UTType
        let properties: CFDictionary?
        switch encoding {
        case .png:
            type = .png
            properties = nil
        case let .jpeg(quality):
            guard (0 ... 1).contains(quality) else { return nil }
            type = .jpeg
            properties = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        }
        guard let destination = CGImageDestinationCreateWithData(
            data,
            type.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func signingIdentifier(for application: NSRunningApplication) -> String? {
        RunningCodeIdentity.signingIdentifier(processID: application.processIdentifier)
    }

    static func matchingProcessIDs(
        _ candidates: [(processID: pid_t, signingIdentifier: String?)],
        expectedSigningIdentifier: String,
        requiredProcessID: pid_t?
    ) throws -> Set<pid_t> {
        let eligible = candidates.filter {
            requiredProcessID == nil || $0.processID == requiredProcessID
        }
        guard !eligible.isEmpty else {
            throw CaptureFailure.approvedApplicationNotRunning
        }
        let matching = eligible.filter {
            $0.signingIdentifier == expectedSigningIdentifier
        }
        guard !matching.isEmpty else {
            throw CaptureFailure.signingIdentifierMismatch
        }
        return Set(matching.map(\.processID))
    }

    static func displayFingerprint(_ displays: [SCDisplay], selected: SCDisplay) -> String {
        let layout = displays
            .sorted { $0.displayID < $1.displayID }
            .map { "\($0.displayID):\($0.frame.origin.x):\($0.frame.origin.y):\($0.frame.width):\($0.frame.height)" }
            .joined(separator: "|")
        let value = "selected=\(selected.displayID)|\(layout)"
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func selectedDisplayID(
        for windowFrame: CGRect,
        from displays: [(displayID: CGDirectDisplayID, frame: CGRect)]
    ) -> CGDirectDisplayID? {
        displays.compactMap { display -> (displayID: CGDirectDisplayID, area: CGFloat)? in
            let intersection = display.frame.intersection(windowFrame)
            guard !intersection.isNull, !intersection.isInfinite,
                  intersection.width > 0, intersection.height > 0
            else {
                return nil
            }
            return (display.displayID, intersection.width * intersection.height)
        }.max { left, right in
            if left.area == right.area {
                return left.displayID > right.displayID
            }
            return left.area < right.area
        }?.displayID
    }

    static func selectedDisplay(for windowFrame: CGRect, from displays: [SCDisplay]) -> SCDisplay? {
        let selectedID = selectedDisplayID(
            for: windowFrame,
            from: displays.map { ($0.displayID, $0.frame) }
        )
        return displays.first { $0.displayID == selectedID }
    }

    static func displayLocalRect(_ frame: CGRect, displayFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - displayFrame.minX,
            y: frame.minY - displayFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    static func preferredWindowID(
        candidates: [(windowID: CGWindowID, frame: CGRect)],
        frontToBackWindowIDs: [CGWindowID],
        activeWindowIDs: [CGWindowID] = [],
        shareableWindowIDs: [CGWindowID] = [],
        focusedWindowID: CGWindowID? = nil,
        requiredWindowID: CGWindowID? = nil,
        preferFocusedWindow: Bool = false,
        excludedWindowIDs: Set<CGWindowID> = []
    ) -> CGWindowID? {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0.frame) })
        if let requiredWindowID {
            return byID[requiredWindowID] == nil ? nil : requiredWindowID
        }
        let eligibleWindowIDs = Set(byID.keys).subtracting(excludedWindowIDs)
        let eligibleFocusedWindowID: CGWindowID? = focusedWindowID.flatMap { windowID in
            guard eligibleWindowIDs.contains(windowID),
                  let frame = byID[windowID],
                  frame.width >= 100,
                  frame.height >= 100
            else { return nil }
            return windowID
        }
        if preferFocusedWindow, let eligibleFocusedWindowID {
            return eligibleFocusedWindowID
        }
        if let frontmostSubstantial = frontToBackWindowIDs.first(where: { windowID in
            guard eligibleWindowIDs.contains(windowID),
                  let frame = byID[windowID]
            else { return false }
            return frame.width >= 100 && frame.height >= 100
        }) {
            return frontmostSubstantial
        }
        if let eligibleFocusedWindowID {
            return eligibleFocusedWindowID
        }
        if let activeWindowID = activeWindowIDs.first(where: { windowID in
            guard eligibleWindowIDs.contains(windowID),
                  let frame = byID[windowID]
            else { return false }
            return frame.width >= 100 && frame.height >= 100
        }) {
            return activeWindowID
        }
        if let shareableSubstantial = shareableWindowIDs.first(where: { windowID in
            guard eligibleWindowIDs.contains(windowID),
                  let frame = byID[windowID]
            else { return false }
            return frame.width >= 100 && frame.height >= 100
        }) {
            return shareableSubstantial
        }
        return candidates.filter { eligibleWindowIDs.contains($0.windowID) }.max { left, right in
            let leftArea = left.frame.width * left.frame.height
            let rightArea = right.frame.width * right.frame.height
            if leftArea == rightArea { return left.windowID > right.windowID }
            return leftArea < rightArea
        }?.windowID
    }

    static func matchingWindowCandidates(
        _ candidates: [WindowCandidate],
        processIDs: Set<pid_t>
    ) -> [WindowCandidate] {
        candidates.filter {
            processIDs.contains($0.processID)
                && $0.frame.width > 1
                && $0.frame.height > 1
        }
    }

    static func selectionCandidates(
        shareable: [WindowCandidate],
        visible: [WindowCandidate]
    ) -> [WindowCandidate] {
        var selected = shareable
        var selectedIDs = Set(shareable.map(\.windowID))
        for candidate in visible where selectedIDs.insert(candidate.windowID).inserted {
            selected.append(candidate)
        }
        return selected
    }

    static func windowSelectionProcessIDs(
        matchingProcessIDs: Set<pid_t>,
        candidates: [WindowCandidate],
        frontmostProcessID: pid_t?,
        hasRequiredWindow: Bool
    ) throws -> Set<pid_t> {
        guard !hasRequiredWindow else { return matchingProcessIDs }
        let substantialCandidates = candidates.filter {
            $0.frame.width >= 100 && $0.frame.height >= 100
        }
        guard substantialCandidates.count > 1 else { return matchingProcessIDs }
        guard let frontmostProcessID,
              matchingProcessIDs.contains(frontmostProcessID),
              substantialCandidates.contains(where: { $0.processID == frontmostProcessID })
        else {
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        return [frontmostProcessID]
    }

    public static func withOperationTimeout<Value: Sendable>(
        _ timeout: Duration = operationTimeout,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let resolver = CaptureOperationResolver<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                resolver.install(continuation)
                Task.detached {
                    do {
                        resolver.resolve(.success(try await operation()))
                    } catch {
                        resolver.resolve(.failure(error))
                    }
                }
                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                        resolver.resolve(.failure(CaptureFailure.operationTimedOut))
                    } catch {}
                }
            }
        } onCancel: {
            resolver.resolve(.failure(CancellationError()))
        }
    }

    @MainActor
    private static func focusedWindowID(processIDs: Set<pid_t>) -> CGWindowID? {
        let frontmostProcessID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let orderedProcessIDs = processIDs.sorted { left, right in
            if left == frontmostProcessID { return true }
            if right == frontmostProcessID { return false }
            return left < right
        }
        for processID in orderedProcessIDs {
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, 0.2)
            var focusedValue: CFTypeRef?
            let focusedError = AXUIElementCopyAttributeValue(
                application,
                kAXFocusedWindowAttribute as CFString,
                &focusedValue
            )
            guard focusedError == .success,
                  let focusedValue
            else { continue }
            guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else { continue }
            let focusedWindow = unsafeDowncast(focusedValue, to: AXUIElement.self)
            if let windowID = accessibilityWindowID(focusedWindow) {
                return windowID
            }
        }
        return nil
    }

    private static func frontToBackWindowCandidates(
        processIDs: Set<pid_t>
    ) -> [WindowCandidate] {
        guard let values = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard let owner = (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  processIDs.contains(owner),
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = value[kCGWindowNumber as String] as? NSNumber,
                  let bounds = value[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { return nil }
            return WindowCandidate(
                windowID: CGWindowID(number.uint32Value),
                frame: frame,
                processID: owner,
                isOnScreen: true
            )
        }
    }
}

private final class CaptureOperationResolver<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func resolve(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
