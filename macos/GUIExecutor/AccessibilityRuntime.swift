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
    public let baseHadPageIdentity: Bool
    public let currentHasPageIdentity: Bool

    public init(
        context: AccessibilityStateContext,
        observation: AccessibilityObservation,
        baseHadPageIdentity: Bool,
        currentHasPageIdentity: Bool
    ) {
        self.context = context
        self.observation = observation
        self.baseHadPageIdentity = baseHadPageIdentity
        self.currentHasPageIdentity = currentHasPageIdentity
    }
}

public struct AccessibilityStabilityFingerprint: Equatable, Sendable {
    public let content: Int
    public let meaningful: Int
    public let trackedElementPresent: Bool?
    public let trackedElementContent: Int?

    public init(
        content: Int,
        meaningful: Int,
        trackedElementPresent: Bool? = nil,
        trackedElementContent: Int? = nil
    ) {
        self.content = content
        self.meaningful = meaningful
        self.trackedElementPresent = trackedElementPresent
        self.trackedElementContent = trackedElementContent
    }
}

@MainActor
public final class AccessibilityRuntime {
    private struct Snapshot {
        let context: AccessibilityStateContext
        let nodes: [AccessibilityNode]
        let elements: [UInt32: AXUIElement]
        let truncated: Bool
    }

    private var snapshots: [String: Snapshot] = [:]

    public init() {}

    public func clear() {
        snapshots.removeAll(keepingCapacity: false)
    }

    public func clear(applicationDigest: String) {
        snapshots.removeValue(forKey: applicationDigest)
    }

    public func currentStabilityFingerprint(
        context window: WindowContext,
        trackingElementIndex: UInt32? = nil
    ) -> AccessibilityStabilityFingerprint? {
        guard let current = snapshots[window.application.stableDigest],
              current.context.applicationDigest == window.application.stableDigest,
              current.context.windowID == window.windowID,
              current.context.displayFingerprint == window.displayFingerprint
        else { return nil }
        return Self.stabilityFingerprint(
            nodes: current.nodes,
            truncated: current.truncated,
            trackingElementIndex: trackingElementIndex
        )
    }

    public func isEditableTextTarget(_ target: ElementTarget) -> Bool {
        guard let current = snapshots[target.applicationDigest], current.context.matches(target),
              let node = current.nodes.first(where: { $0.index == target.elementIndex })
        else { return false }
        return Self.isEditableTextRole(node.role, settable: node.settable)
    }

    public func focusEditableTextTarget(_ target: ElementTarget) throws -> Bool {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        guard let current = snapshots[target.applicationDigest], current.context.matches(target),
              let node = current.nodes.first(where: { $0.index == target.elementIndex }),
              Self.isEditableTextRole(node.role, settable: node.settable),
              let element = current.elements[target.elementIndex]
        else { return false }
        if isFocused(element) { return true }

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            kAXFocusedAttribute as CFString,
            &settable
        ) == .success, settable.boolValue,
            AXUIElementSetAttributeValue(
                element,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            ) == .success
        else { return false }
        return isFocused(element)
    }

    static func isEditableTextRole(_ role: String, settable: Bool) -> Bool {
        settable && ["AXTextField", "AXTextArea", "AXSearchField"].contains(role)
    }

    static func shouldFocusEditableTextDirectly(role: String, settable: Bool) -> Bool {
        isEditableTextRole(role, settable: settable)
    }

    static func shouldFallbackEditableTextFocusToPress(
        applicationBundleIdentifier: String?,
        actions: [String]
    ) -> Bool {
        guard actions.contains(kAXPressAction as String),
              let applicationBundleIdentifier
        else { return false }
        return applicationBundleIdentifier.lowercased().hasPrefix("com.apple.")
    }

    public func rebindCurrent(
        context window: WindowContext,
        stateGeneration: UInt64
    ) -> AccessibilityStateContext? {
        guard let current = snapshots[window.application.stableDigest],
              current.context.applicationDigest == window.application.stableDigest,
              current.context.windowID == window.windowID,
              current.context.displayFingerprint == window.displayFingerprint
        else { return nil }
        let context = AccessibilityStateContext(
            stateID: UUID(),
            stateGeneration: stateGeneration,
            applicationDigest: current.context.applicationDigest,
            windowID: current.context.windowID,
            displayFingerprint: current.context.displayFingerprint
        )
        snapshots[window.application.stableDigest] = Snapshot(
            context: context,
            nodes: current.nodes,
            elements: current.elements,
            truncated: current.truncated
        )
        return context
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
        let focusedElement = focusedElement(processID: window.processID)
        let previous = snapshots[window.application.stableDigest]
        var renderer = BoundedAXRenderer(
            policy: policy,
            applicationBundleIdentifier: window.application.bundleIdentifier,
            priorNodes: previous?.nodes ?? [],
            priorElements: previous?.elements ?? [:]
        )
        let rendered = renderer.render(
            root: root,
            focusedElement: focusedElement,
            windowFrame: window.windowFrame
        )
        let stateID = UUID()
        let context = AccessibilityStateContext(
            stateID: stateID,
            stateGeneration: stateGeneration,
            applicationDigest: window.application.stableDigest,
            windowID: window.windowID,
            displayFingerprint: window.displayFingerprint
        )

        let canDiff = baseStateID != nil
            && baseStateID == previous?.context.stateID
            && previous?.context.applicationDigest == context.applicationDigest
            && previous?.context.windowID == context.windowID
            && previous?.context.displayFingerprint == context.displayFingerprint
        let observation: AccessibilityObservation
        if canDiff, let previous {
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
        snapshots[window.application.stableDigest] = Snapshot(
            context: context,
            nodes: rendered.nodes,
            elements: rendered.elements,
            truncated: rendered.truncated
        )
        return AccessibilitySnapshotResult(
            context: context,
            observation: observation,
            baseHadPageIdentity: canDiff && previous.map { Self.hasPageIdentity(in: $0.nodes) } == true,
            currentHasPageIdentity: Self.hasPageIdentity(in: rendered.nodes)
        )
    }

    public func perform(_ action: ActionV2, target: ElementTarget) throws {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        guard let current = snapshots[target.applicationDigest], current.context.matches(target) else {
            throw AccessibilityFailure.staleTarget
        }
        guard let node = current.nodes.first(where: { $0.index == target.elementIndex }),
              let element = current.elements[target.elementIndex]
        else {
            throw AccessibilityFailure.elementUnavailable
        }
        switch action {
        case .press:
            // Chromium and Electron may expose AXPress on editable nodes even
            // though the requested operation is only focus. Calling AXPress can
            // block the target application's AX IPC, so focus the field directly.
            // Some native Apple search fields reject AXFocused while exposing a
            // working AXPress; use that fallback only for Apple-owned apps.
            if Self.shouldFocusEditableTextDirectly(role: node.role, settable: node.settable) {
                if try !focusEditableTextTarget(target) {
                    guard Self.shouldFallbackEditableTextFocusToPress(
                        applicationBundleIdentifier: bundleIdentifier(of: element),
                        actions: node.actions
                    ) else {
                        throw AccessibilityFailure.operationFailed
                    }
                    try performNamedAction(kAXPressAction as String, on: element)
                }
            } else {
                try performNamedAction(kAXPressAction as String, on: element)
            }
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

    private func isFocused(_ element: AXUIElement) -> Bool {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return false }
        let application = AXUIElementCreateApplication(processID)
        var rawFocused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &rawFocused
        ) == .success,
            let rawFocused,
            CFGetTypeID(rawFocused) == AXUIElementGetTypeID()
        else { return false }
        return CFEqual(rawFocused, element)
    }

    private func bundleIdentifier(of element: AXUIElement) -> String? {
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
    }

    public func valueMatches(_ expectedValue: String, target: ElementTarget) throws -> Bool {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        guard let current = snapshots[target.applicationDigest], current.context.matches(target) else {
            throw AccessibilityFailure.staleTarget
        }
        guard let element = current.elements[target.elementIndex] else {
            throw AccessibilityFailure.elementUnavailable
        }
        try rejectSecure(element)
        var rawValue: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &rawValue
        )
        if result == .noValue {
            return expectedValue.isEmpty
        }
        guard result == .success else { throw AccessibilityFailure.operationFailed }
        let value = stringValue(rawValue)
        guard expectedValue.isEmpty else { return value == expectedValue }

        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &settable
        )
        let placeholder = AccessibilityTextNormalization.placeholder(
            attribute(kAXPlaceholderValueAttribute as String, from: element),
            value: value,
            label: attribute(kAXDescriptionAttribute as String, from: element),
            role: attribute(kAXRoleAttribute as String, from: element) ?? "",
            isSettable: settable.boolValue
        )
        return Self.valueMatches(
            value,
            expectedValue: expectedValue,
            placeholder: placeholder
        )
    }

    static func valueMatches(
        _ value: String?,
        expectedValue: String,
        placeholder: String? = nil
    ) -> Bool {
        if value == expectedValue { return true }
        guard expectedValue.isEmpty else { return false }
        return AccessibilityTextNormalization.value(value, placeholder: placeholder) == nil
    }

    public func stabilityFingerprint(
        context: WindowContext,
        policy: ObservationPolicy,
        trackingElementIndex: UInt32? = nil
    ) throws -> AccessibilityStabilityFingerprint {
        guard AXIsProcessTrusted() else { throw AccessibilityFailure.permissionMissing }
        let root = try focusedWindow(processID: context.processID, matching: context.windowFrame)
        let focusedElement = focusedElement(processID: context.processID)
        let previous = snapshots[context.application.stableDigest]
        var renderer = BoundedAXRenderer(
            policy: policy,
            applicationBundleIdentifier: context.application.bundleIdentifier,
            priorNodes: previous?.nodes ?? [],
            priorElements: previous?.elements ?? [:]
        )
        let rendered = renderer.render(
            root: root,
            focusedElement: focusedElement,
            windowFrame: context.windowFrame
        )
        return Self.stabilityFingerprint(
            nodes: rendered.nodes,
            truncated: rendered.truncated,
            trackingElementIndex: trackingElementIndex
        )
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

    private func focusedElement(processID: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)
        enableDynamicAccessibility(on: application)
        return attribute(kAXFocusedUIElementAttribute, from: application)
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
        if changeCount * 2 > max(current.count, 1),
           shouldResetLargeChange(previous: previous, current: current)
        {
            return AccessibilityObservation(
                kind: .full,
                reset: true,
                truncated: truncated,
                nodes: current,
                removed: []
            )
        }
        let changedIndexes = Set(changed.map(\.index))
        let anchorIndexes = truncated && changeCount > 0
            ? Self.navigationAnchorIndexes(in: current)
            : []
        return AccessibilityObservation(
            kind: .diff,
            reset: false,
            truncated: truncated,
            nodes: current.filter {
                changedIndexes.contains($0.index) || anchorIndexes.contains($0.index)
            },
            removed: removed
        )
    }

    private static func shouldResetLargeChange(
        previous: [AccessibilityNode],
        current: [AccessibilityNode]
    ) -> Bool {
        func pageIdentities(in nodes: [AccessibilityNode]) -> Set<String> {
            Set(nodes.lazy.filter { $0.role == "AXWebArea" }.compactMap { node in
                let title = node.title ?? ""
                let url = node.url ?? ""
                guard !title.isEmpty || !url.isEmpty else { return nil }
                return "\(title)\u{1F}\(url)"
            })
        }
        let previousPages = pageIdentities(in: previous)
        let currentPages = pageIdentities(in: current)
        if !previousPages.isEmpty, !currentPages.isEmpty {
            return previousPages.isDisjoint(with: currentPages)
        }

        // Reaching diff() already proves that the application, native window,
        // and display context match the model-visible base. Bounded browser AX
        // traversal can temporarily omit both AXWebArea and AXWindow while a
        // find bar, infobar, popover, or menu takes priority. Missing AX anchors
        // therefore cannot establish a context replacement on their own.
        return false
    }

    static func hasPageIdentity(in nodes: [AccessibilityNode]) -> Bool {
        nodes.contains { node in
            node.role == "AXWebArea"
                && (!(node.title ?? "").isEmpty || !(node.url ?? "").isEmpty)
        }
    }

    private static func navigationAnchorIndexes(
        in nodes: [AccessibilityNode]
    ) -> Set<UInt32> {
        var indexes: Set<UInt32> = []
        if let webArea = nodes.first(where: { $0.role == "AXWebArea" }) {
            indexes.insert(webArea.index)
        }
        for heading in nodes.lazy.filter({ $0.role == "AXHeading" }).prefix(2) {
            indexes.insert(heading.index)
        }
        return indexes
    }

    static func stabilityFingerprint(
        nodes: [AccessibilityNode],
        truncated: Bool,
        trackingElementIndex: UInt32? = nil
    ) -> AccessibilityStabilityFingerprint {
        let pageIndexes = Set(nodes.lazy.filter { $0.role == "AXWebArea" }.map(\.index))
        let nodesByIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.index, $0) })
        var pageTextCount = 0
        var contentHasher = Hasher()
        contentHasher.combine(truncated)
        for node in nodes {
            let belongsToPage = Self.belongsToPage(
                node,
                pageIndexes: pageIndexes,
                nodesByIndex: nodesByIndex
            )
            let isLeadingPageText = belongsToPage
                && pageTextCount < 24
                && ["AXHeading", "AXStaticText"].contains(node.role)
            if isLeadingPageText { pageTextCount += 1 }
            if pageIndexes.isEmpty
                || node.role == "AXWebArea"
                || node.settable
                || [
                    "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
                    "AXProgressIndicator", "AXBusyIndicator",
                ].contains(node.role)
                || isLeadingPageText
            {
                contentHasher.combine(node)
            }
        }
        let content = contentHasher.finalize()

        let pageNodes = nodes.filter { $0.role == "AXWebArea" }
        var meaningfulHasher = Hasher()
        if pageNodes.isEmpty {
            meaningfulHasher.combine(content)
        } else {
            for node in pageNodes {
                meaningfulHasher.combine(node.role)
                meaningfulHasher.combine(node.title)
                meaningfulHasher.combine(node.url)
            }
        }
        let trackedNode = trackingElementIndex.flatMap { trackedIndex in
            nodes.first { $0.index == trackedIndex }
        }
        var trackedElementHasher = Hasher()
        if let trackedNode {
            trackedElementHasher.combine(trackedNode.role)
            trackedElementHasher.combine(trackedNode.title)
            trackedElementHasher.combine(trackedNode.label)
            trackedElementHasher.combine(trackedNode.value)
            trackedElementHasher.combine(trackedNode.placeholder)
            trackedElementHasher.combine(trackedNode.url)
            trackedElementHasher.combine(trackedNode.settable)
            trackedElementHasher.combine(trackedNode.actions)
        }
        return AccessibilityStabilityFingerprint(
            content: content,
            meaningful: meaningfulHasher.finalize(),
            trackedElementPresent: trackingElementIndex.map { _ in trackedNode != nil },
            trackedElementContent: trackedNode.map { _ in trackedElementHasher.finalize() }
        )
    }

    private static func belongsToPage(
        _ node: AccessibilityNode,
        pageIndexes: Set<UInt32>,
        nodesByIndex: [UInt32: AccessibilityNode]
    ) -> Bool {
        var candidate: AccessibilityNode? = node
        var visited: Set<UInt32> = []
        while let current = candidate, visited.insert(current.index).inserted {
            if pageIndexes.contains(current.index) { return true }
            candidate = current.parentIndex.flatMap { nodesByIndex[$0] }
        }
        return false
    }
}

private struct BoundedAXRenderer {
    private struct StableNodeIdentity: Hashable {
        let parentIndex: UInt32?
        let depth: UInt8
        let role: String
        let title: String?
        let label: String?
        let placeholder: String?
        let url: String?
        let settable: Bool
        let actions: [String]

        init(node: AccessibilityNode) {
            parentIndex = node.parentIndex
            depth = node.depth
            role = node.role
            title = node.title
            label = node.label
            placeholder = node.placeholder
            url = node.url
            settable = node.settable
            actions = node.actions
        }

        init(
            parentIndex: UInt32?,
            depth: UInt8,
            role: String,
            title: String?,
            label: String?,
            placeholder: String?,
            url: String?,
            settable: Bool,
            actions: [String]
        ) {
            self.parentIndex = parentIndex
            self.depth = depth
            self.role = role
            self.title = title
            self.label = label
            self.placeholder = placeholder
            self.url = url
            self.settable = settable
            self.actions = actions
        }
    }

    private struct PendingElement {
        let element: AXUIElement
        let parentIndex: UInt32?
        let depth: UInt8
        let ancestorVisible: Bool
        let contentPriority: UInt8
        let insideWebArea: Bool
    }

    private static let snapshotAttributeNames = [
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
        kAXHiddenAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXTitleAttribute as String,
        kAXDescriptionAttribute as String,
        kAXValueAttribute as String,
        kAXPlaceholderValueAttribute as String,
        kAXSelectedAttribute as String,
        "AXURL",
    ]

    let policy: ObservationPolicy
    let applicationBundleIdentifier: String
    let priorElementsByHash: [UInt: [(UInt32, AXUIElement)]]
    private let priorNodesByIndex: [UInt32: AccessibilityNode]
    private let priorIndexesByIdentity: [StableNodeIdentity: [UInt32]]
    let deadline: ContinuousClock.Instant
    private(set) var nodes: [AccessibilityNode] = []
    private(set) var elements: [UInt32: AXUIElement] = [:]
    private var usedIndexes: Set<UInt32> = []
    private var seenElementsByHash: [UInt: [AXUIElement]] = [:]
    private(set) var textBytes = 0
    private(set) var truncated = false

    init(
        policy: ObservationPolicy,
        applicationBundleIdentifier: String,
        priorNodes: [AccessibilityNode],
        priorElements: [UInt32: AXUIElement]
    ) {
        self.policy = policy
        self.applicationBundleIdentifier = applicationBundleIdentifier
        deadline = ContinuousClock.now.advanced(by: .seconds(3))
        priorElementsByHash = Dictionary(grouping: priorElements.sorted { $0.key < $1.key }) {
            CFHash($0.value)
        }
        priorNodesByIndex = Dictionary(uniqueKeysWithValues: priorNodes.map { ($0.index, $0) })
        priorIndexesByIdentity = Dictionary(
            grouping: priorNodes.sorted { $0.index < $1.index },
            by: StableNodeIdentity.init(node:)
        ).mapValues { $0.map(\.index) }
    }

    mutating func render(
        root: AXUIElement,
        focusedElement: AXUIElement?,
        windowFrame: CGRect
    ) -> (nodes: [AccessibilityNode], elements: [UInt32: AXUIElement], truncated: Bool) {
        var pending = [PendingElement(
            element: root,
            parentIndex: nil,
            depth: 0,
            ancestorVisible: true,
            contentPriority: 0,
            insideWebArea: false
        )]
        var priorityPending: [PendingElement] = []
        var foregroundPending: [PendingElement] = []
        if let focusedElement,
           !CFEqual(focusedElement, root),
           let focusedRole: String = attribute(kAXRoleAttribute as String, from: focusedElement),
           AccessibilityTraversal.shouldPrioritizeFocusedElement(role: focusedRole)
        {
            let priorNode = priorNode(for: focusedElement)
            foregroundPending.append(PendingElement(
                element: focusedElement,
                parentIndex: priorNode?.parentIndex,
                depth: priorNode?.depth ?? 0,
                ancestorVisible: true,
                contentPriority: 2,
                insideWebArea: priorNode.map(isInsideWebArea) ?? false
            ))
        }
        var cursor = 0
        var priorityCursor = 0
        var foregroundCursor = 0
        var preferredQueueBurstCount = 0
        while foregroundCursor < foregroundPending.count
            || priorityCursor < priorityPending.count
            || cursor < pending.count
        {
            guard ContinuousClock.now < deadline,
                  nodes.count < Int(policy.maxNodes)
            else {
                truncated = true
                break
            }
            let item: PendingElement
            if AccessibilityTraversal.shouldVisitStandardQueue(
                preferredQueueBurstCount: preferredQueueBurstCount,
                hasStandardElements: cursor < pending.count
            ) {
                item = pending[cursor]
                cursor += 1
                preferredQueueBurstCount = 0
            } else if foregroundCursor < foregroundPending.count {
                item = foregroundPending[foregroundCursor]
                foregroundCursor += 1
                preferredQueueBurstCount += 1
            } else if priorityCursor < priorityPending.count {
                item = priorityPending[priorityCursor]
                priorityCursor += 1
                preferredQueueBurstCount += 1
            } else {
                item = pending[cursor]
                cursor += 1
                preferredQueueBurstCount = 0
            }
            let discovered = visit(
                item.element,
                parentIndex: item.parentIndex,
                depth: item.depth,
                windowFrame: windowFrame,
                ancestorVisible: item.ancestorVisible,
                contentPriority: item.contentPriority,
                insideWebArea: item.insideWebArea
            )
            foregroundPending.append(contentsOf: discovered.filter { $0.contentPriority == 2 })
            priorityPending.append(contentsOf: discovered.filter { $0.contentPriority == 1 })
            pending.append(contentsOf: discovered.filter { $0.contentPriority == 0 })
        }
        if foregroundCursor < foregroundPending.count
            || priorityCursor < priorityPending.count
            || cursor < pending.count
        {
            truncated = true
        }
        return (nodes, elements, truncated)
    }

    private mutating func visit(
        _ element: AXUIElement,
        parentIndex: UInt32?,
        depth: UInt8,
        windowFrame: CGRect,
        ancestorVisible: Bool,
        contentPriority: UInt8,
        insideWebArea: Bool
    ) -> [PendingElement] {
        guard ContinuousClock.now < deadline,
              nodes.count < Int(policy.maxNodes),
              depth <= policy.maxDepth
        else {
            truncated = true
            return []
        }
        guard markSeen(element) else { return [] }
        let snapshot = snapshotAttributes(of: element)
        let rawRole: String = snapshot[kAXRoleAttribute as String] as? String ?? "AXUnknown"
        let subrole = snapshot[kAXSubroleAttribute as String] as? String
        let secure = rawRole == "AXSecureTextField" || subrole == "AXSecureTextField"
        let hidden = snapshot[kAXHiddenAttribute as String] as? Bool ?? false
        let screenFrame = elementFrame(snapshot)
        let descendantContentPriority = max(
            contentPriority,
            AccessibilityTraversal.contentPriority(
                screenFrame,
                windowFrame: windowFrame,
                depth: depth
            )
        )
        let visible = AccessibilityVisibility.isVisible(
            hidden: hidden,
            frame: screenFrame,
            windowFrame: windowFrame,
            ancestorVisible: ancestorVisible
        )
        guard visible else { return [] }

        let rawLabel = snapshot[kAXDescriptionAttribute as String] as? String
        if AccessibilityTraversal.shouldPruneLowValueBrowserChromeSubtree(
            applicationBundleIdentifier: applicationBundleIdentifier,
            role: rawRole,
            label: rawLabel,
            frame: screenFrame,
            windowFrame: windowFrame,
            insideWebArea: insideWebArea
        ) {
            return []
        }
        let children = childElements(of: element, role: rawRole)
        let descendantInsideWebArea = insideWebArea || rawRole == "AXWebArea"
        if AccessibilityTraversal.shouldPruneInactiveBrowserChromeSubtree(
            applicationBundleIdentifier: applicationBundleIdentifier,
            role: rawRole,
            selected: snapshot[kAXSelectedAttribute as String] as? Bool,
            value: stringValue(snapshot[kAXValueAttribute as String]),
            insideWebArea: insideWebArea
        ) {
            return []
        }
        var settable = DarwinBoolean(false)
        _ = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        var actionValues: CFArray?
        _ = AXUIElementCopyActionNames(element, &actionValues)
        let rawActions = AccessibilityTraversal.protocolSafeActions(
            (actionValues as? [String]) ?? []
        )
        let exposedActions = AccessibilityTraversal.exposedActions(
            rawActions,
            role: rawRole
        )
        let rawTitle = snapshot[kAXTitleAttribute as String] as? String
        let rawAXValue = secure ? nil : stringValue(snapshot[kAXValueAttribute as String])
        let rawPlaceholder = AccessibilityTextNormalization.placeholder(
            snapshot[kAXPlaceholderValueAttribute as String] as? String,
            value: rawAXValue,
            label: rawLabel,
            role: rawRole,
            isSettable: settable.boolValue
        )
        let rawValue = secure ? nil : AccessibilityTextNormalization.value(
            rawAXValue,
            placeholder: rawPlaceholder
        )
        let rawURL = secure ? nil : stringValue(snapshot["AXURL"])
        let hasSemanticText = [rawTitle, rawLabel, rawValue, rawPlaceholder, rawURL]
            .contains { $0?.isEmpty == false }
        let effectiveSettable = settable.boolValue
            && AccessibilityTraversal.supportsSettableValue(
                role: rawRole,
                contentPriority: descendantContentPriority
            )
        let textPriority = AccessibilityTraversal.textPriority(
            role: rawRole,
            isSettable: effectiveSettable,
            actions: exposedActions
        )

        if AccessibilityTraversal.shouldElideWrapper(
            role: rawRole,
            hasSemanticText: hasSemanticText,
            isSettable: effectiveSettable,
            actions: exposedActions,
            childCount: children.count
        ) {
            return pendingChildren(
                children,
                role: rawRole,
                parentIndex: parentIndex,
                depth: depth,
                contentPriority: descendantContentPriority,
                insideWebArea: descendantInsideWebArea
            )
        }

        guard let role = bounded(
            rawRole,
            maximumCharacters: 80,
            priority: textPriority
        ) else {
            truncated = true
            return pendingChildren(
                children,
                role: rawRole,
                parentIndex: parentIndex,
                depth: depth,
                contentPriority: descendantContentPriority,
                insideWebArea: descendantInsideWebArea
            )
        }
        let actions = exposedActions
            .prefix(16)
            .compactMap {
                bounded($0, maximumCharacters: 128, priority: textPriority)
            }
        let title = bounded(
            rawTitle,
            maximumCharacters: Int(policy.maxTextPerNode),
            priority: textPriority
        )
        let label = bounded(
            rawLabel,
            maximumCharacters: Int(policy.maxTextPerNode),
            priority: textPriority
        )
        let value = bounded(
            rawValue,
            maximumCharacters: Int(policy.maxTextPerNode),
            priority: textPriority
        )
        let placeholder = bounded(
            rawPlaceholder,
            maximumCharacters: Int(policy.maxTextPerNode),
            priority: textPriority
        )
        let url = bounded(
            rawURL,
            maximumCharacters: Int(policy.maxTextPerNode),
            priority: textPriority
        )
        let frame = AccessibilityTraversal.shouldIncludeFrame(
            isSettable: !secure && effectiveSettable,
            actions: actions
        ) ? relativeFrame(screenFrame, windowFrame: windowFrame) : nil
        let identity = StableNodeIdentity(
            parentIndex: parentIndex,
            depth: depth,
            role: role,
            title: title,
            label: label,
            placeholder: placeholder,
            url: url,
            settable: !secure && effectiveSettable,
            actions: actions
        )
        guard let index = allocateIndex(for: element, identity: identity) else {
            truncated = true
            return []
        }
        let node = AccessibilityNode(
            index: index,
            parentIndex: parentIndex,
            depth: depth,
            role: role,
            title: title,
            label: label,
            value: value,
            placeholder: placeholder,
            url: url,
            frame: frame,
            settable: !secure && effectiveSettable,
            actions: actions
        )
        nodes.append(node)
        elements[index] = element

        guard depth < policy.maxDepth else {
            if !children.isEmpty { truncated = true }
            return []
        }
        let maximumChildren = AccessibilityTraversal.childTraversalLimit(
            count: children.count,
            maximumPerContainer: Int(policy.maxVisibleRowsPerContainer),
            role: rawRole
        )
        if children.count > maximumChildren { truncated = true }
        return AccessibilityTraversal.boundedChildOffsets(
            count: children.count,
            maximum: maximumChildren
        ).map { offset in
            PendingElement(
                element: children[offset],
                parentIndex: index,
                depth: depth + 1,
                ancestorVisible: true,
                contentPriority: descendantContentPriority,
                insideWebArea: descendantInsideWebArea
            )
        }
    }

    private mutating func pendingChildren(
        _ children: [AXUIElement],
        role: String,
        parentIndex: UInt32?,
        depth: UInt8,
        contentPriority: UInt8,
        insideWebArea: Bool
    ) -> [PendingElement] {
        let maximumChildren = AccessibilityTraversal.childTraversalLimit(
            count: children.count,
            maximumPerContainer: Int(policy.maxVisibleRowsPerContainer),
            role: role
        )
        if children.count > maximumChildren { truncated = true }
        return AccessibilityTraversal.boundedChildOffsets(
            count: children.count,
            maximum: maximumChildren
        ).map { offset in
            PendingElement(
                element: children[offset],
                parentIndex: parentIndex,
                depth: depth,
                ancestorVisible: true,
                contentPriority: contentPriority,
                insideWebArea: insideWebArea
            )
        }
    }

    private mutating func allocateIndex(
        for element: AXUIElement,
        identity: StableNodeIdentity
    ) -> UInt32? {
        if let preferred = priorElementsByHash[CFHash(element)]?
            .first(where: { CFEqual($0.1, element) })?
            .0,
            preferred < UInt32(policy.maxNodes),
            usedIndexes.insert(preferred).inserted
        {
            return preferred
        }
        if let preferred = priorIndexesByIdentity[identity]?
            .first(where: { $0 < UInt32(policy.maxNodes) && !usedIndexes.contains($0) })
        {
            usedIndexes.insert(preferred)
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

    private func priorNode(for element: AXUIElement) -> AccessibilityNode? {
        let hash = CFHash(element)
        guard let prior = priorElementsByHash[hash]?.first(where: { CFEqual($0.1, element) })
        else { return nil }
        return priorNodesByIndex[prior.0]
    }

    private func isInsideWebArea(_ node: AccessibilityNode) -> Bool {
        var candidate: AccessibilityNode? = node
        var visited: Set<UInt32> = []
        while let current = candidate, visited.insert(current.index).inserted {
            if current.role == "AXWebArea" { return true }
            candidate = current.parentIndex.flatMap { priorNodesByIndex[$0] }
        }
        return false
    }

    private func childElements(of element: AXUIElement, role: String) -> [AXUIElement] {
        let rows: [AXUIElement] = AccessibilityTraversal.usesRowBudget(role: role)
            ? attribute(kAXRowsAttribute as String, from: element) ?? []
            : []
        let visibleChildren: [AXUIElement] = AccessibilityTraversal.usesVisibleChildren(role: role)
            ? attribute("AXVisibleChildren", from: element) ?? []
            : []
        let attributes = AccessibilityTraversal.childAttributes(
            role: role,
            hasRows: !rows.isEmpty,
            hasVisibleChildren: !visibleChildren.isEmpty
        )
        for name in attributes {
            let values: [AXUIElement]
            if name == kAXRowsAttribute as String {
                values = rows
            } else if name == "AXVisibleChildren" {
                values = visibleChildren
            } else {
                values = attribute(name, from: element) ?? []
            }
            if !values.isEmpty { return values }
        }
        return []
    }

    private mutating func bounded(
        _ value: String?,
        maximumCharacters: Int,
        priority: AccessibilityTextPriority
    ) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let limit = AccessibilityTraversal.textBudgetLimit(
            totalBytes: Int(policy.maxTotalTextBytes),
            priority: priority
        )
        guard textBytes < limit else {
            truncated = true
            return nil
        }
        let remaining = limit - textBytes
        guard let result = AccessibilityTraversal.boundedText(
            value,
            maximumCharacters: maximumCharacters,
            maximumBytes: remaining
        ) else { return nil }
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

enum AccessibilityTextNormalization {
    static func placeholder(
        _ placeholder: String?,
        value: String?,
        label: String?,
        role: String,
        isSettable: Bool
    ) -> String? {
        if let placeholder, !placeholder.isEmpty { return placeholder }
        guard isSettable,
              ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"].contains(role),
              let value,
              let label,
              !label.isEmpty
        else { return nil }
        let trimming = CharacterSet.whitespacesAndNewlines
        return value.trimmingCharacters(in: trimming)
            == label.trimmingCharacters(in: trimming)
            ? label
            : nil
    }

    static func value(_ value: String?, placeholder: String?) -> String? {
        guard let value else { return nil }
        guard let placeholder, !placeholder.isEmpty else { return value }
        let trimming = CharacterSet.whitespacesAndNewlines
        return value.trimmingCharacters(in: trimming)
            == placeholder.trimmingCharacters(in: trimming)
            ? nil
            : value
    }
}

enum AccessibilityTextPriority {
    case structural
    case interactive
    case editable
}

enum AccessibilityTraversal {
    private static let preferredQueueBurstLimit = 4
    private static let lowValueStructuralActions = [
        "AXShowMenu", "AXScrollToVisible",
    ]

    static func protocolSafeActions(_ actions: [String]) -> [String] {
        actions.filter { action in
            !action.isEmpty
                && action.count <= 128
                && action.unicodeScalars.allSatisfy {
                    !CharacterSet.controlCharacters.contains($0)
                }
        }
    }

    static func shouldVisitStandardQueue(
        preferredQueueBurstCount: Int,
        hasStandardElements: Bool
    ) -> Bool {
        hasStandardElements && preferredQueueBurstCount >= preferredQueueBurstLimit
    }

    static func shouldPrioritizeFocusedElement(role: String) -> Bool {
        // Chromium can keep a detached pre-navigation AXWebArea focused after
        // history navigation. Traversing it ahead of the current window root
        // mixes stale page content with fresh browser chrome.
        role != "AXWebArea"
    }

    static func exposedActions(_ actions: [String], role: String) -> [String] {
        guard actions.allSatisfy(lowValueStructuralActions.contains),
              ["AXGroup", "AXStaticText", "AXImage", "AXUnknown"].contains(role)
        else { return actions }
        return []
    }

    static func shouldPruneInactiveBrowserChromeSubtree(
        applicationBundleIdentifier: String,
        role: String,
        selected: Bool?,
        value: String? = nil,
        insideWebArea: Bool
    ) -> Bool {
        let normalizedValue = value?.lowercased()
        let active = selected == true || normalizedValue == "1" || normalizedValue == "true"
        return applicationBundleIdentifier.caseInsensitiveCompare("com.google.Chrome") == .orderedSame
            && role == "AXRadioButton"
            && !active
            && !insideWebArea
    }

    static func shouldPruneLowValueBrowserChromeSubtree(
        applicationBundleIdentifier: String,
        role: String,
        label: String?,
        frame: CGRect?,
        windowFrame: CGRect,
        insideWebArea: Bool
    ) -> Bool {
        guard applicationBundleIdentifier.caseInsensitiveCompare("com.google.Chrome") == .orderedSame,
              role == "AXToolbar",
              label?.isEmpty == false,
              !insideWebArea,
              let frame,
              windowFrame.width > 0,
              windowFrame.height > 0
        else { return false }
        let topBandHeight = min(160, windowFrame.height * 0.2)
        return frame.minY < windowFrame.minY + topBandHeight
            && frame.height <= 50
            && frame.width >= windowFrame.width * 0.5
    }

    static func contentPriority(
        _ frame: CGRect?,
        windowFrame: CGRect,
        depth: UInt8
    ) -> UInt8 {
        guard depth > 0, let frame,
              windowFrame.width > 0, windowFrame.height > 0
        else { return 0 }
        let insetFromLeft = frame.minX - windowFrame.minX
        let insetFromTop = frame.minY - windowFrame.minY
        if frame.width >= windowFrame.width * 0.3,
           insetFromTop >= windowFrame.height * 0.55
        {
            return 2
        }
        guard frame.width >= windowFrame.width * 0.45,
              frame.height >= windowFrame.height * 0.35
        else { return 0 }
        return insetFromLeft >= windowFrame.width * 0.1
            || insetFromTop >= windowFrame.height * 0.1
            ? 1
            : 0
    }

    static func boundedText(
        _ value: String,
        maximumCharacters: Int,
        maximumBytes: Int
    ) -> String? {
        guard maximumCharacters > 0, maximumBytes > 0 else { return nil }
        var result = ""
        var resultBytes = 0
        for character in value.prefix(maximumCharacters) {
            let count = String(character).utf8.count
            if resultBytes + count > maximumBytes { break }
            result.append(character)
            resultBytes += count
        }
        return result.isEmpty ? nil : result
    }

    static func boundedChildOffsets(count: Int, maximum: Int) -> [Int] {
        guard count > 0, maximum > 0 else { return [] }
        var offsets: [Int] = []
        var leading = 0
        var trailing = count - 1
        while leading <= trailing, offsets.count < min(count, maximum) {
            offsets.append(trailing)
            trailing -= 1
            if leading <= trailing, offsets.count < min(count, maximum) {
                offsets.append(leading)
                leading += 1
            }
        }
        return offsets
    }

    static func childTraversalLimit(
        count: Int,
        maximumPerContainer: Int,
        role: String
    ) -> Int {
        usesRowBudget(role: role) ? min(count, maximumPerContainer) : count
    }

    static func isInteractionPriority(
        role: String,
        isSettable: Bool,
        actions: [String]
    ) -> Bool {
        isSettable
            || !actions.isEmpty
            || ["AXTextArea", "AXTextField", "AXSearchField", "AXComboBox"]
                .contains(role)
    }

    static func supportsSettableValue(role: String, contentPriority: UInt8 = 0) -> Bool {
        if [
            "AXTextArea", "AXTextField", "AXSearchField", "AXComboBox",
            "AXSlider", "AXIncrementor",
        ].contains(role) {
            return true
        }
        return role == "AXGroup" && contentPriority == 2
    }

    static func shouldIncludeFrame(isSettable: Bool, actions: [String]) -> Bool {
        isSettable || !actions.isEmpty
    }

    static func textPriority(
        role: String,
        isSettable: Bool,
        actions: [String]
    ) -> AccessibilityTextPriority {
        if isSettable || ["AXTextArea", "AXTextField", "AXSearchField", "AXSecureTextField"]
            .contains(role)
        {
            return .editable
        }
        return actions.isEmpty ? .structural : .interactive
    }

    static func textBudgetLimit(
        totalBytes: Int,
        priority: AccessibilityTextPriority
    ) -> Int {
        switch priority {
        case .structural:
            totalBytes - totalBytes / 4
        case .interactive:
            totalBytes - totalBytes / 8
        case .editable:
            totalBytes
        }
    }

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

    static func usesVisibleChildren(role: String) -> Bool {
        ["AXList", "AXTable", "AXOutline", "AXBrowser", "AXWebArea", "AXScrollArea"]
            .contains(role)
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
            && childCount > 0
    }

    private static func usesRowsAsPrimary(role: String) -> Bool {
        usesRowBudget(role: role)
    }

    private static func usesVisibleChildrenAsPrimary(role: String) -> Bool {
        usesVisibleChildren(role: role)
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
