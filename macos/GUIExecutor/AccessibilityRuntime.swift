import AppKit
import ApplicationServices
import DeviceProtocol
import DeviceSecurity
import Foundation

public enum AccessibilityFailure: Error, Equatable, Sendable {
    case permissionMissing
    case windowUnavailable
    case staleTarget
    case elementUnavailable
    case actionUnavailable
    case secureField
    case valueNotSettable
    case textNotFound
    case ambiguousText
    case invalidSelection
    case operationFailed

    public var diagnosticCode: String {
        switch self {
        case .permissionMissing: "accessibility_permission_missing"
        case .windowUnavailable: "accessibility_window_unavailable"
        case .staleTarget: "stale_element_target"
        case .elementUnavailable: "accessibility_element_unavailable"
        case .actionUnavailable: "accessibility_action_unavailable"
        case .secureField: "secure_field_requires_user_handoff"
        case .valueNotSettable: "accessibility_value_not_settable"
        case .textNotFound: "selection_text_not_found"
        case .ambiguousText: "selection_text_is_ambiguous"
        case .invalidSelection: "selection_range_invalid"
        case .operationFailed: "accessibility_operation_failed"
        }
    }
}

public struct AccessibilitySnapshotResult: Sendable {
    public let context: AccessibilityStateContext
    public let observation: AccessibilityObservation

    public init(context: AccessibilityStateContext, observation: AccessibilityObservation) {
        self.context = context
        self.observation = observation
    }
}

@MainActor
public final class AccessibilityRuntime {
    private struct Snapshot {
        let context: AccessibilityStateContext
        let nodes: [AccessibilityNode]
        let elements: [UInt32: AXUIElement]
    }

    private var current: Snapshot?

    public init() {}

    public func clear() {
        current = nil
    }

    public func observe(
        context window: WindowContext,
        stateGeneration: UInt64,
        baseStateID: UUID?,
        policy: ObservationPolicy
    ) throws -> AccessibilitySnapshotResult {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        guard policy.hasValidParameters else { throw AccessibilityFailure.operationFailed }
        let root = try focusedWindow(processID: window.processID, matching: window.windowFrame)
        var renderer = BoundedAXRenderer(
            policy: policy,
            priorElements: current?.elements ?? [:]
        )
        let rendered = renderer.render(root: root, windowFrame: window.windowFrame)
        let stateID = UUID()
        let context = AccessibilityStateContext(
            stateID: stateID,
            stateGeneration: stateGeneration,
            applicationDigest: window.application.stableDigest,
            windowID: window.windowID,
            displayFingerprint: window.displayFingerprint
        )

        let canDiff = baseStateID != nil
            && baseStateID == current?.context.stateID
            && current?.context.applicationDigest == context.applicationDigest
            && current?.context.windowID == context.windowID
            && current?.context.displayFingerprint == context.displayFingerprint
        let observation: AccessibilityObservation
        if canDiff, let previous = current {
            observation = Self.diff(previous: previous.nodes, current: rendered.nodes, truncated: rendered.truncated)
        } else {
            observation = AccessibilityObservation(
                kind: .full,
                reset: baseStateID != nil,
                truncated: rendered.truncated,
                nodes: rendered.nodes,
                removed: []
            )
        }
        current = Snapshot(context: context, nodes: rendered.nodes, elements: rendered.elements)
        return AccessibilitySnapshotResult(context: context, observation: observation)
    }

    public func perform(_ action: ActionV2, target: ElementTarget) throws {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        guard let current, current.context.matches(target) else {
            throw AccessibilityFailure.staleTarget
        }
        guard let element = current.elements[target.elementIndex] else {
            throw AccessibilityFailure.elementUnavailable
        }
        switch action {
        case .press:
            try performNamedAction(kAXPressAction as String, on: element)
        case let .setValue(_, value):
            try rejectSecure(element)
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(
                element,
                kAXValueAttribute as CFString,
                &settable
            ) == .success, settable.boolValue else {
                throw AccessibilityFailure.valueNotSettable
            }
            guard AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                value as CFString
            ) == .success else {
                throw AccessibilityFailure.operationFailed
            }
        case let .selectText(_, text, prefix, suffix, selectionType):
            try selectText(
                text,
                prefix: prefix,
                suffix: suffix,
                selectionType: selectionType,
                in: element
            )
        case let .scrollElement(_, direction, pages):
            let name = switch direction {
            case .up: "AXScrollUpByPage"
            case .down: "AXScrollDownByPage"
            case .left: "AXScrollLeftByPage"
            case .right: "AXScrollRightByPage"
            }
            for _ in 0 ..< pages {
                try performNamedAction(name, on: element)
            }
        case let .secondaryAction(_, actionName):
            try performNamedAction(actionName, on: element)
        default:
            throw AccessibilityFailure.actionUnavailable
        }
    }

    public func stabilityFingerprint(
        context: WindowContext,
        policy: ObservationPolicy
    ) throws -> Int {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        let root = try focusedWindow(processID: context.processID, matching: context.windowFrame)
        var renderer = BoundedAXRenderer(
            policy: policy,
            priorElements: current?.elements ?? [:]
        )
        let rendered = renderer.render(root: root, windowFrame: context.windowFrame)
        var hasher = Hasher()
        hasher.combine(rendered.truncated)
        for node in rendered.nodes {
            hasher.combine(node)
        }
        return hasher.finalize()
    }

    private func focusedWindow(processID: pid_t, matching expectedFrame: CGRect) throws -> AXUIElement {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        enableDynamicAccessibility(on: application)
        if let focused: AXUIElement = attribute(kAXFocusedWindowAttribute, from: application),
           windowFrame(focused).map({ Self.windowMatchScore($0, expectedFrame) >= 0.7 }) == true
        {
            return focused
        }
        let windows: [AXUIElement] = attribute(kAXWindowsAttribute, from: application) ?? []
        let candidates = windows.compactMap { window -> (AXUIElement, CGFloat)? in
            guard let frame = windowFrame(window) else { return nil }
            return (window, Self.windowMatchScore(frame, expectedFrame))
        }
        guard let match = candidates.max(by: { $0.1 < $1.1 }), match.1 >= 0.7 else {
            throw AccessibilityFailure.windowUnavailable
        }
        return match.0
    }

    private func enableDynamicAccessibility(on application: AXUIElement) {
        // Chromium, Electron and WebKit surfaces may expose a cached or partial
        // tree until an assistive client opts into their dynamic AX mode.
        for attributeName in ["AXEnhancedUserInterface", "AXManualAccessibility"] {
            _ = AXUIElementSetAttributeValue(
                application,
                attributeName as CFString,
                kCFBooleanTrue
            )
        }
    }

    private func windowFrame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = attribute(kAXPositionAttribute, from: element),
              let sizeValue: AXValue = attribute(kAXSizeAttribute, from: element)
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    static func windowMatchScore(_ left: CGRect, _ right: CGRect) -> CGFloat {
        guard left.width > 0, left.height > 0, right.width > 0, right.height > 0,
              !left.isInfinite, !right.isInfinite,
              !left.isNull, !right.isNull
        else { return 0 }
        let intersection = left.intersection(right)
        guard !intersection.isNull, !intersection.isInfinite,
              intersection.width > 0, intersection.height > 0
        else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = left.width * left.height + right.width * right.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private func performNamedAction(_ name: String, on element: AXUIElement) throws {
        var values: CFArray?
        guard AXUIElementCopyActionNames(element, &values) == .success,
              let actions = values as? [String],
              actions.contains(name)
        else {
            throw AccessibilityFailure.actionUnavailable
        }
        guard AXUIElementPerformAction(element, name as CFString) == .success else {
            throw AccessibilityFailure.operationFailed
        }
    }

    private func rejectSecure(_ element: AXUIElement) throws {
        let role: String? = attribute(kAXRoleAttribute, from: element)
        let subrole: String? = attribute(kAXSubroleAttribute, from: element)
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" {
            throw AccessibilityFailure.secureField
        }
    }

    private func selectText(
        _ text: String,
        prefix: String?,
        suffix: String?,
        selectionType: SelectionType,
        in element: AXUIElement
    ) throws {
        try rejectSecure(element)
        guard let value: String = attribute(kAXValueAttribute, from: element) else {
            throw AccessibilityFailure.valueNotSettable
        }
        let source = value as NSString
        var searchRange = NSRange(location: 0, length: source.length)
        var matches: [NSRange] = []
        while searchRange.length > 0 {
            let match = source.range(of: text, options: [], range: searchRange)
            if match.location == NSNotFound { break }
            let prefixMatches = prefix.map {
                match.location >= ($0 as NSString).length
                    && source.substring(with: NSRange(
                        location: match.location - ($0 as NSString).length,
                        length: ($0 as NSString).length
                    )) == $0
            } ?? true
            let suffixMatches = suffix.map {
                let start = NSMaxRange(match)
                return start + ($0 as NSString).length <= source.length
                    && source.substring(with: NSRange(
                        location: start,
                        length: ($0 as NSString).length
                    )) == $0
            } ?? true
            if prefixMatches && suffixMatches { matches.append(match) }
            let next = NSMaxRange(match)
            if next >= source.length { break }
            searchRange = NSRange(location: next, length: source.length - next)
        }
        guard !matches.isEmpty else { throw AccessibilityFailure.textNotFound }
        guard matches.count == 1, let match = matches.first else {
            throw AccessibilityFailure.ambiguousText
        }
        var range = switch selectionType {
        case .text: CFRange(location: match.location, length: match.length)
        case .cursorBefore: CFRange(location: match.location, length: 0)
        case .cursorAfter: CFRange(location: NSMaxRange(match), length: 0)
        }
        guard let rangeValue = AXValueCreate(.cfRange, &range) else {
            throw AccessibilityFailure.invalidSelection
        }
        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        ) == .success else {
            throw AccessibilityFailure.operationFailed
        }
    }

    static func diff(
        previous: [AccessibilityNode],
        current: [AccessibilityNode],
        truncated: Bool
    ) -> AccessibilityObservation {
        let previousByIndex = Dictionary(uniqueKeysWithValues: previous.map { ($0.index, $0) })
        let currentByIndex = Dictionary(uniqueKeysWithValues: current.map { ($0.index, $0) })
        let changed = current.filter { previousByIndex[$0.index] != $0 }
        let removed = previous.compactMap { currentByIndex[$0.index] == nil ? $0.index : nil }
        let changeCount = changed.count + removed.count
        if changeCount * 2 > max(current.count, 1) {
            return AccessibilityObservation(
                kind: .full,
                reset: true,
                truncated: truncated,
                nodes: current,
                removed: []
            )
        }
        return AccessibilityObservation(
            kind: .diff,
            reset: false,
            truncated: truncated,
            nodes: changed,
            removed: removed
        )
    }
}

private struct BoundedAXRenderer {
    private static let snapshotAttributeNames = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXHiddenAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXRowsAttribute as String,
        "AXVisibleChildren",
        kAXChildrenAttribute as String,
        "AXContents",
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXPlaceholderValueAttribute as String,
        "AXURL",
    ]

    let policy: ObservationPolicy
    let priorElementsByHash: [UInt: [(UInt32, AXUIElement)]]
    let deadline: ContinuousClock.Instant
    private(set) var nodes: [AccessibilityNode] = []
    private(set) var elements: [UInt32: AXUIElement] = [:]
    private var usedIndexes: Set<UInt32> = []
    private var seenElementsByHash: [UInt: [AXUIElement]] = [:]
    private(set) var textBytes = 0
    private(set) var truncated = false

    init(policy: ObservationPolicy, priorElements: [UInt32: AXUIElement]) {
        self.policy = policy
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        priorElementsByHash = Dictionary(grouping: priorElements.sorted { $0.key < $1.key }) {
            CFHash($0.value)
        }
    }

    mutating func render(
        root: AXUIElement,
        windowFrame: CGRect
    ) -> (nodes: [AccessibilityNode], elements: [UInt32: AXUIElement], truncated: Bool) {
        visit(
            root,
            parentIndex: nil,
            depth: 0,
            windowFrame: windowFrame,
            ancestorVisible: true
        )
        return (nodes, elements, truncated)
    }

    private mutating func visit(
        _ element: AXUIElement,
        parentIndex: UInt32?,
        depth: UInt8,
        windowFrame: CGRect,
        ancestorVisible: Bool
    ) {
        guard ContinuousClock.now < deadline,
              nodes.count < Int(policy.maxNodes),
              depth <= policy.maxDepth,
              textBytes < Int(policy.maxTotalTextBytes)
        else {
            truncated = true
            return
        }
        guard markSeen(element) else { return }
        let snapshot = snapshotAttributes(of: element)
        let rawRole: String = snapshot[kAXRoleAttribute as String] as? String ?? "AXUnknown"
        let subrole = snapshot[kAXSubroleAttribute as String] as? String
        let secure = rawRole == "AXSecureTextField" || subrole == "AXSecureTextField"
        let hidden = snapshot[kAXHiddenAttribute as String] as? Bool ?? false
        let screenFrame = elementFrame(snapshot)
        let visible = AccessibilityVisibility.isVisible(
            hidden: hidden,
            frame: screenFrame,
            windowFrame: windowFrame,
            ancestorVisible: ancestorVisible
        )
        guard visible else { return }

        let children = childElements(snapshot: snapshot, role: rawRole)
        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var actionValues: CFArray?
        _ = AXUIElementCopyActionNames(element, &actionValues)
        let rawActions = (actionValues as? [String]) ?? []
        let rawTitle = snapshot[kAXTitleAttribute as String] as? String
        let rawLabel = snapshot[kAXDescriptionAttribute as String] as? String
        let rawValue = secure ? nil : stringValue(snapshot[kAXValueAttribute as String])
        let rawPlaceholder = snapshot[kAXPlaceholderValueAttribute as String] as? String
        let rawURL = secure ? nil : stringValue(snapshot["AXURL"])
        let hasSemanticText = [rawTitle, rawLabel, rawValue, rawPlaceholder, rawURL]
            .contains { $0?.isEmpty == false }

        if AccessibilityTraversal.shouldElideWrapper(
            role: rawRole,
            hasSemanticText: hasSemanticText,
            isSettable: settable.boolValue,
            actions: rawActions,
            childCount: children.count
        ), let child = children.first {
            visit(
                child,
                parentIndex: parentIndex,
                depth: depth,
                windowFrame: windowFrame,
                ancestorVisible: true
            )
            return
        }

        guard let index = allocateIndex(for: element) else {
            truncated = true
            return
        }
        let role = bounded(rawRole, maximumCharacters: 80) ?? "?"
        let actions = rawActions
            .prefix(16)
            .compactMap { bounded($0, maximumCharacters: 128) }
        let node = AccessibilityNode(
            index: index,
            parentIndex: parentIndex,
            depth: depth,
            role: role,
            title: bounded(rawTitle, maximumCharacters: Int(policy.maxTextPerNode)),
            label: bounded(rawLabel, maximumCharacters: Int(policy.maxTextPerNode)),
            value: bounded(rawValue, maximumCharacters: Int(policy.maxTextPerNode)),
            placeholder: bounded(rawPlaceholder, maximumCharacters: Int(policy.maxTextPerNode)),
            url: bounded(rawURL, maximumCharacters: Int(policy.maxTextPerNode)),
            frame: relativeFrame(screenFrame, windowFrame: windowFrame),
            settable: !secure && settable.boolValue,
            actions: actions
        )
        nodes.append(node)
        elements[index] = element

        guard depth < policy.maxDepth else {
            if !children.isEmpty { truncated = true }
            return
        }
        let maximumChildren = AccessibilityTraversal.usesRowBudget(role: rawRole)
            ? Int(policy.maxVisibleRowsPerContainer)
            : children.count
        if children.count > maximumChildren { truncated = true }
        for child in children.prefix(maximumChildren) {
            visit(
                child,
                parentIndex: index,
                depth: depth + 1,
                windowFrame: windowFrame,
                ancestorVisible: true
            )
            if nodes.count >= Int(policy.maxNodes) { break }
        }
    }

    private mutating func allocateIndex(for element: AXUIElement) -> UInt32? {
        if let preferred = priorElementsByHash[CFHash(element)]?
            .first(where: { CFEqual($0.1, element) })?
            .0,
            preferred < UInt32(policy.maxNodes),
            usedIndexes.insert(preferred).inserted
        {
            return preferred
        }
        for candidate in UInt32(0) ..< UInt32(policy.maxNodes)
            where usedIndexes.insert(candidate).inserted
        {
            return candidate
        }
        return nil
    }

    private mutating func markSeen(_ element: AXUIElement) -> Bool {
        let hash = CFHash(element)
        if seenElementsByHash[hash]?.contains(where: { CFEqual($0, element) }) == true {
            return false
        }
        seenElementsByHash[hash, default: []].append(element)
        return true
    }

    private func childElements(snapshot: [String: Any], role: String) -> [AXUIElement] {
        let rows = snapshot[kAXRowsAttribute as String] as? [AXUIElement] ?? []
        let visibleChildren = snapshot["AXVisibleChildren"] as? [AXUIElement] ?? []
        let attributes = AccessibilityTraversal.childAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visibleChildren.isEmpty
        )
        var result: [AXUIElement] = []
        for name in attributes {
            let values: [AXUIElement]
            if name == kAXRowsAttribute as String {
                values = rows
            } else if name == "AXVisibleChildren" {
                values = visibleChildren
            } else {
                values = snapshot[name] as? [AXUIElement] ?? []
            }
            for child in values where !result.contains(where: { CFEqual($0, child) }) {
                result.append(child)
            }
        }
        return result
    }

    private mutating func bounded(_ value: String?, maximumCharacters: Int) -> String? {
        guard let value, !value.isEmpty, textBytes < Int(policy.maxTotalTextBytes) else {
            return nil
        }
        let characterBounded = String(value.prefix(maximumCharacters))
        let remaining = Int(policy.maxTotalTextBytes) - textBytes
        var result = ""
        var resultBytes = 0
        for character in characterBounded {
            let count = String(character).utf8.count
            if resultBytes + count > remaining { break }
            result.append(character)
            resultBytes += count
        }
        guard !result.isEmpty else { return nil }
        textBytes += result.utf8.count
        if result != value { truncated = true }
        return result
    }

    private func snapshotAttributes(of element: AXUIElement) -> [String: Any] {
        var copiedValues: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            Self.snapshotAttributeNames as CFArray,
            [],
            &copiedValues
        ) == .success,
            let values = copiedValues as? [Any],
            values.count == Self.snapshotAttributeNames.count
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(Self.snapshotAttributeNames, values))
    }

    private func elementFrame(_ snapshot: [String: Any]) -> CGRect? {
        guard let rawPosition = snapshot[kAXPositionAttribute as String],
              let rawSize = snapshot[kAXSizeAttribute as String],
              CFGetTypeID(rawPosition as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(rawSize as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func relativeFrame(_ frame: CGRect?, windowFrame: CGRect) -> [Int32]? {
        guard let frame else { return nil }
        return [
            clampedInt32(frame.minX - windowFrame.minX),
            clampedInt32(frame.minY - windowFrame.minY),
            clampedInt32(frame.width),
            clampedInt32(frame.height),
        ]
    }
}

enum AccessibilityTraversal {
    static func childAttributes(
        role: String,
        hasRows: Bool,
        hasVisibleChildren: Bool
    ) -> [String] {
        if hasRows, usesRowsAsPrimary(role: role) {
            return [kAXRowsAttribute as String, "AXVisibleChildren", "AXContents"]
        }
        if hasVisibleChildren, usesVisibleChildrenAsPrimary(role: role) {
            return ["AXVisibleChildren", kAXRowsAttribute as String, "AXContents"]
        }
        return [kAXChildrenAttribute as String, kAXRowsAttribute as String, "AXContents", "AXVisibleChildren"]
    }

    static func usesRowBudget(role: String) -> Bool {
        ["AXTable", "AXList", "AXOutline", "AXBrowser"].contains(role)
    }

    static func shouldElideWrapper(
        role: String,
        hasSemanticText: Bool,
        isSettable: Bool,
        actions: [String],
        childCount: Int
    ) -> Bool {
        ["AXGroup", "AXUnknown", "AXGenericElement"].contains(role)
            && !hasSemanticText
            && !isSettable
            && actions.isEmpty
            && childCount == 1
    }

    private static func usesRowsAsPrimary(role: String) -> Bool {
        usesRowBudget(role: role)
    }

    private static func usesVisibleChildrenAsPrimary(role: String) -> Bool {
        ["AXList", "AXTable", "AXOutline", "AXBrowser", "AXWebArea", "AXScrollArea"]
            .contains(role)
    }
}

enum AccessibilityVisibility {
    static func isVisible(
        hidden: Bool,
        frame: CGRect?,
        windowFrame: CGRect,
        ancestorVisible: Bool
    ) -> Bool {
        guard ancestorVisible, !hidden else { return false }
        guard let frame else { return true }
        return frame.width > 0 && frame.height > 0 && frame.intersects(windowFrame)
    }
}

private func attributeValue(_ name: String, from element: AXUIElement) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
        return nil
    }
    return value
}

private func attribute<T>(_ name: String, from element: AXUIElement) -> T? {
    attributeValue(name, from: element) as? T
}

private func stringValue(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? URL { return value.absoluteString }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func clampedInt32(_ value: CGFloat) -> Int32 {
    Int32(clamping: Int64(value.rounded()))
}
