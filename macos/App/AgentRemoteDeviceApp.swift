import DeviceAppCore
import DeviceIPC
import Darwin
import OSLog
import SwiftUI

@main
struct AgentRemoteDeviceApp: App {
    @StateObject private var model = DeviceAppModel()
    private let broker = DeviceBrokerClient()
    private let brokerLogger = Logger(subsystem: "dev.agentremote.device", category: "broker")
    private let healthLogger = Logger(
        subsystem: "dev.agentremote.device",
        category: "xpc-health"
    )

    init() {
        guard DeviceProcessHardening.disableCoreDumps() else {
            exit(EXIT_FAILURE)
        }
    }

    var body: some Scene {
        WindowGroup {
            DeviceStatusView(model: model)
                .frame(minWidth: 540, minHeight: 420)
                .task {
                    await monitorBroker()
                }
        }
        .windowResizability(.contentMinSize)
    }

    @MainActor
    private func monitorBroker() async {
        configureModelHandlers()
        var connectedPreviously = false
        var presentedBinding: DeviceSessionBinding?
        while !Task.isCancelled {
            if model.state == .reconnecting {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            let ready = await broker.connect()
            if !ready {
                if connectedPreviously {
                    healthLogger.error("Secure XPC chain disconnected")
                } else {
                    healthLogger.error("Secure XPC chain unavailable")
                }
                connectedPreviously = false
                model.failIfInfrastructureUnavailable(false)
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if !connectedPreviously {
                healthLogger.notice("Secure XPC chain ready")
            }
            connectedPreviously = true
            model.recoverAfterInfrastructureReconnect()

            do {
                try await synchronizeBrokerState(presentedBinding: &presentedBinding)
            } catch {
                brokerLogger.error("Broker synchronization failed")
                model.reportSessionDiscoveryFailure(error)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @MainActor
    private func configureModelHandlers() {
        model.onApprove = { approvals in
            try await broker.approve(approvals)
        }
        model.onRefreshSessionCandidates = {
            try await broker.sessionCandidates()
        }
        model.onClaimSession = { toolSessionID in
            try await broker.claimSession(toolSessionID: toolSessionID)
        }
        model.onDeny = { approvals in
            try await broker.deny(approvals)
        }
        model.onAbort = { reason in
            let brokerReason: BrokerAbortReason = switch reason {
            case .escape: .escape
            case .networkDisconnected: .disconnect
            case .sleep, .screenLocked, .userSwitched: .localStop
            }
            try await broker.abort(reason: brokerReason)
        }
        model.onEndSession = {
            try await broker.endSession()
        }
        model.onReconnect = {
            await broker.connect()
        }
        broker.setRuntimeEventHandler { kind in
            try await model.handleRuntimeEvent(kind)
        }
    }

    @MainActor
    private func synchronizeBrokerState(
        presentedBinding: inout DeviceSessionBinding?
    ) async throws {
        model.enforceCurrentPermissions()
        switch model.state {
        case .selectingSession:
            guard !model.isRefreshingSessionCandidates else { return }
            let candidates = try await broker.sessionCandidates()
            model.presentSessionCandidates(candidates)
        case .ready, .paused, .stopped, .denied:
            if let pending = try await broker.pollPendingSession() {
                if pending.binding != presentedBinding {
                    let presentation = try LocalApplicationDiscovery.approvalPresentation(
                        generation: pending.binding.generation
                    )
                    model.presentApproval(presentation)
                    presentedBinding = pending.binding
                }
            } else {
                presentedBinding = nil
                let candidates = try await broker.sessionCandidates()
                model.presentSessionCandidates(candidates)
            }
        case .permissionRequired:
            if model.approvalPresentation == nil, model.sessionCandidates.isEmpty {
                let candidates = try await broker.sessionCandidates()
                model.presentSessionCandidates(candidates)
            }
        case .claimingSession, .awaitingApproval, .activating, .active, .pausing,
             .endingSession, .reconnecting, .failed:
            break
        }
    }
}
