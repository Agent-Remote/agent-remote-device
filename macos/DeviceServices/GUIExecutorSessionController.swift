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
    private var turnPaused = false
    private var requiresFreshScreenshot = false
    private let runtimeFactory: RuntimeFactory

    public init(
        runtimeFactory: @escaping RuntimeFactory = { guardState in
            await LiveGUIActionRuntime.make(guardState: guardState)
        }
    ) {
        self.runtimeFactory = runtimeFactory
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
        turnPaused = false
        requiresFreshScreenshot = false
    }

    public func performAction(_ data: Data) async throws -> Data {
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
        turnPaused = true
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
        turnPaused = false
        requiresFreshScreenshot = false
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
        }
        if let guardState {
            await guardState.failClosed()
        }
        latestCapture = nil
        turnPaused = false
        requiresFreshScreenshot = false
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
                    targetApplication: nil
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
