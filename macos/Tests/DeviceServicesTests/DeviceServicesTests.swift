import DeviceIPC
import DeviceProtocol
import DeviceSecurity
import DeviceServices
import Foundation
import GUIExecutor
import Testing

@Test func executorSessionControllerActivatesStopsAndEndsOneBoundSession() async throws {
    let recorder = RuntimeRecorder()
    let controller = GUIExecutorSessionController { guardState in
        RuntimeStub(guardState: guardState, recorder: recorder)
    }
    let session = configuration(leaseUntil: Date().addingTimeInterval(60))
    let update = try envelope(payload: JSONEncoder().encode(session)).encoded()

    try await controller.updateSession(update)
    #expect(await controller.hasActiveSession())
    #expect(await controller.currentState() == .active)

    let stop = try envelope(payload: JSONEncoder().encode(
        BrokerAbortRequest(binding: session.binding, reason: .escape)
    )).encoded()
    try await controller.stopCurrentAction(stop)
    #expect(await controller.currentState() == .failed)

    let end = try envelope(payload: JSONEncoder().encode(
        BrokerEndRequest(binding: session.binding)
    )).encoded()
    try await controller.endSession(end)
    #expect(await controller.currentState() == nil)
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

@Test func executorPausesOneTurnAndRequiresANewScreenshotAfterResume() async throws {
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

@Test func remoteLifecycleStopsTurnWithoutAbortingAndEndsSessionAfterward() async throws {
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

@Test func unresponsiveApprovalUITimesOutAndAbortsTheRelay() async throws {
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
            TriggerLifecycleRelay(request: try actionEnvelope(
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
    let abort = await lifecycleRecorder.waitForAbort()
    #expect(abort == BrokerAbortRequest(binding: session.binding, reason: .disconnect))
    #expect(executor.stoppedRequest() != nil)
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
    #expect(await approvalUI.waitForEvents(3) == [.turnStopped, .turnStarted, .sessionEnded])
    #expect(executor.paused != nil)
    #expect(executor.resumed != nil)
    #expect(executor.actioned == second as NSData)
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
        generationRotationInterval: .milliseconds(1)
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
        generationRotationInterval: .milliseconds(10)
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
    let abort = await lifecycleRecorder.waitForAbort()
    #expect(abort.binding == session.binding)
    #expect(abort.reason == .disconnect)
    #expect(executor.stoppedRequest() != nil)
    #expect(await approvalUI.waitForEvents(1) == [.sessionEnded])
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

private actor RuntimeRecorder {
    private(set) var actions: [Action] = []
    private(set) var captureCount = 0
    private(set) var releaseCount = 0

    func captured() {
        captureCount += 1
    }

    func executed(_ action: Action) {
        actions.append(action)
    }

    func released() {
        releaseCount += 1
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

private actor LockRecorder {
    private var binding: DeviceSessionBinding?
    private var continuation: CheckedContinuation<DeviceSessionBinding, Never>?

    func record(_ binding: DeviceSessionBinding) {
        guard self.binding == nil else { return }
        self.binding = binding
        continuation?.resume(returning: binding)
        continuation = nil
    }

    func value() async -> DeviceSessionBinding {
        if let binding { return binding }
        return await withCheckedContinuation { continuation = $0 }
    }
}

private final class ApprovalUIStub: NSObject, ApprovalUIXPCProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [BrokerRuntimeEventKind] = []

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
        reply(nil)
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

    init(guardState: SessionGuard, recorder: RuntimeRecorder) {
        self.guardState = guardState
        self.recorder = recorder
    }

    func capture(
        approvedApplications: [ApplicationIdentity],
        targetApplication _: String?
    ) async throws -> CapturedWindow {
        let application = try #require(approvedApplications.first)
        await recorder.captured()
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
    private let updateResponds: Bool

    init(
        stopFails: Bool = false,
        endFails: Bool = false,
        updateResponds: Bool = true
    ) {
        self.stopFails = stopFails
        self.endFails = endFails
        self.updateResponds = updateResponds
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
        lock.unlock()
        reply(nil)
    }

    func performAction(_ request: NSData, reply: @escaping (NSData?, NSError?) -> Void) {
        lock.lock()
        actioned = request
        lock.unlock()
        reply(request, nil)
    }

    func pauseTurn(_ request: NSData, reply: @escaping (NSError?) -> Void) {
        lock.withLock { paused = request }
        reply(nil)
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
