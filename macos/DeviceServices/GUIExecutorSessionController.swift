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

        if requiresFreshScreenshot, request.action != .screenshot {
            throw GuardFailure.staleScreenshot
        }

        switch request.action {
        case .screenshot:
            try await guardState.authorizeScreenshot(
                sequence: request.context.monotonicSequence
            )
            capture = try await runtime.capture(approvedApplications: approvedApplications)
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
        default:
            guard let latestCapture else { throw GuardFailure.staleScreenshot }
            try await runtime.execute(
                action: request.action,
                sequence: request.context.monotonicSequence,
                screenshotGeneration: currentGeneration,
                capture: latestCapture
            )
            capture = try await runtime.capture(approvedApplications: approvedApplications)
            try await record(
                capture: capture,
                generation: nextGeneration,
                sequence: request.context.monotonicSequence,
                acceptSequence: false
            )
        }

        latestCapture = capture
        if request.action == .screenshot {
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
