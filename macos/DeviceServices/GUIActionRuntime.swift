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
    func releasePressedState() async
}

public actor LiveGUIActionRuntime: GUIActionRuntime {
    private let captureEngine = WindowCapture(
        profile: CaptureProfile(maximumWidth: 1_280, maximumHeight: 800)
    )
    private let executor: ActionExecutor

    private init(executor: ActionExecutor) {
        self.executor = executor
    }

    public static func make(guardState: SessionGuard) async -> LiveGUIActionRuntime {
        let executor = await MainActor.run { ActionExecutor(guardState: guardState) }
        return LiveGUIActionRuntime(executor: executor)
    }

    public func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String? = nil
    ) async throws -> CapturedWindow {
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
        let captureCandidates: [ApplicationIdentity]
        if targetApplication != nil, candidates.count == 1, let application = candidates.first {
            try await captureEngine.activate(application: application)
            captureCandidates = [application]
        } else if targetApplication == nil, candidates.isEmpty, approvedApplications.count == 1,
           let application = approvedApplications.first
        {
            try await captureEngine.activate(application: application)
            captureCandidates = [application]
        } else {
            captureCandidates = candidates
        }
        guard captureCandidates.count == 1 else {
            if targetApplication != nil {
                throw CaptureFailure.requestedApplicationNotApprovedOrAmbiguous
            }
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        for application in captureCandidates {
            do {
                return try await captureEngine.capture(application: application)
            } catch CaptureFailure.signingIdentifierMismatch {
                continue
            }
        }
        throw CaptureFailure.signingIdentifierMismatch
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
}
