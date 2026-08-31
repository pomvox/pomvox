import Foundation

/// The optional dictation mark: one small emoji appended to the final text of
/// every dictation, so a post can show it was dictated without typing it.
///
/// Off by default, and an upgrade never turns it on. Silently appending
/// characters to what someone said is the one thing this app promises not to
/// do, so the mark exists only where the user has explicitly asked for it and
/// only where they can see it: it lands on the *final* text, after cleanup and
/// after the dictionary fixups, so it can never become input the LLM or a
/// replacement rule acts on.
struct Signature: Equatable {
    /// One-click choices in Settings. `[signature] mark` stays free text in the
    /// file, so any emoji works — these are just the ones on offer.
    static let presets = ["🎙️", "🗣️", "✨", "💬", "🎧", "🪶"]
    static let defaultMark = "🎙️"

    /// The longest mark we'll append, in grapheme clusters. A guard, not a
    /// preference: this is a mark, not somewhere to staple a sentence onto the
    /// end of every dictation. An over-long mark reads as off.
    static let maxGraphemes = 8

    let enabled: Bool
    let mark: String

    init(enabled: Bool = false, mark: String = Signature.defaultMark) {
        let trimmed = mark.trimmingCharacters(in: .whitespacesAndNewlines)
        self.mark = trimmed
        self.enabled = enabled && !trimmed.isEmpty && trimmed.count <= Signature.maxGraphemes
    }

    /// Read `[signature]` out of a config document. An absent section is off.
    static func read(_ doc: ConfigDocument) -> Signature {
        Signature(
            enabled: doc.bool("signature", "enabled") ?? false,
            mark: doc.string("signature", "mark") ?? Signature.defaultMark)
    }

    /// Append the mark to `text`, separated by a single space.
    ///
    /// - A no-op on blank text: an empty dictation must stay empty, or the
    ///   engine's empty-transcript path would paste a lone emoji.
    /// - Idempotent. History re-insert re-pastes stored `final_text`, which
    ///   already carries the mark; marking it twice would compound per re-use.
    /// - Trailing whitespace stays trailing (`"done.\n"` → `"done. 🎙️\n"`), so
    ///   a dictation that ended a line still ends it.
    func apply(to text: String) -> String {
        guard enabled, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return text
        }
        let split = text.lastIndex { !$0.isWhitespace }.map(text.index(after:)) ?? text.startIndex
        let body = String(text[..<split])
        let tail = String(text[split...])
        guard !body.hasSuffix(mark) else { return text }
        return body + " " + mark + tail
    }
}
