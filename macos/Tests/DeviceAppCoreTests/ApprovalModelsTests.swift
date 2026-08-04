import DeviceAppCore
import DeviceIPC
import DeviceProtocol
import DeviceSecurity
import Foundation
import GUIExecutor
import Testing

@Test func approvalPresentationRejectsDuplicateApplications() throws {
    let candidate = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    #expect(throws: ApprovalModelFailure.duplicateApplication) {
        try ApprovalPresentation(
            generation: 1,
            applications: [candidate, candidate],
            hiddenApplicationCount: 0
        )
    }
}

@Test func approvalPresentationRejectsNonactiveGenerations() throws {
    let application = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    for generation in [UInt64(0), maximumDeviceSessionGeneration, UInt64.max] {
        #expect(throws: ApprovalModelFailure.invalidGeneration) {
            try ApprovalPresentation(
                generation: generation,
                applications: [application],
                hiddenApplicationCount: 0
            )
        }
    }
    #expect(throws: Never.self) {
        try ApprovalPresentation(
            generation: maximumActiveDeviceSessionGeneration,
            applications: [application],
            hiddenApplicationCount: 0
        )
    }
}

@Test func unknownApplicationUsesOnlyTheCurrentRequestLevel() throws {
    let unknown = candidate(bundleIdentifier: "dev.example.Unknown", requested: .clickOnly)
    let presentation = try ApprovalPresentation(
        generation: 7,
        applications: [unknown],
        hiddenApplicationCount: -2
    )
    let approvals = presentation.approvals(
        applicationSelections: [unknown.id],
        clipboardSelections: [unknown.id],
        controlLevelSelections: [unknown.id: .clickOnly]
    )

    #expect(unknown.classification.source == .pendingConfirmation)
    #expect(unknown.classification.controlLevel == nil)
    #expect(approvals.first?.controlLevel == .clickOnly)
    #expect(approvals.first?.generation == 7)
    #expect(approvals.first?.clipboardAllowed == true)
    #expect(presentation.hiddenApplicationCount == 0)
}

@Test func clipboardIsDeniedUnlessRequestedAndSelected() throws {
    let browser = candidate(
        bundleIdentifier: "com.apple.Safari",
        requested: .fullControl,
        clipboardRequested: false
    )
    let presentation = try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 3
    )
    let approval = try #require(
        presentation.approvals(
            applicationSelections: [browser.id],
            clipboardSelections: [browser.id],
            controlLevelSelections: [:]
        ).first
    )

    #expect(approval.controlLevel == .viewOnly)
    #expect(approval.clipboardAllowed == false)
}

@Test func applicationsRequireExplicitPerSessionSelection() throws {
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    let presentation = try ApprovalPresentation(
        generation: 7,
        applications: [browser],
        hiddenApplicationCount: 0
    )

    #expect(presentation.approvals(
        applicationSelections: [],
        clipboardSelections: [browser.id],
        controlLevelSelections: [:]
    ).isEmpty)
}

@Test func hiddenApplicationCountCanOnlyBeUpdatedLocallyWithoutChangingApproval() throws {
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    let presentation = try ApprovalPresentation(
        generation: 4,
        applications: [browser],
        hiddenApplicationCount: 99
    ).updatingHiddenApplicationCount(2)

    #expect(presentation.generation == 4)
    #expect(presentation.applications == [browser])
    #expect(presentation.hiddenApplicationCount == 2)
}

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
@Test func localProtectionIsReadyBeforeBrokerApproval() async throws {
    let events = EventRecorder()
    let visibility = RecordingVisibilityController(events: events)
    let model = DeviceAppModel(
        visibilityController: visibility,
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in events.append("approve") }

    model.allowForSession()
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .active)
    #expect(events.values().prefix(3) == ["hide", "monitor", "approve"])
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
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in }
    model.onEndSession = { events.append("end") }
    model.allowForSession()
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }

    permissionsGranted = false
    model.enforceCurrentPermissions()
    for _ in 0 ..< 100 where model.state != .permissionRequired {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .permissionRequired)
    #expect(events.values().contains("restore"))
    #expect(events.values().contains("end"))
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
    model.onClaimSession = { _ in claimed = true }

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
@Test func switchingAnActiveSessionCleansUpBeforeShowingCandidates() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in }
    model.allowForSession()
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }
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
@Test func switchingAPendingApprovalEndsBindingBeforeShowingCandidates() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        permissionsGranted: { true }
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
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
    #expect(model.approvalPresentation == nil)
    #expect(model.sessionCandidates == [remote])
    let values = events.values()
    #expect(values.firstIndex(of: "restore")! < values.firstIndex(of: "end")!)
    #expect(values.firstIndex(of: "end")! < values.firstIndex(of: "candidates")!)
}

@MainActor
@Test func switchingDuringActivationCannotBeOverwrittenByLateApproval() async throws {
    let events = EventRecorder()
    let approvalGate = ApprovalGate()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: { events.append("notify") }
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in
        events.append("approve")
        await approvalGate.wait()
    }
    model.onEndSession = { events.append("end") }
    model.onRefreshSessionCandidates = {
        events.append("candidates")
        return []
    }

    model.allowForSession()
    for _ in 0 ..< 100 where !events.values().contains("approve") {
        try await Task.sleep(for: .milliseconds(5))
    }
    model.switchSession()
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }
    await approvalGate.release()
    try await Task.sleep(for: .milliseconds(20))

    #expect(model.state == .selectingSession)
    #expect(events.values().contains("end"))
    #expect(!events.values().contains("notify"))
}

@MainActor
@Test func stopDuringBrokerApprovalCannotReactivateTheSession() async throws {
    let events = EventRecorder()
    let approvalGate = ApprovalGate()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: { events.append("notify") }
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in
        events.append("approve")
        await approvalGate.wait()
    }
    model.onAbort = { reason in
        #expect(reason == .screenLocked)
        events.append("abort")
    }

    model.allowForSession()
    for _ in 0 ..< 100 where !events.values().contains("approve") {
        try await Task.sleep(for: .milliseconds(5))
    }
    model.stopCurrentAction(reason: .screenLocked)
    await approvalGate.release()
    for _ in 0 ..< 100 where !events.values().contains("abort") {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .paused)
    #expect(model.lastUnsafeTransition == .screenLocked)
    #expect(events.values().contains("restore"))
    #expect(events.values().contains("abort"))
    #expect(!events.values().contains("notify"))
}

@MainActor
@Test func remoteTurnLifecycleRestoresAndReprotectsApplications() async throws {
    let events = EventRecorder()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: {}
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in }
    model.allowForSession()
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }

    try model.handleRuntimeEvent(.turnStopped)
    #expect(model.state == .paused)
    #expect(model.lastUnsafeTransition == nil)
    try model.handleRuntimeEvent(.turnStarted)
    #expect(model.state == .active)
    try model.handleRuntimeEvent(.sessionEnded)

    #expect(model.state == .selectingSession)
    #expect(model.completionMessage == "The remote device-control session ended.")
    #expect(events.values().filter { $0 == "hide" }.count == 2)
    #expect(events.values().filter { $0 == "restore" }.count == 2)
    #expect(events.values().filter { $0 == "monitor" }.count == 2)
    #expect(events.values().filter { $0 == "stop-monitor" }.count == 2)
}

@MainActor
@Test func remoteSessionEndDuringActivationCannotBeOverwritten() async throws {
    let events = EventRecorder()
    let approvalGate = ApprovalGate()
    let model = DeviceAppModel(
        visibilityController: RecordingVisibilityController(events: events),
        safetyMonitorFactory: { _ in RecordingSafetyMonitor(events: events) },
        permissionsGranted: { true },
        controlNotifier: { events.append("notify") }
    )
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in
        events.append("approve")
        await approvalGate.wait()
    }

    model.allowForSession()
    for _ in 0 ..< 100 where !events.values().contains("approve") {
        try await Task.sleep(for: .milliseconds(5))
    }
    try model.handleRuntimeEvent(.sessionEnded)
    await approvalGate.release()
    try await Task.sleep(for: .milliseconds(10))

    #expect(model.state == .selectingSession)
    #expect(model.approvalPresentation == nil)
    #expect(events.values().contains("restore"))
    #expect(!events.values().contains("notify"))
}

@MainActor
@Test func stoppingAnActiveActionWaitsForBindingSynchronization() async throws {
    let events = EventRecorder()
    let abortGate = ApprovalGate()
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
}

@MainActor
@Test func endingControlReturnsToSessionListWithoutTerminalScreen() async throws {
    let events = EventRecorder()
    let endGate = ApprovalGate()
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
@Test func denyingApprovalReturnsToSessionList() async throws {
    let model = DeviceAppModel(permissionsGranted: { true })
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.onDeny = { _ in }
    model.onRefreshSessionCandidates = { [] }

    model.deny()
    for _ in 0 ..< 100 where model.state != .selectingSession {
        try await Task.sleep(for: .milliseconds(5))
    }

    #expect(model.state == .selectingSession)
    #expect(model.completionMessage == "The device-control request was denied.")
}

@MainActor
@Test func staleCandidateRefreshCannotOverwriteNewerResults() async throws {
    let firstGate = ApprovalGate()
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
    #expect(endModel.approvalPresentation == nil)
    #expect(endModel.applicationSelections.isEmpty)
    #expect(endModel.clipboardSelections.isEmpty)
    #expect(endModel.controlLevelSelections.isEmpty)
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
    let browser = candidate(bundleIdentifier: "com.apple.Safari", requested: .viewOnly)
    model.presentApproval(try ApprovalPresentation(
        generation: 1,
        applications: [browser],
        hiddenApplicationCount: 0
    ))
    model.applicationSelections = [browser.id]
    model.onApprove = { _ in }
    model.allowForSession()
    for _ in 0 ..< 100 where model.state != .active {
        try await Task.sleep(for: .milliseconds(5))
    }
    return model
}

private actor ApprovalGate {
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

    func unapprovedApplicationCount(approvedBundleIdentifiers _: Set<String>) -> Int { 0 }

    func hideUnapprovedApplications(approvedBundleIdentifiers _: Set<String>) throws -> Int {
        events.append("hide")
        return 0
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

private func candidate(
    bundleIdentifier: String,
    requested: ControlLevel,
    clipboardRequested: Bool = true
) -> ApprovalCandidate {
    ApprovalCandidate(
        application: ApplicationIdentity(
            bundleIdentifier: bundleIdentifier,
            signingIdentifier: bundleIdentifier
        ),
        displayName: bundleIdentifier,
        requestedControlLevel: requested,
        classification: ApplicationPolicy.classify(bundleIdentifier: bundleIdentifier),
        clipboardRequested: clipboardRequested
    )
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
