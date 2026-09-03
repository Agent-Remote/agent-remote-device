import AppKit
import DeviceAppCore
import DeviceIPC
import SwiftUI

struct DeviceStatusView: View {
    @ObservedObject var model: DeviceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 28))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(localizedAppString("app.name"))
                        .font(.title2.weight(.semibold))
                    Text(statusTitle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            if model.state == .selectingSession, let completionMessage = model.completionMessage {
                Label(completionMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            switch model.state {
            case .permissionRequired:
                PermissionView(model: model)
            case .selectingSession:
                SessionSelectionView(model: model)
            case .claimingSession, .activating:
                SessionPreparationView(model: model)
            case .active, .paused:
                SessionControlsView(model: model)
            case .pausing:
                OperationProgressView(
                    title: localizedAppString("status.pausing"),
                    systemImage: "stop.fill"
                )
            case .endingSession:
                OperationProgressView(
                    title: localizedAppString("status.ending_session"),
                    systemImage: "xmark.circle"
                )
            case .reconnecting:
                OperationProgressView(
                    title: localizedAppString("status.reconnecting"),
                    systemImage: "network"
                )
            case .failed:
                FailureRecoveryView(model: model)
            case .stopped:
                RecoveryActionView(
                    title: statusTitle,
                    message: model.completionMessage ?? localizedAppString("session.return_hint"),
                    actionTitle: localizedAppString("session.return_to_list"),
                    action: model.returnToSessionSelection
                )
            case .ready:
                OperationProgressView(
                    title: localizedAppString("status.loading_sessions"),
                    systemImage: "desktopcomputer"
                )
            }
        }
        .padding(24)
    }

    private var statusTitle: String {
        switch model.state {
        case .ready: localizedAppString("status.ready")
        case .selectingSession: localizedAppString("status.selecting_session")
        case .claimingSession: localizedAppString("status.claiming_session")
        case .permissionRequired: localizedAppString("status.permission_required")
        case .activating: localizedAppString("status.activating")
        case .active: localizedAppString("status.active")
        case .pausing: localizedAppString("status.pausing")
        case .paused: localizedAppString("status.paused")
        case .endingSession: localizedAppString("status.ending_session")
        case .reconnecting: localizedAppString("status.reconnecting")
        case .stopped: localizedAppString("status.stopped")
        case .failed: localizedAppString("status.failed")
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .active, .activating: "cursorarrow.motionlines"
        case .pausing: "stop.fill"
        case .selectingSession, .claimingSession: "list.bullet.rectangle"
        case .endingSession: "xmark.circle"
        case .reconnecting: "network"
        case .permissionRequired: "hand.raised"
        case .failed: "exclamationmark.shield"
        case .paused, .stopped: "stop.circle"
        case .ready: "checkmark.shield"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .active, .activating: .green
        case .selectingSession, .claimingSession: .blue
        case .permissionRequired: .orange
        case .failed: .red
        case .pausing, .endingSession, .reconnecting: .blue
        default: .secondary
        }
    }
}

private struct SessionSelectionView: View {
    @ObservedObject var model: DeviceAppModel
    @State private var candidateToClaim: BrokerSessionCandidate?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    localizedAppString("session.select_title"),
                    systemImage: "rectangle.stack.person.crop"
                )
                .font(.headline)
                Spacer()
                Button {
                    model.refreshSessionCandidates()
                } label: {
                    Label(localizedAppString("session.refresh"), systemImage: "arrow.clockwise")
                }
                .disabled(model.state == .claimingSession || model.isRefreshingSessionCandidates)
            }

            if let failureMessage = model.failureMessage {
                VStack(alignment: .leading, spacing: 4) {
                    Label(failureMessage, systemImage: "exclamationmark.triangle")
                    if let failureCode = model.failureCode {
                        Text(failureCode)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.leading, 24)
                    }
                }
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }

            if model.isRefreshingSessionCandidates, model.sessionCandidates.isEmpty {
                Spacer()
                ProgressView(localizedAppString("session.loading"))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if model.sessionCandidates.isEmpty {
                ContentUnavailableView(
                    localizedAppString("session.no_candidates"),
                    systemImage: "desktopcomputer"
                )
            } else {
                List(model.sessionCandidates, id: \.toolSessionID) { candidate in
                    Button {
                        if candidate.currentDeviceID == nil {
                            model.claimSession(candidate)
                        } else {
                            candidateToClaim = candidate
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(candidate.displayName)
                                    .font(.headline)
                                Text(candidate.projectKey)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                if let deviceName = candidate.currentDeviceName {
                                    Text(
                                        String.localizedStringWithFormat(
                                            localizedAppString("session.current_device"),
                                            deviceName
                                        )
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.state == .claimingSession)
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .alert(
            localizedAppString("session.rebind_title"),
            isPresented: Binding(
                get: { candidateToClaim != nil },
                set: { visible in
                    if !visible { candidateToClaim = nil }
                }
            )
        ) {
            Button(localizedAppString("session.claim"), role: .destructive) {
                if let candidateToClaim {
                    model.claimSession(candidateToClaim)
                }
                candidateToClaim = nil
            }
            Button(localizedAppString("common.cancel"), role: .cancel) {
                candidateToClaim = nil
            }
        } message: {
            Text(localizedAppString("session.rebind_message"))
        }
    }
}

private struct SessionPreparationView: View {
    @ObservedObject var model: DeviceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selectedSession = model.selectedSession {
                SessionIdentityView(session: selectedSession)
            }
            Spacer()
            ContentUnavailableView {
                Label(
                    localizedAppString("session.preparing_secure_connection"),
                    systemImage: "lock.shield"
                )
            } description: {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer()
        }
    }
}

private struct PermissionView: View {
    @ObservedObject var model: DeviceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PermissionRow(
                title: localizedAppString("permission.accessibility"),
                granted: model.permissions.accessibilityGranted,
                request: model.permissions.requestAccessibility,
                settings: model.permissions.openAccessibilitySettings
            )
            PermissionRow(
                title: localizedAppString("permission.screen_recording"),
                granted: model.permissions.screenRecordingGranted,
                request: model.permissions.requestScreenRecording,
                settings: model.permissions.openScreenRecordingSettings
            )
            if model.permissions.restartRequired {
                Label(localizedAppString("permission.restart_required"), systemImage: "arrow.clockwise")
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                if model.selectedSession != nil {
                    Button {
                        model.switchSession()
                    } label: {
                        Label(
                            localizedAppString("session.switch"),
                            systemImage: "arrow.left.arrow.right"
                        )
                    }
                }
                Spacer()
                Button {
                    model.retryAfterPermissionChange()
                } label: {
                    Label(localizedAppString("permission.check_again"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let granted: Bool
    let request: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack {
            Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .primary)
            Spacer()
            if !granted {
                Button(localizedAppString("permission.request"), action: request)
                Button(action: settings) {
                    Image(systemName: "gear")
                }
                .help(localizedAppString("permission.open_settings"))
            }
        }
    }
}

private struct SessionControlsView: View {
    @ObservedObject var model: DeviceAppModel
    @State private var pendingConfirmation: SessionControlConfirmation?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selectedSession = model.selectedSession {
                SessionIdentityView(session: selectedSession)
            }
            if model.state == .paused, let reason = model.lastUnsafeTransition {
                Label(reasonTitle(reason), systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button {
                    pendingConfirmation = .switchSession
                } label: {
                    Label(
                        localizedAppString("session.switch"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                }
                .disabled(model.state == .activating)
                Button {
                    model.stopCurrentAction(reason: .escape)
                } label: {
                    Label(localizedAppString("session.stop_action"), systemImage: "stop.fill")
                }
                .disabled(model.state != .active && model.state != .activating)
                Spacer()
                Button(role: .destructive) {
                    pendingConfirmation = .endControl
                } label: {
                    Label(localizedAppString("session.end_control"), systemImage: "xmark.circle")
                }
            }
        }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: { visible in
                    if !visible { pendingConfirmation = nil }
                }
            )
        ) {
            switch pendingConfirmation {
            case .switchSession:
                Button(localizedAppString("session.switch_confirm"), role: .destructive) {
                    model.switchSession()
                    pendingConfirmation = nil
                }
            case .endControl:
                Button(localizedAppString("session.end_confirm"), role: .destructive) {
                    model.endSession()
                    pendingConfirmation = nil
                }
            case nil:
                EmptyView()
            }
            Button(localizedAppString("common.cancel"), role: .cancel) {
                pendingConfirmation = nil
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .switchSession: localizedAppString("session.switch_confirm_title")
        case .endControl: localizedAppString("session.end_confirm_title")
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .switchSession: localizedAppString("session.switch_confirm_message")
        case .endControl: localizedAppString("session.end_confirm_message")
        case nil: ""
        }
    }

    private func reasonTitle(_ reason: UnsafeTransitionReason) -> String {
        switch reason {
        case .escape: localizedAppString("stop.escape")
        case .sleep: localizedAppString("stop.sleep")
        case .screenLocked: localizedAppString("stop.screen_locked")
        case .userSwitched: localizedAppString("stop.user_switched")
        case .networkDisconnected: localizedAppString("stop.network_disconnected")
        }
    }
}

private struct SessionIdentityView: View {
    let session: BrokerSessionCandidate

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.displayName)
                    .font(.headline)
                Text(session.projectKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
        }
    }
}

private enum SessionControlConfirmation {
    case switchSession
    case endControl
}

private struct OperationProgressView: View {
    let title: String
    let systemImage: String

    var body: some View {
        Spacer()
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            ProgressView()
                .controlSize(.small)
        }
        Spacer()
    }
}

private struct RecoveryActionView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        Spacer()
        ContentUnavailableView {
            Label(title, systemImage: "checkmark.shield")
        } description: {
            Text(message)
        } actions: {
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
        }
        Spacer()
    }
}

private struct FailureRecoveryView: View {
    @ObservedObject var model: DeviceAppModel

    var body: some View {
        Spacer()
        ContentUnavailableView {
            Label(localizedAppString("failure.title"), systemImage: "exclamationmark.shield")
        } description: {
            VStack(spacing: 8) {
                Text(model.failureMessage ?? localizedAppString("failure.closed"))
                if let failureCode = model.failureCode {
                    Text(failureCode)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .textSelection(.enabled)
        } actions: {
            switch model.failureRecovery {
            case .reconnect:
                Button(localizedAppString("failure.reconnect")) {
                    model.retryAfterFailure()
                }
                .buttonStyle(.borderedProminent)
            case .sessionSelection:
                Button(localizedAppString("session.return_to_list")) {
                    model.returnToSessionSelection()
                }
                .buttonStyle(.borderedProminent)
            case .restartApplication:
                Button(localizedAppString("failure.quit"), role: .destructive) {
                    NSApplication.shared.terminate(nil)
                }
            case nil:
                Button(localizedAppString("session.return_to_list")) {
                    model.returnToSessionSelection()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        Spacer()
    }
}

private func localizedAppString(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
