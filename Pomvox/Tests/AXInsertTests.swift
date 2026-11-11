import AppKit
import XCTest
@testable import Pomvox

/// The opt-in AX insert prototype (#225): the read-back policy against a fake
/// field, and `Paster.perform` falling through to ⌘V/clipboard on anything
/// short of a verified insert.
final class AXInsertTests: XCTestCase {

    /// A text field whose setter can behave, lie (claim success, drop text),
    /// mangle, or fail.
    private final class FakeField: AXTextTarget {
        enum Setter { case honest, dropsText, mangles, fails }
        var text: String?
        var range: NSRange?
        var setter: Setter
        init(_ text: String?, range: NSRange?, setter: Setter = .honest) {
            self.text = text; self.range = range; self.setter = setter
        }
        func value() -> String? { text }
        func selectedRange() -> NSRange? { range }
        func setSelectedText(_ new: String) -> Bool {
            switch setter {
            case .fails: return false
            case .dropsText: return true
            case .mangles: text = (text ?? "") + new.uppercased(); return true
            case .honest:
                guard let t = text, let r = range else { return false }
                text = (t as NSString).replacingCharacters(in: r, with: new)
                return true
            }
        }
    }

    // MARK: - read-back policy

    func testHonestFieldIsInsertedAtTheSelection() {
        let field = FakeField("Hello world", range: NSRange(location: 6, length: 5))
        XCTAssertEqual(AXInsert.insert("there", into: field), .inserted)
        XCTAssertEqual(field.text, "Hello there")
    }

    func testNonASCIIRangesAreUTF16() {
        let field = FakeField("👋 x", range: NSRange(location: 3, length: 1))  // 👋 is 2 UTF-16 units
        XCTAssertEqual(AXInsert.insert("café", into: field), .inserted)
        XCTAssertEqual(field.text, "👋 café")
    }

    func testSetterThatClaimsSuccessButDropsTextIsAMismatch() {
        let field = FakeField("abc", range: NSRange(location: 3, length: 0), setter: .dropsText)
        XCTAssertEqual(AXInsert.insert("def", into: field), .mismatch(valueChanged: false))
    }

    func testSetterThatChangesTheWrongThingIsAMismatch() {
        let field = FakeField("abc", range: NSRange(location: 0, length: 0), setter: .mangles)
        XCTAssertEqual(AXInsert.insert("def", into: field), .mismatch(valueChanged: true))
    }

    func testFailingSetterOrUnreadableFieldIsAnError() {
        XCTAssertEqual(AXInsert.insert("x", into: FakeField("a", range: NSRange(location: 0, length: 0),
                                                            setter: .fails)), .error)
        XCTAssertEqual(AXInsert.insert("x", into: FakeField(nil, range: NSRange(location: 0, length: 0))), .error)
        XCTAssertEqual(AXInsert.insert("x", into: FakeField("a", range: nil)), .error)
        XCTAssertEqual(AXInsert.insert("x", into: FakeField("a", range: NSRange(location: 5, length: 0))), .error)
    }

    func testNoTargetIsNoFocus() {
        XCTAssertEqual(AXInsert.insert("x", into: nil), .noFocus)
    }

    func testOffByDefaultAndOptInByDefaultsOrEnv() {
        let defaults = UserDefaults(suiteName: "app.pomvox.test.\(UUID().uuidString)")!
        XCTAssertFalse(AXInsert.enabled(defaults: defaults, environment: [:]))
        XCTAssertTrue(AXInsert.enabled(defaults: defaults, environment: [AXInsert.envKey: "1"]))
        defaults.set(true, forKey: AXInsert.defaultsKey)
        XCTAssertTrue(AXInsert.enabled(defaults: defaults, environment: [:]))
    }

    // MARK: - Paster.perform integration

    @MainActor
    private func run(_ result: AXInsertResult?, focused: Bool = true)
        async -> (outcome: PasteOutcome, pb: NSPasteboard, posted: Bool, axCalls: Int) {
        let pb = NSPasteboard(name: .init("app.pomvox.ax-test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("old", forType: .string)
        let request = await Paster.prepare(using: PasteCoordinator(), targetIsCurrent: { true })!
        var posted = false
        var calls = 0
        let outcome = Paster.perform("dictated", request: request, to: pb, focusedAcceptsText: focused,
                                     axInsert: result.map { r in { calls += 1; return r } },
                                     synthesizePaste: { posted = true }, schedule: { _, _ in })
        return (outcome, pb, posted, calls)
    }

    @MainActor
    func testVerifiedInsertSkipsPasteAndLeavesClipboardAlone() async {
        let r = await run(.inserted)
        XCTAssertEqual(r.outcome, .pasted)
        XCTAssertFalse(r.posted)
        XCTAssertEqual(r.axCalls, 1)
        XCTAssertEqual(r.pb.string(forType: .string), "old")
    }

    @MainActor
    func testMismatchErrorAndNoFocusFallThroughToPaste() async {
        for result: AXInsertResult in [.mismatch(valueChanged: false), .mismatch(valueChanged: true),
                                       .error, .noFocus] {
            let r = await run(result)
            XCTAssertEqual(r.outcome, .pasted, "\(result)")
            XCTAssertTrue(r.posted, "\(result)")
            XCTAssertEqual(r.pb.string(forType: .string), "dictated", "\(result)")  // staged for ⌘V
        }
    }

    @MainActor
    func testFailedInsertWithNoFocusStillLeavesTextOnClipboard() async {
        let r = await run(.noFocus, focused: false)
        XCTAssertEqual(r.outcome, .pasteUnverified)
        XCTAssertEqual(r.pb.string(forType: .string), "dictated")
    }

    @MainActor
    func testDefaultPathNeverCallsAX() async {
        let r = await run(nil)
        XCTAssertEqual(r.outcome, .pasted)
        XCTAssertTrue(r.posted)
        XCTAssertEqual(r.axCalls, 0)
    }

    @MainActor
    func testChangedTargetCopiesWithoutTryingAX() async {
        let pb = NSPasteboard(name: .init("app.pomvox.ax-test.\(UUID().uuidString)"))
        pb.clearContents()
        let request = await Paster.prepare(using: PasteCoordinator(), targetIsCurrent: { false })!
        var calls = 0
        let outcome = Paster.perform("dictated", request: request, to: pb, focusedAcceptsText: true,
                                     axInsert: { calls += 1; return .inserted },
                                     synthesizePaste: {}, schedule: { _, _ in })
        XCTAssertEqual(outcome, .copiedToClipboard)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(pb.string(forType: .string), "dictated")
    }
}
