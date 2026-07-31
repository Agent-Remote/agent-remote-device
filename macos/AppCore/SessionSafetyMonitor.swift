import AppKit
import Foundation
import GUIExecutor
import Network

public enum UnsafeTransitionReason: String, Sendable {
    case escape
    case sleep
    case screenLocked = "screen_locked"
    case userSwitched = "user_switched"
    case networkDisconnected = "network_disconnected"
}

private final class SafetyCallbackContext: @unchecked Sendable {
    private let lock = NSLock()
    private var observedSatisfiedNetwork = false
    let onTransition: @Sendable (UnsafeTransitionReason) -> Void

    init(onTransition: @escaping @Sendable (UnsafeTransitionReason) -> Void) {
        self.onTransition = onTransition
    }

    func handleNetworkPath(_ path: NWPath) {
        lock.lock()
        defer { lock.unlock() }
        if path.status == .satisfied {
            observedSatisfiedNetwork = true
        } else if observedSatisfiedNetwork {
            onTransition(.networkDisconnected)
        }
    }
}

@MainActor
public protocol SessionSafetyMonitoring: AnyObject {
    func start() throws
    func stop()
}

public final class SessionSafetyMonitor: SessionSafetyMonitoring, @unchecked Sendable {
    private let context: SafetyCallbackContext
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(label: "dev.agentremote.device.network-monitor")
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var escapeMonitor: GlobalStopMonitor?

    public init(onTransition: @escaping @Sendable (UnsafeTransitionReason) -> Void) {
        context = SafetyCallbackContext(onTransition: onTransition)
    }

    public func start() throws {
        precondition(Thread.isMainThread)
        guard escapeMonitor == nil else { return }

        let escapeMonitor = GlobalStopMonitor { [context] in
            context.onTransition(.escape)
        }
        try escapeMonitor.start()
        self.escapeMonitor = escapeMonitor

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [context] _ in context.onTransition(.sleep) },
            workspaceCenter.addObserver(
                forName: NSWorkspace.sessionDidResignActiveNotification,
                object: nil,
                queue: .main
            ) { [context] _ in context.onTransition(.userSwitched) },
        ]

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers = [
            distributedCenter.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { [context] _ in context.onTransition(.screenLocked) },
        ]

        pathMonitor.pathUpdateHandler = { [context] path in
            context.handleNetworkPath(path)
        }
        pathMonitor.start(queue: pathQueue)
    }

    public func stop() {
        precondition(Thread.isMainThread)
        escapeMonitor?.stop()
        escapeMonitor = nil
        pathMonitor.cancel()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll(keepingCapacity: false)

        let distributedCenter = DistributedNotificationCenter.default()
        distributedObservers.forEach(distributedCenter.removeObserver)
        distributedObservers.removeAll(keepingCapacity: false)
    }
}
