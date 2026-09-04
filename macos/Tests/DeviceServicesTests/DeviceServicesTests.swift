import DeviceIPC
import DeviceProtocol
import DeviceSecurity
@testable import DeviceServices
import Foundation
import GUIExecutor
import Testing

@Test func executorReplaysTheLastCompletedRequestWithoutExecutingItTwice() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let update = try envelope(payload: JSONEncoder().encode(session)).encoded()
    try await controller.updateSession(update)
    let request = try actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    )

    let first = try await controller.performAction(request)
    let replay = try await controller.performAction(request)

    #expect(replay == first)
    #expect(await recorder.captureCount == 1)
    #expect(await recorder.lifecycleEvents == ["restore_focus"])

    try await controller.updateSession(update)
    _ = try await controller.performAction(request)
    #expect(await recorder.captureCount == 2)
}

@Test func executorNegotiatesV2StateAndScreenshotGenerationsIndependently() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let firstData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .screenshot),
        action: .observe(application: nil)
    ))
    let first = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)
    #expect(first.status == .success)
    #expect(first.stateGeneration == 1)
    #expect(first.screenshotGeneration == 1)
    #expect(first.stateID != nil)
    #expect(first.observation == nil)
    #expect(first.image?.profile == .compact)
    #expect(await recorder.captureCount == 1)

    let staleData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 0,
        screenshotGeneration: 1,
        observation: ObservationPolicy(mode: .none, settle: .none, settleTimeoutMilliseconds: 0, imageProfile: .none),
        action: .observe(application: nil)
    ))
    let stale = try JSONDecoder().decode(ActionResponseV2.self, from: staleData)
    #expect(stale.status == .failed)
    #expect(stale.message.hasPrefix("stale_state:"))
    #expect(await controller.currentState() == .active)
}

@Test func repeatedNamedAccessibilityObservationsFollowTheFrontmostWindow() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextWindowIDs: [7, 8]
        )
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let firstData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: "com.apple.Safari")
    ))
    let first = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)
    let secondData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        baseStateID: first.stateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .observe(application: "com.apple.Safari")
    ))
    let second = try JSONDecoder().decode(ActionResponseV2.self, from: secondData)

    #expect(first.status == .success)
    #expect(first.windowID == 7)
    #expect(second.status == .success)
    #expect(second.windowID == 8)
    #expect(second.baseStateID == nil)
    #expect(await recorder.windowContextPreferredWindowIDs == [[], []])
    #expect(await recorder.observationBaseStateIDs == [nil, nil])
}

@Test func repeatedNamedScreenshotsFollowTheFrontmostWindow() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let firstData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .screenshot),
        action: .observe(application: "com.apple.Safari")
    ))
    let first = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)
    let screenshotData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 1,
        observation: ObservationPolicy(mode: .screenshot),
        action: .observe(application: "com.apple.Safari")
    ))
    let screenshot = try JSONDecoder().decode(ActionResponseV2.self, from: screenshotData)

    #expect(first.status == .success)
    #expect(first.screenshotGeneration == 1)
    #expect(screenshot.status == .success)
    #expect(screenshot.screenshotGeneration == 2)
    #expect(screenshot.windowID == 7)
    #expect(await recorder.preferredWindowIDs == [[], []])
}

@Test func legacyScreenshotsReuseTheLatestBoundWindow() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .screenshot
    ))

    #expect(await recorder.preferredWindowIDs == [[], [7]])
}

@Test func legacyWindowManagementKeysDoNotRetainThePreviousWindowBinding() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    let newWindowData = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .key("CMD+N")
    ))
    let nextWindowData = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        screenshotGeneration: 2,
        action: .key("CMD+`")
    ))
    let newWindow = try JSONDecoder().decode(ExecutorActionResponse.self, from: newWindowData)
    let nextWindow = try JSONDecoder().decode(ExecutorActionResponse.self, from: nextWindowData)

    #expect(newWindow.status == .success)
    #expect(nextWindow.status == .success)
    #expect(await recorder.actions == [.key("CMD+N"), .key("CMD+`")])
    #expect(await recorder.preferredWindowIDs == [[], [], []])
}

@Test func repeatedAccessibilityObservationsResolveTheFrontmostWindow() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: "com.apple.Safari")
    ))
    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: "com.apple.Safari")
    ))

    #expect(await recorder.windowContextPreferredWindowIDs == [[], []])
}

@Test func executorRunsStateBoundV2ElementActionAndRejectsItsReuse() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .clickOnly,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let target = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(target)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)
    #expect(action.status == .success)
    #expect(action.stateGeneration == 2)
    #expect(await recorder.elementActions == [.press(target)])
    #expect(await recorder.settlePhases == ["prepare", "execute"])
    #expect(await recorder.accessibilityClearCount == 0)
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7]])

    let staleData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: 2,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(target)
    ))
    let stale = try JSONDecoder().decode(ActionResponseV2.self, from: staleData)
    #expect(stale.status == .failed)
    #expect(stale.message.hasPrefix("fresh_observation_required:"))
    #expect(await recorder.elementActions == [.press(target)])
}

@Test func executorRunsKeyboardContextActionWithoutScreenshotButRejectsCoordinates() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let keyboardData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.key("CMD+A"))
    ))
    let keyboard = try JSONDecoder().decode(ActionResponseV2.self, from: keyboardData)
    #expect(keyboard.status == .success)
    #expect(await recorder.actions == [.key("CMD+A")])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7]])

    let clickData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: 2,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.leftClick(Point(x: 10, y: 10)))
    ))
    let click = try JSONDecoder().decode(ActionResponseV2.self, from: clickData)
    #expect(click.status == .failed)
    #expect(click.message.hasPrefix("fresh_screenshot_required:"))
    #expect(await recorder.actions == [.key("CMD+A")])
}

@Test func executorRejectsCoordinatesFromAScreenshotInvalidatedByScrolling() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let screenshotData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .screenshot, imageProfile: .standard),
        action: .observe(application: nil)
    ))
    let screenshot = try JSONDecoder().decode(ActionResponseV2.self, from: screenshotData)
    #expect(screenshot.status == .success)
    #expect(screenshot.screenshotGeneration == 1)

    let scrollData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 1,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.scroll(deltaX: 0, deltaY: -100, coordinate: nil))
    ))
    let scroll = try JSONDecoder().decode(ActionResponseV2.self, from: scrollData)
    #expect(scroll.status == .success)
    #expect(scroll.screenshotGeneration == 1)

    let staleCoordinateData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: 2,
        screenshotGeneration: 1,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.mouseMove(Point(x: 10, y: 10)))
    ))
    let staleCoordinate = try JSONDecoder().decode(
        ActionResponseV2.self,
        from: staleCoordinateData
    )
    #expect(staleCoordinate.status == .failed)
    #expect(staleCoordinate.message.hasPrefix("fresh_screenshot_required:"))
    #expect(await recorder.actions == [.scroll(deltaX: 0, deltaY: -100, coordinate: nil)])

    let refreshedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: 2,
        screenshotGeneration: 1,
        observation: ObservationPolicy(mode: .screenshot, imageProfile: .standard),
        action: .observe(application: nil)
    ))
    let refreshed = try JSONDecoder().decode(ActionResponseV2.self, from: refreshedData)
    #expect(refreshed.status == .success)
    #expect(refreshed.stateGeneration == 3)
    #expect(refreshed.screenshotGeneration == 2)

    let freshCoordinateData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 4,
        stateGeneration: 3,
        screenshotGeneration: 2,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.mouseMove(Point(x: 10, y: 10)))
    ))
    let freshCoordinate = try JSONDecoder().decode(
        ActionResponseV2.self,
        from: freshCoordinateData
    )
    #expect(freshCoordinate.status == .success)
    #expect(await recorder.actions == [
        .scroll(deltaX: 0, deltaY: -100, coordinate: nil),
        .mouseMove(Point(x: 10, y: 10)),
    ])
}

@Test func passiveWaitRetainsTheCurrentWindowBinding() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let waitData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.wait(50))
    ))
    let response = try JSONDecoder().decode(ActionResponseV2.self, from: waitData)

    #expect(response.status == .success)
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7]])
}

@Test func interactiveActionRetriesAndRebindsToANewFrontmostWindow() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextWindowIDs: [7, 7, 8]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        baseStateID: observed.stateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .coordinate(.key("CMD+`"))
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.windowID == 8)
    #expect(action.baseStateID == nil)
    #expect(await recorder.actions == [.key("CMD+`")])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [], []])
    #expect(await recorder.accessibilityClearCount == 1)
    #expect(await recorder.observationBaseStateIDs == [nil, nil])
    #expect(await recorder.windowRefreshPhases == [
        "window_context", "execute", "window_context", "window_context", "settle",
    ])
}

@Test func elementWindowReplacementRetriesWithoutTheStaleWindowBinding() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextFailures: [nil, .approvedWindowMissing],
            windowContextWindowIDs: [7, 8]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let target = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: observed.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(target)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.windowID == 8)
    #expect(action.baseStateID == nil)
    #expect(await recorder.elementActions == [.press(target)])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7], []])
    #expect(await recorder.accessibilityClearCount == 1)
}

@Test func elementWindowReplacementStillFailsClosedWithoutAnApprovedReplacement() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextFailures: [nil, .approvedWindowMissing, .approvedWindowMissing]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let target = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )

    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: observed.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(target)
    ))
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("window_refresh_failed:"))
    #expect(await recorder.elementActions == [.press(target)])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7], []])
    #expect(await controller.currentState() == .failed)
    #expect(!(await controller.hasActiveSession()))
}

@Test func interactiveWindowRefreshTimesOutAStalledContextLookup() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextDelays: [0, 10_000]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))

    let started = ContinuousClock.now
    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .axDiff,
            settleTimeoutMilliseconds: 100
        ),
        action: .coordinate(.key("CMD+`"))
    ))
    let elapsed = ContinuousClock.now - started
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("window_refresh_failed:"))
    #expect(elapsed < .seconds(1))
    #expect(await controller.currentState() == .failed)
    #expect(!(await controller.hasActiveSession()))
    #expect(await recorder.actions == [.key("CMD+`")])
}

@Test func interactiveWindowRefreshUsesTheSettleDeadlineWithoutRestartingIt() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleDelayMilliseconds: 30,
            windowContextWindowIDs: [7, 7]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .axDiff,
            settleTimeoutMilliseconds: 1
        ),
        action: .coordinate(.key("CMD+`"))
    ))
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("window_refresh_failed:"))
    #expect(await recorder.actions == [.key("CMD+`")])
    #expect(await recorder.windowContextPreferredWindowIDs == [[]])
    #expect(await recorder.windowRefreshPhases == [
        "window_context", "execute",
    ])
    #expect(await controller.currentState() == .failed)
    #expect(!(await controller.hasActiveSession()))
}

@Test func interactiveWindowRefreshFailureFailsClosedAfterTheActionWasAccepted() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextFailures: [nil, .approvedWindowMissing]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.key("CMD+`"))
    ))
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("window_refresh_failed:"))
    #expect(await controller.currentState() == .failed)
    #expect(!(await controller.hasActiveSession()))
    #expect(await recorder.actions == [.key("CMD+`")])
}

@Test func noSettleWindowRefreshHonorsTheRequestLease() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextDelays: [0, 2_000]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))

    let shortLease = Date(
        timeIntervalSince1970: ceil(Date().timeIntervalSince1970) + 2
    )
    let started = ContinuousClock.now
    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        leaseUntil: shortLease,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.key("CMD+`"))
    ))
    let elapsed = ContinuousClock.now - started
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("window_refresh_failed:"))
    #expect(elapsed < .seconds(5))
    #expect(await controller.currentState() == .failed)
}

@Test func executorReturnsV2ActivationFailureWithoutDroppingTheSession() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            contextActionFailure: .applicationActivationTimedOut
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let failureData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.key("CMD+L"))
    ))
    let failure = try JSONDecoder().decode(ActionResponseV2.self, from: failureData)

    #expect(failure.status == .failed)
    #expect(failure.message.hasPrefix("approved_application_activation_timed_out:"))
    #expect(await controller.currentState() == .active)
}

@Test func typedActionWaitsForFreshAccessibilityText() async throws {
    let recorder = RuntimeRecorder()
    let typedText = "fresh typed text"
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            observationValues: [nil, nil, typedText]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let typedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .coordinate(.type(typedText))
    ))
    let typed = try JSONDecoder().decode(ActionResponseV2.self, from: typedData)

    #expect(typed.status == .success)
    #expect(typed.observation?.nodes.contains { $0.value == typedText } == true)
    #expect(await recorder.actions == [.type(typedText)])
}

@Test func setValueWaitsForBoundAccessibilityValueBeforeReturningAX() async throws {
    let recorder = RuntimeRecorder()
    let expectedValue = "fresh bound value"
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            observationValues: [nil, expectedValue]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(30))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let target = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: observed.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .setValue(target: target, value: expectedValue)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)
    let calls = await recorder.valueFreshnessCalls

    #expect(action.status == .success)
    #expect(action.observation?.nodes.contains { $0.value == expectedValue } == true)
    #expect(calls.count == 1)
    let freshnessCall = try #require(calls.first)
    #expect(freshnessCall.target == target)
    #expect(freshnessCall.expectedValue == expectedValue)
    #expect(freshnessCall.deadline <= session.leaseUntil)
    #expect(freshnessCall.deadline.timeIntervalSince(freshnessCall.recordedAt) <= 2)

    let latestTarget = ElementTarget(
        stateID: try #require(action.stateID),
        stateGeneration: action.stateGeneration,
        applicationDigest: try #require(action.applicationDigest),
        windowID: try #require(action.windowID),
        displayFingerprint: try #require(action.displayFingerprint),
        elementIndex: 0
    )
    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: action.stateGeneration,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(latestTarget)
    ))
    #expect(await recorder.valueFreshnessCalls.count == 1)
}

@Test func setValueFreshnessTimeoutReturnsBoundedStateWithDiagnostic() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            observationValues: [nil, nil],
            valueFreshnessConfirmed: false
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(30))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let target = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: observed.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .setValue(target: target, value: "not yet visible")
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.stateID != nil)
    #expect(action.message.contains("Expected accessibility value was not visible"))
    #expect(await recorder.valueFreshnessCalls.count == 1)
}

@Test func v2ActionFollowUpStateStaysBoundToTheObservedApplication() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            observationValues: [nil, "bound text"]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let chrome = ApplicationIdentity(
        bundleIdentifier: "com.google.Chrome",
        signingIdentifier: "com.google.Chrome"
    )
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [
            LocalApproval(
                application: base.approvals[0].application,
                controlLevel: .fullControl,
                clipboardAllowed: false,
                generation: base.binding.generation
            ),
            LocalApproval(
                application: chrome,
                controlLevel: .fullControl,
                clipboardAllowed: false,
                generation: base.binding.generation
            ),
        ]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: "com.apple.Safari")
    ))
    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .coordinate(.type("bound text"))
    ))

    #expect(await recorder.captureTargets == [
        "com.apple.Safari",
        "com.apple.Safari",
    ])
}

@Test func v2ElementStatesRemainUsableAcrossApprovedApplications() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let chrome = ApplicationIdentity(
        bundleIdentifier: "com.google.Chrome",
        signingIdentifier: "com.google.Chrome"
    )
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [
            LocalApproval(
                application: base.approvals[0].application,
                controlLevel: .clickOnly,
                clipboardAllowed: false,
                generation: base.binding.generation
            ),
            LocalApproval(
                application: chrome,
                controlLevel: .clickOnly,
                clipboardAllowed: false,
                generation: base.binding.generation
            ),
        ]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let firstData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: base.approvals[0].application.bundleIdentifier)
    ))
    let first = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)
    let firstTarget = ElementTarget(
        stateID: try #require(first.stateID),
        stateGeneration: first.stateGeneration,
        applicationDigest: try #require(first.applicationDigest),
        windowID: try #require(first.windowID),
        displayFingerprint: try #require(first.displayFingerprint),
        elementIndex: 0
    )

    _ = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: chrome.bundleIdentifier)
    ))

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: 2,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(firstTarget)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.stateGeneration == 3)
    #expect(await recorder.elementActions == [.press(firstTarget)])
    #expect(await recorder.accessibilityClearCount == 0)
}

@Test func accessibilityIdentityIgnoresWindowGeometryButRejectsBindingChanges() {
    let approvedApplication = ApplicationIdentity(
        bundleIdentifier: "com.google.Chrome",
        signingIdentifier: "com.google.Chrome"
    )
    let original = WindowContext(
        windowID: 7,
        windowFrame: CGRect(x: 0, y: 0, width: 1_800, height: 1_000),
        processID: 42,
        application: approvedApplication,
        displayFingerprint: "display-a"
    )
    func context(
        windowID: UInt32 = 7,
        frame: CGRect = CGRect(x: 0.25, y: 0, width: 1_799.75, height: 1_000),
        processID: Int32 = 42,
        application: ApplicationIdentity? = nil,
        displayFingerprint: String = "display-a"
    ) -> WindowContext {
        WindowContext(
            windowID: windowID,
            windowFrame: frame,
            processID: processID,
            application: application ?? approvedApplication,
            displayFingerprint: displayFingerprint
        )
    }

    #expect(GUIExecutorSessionController.sameAccessibilityIdentity(original, context()))
    #expect(!GUIExecutorSessionController.sameAccessibilityIdentity(
        original,
        context(windowID: 8)
    ))
    #expect(!GUIExecutorSessionController.sameAccessibilityIdentity(
        original,
        context(processID: 43)
    ))
    #expect(!GUIExecutorSessionController.sameAccessibilityIdentity(
        original,
        context(application: ApplicationIdentity(
            bundleIdentifier: "com.google.Chrome",
            signingIdentifier: "different-signer"
        ))
    ))
    #expect(!GUIExecutorSessionController.sameAccessibilityIdentity(
        original,
        context(displayFingerprint: "display-b")
    ))
}

@Test func windowGeometryJitterPreservesTheActionDiffBase() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            windowContextFrames: [
                CGRect(x: 0, y: 0, width: 1_800, height: 1_000),
                CGRect(x: 0.25, y: 0, width: 1_799.75, height: 1_000),
            ]
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let observedStateID = try #require(observed.stateID)
    let target = ElementTarget(
        stateID: observedStateID,
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(observed.applicationDigest),
        windowID: try #require(observed.windowID),
        displayFingerprint: try #require(observed.displayFingerprint),
        elementIndex: 0
    )
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: observedStateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .setValue(target: target, value: "computer accessibility")
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.observation?.kind == .diff)
    #expect(action.baseStateID == observedStateID)
    #expect(await recorder.observationBaseStateIDs == [nil, observedStateID])
    #expect(await recorder.accessibilityClearCount == 0)
}

@Test func adaptiveSettleUsesLongerGraceOnlyForNavigationCapableActions() {
    let target = ElementTarget(
        stateID: UUID(),
        stateGeneration: 1,
        applicationDigest: "app",
        windowID: 7,
        displayFingerprint: "display",
        elementIndex: 0
    )

    #expect(ActionSettleTiming.minimumStableMilliseconds(for: .press(target)) == 600)
    #expect(ActionSettleTiming.minimumStableMilliseconds(
        for: .coordinate(.key("Return"))
    ) == 600)
    #expect(ActionSettleTiming.minimumStableMilliseconds(
        for: .coordinate(.type("text"))
    ) == 300)
    #expect(ActionSettleTiming.minimumStableMilliseconds(
        for: .coordinate(.key("cmd+c"))
    ) == 200)
    #expect(ActionSettleTiming.minimumStableMilliseconds(
        for: .setValue(target: target, value: "text")
    ) == 300)
    for actionName in ["AXScrollToVisible", "AXShowMenu"] {
        let action = ActionV2.secondaryAction(target: target, actionName: actionName)
        #expect(ActionSettleTiming.minimumStableMilliseconds(for: action) == 300)
        #expect(ActionSettleTiming.requiredStableSamples(for: action) == 2)
        #expect(!ActionSettleTiming.requiresMeaningfulChange(for: action))
        #expect(ActionSettleTiming.noChangeGraceMilliseconds(for: action) == 0)
    }
    let unknownSecondaryAction = ActionV2.secondaryAction(
        target: target,
        actionName: "AXFutureNavigationAction"
    )
    #expect(ActionSettleTiming.minimumStableMilliseconds(for: unknownSecondaryAction) == 600)
    #expect(ActionSettleTiming.requiredStableSamples(for: unknownSecondaryAction) == 6)
    #expect(ActionSettleTiming.requiresMeaningfulChange(for: unknownSecondaryAction))
    #expect(ActionSettleTiming.noChangeGraceMilliseconds(for: unknownSecondaryAction) == 2_000)
    #expect(ActionSettleTiming.requiredStableSamples(for: .press(target)) == 6)
    #expect(ActionSettleTiming.requiredStableSamples(
        for: .setValue(target: target, value: "text")
    ) == 2)
    #expect(ActionSettleTiming.requiredStableSamples(
        for: .coordinate(.key("super+a"))
    ) == 1)
    #expect(ActionSettleTiming.requiresMeaningfulChange(for: .press(target)))
    #expect(ActionSettleTiming.requiresMeaningfulChange(
        for: .coordinate(.key("alt+Left"))
    ))
    for shortcut in ["cmd+Left", "cmd+Right", "super+Left", "super+Right", "cmd+[", "cmd+]"] {
        #expect(ActionSettleTiming.requiresMeaningfulChange(
            for: .coordinate(.key(shortcut))
        ))
        #expect(ActionSettleTiming.requiredStableSamples(
            for: .coordinate(.key(shortcut))
        ) == 6)
    }
    for shortcut in ["cmd+n", "cmd+shift+n", "shift+cmd+n", "cmd+`", "command+shift+`"] {
        let action = ActionV2.coordinate(.key(shortcut))
        #expect(action.mayChangeFrontmostWindow)
        #expect(ActionSettleTiming.requiresMeaningfulChange(for: action))
        #expect(ActionSettleTiming.requiredStableSamples(for: action) == 6)
    }
    #expect(ActionSettleTiming.noChangeGraceMilliseconds(for: .press(target)) == 2_000)
    #expect(ActionSettleTiming.noChangeGraceMilliseconds(
        for: .coordinate(.type("text"))
    ) == 0)
    #expect(ActionSettleTiming.minimumStableMilliseconds(
        for: .press(target),
        pressTargetsEditableText: true
    ) == 250)
    #expect(ActionSettleTiming.requiredStableSamples(
        for: .press(target),
        pressTargetsEditableText: true
    ) == 2)
    #expect(!ActionSettleTiming.requiresMeaningfulChange(
        for: .press(target),
        pressTargetsEditableText: true
    ))
    #expect(ActionSettleTiming.noChangeGraceMilliseconds(
        for: .press(target),
        pressTargetsEditableText: true
    ) == 0)
    #expect(!ActionSettleTiming.canReturn(
        stableSamples: 6,
        requiredStableSamples: 6,
        elapsedMilliseconds: 1_200,
        minimumStableMilliseconds: 600,
        observedMeaningfulChange: false,
        noChangeGraceMilliseconds: 2_000
    ))
    #expect(ActionSettleTiming.canReturn(
        stableSamples: 6,
        requiredStableSamples: 6,
        elapsedMilliseconds: 700,
        minimumStableMilliseconds: 600,
        observedMeaningfulChange: true,
        noChangeGraceMilliseconds: 2_000
    ))
    #expect(ActionSettleTiming.canReturn(
        stableSamples: 20,
        requiredStableSamples: 6,
        elapsedMilliseconds: 2_000,
        minimumStableMilliseconds: 600,
        observedMeaningfulChange: false,
        noChangeGraceMilliseconds: 2_000
    ))
}

@Test func navigationSettleRecoversWhenFinalDiffOmitsPageIdentity() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleObservedMeaningfulChange: true,
            currentSnapshotHasPageIdentity: false
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [LocalApproval(
            application: base.approvals[0].application,
            controlLevel: .clickOnly,
            clipboardAllowed: false,
            generation: base.binding.generation
        )]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: session.approvals[0].application.bundleIdentifier)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let initialStateID = try #require(initial.stateID)
    let target = ElementTarget(
        stateID: initialStateID,
        stateGeneration: initial.stateGeneration,
        applicationDigest: try #require(initial.applicationDigest),
        windowID: try #require(initial.windowID),
        displayFingerprint: try #require(initial.displayFingerprint),
        elementIndex: 0
    )

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        baseStateID: initialStateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .press(target)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.observation?.kind == .full)
    #expect(action.observation?.reset == true)
    #expect(action.baseStateID == nil)
    #expect(await recorder.observationBaseStateIDs == [nil, initialStateID, nil])
}

@Test func fullObservationResetMatchesWhetherItReplacesAModelVisibleBase() {
    let full = AccessibilityObservation(
        kind: .full,
        reset: false,
        truncated: false,
        nodes: [],
        removed: []
    )
    let first = GUIExecutorSessionController.observationRequiringResetWhenReplacingModelBase(
        full,
        modelBaseStateID: nil
    )
    let replacement = GUIExecutorSessionController.observationRequiringResetWhenReplacingModelBase(
        full,
        modelBaseStateID: UUID()
    )

    #expect(!first.reset)
    #expect(replacement.reset)
}

@Test func localElementChangesDoNotTriggerNavigationObservationRecovery() {
    let target = ElementTarget(
        stateID: UUID(),
        stateGeneration: 1,
        applicationDigest: String(repeating: "a", count: 64),
        windowID: 7,
        displayFingerprint: "display-a",
        elementIndex: 0
    )
    let settle = ActionSettleOutcome(
        result: SettleResult(status: .settled, elapsedMilliseconds: 10),
        observedMeaningfulChange: true
    )
    let diff = AccessibilityObservation(
        kind: .diff,
        reset: false,
        truncated: false,
        nodes: [],
        removed: []
    )

    for action in [
        ActionV2.setValue(target: target, value: "query"),
        .selectText(
            target: target,
            text: "query",
            prefix: nil,
            suffix: nil,
            selectionType: .text
        ),
        .scrollElement(target: target, direction: .down, pages: 1),
    ] {
        #expect(!GUIExecutorSessionController.needsNavigationObservationRecovery(
            settleOutcome: settle,
            observation: diff,
            baseHadPageIdentity: true,
            currentHasPageIdentity: true,
            action: action
        ))
    }
    #expect(!GUIExecutorSessionController.needsNavigationObservationRecovery(
        settleOutcome: ActionSettleOutcome(
            result: settle.result,
            observedMeaningfulChange: true,
            pressTargetWasEditableText: true
        ),
        observation: diff,
        baseHadPageIdentity: true,
        currentHasPageIdentity: true,
        action: .press(target)
    ))
    #expect(GUIExecutorSessionController.needsNavigationObservationRecovery(
        settleOutcome: settle,
        observation: diff,
        baseHadPageIdentity: true,
        currentHasPageIdentity: false,
        action: .press(target)
    ))
    #expect(!GUIExecutorSessionController.needsNavigationObservationRecovery(
        settleOutcome: settle,
        observation: diff,
        baseHadPageIdentity: true,
        currentHasPageIdentity: false,
        action: .coordinate(.key("cmd+c"))
    ))

    #expect(!GUIExecutorSessionController.needsNavigationObservationRecovery(
        settleOutcome: settle,
        observation: diff,
        baseHadPageIdentity: false,
        currentHasPageIdentity: false,
        action: .press(target)
    ))
}

@Test func localBrowserUiDismissalPreservesDiffWhenCurrentSnapshotStillHasPageIdentity() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleObservedMeaningfulChange: true,
            currentSnapshotHasPageIdentity: true
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [LocalApproval(
            application: base.approvals[0].application,
            controlLevel: .clickOnly,
            clipboardAllowed: false,
            generation: base.binding.generation
        )]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: session.approvals[0].application.bundleIdentifier)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let initialStateID = try #require(initial.stateID)
    let target = ElementTarget(
        stateID: initialStateID,
        stateGeneration: initial.stateGeneration,
        applicationDigest: try #require(initial.applicationDigest),
        windowID: try #require(initial.windowID),
        displayFingerprint: try #require(initial.displayFingerprint),
        elementIndex: 0
    )

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: initial.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: initialStateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .press(target)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.observation?.kind == .diff)
    #expect(action.observation?.reset == false)
    #expect(action.baseStateID == initialStateID)
    #expect(await recorder.observationBaseStateIDs == [nil, initialStateID])
}

@Test func editableTextPressPreservesItsDiffWithoutNavigationRecovery() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleObservedMeaningfulChange: true,
            settlePressTargetWasEditableText: true
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [LocalApproval(
            application: base.approvals[0].application,
            controlLevel: .clickOnly,
            clipboardAllowed: false,
            generation: base.binding.generation
        )]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: session.approvals[0].application.bundleIdentifier)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let initialStateID = try #require(initial.stateID)
    let target = ElementTarget(
        stateID: initialStateID,
        stateGeneration: initial.stateGeneration,
        applicationDigest: try #require(initial.applicationDigest),
        windowID: try #require(initial.windowID),
        displayFingerprint: try #require(initial.displayFingerprint),
        elementIndex: 0
    )

    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        baseStateID: initialStateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .press(target)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.observation?.kind == .diff)
    #expect(action.observation?.reset == false)
    #expect(action.baseStateID == initialStateID)
    #expect(await recorder.observationBaseStateIDs == [nil, initialStateID])
}

@Test func settleTimeoutReturnsOneFiniteSafeObservationWithoutRetry() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleStatus: .timeout,
            settleElapsedMilliseconds: 5_001
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let initialStateID = try #require(initial.stateID)
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        baseStateID: initialStateID,
        observation: ObservationPolicy(mode: .axDiff),
        action: .coordinate(.key("Tab"))
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.settle == SettleResult(status: .timeout, elapsedMilliseconds: 5_000))
    #expect(action.observation?.kind == .diff)
    #expect(action.image == nil)
    #expect(await recorder.observationBaseStateIDs == [nil, initialStateID])
    #expect(await recorder.actions == [.key("Tab")])
}

@Test func fixedSettleLeavesABoundedWindowRefreshBudget() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleDelayMilliseconds: 30
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: initial.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: initial.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .fixed,
            settleTimeoutMilliseconds: 1,
            imageProfile: .none
        ),
        action: .coordinate(.key("Tab"))
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.settle.status == .settled)
    #expect(await recorder.actions == [.key("Tab")])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7]])
}

@Test func automaticSettleLeavesABoundedSameWindowRefreshBudget() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(
            guardState: guardState,
            recorder: recorder,
            settleStatus: .timeout,
            settleElapsedMilliseconds: 30,
            settleDelayMilliseconds: 30
        )
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .fullControl,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let initialData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let initial = try JSONDecoder().decode(ActionResponseV2.self, from: initialData)
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: initial.stateGeneration,
        screenshotGeneration: 0,
        baseStateID: initial.stateID,
        observation: ObservationPolicy(
            mode: .axDiff,
            settle: .auto,
            settleTimeoutMilliseconds: 1,
            imageProfile: .none
        ),
        action: .coordinate(.key("Return"))
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)

    #expect(action.status == .success)
    #expect(action.settle == SettleResult(status: .timeout, elapsedMilliseconds: 1))
    #expect(await recorder.actions == [.key("Return")])
    #expect(await recorder.windowContextPreferredWindowIDs == [[], [7]])
    #expect(await controller.currentState() == .active)
}

@Test func executorSessionControllerActivatesStopsAndEndsOneBoundSession() async throws {
    let recorder = RuntimeRecorder()
    let automaticTerminationRecorder = AutomaticTerminationRecorder()
    let controller = GUIExecutorSessionController(
        runtimeFactory: { guardState in
            RuntimeStub(guardState: guardState, recorder: recorder)
        },
        automaticTerminationHandler: { disabled in
            automaticTerminationRecorder.record(disabled)
        }
    )
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let update = try envelope(payload: JSONEncoder().encode(session)).encoded()

    try await controller.updateSession(update)
    #expect(await controller.hasActiveSession())
    #expect(await controller.currentState() == .active)
    #expect(automaticTerminationRecorder.values == [true])

    try await controller.renewSession(update)
    #expect(automaticTerminationRecorder.values == [true])

    let stop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: session.binding, reason: .escape)
    )).encoded()
    try await controller.stopCurrentAction(stop)
    #expect(await controller.currentState() == .failed)
    #expect(automaticTerminationRecorder.values == [true, false])

    try await controller.updateSession(update)
    #expect(automaticTerminationRecorder.values == [true, false, true])

    let end = try envelope(payload: JSONEncoder().encode(
        BrokerEndRequest(binding: session.binding)
    )).encoded()
    try await controller.endSession(end)
    #expect(await controller.currentState() == nil)
    #expect(automaticTerminationRecorder.values == [true, false, true, false])
}

@Test func executorSessionControllerReleasesAutomaticTerminationOnDeinit() async throws {
    let recorder = RuntimeRecorder()
    let automaticTerminationRecorder = AutomaticTerminationRecorder()
    var controller: GUIExecutorSessionController? = GUIExecutorSessionController(
        runtimeFactory: { guardState in
            RuntimeStub(guardState: guardState, recorder: recorder)
        },
        automaticTerminationHandler: { disabled in
            automaticTerminationRecorder.record(disabled)
        }
    )
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller?.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    #expect(automaticTerminationRecorder.values == [true])

    controller = nil

    #expect(automaticTerminationRecorder.values == [true, false])
}

@Test func executorReturnsAConcreteCaptureFailureInsteadOfDroppingTheRelay() async throws {
    let controller = GUIExecutorSessionController { _ in
        RecoveringCaptureRuntime(failure: .screenRecordingPermissionMissing)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let requestID = UUID()

    let data = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: requestID,
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    let response = try JSONDecoder().decode(ExecutorActionResponse.self, from: data)

    #expect(response.requestID == requestID)
    #expect(response.status == .failed)
    #expect(response.screenshotGeneration == 0)
    #expect(response.image == nil)
    #expect(response.message == "screen_recording_permission_missing: Mac screen recording permission is missing for Agent Remote Device.")
    #expect(await controller.currentState() == .active)

    let retryData = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    let retry = try JSONDecoder().decode(ExecutorActionResponse.self, from: retryData)
    #expect(retry.status == .success)
    #expect(retry.screenshotGeneration == 1)
    #expect(await controller.currentState() == .active)
}

@Test func executorReturnsControlLevelDenialWithoutDroppingTheRelay() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let viewOnly = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .viewOnly,
                clipboardAllowed: $0.clipboardAllowed,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(viewOnly)).encoded()
    )
    _ = try await controller.performAction(actionEnvelope(
        configuration: viewOnly,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))

    let data = try await controller.performAction(actionEnvelope(
        configuration: viewOnly,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .leftClick(.init(x: 1, y: 1))
    ))
    let response = try JSONDecoder().decode(ExecutorActionResponse.self, from: data)

    #expect(response.status == .failed)
    #expect(response.message == "control_level_denied: This session was not approved for the requested control level.")
    #expect(await controller.currentState() == .active)
}

@Test func clipboardReadRequiresExplicitApprovalAndReturnsTextWithoutANewScreenshot() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let clipboardApproved = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .viewOnly,
                clipboardAllowed: true,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(clipboardApproved)).encoded()
    )
    _ = try await controller.performAction(actionEnvelope(
        configuration: clipboardApproved,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))

    let data = try await controller.performAction(actionEnvelope(
        configuration: clipboardApproved,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .readClipboard
    ))
    let response = try JSONDecoder().decode(ExecutorActionResponse.self, from: data)

    #expect(response.status == .success)
    #expect(response.message == "clipboard text")
    #expect(response.screenshotGeneration == 1)
    #expect(response.image == nil)
    #expect(await controller.currentState() == .active)
}

@Test func fullTrustClipboardReadDoesNotRequireAnApplicationObservation() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let responseData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .readClipboard
    ))
    let response = try JSONDecoder().decode(ActionResponseV2.self, from: responseData)

    #expect(response.status == .success)
    #expect(response.clipboard == "clipboard text")
    #expect(response.stateGeneration == 0)
    #expect(response.screenshotGeneration == 0)
    #expect(response.stateID == nil)
    #expect(response.applicationDigest == nil)
    #expect(await recorder.clipboardMaximumBytes == [maximumClipboardTextBytesV2])
}

@Test func fullTrustClipboardFailuresPreserveConcreteCodesWithoutEndingTheSession() async throws {
    let failures: [(ExecutionFailure, String)] = [
        (.clipboardEmpty, "clipboard_empty"),
        (.clipboardNonText, "clipboard_non_text"),
        (.clipboardUnavailable, "clipboard_unavailable"),
        (.clipboardTooLarge, "clipboard_too_large"),
    ]
    for (failure, code) in failures {
        let recorder = RuntimeRecorder()
        let controller = GUIExecutorSessionController { guardState in
            RuntimeStub(
                guardState: guardState,
                recorder: recorder,
                clipboardFailure: failure
            )
        }
        let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
        try await controller.updateSession(
            envelope(payload: JSONEncoder().encode(session)).encoded()
        )

        let responseData = try await controller.performAction(actionEnvelopeV2(
            configuration: session,
            requestID: UUID(),
            sequence: 1,
            stateGeneration: 0,
            screenshotGeneration: 0,
            observation: ObservationPolicy(
                mode: .none,
                settle: .none,
                settleTimeoutMilliseconds: 0,
                imageProfile: .none
            ),
            action: .readClipboard
        ))
        let response = try JSONDecoder().decode(ActionResponseV2.self, from: responseData)

        #expect(response.status == .failed)
        #expect(response.message.hasPrefix("\(code): "))
        #expect(response.clipboard == nil)
        #expect(await controller.currentState() == .active)
    }
}

@Test func fullTrustLaunchReturnsAFirstObservationAndExactReplayDoesNotRelaunch() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let request = try actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .launchApplication("com.apple.Safari")
    )

    let firstData = try await controller.performAction(request)
    let replayData = try await controller.performAction(request)
    let response = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)

    #expect(firstData == replayData)
    #expect(response.status == .success, Comment(rawValue: response.message))
    #expect(response.observation?.kind == .full)
    #expect(response.stateGeneration == 1)
    #expect(await recorder.launchedApplications == ["com.apple.Safari"])
}

@Test func uncertainFullTrustLaunchFailureEndsTheGenerationButPreflightFailureDoesNot() async throws {
    for (failure, expectedCode, expectedState) in [
        (
            CaptureFailure.applicationLaunchTimeout,
            "application_launch_timeout",
            DeviceSessionState.failed
        ),
        (
            CaptureFailure.applicationLaunchResultUnknown,
            "application_launch_result_unknown",
            DeviceSessionState.failed
        ),
        (
            CaptureFailure.applicationNotFound,
            "application_not_found",
            DeviceSessionState.active
        ),
    ] {
        let recorder = RuntimeRecorder()
        let controller = GUIExecutorSessionController { guardState in
            RuntimeStub(
                guardState: guardState,
                recorder: recorder,
                launchFailure: failure
            )
        }
        let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
        try await controller.updateSession(
            envelope(payload: JSONEncoder().encode(session)).encoded()
        )
        let request = try actionEnvelopeV2(
            configuration: session,
            requestID: UUID(),
            sequence: 1,
            stateGeneration: 0,
            screenshotGeneration: 0,
            observation: ObservationPolicy(mode: .axFull),
            action: .launchApplication("com.apple.Safari")
        )

        let firstData = try await controller.performAction(request)
        let replayData = try await controller.performAction(request)
        let response = try JSONDecoder().decode(ActionResponseV2.self, from: firstData)

        #expect(firstData == replayData)
        #expect(response.status == .failed)
        #expect(response.message.hasPrefix("\(expectedCode): "))
        #expect(await controller.currentState() == expectedState)
        #expect(await recorder.launchedApplications == ["com.apple.Safari"])
    }
}

@Test func launchedWindowFailureRestoresThePriorUserFocus() async {
    let recorder = RuntimeRecorder()

    await #expect(throws: CaptureFailure.displayMissing) {
        try await LiveGUIActionRuntime.waitForLaunchedWindow(
            deadline: Date().addingTimeInterval(1),
            context: { throw CaptureFailure.displayMissing },
            restore: { await recorder.restoredFocus() }
        )
    }

    #expect(await recorder.lifecycleEvents == ["restore_focus"])
}

@Test func v2ClipboardReadPreservesTheExistingAXSnapshotForTheNextElementAction() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .clickOnly,
                clipboardAllowed: true,
                generation: $0.generation
            )
        }
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)

    let clipboardData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .readClipboard
    ))
    let clipboard = try JSONDecoder().decode(ActionResponseV2.self, from: clipboardData)
    #expect(clipboard.status == .success)
    #expect(clipboard.message == "Clipboard read.")
    #expect(clipboard.clipboard == "clipboard text")
    #expect(clipboard.observation == nil)
    #expect(clipboard.image == nil)
    #expect(clipboard.stateID == observed.stateID)
    #expect(clipboard.stateGeneration == observed.stateGeneration)
    #expect(await recorder.clipboardMaximumBytes == [maximumClipboardTextBytesV2])

    let originalTarget = ElementTarget(
        stateID: try #require(observed.stateID),
        stateGeneration: observed.stateGeneration,
        applicationDigest: try #require(clipboard.applicationDigest),
        windowID: try #require(clipboard.windowID),
        displayFingerprint: try #require(clipboard.displayFingerprint),
        elementIndex: 0
    )
    let actionData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 3,
        stateGeneration: clipboard.stateGeneration,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .press(originalTarget)
    ))
    let action = try JSONDecoder().decode(ActionResponseV2.self, from: actionData)
    #expect(action.status == .success)
    #expect(await recorder.elementActions == [.press(originalTarget)])
}

@Test func v2ClipboardReadUsesTheBoundedMessageFallbackWithoutThePayloadCapability() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: base.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: .viewOnly,
                clipboardAllowed: true,
                generation: $0.generation
            )
        },
        capabilities: [
            capabilityObservationModeV2,
            capabilityAXStateV2,
            capabilityAdaptiveSettleV2,
        ]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let observedData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(mode: .axFull),
        action: .observe(application: nil)
    ))
    let observed = try JSONDecoder().decode(ActionResponseV2.self, from: observedData)
    let clipboardData = try await controller.performAction(actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: observed.stateGeneration,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .readClipboard
    ))
    let clipboard = try JSONDecoder().decode(ActionResponseV2.self, from: clipboardData)

    #expect(clipboard.status == .success)
    #expect(clipboard.message == "clipboard text")
    #expect(clipboard.clipboard == nil)
    #expect(await recorder.clipboardMaximumBytes == [4 * 1_024])
}

@Test func executorRejectsCrossGenerationStopAndEndMessages() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let staleBinding = DeviceSessionBinding(
        userID: session.binding.userID,
        deviceID: session.binding.deviceID,
        toolSessionID: session.binding.toolSessionID,
        deviceSessionID: session.binding.deviceSessionID,
        nodeID: session.binding.nodeID,
        platform: session.binding.platform,
        generation: session.binding.generation + 1
    )
    let staleStop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: staleBinding, reason: .disconnect)
    )).encoded()
    await #expect(throws: DeviceIPCFailure.invalidMessage) {
        try await controller.stopCurrentAction(staleStop)
    }
    let staleEnd = try envelope(payload: JSONEncoder().encode(
        BrokerEndRequest(binding: staleBinding)
    )).encoded()
    await #expect(throws: DeviceIPCFailure.invalidMessage) {
        try await controller.endSession(staleEnd)
    }

    #expect(await controller.hasActiveSession())
    #expect(await recorder.releaseCount == 0)
}

@Test func executorSessionControllerRejectsExpiredAndCrossGenerationApproval() async throws {
    let controller = GUIExecutorSessionController()
    let expired = configuration(leaseUntil: Date().addingTimeInterval(-1))
    let expiredData = try envelope(payload: JSONEncoder().encode(expired)).encoded()
    await #expect(throws: DeviceIPCFailure.invalidMessage) {
        try await controller.updateSession(expiredData)
    }

    let valid = configuration(leaseUntil: Date().addingTimeInterval(60))
    let mismatched = ExecutorSessionConfiguration(
        binding: valid.binding,
        leaseUntil: valid.leaseUntil,
        approvals: [
            LocalApproval(
                application: valid.approvals[0].application,
                controlLevel: .viewOnly,
                clipboardAllowed: false,
                generation: valid.binding.generation + 1
            ),
        ]
    )
    let mismatchedData = try envelope(payload: JSONEncoder().encode(mismatched)).encoded()
    await #expect(throws: DeviceIPCFailure.invalidMessage) {
        try await controller.updateSession(mismatchedData)
    }
}

@Test func executorLeaseRenewalPreservesSequenceAndScreenshotState() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let initial = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(initial)).encoded()
    )
    _ = try await controller.performAction(actionEnvelope(
        configuration: initial,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))

    let renewed = ExecutorSessionConfiguration(
        binding: initial.binding,
        leaseUntil: initial.leaseUntil.addingTimeInterval(60),
        approvals: initial.approvals
    )
    try await controller.renewSession(
        envelope(payload: JSONEncoder().encode(renewed)).encoded()
    )
    let response = try await controller.performAction(actionEnvelope(
        configuration: renewed,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .wait(50)
    ))
    let decoded = try JSONDecoder().decode(ExecutorActionResponse.self, from: response)
    #expect(decoded.monotonicSequence == 2)
    #expect(decoded.screenshotGeneration == 2)
    #expect(await recorder.actions == [.wait(50)])
}

@Test func executorPauseReleasesInputThenRestoresFocusAndRequiresANewScreenshot() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    let stopped = BrokerRuntimeEvent(binding: session.binding, kind: .turnStopped)
    try await controller.pauseTurn(
        envelope(payload: JSONEncoder().encode(stopped)).encoded()
    )

    #expect(await !controller.hasActiveSession())
    #expect(await controller.currentState() == .active)
    #expect(await recorder.releaseCount == 1)
    #expect(await recorder.lifecycleEvents.suffix(2) == ["release", "restore_focus"])

    let started = BrokerRuntimeEvent(binding: session.binding, kind: .turnStarted)
    try await controller.resumeTurn(
        envelope(payload: JSONEncoder().encode(started)).encoded()
    )
    let response = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .screenshot
    ))
    let decoded = try JSONDecoder().decode(ExecutorActionResponse.self, from: response)

    #expect(decoded.screenshotGeneration == 2)
    #expect(await controller.hasActiveSession())
}

@Test func executorPerformsBoundActionsAndRejectsStaleReplay() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    let screenshotID = UUID()
    let screenshotResponse = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: screenshotID,
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    ))
    let first = try JSONDecoder().decode(ExecutorActionResponse.self, from: screenshotResponse)
    #expect(first.requestID == screenshotID)
    #expect(first.monotonicSequence == 1)
    #expect(first.screenshotGeneration == 1)
    #expect(first.status == .success)
    #expect(first.image?.base64Data == Data("bounded png".utf8).base64EncodedString())
    #expect(first.image?.mimeType == "image/png")

    let waitID = UUID()
    let waitResponse = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: waitID,
        sequence: 2,
        screenshotGeneration: 1,
        action: .wait(50)
    ))
    let second = try JSONDecoder().decode(ExecutorActionResponse.self, from: waitResponse)
    #expect(second.requestID == waitID)
    #expect(second.monotonicSequence == 2)
    #expect(second.screenshotGeneration == 2)
    #expect(await recorder.actions == [.wait(50)])

    await #expect(throws: GuardFailure.staleScreenshot) {
        try await controller.performAction(actionEnvelope(
            configuration: session,
            requestID: UUID(),
            sequence: 3,
            screenshotGeneration: 1,
            action: .leftClick(.init(x: 1, y: 1))
        ))
    }
    #expect(await controller.currentState() == .failed)
    #expect(await recorder.releaseCount == 1)
}

@Test func legacyActionFollowUpScreenshotStaysBoundToTheCapturedApplication() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let base = configuration(leaseUntil: Date().addingTimeInterval(60))
    let chrome = ApplicationIdentity(
        bundleIdentifier: "com.google.Chrome",
        signingIdentifier: "com.google.Chrome"
    )
    let session = ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: base.leaseUntil,
        approvals: [
            base.approvals[0],
            LocalApproval(
                application: chrome,
                controlLevel: .fullControl,
                clipboardAllowed: false,
                generation: base.binding.generation
            ),
        ]
    )
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )

    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshotApplication("com.google.Chrome")
    ))
    _ = try await controller.performAction(actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .key("CMD+L")
    ))

    #expect(await recorder.captureTargets == [
        "com.google.Chrome",
        "com.google.Chrome",
    ])
}

@Test func executorRejectsEnvelopeAndSessionBindingMismatch() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    try await controller.updateSession(
        envelope(payload: JSONEncoder().encode(session)).encoded()
    )
    let requestID = UUID()
    let request = actionRequest(
        configuration: session,
        requestID: requestID,
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot,
        deviceID: UUID()
    )
    let mismatchedEnvelope = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONEncoder().encode(request)
    ).encoded()

    await #expect(throws: DeviceIPCFailure.invalidMessage) {
        try await controller.performAction(mismatchedEnvelope)
    }
    #expect(await controller.currentState() == .failed)
    #expect(await recorder.captureCount == 0)
}

@Test func nestedTLSIdentityAndMaterialAreGenerationScoped() throws {
    let first = try NestedTLSGenerationIdentity.generate()
    let second = try NestedTLSGenerationIdentity.generate()
    #expect(first.certificateDER != second.certificateDER)
    #expect(first.spkiSHA256 != second.spkiSHA256)
    #expect(first.spkiSHA256.count == 64)
    #expect(first.spkiSHA256.utf8.allSatisfy {
        (48 ... 57).contains($0) || (97 ... 102).contains($0)
    })

    let context = String(repeating: "cd", count: 32)
    let material = try NestedTLSGenerationMaterial(
        generation: 1,
        expectedPeerSPKISHA256Hex: first.spkiSHA256,
        exporterContextHex: context
    )
    #expect(material.expectedPeerSPKISHA256.count == 32)
    #expect(material.exporterContext.count == 32)
    #expect(throws: NestedTLSParametersFailure.invalidGeneration) {
        try NestedTLSGenerationMaterial(
            generation: 0,
            expectedPeerSPKISHA256Hex: first.spkiSHA256,
            exporterContextHex: context
        )
    }
    #expect(throws: NestedTLSParametersFailure.invalidGeneration) {
        try NestedTLSGenerationMaterial(
            generation: maximumDeviceSessionGeneration,
            expectedPeerSPKISHA256Hex: first.spkiSHA256,
            exporterContextHex: context
        )
    }
    #expect(throws: NestedTLSParametersFailure.invalidHexMaterial) {
        try NestedTLSGenerationMaterial(
            generation: 1,
            expectedPeerSPKISHA256Hex: first.spkiSHA256.uppercased(),
            exporterContextHex: context
        )
    }
}

@Test func nestedTLSPeerPinRejectsAnotherGenerationCertificate() throws {
    let expected = try NestedTLSGenerationIdentity.generate()
    let presented = try NestedTLSGenerationIdentity.generate()
    let material = try NestedTLSGenerationMaterial(
        generation: 1,
        expectedPeerSPKISHA256Hex: expected.spkiSHA256,
        exporterContextHex: String(repeating: "ab", count: 32)
    )
    let expectedPin = material.expectedPeerSPKISHA256
    let now = Date()

    #expect(NestedTLSParameters.peerCertificateMatches(
        certificateChainDER: [expected.certificateDER],
        expectedSPKISHA256: expectedPin,
        now: now
    ))
    #expect(!NestedTLSParameters.peerCertificateMatches(
        certificateChainDER: [presented.certificateDER],
        expectedSPKISHA256: expectedPin,
        now: now
    ))
    #expect(!NestedTLSParameters.peerCertificateMatches(
        certificateChainDER: [expected.certificateDER, presented.certificateDER],
        expectedSPKISHA256: expectedPin,
        now: now
    ))
}

@Test func exporterConfirmationMatchesCrossLanguageVector() throws {
    let exporter = Data((0 ..< 32).map(UInt8.init))
    let sessionID = try #require(UUID(uuidString: "00112233-4455-6677-8899-aabbccddeeff"))
    let record = try NestedTLSParameters.confirmationRecord(
        exporterBinding: exporter,
        role: .device,
        generation: 9,
        deviceSessionID: sessionID
    )

    #expect(record.prefix(2) == Data([1, NestedTLSRole.device.rawValue]))
    #expect(record.dropFirst(2).map { String(format: "%02x", $0) }.joined()
        == "0c53d315be38f07f3cccd675e64f41621d8fc50cba65ab1133562d508aff9c48")
    try NestedTLSParameters.verifyPeerConfirmation(
        record,
        exporterBinding: exporter,
        localRole: .proxy,
        generation: 9,
        deviceSessionID: sessionID
    )
}

@Test func exporterConfirmationRejectsWrongRoleGenerationSessionAndTag() throws {
    let exporter = Data(repeating: 7, count: 32)
    let sessionID = UUID()
    let record = try NestedTLSParameters.confirmationRecord(
        exporterBinding: exporter,
        role: .device,
        generation: 3,
        deviceSessionID: sessionID
    )

    #expect(throws: NestedTLSParametersFailure.exporterConfirmationFailed) {
        try NestedTLSParameters.verifyPeerConfirmation(
            record,
            exporterBinding: exporter,
            localRole: .device,
            generation: 3,
            deviceSessionID: sessionID
        )
    }
    #expect(throws: NestedTLSParametersFailure.exporterConfirmationFailed) {
        try NestedTLSParameters.verifyPeerConfirmation(
            record,
            exporterBinding: exporter,
            localRole: .proxy,
            generation: 4,
            deviceSessionID: sessionID
        )
    }
    var changed = record
    changed[2] ^= 1
    #expect(throws: NestedTLSParametersFailure.exporterConfirmationFailed) {
        try NestedTLSParameters.verifyPeerConfirmation(
            changed,
            exporterBinding: exporter,
            localRole: .proxy,
            generation: 3,
            deviceSessionID: UUID()
        )
    }
}

@Test func networkBrokerBuildsExecutorConfigurationOnlyFromValidatedApproval() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let lockRecorder = LockRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { decision in
            guard decision.binding == session.binding,
                  decision.approvals == session.approvals
            else {
                throw DeviceIPCFailure.invalidMessage
            }
            if decision.result == .denied { return nil }
            return session
        },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            let binding = DeviceSessionBinding(
                userID: request.binding.userID,
                deviceID: request.binding.deviceID,
                toolSessionID: request.binding.toolSessionID,
                deviceSessionID: request.binding.deviceSessionID,
                nodeID: request.binding.nodeID,
                platform: request.binding.platform,
                generation: request.binding.generation + 1
            )
            return BrokerPendingSession(
                binding: binding,
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        endProvider: { request in
            await lifecycleRecorder.recordEnd(request)
        },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { binding in
            await lockRecorder.record(binding)
        }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let requestID = UUID()
    let valid = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONEncoder().encode(decision)
    ).encoded() as NSData

    let opened = await withCheckedContinuation { continuation in
        broker.approveSession(valid) { data, error in
            continuation.resume(returning: (data.map { Data(referencing: $0) }, error?.code))
        }
    }
    let openedEnvelope = try DeviceIPCEnvelope.decode(try #require(opened.0))
    let openedConfiguration = try JSONDecoder().decode(
        ExecutorSessionConfiguration.self,
        from: openedEnvelope.payload
    )
    #expect(openedEnvelope.requestID == requestID)
    #expect(openedConfiguration == session)
    #expect(opened.1 == nil)
    #expect(executor.updated.map { Data(referencing: $0) } == opened.0)
    #expect(await lockRecorder.value() == session.binding)

    let denial = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .denied
    )
    let denialRequest = try envelope(payload: JSONEncoder().encode(denial)).encoded() as NSData
    let denied = await withCheckedContinuation { continuation in
        broker.approveSession(denialRequest) { data, error in
            continuation.resume(returning: (
                data.map { Data(referencing: $0) },
                error?.code
            ))
        }
    }
    #expect(denied.0 == nil)
    #expect(denied.1 == nil)
    #expect(executor.updateCount == 1)

    let abortRequest = BrokerAbortRequest(binding: session.binding, reason: .escape)
    let lifecycle = try envelope(payload: JSONEncoder().encode(abortRequest)).encoded() as NSData
    let stopError = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(lifecycle) { continuation.resume(returning: $0?.code) }
    }
    let endRequest = BrokerEndRequest(binding: session.binding)
    let endData = try envelope(payload: JSONEncoder().encode(endRequest)).encoded() as NSData
    let endError = await withCheckedContinuation { continuation in
        broker.endSession(endData) { continuation.resume(returning: $0?.code) }
    }
    #expect(stopError == nil)
    #expect(endError == nil)
    #expect(executor.stopped == lifecycle)
    #expect(executor.ended == endData)
    #expect(await lifecycleRecorder.abortRequest == abortRequest)
    #expect(await lifecycleRecorder.endRequest == endRequest)

    let invalid = NSData(data: Data("not an envelope".utf8))
    let invalidResult = await withCheckedContinuation { continuation in
        broker.approveSession(invalid) { data, error in
            continuation.resume(returning: (data.map { Data(referencing: $0) }, error?.code))
        }
    }
    #expect(invalidResult.0 == nil)
    #expect(invalidResult.1 == DeviceIPCFailure.invalidMessage.rawValue)
    #expect(executor.updateCount == 1)
}

@Test func initialRelayFailureRotatesGenerationOnceWithoutRepeatingUserApproval() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let attempts = RelayAttemptRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { configuration in
            let attempt = await attempts.record(configuration)
            if attempt == 1 {
                throw DeviceIPCFailure.serviceUnavailable
            }
            return HoldingRelay(cancellationRecorder: CancellationRecorder())
        },
        lockProvider: { _ in },
        rotationProvider: { previous in rotatedConfiguration(previous) }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let requestID = UUID()
    let request = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONEncoder().encode(decision)
    ).encoded() as NSData

    let result = await withCheckedContinuation { continuation in
        broker.approveSession(request) { data, error in
            continuation.resume(returning: (data.map { Data(referencing: $0) }, error?.code))
        }
    }

    let response = try DeviceIPCEnvelope.decode(try #require(result.0))
    let activated = try JSONDecoder().decode(
        ExecutorSessionConfiguration.self,
        from: response.payload
    )
    #expect(result.1 == nil)
    #expect(response.requestID == requestID)
    #expect(activated.binding.generation == session.binding.generation + 1)
    #expect(activated.approvals.allSatisfy { $0.generation == activated.binding.generation })
    #expect(await attempts.generations == [
        session.binding.generation,
        session.binding.generation + 1,
    ])
    #expect(executor.sessionUpdateCount() == 2)
    #expect(executor.stoppedRequest() != nil)
    #expect(approvalUI.recordedEvents().isEmpty)
}

@Test func fullTrustClaimActivatesExecutorAndRelayBeforeReplying() async throws {
    let executor = ExecutorStub()
    let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
    let relayConfigurations = ConfigurationRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        claimProvider: { request in
            #expect(request.toolSessionID == session.binding.toolSessionID)
            #expect(request.deviceCapabilities == [capabilitySessionFullTrustV1])
            return BrokerPendingSession(
                binding: session.binding,
                expiresAt: session.leaseUntil.addingTimeInterval(1),
                activationConfiguration: session
            )
        },
        relayProvider: { configuration in
            await relayConfigurations.record(configuration)
            return HoldingRelay(cancellationRecorder: CancellationRecorder())
        },
        lockProvider: { _ in }
    )
    let requestID = UUID()
    let request = try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONEncoder().encode(BrokerClaimRequest(
            toolSessionID: session.binding.toolSessionID
        ))
    ).encoded() as NSData

    let result = await withCheckedContinuation { continuation in
        broker.claimSession(request) { data, error in
            continuation.resume(returning: (data.map { Data(referencing: $0) }, error?.code))
        }
    }

    let response = try DeviceIPCEnvelope.decode(try #require(result.0))
    let pending = try JSONDecoder().decode(BrokerPendingSession.self, from: response.payload)
    #expect(result.1 == nil)
    #expect(pending.activationConfiguration == session)
    #expect(executor.sessionUpdateCount() == 1)
    #expect(await relayConfigurations.first == session)
}

@Test func failedFullTrustClaimActivationStopsExecutorAndAbortsControlPlane() async throws {
    let executor = ExecutorStub()
    let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        claimProvider: { _ in
            BrokerPendingSession(
                binding: session.binding,
                expiresAt: session.leaseUntil.addingTimeInterval(1),
                activationConfiguration: session
            )
        },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: request.binding,
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { _ in throw DeviceIPCFailure.serviceUnavailable },
        rotationProvider: { _ in throw DeviceIPCFailure.serviceUnavailable }
    )
    let request = try envelope(payload: JSONEncoder().encode(BrokerClaimRequest(
        toolSessionID: session.binding.toolSessionID
    ))).encoded() as NSData

    let result = await withCheckedContinuation { continuation in
        broker.claimSession(request) { data, error in
            continuation.resume(returning: (data == nil, error?.code))
        }
    }

    #expect(result.0)
    #expect(result.1 == DeviceIPCFailure.serviceUnavailable.rawValue)
    #expect(executor.stoppedRequest() != nil)
    #expect(await lifecycleRecorder.abortCount == 1)
    #expect(await lifecycleRecorder.abortRequest?.binding == session.binding)
}

@Test func fullTrustClaimRotationRejectsChangedAuthorizationScope() async throws {
    let executor = ExecutorStub()
    let session = fullTrustConfiguration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let relayAttempts = RelayAttemptRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        claimProvider: { _ in
            BrokerPendingSession(
                binding: session.binding,
                expiresAt: session.leaseUntil.addingTimeInterval(1),
                activationConfiguration: session
            )
        },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: request.binding,
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { configuration in
            _ = await relayAttempts.record(configuration)
            throw DeviceIPCFailure.serviceUnavailable
        },
        rotationProvider: { previous in
            let binding = DeviceSessionBinding(
                userID: previous.binding.userID,
                deviceID: previous.binding.deviceID,
                toolSessionID: previous.binding.toolSessionID,
                deviceSessionID: previous.binding.deviceSessionID,
                nodeID: previous.binding.nodeID,
                platform: previous.binding.platform,
                generation: previous.binding.generation + 1
            )
            var exclusions = try #require(previous.authorization).excludedBundleIdentifiers
            exclusions.insert("com.example.changed-scope")
            return ExecutorSessionConfiguration(
                binding: binding,
                leaseUntil: Date().addingTimeInterval(60),
                approvals: [],
                authorization: SessionAuthorization(
                    excludedBundleIdentifiers: exclusions,
                    generation: binding.generation
                ),
                capabilities: previous.capabilities
            )
        }
    )
    let request = try envelope(payload: JSONEncoder().encode(BrokerClaimRequest(
        toolSessionID: session.binding.toolSessionID
    ))).encoded() as NSData

    let error = await withCheckedContinuation { continuation in
        broker.claimSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(error == DeviceIPCFailure.invalidMessage.rawValue)
    #expect(await relayAttempts.generations == [session.binding.generation])
    #expect(executor.sessionUpdateCount() == 1)
    #expect(await lifecycleRecorder.abortCount == 1)
}

@Test func unavailableExecutorRejectsApprovalBeforeRelayOrRotation() async throws {
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let relayAttempts = RelayAttemptRecorder()
    let rotationAttempts = ConfigurationRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { configuration in
            _ = await relayAttempts.record(configuration)
            return HoldingRelay(cancellationRecorder: CancellationRecorder())
        },
        rotationProvider: { configuration in
            await rotationAttempts.record(configuration)
            return rotatedConfiguration(configuration)
        }
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData

    let error = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(error == DeviceIPCFailure.serviceUnavailable.rawValue)
    #expect(await relayAttempts.generations.isEmpty)
    #expect(await rotationAttempts.first == nil)
    #expect(await lifecycleRecorder.abortRequest?.binding == session.binding)
}

@Test func repeatedInitialRelayFailureStopsAfterOneGenerationRotation() async throws {
    let executor = ExecutorStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let attempts = RelayAttemptRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { configuration in
            _ = await attempts.record(configuration)
            throw DeviceIPCFailure.serviceUnavailable
        },
        rotationProvider: { previous in rotatedConfiguration(previous) }
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData

    let error = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    let rotatedGeneration = session.binding.generation + 1
    #expect(error == DeviceIPCFailure.serviceUnavailable.rawValue)
    #expect(await attempts.generations == [session.binding.generation, rotatedGeneration])
    #expect(await lifecycleRecorder.abortCount == 1)
    #expect(await lifecycleRecorder.abortRequest?.binding.generation == rotatedGeneration)
    #expect(executor.sessionUpdateCount() == 2)
}

@Test func networkBrokerForwardsV2ObserveWithoutAbortingRelay() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let observe = try actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(),
        action: .observe(application: "com.apple.Safari")
    )
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { _ in TriggerActionRelay(request: observe) },
        lockProvider: { _ in }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    for _ in 0 ..< 100 where executor.actioned == nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(executor.actioned == observe as NSData)
    #expect(await lifecycleRecorder.abortRequest == nil)

    let abortRequest = BrokerAbortRequest(binding: session.binding, reason: .escape)
    let stop = try envelope(payload: JSONEncoder().encode(abortRequest)).encoded() as NSData
    let stopError = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(stop) { continuation.resume(returning: $0?.code) }
    }
    #expect(stopError == nil)
}

@Test func networkBrokerLeavesV2ApplicationActivationToTheGUIExecutor() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let completed = AsyncEventRecorder()
    let observe = try actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(),
        action: .observe(application: "com.apple.Safari")
    )
    let key = try actionEnvelopeV2(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        stateGeneration: 1,
        screenshotGeneration: 0,
        observation: ObservationPolicy(
            mode: .none,
            settle: .none,
            settleTimeoutMilliseconds: 0,
            imageProfile: .none
        ),
        action: .coordinate(.key("CMD+L"))
    )
    var broker: NetworkBrokerService? = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { _ in
            SequentialActionRelay(requests: [observe, key], completed: completed)
        },
        lockProvider: { _ in }
    )
    broker?.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker?.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    await completed.wait()
    #expect(approvalUI.activationCount() == 0)
    let releasedBroker = WeakReference(broker)
    broker = nil
    for _ in 0 ..< 100 where releasedBroker.value != nil {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(releasedBroker.value == nil)
}

@Test func networkBrokerLeavesLegacyScreenshotActivationToTheExecutor() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let requestData = try actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshotApplication("com.apple.Safari")
    )
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { _ in TriggerActionRelay(request: requestData) },
        lockProvider: { _ in }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let approval = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(approval) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    for _ in 0 ..< 100 where executor.actionedRequest() == nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(executor.actionedRequest() == requestData as NSData)
    #expect(approvalUI.activationCount() == 0)
}

@Test func slowExecutorActionUsesItsOwnTimeoutWithoutAbortingRelay() async throws {
    let executor = ExecutorStub(actionReplyDelaySeconds: 0.03)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let lockRecorder = LockRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { binding in await lockRecorder.record(binding) },
        xpcReplyTimeout: .milliseconds(10),
        actionReplyTimeout: .milliseconds(100)
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    #expect(await lockRecorder.value() == session.binding)
    #expect(await lifecycleRecorder.abortRequest == nil)

    let stop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: session.binding, reason: .escape)
    )).encoded() as NSData
    _ = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(stop) { continuation.resume(returning: $0?.code) }
    }
}

@Test func transientExecutorRenewalFailureRetriesWithoutAbortingRelay() async throws {
    let executor = ExecutorStub(renewFailuresBeforeSuccess: 1)
    let session = configuration(leaseUntil: Date().addingTimeInterval(3))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        relayProvider: { _ in HoldingRelay(cancellationRecorder: CancellationRecorder()) },
        lockProvider: { _ in },
        renewProvider: { configuration in
            ExecutorSessionConfiguration(
                binding: configuration.binding,
                leaseUntil: Date().addingTimeInterval(3),
                approvals: configuration.approvals,
                capabilities: configuration.capabilities
            )
        },
        renewalRetryDelaySeconds: 0.01
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    for _ in 0 ..< 300 where executor.renewalCount() < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(executor.renewalCount() == 2)
    #expect(await lifecycleRecorder.abortRequest == nil)

    let stop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: session.binding, reason: .escape)
    )).encoded() as NSData
    _ = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(stop) { continuation.resume(returning: $0?.code) }
    }
}

@Test func unresponsiveExecutorUpdateTimesOutWithoutStartingRelay() async throws {
    let executor = ExecutorStub(updateResponds: false)
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        xpcReplyTimeout: .milliseconds(10)
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == DeviceIPCFailure.serviceUnavailable.rawValue)
    #expect(executor.updateCount == 1)
    try await Task.sleep(for: .milliseconds(20))
    #expect(await lifecycleRecorder.abortCount == 1)
    #expect(executor.stoppedRequest() != nil)
}

@Test func remoteLifecycleStopsTurnIdempotentlyWithoutAbortingAndEndsSessionAfterward() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let lockRecorder = LockRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { configuration in
            TriggerLifecycleRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { binding in await lockRecorder.record(binding) }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(approvalError == nil)
    #expect(await lifecycleRecorder.waitForEnd() == BrokerEndRequest(binding: session.binding))
    #expect(await lifecycleRecorder.abortRequest == nil)
    #expect(await lockRecorder.value() == session.binding)

    let stoppedEnvelope = try DeviceIPCEnvelope.decode(
        Data(referencing: try #require(executor.paused))
    )
    let stopped = try JSONDecoder().decode(BrokerRuntimeEvent.self, from: stoppedEnvelope.payload)
    #expect(stopped == BrokerRuntimeEvent(binding: session.binding, kind: .turnStopped))
    #expect(executor.turnPauseCount() == 1)
    let endedEnvelope = try DeviceIPCEnvelope.decode(
        Data(referencing: try #require(executor.ended))
    )
    let ended = try JSONDecoder().decode(BrokerEndRequest.self, from: endedEnvelope.payload)
    #expect(ended == BrokerEndRequest(binding: session.binding))
    #expect(await approvalUI.waitForEvents(2) == [.turnStopped, .sessionEnded])
}

@Test func completedRemoteSessionDoesNotAbortWhenRelayClosesWithAnError() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let relayExit = AsyncEventRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { _ in SessionEndThenFailureRelay(exitRecorder: relayExit) },
        lockProvider: { _ in }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    await relayExit.wait()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await lifecycleRecorder.endRequest == BrokerEndRequest(binding: session.binding))
    #expect(await lifecycleRecorder.abortCount == 0)
}

@Test func unresponsiveApprovalUIDoesNotBlockABackgroundScreenshot() async throws {
    let executor = ExecutorStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            throw DeviceIPCFailure.invalidMessage
        },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        xpcReplyTimeout: .milliseconds(10)
    )
    broker.installApprovalUI(UnresponsiveApprovalUIStub())
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    for _ in 0 ..< 100 where executor.actionedRequest() == nil {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(executor.actionedRequest() != nil)
    #expect(await lifecycleRecorder.abortRequest == nil)
    #expect(executor.stoppedRequest() == nil)
    #expect(await lifecycleRecorder.endRequest == nil)
}

@Test func nextTurnReprotectsUIAndResumesExecutorBeforeItsFirstAction() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let first = try actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 1,
        screenshotGeneration: 0,
        action: .screenshot
    )
    let second = try actionEnvelope(
        configuration: session,
        requestID: UUID(),
        sequence: 2,
        screenshotGeneration: 1,
        action: .screenshot
    )
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { _ in TurnCycleRelay(first: first, second: second) },
        lockProvider: { _ in }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    #expect(await lifecycleRecorder.waitForEnd() == BrokerEndRequest(binding: session.binding))
    #expect(await approvalUI.waitForEvents(3) == [
        .turnStopped,
        .turnStarted,
        .sessionEnded,
    ])
    #expect(executor.paused != nil)
    #expect(executor.resumed != nil)
    #expect(executor.actioned == second as NSData)
}

@Test func localStopRejectsRemainingTurnActionsUntilTrustedTurnStop() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let first = configuration(leaseUntil: Date().addingTimeInterval(60))
    let second = rotatedConfiguration(first)
    let cancellation = CancellationRecorder()
    let responses = ActionDataRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let blocked = try actionEnvelopeV2(
        configuration: second,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(),
        action: .observe(application: "Finder")
    )
    let resumed = try actionEnvelopeV2(
        configuration: second,
        requestID: UUID(),
        sequence: 1,
        stateGeneration: 0,
        screenshotGeneration: 0,
        observation: ObservationPolicy(),
        action: .observe(application: "Finder")
    )
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { decision in
            decision.binding.generation == first.binding.generation ? first : second
        },
        abortProvider: { _ in
            BrokerPendingSession(
                binding: second.binding,
                expiresAt: second.leaseUntil,
                activationConfiguration: second
            )
        },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { configuration in
            if configuration.binding.generation == first.binding.generation {
                return HoldingRelay(cancellationRecorder: cancellation)
            }
            return LocalStopRecoveryRelay(
                blocked: blocked,
                resumed: resumed,
                responses: responses
            )
        },
        lockProvider: { _ in }
    )
    broker.installApprovalUI(approvalUI)

    let firstDecision = BrokerApprovalDecision(
        binding: first.binding,
        approvals: first.approvals,
        result: .allowed
    )
    let firstRequest = try envelope(
        payload: JSONEncoder().encode(firstDecision)
    ).encoded() as NSData
    let firstError = await withCheckedContinuation { continuation in
        broker.approveSession(firstRequest) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(firstError == nil)

    let abort = BrokerAbortRequest(binding: first.binding, reason: .escape)
    let abortData = try envelope(payload: JSONEncoder().encode(abort)).encoded() as NSData
    let abortError = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(abortData) { continuation.resume(returning: $0?.code) }
    }
    #expect(abortError == nil)
    #expect(cancellation.wasCancelled)

    let secondDecision = BrokerApprovalDecision(
        binding: second.binding,
        approvals: second.approvals,
        result: .allowed
    )
    let secondRequest = try envelope(
        payload: JSONEncoder().encode(secondDecision)
    ).encoded() as NSData
    let secondError = await withCheckedContinuation { continuation in
        broker.approveSession(secondRequest) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(secondError == nil)
    #expect(await lifecycleRecorder.waitForEnd() == BrokerEndRequest(binding: second.binding))

    let recorded = await responses.waitForValues(2)
    let rejected = try JSONDecoder().decode(ActionResponseV2.self, from: recorded[0])
    #expect(rejected.status == .failed)
    #expect(rejected.message.hasPrefix("turn_stopped:"))
    #expect(recorded[1] == resumed)
    #expect(executor.turnPauseCount() == 1)
    #expect(executor.resumed != nil)
    #expect(executor.actioned == resumed as NSData)
    #expect(await approvalUI.waitForEvents(2) == [.turnStarted, .sessionEnded])
}

@Test func simultaneousRelayAndRotationFailuresAbortOnlyOnce() async throws {
    let executor = ExecutorStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { _ in DelayedFailureRelay() },
        lockProvider: { _ in },
        rotationProvider: { previous in rotatedConfiguration(previous) },
        generationRotationInterval: .milliseconds(1),
        generationRotationQuietPeriod: .milliseconds(25)
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    _ = await lifecycleRecorder.waitForAbort()
    try await Task.sleep(for: .milliseconds(20))
    #expect(await lifecycleRecorder.abortCount == 1)
}

@Test func approvalUIDisconnectCancelsRelayAndAbortsWhenExecutorStopFails() async throws {
    let executor = ExecutorStub(stopFails: true)
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let cancellationRecorder = CancellationRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { _ in HoldingRelay(cancellationRecorder: cancellationRecorder) },
        lockProvider: { _ in }
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(approvalError == nil)

    broker.approvalUIConnectionInvalidated()
    let abort = await lifecycleRecorder.waitForAbort()

    #expect(abort == BrokerAbortRequest(binding: session.binding, reason: .disconnect))
    #expect(cancellationRecorder.wasCancelled)
    #expect(executor.stoppedRequest() != nil)
}

@Test func localStopAndEndReachControlPlaneWhenExecutorCleanupFails() async throws {
    let executor = ExecutorStub(stopFails: true, endFails: true)
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let pendingBinding = DeviceSessionBinding(
        userID: session.binding.userID,
        deviceID: session.binding.deviceID,
        toolSessionID: session.binding.toolSessionID,
        deviceSessionID: session.binding.deviceSessionID,
        nodeID: session.binding.nodeID,
        platform: session.binding.platform,
        generation: session.binding.generation + 1
    )
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: pendingBinding,
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) }
    )
    let abortRequest = BrokerAbortRequest(binding: session.binding, reason: .escape)
    let abortData = try envelope(payload: JSONEncoder().encode(abortRequest)).encoded() as NSData
    let abortError = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(abortData) { continuation.resume(returning: $0?.code) }
    }
    let endRequest = BrokerEndRequest(binding: pendingBinding)
    let endData = try envelope(payload: JSONEncoder().encode(endRequest)).encoded() as NSData
    let endError = await withCheckedContinuation { continuation in
        broker.endSession(endData) { continuation.resume(returning: $0?.code) }
    }

    #expect(abortError == nil)
    #expect(endError == nil)
    #expect(await lifecycleRecorder.abortRequest == abortRequest)
    #expect(await lifecycleRecorder.endRequest == endRequest)
    #expect(executor.stoppedRequest() != nil)
    #expect(executor.ended != nil)
}

@Test func staleLocalStopAndEndCannotCancelTheCurrentRelay() async throws {
    let executor = ExecutorStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let cancellationRecorder = CancellationRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(binding: request.binding, expiresAt: Date().addingTimeInterval(60))
        },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { _ in HoldingRelay(cancellationRecorder: cancellationRecorder) },
        lockProvider: { _ in }
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let approval = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(approval) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(approvalError == nil)

    let staleBinding = DeviceSessionBinding(
        userID: session.binding.userID,
        deviceID: session.binding.deviceID,
        toolSessionID: session.binding.toolSessionID,
        deviceSessionID: session.binding.deviceSessionID,
        nodeID: session.binding.nodeID,
        platform: session.binding.platform,
        generation: session.binding.generation + 1
    )
    let staleStop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: staleBinding, reason: .disconnect)
    )).encoded() as NSData
    let stopError = await withCheckedContinuation { continuation in
        broker.stopCurrentAction(staleStop) { continuation.resume(returning: $0?.code) }
    }
    let staleEnd = try envelope(payload: JSONEncoder().encode(
        BrokerEndRequest(binding: staleBinding)
    )).encoded() as NSData
    let endError = await withCheckedContinuation { continuation in
        broker.endSession(staleEnd) { continuation.resume(returning: $0?.code) }
    }

    #expect(stopError == DeviceIPCFailure.invalidMessage.rawValue)
    #expect(endError == DeviceIPCFailure.invalidMessage.rawValue)
    #expect(!cancellationRecorder.wasCancelled)
    #expect(await lifecycleRecorder.abortRequest == nil)
    #expect(await lifecycleRecorder.endRequest == nil)

    broker.approvalUIConnectionInvalidated()
}

@Test func localEndDuringRelaySetupCannotReactivateTheSession() async throws {
    let executor = ExecutorStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let relayProviderEntered = AsyncEventRecorder()
    let releaseRelayProvider = AsyncEventRecorder()
    let cancellationRecorder = CancellationRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        endProvider: { request in await lifecycleRecorder.recordEnd(request) },
        relayProvider: { _ in
            await relayProviderEntered.record()
            await releaseRelayProvider.wait()
            return HoldingRelay(cancellationRecorder: cancellationRecorder)
        },
        lockProvider: { _ in }
    )
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let approval = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalTask = Task {
        await withCheckedContinuation { continuation in
            broker.approveSession(approval) { _, error in
                continuation.resume(returning: error?.code)
            }
        }
    }
    await relayProviderEntered.wait()

    let endRequest = BrokerEndRequest(binding: session.binding)
    let endData = try envelope(payload: JSONEncoder().encode(endRequest)).encoded() as NSData
    let endError = await withCheckedContinuation { continuation in
        broker.endSession(endData) { continuation.resume(returning: $0?.code) }
    }
    await releaseRelayProvider.record()
    let approvalError = await approvalTask.value

    #expect(endError == nil)
    #expect(approvalError == DeviceIPCFailure.serviceUnavailable.rawValue)
    #expect(await lifecycleRecorder.endRequest == endRequest)
    #expect(cancellationRecorder.wasCancelled)
}

@Test func relayIdentityLifetimeRotatesTheActiveGeneration() async throws {
    let rotationStartedAt = ContinuousClock().now
    let executor = ExecutorStub(stopFails: true)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let rotationRecorder = ConfigurationRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        rotationProvider: { previous in
            let next = rotatedConfiguration(previous)
            await rotationRecorder.record(next)
            return next
        },
        generationRotationInterval: .milliseconds(100),
        generationRotationQuietPeriod: .milliseconds(50)
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(approvalError == nil)
    let rotated = await rotationRecorder.waitForFirst()
    #expect(rotationStartedAt.duration(to: ContinuousClock().now) >= .milliseconds(125))
    #expect(rotated.binding.generation == session.binding.generation + 1)
    #expect(rotated.approvals.allSatisfy { $0.generation == rotated.binding.generation })
    for _ in 0 ..< 100 where executor.sessionUpdateCount() < 2 {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(executor.stoppedRequest() != nil)
    #expect(executor.sessionUpdateCount() >= 2)
    #expect(approvalUI.recordedEvents().isEmpty)
}

@Test func relayIdentityRotationUsesTheLatestRenewedConfiguration() async throws {
    let executor = ExecutorStub(stopFails: true)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(2))
    let renewalRecorder = ConfigurationRecorder()
    let rotationRecorder = ConfigurationRecorder()
    let renewalStarted = AsyncEventRecorder()
    let releaseRenewal = AsyncEventRecorder()
    let renewedLease = Date().addingTimeInterval(60)
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        renewProvider: { previous in
            await renewalStarted.record()
            await releaseRenewal.wait()
            let renewed = ExecutorSessionConfiguration(
                binding: previous.binding,
                leaseUntil: renewedLease,
                approvals: previous.approvals,
                capabilities: previous.capabilities
            )
            await renewalRecorder.record(renewed)
            return renewed
        },
        rotationProvider: { previous in
            await rotationRecorder.record(previous)
            return rotatedConfiguration(previous)
        },
        generationRotationInterval: .milliseconds(1_200),
        generationRotationQuietPeriod: .milliseconds(50)
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    await renewalStarted.wait()
    try await Task.sleep(for: .milliseconds(300))
    #expect(await rotationRecorder.first == nil)
    await releaseRenewal.record()
    let renewed = await renewalRecorder.waitForFirst()
    #expect(renewed.leaseUntil == renewedLease)
    let configurationUsedForRotation = await rotationRecorder.waitForFirst()
    #expect(configurationUsedForRotation.leaseUntil == renewedLease)
    #expect(configurationUsedForRotation.binding == session.binding)
    #expect(approvalUI.recordedEvents().isEmpty)
}

@Test func transportDisconnectRotatesGenerationInsteadOfEndingManagedControl() async throws {
    let executor = ExecutorStub(stopFails: true)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let rotationRecorder = ConfigurationRecorder()
    let relayAttempts = RelayAttemptRecorder()
    let replacementRelayCancellation = CancellationRecorder()
    let automaticTerminationRecorder = AutomaticTerminationRecorder()
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        endProvider: { request in
            await lifecycleRecorder.recordEnd(request)
        },
        relayProvider: { configuration in
            let attempt = await relayAttempts.record(configuration)
            if attempt == 1 {
                return TransportDisconnectRelay()
            }
            return HoldingRelay(cancellationRecorder: replacementRelayCancellation)
        },
        lockProvider: { _ in },
        rotationProvider: { previous in
            let next = rotatedConfiguration(previous)
            await rotationRecorder.record(next)
            return next
        },
        automaticTerminationHandler: { disabled in
            automaticTerminationRecorder.record(disabled)
        }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    let rotated = await rotationRecorder.waitForFirst()
    #expect(rotated.binding.generation == session.binding.generation + 1)
    for _ in 0 ..< 100 where await relayAttempts.generations.count < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await relayAttempts.generations == [
        session.binding.generation,
        session.binding.generation + 1,
    ])
    #expect(automaticTerminationRecorder.values == [true])
    #expect(approvalUI.recordedEvents().isEmpty)

    let staleEnd = try envelope(payload: JSONEncoder().encode(
        BrokerEndRequest(binding: session.binding)
    )).encoded() as NSData
    let endError = await withCheckedContinuation { continuation in
        broker.endSession(staleEnd) { continuation.resume(returning: $0?.code) }
    }

    #expect(endError == nil)
    #expect(await lifecycleRecorder.endRequest?.binding == rotated.binding)
    let executorEndEnvelope = try DeviceIPCEnvelope.decode(
        Data(referencing: try #require(executor.ended))
    )
    let executorEnd = try DeviceIPCDecoder.decode(
        BrokerEndRequest.self,
        from: executorEndEnvelope.payload
    )
    #expect(executorEnd.binding == rotated.binding)
    #expect(replacementRelayCancellation.wasCancelled)
    #expect(automaticTerminationRecorder.values == [true, false])
}

@Test func cleanRelayDisconnectRotatesWithoutApplyingAnInFlightOldRenewal() async throws {
    let executor = ExecutorStub(stopFails: true)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(2))
    let renewalStarted = AsyncEventRecorder()
    let releaseRenewal = AsyncEventRecorder()
    let rotationRecorder = ConfigurationRecorder()
    let relayAttempts = RelayAttemptRecorder()
    let replacementRelayCancellation = CancellationRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { configuration in
            let attempt = await relayAttempts.record(configuration)
            if attempt == 1 {
                return CleanDisconnectAfterEventRelay(event: renewalStarted)
            }
            return HoldingRelay(cancellationRecorder: replacementRelayCancellation)
        },
        lockProvider: { _ in },
        renewProvider: { previous in
            await renewalStarted.record()
            await releaseRenewal.wait()
            return ExecutorSessionConfiguration(
                binding: previous.binding,
                leaseUntil: Date().addingTimeInterval(60),
                approvals: previous.approvals,
                capabilities: previous.capabilities
            )
        },
        rotationProvider: { previous in
            let next = rotatedConfiguration(previous)
            await rotationRecorder.record(next)
            return next
        }
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    let rotated = await rotationRecorder.waitForFirst()
    #expect(rotated.binding.generation == session.binding.generation + 1)
    await releaseRenewal.record()
    try await Task.sleep(for: .milliseconds(50))
    #expect(executor.renewalCount() == 0)
    #expect(executor.sessionUpdateCount() == 2)
    #expect(await relayAttempts.generations == [
        session.binding.generation,
        session.binding.generation + 1,
    ])
    #expect(approvalUI.recordedEvents().isEmpty)
    broker.approvalUIConnectionInvalidated()
}

@Test func relayIdentityRotationWaitsForAnInFlightAction() async throws {
    let executor = ExecutorStub(actionReplyDelaySeconds: 0.5)
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let rotationRecorder = ConfigurationRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        rotationProvider: { previous in
            let next = rotatedConfiguration(previous)
            await rotationRecorder.record(next)
            return next
        },
        generationRotationInterval: .milliseconds(200),
        generationRotationQuietPeriod: .milliseconds(100)
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }
    #expect(approvalError == nil)

    for _ in 0 ..< 1_000 where executor.actionedRequest() == nil {
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(executor.actionedRequest() != nil)
    try await Task.sleep(for: .milliseconds(250))
    #expect(await rotationRecorder.first == nil)

    let rotated = await rotationRecorder.waitForFirst()
    #expect(rotated.binding.generation == session.binding.generation + 1)
    #expect(executor.stoppedRequest() != nil)
}

@Test func failedGenerationRotationAbortsTheOldBindingAndEndsLocalApproval() async throws {
    let executor = ExecutorStub()
    let approvalUI = ApprovalUIStub()
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let lifecycleRecorder = LifecycleRecorder()
    let broker = NetworkBrokerService(
        executorOverride: executor,
        approvalProvider: { _ in session },
        abortProvider: { request in
            await lifecycleRecorder.recordAbort(request)
            return BrokerPendingSession(
                binding: DeviceSessionBinding(
                    userID: request.binding.userID,
                    deviceID: request.binding.deviceID,
                    toolSessionID: request.binding.toolSessionID,
                    deviceSessionID: request.binding.deviceSessionID,
                    nodeID: request.binding.nodeID,
                    platform: request.binding.platform,
                    generation: request.binding.generation + 1
                ),
                expiresAt: Date().addingTimeInterval(60)
            )
        },
        relayProvider: { configuration in
            TriggerActionRelay(request: try actionEnvelope(
                configuration: configuration,
                requestID: UUID(),
                sequence: 1,
                screenshotGeneration: 0,
                action: .screenshot
            ))
        },
        lockProvider: { _ in },
        rotationProvider: { _ in throw DeviceIPCFailure.serviceUnavailable },
        generationRotationInterval: .milliseconds(10),
        generationRotationQuietPeriod: .milliseconds(25)
    )
    broker.installApprovalUI(approvalUI)
    let decision = BrokerApprovalDecision(
        binding: session.binding,
        approvals: session.approvals,
        result: .allowed
    )
    let request = try envelope(payload: JSONEncoder().encode(decision)).encoded() as NSData
    let approvalError = await withCheckedContinuation { continuation in
        broker.approveSession(request) { _, error in
            continuation.resume(returning: error?.code)
        }
    }

    #expect(approvalError == nil)
    #expect(await lifecycleRecorder.waitForAbort().binding == session.binding)
    #expect(await approvalUI.waitForEvents(1) == [.sessionEnded])
    #expect(executor.stoppedRequest() != nil)
}

private func rotatedConfiguration(
    _ previous: ExecutorSessionConfiguration
) -> ExecutorSessionConfiguration {
    let binding = DeviceSessionBinding(
        userID: previous.binding.userID,
        deviceID: previous.binding.deviceID,
        toolSessionID: previous.binding.toolSessionID,
        deviceSessionID: previous.binding.deviceSessionID,
        nodeID: previous.binding.nodeID,
        platform: previous.binding.platform,
        generation: previous.binding.generation + 1
    )
    return ExecutorSessionConfiguration(
        binding: binding,
        leaseUntil: Date().addingTimeInterval(60),
        approvals: previous.approvals.map {
            LocalApproval(
                application: $0.application,
                controlLevel: $0.controlLevel,
                clipboardAllowed: $0.clipboardAllowed,
                generation: binding.generation
            )
        },
        capabilities: previous.capabilities
    )
}

private func configuration(leaseUntil: Date) -> ExecutorSessionConfiguration {
    let generation: UInt64 = 3
    return ExecutorSessionConfiguration(
        binding: DeviceSessionBinding(
            userID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
            deviceID: UUID(uuidString: "10000000-0000-4000-8000-000000000002")!,
            toolSessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
            deviceSessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!,
            nodeID: UUID(uuidString: "10000000-0000-4000-8000-000000000005")!,
            platform: .macos,
            generation: generation
        ),
        leaseUntil: leaseUntil,
        approvals: [
            LocalApproval(
                application: ApplicationIdentity(
                    bundleIdentifier: "com.apple.Safari",
                    signingIdentifier: "com.apple.Safari"
                ),
                controlLevel: .viewOnly,
                clipboardAllowed: false,
                generation: generation
            ),
        ]
    )
}

private func fullTrustConfiguration(leaseUntil: Date) -> ExecutorSessionConfiguration {
    let base = configuration(leaseUntil: leaseUntil)
    return ExecutorSessionConfiguration(
        binding: base.binding,
        leaseUntil: leaseUntil,
        approvals: [],
        authorization: SessionAuthorization(generation: base.binding.generation),
        capabilities: [
            capabilityObservationModeV2,
            capabilityAXStateV2,
            capabilityAdaptiveSettleV2,
            capabilityClipboardPayloadV2,
            capabilitySessionFullTrustV1,
            capabilityApplicationLaunchV1,
            capabilityGlobalClipboardV1,
        ]
    )
}

private func envelope(payload: Data) throws -> DeviceIPCEnvelope {
    try DeviceIPCEnvelope(requestID: UUID(), payload: payload)
}

private func actionEnvelope(
    configuration: ExecutorSessionConfiguration,
    requestID: UUID,
    sequence: UInt64,
    screenshotGeneration: UInt64,
    action: Action
) throws -> Data {
    let request = actionRequest(
        configuration: configuration,
        requestID: requestID,
        sequence: sequence,
        screenshotGeneration: screenshotGeneration,
        action: action
    )
    return try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONEncoder().encode(request)
    ).encoded()
}

private func actionRequest(
    configuration: ExecutorSessionConfiguration,
    requestID: UUID,
    sequence: UInt64,
    screenshotGeneration: UInt64,
    action: Action,
    deviceID: UUID? = nil
) -> ActionRequest {
    let binding = configuration.binding
    return ActionRequest(
        requestID: requestID,
        context: RequestContext(
            userID: binding.userID,
            deviceID: deviceID ?? binding.deviceID,
            toolSessionID: binding.toolSessionID,
            deviceSessionID: binding.deviceSessionID,
            nodeID: binding.nodeID,
            platform: binding.platform,
            generation: binding.generation,
            monotonicSequence: sequence,
            currentScreenshotGeneration: screenshotGeneration
        ),
        leaseUntil: configuration.leaseUntil,
        action: action
    )
}

private func actionEnvelopeV2(
    configuration: ExecutorSessionConfiguration,
    requestID: UUID,
    sequence: UInt64,
    stateGeneration: UInt64,
    screenshotGeneration: UInt64,
    baseStateID: UUID? = nil,
    leaseUntil: Date? = nil,
    observation: ObservationPolicy,
    action: ActionV2
) throws -> Data {
    let binding = configuration.binding
    let request = ActionRequestV2(
        requestID: requestID,
        context: RequestContextV2(
            userID: binding.userID,
            deviceID: binding.deviceID,
            toolSessionID: binding.toolSessionID,
            deviceSessionID: binding.deviceSessionID,
            nodeID: binding.nodeID,
            platform: binding.platform,
            generation: binding.generation,
            monotonicSequence: sequence,
            currentStateGeneration: stateGeneration,
            currentScreenshotGeneration: screenshotGeneration,
            baseStateID: baseStateID
        ),
        leaseUntil: leaseUntil ?? configuration.leaseUntil,
        observation: observation,
        action: action
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var object = try #require(
        JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
    )
    var context = try #require(object["context"] as? [String: Any])
    context["base_state_id"] = baseStateID?.uuidString ?? NSNull()
    object["context"] = context
    var observationObject = try #require(object["observation"] as? [String: Any])
    observationObject["region"] = NSNull()
    object["observation"] = observationObject
    return try DeviceIPCEnvelope(
        requestID: requestID,
        payload: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    ).encoded()
}

private actor RuntimeRecorder {
    private(set) var actions: [Action] = []
    private(set) var elementActions: [ActionV2] = []
    private(set) var captureCount = 0
    private(set) var releaseCount = 0
    private(set) var accessibilityClearCount = 0
    private(set) var lifecycleEvents: [String] = []
    private(set) var captureTargets: [String?] = []
    private(set) var preferredWindowIDs: [[UInt32]] = []
    private(set) var windowContextPreferredWindowIDs: [[UInt32]] = []
    private(set) var clipboardMaximumBytes: [Int] = []
    private(set) var launchedApplications: [String] = []
    private(set) var valueFreshnessCalls: [(
        target: ElementTarget,
        expectedValue: String,
        deadline: Date,
        recordedAt: Date
    )] = []
    private(set) var observationBaseStateIDs: [UUID?] = []
    private(set) var settlePhases: [String] = []
    private(set) var windowRefreshPhases: [String] = []

    func captured(targetApplication: String? = nil) {
        captureCount += 1
        captureTargets.append(targetApplication)
    }

    func captured(preferredWindowContexts: [WindowContext]) {
        preferredWindowIDs.append(preferredWindowContexts.map(\.windowID))
    }

    func resolvedWindowContext(preferredWindowContexts: [WindowContext]) {
        windowContextPreferredWindowIDs.append(preferredWindowContexts.map(\.windowID))
        windowRefreshPhases.append("window_context")
    }

    func readClipboard(maximumBytes: Int) {
        clipboardMaximumBytes.append(maximumBytes)
    }

    func launched(application: String) {
        launchedApplications.append(application)
    }

    func executed(_ action: Action) {
        actions.append(action)
        settlePhases.append("execute")
        windowRefreshPhases.append("execute")
    }

    func executedElement(_ action: ActionV2) {
        elementActions.append(action)
        settlePhases.append("execute")
        windowRefreshPhases.append("execute")
    }

    func released() {
        releaseCount += 1
        lifecycleEvents.append("release")
    }

    func restoredFocus() {
        lifecycleEvents.append("restore_focus")
    }

    func clearedAccessibility() {
        accessibilityClearCount += 1
    }

    func checkedValueFreshness(target: ElementTarget, expectedValue: String, deadline: Date) {
        valueFreshnessCalls.append((target, expectedValue, deadline, Date()))
    }

    func observed(baseStateID: UUID?) {
        observationBaseStateIDs.append(baseStateID)
    }

    func preparedSettle() {
        settlePhases.append("prepare")
    }

    func settled() {
        windowRefreshPhases.append("settle")
    }
}

private actor LifecycleRecorder {
    private(set) var abortRequest: BrokerAbortRequest?
    private(set) var endRequest: BrokerEndRequest?
    private(set) var abortCount = 0
    private var endContinuation: CheckedContinuation<BrokerEndRequest, Never>?
    private var abortContinuation: CheckedContinuation<BrokerAbortRequest, Never>?

    func recordAbort(_ request: BrokerAbortRequest) {
        abortCount += 1
        abortRequest = request
        abortContinuation?.resume(returning: request)
        abortContinuation = nil
    }

    func recordEnd(_ request: BrokerEndRequest) {
        endRequest = request
        endContinuation?.resume(returning: request)
        endContinuation = nil
    }

    func waitForEnd() async -> BrokerEndRequest {
        if let endRequest { return endRequest }
        return await withCheckedContinuation { endContinuation = $0 }
    }

    func waitForAbort() async -> BrokerAbortRequest {
        if let abortRequest { return abortRequest }
        return await withCheckedContinuation { abortContinuation = $0 }
    }
}

private actor AsyncEventRecorder {
    private var completed = false
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        completed = true
        continuation?.resume(returning: ())
        continuation = nil
    }

    func wait() async {
        if completed { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

private actor ActionDataRecorder {
    private var values: [Data] = []

    func record(_ value: Data) {
        values.append(value)
    }

    func waitForValues(_ count: Int) async -> [Data] {
        for _ in 0 ..< 100 where values.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return values
    }
}

private actor ConfigurationRecorder {
    private(set) var first: ExecutorSessionConfiguration?
    private var continuation: CheckedContinuation<ExecutorSessionConfiguration, Never>?

    func record(_ configuration: ExecutorSessionConfiguration) {
        guard first == nil else { return }
        first = configuration
        continuation?.resume(returning: configuration)
        continuation = nil
    }

    func waitForFirst() async -> ExecutorSessionConfiguration {
        if let first { return first }
        return await withCheckedContinuation { continuation = $0 }
    }
}

private actor RelayAttemptRecorder {
    private(set) var generations: [UInt64] = []

    func record(_ configuration: ExecutorSessionConfiguration) -> Int {
        generations.append(configuration.binding.generation)
        return generations.count
    }
}

private final class TriggerActionRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let request: Data

    init(request: Data) {
        self.request = request
    }

    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        _ = try await actionHandler(request)
        try await Task.sleep(for: .seconds(3_600))
    }

    func cancel() {}
}

private final class SequentialActionRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let requests: [Data]
    private let completed: AsyncEventRecorder

    init(requests: [Data], completed: AsyncEventRecorder) {
        self.requests = requests
        self.completed = completed
    }

    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        for request in requests {
            _ = try await actionHandler(request)
        }
        await completed.record()
        try await Task.sleep(for: .seconds(3_600))
    }

    func cancel() {}
}

private final class TriggerLifecycleRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let request: Data

    init(request: Data) {
        self.request = request
    }

    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        _ = try await actionHandler(request)
        try await lifecycleHandler(.turnStop)
        try await lifecycleHandler(.turnStop)
        try await lifecycleHandler(.sessionEnd)
    }

    func cancel() {}
}

private final class TurnCycleRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let first: Data
    private let second: Data

    init(first: Data, second: Data) {
        self.first = first
        self.second = second
    }

    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        _ = try await actionHandler(first)
        try await lifecycleHandler(.turnStop)
        _ = try await actionHandler(second)
        try await lifecycleHandler(.sessionEnd)
    }

    func cancel() {}
}

private final class LocalStopRecoveryRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let blocked: Data
    private let resumed: Data
    private let responses: ActionDataRecorder

    init(blocked: Data, resumed: Data, responses: ActionDataRecorder) {
        self.blocked = blocked
        self.resumed = resumed
        self.responses = responses
    }

    func run(
        actionHandler: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        await responses.record(try await actionHandler(blocked))
        try await lifecycleHandler(.turnStop)
        await responses.record(try await actionHandler(resumed))
        try await lifecycleHandler(.sessionEnd)
    }

    func cancel() {}
}

private final class SessionEndThenFailureRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let exitRecorder: AsyncEventRecorder

    init(exitRecorder: AsyncEventRecorder) {
        self.exitRecorder = exitRecorder
    }

    func run(
        actionHandler _: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        try await lifecycleHandler(.sessionEnd)
        await exitRecorder.record()
        throw DeviceIPCFailure.serviceUnavailable
    }

    func cancel() {}
}

private final class DelayedFailureRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    func run(
        actionHandler _: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        try await Task.sleep(for: .milliseconds(1))
        throw DeviceIPCFailure.serviceUnavailable
    }

    func cancel() {}
}

private final class TransportDisconnectRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    func run(
        actionHandler _: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        throw NetworkBrokerNestedTLSRelayFailure.connectionFailed
    }

    func cancel() {}
}

private final class CleanDisconnectAfterEventRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let event: AsyncEventRecorder

    init(event: AsyncEventRecorder) {
        self.event = event
    }

    func run(
        actionHandler _: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        await event.wait()
    }

    func cancel() {}
}

private final class HoldingRelay: NetworkBrokerRelayRunning, @unchecked Sendable {
    private let cancellationRecorder: CancellationRecorder

    init(cancellationRecorder: CancellationRecorder) {
        self.cancellationRecorder = cancellationRecorder
    }

    func run(
        actionHandler _: @escaping @Sendable (Data) async throws -> Data,
        lifecycleHandler _: @escaping @Sendable (RemoteLifecycleEvent) async throws -> Void
    ) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }

    func cancel() {
        cancellationRecorder.record()
    }
}

private final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var wasCancelled: Bool {
        lock.withLock { cancelled }
    }

    func record() {
        lock.withLock { cancelled = true }
    }
}

private final class AutomaticTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Bool] = []

    var values: [Bool] {
        lock.withLock { recordedValues }
    }

    func record(_ disabled: Bool) {
        lock.withLock { recordedValues.append(disabled) }
    }
}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private actor LockRecorder {
    private var binding: DeviceSessionBinding?

    func record(_ binding: DeviceSessionBinding) {
        guard self.binding == nil else { return }
        self.binding = binding
    }

    func value() async -> DeviceSessionBinding? {
        for _ in 0 ..< 100 {
            if let binding { return binding }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return binding
    }
}

private final class ApprovalUIStub: NSObject, ApprovalUIXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrokerRuntimeEventKind] = []
    private var applicationActivations = 0

    func handleRuntimeEvent(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        do {
            let envelope = try DeviceIPCEnvelope.decode(Data(referencing: request))
            let event = try JSONDecoder().decode(BrokerRuntimeEvent.self, from: envelope.payload)
            try event.validate()
            lock.withLock { events.append(event.kind) }
            reply(nil)
        } catch {
            reply(DeviceIPCFailure.invalidMessage.nsError)
        }
    }

    func activateApplication(_: NSData, reply: @escaping (NSError?) -> Void) {
        lock.withLock { applicationActivations += 1 }
        reply(nil)
    }

    func activationCount() -> Int {
        lock.withLock { applicationActivations }
    }

    func recordedEvents() -> [BrokerRuntimeEventKind] {
        lock.withLock { events }
    }

    func waitForEvents(_ count: Int) async -> [BrokerRuntimeEventKind] {
        for _ in 0 ..< 100 {
            let snapshot = lock.withLock { events }
            if snapshot.count >= count { return snapshot }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return lock.withLock { events }
    }
}

private final class UnresponsiveApprovalUIStub: NSObject, ApprovalUIXPCProtocol,
    @unchecked Sendable
{
    func handleRuntimeEvent(_: NSData, reply _: @escaping (NSError?) -> Void) {}
    func activateApplication(_: NSData, reply _: @escaping (NSError?) -> Void) {}
}

private actor RuntimeStub: GUIActionRuntime {
    private let guardState: SessionGuard
    private let recorder: RuntimeRecorder
    private var observationValues: [String?]
    private let contextActionFailure: CaptureFailure?
    private let clipboardFailure: ExecutionFailure?
    private let launchFailure: CaptureFailure?
    private var windowContextFailures: [CaptureFailure?]
    private let valueFreshnessConfirmed: Bool
    private let settleObservedMeaningfulChange: Bool
    private let settlePressTargetWasEditableText: Bool
    private let settleStatus: SettleStatus
    private let settleElapsedMilliseconds: UInt32
    private let settleDelayMilliseconds: UInt64
    private let currentSnapshotHasPageIdentity: Bool
    private var windowContextFrames: [CGRect]
    private var windowContextWindowIDs: [UInt32]
    private var windowContextDelays: [UInt64]

    init(
        guardState: SessionGuard,
        recorder: RuntimeRecorder,
        observationValues: [String?] = [],
        contextActionFailure: CaptureFailure? = nil,
        clipboardFailure: ExecutionFailure? = nil,
        launchFailure: CaptureFailure? = nil,
        windowContextFailures: [CaptureFailure?] = [],
        valueFreshnessConfirmed: Bool = true,
        settleObservedMeaningfulChange: Bool = false,
        settlePressTargetWasEditableText: Bool = false,
        settleStatus: SettleStatus = .settled,
        settleElapsedMilliseconds: UInt32 = 0,
        settleDelayMilliseconds: UInt64 = 0,
        currentSnapshotHasPageIdentity: Bool = true,
        windowContextFrames: [CGRect] = [],
        windowContextWindowIDs: [UInt32] = [],
        windowContextDelays: [UInt64] = []
    ) {
        self.guardState = guardState
        self.recorder = recorder
        self.observationValues = observationValues
        self.contextActionFailure = contextActionFailure
        self.clipboardFailure = clipboardFailure
        self.launchFailure = launchFailure
        self.windowContextFailures = windowContextFailures
        self.valueFreshnessConfirmed = valueFreshnessConfirmed
        self.settleObservedMeaningfulChange = settleObservedMeaningfulChange
        self.settlePressTargetWasEditableText = settlePressTargetWasEditableText
        self.settleStatus = settleStatus
        self.settleElapsedMilliseconds = settleElapsedMilliseconds
        self.settleDelayMilliseconds = settleDelayMilliseconds
        self.currentSnapshotHasPageIdentity = currentSnapshotHasPageIdentity
        self.windowContextFrames = windowContextFrames
        self.windowContextWindowIDs = windowContextWindowIDs
        self.windowContextDelays = windowContextDelays
    }

    func resolveApplication(
        targetApplication _: String?,
        excludedBundleIdentifiers _: Set<String>
    ) async throws -> ApplicationIdentity {
        ApplicationIdentity(
            bundleIdentifier: "com.apple.Safari",
            signingIdentifier: "com.apple.Safari"
        )
    }

    func launchApplication(
        _ application: String,
        excludedBundleIdentifiers _: Set<String>,
        deadline _: Date
    ) async throws -> WindowContext {
        await recorder.launched(application: application)
        if let launchFailure { throw launchFailure }
        return WindowContext(
            windowID: 7,
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            processID: 42,
            application: ApplicationIdentity(
                bundleIdentifier: "com.apple.Safari",
                signingIdentifier: "com.apple.Safari"
            ),
            displayFingerprint: "display-layout"
        )
    }

    func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?
    ) async throws -> CapturedWindow {
        let application = try #require(approvedApplications.first {
            targetApplication == nil || $0.bundleIdentifier == targetApplication
        })
        await recorder.captured(targetApplication: targetApplication)
        return CapturedWindow(
            pngData: Data("bounded png".utf8),
            pixelWidth: 100,
            pixelHeight: 100,
            windowID: 7,
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            coordinateFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            processID: 42,
            application: application,
            displayFingerprint: "display-layout"
        )
    }

    func captureV2(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        preferredWindowContexts: [WindowContext],
        profile _: ImageProfile,
        region: Region?
    ) async throws -> CapturedWindow {
        await recorder.captured(preferredWindowContexts: preferredWindowContexts)
        let capture = try await capture(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        return try region.map { try WindowCapture.cropped(capture, to: $0) } ?? capture
    }

    func windowContext(
        approvedApplications: [ApplicationIdentity],
        targetApplication: String?,
        preferredWindowContexts: [WindowContext]
    ) async throws -> WindowContext {
        await recorder.resolvedWindowContext(
            preferredWindowContexts: preferredWindowContexts
        )
        if !windowContextDelays.isEmpty {
            let delay = windowContextDelays.removeFirst()
            if delay > 0 {
                try await Task.sleep(for: .milliseconds(delay))
            }
        }
        if !windowContextFailures.isEmpty,
           let windowContextFailure = windowContextFailures.removeFirst()
        {
            throw windowContextFailure
        }
        let capture = try await capture(
            approvedApplications: approvedApplications,
            targetApplication: targetApplication
        )
        guard !windowContextFrames.isEmpty || !windowContextWindowIDs.isEmpty else {
            return capture.windowContext
        }
        return WindowContext(
            windowID: windowContextWindowIDs.isEmpty
                ? capture.windowID
                : windowContextWindowIDs.removeFirst(),
            windowFrame: windowContextFrames.isEmpty
                ? capture.windowFrame
                : windowContextFrames.removeFirst(),
            processID: capture.processID,
            application: capture.application,
            displayFingerprint: capture.displayFingerprint
        )
    }

    func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        try await guardState.authorize(
            action: action,
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            displayFingerprint: capture.displayFingerprint,
            application: capture.application
        )
        try await guardState.accept(sequence: sequence)
        await recorder.executed(action)
    }

    func observeAccessibility(
        context: WindowContext,
        stateGeneration: UInt64,
        baseStateID: UUID?,
        policy _: ObservationPolicy
    ) async throws -> AccessibilitySnapshotResult {
        await recorder.observed(baseStateID: baseStateID)
        let value = observationValues.isEmpty ? nil : observationValues.removeFirst()
        let state = AccessibilityStateContext(
            stateID: UUID(),
            stateGeneration: stateGeneration,
            applicationDigest: context.application.stableDigest,
            windowID: context.windowID,
            displayFingerprint: context.displayFingerprint
        )
        return AccessibilitySnapshotResult(
            context: state,
            observation: AccessibilityObservation(
                kind: baseStateID == nil ? .full : .diff,
                reset: false,
                truncated: false,
                nodes: [AccessibilityNode(
                    index: 0,
                    parentIndex: nil,
                    depth: 0,
                    role: "AXButton",
                    title: "Continue",
                    label: nil,
                    value: value,
                    placeholder: nil,
                    url: nil,
                    frame: [0, 0, 20, 20],
                    settable: false,
                    actions: ["AXPress"]
                )],
                removed: []
            ),
            baseHadPageIdentity: baseStateID != nil,
            currentHasPageIdentity: currentSnapshotHasPageIdentity
        )
    }

    func executeElement(
        action: ActionV2,
        target: ElementTarget,
        sequence: UInt64,
        context: WindowContext
    ) async throws {
        try await guardState.authorizeElement(
            action: action,
            sequence: sequence,
            target: target,
            displayFingerprint: context.displayFingerprint,
            windowID: context.windowID,
            application: context.application
        )
        try await guardState.accept(sequence: sequence)
        await recorder.executedElement(action)
    }

    func rebindAccessibilityState(
        context: WindowContext,
        stateGeneration: UInt64
    ) async -> AccessibilityStateContext? {
        AccessibilityStateContext(
            stateID: UUID(),
            stateGeneration: stateGeneration,
            applicationDigest: context.application.stableDigest,
            windowID: context.windowID,
            displayFingerprint: context.displayFingerprint
        )
    }

    func executeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws {
        if let contextActionFailure {
            throw contextActionFailure
        }
        try await guardState.authorizeContextAction(
            action: action,
            sequence: sequence,
            stateGeneration: stateGeneration,
            displayFingerprint: context.displayFingerprint,
            windowID: context.windowID,
            application: context.application
        )
        try await guardState.accept(sequence: sequence)
        await recorder.executed(action)
    }

    func settle(
        context _: WindowContext,
        policy: ObservationPolicy,
        action _: ActionV2,
        preparation _: ActionSettlePreparation?,
        deadline _: Date
    ) async throws -> ActionSettleOutcome {
        if settleDelayMilliseconds > 0 {
            try await Task.sleep(for: .milliseconds(settleDelayMilliseconds))
        }
        await recorder.settled()
        return ActionSettleOutcome(
            result: SettleResult(
                status: policy.settle == .none ? .notRequested : settleStatus,
                elapsedMilliseconds: policy.settle == .none ? 0 : settleElapsedMilliseconds
            ),
            observedMeaningfulChange: settleObservedMeaningfulChange,
            pressTargetWasEditableText: settlePressTargetWasEditableText
        )
    }

    func prepareSettle(
        context _: WindowContext,
        policy _: ObservationPolicy,
        action _: ActionV2
    ) async -> ActionSettlePreparation {
        await recorder.preparedSettle()
        return ActionSettlePreparation(
            baseline: nil,
            pressTargetWasEditableText: false
        )
    }

    func waitForAccessibilityValue(
        target: ElementTarget,
        expectedValue: String,
        deadline: Date
    ) async throws -> Bool {
        await recorder.checkedValueFreshness(
            target: target,
            expectedValue: expectedValue,
            deadline: deadline
        )
        return valueFreshnessConfirmed
    }

    func clearAccessibilityState(applicationDigest _: String?) async {
        await recorder.clearedAccessibility()
    }

    func readClipboardV2(
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext,
        maximumBytes: Int
    ) async throws -> String {
        await recorder.readClipboard(maximumBytes: maximumBytes)
        try await guardState.authorizeClipboardV2(
            sequence: sequence,
            stateGeneration: stateGeneration,
            displayFingerprint: context.displayFingerprint,
            windowID: context.windowID,
            application: context.application
        )
        guard "clipboard text".utf8.count <= maximumBytes else {
            throw ExecutionFailure.clipboardTooLarge
        }
        try await guardState.accept(sequence: sequence)
        return "clipboard text"
    }

    func readGlobalClipboard(sequence: UInt64, maximumBytes: Int) async throws -> String {
        await recorder.readClipboard(maximumBytes: maximumBytes)
        try await guardState.authorizeGlobalClipboard(sequence: sequence)
        if let clipboardFailure { throw clipboardFailure }
        guard "clipboard text".utf8.count <= maximumBytes else {
            throw ExecutionFailure.clipboardTooLarge
        }
        try await guardState.accept(sequence: sequence)
        return "clipboard text"
    }

    func authorizeCaptureAction(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        try await guardState.authorize(
            action: action,
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            displayFingerprint: capture.displayFingerprint,
            application: capture.application
        )
    }

    func readClipboard(
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws -> String {
        try await guardState.authorize(
            action: .readClipboard,
            sequence: sequence,
            screenshotGeneration: screenshotGeneration,
            displayFingerprint: capture.displayFingerprint,
            application: capture.application
        )
        try await guardState.accept(sequence: sequence)
        return "clipboard text"
    }

    func releasePressedState() async {
        await recorder.released()
    }

    func restoreUserFocus() async {
        await recorder.restoredFocus()
    }
}

private actor RecoveringCaptureRuntime: GUIActionRuntime {
    let failure: CaptureFailure
    private var captureCount = 0

    init(failure: CaptureFailure) {
        self.failure = failure
    }

    func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication _: String?
    ) async throws -> CapturedWindow {
        captureCount += 1
        if captureCount == 1 {
            throw failure
        }
        let application = try #require(approvedApplications.first)
        return CapturedWindow(
            pngData: Data("recovered png".utf8),
            pixelWidth: 100,
            pixelHeight: 100,
            windowID: 7,
            windowFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            coordinateFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            processID: 42,
            application: application,
            displayFingerprint: "display-layout"
        )
    }

    func execute(
        action _: Action,
        sequence _: UInt64,
        screenshotGeneration _: UInt64,
        capture _: CapturedWindow
    ) async throws {}

    func authorizeCaptureAction(
        action _: Action,
        sequence _: UInt64,
        screenshotGeneration _: UInt64,
        capture _: CapturedWindow
    ) async throws {}

    func readClipboard(
        sequence _: UInt64,
        screenshotGeneration _: UInt64,
        capture _: CapturedWindow
    ) async throws -> String {
        "clipboard text"
    }

    func releasePressedState() async {}
}

private final class ExecutorStub: NSObject, GUIExecutorXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private let stopFails: Bool
    private let endFails: Bool
    private(set) var updated: NSData?
    private(set) var renewed: NSData?
    private(set) var stopped: NSData?
    private(set) var ended: NSData?
    private(set) var actioned: NSData?
    private(set) var paused: NSData?
    private(set) var resumed: NSData?
    private(set) var updateCount = 0
    private var pauseCount = 0
    private let updateResponds: Bool
    private let actionReplyDelaySeconds: TimeInterval
    private var remainingRenewFailures: Int
    private var renewCount = 0

    init(
        stopFails: Bool = false,
        endFails: Bool = false,
        updateResponds: Bool = true,
        actionReplyDelaySeconds: TimeInterval = 0,
        renewFailuresBeforeSuccess: Int = 0
    ) {
        self.stopFails = stopFails
        self.endFails = endFails
        self.updateResponds = updateResponds
        self.actionReplyDelaySeconds = actionReplyDelaySeconds
        remainingRenewFailures = renewFailuresBeforeSuccess
    }

    func protocolVersion(reply: @escaping (UInt64) -> Void) {
        reply(DeviceIPCVersion.current)
    }

    func brokerEndpoint(reply: @escaping (NSXPCListenerEndpoint?, NSError?) -> Void) {
        reply(nil, DeviceIPCFailure.serviceUnavailable.nsError)
    }

    func updateSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.lock()
        updated = request
        updateCount += 1
        lock.unlock()
        guard updateResponds else { return }
        reply(nil)
    }

    func renewSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.lock()
        renewed = request
        renewCount += 1
        let shouldFail = remainingRenewFailures > 0
        remainingRenewFailures = max(0, remainingRenewFailures - 1)
        lock.unlock()
        reply(shouldFail ? DeviceIPCFailure.serviceUnavailable.nsError : nil)
    }

    func performAction(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void) {
        lock.lock()
        actioned = request
        lock.unlock()
        if actionReplyDelaySeconds > 0 {
            Thread.sleep(forTimeInterval: actionReplyDelaySeconds)
        }
        reply(request, nil)
    }

    func renewalCount() -> Int {
        lock.withLock { renewCount }
    }

    func sessionUpdateCount() -> Int {
        lock.withLock { updateCount }
    }

    func actionedRequest() -> NSData? {
        lock.withLock { actioned }
    }

    func pauseTurn(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.withLock {
            paused = request
            pauseCount += 1
        }
        reply(nil)
    }

    func turnPauseCount() -> Int {
        lock.withLock { pauseCount }
    }

    func resumeTurn(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.withLock { resumed = request }
        reply(nil)
    }

    func stopCurrentAction(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.lock()
        stopped = request
        lock.unlock()
        reply(stopFails ? DeviceIPCFailure.serviceUnavailable.nsError : nil)
    }

    func stoppedRequest() -> NSData? {
        lock.withLock { stopped }
    }

    func endSession(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.lock()
        ended = request
        lock.unlock()
        reply(endFails ? DeviceIPCFailure.serviceUnavailable.nsError : nil)
    }
}
