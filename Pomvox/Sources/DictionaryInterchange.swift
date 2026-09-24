import Foundation

/// Plain-text import/export: one word per line for the words list, and
/// `source1|source2,target` per line for rules. The separator is the last
/// comma that is not escaped with a backslash, so sources may contain raw
/// commas and a target may contain a comma written as `\,` (a literal
/// backslash is `\\`). `#` comments and blank lines are skipped. Import is
/// merge-with-dedupe (the store's addWords/upsertAll already dedupe), never
/// a destructive replace.
enum DictionaryInterchange {

    static func parseWordList(_ text: String) -> [String] {
        lines(text).filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func wordList(_ words: [String]) -> String {
        words.map { $0 + "\n" }.joined()
    }

    static func parseRulesCSV(_ text: String) -> [DictionaryRule] {
        lines(text).compactMap { line in
            guard !line.isEmpty, !line.hasPrefix("#"),
                  let split = splitSourcesAndTarget(line) else { return nil }
            let sources = split.sources.components(separatedBy: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let target = unescapeTarget(split.target.trimmingCharacters(in: .whitespaces))
            guard !sources.isEmpty else { return nil }
            return DictionaryRule(sources: sources, target: target,
                                  enabled: true, origin: "manual")
        }
    }

    static func rulesCSV(_ rules: [DictionaryRule]) -> String {
        rules.map { rule in
            rule.sources.joined(separator: "|") + "," + escapeTarget(rule.target) + "\n"
        }.joined()
    }

    /// Split on `\n` after folding `\r\n` and bare `\r` into `\n`. Trimming
    /// spaces only (the old behavior) left a trailing CR on every row of a
    /// Windows file, so "MLX" imported as "MLX\r". Folding first also keeps
    /// `\r\n` from becoming a blank row, which `CharacterSet.newlines` would
    /// do because both CR and LF are members.
    private static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Last comma not preceded by an odd run of backslashes. That comma is
    /// the sources/target separator; an escaped `\,` belongs to the target.
    private static func splitSourcesAndTarget(_ line: String) -> (sources: String, target: String)? {
        var i = line.endIndex
        while i > line.startIndex {
            i = line.index(before: i)
            guard line[i] == "," else { continue }
            var slashes = 0
            var j = i
            while j > line.startIndex {
                let prev = line.index(before: j)
                guard line[prev] == "\\" else { break }
                slashes += 1
                j = prev
            }
            if slashes % 2 == 0 {
                return (String(line[..<i]), String(line[line.index(after: i)...]))
            }
        }
        return nil
    }

    /// Escape `\` and `,` so a later import still splits on the separator
    /// comma rather than one that belongs to the target.
    private static func escapeTarget(_ target: String) -> String {
        var out = ""
        out.reserveCapacity(target.count)
        for ch in target {
            if ch == "\\" { out += "\\\\" }
            else if ch == "," { out += "\\," }
            else { out.append(ch) }
        }
        return out
    }

    /// Inverse of `escapeTarget`. A backslash that does not introduce `\\`
    /// or `\,` is kept, so a hand-written row is not silently shortened.
    private static func unescapeTarget(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count,
               chars[i + 1] == "\\" || chars[i + 1] == "," {
                out.append(chars[i + 1])
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }
}
