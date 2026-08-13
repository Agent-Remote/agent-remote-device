import DeviceIPC
import DeviceProtocol
import DeviceSecurity
import Foundation
import GUIExecutor

public actor GUIExecutorSessionController {
    public typealias RuntimeFactory = @Sendable (SessionGuard) async -> any GUIActionRuntime

    private var configuration: ExecutorSessionConfiguration?
    private var guardState: SessionGuard?
    private var runtime: (any GUIActionRuntime)?
    private var latestCapture: CapturedWindow?
    private var latestWindowContext: WindowContext?
    private var windowContextsByApplication: [String: WindowContext] = [:]
    private var turnPaused = false
    private var requiresFreshScreenshot = false
    private var lastCompletedRequest: Data?
    private var lastCompletedResponse: Data?
    private let runtimeFactory: RuntimeFactory
    private let automaticTerminationHandler: @Sendable (Bool) -> Void
    private var automaticTerminationDisabled = false

    public init(
        runtimeFactory: @escaping RuntimeFactory = { guardState in
            await LiveGUIActionRuntime.make(guardState: guardState)
        },
        automaticTerminationHandler: @escaping @Sendable (Bool) -> Void = { disabled in
            if disabled {
                ProcessInfo.processInfo.disableAutomaticTermination(
                    "Active Agent Remote GUI execution"
                )
            } else {
                ProcessInfo.processInfo.enableAutomaticTermination(
                    "Active Agent Remote GUI execution"
                )
            }
        }
    ) {
        self.runtimeFactory = runtimeFactory
        self.automaticTerminationHandler = automaticTerminationHandler
    }

    deinit {
        if automaticTerminationDisabled {
            automaticTerminationHandler(false)
        }
    }

    public func updateSession(_ data: Data) async throws {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let configuration = try DeviceIPCDecoder.decode(
            ExecutorSessionConfiguration.self,
            from: envelope.payload
        )
        try configuration.validate()
        await failCurrentSession()

        let guardState = SessionGuard(generation: configuration.binding.generation)
        try await guardState.deviceConnected()
        try await guardState.activate(
            approvals: configuration.approvals,
            leaseUntil: configuration.leaseUntil
        )
        let runtime = await runtimeFactory(guardState)
        self.configuration = configuration
        self.guardState = guardState
        self.runtime = runtime
        latestCapture = nil
        latestWindowContext = nil
        windowContextsByApplication.removeAll(keepingCapacity: false)
        turnPaused = false
        requiresFreshScreenshot = false
        clearReplayCache()
        disableAutomaticTerminationIfNeeded()
    }

    public func performAction(_ data: Data) async throws -> Data {
        if data == lastCompletedRequest, let lastCompletedResponse {
            return lastCompletedResponse
        }
        let response = try await performActionOnce(data)
        lastCompletedRequest = data
        lastCompletedResponse = response
        return response
    }

    private func performActionOnce(_ data: Data) async throws -> Data {
        if try requestVersion(in: data) == protocolVersionV2 {
            return try await performActionV2(data)
        }
        do {
            return try await performValidatedAction(data)
        } catch let failure as CaptureFailure {
            if isRecoverableScreenshotFailure(data) {
                return try failureResponse(for: data, failure: failure)
            }
            await failCurrentSession()
            throw failure
        } catch let failure as ExecutionFailure {
            switch failure {
            case .applicationChanged, .windowChanged, .displayChanged:
                requiresFreshScreenshot = true
                return try failureResponse(
                    for: data,
                    code: "fresh_screenshot_required",
                    message: failure.userMessage
                )
            case .accessibilityPermissionMissing, .eventCreationFailed, .unsupportedKey,
                 .clipboardContentUnavailable, .clipboardContentTooLarge:
                return try failureResponse(
                    for: data,
                    code: failure.diagnosticCode,
                    message: failure.userMessage
                )
            case .actionRequiresCapture:
                await failCurrentSession()
                throw failure
            }
        } catch let failure as GuardFailure {
            if failure == .staleScreenshot, latestCapture == nil {
                return try failureResponse(
                    for: data,
                    code: "fresh_screenshot_required",
                    message: "A successful fresh screenshot is required before this action."
                )
            }
            if let diagnostic = recoverableGuardFailure(failure) {
                return try failureResponse(
                    for: data,
                    code: diagnostic.code,
                    message: diagnostic.message
                )
            }
            await failCurrentSession()
            throw failure
        } catch {
            await failCurrentSession()
            throw error
        }
    }

    public func renewSession(_ data: Data) async throws {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let renewed = try DeviceIPCDecoder.decode(
            ExecutorSessionConfiguration.self,
            from: envelope.payload
        )
        try renewed.validate()
        guard let configuration,
              let guardState,
              renewed.binding == configuration.binding,
              renewed.approvals == configuration.approvals,
              renewed.capabilities == configuration.capabilities,
              renewed.leaseUntil >= configuration.leaseUntil
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        try await guardState.renewLease(until: renewed.leaseUntil)
        self.configuration = renewed
    }

    public func stopCurrentAction(_ data: Data) async throws {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request = try DeviceIPCDecoder.decode(BrokerAbortRequest.self, from: envelope.payload)
        try request.validate()
        guard let configuration, configuration.binding == request.binding else {
            throw DeviceIPCFailure.invalidMessage
        }
        await failCurrentSession()
    }

    public func pauseTurn(_ data: Data) async throws {
        let event = try decodeRuntimeEvent(data, kind: .turnStopped)
        guard let configuration,
              configuration.binding == event.binding,
              let runtime,
              !turnPaused
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        await runtime.releasePressedState()
        latestCapture = nil
        latestWindowContext = nil
        await runtime.clearAccessibilityState(applicationDigest: nil)
        windowContextsByApplication.removeAll(keepingCapacity: false)
        turnPaused = true
        clearReplayCache()
    }

    public func resumeTurn(_ data: Data) throws {
        let event = try decodeRuntimeEvent(data, kind: .turnStarted)
        guard let configuration,
              configuration.binding == event.binding,
              runtime != nil,
              turnPaused
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        turnPaused = false
        requiresFreshScreenshot = true
    }

    public func endSession(_ data: Data) async throws {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request = try DeviceIPCDecoder.decode(BrokerEndRequest.self, from: envelope.payload)
        try request.validate()
        guard let currentConfiguration = configuration,
              currentConfiguration.binding == request.binding
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        await failCurrentSession()
        configuration = nil
        guardState = nil
        runtime = nil
        latestCapture = nil
        latestWindowContext = nil
        windowContextsByApplication.removeAll(keepingCapacity: false)
        turnPaused = false
        requiresFreshScreenshot = false
        clearReplayCache()
    }

    public func hasActiveSession() async -> Bool {
        guard let guardState else { return false }
        return await guardState.state == .active && runtime != nil && !turnPaused
    }

    public func currentState() async -> DeviceSessionState? {
        guard let guardState else { return nil }
        return await guardState.state
    }

    private func failCurrentSession() async {
        if let runtime {
            await runtime.releasePressedState()
            await runtime.clearAccessibilityState(applicationDigest: nil)
        }
        if let guardState {
            await guardState.failClosed()
        }
        latestCapture = nil
        latestWindowContext = nil
        windowContextsByApplication.removeAll(keepingCapacity: false)
        turnPaused = false
        requiresFreshScreenshot = false
        clearReplayCache()
        enableAutomaticTerminationIfNeeded()
    }

    private func disableAutomaticTerminationIfNeeded() {
        guard !automaticTerminationDisabled else { return }
        automaticTerminationDisabled = true
        automaticTerminationHandler(true)
    }

    private func enableAutomaticTerminationIfNeeded() {
        guard automaticTerminationDisabled else { return }
        automaticTerminationDisabled = false
        automaticTerminationHandler(false)
    }

    private func clearReplayCache() {
        lastCompletedRequest = nil
        lastCompletedResponse = nil
    }

    private func performValidatedAction(_ data: Data) async throws -> Data {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request: ActionRequest
        do {
            request = try ActionRequest.decodeStrict(envelope.payload)
        } catch {
            throw DeviceIPCFailure.invalidMessage
        }
        guard request.version == protocolVersion,
              envelope.requestID == request.requestID,
              let configuration,
              let guardState,
              let runtime,
              !turnPaused,
              configuration.binding.matches(request.context),
              request.leaseUntil > Date(),
              request.leaseUntil <= configuration.leaseUntil,
              request.action.hasValidParameters
        else {
            throw DeviceIPCFailure.invalidMessage
        }

        let currentGeneration = await guardState.currentScreenshot?.generation ?? 0
        guard request.context.currentScreenshotGeneration == currentGeneration else {
            throw GuardFailure.staleScreenshot
        }
        let nextGeneration = try incremented(currentGeneration)
        let approvedApplications = configuration.approvals.map(\.application)
        let capture: CapturedWindow

        if requiresFreshScreenshot, !isScreenshot(request.action) {
            throw GuardFailure.staleScreenshot
        }

        switch request.action {
        case .screenshot, .screenshotApplication:
            try await guardState.authorizeScreenshot(
                sequence: request.context.monotonicSequence
            )
            let targetApplication: String? = switch request.action {
            case let .screenshotApplication(application): application
            default: nil
            }
            capture = try await runtime.capture(
                approvedApplications: approvedApplications,
                targetApplication: targetApplication
            )
            try await record(
                capture: capture,
                generation: nextGeneration,
                sequence: request.context.monotonicSequence,
                acceptSequence: true
            )
        case let .zoom(region):
            guard let latestCapture else { throw GuardFailure.staleScreenshot }
            try await runtime.authorizeCaptureAction(
                action: request.action,
                sequence: request.context.monotonicSequence,
                screenshotGeneration: currentGeneration,
                capture: latestCapture
            )
            capture = try WindowCapture.cropped(latestCapture, to: region)
            try await record(
                capture: capture,
                generation: nextGeneration,
                sequence: request.context.monotonicSequence,
                acceptSequence: true
            )
        case .readClipboard:
            guard let latestCapture else { throw GuardFailure.staleScreenshot }
            let text = try await runtime.readClipboard(
                sequence: request.context.monotonicSequence,
                screenshotGeneration: currentGeneration,
                capture: latestCapture
            )
            return try successWithoutImageResponse(
                for: data,
                screenshotGeneration: currentGeneration,
                message: text
            )
        default:
            guard let latestCapture else { throw GuardFailure.staleScreenshot }
            try await runtime.execute(
                action: request.action,
                sequence: request.context.monotonicSequence,
                screenshotGeneration: currentGeneration,
                capture: latestCapture
            )
            do {
                capture = try await runtime.capture(
                    approvedApplications: approvedApplications,
                    targetApplication: latestCapture.application.bundleIdentifier
                )
            } catch let failure as CaptureFailure {
                requiresFreshScreenshot = true
                return try successWithoutImageResponse(
                    for: data,
                    screenshotGeneration: currentGeneration,
                    message: "Action completed, but the follow-up screenshot failed (\(failure.diagnosticCode)): \(failure.userMessage)"
                )
            }
            try await record(
                capture: capture,
                generation: nextGeneration,
                sequence: request.context.monotonicSequence,
                acceptSequence: false
            )
        }

        latestCapture = capture
        latestWindowContext = capture.windowContext
        if isScreenshot(request.action) {
            requiresFreshScreenshot = false
        }
        let response = ExecutorActionResponse(
            requestID: request.requestID,
            monotonicSequence: request.context.monotonicSequence,
            screenshotGeneration: nextGeneration,
            status: .success,
            message: "Action completed.",
            image: ExecutorImagePayload(
                base64Data: capture.pngData.base64EncodedString(),
                mimeType: "image/png"
            )
        )
        let encoded = try JSONEncoder().encode(response)
        guard encoded.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        return encoded
    }

    private func record(
        capture: CapturedWindow,
        generation: UInt64,
        sequence: UInt64,
        acceptSequence: Bool
    ) async throws {
        guard let guardState else { throw GuardFailure.invalidState }
        try await guardState.recordScreenshot(ScreenshotContext(
            generation: generation,
            displayFingerprint: capture.displayFingerprint,
            applicationDigest: capture.application.stableDigest,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight
        ))
        if acceptSequence {
            try await guardState.accept(sequence: sequence)
        }
    }

    private func performActionV2(_ data: Data) async throws -> Data {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request: ActionRequestV2
        do {
            request = try ActionRequestV2.decodeStrict(envelope.payload)
        } catch {
            throw DeviceIPCFailure.invalidMessage
        }
        guard envelope.requestID == request.requestID,
              let configuration,
              configuration.supportsProtocolV2,
              let guardState,
              let runtime,
              !turnPaused,
              bindingMatches(configuration.binding, request.context),
              request.leaseUntil > Date(),
              request.leaseUntil <= configuration.leaseUntil,
              request.observation.hasValidParameters,
              request.action.hasValidParameters
        else {
            throw DeviceIPCFailure.invalidMessage
        }

        let currentState = await guardState.currentState
        let currentStateGeneration = currentState?.stateGeneration ?? 0
        let currentScreenshotGeneration = await guardState.currentScreenshot?.generation ?? 0
        guard request.context.currentStateGeneration == currentStateGeneration,
              request.context.currentScreenshotGeneration == currentScreenshotGeneration
        else {
            return try failureResponseV2(
                request: request,
                code: "stale_state",
                message: "The request does not reference the current GUI state. Observe again."
            )
        }
        let nextStateGeneration = try incremented(currentStateGeneration)
        let approvedApplications = configuration.approvals.map(\.application)
        let targetApplication: String? = switch request.action {
        case let .observe(application): application
        default: nil
        }

        let isObservationOnly: Bool = if case .observe = request.action { true } else { false }
        let elementApplicationDigest: String? = switch request.action {
        case let .press(target),
             let .setValue(target, _),
             let .selectText(target, _, _, _, _),
             let .scrollElement(target, _, _),
             let .secondaryAction(target, _):
            target.applicationDigest
        default:
            nil
        }
        let explicitlyRequestsImage = request.observation.mode == .screenshot
            || request.observation.mode == .both
        var prefetchedCapture: CapturedWindow?
        var observationAuthorized = false

        var windowContext: WindowContext
        do {
            if isObservationOnly, explicitlyRequestsImage {
                try await guardState.authorizeScreenshot(
                    sequence: request.context.monotonicSequence
                )
                observationAuthorized = true
                let profile = request.observation.imageProfile == .none
                    ? ImageProfile.compact
                    : request.observation.imageProfile
                let capture = try await runtime.captureV2(
                    approvedApplications: approvedApplications,
                    targetApplication: targetApplication,
                    profile: profile,
                    region: request.observation.region
                )
                prefetchedCapture = capture
                windowContext = capture.windowContext
            } else if case .observe = request.action {
                windowContext = try await runtime.windowContext(
                    approvedApplications: approvedApplications,
                    targetApplication: targetApplication
                )
            } else if let elementApplicationDigest,
                      let elementContext = windowContextsByApplication[elementApplicationDigest]
            {
                windowContext = elementContext
            } else if let latestWindowContext {
                windowContext = latestWindowContext
            } else {
                return try failureResponseV2(
                    request: request,
                    code: "fresh_observation_required",
                    message: "A successful observation is required before this action."
                )
            }
        } catch let failure as CaptureFailure {
            return try failureResponseV2(
                request: request,
                code: failure.diagnosticCode,
                message: failure.userMessage
            )
        }
        if let latestWindowContext, latestWindowContext != windowContext {
            latestCapture = nil
        }
        let applicationDigest = windowContext.application.stableDigest
        if let prior = windowContextsByApplication[applicationDigest],
           !Self.sameAccessibilityIdentity(prior, windowContext)
        {
            await runtime.clearAccessibilityState(applicationDigest: applicationDigest)
            await guardState.discardState(applicationDigest: applicationDigest)
            windowContextsByApplication.removeValue(forKey: applicationDigest)
        }

        let settlePreparation: ActionSettlePreparation? = if isObservationOnly {
            nil
        } else {
            await runtime.prepareSettle(
                context: windowContext,
                policy: request.observation,
                action: request.action
            )
        }
        var message = "Action completed."
        do {
            switch request.action {
            case .observe:
                if !observationAuthorized {
                    try await guardState.authorizeScreenshot(
                        sequence: request.context.monotonicSequence
                    )
                }
            case let .coordinate(action):
                if action.requiresModelVisibleScreenshot {
                    guard let latestCapture else {
                        return try failureResponseV2(
                            request: request,
                            code: "fresh_screenshot_required",
                            message: "A model-visible screenshot is required for actions that use screen coordinates."
                        )
                    }
                    try await runtime.execute(
                        action: action,
                        sequence: request.context.monotonicSequence,
                        screenshotGeneration: currentScreenshotGeneration,
                        capture: latestCapture
                    )
                } else {
                    try await runtime.executeContextAction(
                        action: action,
                        sequence: request.context.monotonicSequence,
                        stateGeneration: currentStateGeneration,
                        context: windowContext
                    )
                }
            case let .press(target),
                 let .setValue(target, _),
                 let .selectText(target, _, _, _, _),
                 let .scrollElement(target, _, _),
                 let .secondaryAction(target, _):
                try await runtime.executeElement(
                    action: request.action,
                    target: target,
                    sequence: request.context.monotonicSequence,
                    context: windowContext
                )
            case .readClipboard:
                message = try await runtime.readClipboardV2(
                    sequence: request.context.monotonicSequence,
                    stateGeneration: currentStateGeneration,
                    context: windowContext
                )
            }
        } catch let failure as AccessibilityFailure {
            return try failureResponseV2(
                request: request,
                code: failure.diagnosticCode,
                message: String(describing: failure)
            )
        } catch let failure as ExecutionFailure {
            return try failureResponseV2(
                request: request,
                code: failure.diagnosticCode,
                message: failure.userMessage
            )
        } catch let failure as CaptureFailure {
            return try failureResponseV2(
                request: request,
                code: failure.diagnosticCode,
                message: failure.userMessage
            )
        } catch let failure as GuardFailure {
            if let diagnostic = recoverableGuardFailureV2(failure) {
                return try failureResponseV2(
                    request: request,
                    code: diagnostic.code,
                    message: diagnostic.message
                )
            }
            await failCurrentSession()
            throw failure
        }

        if case .readClipboard = request.action {
            guard let currentState else {
                return try failureResponseV2(
                    request: request,
                    code: "fresh_observation_required",
                    message: "A successful observation is required before reading the clipboard."
                )
            }
            latestWindowContext = windowContext
            let response = ActionResponseV2(
                requestID: request.requestID,
                monotonicSequence: request.context.monotonicSequence,
                stateGeneration: currentState.stateGeneration,
                screenshotGeneration: currentScreenshotGeneration,
                stateID: currentState.stateID,
                applicationDigest: currentState.applicationDigest,
                windowID: currentState.windowID,
                displayFingerprint: currentState.displayFingerprint,
                baseStateID: nil,
                status: .success,
                message: message,
                observation: nil,
                settle: SettleResult(status: .notRequested, elapsedMilliseconds: 0),
                image: nil
            )
            return try JSONEncoder().encode(response)
        }

        var observationBaseStateID = request.observation.mode == .axFull
            ? nil
            : request.context.baseStateID
        let actionApplication = windowContext.application.bundleIdentifier
        if !isObservationOnly {
            do {
                let refreshed = try await runtime.windowContext(
                    approvedApplications: approvedApplications,
                    targetApplication: actionApplication
                )
                if !Self.sameAccessibilityIdentity(refreshed, windowContext) {
                    latestCapture = nil
                    let applicationDigest = windowContext.application.stableDigest
                    await runtime.clearAccessibilityState(applicationDigest: applicationDigest)
                    await guardState.discardState(applicationDigest: applicationDigest)
                    windowContextsByApplication.removeValue(forKey: applicationDigest)
                    observationBaseStateID = nil
                }
                windowContext = refreshed
            } catch let failure as CaptureFailure {
                message += " Follow-up window refresh failed (\(failure.diagnosticCode))."
            }
        }
        let settleOutcome: ActionSettleOutcome
        if isObservationOnly {
            settleOutcome = ActionSettleOutcome(
                result: SettleResult(status: .notRequested, elapsedMilliseconds: 0),
                observedMeaningfulChange: false
            )
        } else {
            let requestedDeadline = Date().addingTimeInterval(
                Double(request.observation.settleTimeoutMilliseconds) / 1_000
            )
            let deadline = min(requestedDeadline, request.leaseUntil)
            do {
                settleOutcome = try await runtime.settle(
                    context: windowContext,
                    policy: request.observation,
                    action: request.action,
                    preparation: settlePreparation,
                    deadline: deadline
                )
            } catch {
                settleOutcome = ActionSettleOutcome(
                    result: SettleResult(status: .timeout, elapsedMilliseconds: 0),
                    observedMeaningfulChange: false
                )
                message += " Adaptive settle was unavailable."
            }
        }
        let settle = settleOutcome.result

        var observation: AccessibilityObservation?
        var stateContext: AccessibilityStateContext?
        let expectedTypedText: String? = if case let .coordinate(.type(text)) = request.action {
            text
        } else {
            nil
        }
        let wantsAX = switch request.observation.mode {
        case .axDiff, .axFull, .both, .auto: true
        case .none, .screenshot: false
        }
        if wantsAX, case let .setValue(target, expectedValue) = request.action {
            let freshnessDeadline = min(
                Date().addingTimeInterval(2),
                request.leaseUntil
            )
            do {
                if try await !runtime.waitForAccessibilityValue(
                    target: target,
                    expectedValue: expectedValue,
                    deadline: freshnessDeadline
                ) {
                    message += " Expected accessibility value was not visible before the freshness deadline."
                }
            } catch let failure as AccessibilityFailure {
                message += " Accessibility value freshness check failed (\(failure.diagnosticCode))."
            } catch {
                message += " Accessibility value freshness check was unavailable."
            }
        }
        if wantsAX {
            do {
                var result = try await runtime.observeAccessibility(
                    context: windowContext,
                    stateGeneration: nextStateGeneration,
                    baseStateID: observationBaseStateID,
                    policy: request.observation
                )
                if let expectedTypedText,
                   !expectedTypedText.isEmpty,
                   !Self.observation(result.observation, confirms: expectedTypedText)
                {
                    let freshnessDeadline = min(
                        Date().addingTimeInterval(2),
                        request.leaseUntil
                    )
                    while Date() < freshnessDeadline {
                        try await Task.sleep(for: .milliseconds(100))
                        result = try await runtime.observeAccessibility(
                            context: windowContext,
                            stateGeneration: nextStateGeneration,
                            baseStateID: nil,
                            policy: request.observation
                        )
                        if Self.observation(result.observation, confirms: expectedTypedText) {
                            break
                        }
                    }
                    if !Self.observation(result.observation, confirms: expectedTypedText) {
                        message += " Typed text was not visible in AX before the freshness deadline."
                    }
                }
                if Self.needsNavigationObservationRecovery(
                    settleOutcome: settleOutcome,
                    observation: result.observation,
                    baseHadPageIdentity: result.baseHadPageIdentity,
                    currentHasPageIdentity: result.currentHasPageIdentity,
                    action: request.action
                ) {
                    let remainingMilliseconds = Int64(request.leaseUntil.timeIntervalSinceNow * 1_000)
                    if remainingMilliseconds > 0 {
                        try await Task.sleep(for: .milliseconds(min(100, remainingMilliseconds)))
                    }
                    result = try await runtime.observeAccessibility(
                        context: windowContext,
                        stateGeneration: nextStateGeneration,
                        baseStateID: nil,
                        policy: request.observation
                    )
                }
                observation = Self.observationRequiringResetWhenReplacingModelBase(
                    result.observation,
                    modelBaseStateID: request.context.baseStateID
                )
                stateContext = result.context
            } catch let failure as AccessibilityFailure {
                if request.observation.mode != .auto {
                    if isObservationOnly {
                        return try failureResponseV2(
                            request: request,
                            code: failure.diagnosticCode,
                            message: String(describing: failure)
                        )
                    }
                    message += " AX observation failed after the action (\(failure.diagnosticCode))."
                }
            }
        }

        let needsAutoFallback = request.observation.mode == .auto && observation == nil
        let wantsImage = request.observation.mode == .screenshot
            || request.observation.mode == .both
            || needsAutoFallback
        var image: ImagePayloadV2?
        var screenshotGeneration = currentScreenshotGeneration
        if wantsImage {
            do {
                let profile = request.observation.imageProfile == .none
                    ? ImageProfile.compact
                    : request.observation.imageProfile
                let capture: CapturedWindow
                if let prefetchedCapture {
                    capture = prefetchedCapture
                } else {
                    capture = try await runtime.captureV2(
                        approvedApplications: approvedApplications,
                        targetApplication: actionApplication,
                        profile: profile,
                        region: request.observation.region
                    )
                }
                screenshotGeneration = try incremented(currentScreenshotGeneration)
                try await guardState.recordScreenshot(ScreenshotContext(
                    generation: screenshotGeneration,
                    displayFingerprint: capture.displayFingerprint,
                    applicationDigest: capture.application.stableDigest,
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight
                ))
                latestCapture = capture
                latestWindowContext = capture.windowContext
                image = ImagePayloadV2(
                    base64Data: capture.pngData.base64EncodedString(),
                    mimeType: "image/png",
                    pixelWidth: capture.pixelWidth,
                    pixelHeight: capture.pixelHeight,
                    profile: profile
                )
            } catch let failure as CaptureFailure {
                if isObservationOnly {
                    return try failureResponseV2(
                        request: request,
                        code: failure.diagnosticCode,
                        message: failure.userMessage
                    )
                }
                message += " Follow-up image failed (\(failure.diagnosticCode))."
            }
        }

        if stateContext == nil {
            stateContext = AccessibilityStateContext(
                stateID: UUID(),
                stateGeneration: nextStateGeneration,
                applicationDigest: windowContext.application.stableDigest,
                windowID: windowContext.windowID,
                displayFingerprint: windowContext.displayFingerprint
            )
        }
        guard let stateContext else { throw DeviceIPCFailure.invalidMessage }
        try await guardState.recordState(stateContext)
        latestWindowContext = windowContext
        windowContextsByApplication[stateContext.applicationDigest] = windowContext
        if isObservationOnly {
            try await guardState.accept(sequence: request.context.monotonicSequence)
        }

        let response = ActionResponseV2(
            requestID: request.requestID,
            monotonicSequence: request.context.monotonicSequence,
            stateGeneration: nextStateGeneration,
            screenshotGeneration: screenshotGeneration,
            stateID: stateContext.stateID,
            applicationDigest: stateContext.applicationDigest,
            windowID: stateContext.windowID,
            displayFingerprint: stateContext.displayFingerprint,
            baseStateID: observation?.kind == .diff ? request.context.baseStateID : nil,
            status: .success,
            message: message,
            observation: observation,
            settle: settle,
            image: image
        )
        let encoded = try JSONEncoder().encode(response)
        guard encoded.count <= DeviceIPCVersion.maximumMessageBytes else {
            throw DeviceIPCFailure.messageTooLarge
        }
        return encoded
    }

    private static func observation(
        _ observation: AccessibilityObservation,
        confirms text: String
    ) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let withoutScheme = normalized
            .replacing(/^https?:\/\//, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let needles = [normalized, withoutScheme].filter { !$0.isEmpty }
        return observation.nodes.contains { node in
            [node.title, node.label, node.value, node.url]
                .compactMap { $0?.lowercased() }
                .contains { value in needles.contains { value.contains($0) } }
        }
    }

    static func observationRequiringResetWhenReplacingModelBase(
        _ observation: AccessibilityObservation,
        modelBaseStateID: UUID?
    ) -> AccessibilityObservation {
        guard observation.kind == .full,
              !observation.reset,
              modelBaseStateID != nil
        else { return observation }
        return AccessibilityObservation(
            kind: observation.kind,
            reset: true,
            truncated: observation.truncated,
            nodes: observation.nodes,
            removed: observation.removed
        )
    }

    static func sameAccessibilityIdentity(_ left: WindowContext, _ right: WindowContext) -> Bool {
        left.application == right.application
            && left.processID == right.processID
            && left.windowID == right.windowID
            && left.displayFingerprint == right.displayFingerprint
    }

    static func needsNavigationObservationRecovery(
        settleOutcome: ActionSettleOutcome,
        observation: AccessibilityObservation,
        baseHadPageIdentity: Bool,
        currentHasPageIdentity: Bool,
        action: ActionV2
    ) -> Bool {
        guard settleOutcome.observedMeaningfulChange,
              observation.kind == .diff,
              baseHadPageIdentity,
              !currentHasPageIdentity,
              actionMayNavigate(
                  action,
                  pressTargetWasEditableText: settleOutcome.pressTargetWasEditableText
              )
        else { return false }
        return true
    }

    private static func actionMayNavigate(
        _ action: ActionV2,
        pressTargetWasEditableText: Bool
    ) -> Bool {
        ActionSettleTiming.mayNavigate(
            action,
            pressTargetsEditableText: pressTargetWasEditableText
        )
    }

    private func requestVersion(in data: Data) throws -> UInt8 {
        let envelope = try DeviceIPCEnvelope.decode(data)
        guard let object = try JSONSerialization.jsonObject(with: envelope.payload) as? [String: Any],
              let number = object["version"] as? NSNumber
        else {
            throw DeviceIPCFailure.invalidMessage
        }
        return number.uint8Value
    }

    private func bindingMatches(
        _ binding: DeviceSessionBinding,
        _ context: RequestContextV2
    ) -> Bool {
        binding.userID == context.userID
            && binding.deviceID == context.deviceID
            && binding.toolSessionID == context.toolSessionID
            && binding.deviceSessionID == context.deviceSessionID
            && binding.nodeID == context.nodeID
            && binding.platform == context.platform
            && binding.generation == context.generation
    }

    private func failureResponseV2(
        request: ActionRequestV2,
        code: String,
        message: String
    ) throws -> Data {
        let response = ActionResponseV2(
            requestID: request.requestID,
            monotonicSequence: request.context.monotonicSequence,
            stateGeneration: request.context.currentStateGeneration,
            screenshotGeneration: request.context.currentScreenshotGeneration,
            stateID: nil,
            applicationDigest: nil,
            windowID: nil,
            displayFingerprint: nil,
            baseStateID: nil,
            status: .failed,
            message: "\(code): \(message)",
            observation: nil,
            settle: SettleResult(status: .notRequested, elapsedMilliseconds: 0),
            image: nil
        )
        return try JSONEncoder().encode(response)
    }

    private func recoverableGuardFailureV2(
        _ failure: GuardFailure
    ) -> (code: String, message: String)? {
        switch failure {
        case .controlLevelDenied:
            ("control_level_denied", "This session was not approved for the requested control level.")
        case .clipboardAccessDenied:
            ("clipboard_access_denied", "Clipboard access was not approved for this application in the current session.")
        case .coordinateOutOfBounds:
            ("coordinate_out_of_bounds", "The coordinate is outside the model-visible screenshot.")
        case .invalidParameters:
            ("invalid_action_parameters", "The requested action parameters are invalid.")
        case .staleScreenshot:
            ("fresh_screenshot_required", "Take a new screenshot before using coordinates.")
        case .staleState, .displayChanged, .applicationChanged, .windowChanged:
            ("fresh_observation_required", "The approved UI changed. Observe it again.")
        default:
            nil
        }
    }

    private func incremented(_ value: UInt64) throws -> UInt64 {
        let (next, overflow) = value.addingReportingOverflow(1)
        guard !overflow else { throw DeviceIPCFailure.invalidMessage }
        return next
    }

    private func failureResponse(for data: Data, failure: CaptureFailure) throws -> Data {
        try failureResponse(
            for: data,
            code: failure.diagnosticCode,
            message: failure.userMessage
        )
    }

    private func failureResponse(
        for data: Data,
        code: String,
        message: String
    ) throws -> Data {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request = try ActionRequest.decodeStrict(envelope.payload)
        let response = ExecutorActionResponse(
            requestID: request.requestID,
            monotonicSequence: request.context.monotonicSequence,
            screenshotGeneration: request.context.currentScreenshotGeneration,
            status: .failed,
            message: "\(code): \(message)",
            image: nil
        )
        return try JSONEncoder().encode(response)
    }

    private func successWithoutImageResponse(
        for data: Data,
        screenshotGeneration: UInt64,
        message: String
    ) throws -> Data {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let request = try ActionRequest.decodeStrict(envelope.payload)
        let response = ExecutorActionResponse(
            requestID: request.requestID,
            monotonicSequence: request.context.monotonicSequence,
            screenshotGeneration: screenshotGeneration,
            status: .success,
            message: message,
            image: nil
        )
        return try JSONEncoder().encode(response)
    }

    private func recoverableGuardFailure(
        _ failure: GuardFailure
    ) -> (code: String, message: String)? {
        switch failure {
        case .controlLevelDenied:
            ("control_level_denied", "This session was not approved for the requested control level.")
        case .clipboardAccessDenied:
            ("clipboard_access_denied", "Clipboard access was not approved for this application in the current session.")
        case .coordinateOutOfBounds:
            ("coordinate_out_of_bounds", "The requested coordinate is outside the latest screenshot.")
        case .invalidParameters:
            ("invalid_action_parameters", "The requested action parameters are invalid.")
        case .displayChanged, .applicationChanged:
            ("fresh_screenshot_required", "The approved UI changed after the latest screenshot. Take a fresh screenshot.")
        default:
            nil
        }
    }

    private func isRecoverableScreenshotFailure(_ data: Data) -> Bool {
        guard let envelope = try? DeviceIPCEnvelope.decode(data),
              let request = try? ActionRequest.decodeStrict(envelope.payload)
        else {
            return false
        }
        return isScreenshot(request.action)
    }

    private func isScreenshot(_ action: Action) -> Bool {
        switch action {
        case .screenshot, .screenshotApplication: true
        default: false
        }
    }

    private func decodeRuntimeEvent(
        _ data: Data,
        kind: BrokerRuntimeEventKind
    ) throws -> BrokerRuntimeEvent {
        let envelope = try DeviceIPCEnvelope.decode(data)
        let event = try DeviceIPCDecoder.decode(BrokerRuntimeEvent.self, from: envelope.payload)
        try event.validate()
        guard event.kind == kind else { throw DeviceIPCFailure.invalidMessage }
        return event
    }
}
