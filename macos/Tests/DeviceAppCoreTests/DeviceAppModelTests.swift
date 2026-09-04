import DeviceAppCore
import DeviceIPC
import Foundation
import GUIExecutor
import Testing

@MainActor
@Test func unavailableSecureIPCChangesOnlyTheReadyStateToFailed() {
    let journalURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
        .appendingPathComponent("visibility.json", isDirectory: false)
    let model = DeviceAppModel(
        visibilityController: WorkspaceVisibilityController(journalURL: journalURL)
    )

    model.failIfInfrastructureUnavailable(true)
    #expect(model.state == .ready)
    model.failIfInfrastructureUnavailable(false)
    #expect(model.state == .failed)
    #expect(model.failureMessage == "Secure XPC services are unavailable.")
}

@MainActor
@Test func safetyMonitoringStartsWithoutHidingUserApplications() async throws {
    let events = EventRecorder()
    let visibility = RecordingVisibilityController(events: events)
    let model = DeviceAppModel(
        visibilityController: visibility,
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in
        events.append("claim")
        return true
    }
    try await claimAndWaitForActivation(model)

    #expect(model.state == .active)
    #expect(events.values().prefix(2) == ["claim", "monitor"])
    #expect(!events.values().contains("hide"))
}

@MainActor
@Test func permissionRevocationEndsActiveControl() async throws {
    let events = EventRecorder()
    var permissionsGranted = true
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { permissionsGranted },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    model.onEndSession = { events.append("end") }
    try await claimAndWaitForActivation(model)

    permissionsGranted = false
    model.enforceCurrentPermissions()
    for _ in 0 ..< 200 where model.state != .permissionRequired {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .permissionRequired)
    #expect(events.values().contains("restore"))
    #expect(events.values().contains("end"))
}

@MainActor
@Test func transientPermissionFailureIsRetriedWithoutEndingControl() async throws {
    let events = EventRecorder()
    var permissionsGranted = true
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { permissionsGranted },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    model.onEndSession = { events.append("end") }
    try await claimAndWaitForActivation(model)

    permissionsGranted = false
    model.enforceCurrentPermissions()
    permissionsGranted = true
    try await Task.sleep(for: .milliseconds(350))

    #expect(model.state == .active)
    #expect(!events.values().contains("end"))
}

@MainActor
@Test func pendingPermissionRetryCannotEndReplacementSession() async throws {
    let events = EventRecorder()
    var permissionsGranted = true
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { permissionsGranted },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    model.onEndSession = { events.append("end") }
    try await claimAndWaitForActivation(model)

    permissionsGranted = false
    model.enforceCurrentPermissions()
    try await Task.sleep(for: .milliseconds(300))

    try model.handleRuntimeEvent(.sessionEnded)
    permissionsGranted = true
    try await claimAndWaitForActivation(model, candidate: sessionCandidate(displayName: "Replacement"))

    permissionsGranted = false
    model.enforceCurrentPermissions()
    try await Task.sleep(for: .milliseconds(300))

    #expect(model.state == .active)
    #expect(!events.values().contains("end"))

    permissionsGranted = true
    try await Task.sleep(for: .milliseconds(300))

    #expect(model.state == .active)
    #expect(!events.values().contains("end"))
}

@MainActor
@Test func candidatesWaitForPermissionsBeforeTheyCanBeClaimed() async throws {
    var permissionsGranted = false
    let model = DeviceAppModel(permissionsGranted: { permissionsGranted })
    let remote = BrokerSessionCandidate(
        toolSessionID: UUID(),
        toolType: "claude",
        toolAccountID: UUID(),
        workspaceID: UUID(),
        projectKey: "Workspace",
        displayName: "Workspace",
        status: .running,
        nodeID: UUID(),
        runtimeBackend: "native",
        currentDeviceID: nil,
        currentDeviceName: nil,
        deviceSessionID: nil,
        controllable: true
    )
    var claimed = false
    model.onClaimSession = { _ in
        claimed = true
        return false
    }

    model.presentSessionCandidates([remote])
    #expect(model.state == .permissionRequired)
    model.claimSession(remote)
    #expect(!claimed)

    permissionsGranted = true
    model.retryAfterPermissionChange()
    #expect(model.state == .selectingSession)
    model.claimSession(remote)
    for _ in 0 ..< 100 where !claimed {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(claimed)
}

@MainActor
@Test func claimedFullTrustSessionIsAbortedWhenSafetyMonitoringCannotStart() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        safetyMonitorFactory: { _ in
            FailingSafetyMonitor(events: events)
        },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    let remote = sessionCandidate(displayName: "Workspace")
    model.onClaimSession = { _ in
        events.append("claim")
        return true
    }
    model.onAbort = { reason in
        events.append("abort:\(reason.rawValue)")
    }

    model.presentSessionCandidates([remote])
    model.claimSession(remote)
    for _ in 0 ..< 100 where !events.values().contains("abort:network_disconnected") {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(events.values() == ["claim", "monitor", "abort:network_disconnected"])
    #expect(model.state == .selectingSession)
    #expect(model.failureMessage != nil)
}

@MainActor
@Test func fullTrustClaimKeepsSelectedSessionVisibleThroughActivation() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    let remote = sessionCandidate(displayName: "Selected Workspace")
    model.onClaimSession = { _ in true }

    model.presentSessionCandidates([remote])
    model.claimSession(remote)
    #expect(model.state == .claimingSession)
    #expect(model.selectedSession == remote)
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .active)
    #expect(model.selectedSession == remote)
}

@MainActor
@Test func legacyClaimReturnsToListWithExplicitFullTrustFailure() async throws {
    let model = DeviceAppModel(permissionsGranted: { true })
    let remote = sessionCandidate(displayName: "Legacy Workspace")
    model.onClaimSession = { _ in false }

    model.presentSessionCandidates([remote])
    model.claimSession(remote)
    for _ in 0 ..< 100 where model.failureCode == nil {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.selectedSession == nil)
    #expect(model.failureCode == "full_trust_not_supported")
    #expect(model.failureMessage != nil)
}

@MainActor
@Test func switchingAnActiveSessionCleansUpBeforeShowingCandidates() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    try await claimAndWaitForActivation(model)
    let remote = BrokerSessionCandidate(
        toolSessionID: UUID(),
        toolType: "claude",
        toolAccountID: UUID(),
        workspaceID: UUID(),
        projectKey: "Workspace",
        displayName: "Workspace",
        status: .running,
        nodeID: UUID(),
        runtimeBackend: "native",
        currentDeviceID: nil,
        currentDeviceName: nil,
        deviceSessionID: nil,
        controllable: true
    )
    model.onEndSession = { events.append("end") }
    model.onRefreshSessionCandidates = {
        events.append("candidates")
        return [remote]
    }

    model.switchSession()
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.sessionCandidates == [remote])
    let values = events.values()
    #expect(values.firstIndex(of: "restore")! < values.firstIndex(of: "end")!)
    #expect(values.firstIndex(of: "end")! < values.firstIndex(of: "candidates")!)
}

@MainActor
@Test func staleClaimCompletionCannotReactivateTheSession() async throws {
    let events = EventRecorder()
    let claimGate = AsyncGate()
    let model = DeviceAppModel(
        permissionsGranted: { true },
        controlNotifier: { events.append("notify") }
    )
    let remote = sessionCandidate(displayName: "Workspace")
    model.onClaimSession = { _ in
        events.append("claim")
        await claimGate.wait()
        return true
    }
    model.onAbort = { _ in events.append("abort") }
    model.onRefreshSessionCandidates = { [] }

    model.presentSessionCandidates([remote])
    model.claimSession(remote)
    for _ in 0 ..< 100 where !events.values().contains("claim") {
        try await Task.sleep(for: .milliseconds(5))
    }
    model.returnToSessionSelection()
    await claimGate.release()
    for _ in 0 ..< 100 where !events.values().contains("abort") {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(events.values().contains("abort"))
    #expect(!events.values().contains("notify"))
}

@MainActor
@Test func remoteTurnLifecycleRestartsSafetyMonitoringWithoutHidingApplications() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    try await claimAndWaitForActivation(model)

    try model.handleRuntimeEvent(.turnStopped)
    #expect(model.state == .paused)
    #expect(model.lastUnsafeTransition == nil)
    try model.handleRuntimeEvent(.turnStarted)
    #expect(model.state == .active)
    try model.handleRuntimeEvent(.sessionEnded)

    #expect(model.state == .selectingSession)
    #expect(model.completionMessage == "The remote device-control session ended.")
    #expect(events.values().filter { $0 == "hide" }.isEmpty)
    #expect(events.values().filter { $0 == "restore" }.count == 2)
    #expect(events.values().filter { $0 == "monitor" }.count == 2)
    #expect(events.values().filter { $0 == "stop-monitor" }.count == 2)
}

@MainActor
@Test func stoppingAnActiveActionWaitsForBindingSynchronization() async throws {
    let events = EventRecorder()
    let abortGate = AsyncGate()
    let model = try await activatedModel(visibilityController: RecordingVisibilityController(
        events: events
    ))
    model.onAbort = { _ in
        events.append("abort")
        await abortGate.wait()
    }

    model.stopCurrentAction()
    for _ in 0 ..< 100 where !events.values().contains("abort") {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == .pausing)

    model.switchSession()
    #expect(model.state == .pausing)

    await abortGate.release()
    for _ in 0 ..< 100 where model.state != .paused {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == .paused)
    #expect(model.lastUnsafeTransition == .escape)

    try model.handleRuntimeEvent(.turnStarted)
    #expect(model.state == .active)
    #expect(model.lastUnsafeTransition == nil)
}

@MainActor
@Test func endingControlReturnsToSessionListWithoutTerminalScreen() async throws {
    let events = EventRecorder()
    let endGate = AsyncGate()
    let model = try await activatedModel(visibilityController: RecordingVisibilityController(
        events: events
    ))
    model.onEndSession = {
        events.append("end")
        await endGate.wait()
    }
    model.onRefreshSessionCandidates = { [] }

    model.endSession()
    #expect(model.state == .endingSession)
    await endGate.release()
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.completionMessage == "Device control ended.")
    #expect(events.values().contains("end"))
}

@MainActor
@Test func endingFailureProvidesSessionListRecovery() async throws {
    let model = try await activatedModel(visibilityController: RecordingVisibilityController(
        events: EventRecorder()
    ))
    model.onEndSession = { throw DeviceAppFailure.transportUnavailable }
    model.onRefreshSessionCandidates = { [] }

    model.endSession()
    for _ in 0 ..< 100 where model.state != .failed {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.failureRecovery == .sessionSelection)
    #expect(model.failureCode == "device_operation_failed")

    model.returnToSessionSelection()
    for _ in 0 ..< 100 where model.isRefreshingSessionCandidates {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == .selectingSession)
}

@MainActor
@Test func staleClaimBindingReturnsToSessionSelection() async throws {
    let model = DeviceAppModel(permissionsGranted: { true })
    let remote = sessionCandidate(displayName: "Stale")
    model.onClaimSession = { _ in throw StaleSessionBindingError() }

    model.presentSessionCandidates([remote])
    model.claimSession(remote)
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.selectedSession == nil)
    #expect(model.failureCode == "session_binding_changed")
    #expect(model.failureMessage != nil)
    #expect(model.failureRecovery == nil)
}

@MainActor
@Test func infrastructureFailureCanReconnectAndReturnToSessions() async throws {
    let model = DeviceAppModel(permissionsGranted: { true })
    model.onReconnect = { true }
    model.onRefreshSessionCandidates = { [] }

    model.failIfInfrastructureUnavailable(false)
    #expect(model.state == .failed)
    #expect(model.failureRecovery == .reconnect)
    #expect(model.failureCode == "xpc_services_unavailable")

    model.retryAfterFailure()
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == .selectingSession)
    #expect(model.failureMessage == nil)
}

@MainActor
@Test func staleCandidateRefreshCannotOverwriteNewerResults() async throws {
    let firstGate = AsyncGate()
    let calls = EventRecorder()
    let stale = sessionCandidate(displayName: "Stale")
    let current = sessionCandidate(displayName: "Current")
    let model = DeviceAppModel(permissionsGranted: { true })
    model.onRefreshSessionCandidates = {
        calls.append("refresh")
        if calls.values().count == 1 {
            await firstGate.wait()
            return [stale]
        }
        return [current]
    }

    model.refreshSessionCandidates()
    for _ in 0 ..< 100 where calls.values().isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    model.refreshSessionCandidates()
    for _ in 0 ..< 100 where model.sessionCandidates != [current] {
        try await Task.sleep(for: .milliseconds(5))
    }
    await firstGate.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(model.sessionCandidates == [current])
    #expect(model.state == .selectingSession)
}

@MainActor
@Test func sessionDiscoveryFailureRemainsRecoverableInSessionList() async throws {
    let model = DeviceAppModel(permissionsGranted: { true })
    model.onRefreshSessionCandidates = { throw DeviceAppFailure.transportUnavailable }

    model.refreshSessionCandidates()
    for _ in 0 ..< 100 where model.isRefreshingSessionCandidates {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.failureMessage != nil)
    #expect(model.failureCode == "device_operation_failed")
}

@MainActor
@Test func runtimeRestorationFailureLeavesAnExplicitFailedState() async throws {
    let turnEvents = EventRecorder()
    let turnModel = try await activatedModel(visibilityController: RecordingVisibilityController(
        events: turnEvents,
        restoreFailure: VisibilityTestFailure.restore
    ))

    #expect(throws: VisibilityTestFailure.restore) {
        try turnModel.handleRuntimeEvent(.turnStopped)
    }
    #expect(turnModel.state == .failed)
    #expect(turnModel.failureMessage != nil)

    let endEvents = EventRecorder()
    let endModel = try await activatedModel(visibilityController: RecordingVisibilityController(
        events: endEvents,
        restoreFailure: VisibilityTestFailure.restore
    ))

    #expect(throws: VisibilityTestFailure.restore) {
        try endModel.handleRuntimeEvent(.sessionEnded)
    }
    #expect(endModel.state == .failed)
    #expect(endModel.selectedSession == nil)
}

@MainActor
private func activatedModel(
    visibilityController: any WorkspaceVisibilityControlling
) async throws -> DeviceAppModel {
    let model = DeviceAppModel(
        visibilityController: visibilityController,
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: EventRecorder()) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    model.onClaimSession = { _ in true }
    try await claimAndWaitForActivation(model)
    return model
}

@MainActor
private func claimAndWaitForActivation(
    _ model: DeviceAppModel,
    candidate: BrokerSessionCandidate = sessionCandidate(displayName: "Workspace")
) async throws {
    model.presentSessionCandidates([candidate])
    model.claimSession(candidate)
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(model.state == .active)
}

private actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func append(_ event: String) {
        lock.withLock { events.append(event) }
    }

    func values() -> [String] {
        lock.withLock { events }
    }
}

@MainActor
private final class RecordingVisibilityController: WorkspaceVisibilityControlling {
    private let events: EventRecorder
    private let restoreFailure: Error?

    init(events: EventRecorder, restoreFailure: Error? = nil) {
        self.events = events
        self.restoreFailure = restoreFailure
    }

    func restoreApplications() throws {
        events.append("restore")
        if let restoreFailure { throw restoreFailure }
    }

    func restoreApplicationsFromPreviousRun() throws -> Int { 0 }
}

private enum VisibilityTestFailure: Error {
    case restore
}

private struct StaleSessionBindingError: DeviceAppErrorCodeProviding {
    let deviceErrorCode = "session_binding_changed"
}

@MainActor
private final class RecordingSafetyMonitor: SessionSafetyMonitoring {
    private let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func start() throws {
        events.append("monitor")
    }

    func stop() {
        events.append("stop-monitor")
    }
}

@MainActor
private final class FailingSafetyMonitor: SessionSafetyMonitoring {
    private let events: EventRecorder

    init(events: EventRecorder) {
        self.events = events
    }

    func start() throws {
        events.append("monitor")
        throw DeviceAppFailure.transportUnavailable
    }

    func stop() {
        events.append("stop-monitor")
    }
}

private func sessionCandidate(displayName: String) -> BrokerSessionCandidate {
    BrokerSessionCandidate(
        toolSessionID: UUID(),
        toolType: "claude",
        toolAccountID: UUID(),
        workspaceID: UUID(),
        projectKey: displayName,
        displayName: displayName,
        status: .running,
        nodeID: UUID(),
        runtimeBackend: "native",
        currentDeviceID: nil,
        currentDeviceName: nil,
        deviceSessionID: nil,
        controllable: true
    )
}
