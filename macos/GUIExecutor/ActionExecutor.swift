import AppKit
import ApplicationServices
import CoreGraphics
import DeviceProtocol
import DeviceSecurity
import Foundation
@preconcurrency import ScreenCaptureKit

public enum ExecutionFailure: Error, Equatable {
    case accessibilityPermissionMissing
    case applicationChanged
    case windowChanged
    case displayChanged
    case eventCreationFailed
    case unsupportedKey
    case actionRequiresCapture
    case clipboardContentUnavailable
    case clipboardContentTooLarge

    public var diagnosticCode: String {
        switch self {
        case .accessibilityPermissionMissing: "accessibility_permission_missing"
        case .applicationChanged: "approved_application_changed"
        case .windowChanged: "approved_window_changed"
        case .displayChanged: "display_layout_changed"
        case .eventCreationFailed: "input_event_creation_failed"
        case .unsupportedKey: "unsupported_key"
        case .actionRequiresCapture: "invalid_capture_action_dispatch"
        case .clipboardContentUnavailable: "clipboard_content_unavailable"
        case .clipboardContentTooLarge: "clipboard_content_too_large"
        }
    }

    public var userMessage: String {
        switch self {
        case .accessibilityPermissionMissing:
            "Mac Accessibility permission is missing for Agent Remote Device."
        case .applicationChanged:
            "The approved application changed after the latest screenshot. Take a fresh screenshot."
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
        case .clipboardContentUnavailable:
            "The Mac clipboard does not currently contain text."
        case .clipboardContentTooLarge:
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

@MainActor
public final class ActionExecutor {
    private let guardState: SessionGuard
    private var leftMouseIsDown = false
    private var heldKeyCode: CGKeyCode?

    public init(guardState: SessionGuard) {
        self.guardState = guardState
    }

    public func execute(
        action: Action,
        sequence: UInt64,
        screenshotGeneration: UInt64,
        capture: CapturedWindow
    ) async throws {
        do {
            guard AXIsProcessTrusted() else {
                throw ExecutionFailure.accessibilityPermissionMissing
            }
            let displayFingerprint = try await verifyLiveContext(capture)
            try await guardState.authorize(
                action: action,
                sequence: sequence,
                screenshotGeneration: screenshotGeneration,
                displayFingerprint: displayFingerprint,
                application: capture.application
            )
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
            guard AXIsProcessTrusted() else {
                throw ExecutionFailure.accessibilityPermissionMissing
            }
            let displayFingerprint = try await verifyLiveContext(context)
            try await guardState.authorizeElement(
                action: action,
                sequence: sequence,
                target: target,
                displayFingerprint: displayFingerprint,
                windowID: context.windowID,
                application: context.application
            )
            try accessibility.perform(action, target: target)
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
            let displayFingerprint = try await verifyLiveContext(capture)
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
            let displayFingerprint = try await verifyLiveContext(capture)
            try await guardState.authorize(
                action: .readClipboard,
                sequence: sequence,
                screenshotGeneration: screenshotGeneration,
                displayFingerprint: displayFingerprint,
                application: capture.application
            )
            guard let text = NSPasteboard.general.string(forType: .string) else {
                throw ExecutionFailure.clipboardContentUnavailable
            }
            guard text.utf8.count <= 64 * 1_024 else {
                throw ExecutionFailure.clipboardContentTooLarge
            }
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
        context: WindowContext
    ) async throws -> String {
        do {
            let displayFingerprint = try await verifyLiveContext(context)
            try await guardState.authorizeClipboardV2(
                sequence: sequence,
                stateGeneration: stateGeneration,
                displayFingerprint: displayFingerprint,
                windowID: context.windowID,
                application: context.application
            )
            guard let text = NSPasteboard.general.string(forType: .string) else {
                throw ExecutionFailure.clipboardContentUnavailable
            }
            guard text.utf8.count <= 64 * 1_024 else {
                throw ExecutionFailure.clipboardContentTooLarge
            }
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
            CGEvent(keyboardEventSource: nil, virtualKey: heldKeyCode, keyDown: false)?.post(tap: .cghidEventTap)
            self.heldKeyCode = nil
        }
    }

    private func verifyLiveContext(_ capture: CapturedWindow) async throws -> String {
        try await verifyLiveContext(capture.windowContext)
    }

    private func verifyLiveContext(_ context: WindowContext) async throws -> String {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier == context.processID,
              frontmost.bundleIdentifier == context.application.bundleIdentifier
        else {
            throw ExecutionFailure.applicationChanged
        }
        let content = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == context.windowID }),
              window.owningApplication?.processID == context.processID,
              window.frame.equalTo(context.windowFrame)
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
            try typeText(text)
        case let .key(key):
            try postKey(key)
        case let .holdKey(key, durationMilliseconds):
            let parsed = try KeyParser.parse(key)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true) else {
                throw ExecutionFailure.eventCreationFailed
            }
            down.flags = parsed.flags
            down.post(tap: .cghidEventTap)
            heldKeyCode = parsed.keyCode
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
            guard let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false) else {
                throw ExecutionFailure.eventCreationFailed
            }
            up.flags = parsed.flags
            up.post(tap: .cghidEventTap)
            heldKeyCode = nil
        case let .wait(durationMilliseconds):
            try await Task.sleep(for: .milliseconds(durationMilliseconds))
        }
    }

    private func click(_ point: Point, capture: CapturedWindow, button: CGMouseButton, count: Int64) throws {
        let location = try mapped(point, capture: capture)
        let downType: CGEventType = button == .right ? .rightMouseDown : (button == .center ? .otherMouseDown : .leftMouseDown)
        let upType: CGEventType = button == .right ? .rightMouseUp : (button == .center ? .otherMouseUp : .leftMouseUp)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: location, mouseButton: button),
              let up = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: location, mouseButton: button)
        else {
            throw ExecutionFailure.eventCreationFailed
        }
        down.setIntegerValueField(.mouseEventClickState, value: count)
        up.setIntegerValueField(.mouseEventClickState, value: count)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
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

    private func typeText(_ text: String) throws {
        for chunk in text.utf16.chunked(maximumCount: 20) {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
                throw ExecutionFailure.eventCreationFailed
            }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ value: String) throws {
        let parsed = try KeyParser.parse(value)
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: parsed.keyCode, keyDown: false)
        else {
            throw ExecutionFailure.eventCreationFailed
        }
        down.flags = parsed.flags
        up.flags = parsed.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

struct ParsedKey: Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
}

enum KeyParser {
    static func parse(_ value: String) throws -> ParsedKey {
        let components = value.uppercased().split(separator: "+").map(String.init)
        guard let keyName = components.last, let keyCode = keyCodes[keyName] else {
            throw ExecutionFailure.unsupportedKey
        }
        var flags: CGEventFlags = []
        for modifier in components.dropLast() {
            switch modifier {
            case "CMD", "COMMAND": flags.insert(.maskCommand)
            case "CTRL", "CONTROL": flags.insert(.maskControl)
            case "ALT", "OPTION": flags.insert(.maskAlternate)
            case "SHIFT": flags.insert(.maskShift)
            default: throw ExecutionFailure.unsupportedKey
            }
        }
        return ParsedKey(keyCode: keyCode, flags: flags)
    }

    private static let keyCodes: [String: CGKeyCode] = [
        "A": 0, "S": 1, "D": 2, "F": 3, "H": 4, "G": 5, "Z": 6, "X": 7,
        "C": 8, "V": 9, "B": 11, "Q": 12, "W": 13, "E": 14, "R": 15,
        "Y": 16, "T": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
        "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "O": 31, "U": 32, "[": 33, "I": 34, "P": 35, "L": 37,
        "J": 38, "'": 39, "K": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "N": 45, "M": 46, ".": 47, "TAB": 48, "SPACE": 49, "DELETE": 51,
        "ESC": 53, "ESCAPE": 53, "RETURN": 36, "ENTER": 36,
        "LEFT": 123, "RIGHT": 124, "DOWN": 125, "UP": 126,
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
