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
    case pausing
    case paused
    case endingSession = "ending_session"
    case reconnecting
    case denied
    case stopped
    case failed
}

public enum DeviceFailureRecovery: Equatable, Sendable {
    case reconnect
    case sessionSelection
    case restartApplication
}

public protocol DeviceAppErrorCodeProviding: Error {
    var deviceErrorCode: String { get }
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
    @Published public private(set) var failureCode: String?
    @Published public private(set) var failureRecovery: DeviceFailureRecovery?
    @Published public private(set) var completionMessage: String?
    @Published public private(set) var isRefreshingSessionCandidates = false

    public let permissions: PermissionController

    private let visibilityController: any WorkspaceVisibilityControlling
    private let safetyMonitorFactory: (
        @escaping @Sendable (UnsafeTransitionReason) -> Void
    ) -> any SessionSafetyMonitoring
    private let permissionsGranted: () -> Bool
    private let controlNotifier: (() async -> Void)?
    private var safetyMonitor: (any SessionSafetyMonitoring)?
    private var approvedBundleIdentifiers: Set<String> = []
    private var operationGeneration: UInt64 = 0

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
    public var onReconnect: () async -> Bool = { false }

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
            failureMessage = userFacingDescription(error)
            failureCode = "application_restore_failed"
            failureRecovery = .restartApplication
        }
    }

    public func presentApproval(_ presentation: ApprovalPresentation) {
        invalidateAsyncOperations()
        sessionCandidates = []
        failureMessage = nil
        failureCode = nil
        failureRecovery = nil
        completionMessage = nil
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
        guard state == .ready
            || state == .selectingSession
            || state == .claimingSession
            || state == .permissionRequired
            || state == .denied
            || state == .stopped
            || state == .reconnecting
        else { return }
        invalidateAsyncOperations()
        applySessionCandidates(candidates)
    }

    private func applySessionCandidates(_ candidates: [BrokerSessionCandidate]) {
        sessionCandidates = candidates
        failureMessage = nil
        failureCode = nil
        failureRecovery = nil
        isRefreshingSessionCandidates = false
        state = permissionsGranted() ? .selectingSession : .permissionRequired
    }

    public func refreshSessionCandidates() {
        guard state == .ready
            || state == .selectingSession
            || state == .permissionRequired
            || state == .denied
            || state == .stopped
            || state == .failed
        else {
            return
        }
        let operation = beginAsyncOperation()
        state = .selectingSession
        isRefreshingSessionCandidates = true
        failureMessage = nil
        failureCode = nil
        failureRecovery = nil
        Task {
            do {
                let candidates = try await onRefreshSessionCandidates()
                guard isCurrentOperation(operation), state == .selectingSession else { return }
                applySessionCandidates(candidates)
            } catch {
                guard isCurrentOperation(operation), state == .selectingSession else { return }
                isRefreshingSessionCandidates = false
                failureMessage = userFacingDescription(error)
                failureCode = errorCode(error)
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
        failureCode = nil
        completionMessage = nil
        let operation = beginAsyncOperation()
        Task {
            do {
                try await onClaimSession(candidate.toolSessionID)
                guard isCurrentOperation(operation), state == .claimingSession else { return }
                state = .ready
            } catch {
                guard isCurrentOperation(operation), state == .claimingSession else { return }
                state = .selectingSession
                failureMessage = userFacingDescription(error)
                failureCode = errorCode(error)
            }
        }
    }

    public func failIfInfrastructureUnavailable(_ available: Bool) {
        guard !available else { return }
        if state == .failed, failureRecovery == .restartApplication { return }
        failClosed(
            message: localizedCoreString(
                "failure.infrastructure_unavailable",
                defaultValue: "Secure XPC services are unavailable."
            ),
            recovery: .reconnect,
            code: "xpc_services_unavailable"
        )
    }

    public func recoverAfterInfrastructureReconnect() {
        guard state == .failed || state == .reconnecting else { return }
        guard failureRecovery == .reconnect || state == .reconnecting else { return }
        invalidateAsyncOperations()
        failureMessage = nil
        failureCode = nil
        failureRecovery = nil
        state = .ready
    }

    public func reportSessionDiscoveryFailure(_ error: Error) {
        guard state == .ready || state == .selectingSession else { return }
        state = .selectingSession
        isRefreshingSessionCandidates = false
        failureMessage = userFacingDescription(error)
        failureCode = errorCode(error)
    }

    public func retryAfterFailure() {
        guard state == .failed, let failureRecovery else { return }
        switch failureRecovery {
        case .reconnect:
            let operation = beginAsyncOperation()
            state = .reconnecting
            failureMessage = nil
            failureCode = nil
            Task {
                let connected = await onReconnect()
                guard isCurrentOperation(operation), state == .reconnecting else { return }
                guard connected else {
                    state = .failed
                    self.failureRecovery = .reconnect
                    failureMessage = localizedCoreString(
                        "failure.infrastructure_unavailable",
                        defaultValue: "Secure XPC services are unavailable."
                    )
                    failureCode = "xpc_services_unavailable"
                    return
                }
                state = .ready
                refreshSessionCandidates()
            }
        case .sessionSelection:
            returnToSessionSelection()
        case .restartApplication:
            break
        }
    }

    public func returnToSessionSelection() {
        guard state != .active, state != .activating, state != .endingSession else { return }
        clearSessionContext()
        completionMessage = nil
        state = .selectingSession
        refreshSessionCandidates()
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
            if sessionCandidates.isEmpty {
                state = .ready
                refreshSessionCandidates()
            } else {
                state = .selectingSession
            }
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
        completionMessage = nil
        let operation = beginAsyncOperation()
        Task {
            do {
                try visibilityController.hideUnapprovedApplications(
                    approvedBundleIdentifiers: approvedBundleIdentifiers
                )
                try startSafetyMonitoring()
                try await onApprove(approvals)
                guard isCurrentOperation(operation), state == .activating else {
                    if let reason = lastUnsafeTransition {
                        try await onAbort(reason)
                        guard isCurrentOperation(operation), state == .pausing else { return }
                        state = .paused
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
                guard isCurrentOperation(operation) else { return }
                safetyMonitor?.stop()
                safetyMonitor = nil
                do {
                    try visibilityController.restoreApplications()
                    if errorCode(error) == "session_binding_changed" {
                        clearSessionContext()
                        completionMessage = nil
                        state = .selectingSession
                        refreshSessionCandidates()
                    } else {
                        transitionToFailure(error, recovery: .sessionSelection)
                    }
                } catch {
                    failClosed(
                        message: userFacingDescription(error),
                        recovery: .restartApplication
                    )
                }
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
        clearSessionContext()
        let operation = beginAsyncOperation()
        Task {
            do {
                try await onDeny(deniedApprovals)
                guard isCurrentOperation(operation), state == .denied else { return }
                completionMessage = localizedCoreString(
                    "completion.denied",
                    defaultValue: "The device-control request was denied."
                )
                await loadSessionCandidates(after: operation)
            } catch {
                guard isCurrentOperation(operation), state == .denied else { return }
                transitionToFailure(error, recovery: .sessionSelection)
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
            failClosed(message: userFacingDescription(error), recovery: .restartApplication)
            Task { try? await onAbort(reason) }
            return
        }
        lastUnsafeTransition = reason
        state = .pausing
        guard !wasActivating else { return }
        let operation = beginAsyncOperation()
        Task {
            do {
                try await onAbort(reason)
                guard isCurrentOperation(operation), state == .pausing else { return }
                state = .paused
            } catch {
                guard isCurrentOperation(operation), state == .pausing else { return }
                transitionToFailure(error, recovery: .sessionSelection)
            }
        }
    }

    public func endSession() {
        guard canEndOrSwitch else { return }
        endCurrentSession(
            completion: localizedCoreString(
                "completion.ended",
                defaultValue: "Device control ended."
            )
        )
    }

    public func switchSession() {
        guard canEndOrSwitch else { return }
        endCurrentSession(
            completion: localizedCoreString(
                "completion.switched",
                defaultValue: "Choose another Claude session."
            )
        )
    }

    private var canEndOrSwitch: Bool {
        state == .active
            || state == .activating
            || state == .paused
            || state == .awaitingApproval
            || (state == .permissionRequired && approvalPresentation != nil)
    }

    private func endCurrentSession(completion: String) {
        safetyMonitor?.stop()
        safetyMonitor = nil
        do {
            try visibilityController.restoreApplications()
        } catch {
            failClosed(message: userFacingDescription(error), recovery: .restartApplication)
            return
        }
        clearSessionContext()
        lastUnsafeTransition = nil
        state = .endingSession
        let operation = beginAsyncOperation()
        Task {
            do {
                try await onEndSession()
                guard isCurrentOperation(operation), state == .endingSession else { return }
                completionMessage = completion
                await loadSessionCandidates(after: operation)
            } catch {
                guard isCurrentOperation(operation), state == .endingSession else { return }
                transitionToFailure(error, recovery: .sessionSelection)
            }
        }
    }

    public func handleRuntimeEvent(_ kind: BrokerRuntimeEventKind) throws {
        switch kind {
        case .turnStopped:
            if state == .pausing
                || state == .endingSession
                || state == .stopped
                || state == .selectingSession
            {
                return
            }
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
                failClosed(message: userFacingDescription(error), recovery: .restartApplication)
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
                failClosed(message: userFacingDescription(error), recovery: .restartApplication)
                throw error
            }
        case .sessionEnded:
            if state == .endingSession || state == .stopped || state == .selectingSession {
                return
            }
            guard state == .active
                || state == .activating
                || state == .pausing
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
                failClosed(
                    message: userFacingDescription(restorationError),
                    recovery: .restartApplication
                )
                throw restorationError
            } else {
                state = .stopped
                completionMessage = localizedCoreString(
                    "completion.remote_ended",
                    defaultValue: "The remote device-control session ended."
                )
                refreshSessionCandidates()
            }
        }
    }

    private func loadSessionCandidates(after operation: UInt64) async {
        do {
            let candidates = try await onRefreshSessionCandidates()
            guard isCurrentOperation(operation) else { return }
            applySessionCandidates(candidates)
        } catch {
            guard isCurrentOperation(operation) else { return }
            state = .selectingSession
            isRefreshingSessionCandidates = false
            failureMessage = userFacingDescription(error)
            failureCode = errorCode(error)
            failureRecovery = nil
        }
    }

    private func clearSessionContext() {
        approvalPresentation = nil
        applicationSelections = []
        clipboardSelections = []
        controlLevelSelections = [:]
        approvedBundleIdentifiers = []
        lastUnsafeTransition = nil
    }

    private func transitionToFailure(_ error: Error, recovery: DeviceFailureRecovery) {
        state = .failed
        failureMessage = userFacingDescription(error)
        failureCode = errorCode(error)
        failureRecovery = recovery
        isRefreshingSessionCandidates = false
    }

    private func failClosed(
        message: String,
        recovery: DeviceFailureRecovery,
        code: String = "application_restore_failed"
    ) {
        invalidateAsyncOperations()
        safetyMonitor?.stop()
        safetyMonitor = nil
        var resolvedMessage = message
        var resolvedRecovery = recovery
        var resolvedCode = code
        do {
            try visibilityController.restoreApplications()
        } catch {
            resolvedMessage = userFacingDescription(error)
            resolvedRecovery = .restartApplication
            resolvedCode = "application_restore_failed"
        }
        clearSessionContext()
        state = .failed
        failureMessage = resolvedMessage
        failureCode = resolvedCode
        failureRecovery = resolvedRecovery
        isRefreshingSessionCandidates = false
    }

    private func beginAsyncOperation() -> UInt64 {
        operationGeneration &+= 1
        return operationGeneration
    }

    private func invalidateAsyncOperations() {
        operationGeneration &+= 1
        isRefreshingSessionCandidates = false
    }

    private func isCurrentOperation(_ operation: UInt64) -> Bool {
        operationGeneration == operation
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

private func userFacingDescription(_ error: Error) -> String {
    if let localized = error as? LocalizedError,
       let description = localized.errorDescription,
       !description.isEmpty
    {
        return description
    }
    return error.localizedDescription
}

private func errorCode(_ error: Error) -> String {
    (error as? any DeviceAppErrorCodeProviding)?.deviceErrorCode ?? "device_operation_failed"
}
