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
        var connectedGeneration: UInt64?
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
            guard let currentGeneration = broker.connectedGeneration() else {
                connectedPreviously = false
                model.failIfInfrastructureUnavailable(false)
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            if let connectedGeneration, connectedGeneration != currentGeneration {
                model.failIfInfrastructureUnavailable(false)
            }
            connectedGeneration = currentGeneration
            if !connectedPreviously {
                healthLogger.notice("Secure XPC chain ready")
            }
            connectedPreviously = true
            model.recoverAfterInfrastructureReconnect()

            do {
                try await synchronizeBrokerState()
            } catch {
                brokerLogger.error("Broker synchronization failed")
                model.reportSessionDiscoveryFailure(error)
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    @MainActor
    private func configureModelHandlers() {
        model.onRefreshSessionCandidates = {
            try await broker.sessionCandidates()
        }
        model.onClaimSession = { toolSessionID in
            try await broker.claimSession(toolSessionID: toolSessionID)
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
    private func synchronizeBrokerState() async throws {
        model.enforceCurrentPermissions()
        switch model.state {
        case .selectingSession:
            guard !model.isRefreshingSessionCandidates else { return }
            let candidates = try await broker.sessionCandidates()
            model.presentSessionCandidates(candidates)
        case .ready, .stopped:
            let candidates = try await broker.sessionCandidates()
            model.presentSessionCandidates(candidates)
        case .permissionRequired:
            if model.sessionCandidates.isEmpty {
                let candidates = try await broker.sessionCandidates()
                model.presentSessionCandidates(candidates)
            }
        case .claimingSession, .activating, .active, .pausing, .paused,
             .endingSession, .reconnecting, .failed:
            break
        }
    }
}
