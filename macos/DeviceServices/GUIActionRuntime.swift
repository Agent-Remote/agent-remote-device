import AppKit
import DeviceProtocol
import DeviceSecurity
import Foundation
import GUIExecutor

public protocol GUIActionRuntime: Sendable {
    func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> CapturedWindow
    func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        profile: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow
    func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> WindowContext
    func observeAccessibility(
        context: WindowContext,
        stateGeneration: UInt64,
        baseStateID: UUID?,
        policy: ObservationPolicy
    ) async throws -> AccessibilitySnapshotResult
    func executeElement(
        action: ActionV2,
        target: ElementTarget,
        sequence: UInt64,
        context: WindowContext
    ) async throws
    func executeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws
    func settle(
        context: WindowContext,
        policy: ObservationPolicy,
        deadline: Date
    ) async throws -> SettleResult
    func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws
    func authorizeCaptureAction(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws
    func readClipboard(
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws -> String
    func readClipboardV2(
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws -> String
    func releasePressedState() async
    func clearAccessibilityState() async
}

public extension GUIActionRuntime {
    func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        profile _: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow {
        let capture = try await capture(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        return try region.map { try WindowCapture.cropped(capture, to: $0) } ?? capture
    }

    func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> WindowContext {
        try await capture(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        ).windowContext
    }

    func observeAccessibility(
        context _: WindowContext,
        stateGeneration _: UInt64,
        baseStateID _: UUID?,
        policy _: ObservationPolicy
    ) async throws -> AccessibilitySnapshotResult {
        throw AccessibilityFailure.operationFailed
    }

    func executeElement(
        action _: ActionV2,
        target _: ElementTarget,
        sequence _: UInt64,
        context _: WindowContext
    ) async throws {
        throw AccessibilityFailure.operationFailed
    }

    func executeContextAction(
        action _: Action,
        sequence _: UInt64,
        stateGeneration _: UInt64,
        context _: WindowContext
    ) async throws {
        throw ExecutionFailure.actionRequiresCapture
    }

    func settle(
        context _: WindowContext,
        policy _: ObservationPolicy,
        deadline _: Date
    ) async throws -> SettleResult {
        throw AccessibilityFailure.operationFailed
    }

    func clearAccessibilityState() async {}

    func readClipboardV2(
        sequence _: UInt64,
        stateGeneration _: UInt64,
        context _: WindowContext
    ) async throws -> String {
        throw AccessibilityFailure.operationFailed
    }
}

public actor LiveGUIActionRuntime: GUIActionRuntime {
    private let captureEngine = WindowCapture(
        profile: CaptureProfile(maximumWidth: 1_280, maximumHeight: 800)
    )
    private let executor: ActionExecutor
    private let accessibility: AccessibilityRuntime

    private init(executor: ActionExecutor, accessibility: AccessibilityRuntime) {
        self.executor = executor
        self.accessibility = accessibility
    }

    public static func make(guardState: SessionGuard) async -> LiveGUIActionRuntime {
        let values = await MainActor.run {
            (ActionExecutor(guardState: guardState), AccessibilityRuntime())
        }
        return LiveGUIActionRuntime(executor: values.0, accessibility: values.1)
    }

    public func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String? = nil
    ) async throws -> CapturedWindow {
        let application = try await selectedApplication(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        return try await captureEngine.capture(application: application)
    }

    public func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        profile: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow {
        guard profile != .none else { throw CaptureFailure.invalidCaptureSize }
        let application = try await selectedApplication(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        let dimensions = switch profile {
        case .compact: (960, 600)
        case .standard, .region: (1_280, 800)
        case .none: (1, 1)
        }
        let engine = WindowCapture(
            profile: CaptureProfile(maximumWidth: dimensions.0, maximumHeight: dimensions.1)
        )
        let capture = try await engine.capture(application: application)
        return try region.map { try WindowCapture.cropped(capture, to: $0) } ?? capture
    }

    public func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String? = nil
    ) async throws -> WindowContext {
        let application = try await selectedApplication(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        return try await captureEngine.context(application: application)
    }

    private func selectedApplication(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> ApplicationIdentity {
        let frontmostBundleIdentifier = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        let candidates: [ApplicationIdentity]
        if let targetApplication {
            candidates = await MainActor.run {
                approvedApplications.filter { application in
                    if application.bundleIdentifier.caseInsensitiveCompare(targetApplication)
                        == .orderedSame
                    {
                        return true
                    }
                    return NSRunningApplication.runningApplications(
                        withBundleIdentifier: application.bundleIdentifier
                    ).contains {
                        $0.localizedName?.caseInsensitiveCompare(targetApplication) == .orderedSame
                    }
                }
            }
        } else {
            candidates = approvedApplications.filter {
                $0.bundleIdentifier == frontmostBundleIdentifier
            }
        }
        let captureCandidates = if targetApplication == nil, candidates.isEmpty,
                                   approvedApplications.count == 1,
                                   let application = approvedApplications.first
        {
            [application]
        } else {
            candidates
        }
        guard captureCandidates.count == 1 else {
            if targetApplication != nil {
                throw CaptureFailure.requestedApplicationNotApprovedOrAmbiguous
            }
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        guard let application = captureCandidates.first else {
            throw CaptureFailure.signingIdentifierMismatch
        }
        return application
    }

    public func observeAccessibility(
        context: WindowContext,
        stateGeneration: UInt64,
        baseStateID: UUID?,
        policy: ObservationPolicy
    ) async throws -> AccessibilitySnapshotResult {
        try await MainActor.run {
            try accessibility.observe(
                context: context,
                stateGeneration: stateGeneration,
                baseStateID: baseStateID,
                policy: policy
            )
        }
    }

    public func executeElement(
        action: ActionV2,
        target: ElementTarget,
        sequence: UInt64,
        context: WindowContext
    ) async throws {
        try await captureEngine.activate(
            application: context.application,
            processID: context.processID
        )
        try await executor.executeElement(
            action: action,
            target: target,
            sequence: sequence,
            context: context,
            accessibility: accessibility
        )
    }

    public func executeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws {
        try await captureEngine.activate(
            application: context.application,
            processID: context.processID
        )
        try await executor.executeContextAction(
            action: action,
            sequence: sequence,
            stateGeneration: stateGeneration,
            context: context
        )
    }

    public func readClipboardV2(
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws -> String {
        try await captureEngine.activate(
            application: context.application,
            processID: context.processID
        )
        return try await executor.readClipboardV2(
            sequence: sequence,
            stateGeneration: stateGeneration,
            context: context
        )
    }

    public func settle(
        context: WindowContext,
        policy: ObservationPolicy,
        deadline: Date
    ) async throws -> SettleResult {
        guard policy.settle != .none else {
            return SettleResult(status: .notRequested, elapsedMilliseconds: 0)
        }
        if policy.settle == .fixed {
            let milliseconds = min(
                policy.settleTimeoutMilliseconds,
                UInt32(max(0, deadline.timeIntervalSinceNow * 1_000))
            )
            try await Task.sleep(for: .milliseconds(milliseconds))
            return SettleResult(status: .settled, elapsedMilliseconds: milliseconds)
        }

        let started = ContinuousClock.now
        var prior: Int?
        var stableSamples = 0
        repeat {
            let fingerprint = try await MainActor.run {
                try accessibility.stabilityFingerprint(context: context, policy: policy)
            }
            if fingerprint == prior {
                stableSamples += 1
                let elapsed = elapsedMilliseconds(since: started)
                // Dynamic web views can acknowledge an AXPress before their
                // accessibility subtree begins updating. A short grace period
                // avoids returning the unchanged pre-action tree as settled.
                if stableSamples >= 3, elapsed >= 700 {
                    return SettleResult(
                        status: .settled,
                        elapsedMilliseconds: elapsed
                    )
                }
            } else {
                prior = fingerprint
                stableSamples = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return SettleResult(
            status: .timeout,
            elapsedMilliseconds: elapsedMilliseconds(since: started)
        )
    }

    public func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        try await captureEngine.activate(
            application: capture.application,
            processID: capture.processID
        )
        try await executor.execute(
            action: action,
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            capture: capture
        )
    }

    public func authorizeCaptureAction(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        try await captureEngine.activate(
            application: capture.application,
            processID: capture.processID
        )
        try await executor.authorizeCaptureAction(
            action: action,
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            capture: capture
        )
    }

    public func readClipboard(
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws -> String {
        try await captureEngine.activate(
            application: capture.application,
            processID: capture.processID
        )
        return try await executor.readClipboard(
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            capture: capture
        )
    }

    public func releasePressedState() async {
        await executor.releasePressedState()
    }

    public func clearAccessibilityState() async {
        await MainActor.run { accessibility.clear() }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> UInt32 {
        let duration = start.duration(to: .now)
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return UInt32(clamping: milliseconds)
    }
}
