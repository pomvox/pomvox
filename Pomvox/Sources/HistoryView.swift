import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var model: HubModel
    @EnvironmentObject var reinserter: ReinsertController
    @State private var query = ""
    @State private var confirmingDeleteAll = false
    @State private var fixState: RuleEditorState?

    private var results: [Dictation] { model.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "History") {
                SearchField(text: $query)
            }
            if reinserter.phase != .idle { ReinsertBanner() }
            metaBar
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        EmptyResults(searching: !query.isEmpty, failed: model.loadFailed)
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, d in
                            DictationRow(dictation: d, dateStyle: .calendar, showDelete: true,
                                         onFix: { fixState = RuleEditorState(
                                             editing: nil, seedSources: [],
                                             referenceTranscript: $0.raw) })
                            if idx < results.count - 1 { Divider().overlay(Palette.hair) }
                        }
                    }
                }
            }
        }
        .sheet(item: $fixState) { RuleEditorSheet(state: $0) }
    }

    private var metaBar: some View {
        HStack(spacing: 10) {
            Text("\(model.rows.count) dictations").font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
            Chip(text: "Kept 7 days, then auto-deleted", systemImage: "clock.arrow.circlepath")
            Chip(text: "Text only · never audio", systemImage: "waveform.slash")
            Spacer()
            Button { confirmingDeleteAll = true } label: {
                Chip(text: "Delete all", systemImage: "trash", danger: true)
            }
            .buttonStyle(.plain)
            .disabled(model.rows.isEmpty)
            .accessibilityLabel("Delete all dictations")
            .confirmationDialog("Delete all dictation history?",
                                isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                Button("Delete All", role: .destructive) { model.deleteAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes every dictation on this Mac. It can't be undone.")
            }
        }
        .padding(.horizontal, 34).padding(.vertical, 14)
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
    }
}

/// Top-of-History strip during a re-insert: a 3-2-1 countdown when Accessibility
/// is granted, or the copy-it-yourself prompt when it isn't. Either way the user
/// is never left guessing whether the paste happened.
private struct ReinsertBanner: View {
    @EnvironmentObject var reinserter: ReinsertController

    var body: some View {
        HStack(spacing: 10) {
            switch reinserter.phase {
            case .countdown(let n):
                Image(systemName: "\(n).circle.fill").font(.system(size: 15)).foregroundStyle(Palette.ember)
                Text("Re-inserting in \(n)… click into your target text field.")
                    .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Button("Cancel") { reinserter.cancel() }
                    .buttonStyle(.plain).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
            case .copied:
                Image(systemName: "doc.on.clipboard.fill").font(.system(size: 13)).foregroundStyle(Palette.ember)
                Text("Copied — switch to your app and press ⌘V.")
                    .font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.ink)
                Text("Pomvox doesn't have Accessibility yet, so it can't paste for you.")
                    .font(Typo.ui(12)).foregroundStyle(Palette.muted)
                Spacer()
                Button("Grant Accessibility…") { reinserter.openAccessibilitySettings() }
                    .buttonStyle(.plain).font(Typo.ui(12.5, .semibold)).foregroundStyle(Palette.ember)
                Button("Dismiss") { reinserter.cancel() }
                    .buttonStyle(.plain).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.inkSoft)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 34).padding(.vertical, 11)
        .background(Palette.emberSoft)
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
        .accessibilityElement(children: .combine)
    }
}

struct SearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.muted)
            TextField("Search dictations…", text: $text)
                .textFieldStyle(.plain).font(Typo.ui(13)).foregroundStyle(Palette.ink)
        }
        .padding(.horizontal, 10).frame(width: 240, height: 30)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.pane2))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.hair, lineWidth: 0.5))
    }
}

private struct EmptyResults: View {
    let searching: Bool
    /// See `EmptyState` — a read failure must never render as an empty history.
    var failed: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted)
            Text(title).font(Typo.display(18)).foregroundStyle(Palette.ink)
            if failed {
                Text("Nothing was deleted — ~/.pomvox/history.db couldn't be read. "
                     + "Reopening Pomvox usually clears it.")
                    .font(Typo.ui(12.5)).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).frame(maxWidth: 340)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }

    private var symbol: String {
        if failed { return "exclamationmark.triangle" }
        return searching ? "text.magnifyingglass" : "clock"
    }
    private var title: String {
        if failed { return "Couldn't read your history" }
        return searching ? "No matches" : "No dictations yet"
    }
}
