import Foundation

/// Port of `src/pomvox/dictionary.py` — the user dictionary, Phase 4. Two
/// independent, pure-logic mechanisms (vector-parity tested against
/// `tests/test_dictionary.py`):
///
/// - `dictionaryPromptHint` injects proper nouns / jargon into the cleanup
///   system prompt so the LLM prefers the user's spelling. Constant for the
///   engine's lifetime, so it rides inside the cached prompt prefix and costs
///   nothing per utterance (changing it is re-arm/restart-required).
/// - `substitute` runs literal post-replacements on the final text, so a term
///   the STT model reliably mishears is fixed even when cleanup is off, times
///   out, or its output is rejected — the robust path, never model-dependent.
///   Like every stage it only rewrites; it can fix or re-case a term but never
///   drops the surrounding words.

/// A cleanup-prompt rule pinning the spelling of *words*; "" if none.
func dictionaryPromptHint(_ words: [String]) -> String {
    let terms = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !terms.isEmpty else { return "" }
    return "- Keep these terms spelled exactly as written when you hear them "
        + "(match phonetically, fix the spelling): " + terms.joined(separator: ", ") + ".\n"
}

/// Pre-compile (misheard → correct) pairs for `substitute`. Longest source
/// first so a multi-word phrase wins over a shorter key it contains;
/// whole-word, case-insensitive so "para" never rewrites inside "apparatus".
/// An empty source is skipped — it would match everywhere.
func compileReplacements(_ pairs: [(String, String)]) -> [(NSRegularExpression, String)] {
    var compiled: [(NSRegularExpression, String)] = []
    for (src, repl) in pairs.sorted(by: { $0.0.count > $1.0.count }) {
        let stripped = src.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else {
            NSLog("dictionary: ignoring empty replacement key")
            continue
        }
        let pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: stripped) + "(?!\\w)"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            NSLog("dictionary: bad replacement pattern for %@", stripped)
            continue
        }
        compiled.append((re, repl))
    }
    return compiled
}

/// Apply pre-compiled replacements to *text*, left to right.
func substitute(_ text: String, _ compiled: [(NSRegularExpression, String)]) -> String {
    var out = text
    for (re, repl) in compiled {
        let range = NSRange(out.startIndex..., in: out)
        // An escaped template treats the value literally — a "$1"/"\1"/"&" in a
        // corrected spelling must not be read as a backreference.
        out = re.stringByReplacingMatches(
            in: out, options: [], range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: repl))
    }
    return out
}

/// One compiled rule: the whole-word regex, the literal-escaped template, the
/// owning rule's stable id (for fired-rule reporting), and whether it's a wipe
/// (empty target — those get punctuation-absorbing treatment).
struct CompiledRule {
    let re: NSRegularExpression
    let template: String
    let ruleID: String
    let isWipe: Bool
}

/// Compile enabled rules, expanding many-to-one sources into per-source
/// regexes. Ordering contract unchanged: longest source first across ALL
/// rules, whole-word, case-insensitive, empty sources skipped. Wipe rules
/// additionally absorb one trailing punctuation mark so "um." never leaves
/// a stranded "." (the v0.1.8 rough edge).
func compileRules(_ rules: [DictionaryRule]) -> [CompiledRule] {
    var flat: [(src: String, rule: DictionaryRule)] = []
    for rule in rules where rule.enabled {
        for src in rule.sources { flat.append((src, rule)) }
    }
    var compiled: [CompiledRule] = []
    for (src, rule) in flat.sorted(by: { $0.src.count > $1.src.count }) {
        let stripped = src.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else {
            NSLog("dictionary: ignoring empty replacement key")
            continue
        }
        let isWipe = rule.target.isEmpty
        var pattern = "(?<!\\w)" + NSRegularExpression.escapedPattern(for: stripped) + "(?!\\w)"
        // Absorb one trailing punctuation mark, but only when something other
        // than trailing whitespace follows it — a sentence-ending mark at the
        // very end of the input (possibly followed only by whitespace, e.g. a
        // trailing space/newline from LLM cleanup output) belongs to whatever
        // real content precedes it (kept by tidyAfterWipe), not to the wiped
        // word. (Fully-punctuation leftovers, e.g. a whole-transcript wipe,
        // still collapse to "" via tidyAfterWipe's no-word-chars check.)
        if isWipe { pattern += "(?:[.,!?;:](?!\\s*\\z))?" }
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else {
            NSLog("dictionary: bad replacement pattern for %@", stripped)
            continue
        }
        compiled.append(CompiledRule(
            re: re,
            template: NSRegularExpression.escapedTemplate(for: rule.target),
            ruleID: rule.id,
            isWipe: isWipe))
    }
    return compiled
}

/// `substitute` with fired-rule reporting and post-wipe tidying. Fired ids are
/// unique, in first-fired order.
func substituteReporting(_ text: String, _ compiled: [CompiledRule]) -> (text: String, fired: [String]) {
    var out = text
    var fired: [String] = []
    var wiped = false
    for c in compiled {
        let range = NSRange(out.startIndex..., in: out)
        guard c.re.numberOfMatches(in: out, options: [], range: range) > 0 else { continue }
        out = c.re.stringByReplacingMatches(
            in: out, options: [], range: range, withTemplate: c.template)
        if !fired.contains(c.ruleID) { fired.append(c.ruleID) }
        if c.isWipe { wiped = true }
    }
    if wiped { out = tidyAfterWipe(out) }
    return (out, fired)
}

/// Collapse the debris a wipe leaves behind: runs of spaces, a space before
/// punctuation, and leading/trailing whitespace. Only runs when a wipe rule
/// fired — non-wipe substitutions never reshape their surroundings. If
/// nothing but punctuation/whitespace survives (a whole-transcript wipe, e.g.
/// "um um um." with every word wiped), collapse to "" — the wipe-contract
/// classification depends on that, not on a stray leftover period.
func tidyAfterWipe(_ text: String) -> String {
    var out = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    out = out.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
    out = out.trimmingCharacters(in: .whitespacesAndNewlines)
    guard out.range(of: #"\w"#, options: .regularExpression) != nil else { return "" }
    return out
}

/// The user dictionary, built once from config and read per utterance. `hint`
/// is handed to the cleanup engine at arm (it becomes part of the cached prompt
/// prefix); `apply`/`applyReporting` run on the final text just before insertion.
struct PomvoxDictionary {
    let hint: String
    /// The words behind `hint`, in file order (empty when disabled). The SDK
    /// backend selects its bounded vocabulary from these; the replacement
    /// rules below always see the complete dictionary.
    let cleanupWords: [String]
    private let compiled: [CompiledRule]
    private let enabled: Bool

    /// v2 entry point: build from the parsed dictionary file.
    init(file: DictionaryFile, enabled: Bool = true) {
        self.enabled = enabled
        self.hint = enabled ? dictionaryPromptHint(file.words) : ""
        self.cleanupWords = enabled ? file.words : []
        self.compiled = enabled ? compileRules(file.rules) : []
        if enabled, !self.hint.isEmpty || !self.compiled.isEmpty {
            let termCount = file.words.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
            NSLog("dictionary: %d term(s), %d compiled replacement(s)", termCount, self.compiled.count)
        }
    }

    /// Legacy pairs entry point (pre-v2 tests + parity vectors). Each pair maps
    /// to a single-source rule, so both inits share one compile path.
    init(words: [String], replacements: [(String, String)], enabled: Bool = true) {
        self.init(
            file: DictionaryFile(
                words: words,
                rules: replacements.map {
                    DictionaryRule(sources: [$0.0], target: $0.1, enabled: true, origin: "manual")
                }),
            enabled: enabled)
    }

    func apply(_ text: String) -> String { applyReporting(text).text }

    func applyReporting(_ text: String) -> DictionaryApplied {
        guard enabled, !text.isEmpty, !compiled.isEmpty else {
            return DictionaryApplied(text: text, fired: [])
        }
        let (out, fired) = substituteReporting(text, compiled)
        return DictionaryApplied(text: out, fired: fired)
    }
}

struct DictionaryApplied: Equatable {
    let text: String
    let fired: [String]
}
