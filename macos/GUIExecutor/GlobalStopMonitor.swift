import ApplicationServices
import Foundation

public enum GlobalStopFailure: Error, Equatable {
    case accessibilityPermissionMissing
    case eventTapCreationFailed
}

private final class EventTapContext: @unchecked Sendable {
    var eventTap: CFMachPort?
    let onEscape: @Sendable () -> Void

    init(onEscape: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
    }
}

private func globalStopEventCallback(
    _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let context = Unmanaged<EventTapContext>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let eventTap = context.eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown,
          GlobalStopMonitor.isEscape(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
    else {
        return Unmanaged.passUnretained(event)
    }
    DispatchQueue.main.async(execute: context.onEscape)
    return nil
}

public final class GlobalStopMonitor: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let context: EventTapContext

    public init(onEscape: @escaping @Sendable () -> Void) {
        context = EventTapContext(onEscape: onEscape)
    }

    public func start() throws {
        precondition(Thread.isMainThread)
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else { throw GlobalStopFailure.accessibilityPermissionMissing }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: globalStopEventCallback,
            userInfo: pointer
        ) else {
            throw GlobalStopFailure.eventTapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw GlobalStopFailure.eventTapCreationFailed
        }
        self.eventTap = eventTap
        context.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    public func stop() {
        precondition(Thread.isMainThread)
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }
        context.eventTap = nil
        runLoopSource = nil
        eventTap = nil
    }

    static func isEscape(keyCode: Int64) -> Bool {
        keyCode == 53
    }
}
