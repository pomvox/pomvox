import XCTest
@testable import Pomvox

/// Port spec: tests/test_onboarding.py — OnboardingFlow pure logic, the Setup
/// pane is a dumb renderer. Same vectors, same names.
final class OnboardingLogicTests: XCTestCase {

    private let allGranted: [String: Bool?] = [
        "microphone": true, "input_monitoring": true, "accessibility": true,
    ]
    private let flow = OnboardingFlow()

    func testRowsCoverTheThreePermissionsInOrder() {
        let rows = flow.rows(statuses: allGranted, tapInstalled: true)
        XCTAssertEqual(rows.map(\.key), ["microphone", "input_monitoring", "accessibility"])
        XCTAssertTrue(rows.allSatisfy { $0.granted == true })
        XCTAssertTrue(rows.allSatisfy { !$0.why.isEmpty })  // every row explains itself
    }

    func testUnknownProbeStatusPassesThroughAsNil() {
        var statuses = allGranted
        statuses["accessibility"] = Bool?.none
        let rows = flow.rows(statuses: statuses, tapInstalled: true)
        XCTAssertNil(rows[2].granted)
    }

    func testRelaunchNoteWhenGrantedButTapStillDead() {
        // Input Monitoring grants don't reach an already-running process.
        let rows = flow.rows(statuses: allGranted, tapInstalled: false)
        let im = rows[1]
        XCTAssertEqual(im.granted, true)
        XCTAssertTrue(im.note.lowercased().contains("relaunch"))
    }

    /// The *relaunch* note belongs only to granted-but-no-tap. While simply
    /// ungranted the row now carries the "not listed / move to Applications"
    /// guidance instead — telling someone to relaunch would be nonsense when
    /// they haven't granted anything yet. Asserted against the relaunch note
    /// specifically, not against emptiness, since emptiness is no longer the
    /// point. (This is the one place the Swift flow deliberately diverges from
    /// tests/test_onboarding.py's `test_no_relaunch_note_while_simply_ungranted`
    /// — see the note in OnboardingLogic.swift.)
    func testNoRelaunchNoteWhileSimplyUngranted() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        let rows = flow.rows(statuses: statuses, tapInstalled: false)
        XCTAssertNotEqual(rows[1].note, OnboardingFlow.relaunchNote)
    }

    func testCompleteRequiresAllGrantsAndALiveTap() {
        XCTAssertTrue(flow.complete(statuses: allGranted, tapInstalled: true))
        XCTAssertFalse(flow.complete(statuses: allGranted, tapInstalled: false))
        var micDenied = allGranted
        micDenied["microphone"] = false
        XCTAssertFalse(flow.complete(statuses: micDenied, tapInstalled: true))
        var micUnknown = allGranted
        micUnknown["microphone"] = Bool?.none
        XCTAssertFalse(flow.complete(statuses: micUnknown, tapInstalled: true))
    }

    // MARK: - readyToAutoArm (Setup-pane silent re-arm after grants land)

    func testReadyToAutoArmWhenAllGrantedAndEngineDown() {
        XCTAssertTrue(flow.readyToAutoArm(
            statuses: allGranted, engineArmed: false, alreadyAttempted: false))
    }

    func testNotReadyWhileAnyPermissionMissing() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        XCTAssertFalse(flow.readyToAutoArm(
            statuses: statuses, engineArmed: false, alreadyAttempted: false))
    }

    func testNotReadyWhileProbeUnknown() {
        var statuses = allGranted
        statuses["microphone"] = Bool?.none
        XCTAssertFalse(flow.readyToAutoArm(
            statuses: statuses, engineArmed: false, alreadyAttempted: false))
    }

    func testNotReadyWhenEngineAlreadyArmed() {
        XCTAssertFalse(flow.readyToAutoArm(
            statuses: allGranted, engineArmed: true, alreadyAttempted: false))
    }

    func testAutoArmIsOneShot() {
        // A failed attempt (e.g. Input Monitoring grant not reaching the
        // running process) must not retry at 1 Hz — the relaunch note is the
        // fix path, not an arm() storm.
        XCTAssertFalse(flow.readyToAutoArm(
            statuses: allGranted, engineArmed: false, alreadyAttempted: true))
    }

    // MARK: - Input Monitoring: the grant macOS won't offer to add for you

    private func inputRow(_ rows: [OnboardingFlow.Row]) -> OnboardingFlow.Row {
        rows.first { $0.key == "input_monitoring" }!
    }

    /// Reported 2026-08-30: Grant deep-links to Input Monitoring and Pomvox
    /// simply isn't in the list. `IOHIDRequestAccess` only prompts while the
    /// status is unknown, so once a prompt is dismissed the pane offers no way
    /// forward. Point at the `+` button.
    func testUngrantedInputMonitoringExplainsTheManualAdd() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        let row = inputRow(flow.rows(statuses: statuses, tapInstalled: false,
                                     location: .applicationsFolder))
        XCTAssertEqual(row.note, OnboardingFlow.manualAddNote)
        XCTAssertTrue(row.note.contains("+"))
    }

    /// An unknown probe is still "not granted" — the user is just as stuck.
    func testUnknownInputMonitoringAlsoExplainsTheManualAdd() {
        var statuses = allGranted
        statuses["input_monitoring"] = Bool?.none
        let row = inputRow(flow.rows(statuses: statuses, tapInstalled: false,
                                     location: .applicationsFolder))
        XCTAssertEqual(row.note, OnboardingFlow.manualAddNote)
    }

    /// Adding a translocated copy to the list doesn't stick, so "click +"
    /// would send the user in a circle. Location advice wins.
    func testTranslocatedAppIsToldToMoveNotToClickPlus() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        for location in [OnboardingFlow.AppLocation.translocated, .elsewhere] {
            let row = inputRow(flow.rows(statuses: statuses, tapInstalled: false,
                                         location: location))
            XCTAssertEqual(row.note, OnboardingFlow.moveToApplicationsNote)
            XCTAssertFalse(row.note.contains("+"), "must not send them to the + button")
        }
    }

    /// Granted-but-no-tap keeps the relaunch note, whatever the location —
    /// that path is already correct and must not regress.
    func testGrantedButNoTapStillSaysRelaunch() {
        let row = inputRow(flow.rows(statuses: allGranted, tapInstalled: false,
                                     location: .elsewhere))
        XCTAssertEqual(row.note, OnboardingFlow.relaunchNote)
    }

    /// Fully working: no nagging note at all.
    func testGrantedAndTapInstalledHasNoNote() {
        let row = inputRow(flow.rows(statuses: allGranted, tapInstalled: true,
                                     location: .applicationsFolder))
        XCTAssertEqual(row.note, "")
    }

    /// The other two rows never carry Input Monitoring advice.
    func testOtherRowsAreUnaffected() {
        var statuses = allGranted
        statuses["input_monitoring"] = false
        let rows = flow.rows(statuses: statuses, tapInstalled: false, location: .elsewhere)
        for row in rows where row.key != "input_monitoring" {
            XCTAssertEqual(row.note, "", "\(row.key) should carry no note")
        }
    }
}
