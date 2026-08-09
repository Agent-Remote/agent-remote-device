import DeviceProtocol
import Foundation

public enum DeviceSessionState: String, Sendable {
    case pendingDevice = "pending_device"
    case pendingUserApproval = "pending_user_approval"
    case active
    case stopping
    case stopped
    case denied
    case expired
    case failed
}

public struct LocalApproval: Codable, Equatable, Sendable {
    public let application: ApplicationIdentity
    public let controlLevel: ControlLevel
    public let clipboardAllowed: Bool
    public let generation: UInt64

    public init(
        application: ApplicationIdentity,
        controlLevel: ControlLevel,
        clipboardAllowed: Bool,
        generation: UInt64
    ) {
        self.application = application
        self.controlLevel = controlLevel
        self.clipboardAllowed = clipboardAllowed
        self.generation = generation
    }
}

public struct ScreenshotContext: Equatable, Sendable {
    public let generation: UInt64
    public let displayFingerprint: String
    public let applicationDigest: String
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16

    public init(
        generation: UInt64,
        displayFingerprint: String,
        applicationDigest: String,
        pixelWidth: UInt16,
        pixelHeight: UInt16
    ) {
        self.generation = generation
        self.displayFingerprint = displayFingerprint
        self.applicationDigest = applicationDigest
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum GuardFailure: Error, Equatable, Sendable {
    case invalidState
    case generationMismatch
    case sequenceMismatch
    case counterExhausted
    case leaseExpired
    case approvalMissing
    case approvalFromPriorGeneration
    case controlLevelDenied
    case clipboardAccessDenied
    case staleScreenshot
    case staleState
    case displayChanged
    case applicationChanged
    case windowChanged
    case coordinateOutOfBounds
    case invalidParameters
}

public actor SessionGuard {
    public private(set) var state: DeviceSessionState
    public private(set) var generation: UInt64
    public private(set) var nextSequence: UInt64
    public private(set) var currentScreenshot: ScreenshotContext?
    public private(set) var currentState: AccessibilityStateContext?

    private var leaseUntil: Date?
    private var approvals: [String: LocalApproval] = [:]
    private var statesByApplication: [String: AccessibilityStateContext] = [:]

    public init(generation: UInt64 = 1, nextSequence: UInt64 = 1) {
        state = .pendingDevice
        self.generation = generation
        self.nextSequence = nextSequence
    }

    public func deviceConnected() throws {
        guard state == .pendingDevice else { throw GuardFailure.invalidState }
        guard (1 ... maximumActiveDeviceSessionGeneration).contains(generation) else {
            failClosed()
            throw GuardFailure.generationMismatch
        }
        state = .pendingUserApproval
    }

    public func activate(approvals: [LocalApproval], leaseUntil: Date) throws {
        guard state == .pendingUserApproval, leaseUntil > Date() else {
            throw GuardFailure.invalidState
        }
        guard !approvals.isEmpty, approvals.allSatisfy({ $0.generation == generation }) else {
            throw GuardFailure.approvalFromPriorGeneration
        }
        guard approvals.count <= 32,
              Set(approvals.map(\.application.stableDigest)).count == approvals.count
        else {
            failClosed()
            throw GuardFailure.invalidParameters
        }
        self.approvals = Dictionary(
            uniqueKeysWithValues: approvals.map { ($0.application.stableDigest, $0) }
        )
        self.leaseUntil = leaseUntil
        state = .active
    }

    public func renewLease(until value: Date, now: Date = Date()) throws {
        try requireActive(now: now)
        guard let leaseUntil, value >= leaseUntil, value > now else {
            throw GuardFailure.leaseExpired
        }
        self.leaseUntil = value
    }

    public func recordScreenshot(_ context: ScreenshotContext) throws {
        try requireActive(now: Date())
        guard context.generation > (currentScreenshot?.generation ?? 0) else {
            throw GuardFailure.staleScreenshot
        }
        guard let approval = approvals[context.applicationDigest], approval.generation == generation else {
            throw GuardFailure.approvalMissing
        }
        currentScreenshot = context
    }

    public func recordState(_ context: AccessibilityStateContext) throws {
        try requireActive(now: Date())
        guard context.stateGeneration > (currentState?.stateGeneration ?? 0) else {
            throw GuardFailure.staleState
        }
        guard let approval = approvals[context.applicationDigest], approval.generation == generation else {
            throw GuardFailure.approvalMissing
        }
        currentState = context
        statesByApplication[context.applicationDigest] = context
    }

    public func discardState(applicationDigest: String) {
        statesByApplication.removeValue(forKey: applicationDigest)
    }

    public func authorizeScreenshot(sequence: UInt64, now: Date = Date()) throws {
        try requireActive(now: now)
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        guard nextSequence < UInt64.max else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
    }

    public func authorize(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        displayFingerprint: String,
        application: ApplicationIdentity,
        now: Date = Date()
    ) throws {
        try requireActive(now: now)
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        guard nextSequence < UInt64.max else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        guard action.hasValidParameters else { throw GuardFailure.invalidParameters }
        guard let screenshot = currentScreenshot, screenshot.generation == screenshotGeneration else {
            throw GuardFailure.staleScreenshot
        }
        guard screenshot.displayFingerprint == displayFingerprint else {
            throw GuardFailure.displayChanged
        }
        let digest = application.stableDigest
        guard screenshot.applicationDigest == digest else { throw GuardFailure.applicationChanged }
        guard let approval = approvals[digest] else { throw GuardFailure.approvalMissing }
        guard approval.generation == generation else { throw GuardFailure.approvalFromPriorGeneration }
        if action == .readClipboard, !approval.clipboardAllowed {
            throw GuardFailure.clipboardAccessDenied
        }
        guard approval.controlLevel >= requiredLevel(for: action) else {
            throw GuardFailure.controlLevelDenied
        }
        guard coordinatesFit(action, width: screenshot.pixelWidth, height: screenshot.pixelHeight) else {
            throw GuardFailure.coordinateOutOfBounds
        }
    }

    public func authorizeElement(
        action: ActionV2,
        sequence: UInt64,
        target: ElementTarget,
        displayFingerprint: String,
        windowID: UInt32,
        application: ApplicationIdentity,
        now: Date = Date()
    ) throws {
        try requireActive(now: now)
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        guard nextSequence < UInt64.max else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        guard action.hasValidParameters, target.hasValidParameters else {
            throw GuardFailure.invalidParameters
        }
        guard let state = statesByApplication[target.applicationDigest], state.matches(target) else {
            throw GuardFailure.staleState
        }
        guard state.displayFingerprint == displayFingerprint else {
            throw GuardFailure.displayChanged
        }
        guard state.windowID == windowID else { throw GuardFailure.windowChanged }
        let digest = application.stableDigest
        guard state.applicationDigest == digest else { throw GuardFailure.applicationChanged }
        guard let approval = approvals[digest] else { throw GuardFailure.approvalMissing }
        guard approval.generation == generation else { throw GuardFailure.approvalFromPriorGeneration }
        guard approval.controlLevel >= requiredLevel(for: action) else {
            throw GuardFailure.controlLevelDenied
        }
    }

    public func authorizeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        displayFingerprint: String,
        windowID: UInt32,
        application: ApplicationIdentity,
        now: Date = Date()
    ) throws {
        try requireActive(now: now)
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        guard nextSequence < UInt64.max else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        guard action.hasValidParameters, !action.requiresModelVisibleScreenshot else {
            throw GuardFailure.invalidParameters
        }
        guard let state = currentState, state.stateGeneration == stateGeneration else {
            throw GuardFailure.staleState
        }
        guard state.displayFingerprint == displayFingerprint else {
            throw GuardFailure.displayChanged
        }
        guard state.windowID == windowID else { throw GuardFailure.windowChanged }
        let digest = application.stableDigest
        guard state.applicationDigest == digest else { throw GuardFailure.applicationChanged }
        guard let approval = approvals[digest] else { throw GuardFailure.approvalMissing }
        guard approval.generation == generation else { throw GuardFailure.approvalFromPriorGeneration }
        guard approval.controlLevel >= requiredLevel(for: action) else {
            throw GuardFailure.controlLevelDenied
        }
    }

    public func authorizeClipboardV2(
        sequence: UInt64,
        stateGeneration: UInt64,
        displayFingerprint: String,
        windowID: UInt32,
        application: ApplicationIdentity,
        now: Date = Date()
    ) throws {
        try requireActive(now: now)
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        guard nextSequence < UInt64.max else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        guard let state = currentState, state.stateGeneration == stateGeneration else {
            throw GuardFailure.staleState
        }
        guard state.displayFingerprint == displayFingerprint else {
            throw GuardFailure.displayChanged
        }
        guard state.windowID == windowID else { throw GuardFailure.windowChanged }
        let digest = application.stableDigest
        guard state.applicationDigest == digest else { throw GuardFailure.applicationChanged }
        guard let approval = approvals[digest] else { throw GuardFailure.approvalMissing }
        guard approval.generation == generation else { throw GuardFailure.approvalFromPriorGeneration }
        guard approval.clipboardAllowed else { throw GuardFailure.clipboardAccessDenied }
    }

    public func accept(sequence: UInt64) throws {
        guard sequence == nextSequence else { throw GuardFailure.sequenceMismatch }
        let (next, overflow) = nextSequence.addingReportingOverflow(1)
        guard !overflow else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        nextSequence = next
    }

    public func moveToNewGeneration(_ value: UInt64) throws {
        guard generation < maximumActiveDeviceSessionGeneration else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        let (next, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            failClosed()
            throw GuardFailure.counterExhausted
        }
        guard value == next else { throw GuardFailure.generationMismatch }
        generation = value
        approvals.removeAll(keepingCapacity: false)
        currentScreenshot = nil
        currentState = nil
        statesByApplication.removeAll(keepingCapacity: false)
        leaseUntil = nil
        state = .pendingDevice
    }

    public func failClosed() {
        approvals.removeAll(keepingCapacity: false)
        currentScreenshot = nil
        currentState = nil
        statesByApplication.removeAll(keepingCapacity: false)
        leaseUntil = nil
        state = .failed
    }

    private func requireActive(now: Date) throws {
        guard state == .active else { throw GuardFailure.invalidState }
        guard let leaseUntil, leaseUntil > now else {
            state = .expired
            self.leaseUntil = nil
            currentScreenshot = nil
            currentState = nil
            statesByApplication.removeAll(keepingCapacity: false)
            throw GuardFailure.leaseExpired
        }
    }

    private func requiredLevel(for action: Action) -> ControlLevel {
        switch action {
        case .screenshot, .screenshotApplication, .readClipboard, .zoom, .wait:
            .viewOnly
        case .type, .key, .holdKey:
            .fullControl
        default:
            .clickOnly
        }
    }

    private func requiredLevel(for action: ActionV2) -> ControlLevel {
        switch action {
        case .observe, .readClipboard:
            .viewOnly
        case let .coordinate(action):
            requiredLevel(for: action)
        case .press, .scrollElement, .secondaryAction:
            .clickOnly
        case .setValue, .selectText:
            .fullControl
        }
    }

    private func coordinatesFit(_ action: Action, width: UInt16, height: UInt16) -> Bool {
        let points: [Point]
        switch action {
        case let .leftClick(point), let .mouseMove(point), let .rightClick(point),
             let .middleClick(point), let .doubleClick(point), let .tripleClick(point):
            points = [point]
        case let .scroll(_, _, point):
            points = point.map { [$0] } ?? []
        case let .leftClickDrag(start, end, _):
            points = [start, end]
        case let .zoom(region):
            let maximumX = UInt32(region.x) + UInt32(region.width)
            let maximumY = UInt32(region.y) + UInt32(region.height)
            return maximumX <= UInt32(width) && maximumY <= UInt32(height)
        default:
            points = []
        }
        return points.allSatisfy { $0.x < width && $0.y < height }
    }
}
