import SwiftUI
import TokenCore

/// One desktop widget panel. Each kind has its own glass panel and remembers its position.
struct DesktopWidget: View {
    let kind: WidgetKind
    @EnvironmentObject var store: UsageStore
    @AppStorage(PrefKey.widgetRange) private var rangeRaw = TimeRange.all.rawValue

    var body: some View {
        let range = TimeRange(rawValue: rangeRaw) ?? .all
        let summary = store.snapshot.summary(range, .all)
        Group {
            switch kind {
            case .summary: SummaryWidget(summary: summary, week: store.snapshot.summary(.week, .all), block: store.snapshot.block)
            case .window: WindowWidget(block: store.snapshot.block, sessionUsed: store.syncedSessionUsed(at: store.clock))
            case .tools: ToolsWidget(summary: summary)
            case .cache: CacheWidget(summary: summary)
            case .models: ModelsWidget(summary: summary)
            case .economy: EconomyWidget(summary: summary)
            }
        }
        .padding(14)
        .frame(width: kind.size.width, height: kind.size.height, alignment: .topLeading)
        .background(Color.white.opacity(0.10))
        .background(VisualEffectBackground(material: .popover))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
        )
        // Drag anywhere to move; right-click (or Control-click) for the widget menu.
        .overlay(WidgetDragLayer { WindowManager.shared.widgetMenu(for: kind) })
    }
}

private struct WidgetTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

// MARK: - Usage summary (the original widget)

private struct SummaryWidget: View {
    let summary: UsageSummary
    let week: UsageSummary
    let block: BlockInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                TachometerLogo(size: 16)
                WidgetTitle(text: "Credo · \(summary.range.title)")
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Fmt.tokens(summary.totals.total))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("tokens").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.cost(summary.totals.cost))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            StackedTokenBar(totals: summary.totals).frame(height: 6)
            HStack(spacing: 10) {
                LegendDot(color: Palette.input, label: "in", value: Fmt.tokens(summary.totals.input))
                LegendDot(color: Palette.output, label: "out", value: Fmt.tokens(summary.totals.output))
                LegendDot(color: Palette.cacheRead, label: "cache",
                          value: Fmt.tokens(summary.totals.cacheRead + summary.totals.cacheWrite))
            }
            Divider().opacity(0.5)
            HStack(alignment: .bottom, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Sparkline(buckets: week.buckets).frame(height: 30)
                    Text("Last 7 days").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(summary.bySource.prefix(3))) { item in
                        HStack(spacing: 5) {
                            Circle().fill(Palette.source(item.source)).frame(width: 7, height: 7)
                            Text(item.source?.shortName ?? item.name).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            Text(Fmt.tokens(item.totals.total)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                    if summary.bySource.isEmpty {
                        Text("No usage yet").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 118)
            }
            BlockRow(block: block)
        }
    }
}

private struct Sparkline: View {
    let buckets: [SeriesBucket]

    var body: some View {
        let maxValue = max(buckets.map { $0.totals.total }.max() ?? 1, 1)
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(buckets) { b in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Palette.accent.opacity(b.totals.total == 0 ? 0.25 : 0.85))
                        .frame(height: max(2, geo.size.height * Double(b.totals.total) / Double(maxValue)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
    }
}

private struct BlockRow: View {
    let block: BlockInfo?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let now = context.date
            if let block, block.isActive(at: now) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("5h window · \(Fmt.percent(block.progress(at: now))) elapsed").font(.caption2.weight(.semibold))
                        Spacer()
                        Text("\(Fmt.tokens(block.totals.total)) · resets in \(Fmt.duration(block.end.timeIntervalSince(now)))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    ProgressView(value: block.progress(at: now))
                        .tint(Palette.accent)
                        .controlSize(.mini)
                }
            } else {
                Text("No active 5-hour window")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - 5h window (battery style)

private struct WindowWidget: View {
    let block: BlockInfo?
    /// Claude's own session share when synced with the Claude account.
    var sessionUsed: Double? = nil

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 60)) { context in
            let now = context.date
            let active = block.flatMap { $0.isActive(at: now) ? $0 : nil }
            VStack(spacing: 6) {
                let fraction = active.map { sessionUsed ?? $0.progress(at: now) }
                Ring(fraction: min(fraction ?? 0, 1), color: Palette.accent, lineWidth: 9) {
                    VStack(spacing: 1) {
                        TachometerLogo(size: 24)
                        Text(fraction.map { Fmt.percent($0) } ?? "—")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(sessionUsed != nil ? "used" : "elapsed").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                if let active {
                    Text("\(Fmt.tokens(active.totals.total)) tokens")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                    Text("resets in \(Fmt.duration(active.end.timeIntervalSince(now)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("5h window").font(.caption.weight(.semibold))
                    Text("No active window").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Tokens by tool / by model (Batteries style rings)

private struct RingSlot: View {
    let fraction: Double
    let color: Color
    let symbol: String?
    let badge: String
    let value: String
    let label: String
    var diameter: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            Ring(fraction: fraction, color: color) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(color)
                } else {
                    Text(badge)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: diameter, height: diameter)
            Text(value).font(.callout.weight(.bold)).monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ToolsWidget: View {
    let summary: UsageSummary

    var body: some View {
        let total = max(Double(summary.totals.total), 1)
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitle(text: "Tokens by tool · \(summary.range.title)")
            if summary.bySource.isEmpty {
                Text("No usage yet").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(summary.bySource.prefix(4))) { item in
                    let share = Double(item.totals.total) / total
                    RingSlot(fraction: share, color: Palette.source(item.source),
                             symbol: item.source?.symbol, badge: "",
                             value: Fmt.percent(share), label: item.source?.shortName ?? item.name)
                }
            }
        }
    }
}

private struct ModelsWidget: View {
    let summary: UsageSummary

    var body: some View {
        let total = max(Double(summary.totals.total), 1)
        let top = Array(summary.byModel.prefix(3))
        let rest = summary.byModel.dropFirst(3).reduce(0) { $0 + $1.totals.total }
        VStack(alignment: .leading, spacing: 10) {
            WidgetTitle(text: "Tokens by model · \(summary.range.title)")
            if top.isEmpty {
                Text("No usage yet").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 4) {
                ForEach(Array(top.enumerated()), id: \.element.id) { item in
                    let share = Double(item.element.totals.total) / total
                    RingSlot(fraction: share, color: Palette.models[item.offset],
                             symbol: nil, badge: badge(item.element.name),
                             value: Fmt.percent(share), label: item.element.name, diameter: 58)
                }
                if rest > 0 {
                    let share = Double(rest) / total
                    let count = summary.byModel.count - 3
                    RingSlot(fraction: share, color: Palette.models[3], symbol: nil, badge: "+\(count)",
                             value: Fmt.percent(share), label: "\(count) other\(count == 1 ? "" : "s")", diameter: 58)
                }
            }
        }
    }

    /// "Sonnet 5.5" -> "S5.5"
    private func badge(_ name: String) -> String {
        let parts = name.split(separator: " ")
        guard let first = parts.first?.first else { return name }
        return String(first) + (parts.count > 1 ? String(parts[1]) : "")
    }
}

// MARK: - Cache savings

private struct CacheWidget: View {
    let summary: UsageSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Ring(fraction: summary.totals.cacheHitRate, color: Palette.cacheWrite) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Palette.cacheWrite)
                }
                .frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.percent(summary.totals.cacheHitRate))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("cache hit").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("≈ " + Fmt.cost(summary.totals.saved))
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.cacheWrite)
                .padding(.top, 2)
            Text("saved by prompt caching · \(summary.range.short)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Token economy

private struct EconomyRow: Identifiable {
    let symbol: String
    let value: String
    let label: String
    var id: String { label }
}

private struct EconomyWidget: View {
    let summary: UsageSummary

    var body: some View {
        let t = summary.totals
        let requests = max(t.requests, 1)
        let rows = [
            EconomyRow(symbol: "paperplane", value: Fmt.cost(t.cost / Double(requests)), label: "per request"),
            EconomyRow(symbol: "rectangle.stack", value: Fmt.cost(t.cost / Double(max(summary.sessions, 1))), label: "per session"),
            EconomyRow(symbol: "calendar", value: Fmt.cost(t.cost / Double(max(summary.activeDays, 1))), label: "per active day"),
            EconomyRow(symbol: "cube", value: Fmt.tokens(t.total / requests), label: "tokens per request")
        ]
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WidgetTitle(text: "Token economy · \(summary.range.title)")
                Spacer()
                Text(Fmt.cost(t.cost)).font(.caption.weight(.semibold)).monospacedDigit()
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(rows) { row in
                    HStack(spacing: 9) {
                        Image(systemName: row.symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 34, height: 34)
                            .background(Color.white.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.value)
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text(row.label).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
