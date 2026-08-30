import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import IOKit.hid

/// Port of `src/pomvox/permissions.py` — detect and guide, never crash. The
/// probes are all non-prompting (the Setup checklist polls them at 1 Hz and the
/// silent auto-arm gates on them at login); `request(_:)` is the only path that
/// fires a native prompt, and it always also opens the matching System Settings
/// pane (native prompts appear once; the deep link is the path for users who
/// dismissed one).
enum Permissions {
    static let settingsLinks: [String: String] = [
        "microphone":
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        "accessibility":
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        "input_monitoring":
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
    ]

    // MARK: - non-prompting probes

    static func microphoneStatus() -> Bool? {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func accessibilityStatus() -> Bool? {
        AXIsProcessTrusted()
    }

    static func inputMonitoringStatus() -> Bool? {
        // kIOHIDAccessTypeUnknown = never asked — not granted, same answer
        // Python gets from CGPreflightListenEventAccess().
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// All probes at once — what the onboarding checklist polls.
    static func statuses() -> [String: Bool?] {
        [
            "microphone": microphoneStatus(),
            "accessibility": accessibilityStatus(),
            "input_monitoring": inputMonitoringStatus(),
        ]
    }

    /// Every probe true — the silent auto-arm gate.
    static func allGranted() -> Bool {
        statuses().values.allSatisfy { $0 == true }
    }

    // MARK: - prompting requests

    /// Fire the native prompt for `key` and open its System Settings pane.
    static func request(_ key: String) {
        switch key {
        case "microphone":
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                NSLog("permissions: mic granted=%@", granted ? "true" : "false")
            }
        case "input_monitoring":
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        case "accessibility":
            _ = AXIsProcessTrustedWithOptions(
                [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        default:
            break
        }
        openSettings(key)
    }

    /// Where the running bundle lives. TCC keys grants to the app's location,
    /// so a copy launched from a DMG (App Translocation puts it under a
    /// randomised `/AppTranslocation/` path) or left in ~/Downloads can't hold
    /// an Input Monitoring grant even after the user adds it by hand.
    static func appLocation() -> OnboardingFlow.AppLocation {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return .translocated }
        let home = NSHomeDirectory()
        if path.hasPrefix("/Applications/") || path.hasPrefix("\(home)/Applications/") {
            return .applicationsFolder
        }
        return .elsewhere
    }

    /// Reveal the app in Finder — the fastest path to dragging it into
    /// /Applications, or onto the Input Monitoring list's `+` sheet.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    static func openSettings(_ key: String) {
        guard let link = settingsLinks[key], let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }
}
