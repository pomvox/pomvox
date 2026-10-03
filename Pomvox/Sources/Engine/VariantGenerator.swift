import Foundation

/// Deterministic "what might the STT model write instead?" candidates for a
/// dictionary target. These become PRE-CHECKED, EDITABLE chips in the rule
/// editor — never silently added (the VoiceInk lesson). The LLM-backed
/// generator (CleanupEngine.suggestVariants) merges on top when the cleanup
/// model is resident; these heuristics are the always-available floor.
///
/// All variants are lowercase: rule matching is case-insensitive, so a
/// case-only variant would be a no-op, and lowercase reads as "heard text".
enum VariantGenerator {

    static func heuristicVariants(for term: String) -> [String] {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return [] }
        var out: [String] = []
        func add(_ v: String) {
            let s = v.trimmingCharacters(in: .whitespaces).lowercased()
            guard !s.isEmpty, s.caseInsensitiveCompare(t) != .orderedSame,
                  !out.contains(s) else { return }
            out.append(s)
        }

        // 1. Hump/digit/punctuation split: "ChargeBee" → "charge bee",
        //    "Qwen3" → "qwen 3", "parakeet-mlx" → "parakeet mlx".
        add(splitWords(t).joined(separator: " "))

        // 2. Acronyms (any all-caps run of 2+): "GPT" → "g p t" (letter names
        //    often transcribe spaced).
        if t.count >= 2, t.allSatisfy({ $0.isUppercase && $0.isLetter }) {
            add(t.map(String.init).joined(separator: " "))
        }

        // 3. Hyphen/underscore ↔ space (covered by 1 for mixed terms, but a
        //    lowercase "foo-bar" has no humps, so do it explicitly).
        if t.contains("-") || t.contains("_") {
            add(t.replacingOccurrences(of: "-", with: " ")
                 .replacingOccurrences(of: "_", with: " "))
        }
        return out
    }

    /// Split on case humps, letter↔digit boundaries, and separators.
    /// "ChargeBee" → ["Charge", "Bee"]; "Qwen3" → ["Qwen", "3"].
    private static func splitWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var prev: Character? = nil
        for ch in s {
            if ch == "-" || ch == "_" || ch == " " {
                if !current.isEmpty { words.append(current); current = "" }
            } else if let p = prev,
                      (ch.isUppercase && p.isLowercase)
                          || (ch.isNumber && !p.isNumber)
                          || (!ch.isNumber && p.isNumber) {
                if !current.isEmpty { words.append(current); current = "" }
                current.append(ch)
            } else {
                current.append(ch)
            }
            prev = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Drop a leading list marker, and nothing else.
///
/// Bullets (`-`, `*`, `•`) and numbering (`2.` / `1)`) are markers. A digit
/// that is part of the variant — "3 d printing", "3d printing" — is not, and
/// stripping it used to turn those into "d printing".
func stripVariantListPrefix(_ line: String) -> String {
    var t = line.trimmingCharacters(in: .whitespaces)
    let bullets: Set<Character> = ["-", "*", "•"]
    if let first = t.first, bullets.contains(first) {
        while let c = t.first, bullets.contains(c) { t.removeFirst() }
        while t.first == " " { t.removeFirst() }
    }
    var index = t.startIndex
    var sawDigit = false
    while index < t.endIndex, t[index].isNumber {
        sawDigit = true
        t.formIndex(after: &index)
    }
    if sawDigit, index < t.endIndex, t[index] == "." || t[index] == ")" {
        t.formIndex(after: &index)
        while index < t.endIndex, t[index] == " " { t.formIndex(after: &index) }
        return String(t[index...])
    }
    return t
}

/// Clean an LLM "list the mishearings" response into chip-ready variants:
/// strip bullets/numbering, lowercase, drop echoes of the term itself, drop
/// anything over 5 words (explanatory prose, not a variant), dedupe, cap at 6.
func parseVariantLines(_ raw: String, term: String) -> [String] {
    var out: [String] = []
    for line in raw.components(separatedBy: "\n") {
        let t = stripVariantListPrefix(line).trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty,
              t.caseInsensitiveCompare(term) != .orderedSame,
              t.components(separatedBy: " ").count <= 5,
              !out.contains(t) else { continue }
        out.append(t)
        if out.count == 6 { break }
    }
    return out
}
