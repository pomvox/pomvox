import Foundation

/// Port of `src/pomvox/onboarding.py` `OnboardingFlow` — pure checklist state:
/// probe statuses in, display rows out. The Setup pane renders these rows; the
/// logic is pinned by OnboardingLogicTests (vector parity with
/// tests/test_onboarding.py). No account, no profile quiz — three permission
/// rows with a plain-language *why*.
struct OnboardingFlow {
    /// (key, title, why) — Python's PERMISSIONS tuple, same order.
    static let permissions: [(key: String, title: String, why: String)] = [
        ("microphone", "Microphone", "so Pomvox can hear you"),
        ("input_monitoring", "Input Monitoring", "so the hotkey works in every app"),
        ("accessibility", "Accessibility", "so Pomvox can type your words for you (⌘V)"),
    ]

    static let relaunchNote = "granted — relaunch Pomvox to pick it up"
    /// Input Monitoring is the one grant macOS will not offer to add for you.
    /// `IOHIDRequestAccess` prompts only while the status is *unknown*; once a
    /// prompt has been dismissed or the row deleted, clicking Grant deep-links
    /// to a pane where Pomvox simply isn't listed, with no way forward that the
    /// pane itself suggests. The `+` button is the way out, and nothing on
    /// screen said so (reported 2026-08-30).
    static let manualAddNote =
        "Not listed in System Settings? Click + under that list, pick Pomvox in "
        + "/Applications, switch it on, then relaunch Pomvox."
    /// A translocated or stray copy is worse than unlisted: TCC keys grants to
    /// the app's location, so anything granted to a randomised read-only path
    /// evaporates. Say so before the user fights the pane.
    static let moveToApplicationsNote =
        "Pomvox isn't running from /Applications. Quit it, move Pomvox.app to "
        + "/Applications, and open it from there — macOS ties permissions to "
        + "where the app lives."

    /// Where the running bundle lives — the part of the Input Monitoring
    /// diagnosis that isn't pure, injected so `rows` stays testable.
    enum AppLocation: Equatable {
        case applicationsFolder   // /Applications or ~/Applications
        case translocated         // launched from a DMG/quarantined copy
        case elsewhere            // Downloads, Desktop, a build folder…
    }
    static let staleTccHint =
        "Granted but still red? Remove the app from the list in System Settings "
        + "and add it back."
    static let selfTestText = "Pomvox works! 🎉"

    struct Row: Equatable {
        let key: String
        let title: String
        let why: String
        let granted: Bool?
        var note: String = ""
    }

    func rows(statuses: [String: Bool?], tapInstalled: Bool,
              location: AppLocation = .applicationsFolder) -> [Row] {
        Self.permissions.map { key, title, why in
            let granted = statuses[key] ?? nil
            var note = ""
            if key == "input_monitoring" {
                if granted == true, !tapInstalled {
                    // The grant landed but CGEventTapCreate still fails: macOS
                    // does not extend Input Monitoring to a running process.
                    note = Self.relaunchNote
                } else if granted != true {
                    // Wrong location first: adding a translocated copy to the
                    // list doesn't stick, so telling someone to click + there
                    // would send them in a circle.
                    note = location == .applicationsFolder
                        ? Self.manualAddNote
                        : Self.moveToApplicationsNote
                }
            }
            return Row(key: key, title: title, why: why, granted: granted, note: note)
        }
    }

    func complete(statuses: [String: Bool?], tapInstalled: Bool) -> Bool {
        tapInstalled && Self.permissions.allSatisfy { statuses[$0.key] ?? nil == true }
    }

    /// The Setup pane's 1 Hz poll asks this after every probe refresh: once
    /// every grant is green and the engine is still down, fire ONE silent
    /// arm(). One-shot because a grant that doesn't reach the running process
    /// (Input Monitoring) makes arm() fail every time — the relaunch note is
    /// that path's fix, not a retry loop.
    func readyToAutoArm(statuses: [String: Bool?], engineArmed: Bool,
                        alreadyAttempted: Bool) -> Bool {
        !engineArmed && !alreadyAttempted
            && Self.permissions.allSatisfy { statuses[$0.key] ?? nil == true }
    }
}
