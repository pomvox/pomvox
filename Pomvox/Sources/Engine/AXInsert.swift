import ApplicationServices
import Foundation

/// What an Accessibility insert attempt did. Anything but `.inserted` means
/// the caller must fall through to the normal ⌘V/clipboard path (#225).
enum AXInsertResult: Equatable {
    case inserted                       // set succeeded and the read-back matched
    case mismatch(valueChanged: Bool)   // set claimed success, read-back disagreed
    case error                          // value/range unreadable, or the set failed
    case noFocus                        // no AX text target (or a secure field)
}

/// The three AX operations the insert needs, so the read-back policy is
/// testable without a real focused field. Ranges are UTF-16 (`NSString`), as AX
/// reports them.
protocol AXTextTarget {
    func value() -> String?
    func selectedRange() -> NSRange?
    func setSelectedText(_ text: String) -> Bool
}

/// Prototype: insert the transcript through `kAXSelectedTextAttribute` instead
/// of clipboard + ⌘V (#225). Off by default; opt in with
/// `defaults write app.pomvox.hub PomvoxAXInsert -bool YES` or
/// `POMVOX_AX_INSERT=1`. AX setters can report success and drop the text, so
/// the field is read back and anything short of an exact match falls through
/// to the paste path — never lose words.
enum AXInsert {
    static let defaultsKey = "PomvoxAXInsert"
    static let envKey = "POMVOX_AX_INSERT"
    /// Bounds each AX call on the opt-in path; the default AX timeout is ~6 s
    /// against a hung app.
    static let messagingTimeout: Float = 0.25

    static func enabled(defaults: UserDefaults = .standard,
                        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[envKey] == "1" || defaults.bool(forKey: defaultsKey)
    }

    /// Read once, so the default paste path costs a single cached-bool check.
    static let isEnabled = enabled()

    /// Pure read-back policy: replace the selection, then require the field's
    /// value to equal the expected edit exactly.
    static func insert(_ text: String, into target: AXTextTarget?) -> AXInsertResult {
        guard let target else { return .noFocus }
        guard let before = target.value(), let range = target.selectedRange(),
              range.location != NSNotFound,
              NSMaxRange(range) <= (before as NSString).length else { return .error }
        guard target.setSelectedText(text) else { return .error }
        let expected = (before as NSString).replacingCharacters(in: range, with: text)
        guard let after = target.value() else { return .mismatch(valueChanged: true) }
        return after == expected ? .inserted : .mismatch(valueChanged: after != before)
    }

    /// Production entry: the system-wide focused element, timed and logged
    /// locally (length and outcome only, never the text).
    @MainActor
    static func insertIntoFocused(_ text: String) -> AXInsertResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let result = insert(text, into: LiveAXTextTarget.focused())
        NSLog("paste: ax-insert %@ %.1fms (%d chars)", String(describing: result),
              (CFAbsoluteTimeGetCurrent() - t0) * 1000, text.count)
        return result
    }
}

/// The real focused element. Secure fields are refused: their value can't be
/// read back, so a "mismatch" there could type a password twice.
struct LiveAXTextTarget: AXTextTarget {
    let element: AXUIElement

    static func focused() -> LiveAXTextTarget? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, AXInsert.messagingTimeout)
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, AXInsert.messagingTimeout)
        var subrole: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole) == .success,
           subrole as? String == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        return LiveAXTextTarget(element: element)
    }

    func value() -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func selectedRange() -> NSRange? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func setSelectedText(_ text: String) -> Bool {
        AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success
    }
}
