import AppKit
import DeviceProtocol
import DeviceSecurity
import Foundation
import GUIExecutor

public protocol GUIActionRuntime: Sendable {
    func capture(approvedApplications: [ApplicationIdentity]) async throws -> CapturedWindow
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
        approvedApplications: [ApplicationIdentity]
    ) async throws -> CapturedWindow {
        let frontmostBundleIdentifier = await MainActor.run {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        guard let frontmostBundleIdentifier else {
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        let candidates = approvedApplications.filter {
            $0.bundleIdentifier == frontmostBundleIdentifier
        }
        guard !candidates.isEmpty else {
            throw CaptureFailure.approvedApplicationNotFrontmost
        }
        for application in candidates {
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

    public func releasePressedState() async {
        await executor.releasePressedState()
    }
}
