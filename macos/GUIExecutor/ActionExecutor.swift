import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import DeviceProtocol
import DeviceSecurity
import Foundation
@preconcurrency import ScreenCaptureKit

public enum ExecutionFailure: Error, Equatable, Sendable {
    case accessibilityPermissionMissing
    case applicationChanged
    case windowChanged
    case displayChanged
    case eventCreationFailed
    case unsupportedKey
    case actionRequiresCapture
    case protectedSystemSurface
    case clipboardEmpty
    case clipboardNonText
    case clipboardUnavailable
    case clipboardTooLarge

    public var diagnosticCode: String {
        switch self {
        case .accessibilityPermissionMissing: "accessibility_permission_missing"
        case .applicationChanged: "approved_application_changed"
        case .windowChanged: "approved_window_changed"
        case .displayChanged: "display_layout_changed"
        case .eventCreationFailed: "input_event_creation_failed"
        case .unsupportedKey: "unsupported_key"
        case .actionRequiresCapture: "invalid_capture_action_dispatch"
        case .protectedSystemSurface: "protected_system_surface"
        case .clipboardEmpty: "clipboard_empty"
        case .clipboardNonText: "clipboard_non_text"
        case .clipboardUnavailable: "clipboard_unavailable"
        case .clipboardTooLarge: "clipboard_too_large"
        }
    }

    public var userMessage: String {
        switch self {
        case .accessibilityPermissionMissing:
            "Mac Accessibility permission is missing for Agent Remote Device."
        case .applicationChanged:
            "The target application changed after the latest screenshot. Take a fresh screenshot."
        case .windowChanged:
            "The approved window moved, resized, or closed after the latest screenshot. Take a fresh screenshot."
        case .displayChanged:
            "The Mac display layout changed after the latest screenshot. Take a fresh screenshot."
        case .eventCreationFailed:
            "macOS could not create the requested input event."
        case .unsupportedKey:
            "The requested key or key combination is not supported."
        case .actionRequiresCapture:
            "The capture action was sent to the input-event executor."
        case .protectedSystemSurface:
            "macOS Secure Input is active. The requested action was rejected."
        case .clipboardEmpty:
            "The Mac clipboard is empty."
        case .clipboardNonText:
            "The Mac clipboard does not contain plain text."
        case .clipboardUnavailable:
            "The Mac clipboard text is temporarily unavailable."
        case .clipboardTooLarge:
            "The Mac clipboard text exceeds the 64 KiB limit."
        }
    }
}

public enum CoordinateMapper {
    public static func screenPoint(
        imagePoint: Point,
        pixelWidth: UInt16,
        pixelHeight: UInt16,
        windowFrame: CGRect
    ) -> CGPoint? {
        guard pixelWidth > 0, pixelHeight > 0,
              imagePoint.x < pixelWidth, imagePoint.y < pixelHeight,
              windowFrame.width > 0, windowFrame.height > 0
        else {
            return nil
        }
        return CGPoint(
            x: windowFrame.minX + CGFloat(imagePoint.x) / CGFloat(pixelWidth) * windowFrame.width,
            y: windowFrame.minY + CGFloat(imagePoint.y) / CGFloat(pixelHeight) * windowFrame.height
        )
    }
}

enum WindowFrameValidation: Sendable {
    case exact
    case approximate
    case identityOnly
}

@MainActor
public final class ActionExecutor {
    private let guardState: SessionGuard
    private let secureInputEnabled: () -> Bool
    private var leftMouseIsDown = false
    private var heldKeyCode: CGKeyCode?
    private var heldKeyUpFlags: CGEventFlags = []

    public init(
        guardState: SessionGuard,
        secureInputEnabled: @escaping () -> Bool = { IsSecureEventInputEnabled() }
    ) {
        self.guardState = guardState
        self.secureInputEnabled = secureInputEnabled
    }

    public var hasPressedState: Bool {
        leftMouseIsDown || heldKeyCode != nil
    }

    public func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        do {
            try rejectSecureInput(for: action)
            guard AXIsProcessTrusted() else {
                throw ExecutionFailure.accessibilityPermissionMissing
            }
            let displayFingerprint = try await verifyLiveContext(
                capture,
                frameValidation: action.requiresModelVisibleScreenshot ? .exact : .identityOnly,
                requireFrontmost: action.requiresForegroundApplication
            )
            try await guardState.authorize(
                action: action,
                sequence: sequence,
                screenshotGeneration: screenshotGeneration,
                displayFingerprint: displayFingerprint,
                application: capture.application
            )
            try rejectSecureInput(for: action)
            try await dispatch(action, capture: capture)
            try await guardState.accept(sequence: sequence)
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func executeElement(
        action: ActionV2,
        target: ElementTarget,
        sequence: UInt64,
        context: WindowContext,
        accessibility: AccessibilityRuntime
    ) async throws {
        do {
            try rejectSecureInput(for: action)
            guard AXIsProcessTrusted() else {
                throw ExecutionFailure.accessibilityPermissionMissing
            }
            let displayFingerprint = try await verifyLiveContext(
                context,
                frameValidation: .identityOnly
            )
            try await guardState.authorizeElement(
                action: action,
                sequence: sequence,
                target: target,
                displayFingerprint: displayFingerprint,
                windowID: context.windowID,
                application: context.application
            )
            let requiresEditableFocus = if case .press = action {
                accessibility.isEditableTextTarget(target)
            } else {
                false
            }
            var actionError: Error?
            var editableFocusVerifiedByAction = false
            for attempt in 0 ..< (requiresEditableFocus ? 12 : 1) {
                do {
                    try rejectSecureInput(for: action)
                    if case let .scrollElement(_, direction, pages) = action {
                        let prior = try accessibility.scrollPosition(
                            for: target,
                            direction: direction
                        )
                        if !prior.isAtBoundary(for: direction) {
                            var requiresFallback = false
                            do {
                                try accessibility.perform(action, target: target)
                                try await Task.sleep(for: .milliseconds(150))
                                let observed = try accessibility.scrollPosition(
                                    for: target,
                                    direction: direction
                                )
                                requiresFallback = !observed.moved(from: prior, in: direction)
                            } catch let error as AccessibilityFailure
                                where error == .operationFailed
                            {
                                requiresFallback = true
                            }
                            if requiresFallback {
                                try await postVerifiedPageScroll(
                                    direction: direction,
                                    pages: pages,
                                    target: target,
                                    context: context,
                                    accessibility: accessibility
                                )
                            }
                        }
                    } else {
                        editableFocusVerifiedByAction = try accessibility.perform(
                            action,
                            target: target
                        )
                    }
                    actionError = nil
                    break
                } catch let error as AccessibilityFailure where
                    requiresEditableFocus && error == .operationFailed
                {
                    actionError = error
                    if attempt < 11 {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            if let actionError { throw actionError }
            if Self.shouldVerifyEditableFocusAfterAction(
                requiresEditableFocus: requiresEditableFocus,
                verifiedDuringAction: editableFocusVerifiedByAction
            ) {
                var focused = false
                for _ in 0 ..< 10 {
                    if try accessibility.focusEditableTextTarget(target) {
                        focused = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                guard focused else { throw AccessibilityFailure.operationFailed }
            }
            try await guardState.accept(sequence: sequence)
        } catch {
            releasePressedState()
            throw error
        }
    }

    static func shouldVerifyEditableFocusAfterAction(
        requiresEditableFocus: Bool,
        verifiedDuringAction: Bool
    ) -> Bool {
        requiresEditableFocus && !verifiedDuringAction
    }

    private func postVerifiedPageScroll(
        direction: ScrollDirection,
        pages: UInt8,
        target: ElementTarget,
        context: WindowContext,
        accessibility: AccessibilityRuntime
    ) async throws {
        let prior = try accessibility.scrollPosition(for: target, direction: direction)
        if prior.isAtBoundary(for: direction) { return }
        let visibleFrame = try accessibility.visibleScreenFrame(
            for: target,
            windowFrame: context.windowFrame
        )
        guard let deltas = Self.pageScrollDeltas(
            direction: direction,
            pages: pages,
            visibleFrame: visibleFrame
        ),
            let originalPointer = CGEvent(source: nil)?.location,
            let moveToElement = CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: CGPoint(x: visibleFrame.midX, y: visibleFrame.midY),
                mouseButton: .left
            ),
            let scroll = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltas.vertical,
                wheel2: deltas.horizontal,
                wheel3: 0
            )
        else { throw ExecutionFailure.eventCreationFailed }
        defer {
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: originalPointer,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
        }
        let targetPoint = CGPoint(x: visibleFrame.midX, y: visibleFrame.midY)
        scroll.location = targetPoint
        moveToElement.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(50))
        scroll.post(tap: .cghidEventTap)
        try await Task.sleep(for: .milliseconds(150))
        let observed = try accessibility.scrollPosition(for: target, direction: direction)
        guard observed.moved(from: prior, in: direction) else {
            throw AccessibilityFailure.operationFailed
        }
    }

    static func pageScrollDeltas(
        direction: ScrollDirection,
        pages: UInt8,
        visibleFrame: CGRect
    ) -> (horizontal: Int32, vertical: Int32)? {
        guard pages > 0, visibleFrame.width > 0, visibleFrame.height > 0,
              !visibleFrame.isInfinite, !visibleFrame.isNull
        else { return nil }
        let pageCount = CGFloat(pages)
        let verticalMagnitude = Int32(min(
            10_000,
            max(1, (visibleFrame.height * 0.9 * pageCount).rounded())
        ))
        let horizontalMagnitude = Int32(min(
            10_000,
            max(1, (visibleFrame.width * 0.9 * pageCount).rounded())
        ))
        return switch direction {
        case .up: (0, verticalMagnitude)
        case .down: (0, -verticalMagnitude)
        case .left: (horizontalMagnitude, 0)
        case .right: (-horizontalMagnitude, 0)
        }
    }

    public func executeContextAction(
        action: Action,
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext
    ) async throws {
        do {
            try rejectSecureInput(for: action)
            guard AXIsProcessTrusted() else {
                throw ExecutionFailure.accessibilityPermissionMissing
            }
            let displayFingerprint = try await verifyLiveContext(
                context,
                frameValidation: .identityOnly,
                requireFrontmost: action.requiresForegroundApplication
            )
            try await guardState.authorizeContextAction(
                action: action,
                sequence: sequence,
                stateGeneration: stateGeneration,
                displayFingerprint: displayFingerprint,
                windowID: context.windowID,
                application: context.application
            )
            try rejectSecureInput(for: action)
            try await dispatchContextAction(action, processID: context.processID)
            try await guardState.accept(sequence: sequence)
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func authorizeCaptureAction(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        do {
            let displayFingerprint = try await verifyLiveContext(
                capture,
                requireFrontmost: false
            )
            try await guardState.authorize(
                action: action,
                sequence: sequence,
                screenshotGeneration: screenshotGeneration,
                displayFingerprint: displayFingerprint,
                application: capture.application
            )
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func readClipboard(
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws -> String {
        do {
            let displayFingerprint = try await verifyLiveContext(
                capture,
                requireFrontmost: false
            )
            try await guardState.authorize(
                action: .readClipboard,
                sequence: sequence,
                screenshotGeneration: screenshotGeneration,
                displayFingerprint: displayFingerprint,
                application: capture.application
            )
            let text = try Self.clipboardText(
                from: .general,
                maximumBytes: maximumClipboardTextBytesV2
            )
            try await guardState.accept(sequence: sequence)
            return text
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func readClipboardV2(
        sequence: UInt64,
        stateGeneration: UInt64,
        context: WindowContext,
        maximumBytes: Int = maximumClipboardTextBytesV2
    ) async throws -> String {
        do {
            let displayFingerprint = try await verifyLiveContext(
                context,
                requireFrontmost: false
            )
            try await guardState.authorizeClipboardV2(
                sequence: sequence,
                stateGeneration: stateGeneration,
                displayFingerprint: displayFingerprint,
                windowID: context.windowID,
                application: context.application
            )
            let text = try Self.clipboardText(from: .general, maximumBytes: maximumBytes)
            try await guardState.accept(sequence: sequence)
            return text
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func readGlobalClipboard(
        sequence: UInt64,
        maximumBytes: Int = maximumClipboardTextBytesV2
    ) async throws -> String {
        do {
            try await guardState.authorizeGlobalClipboard(sequence: sequence)
            let text = try Self.clipboardText(from: .general, maximumBytes: maximumBytes)
            try await guardState.accept(sequence: sequence)
            return text
        } catch {
            releasePressedState()
            throw error
        }
    }

    public func releasePressedState() {
        if leftMouseIsDown {
            postMouse(type: .leftMouseUp, point: CGEvent(source: nil)?.location ?? .zero, button: .left)
            leftMouseIsDown = false
        }
        if let heldKeyCode {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: heldKeyCode, keyDown: false)
            event?.flags = heldKeyUpFlags
            event?.post(tap: .cghidEventTap)
            self.heldKeyCode = nil
            heldKeyUpFlags = []
        }
    }

    private func verifyLiveContext(
        _ capture: CapturedWindow,
        frameValidation: WindowFrameValidation = .exact,
        requireFrontmost: Bool = true
    ) async throws -> String {
        try await verifyLiveContext(
            capture.windowContext,
            frameValidation: frameValidation,
            requireFrontmost: requireFrontmost
        )
    }

    private func verifyLiveContext(
        _ context: WindowContext,
        frameValidation: WindowFrameValidation = .approximate,
        requireFrontmost: Bool = true
    ) async throws -> String {
        if requireFrontmost {
            guard WindowCapture.isFrontmost(
                application: context.application,
                requiredProcessID: context.processID
            ) else {
                throw ExecutionFailure.applicationChanged
            }
            guard WindowCapture.isWindowFrontmost(
                processID: context.processID,
                windowID: context.windowID
            ) else {
                throw ExecutionFailure.windowChanged
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: Self.requiresOnScreenWindowList(
                frameValidation: frameValidation,
                requireFrontmost: requireFrontmost
            )
        )
        guard let window = content.windows.first(where: { $0.windowID == context.windowID }),
              window.owningApplication?.processID == context.processID,
              Self.windowFrameMatches(
                  window.frame,
                  expected: context.windowFrame,
                  validation: frameValidation
              )
        else {
            throw ExecutionFailure.windowChanged
        }
        guard let display = WindowCapture.selectedDisplay(
            for: window.frame,
            from: content.displays
        ) else {
            throw ExecutionFailure.displayChanged
        }
        let fingerprint = WindowCapture.displayFingerprint(content.displays, selected: display)
        guard fingerprint == context.displayFingerprint else { throw ExecutionFailure.displayChanged }
        return fingerprint
    }

    static func windowFrameMatches(
        _ actual: CGRect,
        expected: CGRect,
        validation: WindowFrameValidation
    ) -> Bool {
        switch validation {
        case .exact:
            actual.equalTo(expected)
        case .approximate:
            AccessibilityRuntime.windowMatchScore(actual, expected) >= 0.9
        case .identityOnly:
            true
        }
    }

    static func requiresOnScreenWindowList(
        frameValidation: WindowFrameValidation,
        requireFrontmost: Bool
    ) -> Bool {
        requireFrontmost && frameValidation != .identityOnly
    }

    static func usesFrontmostHIDRouting(for key: String) -> Bool {
        Action.key(key).mayChangeFrontmostWindow
    }

    static func clipboardText(
        from pasteboard: NSPasteboard,
        maximumBytes: Int
    ) throws -> String {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            throw ExecutionFailure.clipboardEmpty
        }
        guard items.contains(where: { $0.types.contains(.string) }) else {
            throw ExecutionFailure.clipboardNonText
        }
        guard let text = pasteboard.string(forType: .string) else {
            throw ExecutionFailure.clipboardUnavailable
        }
        guard !text.isEmpty else {
            throw ExecutionFailure.clipboardEmpty
        }
        guard maximumBytes > 0, text.utf8.count <= maximumBytes else {
            throw ExecutionFailure.clipboardTooLarge
        }
        return text
    }

    static func requiresSecureInputClear(_ action: Action) -> Bool {
        switch action {
        case .screenshot, .screenshotApplication, .readClipboard, .zoom, .wait:
            false
        default:
            true
        }
    }

    static func requiresSecureInputClear(_ action: ActionV2) -> Bool {
        switch action {
        case .observe, .launchApplication, .readClipboard:
            false
        default:
            true
        }
    }

    private func rejectSecureInput(for action: Action) throws {
        if Self.requiresSecureInputClear(action), secureInputEnabled() {
            throw ExecutionFailure.protectedSystemSurface
        }
    }

    private func rejectSecureInput(for action: ActionV2) throws {
        if Self.requiresSecureInputClear(action), secureInputEnabled() {
            throw ExecutionFailure.protectedSystemSurface
        }
    }

    private func dispatchContextAction(_ action: Action, processID: pid_t) async throws {
        switch action {
        case let .type(text):
            try typeText(text, processID: processID)
        case let .key(key):
            try postKey(key, processID: processID)
        case let .holdKey(key, durationMilliseconds):
            let parsed = try KeyParser.parse(key)
            guard let down = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: true
            ) else {
                throw ExecutionFailure.eventCreationFailed
            }
            down.flags = parsed.keyDownFlags
            down.post(tap: .cghidEventTap)
            heldKeyCode = parsed.keyCode
            heldKeyUpFlags = parsed.keyUpFlags
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
            guard let up = CGEvent(
                keyboardEventSource: nil,
                virtualKey: parsed.keyCode,
                keyDown: false
            ) else {
                throw ExecutionFailure.eventCreationFailed
            }
            up.flags = parsed.keyUpFlags
            up.post(tap: .cghidEventTap)
            heldKeyCode = nil
            heldKeyUpFlags = []
        case let .scroll(deltaX, deltaY, nil):
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else {
                throw ExecutionFailure.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
        case let .wait(durationMilliseconds):
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
        default:
            throw ExecutionFailure.actionRequiresCapture
        }
    }

    private func dispatch(_ action: Action, capture: CapturedWindow) async throws {
        switch action {
        case .screenshot, .screenshotApplication, .readClipboard, .zoom:
            throw ExecutionFailure.actionRequiresCapture
        case let .leftClick(point):
            try click(point, capture: capture, button: .left, count: 1)
        case let .rightClick(point):
            try click(point, capture: capture, button: .right, count: 1)
        case let .middleClick(point):
            try click(point, capture: capture, button: .center, count: 1)
        case let .doubleClick(point):
            try click(point, capture: capture, button: .left, count: 2)
        case let .tripleClick(point):
            try click(point, capture: capture, button: .left, count: 3)
        case let .mouseMove(point):
            let screenPoint = try mapped(point, capture: capture)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: screenPoint, mouseButton: .left) else {
                throw ExecutionFailure.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
        case let .scroll(deltaX, deltaY, coordinate):
            if let coordinate {
                let screenPoint = try mapped(coordinate, capture: capture)
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: screenPoint, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: deltaY,
                wheel2: deltaX,
                wheel3: 0
            ) else {
                throw ExecutionFailure.eventCreationFailed
            }
            event.post(tap: .cghidEventTap)
        case let .leftClickDrag(start, end, durationMilliseconds):
            let startPoint = try mapped(start, capture: capture)
            let endPoint = try mapped(end, capture: capture)
            try requireMouseEvent(type: .leftMouseDown, point: startPoint, button: .left)
            leftMouseIsDown = true
            try await Task.sleep(for: .milliseconds(durationMilliseconds ?? 500))
            try requireMouseEvent(type: .leftMouseDragged, point: endPoint, button: .left)
            try requireMouseEvent(type: .leftMouseUp, point: endPoint, button: .left)
            leftMouseIsDown = false
        case .leftMouseDown:
            let point = CGEvent(source: nil)?.location ?? capture.windowFrame.origin
            try requireMouseEvent(type: .leftMouseDown, point: point, button: .left)
            leftMouseIsDown = true
        case .leftMouseUp:
            let point = CGEvent(source: nil)?.location ?? capture.windowFrame.origin
            try requireMouseEvent(type: .leftMouseUp, point: point, button: .left)
            leftMouseIsDown = false
        case let .type(text):
            try typeText(text, processID: capture.processID)
        case let .key(key):
            try postKey(key, processID: capture.processID)
        case let .holdKey(key, durationMilliseconds):
            let parsed = try KeyParser.parse(key)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true) else {
                throw ExecutionFailure.eventCreationFailed
            }
            down.flags = parsed.keyDownFlags
            down.post(tap: .cghidEventTap)
            heldKeyCode = parsed.keyCode
            heldKeyUpFlags = parsed.keyUpFlags
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
                throw ExecutionFailure.eventCreationFailed
            }
            up.flags = parsed.keyUpFlags
            up.post(tap: .cghidEventTap)
            heldKeyCode = nil
            heldKeyUpFlags = []
        case let .wait(durationMilliseconds):
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
        }
    }

    private func click(_ point: Point, capture: CapturedWindow, button: CGMouseButton, count: Int64) throws {
        let location = try mapped(point, capture: capture)
        let downType: CGEventType = button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown)
        let upType: CGEventType = button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
        for clickState in Self.clickStates(count: count) {
            guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
                  let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: location, mouseButton: button)
            else {
                throw ExecutionFailure.eventCreationFailed
            }
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    static func clickStates(count: Int64) -> ClosedRange<Int64> {
        precondition(count > 0)
        return 1 ... count
    }

    private func mapped(_ point: Point, capture: CapturedWindow) throws -> CGPoint {
        guard let mapped = CoordinateMapper.screenPoint(
            imagePoint: point,
            pixelWidth: capture.pixelWidth,
            pixelHeight: capture.pixelHeight,
            windowFrame: capture.coordinateFrame
        ) else {
            throw GuardFailure.coordinateOutOfBounds
        }
        return mapped
    }

    private func requireMouseEvent(type: CGEventType, point: CGPoint, button: CGMouseButton) throws {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ExecutionFailure.eventCreationFailed
        }
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(type: CGEventType, point: CGPoint, button: CGMouseButton) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
    }

    private func typeText(_ text: String, processID: pid_t) throws {
        if setFocusedValue(text, processID: processID) {
            return
        }
        for chunk in text.utf16.chunked(maximumCount: 20) {
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
            else {
                throw ExecutionFailure.eventCreationFailed
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.postToPid(processID)
            up.postToPid(processID)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func setFocusedValue(_ text: String, processID: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(processID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
            let focusedValue,
            CFGetTypeID(focusedValue) == AXUIElementGetTypeID()
        else {
            return false
        }
        let focused = focusedValue as! AXUIElement
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            focused,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return false
        }
        var currentValue: CFTypeRef?
        let current = if AXUIElementCopyAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            &currentValue
        ) == .success {
            currentValue as? String ?? ""
        } else {
            ""
        }
        var placeholderValue: CFTypeRef?
        let placeholder: String? = if AXUIElementCopyAttributeValue(
            focused,
            kAXPlaceholderValueAttribute as CFString,
            &placeholderValue
        ) == .success {
            placeholderValue as? String
        } else {
            nil
        }
        var labelValue: CFTypeRef?
        let label: String? = if AXUIElementCopyAttributeValue(
            focused,
            kAXDescriptionAttribute as CFString,
            &labelValue
        ) == .success {
            labelValue as? String
        } else {
            nil
        }
        var roleValue: CFTypeRef?
        let role: String = if AXUIElementCopyAttributeValue(
            focused,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success {
            roleValue as? String ?? "AXUnknown"
        } else {
            "AXUnknown"
        }
        let normalizedPlaceholder = AccessibilityTextNormalization.placeholder(
            placeholder,
            value: current,
            label: label,
            role: role,
            isSettable: settable.boolValue
        )
        let selectedRange = selectedTextRange(focused)
        return AXUIElementSetAttributeValue(
            focused,
            kAXValueAttribute as CFString,
            Self.insertionValue(
                current: current,
                placeholder: normalizedPlaceholder,
                text: text,
                selectedRange: selectedRange
            ) as CFString
        ) == .success
    }

    private func selectedTextRange(_ element: AXUIElement) -> NSRange? {
        var rawValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rawValue
        ) == .success,
            let rawValue,
            CFGetTypeID(rawValue) == AXValueGetTypeID()
        else {
            return nil
        }
        let value = rawValue as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    static func insertionValue(current: String, placeholder: String?, text: String) -> String {
        insertionValue(
            current: current,
            placeholder: placeholder,
            text: text,
            selectedRange: nil
        )
    }

    static func insertionValue(
        current: String,
        placeholder: String?,
        text: String,
        selectedRange: NSRange?
    ) -> String {
        let base = AccessibilityTextNormalization.value(
            current,
            placeholder: placeholder
        ) ?? ""
        guard let selectedRange else { return base + text }
        let utf16Length = (base as NSString).length
        guard selectedRange.location <= utf16Length,
              selectedRange.length <= utf16Length - selectedRange.location
        else {
            return base + text
        }
        return (base as NSString).replacingCharacters(in: selectedRange, with: text)
    }

    private func postKey(_ value: String, processID: pid_t) throws {
        let parsed = try KeyParser.parse(value)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false)
        else {
            throw ExecutionFailure.eventCreationFailed
        }
        down.flags = parsed.keyDownFlags
        up.flags = parsed.keyUpFlags
        if Self.usesFrontmostHIDRouting(for: value) {
            // Window-management shortcuts must enter normal HID routing so the
            // frontmost eligible application can select or create its window.
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        } else {
            down.postToPid(processID)
            up.postToPid(processID)
        }
    }
}

struct ParsedKey: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let modifierFlag: CGEventFlags

    init(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        modifierFlag: CGEventFlags = []
    ) {
        self.keyCode = keyCode
        self.flags = flags
        self.modifierFlag = modifierFlag
    }

    var keyDownFlags: CGEventFlags {
        flags.union(modifierFlag)
    }

    var keyUpFlags: CGEventFlags {
        flags
    }
}

enum KeyParser {
    static func parse(_ value: String) throws -> ParsedKey {
        let components = value.uppercased().split(separator: "+").map(String.init)
        guard let rawKeyName = components.last else {
            throw ExecutionFailure.unsupportedKey
        }
        let keyName = normalizedKeyName(rawKeyName)
        guard let keyCode = keyCodes[keyName]
        else {
            throw ExecutionFailure.unsupportedKey
        }
        var flags: CGEventFlags = []
        for modifier in components.dropLast() {
            switch modifier {
            case "CMD", "COMMAND", "SUPER": flags.insert(.maskCommand)
            case "CTRL", "CONTROL": flags.insert(.maskControl)
            case "ALT", "OPTION": flags.insert(.maskAlternate)
            case "SHIFT": flags.insert(.maskShift)
            default: throw ExecutionFailure.unsupportedKey
            }
        }
        return ParsedKey(
            keyCode: keyCode,
            flags: flags,
            modifierFlag: modifierFlags[keyName] ?? []
        )
    }

    private static func normalizedKeyName(_ value: String) -> String {
        switch value {
        case "PAGE UP", "PAGE_UP", "PAGE-UP": "PAGEUP"
        case "PAGE DOWN", "PAGE_DOWN", "PAGE-DOWN": "PAGEDOWN"
        default: value
        }
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37,
        "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "N": 45, "M": 46, ".": 47, "TAB": 48, "SPACE": 49, "`": 50,
        "DELETE": 51, "BACKSPACE": 51,
        "ESC": 53, "ESCAPE": 53, "RETURN": 36, "ENTER": 36,
        "CMD": 55, "COMMAND": 55, "SUPER": 55, "SHIFT": 56,
        "ALT": 58, "OPTION": 58, "CTRL": 59, "CONTROL": 59,
        "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
        "PAGEUP": 116, "PAGEDOWN": 121, "HOME": 115, "END": 119,
    ]

    private static let modifierFlags: [String: CGEventFlags] = [
        "CMD": .maskCommand,
        "COMMAND": .maskCommand,
        "SUPER": .maskCommand,
        "SHIFT": .maskShift,
        "ALT": .maskAlternate,
        "OPTION": .maskAlternate,
        "CTRL": .maskControl,
        "CONTROL": .maskControl,
    ]
}

private extension Collection where Element == UInt16 {
    func chunked(maximumCount: Int) -> [[UInt16]] {
        var result: [[UInt16]] = []
        var index = startIndex
        while index != endIndex {
            let next = self.index(index, offsetBy: maximumCount, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index ..< next]))
            index = next
        }
        return result
    }
}
