import DeviceProtocol
import Foundation
import Testing
@testable import DeviceSecurity

@Test func publicApplicationMappingsRemainVersionedAndConservative() {
    #expect(ApplicationPolicy.mappingVersion == 1)
    #expect(ApplicationPolicy.classify(bundleIdentifier: "com.apple.Safari").controlLevel == .viewOnly)
    #expect(ApplicationPolicy.classify(bundleIdentifier: "com.apple.Terminal").controlLevel == .clickOnly)
    #expect(ApplicationPolicy.classify(bundleIdentifier: "com.apple.Terminal").warnings == [.shellAccess])
    #expect(ApplicationPolicy.classify(bundleIdentifier: "com.apple.finder").warnings == [.fileAccess])
    #expect(ApplicationPolicy.classify(bundleIdentifier: "example.unknown").source == .pendingConfirmation)
    #expect(ApplicationPolicy.classify(bundleIdentifier: "example.unknown").controlLevel == nil)
}

@Test func approvalCannotCrossGeneration() async throws {
    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Terminal",
        signingIdentifier: "com.apple.Terminal"
    )
    let guardState = SessionGuard()
    try await guardState.deviceConnected()
    try await guardState.activate(
        approvals: [
            LocalApproval(
                application: application,
                controlLevel: .clickOnly,
                clipboardAllowed: false,
                generation: 1
            )
        ],
        leaseUntil: Date().addingTimeInterval(60)
    )
    try await guardState.moveToNewGeneration(2)
    #expect(await guardState.state == .pendingDevice)
    try await guardState.deviceConnected()
    await #expect(throws: GuardFailure.approvalFromPriorGeneration) {
        try await guardState.activate(
            approvals: [
                LocalApproval(
                    application: application,
                    controlLevel: .clickOnly,
                    clipboardAllowed: false,
                    generation: 1
                )
            ],
            leaseUntil: Date().addingTimeInterval(60)
        )
    }
}

@Test func staleCoordinatesAndControlLevelFailClosed() async throws {
    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Terminal",
        signingIdentifier: "com.apple.Terminal"
    )
    let guardState = SessionGuard(nextSequence: 7)
    try await guardState.deviceConnected()
    try await guardState.activate(
        approvals: [
            LocalApproval(
                application: application,
                controlLevel: .clickOnly,
                clipboardAllowed: false,
                generation: 1
            )
        ],
        leaseUntil: Date().addingTimeInterval(60)
    )
    try await guardState.recordScreenshot(
        ScreenshotContext(
            generation: 4,
            displayFingerprint: "display-a",
            applicationDigest: application.stableDigest,
            pixelWidth: 800,
            pixelHeight: 600
        )
    )
    await #expect(throws: GuardFailure.controlLevelDenied) {
        try await guardState.authorize(
            action: .type("not allowed"),
            sequence: 7,
            screenshotGeneration: 4,
            displayFingerprint: "display-a",
            application: application
        )
    }
    await #expect(throws: GuardFailure.coordinateOutOfBounds) {
        try await guardState.authorize(
            action: .leftClick(Point(x: 800, y: 10)),
            sequence: 7,
            screenshotGeneration: 4,
            displayFingerprint: "display-a",
            application: application
        )
    }
    await #expect(throws: GuardFailure.displayChanged) {
        try await guardState.authorize(
            action: .leftClick(Point(x: 10, y: 10)),
            sequence: 7,
            screenshotGeneration: 4,
            displayFingerprint: "display-b",
            application: application
        )
    }
}

@Test func screenshotAuthorizationConsumesOnlyTheExactSequence() async throws {
    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari",
        signingIdentifier: "com.apple.Safari"
    )
    let guardState = SessionGuard(nextSequence: 4)
    try await guardState.deviceConnected()
    try await guardState.activate(
        approvals: [
            LocalApproval(
                application: application,
                controlLevel: .viewOnly,
                clipboardAllowed: false,
                generation: 1
            ),
        ],
        leaseUntil: Date().addingTimeInterval(60)
    )

    await #expect(throws: GuardFailure.sequenceMismatch) {
        try await guardState.authorizeScreenshot(sequence: 3)
    }
    try await guardState.authorizeScreenshot(sequence: 4)
    try await guardState.accept(sequence: 4)
    #expect(await guardState.nextSequence == 5)
    await #expect(throws: GuardFailure.sequenceMismatch) {
        try await guardState.authorizeScreenshot(sequence: 4)
    }
}

@Test func exhaustedSequenceAndGenerationFailClosedWithoutWrapping() async throws {
    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari",
        signingIdentifier: "com.apple.Safari"
    )
    let sequenceGuard = SessionGuard(nextSequence: UInt64.max)
    try await sequenceGuard.deviceConnected()
    try await sequenceGuard.activate(
        approvals: [
            LocalApproval(
                application: application,
                controlLevel: .viewOnly,
                clipboardAllowed: false,
                generation: 1
            ),
        ],
        leaseUntil: Date().addingTimeInterval(60)
    )
    await #expect(throws: GuardFailure.counterExhausted) {
        try await sequenceGuard.authorizeScreenshot(sequence: UInt64.max)
    }
    #expect(await sequenceGuard.state == .failed)

    let generationGuard = SessionGuard(generation: UInt64.max)
    await #expect(throws: GuardFailure.counterExhausted) {
        try await generationGuard.moveToNewGeneration(0)
    }
    #expect(await generationGuard.state == .failed)
}

@Test func sessionGuardRejectsTerminalGenerationAndDuplicateApprovals() async throws {
    let terminalGuard = SessionGuard(generation: maximumDeviceSessionGeneration)
    await #expect(throws: GuardFailure.generationMismatch) {
        try await terminalGuard.deviceConnected()
    }
    #expect(await terminalGuard.state == .failed)

    let application = ApplicationIdentity(
        bundleIdentifier: "com.apple.Safari",
        signingIdentifier: "com.apple.Safari"
    )
    let approval = LocalApproval(
        application: application,
        controlLevel: .viewOnly,
        clipboardAllowed: false,
        generation: 1
    )
    let duplicateGuard = SessionGuard()
    try await duplicateGuard.deviceConnected()
    await #expect(throws: GuardFailure.invalidParameters) {
        try await duplicateGuard.activate(
            approvals: [approval, approval],
            leaseUntil: Date().addingTimeInterval(60)
        )
    }
    #expect(await duplicateGuard.state == .failed)
}

@Test func sessionGuardCannotRotateIntoTheTerminalOnlyGeneration() async throws {
    let guardState = SessionGuard(generation: maximumActiveDeviceSessionGeneration)
    await #expect(throws: GuardFailure.counterExhausted) {
        try await guardState.moveToNewGeneration(maximumDeviceSessionGeneration)
    }
    #expect(await guardState.state == .failed)
}
