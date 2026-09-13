import Foundation

/// Spoken layout commands, applied deterministically after cleanup.
///
/// Dictation apps handle "new line" / "new paragraph" / "bullet" as commands,
/// not as words. Pomvox's cleanup model does neither: it was trained on
/// prose, so a dictated "hi john new line thanks for the update" pastes as
/// "Hi John, new line, thanks for the update." This pass turns the phrases
/// into layout — after the model (so the model's punctuation around the
/// phrase is absorbed), before the dictionary and the dictation mark, and on
/// the raw-fallback path too (a timeout must not also eat the commands).
///
/// Pure text → text; no model, no state. A command fires only where speech
/// would have paused around it:
/// - it must be a whole phrase (word boundaries on both sides), and
/// - it must not be the object of a modifier — "the new line of products",
///   "a bullet point", "silver bullet" stay words. Concretely, the word
///   before the phrase may not be an article, possessive, adjective-ish
///   determiner, or "of" (`blockers`).
/// The model's punctuation immediately around the phrase (", new line,") is
/// consumed with it, and the first letter after a break is capitalized.
enum SpokenFormatting {

    /// Words that, immediately before the phrase, mean it is content.
    private static let blockers: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "our",
        "their", "his", "her", "its", "of", "one", "each", "every", "another",
        "any", "some", "no", "silver", "magic",
    ]

    private struct Command {
        let pattern: NSRegularExpression
        /// What the phrase becomes. `"\n- "` for a bullet, `"\n"`, `"\n\n"`.
        let replacement: String
    }

    /// Each pattern captures (1) the word directly before the phrase, if any,
    /// so the blocker check can run per match, and swallows the punctuation
    /// the model put AFTER the phrase (", new line, thanks" → the second
    /// comma). Punctuation before the phrase belongs to the preceding
    /// sentence ("update. New line" — the period is "update"'s) and stays.
    private static let commands: [Command] = [
        ("new\\s+paragraph", "\n\n"),
        ("new\\s+line", "\n"),
        ("bullet(?:\\s+point)?", "\n- "),
    ].map { phrase, replacement in
        Command(
            pattern: try! NSRegularExpression(
                pattern:
                    #"(?:(\b[A-Za-z']+)\s+)?\b"# + phrase + #"\b[,.;:!?]?\s*"#,
                options: [.caseInsensitive]),
            replacement: replacement)
    }

    /// Apply every command to `text`. Idempotent: running it twice changes
    /// nothing, because the phrases are gone after the first pass.
    static func apply(_ text: String) -> String {
        var out = text
        for command in commands {
            out = rewrite(out, with: command)
        }
        return out
    }

    private static func rewrite(_ text: String, with command: Command) -> String {
        let ns = text as NSString
        let matches = command.pattern.matches(
            in: text, options: [], range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = ""
        var cursor = 0
        for match in matches {
            let leadRange = match.range(at: 1)
            var lead = ""
            if leadRange.location != NSNotFound {
                lead = ns.substring(with: leadRange)
                if blockers.contains(lead.lowercased()) {
                    continue  // content, not a command — leave the whole span alone
                }
            }
            // Keep everything up to the phrase (the lead word included, minus
            // the model's trailing punctuation, which the break replaces).
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !lead.isEmpty { result += lead }
            result = trimTrailingSpaces(result)
            result += command.replacement
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return capitalizeAfterBreaks(result)
    }

    /// Only stray spaces go; the punctuation before a break is the preceding
    /// sentence's and stays ("Hi John,\n", "update.\n").
    private static func trimTrailingSpaces(_ s: String) -> String {
        var out = s
        while out.last == " " { out.removeLast() }
        return out
    }

    /// Capitalize the first letter of each line after a break, as the start
    /// of a new sentence would be.
    private static func capitalizeAfterBreaks(_ s: String) -> String {
        var lines = s.components(separatedBy: "\n")
        for i in lines.indices where i > 0 {
            var line = lines[i]
            let prefix = line.hasPrefix("- ") ? "- " : ""
            var body = String(line.dropFirst(prefix.count))
            if let first = body.first, first.isLetter {
                body = first.uppercased() + body.dropFirst()
            }
            line = prefix + body
            lines[i] = line
        }
        return lines.joined(separator: "\n")
    }
}
