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
        let ready = await broker.connect()
        if ready {
            healthLogger.notice("Secure XPC chain ready")
        } else {
            healthLogger.error("Secure XPC chain unavailable")
        }
        model.failIfInfrastructureUnavailable(ready)
        guard ready else { return }
        model.onApprove = { approvals in
            try await broker.approve(approvals)
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
        broker.setRuntimeEventHandler { kind in
            try await model.handleRuntimeEvent(kind)
        }

        var presentedBinding: DeviceSessionBinding?
        while !Task.isCancelled {
            do {
                if let pending = try await broker.pollPendingSession() {
                    if pending.binding != presentedBinding,
                       model.state != .active,
                       model.state != .activating
                    {
                        let presentation = try LocalApplicationDiscovery.approvalPresentation(
                            generation: pending.binding.generation
                        )
                        model.presentApproval(presentation)
                        presentedBinding = pending.binding
                    }
                } else {
                    presentedBinding = nil
                }
            } catch {
                brokerLogger.error("Broker poll failed")
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
