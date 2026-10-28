import SwiftUI
import AppKit
import Charts

// MARK: - Chip

struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var danger: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11)).opacity(0.7) }
            Text(text).font(Typo.ui(12, .medium))
        }
        .foregroundStyle(danger ? Palette.ember : Palette.inkSoft)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(danger ? Palette.emberSoft : Palette.pane2))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(danger ? Palette.emberSoft : Palette.hair, lineWidth: 0.5))
    }
}

// MARK: - Sparkline

struct Sparkline: View {
    let values: [Double]   // any scale; normalized internally
    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(values.indices, id: \.self) { i in
                    Capsule()
                        .fill(Palette.ember.opacity(0.28))
                        .frame(height: max(2, geo.size.height * values[i] / maxV))
                }
            }
        }
        .frame(height: 26)
    }
}

// MARK: - Stat card

struct StatCard: View {
    let label: String
    let value: String
    var unit: String? = nil
    let meta: String
    var metaAccent: String? = nil      // leading colored fragment, e.g. "↑ 12%"
    let spark: [Double]
    var feature: Bool = false
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(Typo.ui(11.5, .semibold)).tracking(0.4)
                .foregroundStyle(Palette.muted)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(Typo.display(38, .semibold)).foregroundStyle(Palette.ink)
                if let unit { Text(unit).font(Typo.display(18, .medium)).foregroundStyle(Palette.muted) }
            }
            .padding(.top, 8)
            metaLine.padding(.top, 9)
            Sparkline(values: spark).padding(.top, 12)
        }
        .padding(.init(top: 18, leading: 18, bottom: 16, trailing: 18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 13).fill(Palette.card)
                if feature {
                    Circle().fill(RadialGradient(colors: [Palette.emberSoft, .clear],
                                                 center: .center, startRadius: 0, endRadius: 60))
                        .frame(width: 120, height: 120).offset(x: 30, y: -30)
                }
            }
        )
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hair, lineWidth: 0.5))
        .shadow(color: .black.opacity(hovering ? 0.16 : 0.04),
                radius: hovering ? 18 : 2, y: hovering ? 10 : 1)
        .offset(y: hovering ? -3 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label): \(value)\(unit.map { " " + $0 } ?? ""). \(meta)")
    }

    @ViewBuilder private var metaLine: some View {
        HStack(spacing: 6) {
            if let metaAccent { Text(metaAccent).font(Typo.ui(12, .semibold)).foregroundStyle(Palette.gold) }
            Text(meta).font(Typo.ui(12)).foregroundStyle(Palette.inkSoft)
        }
    }
}

// MARK: - Activity strip

struct ActivityStrip: View {
    let buckets: [DayBucket]
    let totalWords: Int
    let spokenHours: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(totalWords.formatted()) words").font(Typo.display(19, .semibold)).foregroundStyle(Palette.ink)
                Spacer()
                Text(String(format: "~%.1f hrs of speaking", spokenHours).uppercased())
                    .font(Typo.ui(11.5, .semibold)).tracking(0.4).foregroundStyle(Palette.muted)
            }
            .padding(.bottom, 14)

            GeometryReader { geo in
                let maxV = max(buckets.map(\.words).max() ?? 1, 1)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(buckets) { b in
                        let frac = Double(b.words) / Double(maxV)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(b.words == 0 ? Palette.hairStrong : Palette.ember)
                            .opacity(b.words == 0 ? 0.6 : (0.45 + frac * 0.55))
                            .frame(height: max(3, geo.size.height * frac))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: 62)

            HStack {
                Text(axisLabel(buckets.first?.date)).font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
                Spacer()
                Text(axisLabel(buckets.last?.date)).font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
            }
            .padding(.top, 8)
        }
        .padding(.init(top: 18, leading: 20, bottom: 14, trailing: 20))
        .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hair, lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(format: "Activity: %@ words over the last 30 days, about %.1f hours of speaking.",
                                   totalWords.formatted(), spokenHours))
    }

    private func axisLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}

// MARK: - 90-day heatmap + streak (the richer "Patterns" view)

/// A GitHub-style calendar heatmap of the last 13 weeks, drawn with Swift
/// Charts, plus your personal streak. Every number is from this Mac's history —
/// no percentile, no cohort, compared to nobody (decision #3).
struct HeatmapCard: View {
    let cells: [HeatmapCell]
    let streak: Int

    private var maxWords: Int {
        max(cells.lazy.filter { !$0.inFuture }.map(\.words).max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.bottom, 16)
            chart
            legend.padding(.top, 12)
        }
        .padding(.init(top: 18, leading: 20, bottom: 16, trailing: 20))
        .background(RoundedRectangle(cornerRadius: 13).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Palette.hair, lineWidth: 0.5))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if streak > 0 {
                Text("\(streak)").font(Typo.display(22, .semibold)).foregroundStyle(Palette.ember)
                Text(streak == 1 ? "day streak" : "day streak")
                    .font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.ink)
            } else {
                Text("No active streak").font(Typo.ui(13.5, .medium)).foregroundStyle(Palette.inkSoft)
            }
            Spacer()
            Text("CONSECUTIVE DAYS YOU DICTATED · JUST YOU")
                .font(Typo.ui(11, .semibold)).tracking(0.4).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(streak > 0
            ? "\(streak) day streak — consecutive days you dictated, compared to nobody."
            : "No active streak yet.")
    }

    private var chart: some View {
        Chart(cells) { cell in
            // Inset each cell a touch so the grid reads as separate squares.
            // Sunday (weekday 0) on top: flip the row so y grows downward.
            RectangleMark(
                xStart: .value("week start", Double(cell.week) + 0.08),
                xEnd:   .value("week end",   Double(cell.week) + 0.92),
                yStart: .value("day start",  Double(6 - cell.weekday) + 0.08),
                yEnd:   .value("day end",    Double(6 - cell.weekday) + 0.92))
                .foregroundStyle(color(for: cell))
                .cornerRadius(2)
                .accessibilityLabel(label(for: cell))
                .accessibilityValue("\(cell.words) words")
                .accessibilityHidden(cell.inFuture)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...13)
        .chartYScale(domain: 0...7)
        .frame(height: 116)
        .accessibilityLabel("Dictation activity heatmap, last 90 days")
    }

    private var legend: some View {
        HStack(spacing: 8) {
            Text(rangeCaption).font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
            Spacer()
            Text("Less").font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { frac in
                RoundedRectangle(cornerRadius: 2)
                    .fill(frac == 0 ? Palette.hairStrong.opacity(0.5) : Palette.ember.opacity(0.35 + frac * 0.65))
                    .frame(width: 11, height: 11)
            }
            Text("More").font(Typo.ui(10.5)).foregroundStyle(Palette.muted)
        }
        .accessibilityHidden(true)
    }

    private func color(for cell: HeatmapCell) -> Color {
        if cell.inFuture { return .clear }
        if cell.words == 0 { return Palette.hairStrong.opacity(0.5) }
        let frac = Double(cell.words) / Double(maxWords)
        return Palette.ember.opacity(0.35 + frac * 0.65)
    }

    private func label(for cell: HeatmapCell) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"
        return f.string(from: cell.date)
    }

    private var rangeCaption: String {
        let visible = cells.filter { !$0.inFuture }
        guard let first = visible.first?.date, let last = visible.last?.date else { return "" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return "\(f.string(from: first)) – \(f.string(from: last))"
    }
}

// MARK: - Dictation row (the two-tone raw → clean reveal)

struct DictationRow: View {
    let dictation: Dictation
    var dateStyle: WhenStyle = .relative
    var showDelete: Bool = false
    var onFix: ((Dictation) -> Void)? = nil
    @State private var hovering = false
    @EnvironmentObject private var model: HubModel
    @EnvironmentObject private var reinserter: ReinsertController

    enum WhenStyle { case relative, calendar }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            whenColumn.frame(width: dateStyle == .calendar ? 84 : 60, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(dictation.final).font(Typo.ui(13.5)).foregroundStyle(Palette.ink)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("RAW").font(Typo.ui(9.5, .semibold)).tracking(0.6).foregroundStyle(Palette.muted)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.hair, lineWidth: 0.5))
                    Text(dictation.raw).font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)

            HStack(spacing: 10) {
                if let dur = dictation.durationSeconds {
                    Text(formatDuration(dur)).font(Typo.ui(10.5)).monospacedDigit().foregroundStyle(Palette.muted)
                }
                if let app = dictation.appHint { AppBadge(name: app) }
                // Faintly visible at rest (not opacity 0, which drops the buttons
                // from the accessibility tree), full on hover. Keeps Copy /
                // Re-insert / Delete reachable by keyboard and VoiceOver.
                rowActions.opacity(hovering ? 1 : 0.55)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
        .background(hovering ? Palette.pane2 : .clear)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(a11ySummary)
    }

    private var a11ySummary: String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        return "\(f.string(from: dictation.timestamp)). \(dictation.final)"
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(dictation.final, forType: .string)
    }

    @ViewBuilder private var whenColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            switch dateStyle {
            case .relative:
                Text(timeOnly(dictation.timestamp)).font(Typo.ui(12, .semibold)).foregroundStyle(Palette.inkSoft)
                Text(relative(dictation.timestamp)).font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
            case .calendar:
                Text(dayLabel(dictation.timestamp)).font(Typo.ui(12, .semibold)).foregroundStyle(Palette.inkSoft)
                Text(timeOnly(dictation.timestamp)).font(Typo.ui(11.5)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var rowActions: some View {
        HStack(spacing: 4) {
            RowButton(symbol: "doc.on.doc", label: "Copy", action: copy)
            RowButton(symbol: "arrow.uturn.left", label: "Re-insert") {
                reinserter.start(text: dictation.final)
            }
            if let onFix {
                // Same wording as the Dictionary page's empty state, which
                // tells the user to come here and choose it.
                RowButton(symbol: "character.book.closed", label: "Fix a misheard word…") {
                    onFix(dictation)
                }
            }
            if showDelete {
                RowButton(symbol: "trash", label: "Delete", danger: true) { model.delete(dictation) }
            }
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    var danger: Bool = false
    let action: () -> Void
    @State private var hovering = false

    private var tint: Color { hovering ? (danger ? Palette.ember : Palette.ember) : Palette.inkSoft }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Palette.pane2 : Palette.card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Palette.hair, lineWidth: 0.5))
        }
        .buttonStyle(.plain).onHover { hovering = $0 }
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct AppBadge: View {
    let name: String
    var body: some View {
        HStack(spacing: 5) {
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.inkSoft))
            Text(name).font(Typo.ui(11)).foregroundStyle(Palette.muted)
        }
    }
}

// MARK: - formatting helpers

private func formatDuration(_ s: Double) -> String {
    let total = Int(s.rounded()); return String(format: "%d:%02d", total / 60, total % 60)
}
private func timeOnly(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: d)
}
private func dayLabel(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "MMM d"; return f.string(from: d)
}
private func relative(_ d: Date) -> String {
    let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
    return f.localizedString(for: d, relativeTo: Date())
}
