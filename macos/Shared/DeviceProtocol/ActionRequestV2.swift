import Foundation

public let protocolVersionV2: UInt8 = 2
public let capabilityObservationModeV2 = "observation_mode_v2"
public let capabilityAXStateV2 = "ax_state_v2"
public let capabilityAdaptiveSettleV2 = "adaptive_settle_v2"
public let capabilityClipboardPayloadV2 = "clipboard_payload_v2"
public let capabilitySessionFullTrustV1 = "session_full_trust_v1"
public let capabilityApplicationLaunchV1 = "application_launch_v1"
public let capabilityGlobalClipboardV1 = "global_clipboard_v1"

public let maximumAXNodes: UInt16 = 800
public let maximumAXDepth: UInt8 = 20
public let maximumAXTextPerNode: UInt16 = 160
public let maximumAXTotalTextBytes: UInt32 = 16 * 1_024
public let maximumAXVisibleRowsPerContainer: UInt8 = 20
public let maximumSettleTimeoutMilliseconds: UInt32 = 5_000
public let defaultAXNodes: UInt16 = 600
public let defaultAXTotalTextBytes: UInt32 = 12 * 1_024
public let defaultAXVisibleRowsPerContainer: UInt8 = 12
public let maximumClipboardTextBytesV2 = 64 * 1_024
public let maximumApplicationSpecifierBytes = 255

public struct ActionRequestV2: Codable, Sendable, Equatable {
    public let version: UInt8
    public let requestID: UUID
    public let context: RequestContextV2
    public let leaseUntil: Date
    public let observation: ObservationPolicy
    public let action: ActionV2

    public init(
        version: UInt8 = protocolVersionV2,
        requestID: UUID,
        context: RequestContextV2,
        leaseUntil: Date,
        observation: ObservationPolicy,
        action: ActionV2
    ) {
        self.version = version
        self.requestID = requestID
        self.context = context
        self.leaseUntil = leaseUntil
        self.observation = observation
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case version, context, observation, action
        case requestID = "request_id"
        case leaseUntil = "lease_until"
    }
}

public struct RequestContextV2: Codable, Sendable, Equatable {
    public let userID: UUID
    public let deviceID: UUID
    public let toolSessionID: UUID
    public let deviceSessionID: UUID
    public let nodeID: UUID
    public let platform: Platform
    public let generation: UInt64
    public let monotonicSequence: UInt64
    public let currentStateGeneration: UInt64
    public let currentScreenshotGeneration: UInt64
    public let baseStateID: UUID?

    public init(
        userID: UUID,
        deviceID: UUID,
        toolSessionID: UUID,
        deviceSessionID: UUID,
        nodeID: UUID,
        platform: Platform,
        generation: UInt64,
        monotonicSequence: UInt64,
        currentStateGeneration: UInt64,
        currentScreenshotGeneration: UInt64,
        baseStateID: UUID?
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.toolSessionID = toolSessionID
        self.deviceSessionID = deviceSessionID
        self.nodeID = nodeID
        self.platform = platform
        self.generation = generation
        self.monotonicSequence = monotonicSequence
        self.currentStateGeneration = currentStateGeneration
        self.currentScreenshotGeneration = currentScreenshotGeneration
        self.baseStateID = baseStateID
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case toolSessionID = "tool_session_id"
        case deviceSessionID = "device_session_id"
        case nodeID = "node_id"
        case platform, generation
        case monotonicSequence = "monotonic_sequence"
        case currentStateGeneration = "current_state_generation"
        case currentScreenshotGeneration = "current_screenshot_generation"
        case baseStateID = "base_state_id"
    }
}

public enum ObservationMode: String, Codable, Sendable {
    case none
    case axDiff = "ax_diff"
    case axFull = "ax_full"
    case screenshot
    case both
    case auto
}

public enum SettleMode: String, Codable, Sendable {
    case none
    case auto
    case fixed
}

public enum ImageProfile: String, Codable, Sendable {
    case none
    case compact
    case standard
    case region
}

public struct ObservationPolicy: Codable, Sendable, Equatable {
    public let mode: ObservationMode
    public let maxNodes: UInt16
    public let maxDepth: UInt8
    public let maxTextPerNode: UInt16
    public let maxTotalTextBytes: UInt32
    public let maxVisibleRowsPerContainer: UInt8
    public let settle: SettleMode
    public let settleTimeoutMilliseconds: UInt32
    public let imageProfile: ImageProfile
    public let region: Region?

    public init(
        mode: ObservationMode = .auto,
        maxNodes: UInt16 = defaultAXNodes,
        maxDepth: UInt8 = maximumAXDepth,
        maxTextPerNode: UInt16 = maximumAXTextPerNode,
        maxTotalTextBytes: UInt32 = defaultAXTotalTextBytes,
        maxVisibleRowsPerContainer: UInt8 = defaultAXVisibleRowsPerContainer,
        settle: SettleMode = .auto,
        settleTimeoutMilliseconds: UInt32 = maximumSettleTimeoutMilliseconds,
        imageProfile: ImageProfile = .compact,
        region: Region? = nil
    ) {
        self.mode = mode
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.maxTextPerNode = maxTextPerNode
        self.maxTotalTextBytes = maxTotalTextBytes
        self.maxVisibleRowsPerContainer = maxVisibleRowsPerContainer
        self.settle = settle
        self.settleTimeoutMilliseconds = settleTimeoutMilliseconds
        self.imageProfile = imageProfile
        self.region = region
    }

    public var hasValidParameters: Bool {
        maxNodes > 0 && maxNodes <= maximumAXNodes
            && maxDepth > 0 && maxDepth <= maximumAXDepth
            && maxTextPerNode > 0 && maxTextPerNode <= maximumAXTextPerNode
            && maxTotalTextBytes > 0 && maxTotalTextBytes <= maximumAXTotalTextBytes
            && maxVisibleRowsPerContainer > 0
            && maxVisibleRowsPerContainer <= maximumAXVisibleRowsPerContainer
            && settleTimeoutMilliseconds <= maximumSettleTimeoutMilliseconds
            && (settle == .none ? settleTimeoutMilliseconds == 0 : settleTimeoutMilliseconds > 0)
            && (region.map { $0.width > 0 && $0.height > 0 } ?? true)
            && ((imageProfile == .region) == (region != nil))
    }

    enum CodingKeys: String, CodingKey {
        case mode, settle, region
        case maxNodes = "max_nodes"
        case maxDepth = "max_depth"
        case maxTextPerNode = "max_text_per_node"
        case maxTotalTextBytes = "max_total_text_bytes"
        case maxVisibleRowsPerContainer = "max_visible_rows_per_container"
        case settleTimeoutMilliseconds = "settle_timeout_ms"
        case imageProfile = "image_profile"
    }
}

public struct ElementTarget: Codable, Sendable, Equatable {
    public let stateID: UUID
    public let stateGeneration: UInt64
    public let applicationDigest: String
    public let windowID: UInt32
    public let displayFingerprint: String
    public let elementIndex: UInt32

    public init(
        stateID: UUID,
        stateGeneration: UInt64,
        applicationDigest: String,
        windowID: UInt32,
        displayFingerprint: String,
        elementIndex: UInt32
    ) {
        self.stateID = stateID
        self.stateGeneration = stateGeneration
        self.applicationDigest = applicationDigest
        self.windowID = windowID
        self.displayFingerprint = displayFingerprint
        self.elementIndex = elementIndex
    }

    public var hasValidParameters: Bool {
        stateGeneration > 0
            && applicationDigest.utf8.count == 64
            && applicationDigest.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 70) || ($0 >= 97 && $0 <= 102)
            }
            && Self.validBoundedText(displayFingerprint, maximumCharacters: 256)
            && elementIndex < UInt32.max
    }

    private static func validBoundedText(_ value: String, maximumCharacters: Int) -> Bool {
        !value.isEmpty && value.count <= maximumCharacters
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    enum CodingKeys: String, CodingKey {
        case stateID = "state_id"
        case stateGeneration = "state_generation"
        case applicationDigest = "application_digest"
        case windowID = "window_id"
        case displayFingerprint = "display_fingerprint"
        case elementIndex = "element_index"
    }
}

public struct AccessibilityStateContext: Equatable, Sendable {
    public let stateID: UUID
    public let stateGeneration: UInt64
    public let applicationDigest: String
    public let windowID: UInt32
    public let displayFingerprint: String

    public init(
        stateID: UUID,
        stateGeneration: UInt64,
        applicationDigest: String,
        windowID: UInt32,
        displayFingerprint: String
    ) {
        self.stateID = stateID
        self.stateGeneration = stateGeneration
        self.applicationDigest = applicationDigest
        self.windowID = windowID
        self.displayFingerprint = displayFingerprint
    }

    public func matches(_ target: ElementTarget) -> Bool {
        stateID == target.stateID
            && stateGeneration == target.stateGeneration
            && applicationDigest == target.applicationDigest
            && windowID == target.windowID
            && displayFingerprint == target.displayFingerprint
    }
}

public enum SelectionType: String, Codable, Sendable {
    case text
    case cursorBefore = "cursor_before"
    case cursorAfter = "cursor_after"
}

public enum ScrollDirection: String, Codable, Sendable {
    case up, down, left, right
}

public enum ActionV2: Sendable, Equatable {
    case observe(application: String?)
    case coordinate(Action)
    case press(ElementTarget)
    case setValue(target: ElementTarget, value: String)
    case selectText(
        target: ElementTarget,
        text: String,
        prefix: String?,
        suffix: String?,
        selectionType: SelectionType
    )
    case scrollElement(target: ElementTarget, direction: ScrollDirection, pages: UInt8)
    case secondaryAction(target: ElementTarget, actionName: String)
    case launchApplication(String)
    case readClipboard

    public var hasValidParameters: Bool {
        switch self {
        case let .observe(application):
            application.map { Self.validBoundedText($0, maximumCharacters: 255) } ?? true
        case let .coordinate(action):
            action.hasValidParameters && Self.isCoordinateAction(action)
        case let .press(target): target.hasValidParameters
        case let .setValue(target, value):
            target.hasValidParameters && value.count <= 4_096
        case let .selectText(target, text, prefix, suffix, _):
            target.hasValidParameters
                && Self.validBoundedText(text, maximumCharacters: 4_096)
                && (prefix.map { $0.count <= 256 } ?? true)
                && (suffix.map { $0.count <= 256 } ?? true)
        case let .scrollElement(target, _, pages):
            target.hasValidParameters && (1 ... 10).contains(pages)
        case let .secondaryAction(target, actionName):
            target.hasValidParameters
                && Self.validBoundedText(actionName, maximumCharacters: 128)
        case let .launchApplication(application):
            Self.validApplicationSpecifier(application)
        case .readClipboard: true
        }
    }

    public var requiresForegroundApplication: Bool {
        switch self {
        case .observe, .launchApplication, .readClipboard:
            false
        case let .coordinate(action):
            action.requiresForegroundApplication
        case .press, .setValue, .selectText, .scrollElement, .secondaryAction:
            true
        }
    }

    /// Whether the coordinate key can create or select a different window.
    public var mayChangeFrontmostWindow: Bool {
        switch self {
        case .launchApplication: true
        case let .coordinate(action): action.mayChangeFrontmostWindow
        default: false
        }
    }

    /// Whether the coordinate shortcut is expected to create a distinct top-level window.
    public var requestsNewWindow: Bool {
        guard case let .coordinate(action) = self else { return false }
        return action.requestsNewWindow
    }

    /// Whether the action can close or replace the currently bound top-level window.
    public var mayCloseOrReplaceWindow: Bool {
        switch self {
        case .press, .secondaryAction: true
        case let .coordinate(action): action.mayCloseWindow
        default: false
        }
    }

    private static func validBoundedText(_ value: String, maximumCharacters: Int) -> Bool {
        !value.isEmpty && value.count <= maximumCharacters
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func validApplicationSpecifier(_ value: String) -> Bool {
        let forbidden = CharacterSet(charactersIn: "/:~;|&$<>`\\")
        return validBoundedText(value, maximumCharacters: 255)
            && value.utf8.count <= maximumApplicationSpecifierBytes
            && !value.unicodeScalars.contains(where: forbidden.contains)
    }

    private static func isCoordinateAction(_ action: Action) -> Bool {
        switch action {
        case .screenshot, .screenshotApplication, .readClipboard, .zoom: false
        default: true
        }
    }
}

extension ActionV2: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, application, action, target, value, text, prefix, suffix, direction, pages
        case selectionType = "selection_type"
        case actionName = "action_name"
    }

    private enum Kind: String, Codable {
        case observe, coordinate, press
        case setValue = "set_value"
        case selectText = "select_text"
        case scrollElement = "scroll_element"
        case secondaryAction = "secondary_action"
        case launchApplication = "launch_application"
        case readClipboard = "read_clipboard"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .observe:
            self = .observe(application: try container.decodeIfPresent(String.self, forKey: .application))
        case .coordinate:
            self = .coordinate(try container.decode(Action.self, forKey: .action))
        case .press:
            self = .press(try container.decode(ElementTarget.self, forKey: .target))
        case .setValue:
            self = .setValue(
                target: try container.decode(ElementTarget.self, forKey: .target),
                value: try container.decode(String.self, forKey: .value)
            )
        case .selectText:
            self = .selectText(
                target: try container.decode(ElementTarget.self, forKey: .target),
                text: try container.decode(String.self, forKey: .text),
                prefix: try container.decodeIfPresent(String.self, forKey: .prefix),
                suffix: try container.decodeIfPresent(String.self, forKey: .suffix),
                selectionType: try container.decode(SelectionType.self, forKey: .selectionType)
            )
        case .scrollElement:
            self = .scrollElement(
                target: try container.decode(ElementTarget.self, forKey: .target),
                direction: try container.decode(ScrollDirection.self, forKey: .direction),
                pages: try container.decode(UInt8.self, forKey: .pages)
            )
        case .secondaryAction:
            self = .secondaryAction(
                target: try container.decode(ElementTarget.self, forKey: .target),
                actionName: try container.decode(String.self, forKey: .actionName)
            )
        case .launchApplication:
            self = .launchApplication(try container.decode(String.self, forKey: .application))
        case .readClipboard: self = .readClipboard
        }
        guard hasValidParameters else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "v2 action parameters are outside the supported bounds"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .observe(application):
            try container.encode(Kind.observe, forKey: .type)
            try container.encodeIfPresent(application, forKey: .application)
        case let .coordinate(action):
            try container.encode(Kind.coordinate, forKey: .type)
            try container.encode(action, forKey: .action)
        case let .press(target):
            try container.encode(Kind.press, forKey: .type)
            try container.encode(target, forKey: .target)
        case let .setValue(target, value):
            try container.encode(Kind.setValue, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(value, forKey: .value)
        case let .selectText(target, text, prefix, suffix, selectionType):
            try container.encode(Kind.selectText, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(prefix, forKey: .prefix)
            try container.encodeIfPresent(suffix, forKey: .suffix)
            try container.encode(selectionType, forKey: .selectionType)
        case let .scrollElement(target, direction, pages):
            try container.encode(Kind.scrollElement, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(direction, forKey: .direction)
            try container.encode(pages, forKey: .pages)
        case let .secondaryAction(target, actionName):
            try container.encode(Kind.secondaryAction, forKey: .type)
            try container.encode(target, forKey: .target)
            try container.encode(actionName, forKey: .actionName)
        case let .launchApplication(application):
            try container.encode(Kind.launchApplication, forKey: .type)
            try container.encode(application, forKey: .application)
        case .readClipboard:
            try container.encode(Kind.readClipboard, forKey: .type)
        }
    }
}

public enum AccessibilityObservationKind: String, Codable, Sendable {
    case full, diff
}

public struct AccessibilityNode: Codable, Sendable, Equatable, Hashable {
    public let index: UInt32
    public let parentIndex: UInt32?
    public let depth: UInt8
    public let role: String
    public let title: String?
    public let label: String?
    public let value: String?
    public let placeholder: String?
    public let url: String?
    public let frame: [Int32]?
    public let settable: Bool
    public let actions: [String]

    public init(
        index: UInt32,
        parentIndex: UInt32?,
        depth: UInt8,
        role: String,
        title: String?,
        label: String?,
        value: String?,
        placeholder: String?,
        url: String?,
        frame: [Int32]?,
        settable: Bool,
        actions: [String]
    ) {
        self.index = index
        self.parentIndex = parentIndex
        self.depth = depth
        self.role = role
        self.title = title
        self.label = label
        self.value = value
        self.placeholder = placeholder
        self.url = url
        self.frame = frame
        self.settable = settable
        self.actions = actions
    }

    enum CodingKeys: String, CodingKey {
        case index, depth, role, title, label, value, placeholder, url, frame, settable, actions
        case parentIndex = "parent_index"
    }
}

public struct AccessibilityObservation: Codable, Sendable, Equatable {
    public let kind: AccessibilityObservationKind
    public let reset: Bool
    public let truncated: Bool
    public let nodes: [AccessibilityNode]
    public let removed: [UInt32]

    public init(
        kind: AccessibilityObservationKind,
        reset: Bool,
        truncated: Bool,
        nodes: [AccessibilityNode],
        removed: [UInt32]
    ) {
        self.kind = kind
        self.reset = reset
        self.truncated = truncated
        self.nodes = nodes
        self.removed = removed
    }
}

public enum SettleStatus: String, Codable, Sendable {
    case settled, timeout
    case notRequested = "not_requested"
}

public struct SettleResult: Codable, Sendable, Equatable {
    public let status: SettleStatus
    public let elapsedMilliseconds: UInt32

    public init(status: SettleStatus, elapsedMilliseconds: UInt32) {
        self.status = status
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    enum CodingKeys: String, CodingKey {
        case status
        case elapsedMilliseconds = "elapsed_ms"
    }
}

public struct ImagePayloadV2: Codable, Sendable, Equatable {
    public let base64Data: String
    public let mimeType: String
    public let pixelWidth: UInt16
    public let pixelHeight: UInt16
    public let profile: ImageProfile

    public init(
        base64Data: String,
        mimeType: String,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        profile: ImageProfile
    ) {
        self.base64Data = base64Data
        self.mimeType = mimeType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.profile = profile
    }

    enum CodingKeys: String, CodingKey {
        case base64Data = "base64_data"
        case mimeType = "mime_type"
        case pixelWidth = "pixel_width"
        case pixelHeight = "pixel_height"
        case profile
    }
}

public enum ResponseStatusV2: String, Codable, Sendable {
    case success, failed
}

public struct ActionResponseV2: Codable, Sendable, Equatable {
    public let requestID: UUID
    public let monotonicSequence: UInt64
    public let stateGeneration: UInt64
    public let screenshotGeneration: UInt64
    public let stateID: UUID?
    public let applicationDigest: String?
    public let windowID: UInt32?
    public let displayFingerprint: String?
    public let baseStateID: UUID?
    public let status: ResponseStatusV2
    public let message: String
    public let clipboard: String?
    public let observation: AccessibilityObservation?
    public let settle: SettleResult
    public let image: ImagePayloadV2?

    public init(
        requestID: UUID,
        monotonicSequence: UInt64,
        stateGeneration: UInt64,
        screenshotGeneration: UInt64,
        stateID: UUID?,
        applicationDigest: String?,
        windowID: UInt32?,
        displayFingerprint: String?,
        baseStateID: UUID?,
        status: ResponseStatusV2,
        message: String,
        clipboard: String? = nil,
        observation: AccessibilityObservation?,
        settle: SettleResult,
        image: ImagePayloadV2?
    ) {
        self.requestID = requestID
        self.monotonicSequence = monotonicSequence
        self.stateGeneration = stateGeneration
        self.screenshotGeneration = screenshotGeneration
        self.stateID = stateID
        self.applicationDigest = applicationDigest
        self.windowID = windowID
        self.displayFingerprint = displayFingerprint
        self.baseStateID = baseStateID
        self.status = status
        self.message = message
        self.clipboard = clipboard
        self.observation = observation
        self.settle = settle
        self.image = image
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case monotonicSequence = "monotonic_sequence"
        case stateGeneration = "state_generation"
        case screenshotGeneration = "screenshot_generation"
        case stateID = "state_id"
        case applicationDigest = "application_digest"
        case windowID = "window_id"
        case displayFingerprint = "display_fingerprint"
        case baseStateID = "base_state_id"
        case status, message, clipboard, observation, settle, image
    }
}
