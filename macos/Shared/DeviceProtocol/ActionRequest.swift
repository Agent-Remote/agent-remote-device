import Foundation

public let protocolVersion: UInt8 = 1
public let maximumFrameBytes = 16 * 1024 * 1024
public let maximumDeviceSessionGeneration = UInt64(Int64.max)
public let maximumActiveDeviceSessionGeneration = maximumDeviceSessionGeneration - 1

public struct ActionRequest: Codable, Sendable, Equatable {
    public let version: UInt8
    public let requestID: UUID
    public let context: RequestContext
    public let leaseUntil: Date
    public let action: Action

    public init(
        version: UInt8 = protocolVersion,
        requestID: UUID,
        context: RequestContext,
        leaseUntil: Date,
        action: Action
    ) {
        self.version = version
        self.requestID = requestID
        self.context = context
        self.leaseUntil = leaseUntil
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case context
        case leaseUntil = "lease_until"
        case action
    }
}

public struct RequestContext: Codable, Sendable, Equatable {
    public let userID: UUID
    public let deviceID: UUID
    public let toolSessionID: UUID
    public let deviceSessionID: UUID
    public let nodeID: UUID
    public let platform: Platform
    public let generation: UInt64
    public let monotonicSequence: UInt64
    public let currentScreenshotGeneration: UInt64

    public init(
        userID: UUID,
        deviceID: UUID,
        toolSessionID: UUID,
        deviceSessionID: UUID,
        nodeID: UUID,
        platform: Platform,
        generation: UInt64,
        monotonicSequence: UInt64,
        currentScreenshotGeneration: UInt64
    ) {
        self.userID = userID
        self.deviceID = deviceID
        self.toolSessionID = toolSessionID
        self.deviceSessionID = deviceSessionID
        self.nodeID = nodeID
        self.platform = platform
        self.generation = generation
        self.monotonicSequence = monotonicSequence
        self.currentScreenshotGeneration = currentScreenshotGeneration
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case deviceID = "device_id"
        case toolSessionID = "tool_session_id"
        case deviceSessionID = "device_session_id"
        case nodeID = "node_id"
        case platform, generation
        case monotonicSequence = "monotonic_sequence"
        case currentScreenshotGeneration = "current_screenshot_generation"
    }
}

public enum Platform: String, Codable, Sendable {
    case macos
}

public enum Action: Sendable, Equatable {
    case screenshot
    case screenshotApplication(String)
    case readClipboard
    case leftClick(Point)
    case type(String)
    case key(String)
    case mouseMove(Point)
    case scroll(deltaX: Int32, deltaY: Int32, coordinate: Point?)
    case leftClickDrag(start: Point, end: Point, durationMilliseconds: UInt32?)
    case rightClick(Point)
    case middleClick(Point)
    case doubleClick(Point)
    case tripleClick(Point)
    case leftMouseDown
    case leftMouseUp
    case holdKey(key: String, durationMilliseconds: UInt32)
    case wait(UInt32)
    case zoom(Region)

    public var hasValidParameters: Bool {
        switch self {
        case let .screenshotApplication(application):
            !application.isEmpty && application.count <= 255
                && application == application.trimmingCharacters(in: .whitespacesAndNewlines)
                && !application.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        case let .type(text):
            !text.isEmpty && text.count <= 4_096
        case let .key(key):
            Self.isValidKey(key)
        case let .scroll(deltaX, deltaY, _):
            (-10_000 ... 10_000).contains(deltaX) && (-10_000 ... 10_000).contains(deltaY)
        case let .leftClickDrag(_, _, durationMilliseconds):
            durationMilliseconds.map { (100 ... 5_000).contains($0) } ?? true
        case let .holdKey(key, durationMilliseconds):
            Self.isValidKey(key) && (50 ... 5_000).contains(durationMilliseconds)
        case let .wait(durationMilliseconds):
            (50 ... 10_000).contains(durationMilliseconds)
        case let .zoom(region):
            region.width > 0 && region.height > 0
        default:
            true
        }
    }

    public var requiresModelVisibleScreenshot: Bool {
        switch self {
        case .leftClick, .mouseMove, .leftClickDrag, .rightClick, .middleClick,
             .doubleClick, .tripleClick, .leftMouseDown:
            true
        case let .scroll(_, _, coordinate):
            coordinate != nil
        default:
            false
        }
    }

    public var requiresForegroundApplication: Bool {
        switch self {
        case .screenshot, .screenshotApplication, .readClipboard, .wait, .zoom:
            false
        default:
            true
        }
    }

    /// Whether normal HID routing is required because the key can change the
    /// frontmost window within the target application.
    public var mayChangeFrontmostWindow: Bool {
        guard case let .key(key) = self else { return false }
        return Self.isFrontmostWindowShortcut(key)
    }

    /// Whether the shortcut is expected to create a distinct top-level window.
    public var requestsNewWindow: Bool {
        guard case let .key(key) = self else { return false }
        return Self.isNewWindowShortcut(key)
    }

    /// Whether the shortcut can close the currently bound top-level window.
    public var mayCloseWindow: Bool {
        guard case let .key(key) = self else { return false }
        return Self.isWindowClosingShortcut(key)
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 64 else { return false }
        let components = key.components(separatedBy: "+").map { $0.uppercased() }
        guard let rawKeyName = components.last, !rawKeyName.isEmpty else { return false }
        let validModifiers = Set([
            "CMD", "COMMAND", "SUPER", "CTRL", "CONTROL", "ALT", "OPTION", "SHIFT",
        ])
        guard components.dropLast().allSatisfy(validModifiers.contains) else { return false }
        let keyName = switch rawKeyName {
        case "PAGE UP", "PAGE_UP", "PAGE-UP": "PAGEUP"
        case "PAGE DOWN", "PAGE_DOWN", "PAGE-DOWN": "PAGEDOWN"
        default: rawKeyName
        }
        return validKeyNames.contains(keyName)
    }

    private static func isFrontmostWindowShortcut(_ key: String) -> Bool {
        let components = key.uppercased().split(separator: "+").map(String.init)
        guard let keyName = components.last else { return false }
        let modifiers = Set(components.dropLast())
        let commandModifiers: Set<String> = ["CMD", "COMMAND", "SUPER"]
        guard !modifiers.isDisjoint(with: commandModifiers),
              modifiers.isSubset(of: commandModifiers.union(["SHIFT"]))
        else { return false }
        return keyName == "N" || keyName == "`"
    }

    private static func isNewWindowShortcut(_ key: String) -> Bool {
        let components = key.uppercased().split(separator: "+").map(String.init)
        guard let keyName = components.last else { return false }
        let modifiers = Set(components.dropLast())
        let commandModifiers: Set<String> = ["CMD", "COMMAND", "SUPER"]
        return keyName == "N"
            && !modifiers.isDisjoint(with: commandModifiers)
            && modifiers.isSubset(of: commandModifiers.union(["SHIFT"]))
    }

    private static func isWindowClosingShortcut(_ key: String) -> Bool {
        let components = key.uppercased().split(separator: "+").map(String.init)
        guard let keyName = components.last else { return false }
        let modifiers = Set(components.dropLast())
        let commandModifiers: Set<String> = ["CMD", "COMMAND", "SUPER"]
        return keyName == "W"
            && !modifiers.isDisjoint(with: commandModifiers)
            && modifiers.isSubset(of: commandModifiers.union(["SHIFT"]))
    }

    private static let validKeyNames = Set([
        "A", "S", "D", "F", "H", "G", "Z", "X", "C", "V", "B", "Q", "W", "E",
        "R", "Y", "T", "1", "2", "3", "4", "6", "5", "=", "9", "7", "-", "8",
        "0", "]", "O", "U", "[", "I", "P", "L", "J", "'", "K", ";", "\\", ",",
        "/", "N", "M", ".", "`", "TAB", "SPACE", "DELETE", "BACKSPACE", "ESC",
        "ESCAPE", "RETURN", "ENTER", "CMD", "COMMAND", "SUPER", "SHIFT", "ALT",
        "OPTION", "CTRL", "CONTROL", "LEFT", "RIGHT", "DOWN", "UP", "PAGEUP",
        "PAGEDOWN", "HOME", "END",
    ])
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, application, coordinate, text, key, start, end, region
        case deltaX = "delta_x"
        case deltaY = "delta_y"
        case durationMS = "duration_ms"
    }

    private enum Kind: String, Codable {
        case screenshot
        case screenshotApplication = "screenshot_application"
        case readClipboard = "read_clipboard"
        case leftClick = "left_click"
        case type, key
        case mouseMove = "mouse_move"
        case scroll
        case leftClickDrag = "left_click_drag"
        case rightClick = "right_click"
        case middleClick = "middle_click"
        case doubleClick = "double_click"
        case tripleClick = "triple_click"
        case leftMouseDown = "left_mouse_down"
        case leftMouseUp = "left_mouse_up"
        case holdKey = "hold_key"
        case wait, zoom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .screenshot: self = .screenshot
        case .screenshotApplication:
            self = .screenshotApplication(try container.decode(String.self, forKey: .application))
        case .readClipboard: self = .readClipboard
        case .leftClick: self = .leftClick(try container.decode(Point.self, forKey: .coordinate))
        case .type: self = .type(try container.decode(String.self, forKey: .text))
        case .key: self = .key(try container.decode(String.self, forKey: .key))
        case .mouseMove: self = .mouseMove(try container.decode(Point.self, forKey: .coordinate))
        case .scroll:
            self = .scroll(
                deltaX: try container.decode(Int32.self, forKey: .deltaX),
                deltaY: try container.decode(Int32.self, forKey: .deltaY),
                coordinate: try container.decodeIfPresent(Point.self, forKey: .coordinate)
            )
        case .leftClickDrag:
            self = .leftClickDrag(
                start: try container.decode(Point.self, forKey: .start),
                end: try container.decode(Point.self, forKey: .end),
                durationMilliseconds: try container.decodeIfPresent(UInt32.self, forKey: .durationMS)
            )
        case .rightClick: self = .rightClick(try container.decode(Point.self, forKey: .coordinate))
        case .middleClick: self = .middleClick(try container.decode(Point.self, forKey: .coordinate))
        case .doubleClick: self = .doubleClick(try container.decode(Point.self, forKey: .coordinate))
        case .tripleClick: self = .tripleClick(try container.decode(Point.self, forKey: .coordinate))
        case .leftMouseDown: self = .leftMouseDown
        case .leftMouseUp: self = .leftMouseUp
        case .holdKey:
            self = .holdKey(
                key: try container.decode(String.self, forKey: .key),
                durationMilliseconds: try container.decode(UInt32.self, forKey: .durationMS)
            )
        case .wait: self = .wait(try container.decode(UInt32.self, forKey: .durationMS))
        case .zoom: self = .zoom(try container.decode(Region.self, forKey: .region))
        }
        guard hasValidParameters else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "action parameters are outside the supported bounds"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .screenshot: try container.encode(Kind.screenshot, forKey: .type)
        case let .screenshotApplication(application):
            try container.encode(Kind.screenshotApplication, forKey: .type)
            try container.encode(application, forKey: .application)
        case .readClipboard:
            try container.encode(Kind.readClipboard, forKey: .type)
        case let .leftClick(point):
            try container.encode(Kind.leftClick, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case let .type(text):
            try container.encode(Kind.type, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .key(key):
            try container.encode(Kind.key, forKey: .type)
            try container.encode(key, forKey: .key)
        case let .mouseMove(point):
            try container.encode(Kind.mouseMove, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case let .scroll(deltaX, deltaY, coordinate):
            try container.encode(Kind.scroll, forKey: .type)
            try container.encode(deltaX, forKey: .deltaX)
            try container.encode(deltaY, forKey: .deltaY)
            try container.encodeIfPresent(coordinate, forKey: .coordinate)
        case let .leftClickDrag(start, end, durationMilliseconds):
            try container.encode(Kind.leftClickDrag, forKey: .type)
            try container.encode(start, forKey: .start)
            try container.encode(end, forKey: .end)
            try container.encodeIfPresent(durationMilliseconds, forKey: .durationMS)
        case let .rightClick(point):
            try container.encode(Kind.rightClick, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case let .middleClick(point):
            try container.encode(Kind.middleClick, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case let .doubleClick(point):
            try container.encode(Kind.doubleClick, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case let .tripleClick(point):
            try container.encode(Kind.tripleClick, forKey: .type)
            try container.encode(point, forKey: .coordinate)
        case .leftMouseDown:
            try container.encode(Kind.leftMouseDown, forKey: .type)
        case .leftMouseUp:
            try container.encode(Kind.leftMouseUp, forKey: .type)
        case let .holdKey(key, durationMilliseconds):
            try container.encode(Kind.holdKey, forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(durationMilliseconds, forKey: .durationMS)
        case let .wait(duration):
            try container.encode(Kind.wait, forKey: .type)
            try container.encode(duration, forKey: .durationMS)
        case let .zoom(region):
            try container.encode(Kind.zoom, forKey: .type)
            try container.encode(region, forKey: .region)
        }
    }
}

public struct Point: Codable, Sendable, Equatable {
    public let x: UInt16
    public let y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(UInt16.self)
        y = try container.decode(UInt16.self)
        guard container.isAtEnd else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "point must contain exactly two values") }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }
}

public struct Region: Codable, Sendable, Equatable {
    public let x: UInt16
    public let y: UInt16
    public let width: UInt16
    public let height: UInt16

    public init(x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(UInt16.self)
        y = try container.decode(UInt16.self)
        width = try container.decode(UInt16.self)
        height = try container.decode(UInt16.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "region must contain exactly four values"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(width)
        try container.encode(height)
    }
}
