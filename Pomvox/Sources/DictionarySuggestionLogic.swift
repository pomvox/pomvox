import Foundation

/// A word the user keeps fixing in History, offered for the Dictionary's
/// Words list. Nothing is added until the user taps it.
struct DictionarySuggestion: Equatable, Identifiable {
    /// The word as the user last wrote it in a fix.
    let word: String
    /// How many History fixes write this word.
    let fixes: Int

    var id: String { DictionarySuggestionLogic.key(word) }
}

/// Pure counting behind "you keep fixing this word" (#227). A History fix is
/// a fixup rule with `origin == "history"`; fixing the same word the same way
/// means several of those rules share a target. The count is derived from
/// dictionary.toml on every call, so there is no fix log to store or migrate.
enum DictionarySuggestionLogic {
    /// History fixes of one word before it is suggested.
    static let threshold = 3

    /// Identity of a word for counting and dismissal: case and surrounding
    /// whitespace don't make a different word.
    static func key(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// One suggestion per word with at least `threshold` History fixes, in
    /// the order the words were first fixed. Words already in the Words list
    /// and dismissed words are never suggested; removal rules (empty target)
    /// name no word and are skipped.
    static func suggestions(file: DictionaryFile, dismissed: Set<String>,
                            threshold: Int = threshold) -> [DictionarySuggestion] {
        let known = Set(file.words.map(key))
        var order: [String] = []
        var byKey: [String: DictionarySuggestion] = [:]
        for rule in file.rules where rule.origin == "history" {
            let k = key(rule.target)
            guard !k.isEmpty, !known.contains(k), !dismissed.contains(k) else { continue }
            if byKey[k] == nil { order.append(k) }
            byKey[k] = DictionarySuggestion(
                word: rule.target.trimmingCharacters(in: .whitespaces),
                fixes: (byKey[k]?.fixes ?? 0) + 1)
        }
        return order.compactMap { byKey[$0] }.filter { $0.fixes >= max(1, threshold) }
    }
}
