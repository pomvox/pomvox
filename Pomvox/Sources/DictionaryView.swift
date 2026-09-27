import AppKit
import SwiftUI

/// The Dictionary page: words the cleanup model should spell your way,
/// misheard-term fixup rules (many-to-one, per-rule toggle, hit counts), and
/// a live test box that shows exactly what the rules do to any text.
struct DictionaryView: View {
    @EnvironmentObject var store: DictionaryStore
    @State private var newWord = ""
    @State private var editorState: RuleEditorState?   // Task 10 presents the sheet
    @State private var testText = ""
    @State private var stats: [String: DictionaryRuleStats] = DictionaryStatsStore.shared.allStats()

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Dictionary") {
                if store.applyingHint {
                    Chip(text: "Applying…", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let err = store.parseError { parseErrorBanner(err) }
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    wordsSection
                    rulesSection
                    testSection
                }
                .padding(.horizontal, 34).padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editorState) { state in
            RuleEditorSheet(state: state)   // Task 10
        }
        .onReceive(NotificationCenter.default
            .publisher(for: .pomvoxDictionaryStatsDidChange)
            .receive(on: RunLoop.main)) { _ in
            stats = DictionaryStatsStore.shared.allStats()
        }
    }

    // MARK: - Sections

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Words",
                          subtitle: "Pomvox tells the cleanup model to spell these your way.")
            FlowLayout(spacing: 6) {
                ForEach(store.file.words, id: \.self) { word in
                    WordChip(word: word) { store.removeWord(word) }
                }
                TextField("Add a word…", text: $newWord)
                    .textFieldStyle(.plain).font(Typo.ui(12.5))
                    .frame(width: 120)
                    .onSubmit {
                        store.addWord(newWord)
                        newWord = ""
                    }
            }
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionHeader("Fixups",
                              subtitle: "When Pomvox hears the left side, it writes the right side. Always applied — even with cleanup off.")
                Spacer()
                Menu {
                    Button("Import words (.txt)…") { importFile(kind: .words) }
                    Button("Import rules (.csv)…") { importFile(kind: .rules) }
                    Divider()
                    Button("Export words (.txt)…") { exportFile(kind: .words) }
                    Button("Export rules (.csv)…") { exportFile(kind: .rules) }
                } label: {
                    Chip(text: "Import / Export", systemImage: "square.and.arrow.up.on.square")
                }
                .menuStyle(.borderlessButton).fixedSize()
                Button {
                    editorState = RuleEditorState(editing: nil)
                } label: {
                    Chip(text: "New rule", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New fixup rule")
            }
            if store.file.rules.isEmpty {
                Text("No rules yet. Add one here, or select a mistake in History and choose “Fix this…”.")
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
            }
            ForEach(store.file.rules) { rule in
                RuleRow(rule: rule, stats: stats[rule.id],
                        onToggle: { store.setRuleEnabled(id: rule.id, $0) },
                        onEdit: { editorState = RuleEditorState(editing: rule) },
                        onDelete: { store.removeRule(id: rule.id) })
            }
        }
    }

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader("Try it",
                          subtitle: "Type anything (or paste a transcript) and watch the rules apply.")
            TextField("say something pomvox would mishear…", text: $testText, axis: .vertical)
                .textFieldStyle(.plain).font(Typo.ui(13))
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pane2))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
            if !testText.isEmpty {
                let applied = PomvoxDictionary(file: store.file).applyReporting(testText)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11)).foregroundStyle(Palette.ember)
                    Text(applied.text.isEmpty ? "(everything removed)" : applied.text)
                        .font(Typo.ui(13)).foregroundStyle(Palette.ink)
                }
                if !applied.fired.isEmpty {
                    Text("\(applied.fired.count) rule\(applied.fired.count == 1 ? "" : "s") fired")
                        .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Typo.display(17)).foregroundStyle(Palette.ink)
            Text(subtitle).font(Typo.ui(12)).foregroundStyle(Palette.muted)
        }
    }

    // MARK: - Import / export

    private enum InterchangeKind { case words, rules }

    private func importFile(kind: InterchangeKind) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.begin { resp in
            guard resp == .OK, let url = panel.url,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            switch kind {
            case .words: store.addWords(DictionaryInterchange.parseWordList(text))
            case .rules: store.upsertAll(DictionaryInterchange.parseRulesCSV(text))
            }
        }
    }

    private func exportFile(kind: InterchangeKind) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = kind == .words ? "pomvox-words.txt" : "pomvox-rules.csv"
        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            let text = kind == .words
                ? DictionaryInterchange.wordList(store.file.words)
                : DictionaryInterchange.rulesCSV(store.file.rules)
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func parseErrorBanner(_ err: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13)).foregroundStyle(Palette.ember)
            Text("dictionary.toml couldn’t be read — \(err). Fix the file, then reload. In-app edits are paused so your changes aren’t overwritten.")
                .font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            Spacer()
            Button("Reload") { store.reloadFromDisk() }
                .buttonStyle(.plain).font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.ember)
        }
        .padding(.horizontal, 34).padding(.vertical, 11)
        .background(Palette.emberSoft)
    }
}

/// Identifiable wrapper so `.sheet(item:)` drives the editor (Task 10 fills in
/// the sheet body; `seedSources`/`referenceTranscript` feed add-from-History).
struct RuleEditorState: Identifiable {
    let id = UUID()
    var editing: DictionaryRule?
    var seedSources: [String] = []
    var referenceTranscript: String? = nil
}

private struct WordChip: View {
    let word: String
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Text(word).font(Typo.ui(12.5)).foregroundStyle(Palette.ink)
            if hovering {
                Button(action: onDelete) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(word)")
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(Palette.pane2))
        .overlay(Capsule().stroke(Palette.hair, lineWidth: 0.5))
        .onHover { hovering = $0 }
    }
}

private struct RuleRow: View {
    let rule: DictionaryRule
    let stats: DictionaryRuleStats?
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: onToggle))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                .accessibilityLabel("Enable rule for \(rule.target.isEmpty ? "removal" : rule.target)")
            FlowLayout(spacing: 4) {
                ForEach(rule.sources, id: \.self) { s in
                    Text(s).font(Typo.ui(12))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.pane2))
                }
            }
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Palette.muted)
            if rule.target.isEmpty {
                Chip(text: "removes", systemImage: "scissors")
            } else {
                Text(rule.target).font(Typo.ui(13, .semibold)).foregroundStyle(Palette.ink)
            }
            Spacer()
            if let s = stats {
                Text("×\(s.count)").font(Typo.ui(11)).monospacedDigit().foregroundStyle(Palette.muted)
                    .help("Fired \(s.count) time\(s.count == 1 ? "" : "s"), last \(Date(timeIntervalSince1970: s.lastFired).formatted(.relative(presentation: .named)))")
            }
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Edit rule")
            Button(action: onDelete) { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Palette.muted)
                .accessibilityLabel("Delete rule")
        }
        .padding(.vertical, 7)
        .opacity(rule.enabled ? 1 : 0.55)
    }
}

/// Minimal wrap layout for chips (macOS 14 `Layout`).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = layout(subviews: subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = layout(subviews: subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for i in row.range {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: .unspecified)
                x += size.width + spacing
            }
        }
    }

    private struct Row { var range: Range<Int>; var y: CGFloat; var height: CGFloat }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var start = 0, x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                rows.append(Row(range: start..<i, y: y, height: rowHeight))
                y += rowHeight + spacing
                start = i; x = 0; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        rows.append(Row(range: start..<subviews.count, y: y, height: rowHeight))
        return rows
    }
}

/// Rule editor: target ("what Pomvox should write"), sources ("what it
/// hears"), generated variant suggestions as toggleable chips (visible,
/// consented — never silently added), an optional tappable transcript (the
/// add-from-History path seeds it), and a live preview against sample text.
struct RuleEditorSheet: View {
    let state: RuleEditorState
    @EnvironmentObject var store: DictionaryStore
    @Environment(\.dismiss) private var dismiss

    @State private var target = ""
    @State private var sources: [String] = []
    @State private var newSource = ""
    @State private var suggestions: [String] = []       // offered, not yet accepted
    @State private var accepted: Set<String> = []       // checked suggestion chips
    @State private var rejected: Set<String> = []       // unchecked suggestions stay rejected across refreshes
    @State private var previewText = ""
    /// Model-generated suggestions need a second generation the SDK backend
    /// does not offer; spelling-based suggestions still appear.
    private let modelSuggestions = NativeEngine.shared.cleanupControls.modelVariantSuggestions

    private var isEditing: Bool { state.editing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(isEditing ? "Edit fixup" : "New fixup")
                .font(Typo.display(18)).foregroundStyle(Palette.ink)

            VStack(alignment: .leading, spacing: 6) {
                Text("POMVOX SHOULD WRITE").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                TextField("e.g. Pomvox — leave empty to remove the heard words", text: $target)
                    .textFieldStyle(.roundedBorder).font(Typo.ui(13))
                    .onChange(of: target) { _, t in refreshSuggestions(for: t) }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("WHEN IT HEARS").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                FlowLayout(spacing: 6) {
                    ForEach(sources, id: \.self) { s in
                        HStack(spacing: 4) {
                            Text(s).font(Typo.ui(12.5))
                            Button { sources.removeAll { $0 == s } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(s)")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Palette.pane2))
                    }
                    TextField("add what it hears…", text: $newSource)
                        .textFieldStyle(.plain).font(Typo.ui(12.5)).frame(width: 140)
                        .onSubmit { addSource(newSource); newSource = "" }
                }
                if !modelSuggestions {
                    Text("Suggestions come from spelling patterns only — the on-device cleanup pack "
                         + "doesn't generate them.")
                        .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                }
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("LIKELY MISHEARINGS — TAP TO INCLUDE")
                        .font(Typo.ui(10, .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions, id: \.self) { v in
                            let on = accepted.contains(v)
                            Button {
                                if on {
                                    accepted.remove(v)
                                    rejected.insert(v)
                                } else {
                                    accepted.insert(v)
                                    rejected.remove(v)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 10))
                                    Text(v).font(Typo.ui(12.5))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(on ? Palette.sel : Palette.pane2))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(on ? "Exclude" : "Include") variant \(v)")
                        }
                    }
                }
            }

            if let transcript = state.referenceTranscript {
                VStack(alignment: .leading, spacing: 6) {
                    Text("FROM YOUR TRANSCRIPT — TAP THE WORDS IT GOT WRONG")
                        .font(Typo.ui(10, .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
                    FlowLayout(spacing: 4) {
                        ForEach(Array(tokenize(transcript).enumerated()), id: \.offset) { _, word in
                            Button { appendToPendingSource(word) } label: {
                                Text(word).font(Typo.ui(12.5))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Palette.pane2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if !newSource.isEmpty {
                        Text("building: “\(newSource)” — press return to add")
                            .font(Typo.ui(11)).foregroundStyle(Palette.muted)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("PREVIEW").font(Typo.ui(10, .semibold)).tracking(0.6)
                    .foregroundStyle(Palette.muted)
                TextField("type a sentence to test this rule…", text: $previewText)
                    .textFieldStyle(.roundedBorder).font(Typo.ui(12.5))
                if !previewText.isEmpty {
                    Text(previewApplied())
                        .font(Typo.ui(12.5)).foregroundStyle(Palette.ember)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isEditing ? "Save" : "Add rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(effectiveSources().isEmpty)
            }
        }
        .padding(26)
        .frame(width: 480)
        .onAppear {
            if let r = state.editing {
                target = r.target
                sources = r.sources
            } else {
                sources = state.seedSources
            }
            refreshSuggestions(for: target)
        }
        .task(id: target) {
            // Debounce: one LLM request per pause in typing, auto-cancelled by
            // SwiftUI on the next keystroke or when the sheet closes — a burst
            // of keystrokes must not queue generate() calls ahead of clean().
            guard modelSuggestions, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let llm = await NativeEngine.shared.variantSuggester.suggestVariants(for: target)
            guard !Task.isCancelled, !llm.isEmpty else { return }
            let known = Set((sources + suggestions).map { $0.lowercased() })
            let fresh = llm.filter { !known.contains($0.lowercased()) }
            suggestions.append(contentsOf: fresh)
            // LLM extras arrive UNCHECKED — accepted is deliberately untouched.
        }
    }

    private func addSource(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !sources.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame })
        else { return }
        sources.append(t)
    }

    /// Word-picker taps build a phrase in the pending-source field so
    /// multi-word mishearings ("pom box") are two taps, then return.
    private func appendToPendingSource(_ word: String) {
        newSource = newSource.isEmpty ? word : newSource + " " + word
    }

    private func refreshSuggestions(for term: String) {
        let already = Set(sources.map { $0.lowercased() })
        suggestions = VariantGenerator.heuristicVariants(for: term)
            .filter { !already.contains($0) }
        accepted = Set(suggestions).subtracting(rejected)   // pre-checked, but respect explicit rejections
    }

    private func effectiveSources() -> [String] {
        sources + suggestions.filter { accepted.contains($0) }
    }

    private func previewApplied() -> String {
        let rule = DictionaryRule(sources: effectiveSources(), target: target,
                                  enabled: true, origin: "manual")
        return PomvoxDictionary(file: DictionaryFile(rules: [rule]))
            .apply(previewText)
    }

    private func save() {
        let origin = state.editing?.origin
            ?? (state.referenceTranscript != nil ? "history"
                : accepted.isEmpty ? "manual" : "variant")
        store.upsert(
            DictionaryRule(sources: effectiveSources(), target: target,
                           enabled: state.editing?.enabled ?? true, origin: origin),
            replacingID: state.editing?.id)
        dismiss()
    }

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }
}
