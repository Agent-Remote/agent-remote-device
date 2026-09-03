import AppKit
import DeviceProtocol
import DeviceSecurity
import Foundation
import GUIExecutor

public struct ActionSettleOutcome: Sendable {
    public let result: SettleResult
    public let observedMeaningfulChange: Bool
    public let pressTargetWasEditableText: Bool

    public init(
        result: SettleResult,
        observedMeaningfulChange: Bool,
        pressTargetWasEditableText: Bool = false
    ) {
        self.result = result
        self.observedMeaningfulChange = observedMeaningfulChange
        self.pressTargetWasEditableText = pressTargetWasEditableText
    }
}

public struct ActionSettlePreparation: Sendable {
    public let baseline: AccessibilityStabilityFingerprint?
    public let pressTargetWasEditableText: Bool
    public let trackedElementIndex: UInt32?

    public init(
        baseline: AccessibilityStabilityFingerprint?,
        pressTargetWasEditableText: Bool,
        trackedElementIndex: UInt32? = nil
    ) {
        self.baseline = baseline
        self.pressTargetWasEditableText = pressTargetWasEditableText
        self.trackedElementIndex = trackedElementIndex
    }
}

public protocol GUIActionRuntime: Sendable {
    func resolveApplication(
        targetApplication: String?,
        excludedBundleIdentifiers: Set<String>
    ) async throws -> ApplicationIdentity
    func launchApplication(
        _ application: String,
        excludedBundleIdentifiers: Set<String>,
        deadline: Date
    ) async throws -> WindowContext
    func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> CapturedWindow
    func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        preferredWindowContexts: [WindowContext],
        profile: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow
    func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        preferredWindowContexts: [WindowContext]
    ) async throws -> WindowContext
    func observeAccessibility(
        context: WindowContext,
        stateGeneration: UInt64,
        baseStateID: UUID?,
        policy: ObservationPolicy
    ) async throws -> AccessibilitySnapshotResult
    func rebindAccessibilityState(
        context: WindowContext,
        stateGeneration: UInt64
    ) async -> AccessibilityStateContext?
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
    func prepareSettle(
        context: WindowContext,
        policy: ObservationPolicy,
        action: ActionV2
    ) async -> ActionSettlePreparation
    func settle(
        context: WindowContext,
        policy: ObservationPolicy,
        action: ActionV2,
        preparation: ActionSettlePreparation?,
        deadline: Date
    ) async throws -> ActionSettleOutcome
    func waitForAccessibilityValue(
        target: ElementTarget,
        expectedValue: String,
        deadline: Date
    ) async throws -> Bool
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
        context: WindowContext,
        maximumBytes: Int
    ) async throws -> String
    func readGlobalClipboard(sequence: UInt64, maximumBytes: Int) async throws -> String
    func releasePressedState() async
    func restoreUserFocus() async
    func clearAccessibilityState(applicationDigest: String?) async
}

public extension GUIActionRuntime {
    func resolveApplication(
        targetApplication _: String?,
        excludedBundleIdentifiers _: Set<String>
    ) async throws -> ApplicationIdentity {
        throw CaptureFailure.applicationNotFound
    }

    func launchApplication(
        _: String,
        excludedBundleIdentifiers _: Set<String>,
        deadline _: Date
    ) async throws -> WindowContext {
        throw CaptureFailure.applicationNotFound
    }

    func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        preferredWindowContexts _: [WindowContext],
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
        targetApplication: String?,
        preferredWindowContexts _: [WindowContext]
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
        action _: ActionV2,
        preparation _: ActionSettlePreparation?,
        deadline _: Date
    ) async throws -> ActionSettleOutcome {
        throw AccessibilityFailure.operationFailed
    }

    func prepareSettle(
        context _: WindowContext,
        policy _: ObservationPolicy,
        action _: ActionV2
    ) async -> ActionSettlePreparation {
        ActionSettlePreparation(
            baseline: nil,
            pressTargetWasEditableText: false
        )
    }

    func waitForAccessibilityValue(
        target _: ElementTarget,
        expectedValue _: String,
        deadline _: Date
    ) async throws -> Bool {
        true
    }

    func clearAccessibilityState(applicationDigest _: String?) async {}

    func restoreUserFocus() async {}

    func rebindAccessibilityState(
        context _: WindowContext,
        stateGeneration _: UInt64
    ) async -> AccessibilityStateContext? {
        nil
    }

    func readClipboardV2(
        sequence _: UInt64,
        stateGeneration _: UInt64,
        context _: WindowContext,
        maximumBytes _: Int
    ) async throws -> String {
        throw AccessibilityFailure.operationFailed
    }

    func readGlobalClipboard(sequence _: UInt64, maximumBytes _: Int) async throws -> String {
        throw AccessibilityFailure.operationFailed
    }
}

public actor LiveGUIActionRuntime: GUIActionRuntime {
    private let captureEngine = WindowCapture(
        profile: CaptureProfile(maximumWidth: 1_280, maximumHeight: 800)
    )
    private let executor: ActionExecutor
    private let accessibility: AccessibilityRuntime
    private var userFocusProcessID: pid_t?
    private var activatedProcessIDs: Set<pid_t> = []

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

    public func resolveApplication(
        targetApplication: String?,
        excludedBundleIdentifiers: Set<String>
    ) async throws -> ApplicationIdentity {
        try await MainActor.run {
            try ApplicationResolver.runningApplication(
                matching: targetApplication,
                excludedBundleIdentifiers: excludedBundleIdentifiers
            )
        }
    }

    public func launchApplication(
        _ application: String,
        excludedBundleIdentifiers: Set<String>,
        deadline: Date
    ) async throws -> WindowContext {
        let priorProcessID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        let target = try await MainActor.run {
            try ApplicationResolver.installedApplication(
                matching: application,
                excludedBundleIdentifiers: excludedBundleIdentifiers
            )
        }
        if let priorProcessID {
            userFocusProcessID = priorProcessID
        }
        let processID: pid_t
        do {
            processID = try await ApplicationResolver.launch(target)
        } catch {
            await restoreUserFocus()
            throw CaptureFailure.applicationLaunchResultUnknown
        }
        activatedProcessIDs.insert(processID)
        do {
            return try await Self.waitForLaunchedWindow(
                deadline: deadline,
                context: { [captureEngine] in
                    try await captureEngine.context(
                        application: target.identity,
                        requiredProcessID: processID
                    )
                },
                restore: { await self.restoreUserFocus() }
            )
        } catch let failure as CaptureFailure where failure == .applicationLaunchTimeout {
            throw failure
        } catch {
            throw CaptureFailure.applicationLaunchResultUnknown
        }
    }

    static func waitForLaunchedWindow(
        deadline: Date,
        context: @escaping @Sendable () async throws -> WindowContext,
        restore: @escaping @Sendable () async -> Void
    ) async throws -> WindowContext {
        do {
            repeat {
                do {
                    return try await context()
                } catch let failure as CaptureFailure
                    where failure == .approvedApplicationNotRunning
                        || failure == .approvedWindowMissing
                {
                    let remainingMilliseconds = Int64(deadline.timeIntervalSinceNow * 1_000)
                    guard remainingMilliseconds > 0 else { break }
                    try await Task.sleep(for: .milliseconds(min(100, remainingMilliseconds)))
                }
            } while Date() < deadline
            throw CaptureFailure.applicationLaunchTimeout
        } catch {
            await restore()
            throw error
        }
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
        preferredWindowContexts: [WindowContext],
        profile: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow {
        guard profile != .none else { throw CaptureFailure.invalidCaptureSize }
        let application = try await selectedApplication(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        let captureProfile = switch profile {
        case .compact:
            CaptureProfile(
                maximumWidth: 960,
                maximumHeight: 600,
                encoding: .jpeg(quality: 0.72)
            )
        case .standard:
            CaptureProfile(
                maximumWidth: 1_280,
                maximumHeight: 800,
                encoding: .jpeg(quality: 0.75)
            )
        case .region:
            CaptureProfile(
                maximumWidth: 1_280,
                maximumHeight: 800,
                encoding: .jpeg(quality: 0.82)
            )
        case .none:
            CaptureProfile(maximumWidth: 1, maximumHeight: 1)
        }
        let engine = WindowCapture(profile: captureProfile)
        let preferredWindowID = preferredWindowContexts.first {
            $0.application.stableDigest == application.stableDigest
        }?.windowID
        let capture = try await engine.capture(
            application: application,
            requiredWindowID: preferredWindowID
        )
        return try region.map { try WindowCapture.cropped(capture, to: $0) } ?? capture
    }

    public func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String? = nil,
        preferredWindowContexts: [WindowContext] = []
    ) async throws -> WindowContext {
        let application = try await selectedApplication(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        let preferredWindowID = preferredWindowContexts.first {
            $0.application.stableDigest == application.stableDigest
        }?.windowID
        return try await captureEngine.context(
            application: application,
            requiredWindowID: preferredWindowID
        )
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
                    let displayNames = NSRunningApplication.runningApplications(
                        withBundleIdentifier: application.bundleIdentifier
                    ).compactMap(\.localizedName)
                    return ApplicationTargetMatching.matches(
                        target: targetApplication,
                        bundleIdentifier: application.bundleIdentifier,
                        displayNames: displayNames
                    )
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
        try await activateForAction(
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

    public func rebindAccessibilityState(
        context: WindowContext,
        stateGeneration: UInt64
    ) async -> AccessibilityStateContext? {
        await MainActor.run {
            accessibility.rebindCurrent(
                context: context,
                stateGeneration: stateGeneration
            )
        }
    }

    public func executeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws {
        if action.requiresForegroundApplication {
            try await activateForAction(
                application: context.application,
                processID: context.processID
            )
        }
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
        context: WindowContext,
        maximumBytes: Int
    ) async throws -> String {
        return try await executor.readClipboardV2(
            sequence: sequence,
            stateGeneration: stateGeneration,
            context: context,
            maximumBytes: maximumBytes
        )
    }

    public func readGlobalClipboard(sequence: UInt64, maximumBytes: Int) async throws -> String {
        try await executor.readGlobalClipboard(
            sequence: sequence,
            maximumBytes: maximumBytes
        )
    }

    public func settle(
        context: WindowContext,
        policy: ObservationPolicy,
        action: ActionV2,
        preparation: ActionSettlePreparation?,
        deadline: Date
    ) async throws -> ActionSettleOutcome {
        guard policy.settle != .none else {
            return ActionSettleOutcome(
                result: SettleResult(status: .notRequested, elapsedMilliseconds: 0),
                observedMeaningfulChange: false
            )
        }
        if policy.settle == .fixed {
            let milliseconds = min(
                policy.settleTimeoutMilliseconds,
                UInt32(max(0, deadline.timeIntervalSinceNow * 1_000))
            )
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ActionSettleOutcome(
                result: SettleResult(status: .settled, elapsedMilliseconds: milliseconds),
                observedMeaningfulChange: false
            )
        }

        let started = ContinuousClock.now
        let pressTargetsEditableText = preparation?.pressTargetWasEditableText ?? false
        let minimumStableMilliseconds = ActionSettleTiming.minimumStableMilliseconds(
            for: action,
            pressTargetsEditableText: pressTargetsEditableText
        )
        let requiredStableSamples = ActionSettleTiming.requiredStableSamples(
            for: action,
            pressTargetsEditableText: pressTargetsEditableText
        )
        let requiresMeaningfulChange = ActionSettleTiming.requiresMeaningfulChange(
            for: action,
            pressTargetsEditableText: pressTargetsEditableText
        )
        let noChangeGraceMilliseconds = ActionSettleTiming.noChangeGraceMilliseconds(
            for: action,
            pressTargetsEditableText: pressTargetsEditableText
        )
        let baseline: AccessibilityStabilityFingerprint? = if requiresMeaningfulChange {
            if let preparation {
                preparation.baseline
            } else {
                await MainActor.run {
                    accessibility.currentStabilityFingerprint(context: context)
                }
            }
        } else {
            nil
        }
        var observedMeaningfulChange = !requiresMeaningfulChange || baseline == nil
        var priorContent: Int?
        var stableSamples = 0
        repeat {
            let fingerprint: AccessibilityStabilityFingerprint
            do {
                fingerprint = try await MainActor.run {
                    try accessibility.stabilityFingerprint(
                        context: context,
                        policy: policy,
                        trackingElementIndex: preparation?.trackedElementIndex
                    )
                }
            } catch let failure as AccessibilityFailure
                where failure.isTransientDuringSettle
            {
                let remainingMilliseconds = Int64(deadline.timeIntervalSinceNow * 1_000)
                guard remainingMilliseconds > 0 else { break }
                try await Task.sleep(
                    for: .milliseconds(min(100, remainingMilliseconds))
                )
                continue
            }
            if let baseline {
                let trackedElementDisappeared = baseline.trackedElementPresent == true
                    && fingerprint.trackedElementPresent == false
                let trackedElementChanged = baseline.trackedElementContent != nil
                    && fingerprint.trackedElementContent != baseline.trackedElementContent
                if fingerprint.meaningful != baseline.meaningful
                    || trackedElementDisappeared
                    || trackedElementChanged
                {
                    observedMeaningfulChange = true
                }
            }
            if fingerprint.content == priorContent {
                stableSamples += 1
                let elapsed = elapsedMilliseconds(since: started)
                if ActionSettleTiming.canReturn(
                    stableSamples: stableSamples,
                    requiredStableSamples: requiredStableSamples,
                    elapsedMilliseconds: elapsed,
                    minimumStableMilliseconds: minimumStableMilliseconds,
                    observedMeaningfulChange: observedMeaningfulChange,
                    noChangeGraceMilliseconds: noChangeGraceMilliseconds
                ) {
                    return ActionSettleOutcome(
                        result: SettleResult(
                            status: .settled,
                            elapsedMilliseconds: elapsed
                        ),
                        observedMeaningfulChange: observedMeaningfulChange,
                        pressTargetWasEditableText: pressTargetsEditableText
                    )
                }
            } else {
                priorContent = fingerprint.content
                stableSamples = 0
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return ActionSettleOutcome(
            result: SettleResult(
                status: .timeout,
                elapsedMilliseconds: elapsedMilliseconds(since: started)
            ),
            observedMeaningfulChange: observedMeaningfulChange,
            pressTargetWasEditableText: pressTargetsEditableText
        )
    }

    public func prepareSettle(
        context: WindowContext,
        policy: ObservationPolicy,
        action: ActionV2
    ) async -> ActionSettlePreparation {
        guard policy.settle == .auto else {
            return ActionSettlePreparation(
                baseline: nil,
                pressTargetWasEditableText: false
            )
        }
        let pressTargetsEditableText: Bool = if case let .press(target) = action {
            await MainActor.run { accessibility.isEditableTextTarget(target) }
        } else {
            false
        }
        let trackedElementIndex: UInt32? = switch action {
        case let .press(target), let .secondaryAction(target, _):
            target.elementIndex
        default:
            nil
        }
        let requiresMeaningfulChange = ActionSettleTiming.requiresMeaningfulChange(
            for: action,
            pressTargetsEditableText: pressTargetsEditableText
        )
        let baseline: AccessibilityStabilityFingerprint? = requiresMeaningfulChange
            ? await MainActor.run { () -> AccessibilityStabilityFingerprint? in
                accessibility.currentStabilityFingerprint(
                    context: context,
                    trackingElementIndex: trackedElementIndex
                )
            }
            : nil
        return ActionSettlePreparation(
            baseline: baseline,
            pressTargetWasEditableText: pressTargetsEditableText,
            trackedElementIndex: trackedElementIndex
        )
    }

    public func waitForAccessibilityValue(
        target: ElementTarget,
        expectedValue: String,
        deadline: Date
    ) async throws -> Bool {
        repeat {
            if try await MainActor.run(body: {
                try accessibility.valueMatches(expectedValue, target: target)
            }) {
                return true
            }
            let remainingMilliseconds = Int64(deadline.timeIntervalSinceNow * 1_000)
            guard remainingMilliseconds > 0 else { return false }
            try await Task.sleep(for: .milliseconds(min(100, remainingMilliseconds)))
        } while Date() < deadline
        return false
    }

    public func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        if action.requiresForegroundApplication {
            try await activateForAction(
                application: capture.application,
                processID: capture.processID
            )
        }
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
        return try await executor.readClipboard(
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            capture: capture
        )
    }

    public func releasePressedState() async {
        await executor.releasePressedState()
    }

    public func restoreUserFocus() async {
        let hasPressedState = await executor.hasPressedState
        guard !hasPressedState else { return }
        let processID = userFocusProcessID
        userFocusProcessID = nil
        let remotelyActivated = activatedProcessIDs
        activatedProcessIDs.removeAll(keepingCapacity: false)
        guard let processID else { return }
        let shouldRestore = await MainActor.run {
            guard let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
            // A manual application switch supersedes the focus captured for this turn.
            return remotelyActivated.contains(frontmost.processIdentifier)
        }
        guard shouldRestore else { return }
        await MainActor.run {
            WindowCapture.restoreUserApplication(processID: processID)
        }
    }

    private func activateForAction(
        application: ApplicationIdentity,
        processID: pid_t
    ) async throws {
        let priorProcessID = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.processIdentifier
        }
        if let priorProcessID,
           priorProcessID != processID,
           !activatedProcessIDs.contains(priorProcessID)
        {
            userFocusProcessID = priorProcessID
        }
        activatedProcessIDs.insert(processID)
        do {
            let activatedProcessID = try await captureEngine.activate(
                application: application,
                processID: processID
            )
            activatedProcessIDs.insert(activatedProcessID)
        } catch {
            await restoreUserFocus()
            throw error
        }
    }

    public func clearAccessibilityState(applicationDigest: String?) async {
        await MainActor.run {
            if let applicationDigest {
                accessibility.clear(applicationDigest: applicationDigest)
            } else {
                accessibility.clear()
            }
        }
    }

    private func elapsedMilliseconds(since start: ContinuousClock.Instant) -> UInt32 {
        let duration = start.duration(to: .now)
        let milliseconds = duration.components.seconds * 1_000
            + duration.components.attoseconds / 1_000_000_000_000_000
        return UInt32(clamping: milliseconds)
    }
}

enum ActionSettleTiming {
    static func minimumStableMilliseconds(
        for action: ActionV2,
        pressTargetsEditableText: Bool = false
    ) -> UInt32 {
        if isImmediateShortcut(action) { return 200 }
        if pressTargetsEditableText { return 250 }
        return mayNavigate(action, pressTargetsEditableText: false) ? 600 : 300
    }

    static func requiredStableSamples(
        for action: ActionV2,
        pressTargetsEditableText: Bool = false
    ) -> Int {
        if isImmediateShortcut(action) { return 1 }
        if pressTargetsEditableText { return 2 }
        return mayNavigate(action, pressTargetsEditableText: false) ? 6 : 2
    }

    static func requiresMeaningfulChange(
        for action: ActionV2,
        pressTargetsEditableText: Bool = false
    ) -> Bool {
        mayNavigate(action, pressTargetsEditableText: pressTargetsEditableText)
    }

    static func noChangeGraceMilliseconds(
        for action: ActionV2,
        pressTargetsEditableText: Bool = false
    ) -> UInt32 {
        mayNavigate(action, pressTargetsEditableText: pressTargetsEditableText) ? 2_000 : 0
    }

    static func canReturn(
        stableSamples: Int,
        requiredStableSamples: Int,
        elapsedMilliseconds: UInt32,
        minimumStableMilliseconds: UInt32,
        observedMeaningfulChange: Bool,
        noChangeGraceMilliseconds: UInt32
    ) -> Bool {
        stableSamples >= requiredStableSamples
            && elapsedMilliseconds >= minimumStableMilliseconds
            && (observedMeaningfulChange
                || elapsedMilliseconds >= noChangeGraceMilliseconds)
    }

    static func mayNavigate(
        _ action: ActionV2,
        pressTargetsEditableText: Bool
    ) -> Bool {
        if action.mayChangeFrontmostWindow { return true }
        return switch action {
        case .press:
            !pressTargetsEditableText
        case let .secondaryAction(_, actionName):
            !["AXScrollToVisible", "AXShowMenu"].contains(actionName)
        case let .coordinate(action):
            switch action {
            case .leftClick, .rightClick, .middleClick, .doubleClick, .tripleClick:
                true
            case let .key(key):
                [
                    "RETURN", "ENTER", "KP_ENTER", "ALT+LEFT", "ALT+RIGHT",
                    "CMD+LEFT", "CMD+RIGHT", "SUPER+LEFT", "SUPER+RIGHT",
                    "CMD+[", "CMD+]", "SUPER+[", "SUPER+]",
                    "BROWSER_BACK", "BROWSER_FORWARD",
                ].contains(key.uppercased())
            default:
                false
            }
        default:
            false
        }
    }

    private static func isImmediateShortcut(_ action: ActionV2) -> Bool {
        guard case let .coordinate(.key(key)) = action else { return false }
        return [
            "CMD+A", "CMD+C", "CMD+X",
            "SUPER+A", "SUPER+C", "SUPER+X",
        ].contains(key.uppercased())
    }
}
