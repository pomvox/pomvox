import SwiftUI

struct HomeView: View {
    @EnvironmentObject var model: HubModel
    var goToHistory: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(title: "Home") {
                Chip(text: "New dictation  ⌘⇧Space", systemImage: "mic")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    UpdateBanner().padding(.bottom, 20)
                    greeting.padding(.bottom, 26)

                    if model.rows.isEmpty {
                        EmptyState(hasDatabase: model.hasDatabase, failed: model.loadFailed)
                    } else {
                        cards.padding(.bottom, 30)
                        SectionHeader(title: "Activity", sub: "last 30 days")
                        ActivityStrip(buckets: model.stats.activity,
                                      totalWords: model.stats.totalWords,
                                      spokenHours: model.stats.spokenHours)
                            .padding(.bottom, 30)
                        SectionHeader(title: "Patterns", sub: "last 90 days")
                        HeatmapCard(cells: model.heatmap, streak: model.stats.streak)
                            .padding(.bottom, 30)
                        SectionHeader(title: "Recent", action: ("View all →", goToHistory))
                        recent
                    }
                }
                .padding(.horizontal, 34).padding(.top, 30).padding(.bottom, 40)
            }
        }
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(greetingLine).font(Typo.display(30, .medium)).foregroundStyle(Palette.ink)
            Text(subtitleLine).font(Typo.ui(13.5)).foregroundStyle(Palette.muted)
        }
    }

    private var cards: some View {
        HStack(spacing: 14) {
            StatCard(label: "Words dictated",
                     value: (model.stats.lifetimeWords ?? model.stats.totalWords).formatted(),
                     meta: "all-time on this Mac",
                     spark: tailSpark(8), feature: true)
            StatCard(label: "Dictations",
                     value: (model.stats.lifetimeDictations ?? model.stats.dictationCount).formatted(),
                     meta: "all-time on this Mac", spark: tailSpark(8))
            StatCard(label: "Avg. speed", value: "\(model.stats.averageWPM)", unit: "wpm",
                     meta: "Computed here · compared to nobody", spark: tailSpark(8))
        }
    }

    private var recent: some View {
        VStack(spacing: 0) {
            let items = model.recent(5)
            ForEach(Array(items.enumerated()), id: \.element.id) { idx, d in
                DictationRow(dictation: d)
                if idx < items.count - 1 { Divider().overlay(Palette.hair) }
            }
        }
        .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hair, lineWidth: 0.5))
    }

    // Last-N daily word counts as a sparkline, padded if history is short.
    private func tailSpark(_ n: Int) -> [Double] {
        let words = model.stats.activity.suffix(n).map { Double($0.words) }
        return words.isEmpty ? Array(repeating: 0, count: n) : Array(words)
    }

    private var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"; case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"; default: "Still up"
        }
    }

    /// Greet by the Mac account's first name (`NSFullUserName`), never a
    /// hardcoded name. Falls back to a name-less greeting if the account has no
    /// full name set.
    private var greetingLine: String {
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? "\(timeOfDayGreeting)." : "\(timeOfDayGreeting), \(first)."
    }
    private var subtitleLine: String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }
}

// MARK: - shared chrome

struct Toolbar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            Text(title).font(Typo.ui(14, .semibold)).foregroundStyle(Palette.ink)
            Spacer()
            trailing
        }
        .padding(.horizontal, 22).frame(height: 52)
        .background(.bar)
        .overlay(Rectangle().fill(Palette.hair).frame(height: 0.5), alignment: .bottom)
    }
}

struct SectionHeader: View {
    let title: String
    var sub: String? = nil
    var action: (String, () -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Typo.ui(15, .semibold)).foregroundStyle(Palette.ink)
            if let sub { Text(sub).font(Typo.ui(13)).foregroundStyle(Palette.muted) }
            Spacer()
            if let action {
                Button(action: action.1) { Text(action.0).font(Typo.ui(12.5, .medium)).foregroundStyle(Palette.ember) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 14)
    }
}

struct EmptyState: View {
    let hasDatabase: Bool
    /// A failed read is NOT an empty history — say so, or the user reads the
    /// blank page as "Pomvox deleted my dictations".
    var failed: Bool = false

    var body: some View {
        VStack(spacing: 12) {
            if failed {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30, weight: .light)).foregroundStyle(Palette.muted)
            } else {
                Waveform().scaleEffect(1.6).frame(height: 40)
            }
            Text(failed ? "Couldn't read your history" : "No dictations yet")
                .font(Typo.display(20)).foregroundStyle(Palette.ink).padding(.top, 8)
            Text(message)
                .font(Typo.ui(13)).foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var message: String {
        if failed {
            return "Your dictations are still on disk at ~/.pomvox/history.db — "
                + "this is a read error, nothing was deleted. Reopening Pomvox usually clears it."
        }
        return hasDatabase
            ? "Hold Fn and speak — your dictations will appear here, and nowhere else."
            : "Start Pomvox and dictate once. Everything is stored on this Mac, at ~/.pomvox/history.db."
    }
}
