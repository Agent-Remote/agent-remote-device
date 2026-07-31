import DeviceAppCore
import DeviceSecurity
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

            switch model.state {
            case .permissionRequired:
                PermissionView(model: model)
            case .awaitingApproval:
                if let presentation = model.approvalPresentation {
                    ApprovalView(model: model, presentation: presentation)
                }
            case .active, .activating, .paused:
                SessionControlsView(model: model)
            case .failed:
                ContentUnavailableView(
                    localizedAppString("failure.title"),
                    systemImage: "exclamationmark.shield",
                    description: Text(
                        model.failureMessage ?? localizedAppString("failure.closed")
                    )
                )
            default:
                Spacer()
                ContentUnavailableView(statusTitle, systemImage: statusSymbol)
                Spacer()
            }
        }
        .padding(24)
    }

    private var statusTitle: String {
        switch model.state {
        case .ready: localizedAppString("status.ready")
        case .permissionRequired: localizedAppString("status.permission_required")
        case .awaitingApproval: localizedAppString("status.approval_required")
        case .activating: localizedAppString("status.activating")
        case .active: localizedAppString("status.active")
        case .paused: localizedAppString("status.paused")
        case .denied: localizedAppString("status.denied")
        case .stopped: localizedAppString("status.stopped")
        case .failed: localizedAppString("status.failed")
        }
    }

    private var statusSymbol: String {
        switch model.state {
        case .active, .activating: "cursorarrow.motionlines"
        case .permissionRequired, .awaitingApproval: "hand.raised"
        case .failed: "exclamationmark.shield"
        case .paused, .denied, .stopped: "stop.circle"
        case .ready: "checkmark.shield"
        }
    }

    private var statusColor: Color {
        switch model.state {
        case .active, .activating: .green
        case .permissionRequired, .awaitingApproval: .orange
        case .failed: .red
        default: .secondary
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

private struct ApprovalView: View {
    @ObservedObject var model: DeviceAppModel
    let presentation: ApprovalPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            List(presentation.applications) { candidate in
                ApprovalApplicationRow(model: model, candidate: candidate)
            }
            .listStyle(.inset)

            Label(
                String.localizedStringWithFormat(
                    localizedAppString("approval.hidden_applications"),
                    presentation.hiddenApplicationCount
                ),
                systemImage: "eye.slash"
            )
            .foregroundStyle(.secondary)

            HStack {
                Button(role: .cancel) {
                    model.deny()
                } label: {
                    Label(localizedAppString("approval.deny"), systemImage: "xmark")
                }
                Spacer()
                Button {
                    model.allowForSession()
                } label: {
                    Label(localizedAppString("approval.allow_session"), systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.applicationSelections.isEmpty)
            }
        }
    }
}

private struct ApprovalApplicationRow: View {
    @ObservedObject var model: DeviceAppModel
    let candidate: ApprovalCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle(
                    candidate.displayName,
                    isOn: Binding(
                        get: { model.applicationSelections.contains(candidate.id) },
                        set: { enabled in
                            if enabled {
                                model.applicationSelections.insert(candidate.id)
                            } else {
                                model.applicationSelections.remove(candidate.id)
                                model.clipboardSelections.remove(candidate.id)
                            }
                        }
                    )
                )
                .font(.headline)
                Spacer()
                if candidate.classification.source == .pendingConfirmation {
                    Picker(
                        localizedAppString("approval.control_level"),
                        selection: Binding(
                            get: { model.controlLevelSelections[candidate.id] ?? .viewOnly },
                            set: { model.controlLevelSelections[candidate.id] = $0 }
                        )
                    ) {
                        Text(localizedAppString("control.view")).tag(ControlLevel.viewOnly)
                        Text(localizedAppString("control.click")).tag(ControlLevel.clickOnly)
                        Text(localizedAppString("control.full")).tag(ControlLevel.fullControl)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                } else {
                    Text(controlLevelTitle)
                        .foregroundStyle(.secondary)
                }
            }
            if candidate.classification.source == .pendingConfirmation {
                Label(localizedAppString("approval.category_pending"), systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
            }
            ForEach(candidate.classification.warnings.sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { warning in
                Label(warningTitle(warning), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if candidate.clipboardRequested {
                Toggle(
                    localizedAppString("approval.clipboard"),
                    isOn: Binding(
                        get: { model.clipboardSelections.contains(candidate.id) },
                        set: { enabled in
                            if enabled {
                                model.clipboardSelections.insert(candidate.id)
                            } else {
                                model.clipboardSelections.remove(candidate.id)
                            }
                        }
                    )
                )
                .disabled(!model.applicationSelections.contains(candidate.id))
            }
        }
        .padding(.vertical, 6)
    }

    private var controlLevelTitle: String {
        switch candidate.effectiveControlLevel {
        case .viewOnly: localizedAppString("control.view_only")
        case .clickOnly: localizedAppString("control.click_only")
        case .fullControl: localizedAppString("control.full_control")
        }
    }

    private func warningTitle(_ warning: ApplicationWarning) -> String {
        switch warning {
        case .shellAccess: localizedAppString("warning.shell_access")
        case .fileAccess: localizedAppString("warning.file_access")
        case .systemSettings: localizedAppString("warning.system_settings")
        }
    }
}

private struct SessionControlsView: View {
    @ObservedObject var model: DeviceAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.state == .paused, let reason = model.lastUnsafeTransition {
                Label(reasonTitle(reason), systemImage: "hand.raised.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Button {
                    model.stopCurrentAction(reason: .escape)
                } label: {
                    Label(localizedAppString("session.stop_action"), systemImage: "stop.fill")
                }
                .disabled(model.state != .active && model.state != .activating)
                Spacer()
                Button(role: .destructive) {
                    model.endSession()
                } label: {
                    Label(localizedAppString("session.end"), systemImage: "xmark.circle")
                }
            }
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

private func localizedAppString(_ key: String) -> String {
    NSLocalizedString(key, bundle: .main, comment: "")
}
