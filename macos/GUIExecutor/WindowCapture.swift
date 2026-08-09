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

public struct CaptureProfile: Equatable, Sendable {
    public let maximumWidth: Int
    public let maximumHeight: Int

    public init(maximumWidth: Int, maximumHeight: Int) {
        precondition(maximumWidth > 0 && maximumHeight > 0)
        self.maximumWidth = maximumWidth
        self.maximumHeight = maximumHeight
    }
}

public struct CapturedWindow: @unchecked Sendable {
    public let pngData: Data
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let coordinateFrame: CGRect
    public let processID: pid_t
    public let application: ApplicationIdentity
    public let displayFingerprint: String

    public init(
        pngData: Data,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        windowID: CGWindowID,
        windowFrame: CGRect,
        coordinateFrame: CGRect,
        processID: pid_t,
        application: ApplicationIdentity,
        displayFingerprint: String
    ) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.coordinateFrame = coordinateFrame
        self.processID = processID
        self.application = application
        self.displayFingerprint = displayFingerprint
    }
}

public struct WindowContext: Equatable, Sendable {
    public let windowID: CGWindowID
    public let windowFrame: CGRect
    public let processID: pid_t
    public let application: ApplicationIdentity
    public let displayFingerprint: String

    public init(
        windowID: CGWindowID,
        windowFrame: CGRect,
        processID: pid_t,
        application: ApplicationIdentity,
        displayFingerprint: String
    ) {
        self.windowID = windowID
        self.windowFrame = windowFrame
        self.processID = processID
        self.application = application
        self.displayFingerprint = displayFingerprint
    }
}

public extension CapturedWindow {
    var windowContext: WindowContext {
        WindowContext(
            windowID: windowID,
            windowFrame: windowFrame,
            processID: processID,
            application: application,
            displayFingerprint: displayFingerprint
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
        }
    }

    public var userMessage: String {
        switch self {
        case .screenRecordingPermissionMissing:
            "Mac screen recording permission is missing for Agent Remote Device."
        case .approvedApplicationNotFrontmost:
            "The approved application is not the frontmost Mac application."
        case .requestedApplicationNotApprovedOrAmbiguous:
            "The requested application does not uniquely match a running approved application."
        case .approvedApplicationNotRunning:
            "The approved application is not currently running on the Mac."
        case .applicationActivationRejected:
            "macOS rejected the request to bring the approved application to the foreground."
        case .applicationActivationTimedOut:
            "The approved application did not become frontmost within five seconds."
        case .signingIdentifierMismatch:
            "The frontmost application does not match the approved code identity."
        case .approvedWindowMissing:
            "No visible window was found for the approved application."
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
        }
    }
}

public struct WindowCapture: Sendable {
    static let operationTimeout: Duration = .seconds(8)
    private static let lightweightActivationAttempts = 20
    private static let workspaceActivationAttempts = 80

    private let profile: CaptureProfile
    private let excludedBundleIdentifier: String

    public init(profile: CaptureProfile, excludedBundleIdentifier: String = "dev.agentremote.device") {
        self.profile = profile
        self.excludedBundleIdentifier = excludedBundleIdentifier
    }

    @MainActor
    public func capture(application: ApplicationIdentity) async throws -> CapturedWindow {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingPermissionMissing
        }
        let resolved = try await resolve(application: application)
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
        configuration.sourceRect = Self.displayLocalRect(
            resolved.captureFrame,
            displayFrame: resolved.display.frame
        )
        let filter = SCContentFilter(display: resolved.display, including: [resolved.window])
        let image = try await Self.withOperationTimeout {
            try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        }
        guard let pngData = Self.pngData(image) else { throw CaptureFailure.encodingFailed }
        return CapturedWindow(
            pngData: pngData,
            pixelWidth: UInt16(size.width),
            pixelHeight: UInt16(size.height),
            windowID: resolved.window.windowID,
            windowFrame: resolved.window.frame,
            coordinateFrame: resolved.captureFrame,
            processID: resolved.processID,
            application: application,
            displayFingerprint: Self.displayFingerprint(
                resolved.content.displays,
                selected: resolved.display
            )
        )
    }

    @MainActor
    public func context(application: ApplicationIdentity) async throws -> WindowContext {
        let resolved = try await resolve(application: application)
        return WindowContext(
            windowID: resolved.window.windowID,
            windowFrame: resolved.window.frame,
            processID: resolved.processID,
            application: application,
            displayFingerprint: Self.displayFingerprint(
                resolved.content.displays,
                selected: resolved.display
            )
        )
    }

    @MainActor
    private func resolve(application: ApplicationIdentity) async throws -> (
        processID: pid_t,
        content: SCShareableContent,
        window: SCWindow,
        display: SCDisplay,
        captureFrame: CGRect
    ) {
        guard application.bundleIdentifier != excludedBundleIdentifier else {
            throw CaptureFailure.applicationActivationRejected
        }
        let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).filter { !$0.isTerminated }
        guard !running.isEmpty else {
            throw CaptureFailure.approvedApplicationNotRunning
        }
        let matching = running.filter {
            Self.signingIdentifier(for: $0) == application.signingIdentifier
        }
        guard matching.count == 1, let target = matching.first else {
            throw CaptureFailure.signingIdentifierMismatch
        }
        let processID = target.processIdentifier
        let content = try await Self.withOperationTimeout {
            try await SCShareableContent.excludingDesktopWindows(
                true,
                onScreenWindowsOnly: true
            )
        }
        let windows = content.windows.filter {
            $0.owningApplication?.processID == processID
                && $0.isOnScreen
                && $0.frame.width > 1
                && $0.frame.height > 1
        }
        let selectedWindowID = Self.preferredWindowID(
            candidates: windows.map { ($0.windowID, $0.frame) },
            frontToBackWindowIDs: Self.frontToBackWindowIDs(processID: processID)
        )
        guard let selectedWindowID,
              let window = windows.first(where: { $0.windowID == selectedWindowID })
        else {
            throw CaptureFailure.approvedWindowMissing
        }
        guard let display = Self.selectedDisplay(for: window.frame, from: content.displays) else {
            throw CaptureFailure.displayMissing
        }
        let captureFrame = window.frame.intersection(display.frame)
        guard !captureFrame.isNull, !captureFrame.isInfinite,
              captureFrame.width > 0, captureFrame.height > 0
        else {
            throw CaptureFailure.displayMissing
        }
        return (processID, content, window, display, captureFrame)
    }

    public func activate(
        application: ApplicationIdentity,
        processID requiredProcessID: pid_t? = nil
    ) async throws {
        guard application.bundleIdentifier != excludedBundleIdentifier else {
            throw CaptureFailure.applicationActivationRejected
        }
        let target = try await Self.activationTarget(
            application: application,
            requiredProcessID: requiredProcessID
        )
        let isAlreadyFrontmost = await MainActor.run {
            Self.isProcessFrontmost(target.processID)
        }
        if isAlreadyFrontmost { return }

        await MainActor.run {
            Self.requestProcessActivation(processID: target.processID)
            if let bundleURL = target.bundleURL {
                Self.requestWorkspaceActivation(at: bundleURL)
            }
        }
        if try await Self.waitUntilFrontmost(
            processID: target.processID,
            attempts: Self.lightweightActivationAttempts
        ) {
            return
        }

        if let bundleURL = target.bundleURL {
            await MainActor.run {
                Self.requestWorkspaceActivation(at: bundleURL)
            }
        }

        if try await Self.waitUntilFrontmost(
            processID: target.processID,
            attempts: Self.workspaceActivationAttempts
        ) {
            return
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
        attempts: Int
    ) async throws -> Bool {
        for attempt in 0 ..< attempts {
            let isFrontmost = await MainActor.run {
                Self.isProcessFrontmost(processID)
            }
            if isFrontmost { return true }
            if attempt > 0, attempt.isMultiple(of: 10) {
                await MainActor.run {
                    requestProcessActivation(processID: processID)
                }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
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
        // NSWorkspace's cached frontmost application can lag in an XPC service that
        // has no NSApplication event loop. NSRunningApplication.isActive reflects the
        // process activation state directly and avoids reporting a successful switch
        // as a timeout.
        return application.isActive
            || NSWorkspace.shared.frontmostApplication?.processIdentifier == processID
    }

    @MainActor
    private static func requestProcessActivation(processID: pid_t) {
        guard let application = NSRunningApplication(processIdentifier: processID) else { return }
        _ = application.unhide()
        _ = application.activate(options: [.activateAllWindows])
        requestAccessibilityActivation(processID: processID)
    }

    @MainActor
    private static func requestAccessibilityActivation(processID: pid_t) {
        let accessibilityApplication = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetAttributeValue(
            accessibilityApplication,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        raiseAccessibilityWindows(processID: processID)
    }

    private static func raiseAccessibilityWindows(processID: pid_t) {
        let application = AXUIElementCreateApplication(processID)
        _ = AXUIElementSetAttributeValue(
            application,
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        )
        var rawWindows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXWindowsAttribute as CFString,
            &rawWindows
        ) == .success,
            let windows = rawWindows as? [AXUIElement]
        else { return }
        for window in windows.prefix(8) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
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
              let pngData = pngData(croppedImage)
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
            pngData: pngData,
            pixelWidth: region.width,
            pixelHeight: region.height,
            windowID: capture.windowID,
            windowFrame: capture.windowFrame,
            coordinateFrame: coordinateFrame,
            processID: capture.processID,
            application: capture.application,
            displayFingerprint: capture.displayFingerprint
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

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    private static func signingIdentifier(for application: NSRunningApplication) -> String? {
        RunningCodeIdentity.signingIdentifier(processID: application.processIdentifier)
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
        frontToBackWindowIDs: [CGWindowID]
    ) -> CGWindowID? {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.windowID, $0.frame) })
        if let frontmostSubstantial = frontToBackWindowIDs.first(where: { windowID in
            guard let frame = byID[windowID] else { return false }
            return frame.width >= 100 && frame.height >= 100
        }) {
            return frontmostSubstantial
        }
        return candidates.max { left, right in
            let leftArea = left.frame.width * left.frame.height
            let rightArea = right.frame.width * right.frame.height
            if leftArea == rightArea { return left.windowID > right.windowID }
            return leftArea < rightArea
        }?.windowID
    }

    static func withOperationTimeout<Value: Sendable>(
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

    private static func frontToBackWindowIDs(processID: pid_t) -> [CGWindowID] {
        guard let values = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return values.compactMap { value in
            guard (value[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  (value[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let number = value[kCGWindowNumber as String] as? NSNumber
            else { return nil }
            return CGWindowID(number.uint32Value)
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
