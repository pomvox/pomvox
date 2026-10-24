import CoreGraphics
import Foundation

enum EventTapError: Error {
    /// The tap could not be created — Input Monitoring isn't granted.
    case notPermitted
}

/// Active CGEventTap feeding flagsChanged/keyDown decisions, on a dedicated
/// thread with its own CFRunLoop so it never blocks the SwiftUI run loop. Port
/// of `hotkey.py:EventTap`. The decision closures are called synchronously on
/// the tap thread and must stay fast; the owner (`NativeEngine`) serializes the
/// HotkeyMachine behind them and returns the `Decision` (so swallowed keys are
/// honored). Keyboard modifiers always pass through; keys and mouse side
/// buttons are swallowed only when the decision says so.
///
/// Mouse side buttons (#191) are subscribed only when `mouseButtons` is set
/// (PTT is `mouse4`/`mouse5`), so a keyboard setup gets the tap it always had;
/// they take the modifier path under the machine's synthetic keycodes.
final class EventTap {
    typealias ModifierDecision = (_ keycode: Int, _ isDown: Bool) -> HotkeyMachine.Decision
    typealias KeyDecision = (_ keycode: Int) -> HotkeyMachine.Decision

    /// Where an event goes. Pure, so the routing is unit-tested without a
    /// live tap (which needs Input Monitoring and a window server).
    enum Route: Equatable {
        case modifier(keycode: Int, isDown: Bool)
        case key(keycode: Int)
        case pass
    }

    private let onModifier: ModifierDecision
    private let onKeyDown: KeyDecision
    private let mouseButtons: Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: Thread?
    private var threadRunLoop: CFRunLoop?

    // flagsChanged carries the keycode of the modifier that changed; the
    // matching mask bit tells us whether it went down or up (mirrors hotkey.py).
    private static let modifierMasks: [Int64: CGEventFlags] = [
        63: .maskSecondaryFn,
        58: .maskAlternate, 61: .maskAlternate,
        55: .maskCommand, 54: .maskCommand,
        56: .maskShift, 60: .maskShift,
        59: .maskControl, 62: .maskControl,
    ]

    init(onModifier: @escaping ModifierDecision, onKeyDown: @escaping KeyDecision,
         mouseButtons: Bool = false) {
        self.onModifier = onModifier
        self.onKeyDown = onKeyDown
        self.mouseButtons = mouseButtons
    }

    static func eventMask(mouseButtons: Bool) -> CGEventMask {
        var mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        if mouseButtons {
            mask |= (1 << CGEventType.otherMouseDown.rawValue) | (1 << CGEventType.otherMouseUp.rawValue)
        }
        return CGEventMask(mask)
    }

    /// Fields are autoclosures so each event kind reads only its own field:
    /// the keyboard path does exactly the reads it did before #191.
    static func route(type: CGEventType, keycode: @autoclosure () -> Int64,
                      flags: @autoclosure () -> CGEventFlags, button: @autoclosure () -> Int64) -> Route {
        switch type {
        case .flagsChanged:
            let keycode = keycode()
            guard let mask = modifierMasks[keycode] else { return .pass }
            return .modifier(keycode: Int(keycode), isDown: flags().contains(mask))
        case .keyDown:
            return .key(keycode: Int(keycode()))
        case .otherMouseDown, .otherMouseUp:
            guard let code = HotkeyMachine.mouseButtonKeycode(button()) else { return .pass }
            return .modifier(keycode: code, isDown: type == .otherMouseDown)
        default:
            return .pass
        }
    }

    /// Backstop: if the last strong reference to a still-running tap is ever
    /// dropped without an explicit stop() (e.g. a future bookkeeping bug),
    /// this guarantees the CGEventTap callback — which holds an unretained
    /// pointer to this instance — never keeps firing into freed memory.
    deinit {
        stop()
    }

    /// Create the tap (throws if Input Monitoring isn't granted) and run its
    /// run loop on a dedicated background thread.
    func start() throws {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask(mouseButtons: mouseButtons),
            callback: { _, type, event, refcon in
                let me = Unmanaged<EventTap>.fromOpaque(refcon!).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw EventTapError.notPermitted
        }
        self.tap = tap

        let thread = Thread { [weak self] in
            guard let self, let tap = self.tap else { return }
            let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
            self.source = source
            self.threadRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "app.pomvox.eventtap"
        self.thread = thread
        thread.start()
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let rl = threadRunLoop {
            if let source { CFRunLoopRemoveSource(rl, source, .commonModes) }
            CFRunLoopStop(rl)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil; source = nil; threadRunLoop = nil; thread = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a slow/contended tap; re-enable and pass through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let decision: HotkeyMachine.Decision
        switch Self.route(type: type,
                          keycode: event.getIntegerValueField(.keyboardEventKeycode),
                          flags: event.flags,
                          button: event.getIntegerValueField(.mouseEventButtonNumber)) {
        case .modifier(let keycode, let isDown):
            decision = onModifier(keycode, isDown)
        case .key(let keycode):
            decision = onKeyDown(keycode)
        case .pass:
            return Unmanaged.passUnretained(event)
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}
