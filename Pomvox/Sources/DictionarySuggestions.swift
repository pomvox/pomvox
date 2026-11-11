import Foundation
import SwiftUI

/// Words the user has already answered a suggestion for (added or dismissed),
/// so each word is suggested once. A JSON sidecar next to dictionary.toml —
/// deliberately not history.db, whose schema is frozen. Local only. A corrupt
/// or unwritable file degrades to "nothing dismissed" with a log line.
@MainActor
final class DictionarySuggestionStore: ObservableObject {
    @MainActor static let shared = DictionarySuggestionStore()

    @Published private(set) var dismissed: Set<String>
    private let path: String

    init(path: String = DictionarySuggestionStore.defaultPath()) {
        self.path = path
        guard let data = FileManager.default.contents(atPath: path) else {
            dismissed = []
            return
        }
        do {
            dismissed = Set(try JSONDecoder().decode([String].self, from: data))
        } catch {
            NSLog("dictionary: suggestions sidecar unreadable, starting empty: %@",
                  String(describing: error))
            dismissed = []
        }
    }

    nonisolated static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let o = environment["POMVOX_DICTIONARY_SUGGESTIONS_PATH"], !o.isEmpty {
            return o
        }
        return NSString(string: "~/.pomvox/dictionary-suggestions.json").expandingTildeInPath
    }

    /// Never suggest `word` again. Persists across relaunch.
    func dismiss(_ word: String) {
        let k = DictionarySuggestionLogic.key(word)
        guard !k.isEmpty, dismissed.insert(k).inserted else { return }
        do {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try JSONEncoder().encode(dismissed.sorted())
                .write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            // Still dismissed for this session; it may come back after relaunch.
            NSLog("dictionary: saving suggestions sidecar failed: %@", String(describing: error))
        }
    }
}

/// "You keep fixing this word" strip for the History and Dictionary pages.
/// Shows one suggestion at a time and writes nothing until a button is tapped.
struct DictionarySuggestionBanner: View {
    @EnvironmentObject var store: DictionaryStore
    @ObservedObject private var dismissals = DictionarySuggestionStore.shared

    var body: some View {
        // A malformed dictionary.toml blocks in-app edits, so "Add" would do
        // nothing: don't offer it.
        if store.parseError == nil,
           let s = DictionarySuggestionLogic.suggestions(
               file: store.file, dismissed: dismissals.dismissed).first {
            HStack(spacing: 10) {
                Image(systemName: "character.book.closed")
                    .font(.system(size: 13)).foregroundStyle(Palette.ember)
                Text("You’ve fixed “\(s.word)” \(s.fixes) times in History. Add it to your Dictionary words?")
                    .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("Add “\(s.word)”") {
                    store.addWord(s.word)
                    dismissals.dismiss(s.word)
                }
                .buttonStyle(.plain).font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.ember)
                Button("Dismiss") { dismissals.dismiss(s.word) }
                    .buttonStyle(.plain).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
            }
            .padding(.horizontal, 34).padding(.vertical, 11)
            .background(Palette.emberSoft)
            .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
        }
    }
}
