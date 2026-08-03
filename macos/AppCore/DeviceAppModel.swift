import AppKit
import Combine
import DeviceIPC
import DeviceSecurity
import Foundation
import GUIExecutor
import UserNotifications

public enum DeviceAppState: String, Sendable {
    case ready
    case selectingSession = "selecting_session"
    case claimingSession = "claiming_session"
    case permissionRequired = "permission_required"
    case awaitingApproval = "awaiting_approval"
    case activating
    case active
    case paused
    case denied
    case stopped
    case failed
}

public enum DeviceAppFailure: Error, Equatable, Sendable {
    case transportUnavailable
    case invalidRuntimeTransition
}

@MainActor
public final class DeviceAppModel: ObservableObject {
    @Published public private(set) var state: DeviceAppState = .ready
    @Published public private(set) var approvalPresentation: ApprovalPresentation?
    @Published public private(set) var sessionCandidates: [BrokerSessionCandidate] = []
    @Published public var applicationSelections: Set<String> = []
    @Published public var clipboardSelections: Set<String> = []
    @Published public var controlLevelSelections: [String: ControlLevel] = [:]
    @Published public private(set) var lastUnsafeTransition: UnsafeTransitionReason?
    @Published public private(set) var failureMessage: String?

    public let permissions: PermissionController

    private let visibilityController: any WorkspaceVisibilityControlling
    private let safetyMonitorFactory: (
        @escaping @Sendable (UnsafeTransitionReason) -> Void
    ) -> any SessionSafetyMonitoring
    private let permissionsGranted: () -> Bool
    private let controlNotifier: (() async -> Void)?
    private var safetyMonitor: (any SessionSafetyMonitoring)?
    private var approvedBundleIdentifiers: Set<String> = []

    public var onApprove: ([LocalApproval]) async throws -> Void = { _ in
        throw DeviceAppFailure.transportUnavailable
    }
    public var onRefreshSessionCandidates: () async throws -> [BrokerSessionCandidate] = { [] }
    public var onClaimSession: (UUID) async throws -> Void = { _ in
        throw DeviceAppFailure.transportUnavailable
    }
    public var onDeny: ([LocalApproval]) async throws -> Void = { _ in
        throw DeviceAppFailure.transportUnavailable
    }
    public var onAbort: (UnsafeTransitionReason) async throws -> Void = { _ in
        throw DeviceAppFailure.transportUnavailable
    }
    public var onEndSession: () async throws -> Void = {
        throw DeviceAppFailure.transportUnavailable
    }

    public init(
        permissions: PermissionController? = nil,
        visibilityController: (any WorkspaceVisibilityControlling)? = nil,
        safetyMonitorFactory: @escaping (
            @escaping @Sendable (UnsafeTransitionReason) -> Void
        ) -> any SessionSafetyMonitoring = { SessionSafetyMonitor(onTransition: $0) },
        permissionsGranted: (() -> Bool)? = nil,
        controlNotifier: (() async -> Void)? = nil
    ) {
        let resolvedPermissions = permissions ?? PermissionController()
        self.permissions = resolvedPermissions
        self.visibilityController = visibilityController ?? WorkspaceVisibilityController()
        self.safetyMonitorFactory = safetyMonitorFactory
        self.permissionsGranted = permissionsGranted ?? { resolvedPermissions.allGranted }
        self.controlNotifier = controlNotifier
        do {
            try self.visibilityController.restoreApplicationsFromPreviousRun()
        } catch {
            state = .failed
            failureMessage = String(describing: error)
        }
    }

    public func presentApproval(_ presentation: ApprovalPresentation) {
        sessionCandidates = []
        permissions.refresh()
        let approvedIdentifiers = Set(
            presentation.applications.map { $0.application.bundleIdentifier }
        )
        approvalPresentation = presentation.updatingHiddenApplicationCount(
            visibilityController.unapprovedApplicationCount(
                approvedBundleIdentifiers: approvedIdentifiers
            )
        )
        applicationSelections = []
        clipboardSelections = []
        controlLevelSelections = Dictionary(uniqueKeysWithValues: presentation.applications.map {
            ($0.id, $0.classification.controlLevel ?? .viewOnly)
        })
        state = permissionsGranted() ? .awaitingApproval : .permissionRequired
    }

    public func presentSessionCandidates(_ candidates: [BrokerSessionCandidate]) {
        guard state != .active, state != .activating else { return }
        sessionCandidates = candidates
        failureMessage = nil
        state = permissionsGranted() ? .selectingSession : .permissionRequired
    }

    public func refreshSessionCandidates() {
        guard state == .ready || state == .selectingSession || state == .permissionRequired else {
            return
        }
        Task {
            do {
                let candidates = try await onRefreshSessionCandidates()
                presentSessionCandidates(candidates)
            } catch {
                failureMessage = String(describing: error)
            }
        }
    }

    public func claimSession(_ candidate: BrokerSessionCandidate) {
        guard state == .selectingSession, candidate.controllable else { return }
        guard permissionsGranted() else {
            permissions.refresh()
            state = .permissionRequired
            return
        }
        state = .claimingSession
        failureMessage = nil
        Task {
            do {
                try await onClaimSession(candidate.toolSessionID)
                state = .ready
            } catch {
                state = .selectingSession
                failureMessage = String(describing: error)
            }
        }
    }

    public func failIfInfrastructureUnavailable(_ available: Bool) {
        guard !available, state == .ready else { return }
        state = .failed
        failureMessage = localizedCoreString(
            "failure.infrastructure_unavailable",
            defaultValue: "Secure XPC services are unavailable."
        )
    }

    public func enforceCurrentPermissions() {
        guard state == .active || state == .activating || state == .paused else { return }
        permissions.refresh()
        guard !permissionsGranted() else { return }
        endSession()
    }

    public func retryAfterPermissionChange() {
        permissions.refresh()
        guard approvalPresentation != nil else {
            state = sessionCandidates.isEmpty ? .ready : .selectingSession
            return
        }
        state = permissionsGranted() ? .awaitingApproval : .permissionRequired
    }

    public func allowForSession() {
        guard state == .awaitingApproval, let approvalPresentation else { return }
        let approvals = approvalPresentation.approvals(
            applicationSelections: applicationSelections,
            clipboardSelections: clipboardSelections,
            controlLevelSelections: controlLevelSelections
        )
        guard !approvals.isEmpty else { return }
        approvedBundleIdentifiers = Set(approvals.map { $0.application.bundleIdentifier })
        state = .activating
        Task {
            do {
                try visibilityController.hideUnapprovedApplications(
                    approvedBundleIdentifiers: approvedBundleIdentifiers
                )
                try startSafetyMonitoring()
                try await onApprove(approvals)
                guard state == .activating else {
                    if let reason = lastUnsafeTransition {
                        try await onAbort(reason)
                    }
                    return
                }
                state = .active
                lastUnsafeTransition = nil
                if let controlNotifier {
                    await controlNotifier()
                } else {
                    await postControlNotification()
                }
            } catch {
                safetyMonitor?.stop()
                safetyMonitor = nil
                try? visibilityController.restoreApplications()
                state = .failed
                failureMessage = String(describing: error)
            }
        }
    }

    public func deny() {
        guard state == .awaitingApproval || state == .permissionRequired else { return }
        guard let presentation = approvalPresentation else { return }
        let deniedApprovals = presentation.approvals(
            applicationSelections: Set(presentation.applications.map(\.id)),
            clipboardSelections: [],
            controlLevelSelections: controlLevelSelections
        )
        state = .denied
        approvalPresentation = nil
        applicationSelections = []
        clipboardSelections = []
        controlLevelSelections = [:]
        Task {
            do {
                try await onDeny(deniedApprovals)
            } catch {
                state = .failed
                failureMessage = String(describing: error)
            }
        }
    }

    public func stopCurrentAction(reason: UnsafeTransitionReason = .escape) {
        guard state == .active || state == .activating else { return }
        let wasActivating = state == .activating
        safetyMonitor?.stop()
        safetyMonitor = nil
        do {
            try visibilityController.restoreApplications()
        } catch {
            state = .failed
            failureMessage = String(describing: error)
            Task { try? await onAbort(reason) }
            return
        }
        lastUnsafeTransition = reason
        state = .paused
        guard !wasActivating else { return }
        Task {
            do {
                try await onAbort(reason)
            } catch {
                state = .failed
                failureMessage = String(describing: error)
            }
        }
    }

    public func endSession() {
        guard state != .ready, state != .stopped else { return }
        safetyMonitor?.stop()
        safetyMonitor = nil
        do {
            try visibilityController.restoreApplications()
        } catch {
            state = .failed
            failureMessage = String(describing: error)
        }
        approvalPresentation = nil
        applicationSelections = []
        clipboardSelections = []
        controlLevelSelections = [:]
        approvedBundleIdentifiers = []
        state = .stopped
        Task {
            do {
                try await onEndSession()
            } catch {
                state = .failed
                failureMessage = String(describing: error)
            }
        }
    }

    public func switchSession() {
        let canSwitch = state == .active
            || state == .activating
            || state == .paused
            || state == .awaitingApproval
            || (state == .permissionRequired && approvalPresentation != nil)
        guard canSwitch else { return }
        safetyMonitor?.stop()
        safetyMonitor = nil
        do {
            try visibilityController.restoreApplications()
        } catch {
            state = .failed
            failureMessage = String(describing: error)
            return
        }
        approvalPresentation = nil
        applicationSelections = []
        clipboardSelections = []
        controlLevelSelections = [:]
        approvedBundleIdentifiers = []
        lastUnsafeTransition = nil
        state = .claimingSession
        Task {
            do {
                try await onEndSession()
                let candidates = try await onRefreshSessionCandidates()
                presentSessionCandidates(candidates)
            } catch {
                state = .failed
                failureMessage = String(describing: error)
            }
        }
    }

    public func handleRuntimeEvent(_ kind: BrokerRuntimeEventKind) throws {
        switch kind {
        case .turnStopped:
            guard state == .active || state == .activating else {
                throw DeviceAppFailure.invalidRuntimeTransition
            }
            safetyMonitor?.stop()
            safetyMonitor = nil
            do {
                try visibilityController.restoreApplications()
                lastUnsafeTransition = nil
                state = .paused
            } catch {
                state = .failed
                failureMessage = String(describing: error)
                throw error
            }
        case .turnStarted:
            guard state == .paused,
                  lastUnsafeTransition == nil,
                  !approvedBundleIdentifiers.isEmpty
            else {
                throw DeviceAppFailure.invalidRuntimeTransition
            }
            do {
                try visibilityController.hideUnapprovedApplications(
                    approvedBundleIdentifiers: approvedBundleIdentifiers
                )
                try startSafetyMonitoring()
                state = .active
            } catch {
                safetyMonitor?.stop()
                safetyMonitor = nil
                try? visibilityController.restoreApplications()
                state = .failed
                failureMessage = String(describing: error)
                throw error
            }
        case .sessionEnded:
            guard state == .active
                || state == .activating
                || (state == .paused && lastUnsafeTransition == nil)
            else {
                throw DeviceAppFailure.invalidRuntimeTransition
            }
            safetyMonitor?.stop()
            safetyMonitor = nil
            var restorationError: Error?
            do {
                try visibilityController.restoreApplications()
            } catch {
                restorationError = error
            }
            approvalPresentation = nil
            applicationSelections = []
            clipboardSelections = []
            controlLevelSelections = [:]
            approvedBundleIdentifiers = []
            lastUnsafeTransition = nil
            if let restorationError {
                state = .failed
                failureMessage = String(describing: restorationError)
                throw restorationError
            } else {
                state = .stopped
            }
        }
    }

    private func startSafetyMonitoring() throws {
        let monitor = safetyMonitorFactory { [weak self] reason in
            DispatchQueue.main.async {
                self?.stopCurrentAction(reason: reason)
            }
        }
        try monitor.start()
        safetyMonitor = monitor
    }

    private func postControlNotification() async {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = localizedCoreString(
            "notification.active.title",
            defaultValue: "Agent Remote Device"
        )
        content.body = localizedCoreString(
            "notification.active.body",
            defaultValue: "Claude is using this Mac. Press Esc to stop the current action."
        )
        let request = UNNotificationRequest(
            identifier: "device-control-active",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }
}

private func localizedCoreString(_ key: String, defaultValue: String) -> String {
    NSLocalizedString(key, bundle: .main, value: defaultValue, comment: "")
}
