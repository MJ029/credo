import SwiftUI
import Charts
import AppKit
import TokenCore

struct MenuBarLabel: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        Text(store.menuBarText)
            .monospacedDigit()
    }
}

struct PopoverView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            Divider()
            if store.snapshot.recordCount == 0 {
                EmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !store.provider.isSupported {
                VStack(alignment: .leading, spacing: 12) {
                    FilterBar()
                    ProviderComingSoon(provider: store.provider)
                    Spacer()
                }
                .padding(14)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        FilterBar()
                        HeroCard(summary: store.summary, provider: store.provider)
                        TokenTiles(totals: store.summary.totals)
                        if let block = store.snapshot.block, block.isActive(at: Date()) {
                            BlockCard(block: block, sessionUsed: store.syncedSessionUsed(at: Date()),
                                      week: store.syncedWeek(at: Date()))
                        }
                        UsageChartCard(summary: store.summary)
                        BreakdownCard(title: "By model", icon: "cpu", items: store.summary.byModel)
                        if store.filter == .all || store.filter == .cli || store.filter == .desktop {
                            BreakdownCard(title: "By tool", icon: "macwindow.on.rectangle", items: store.summary.bySource)
                        }
                        BreakdownCard(title: "Top projects", icon: "folder",
                                      items: Array(store.summary.byProject.prefix(6)))
                    }
                    .padding(14)
                }
            }
            Divider()
            FooterBar()
        }
        .frame(width: 400, height: 640)
        .background(GlowBackground())
        .onAppear { store.refresh() }
    }
}

// MARK: - Header / footer

struct HeaderBar: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        HStack(spacing: 8) {
            TachometerLogo(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("Credo").font(.headline)
                if let updated = store.lastUpdated {
                    Text("Updated \(updated, style: .relative) ago")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Reading logs…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if store.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

struct FooterBar: View {
    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            Button("Settings…") { WindowManager.shared.showSettings() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct FilterBar: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 8) {
            Picker("Range", selection: $store.range) {
                ForEach(TimeRange.allCases) { r in Text(r.short).tag(r) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Picker("Provider", selection: $store.provider) {
                ForEach(Provider.allCases) { p in Text(p.label).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if store.provider.isSupported {
                Picker("Tool", selection: $store.filter) {
                    ForEach(store.availableFilters) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }
}

/// Shown when a provider whose logs Credo can't read yet is selected.
struct ProviderComingSoon: View {
    let provider: Provider

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("\(provider.label) isn't tracked yet", systemImage: "hourglass")
                    .font(.headline)
                Text("Credo currently reads Claude Code and Claude Desktop logs. Support for \(provider.plannedTools) is planned for a future version.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: store.isScanning ? "hourglass" : "tray")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text(store.isScanning ? "Reading your Claude logs…" : "No Claude usage found yet")
                .font(.headline)
            if !store.isScanning {
                Text("Credo looks for Claude Code and Claude Desktop session logs in these folders:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.snapshot.roots) { root in
                        HStack(spacing: 6) {
                            Image(systemName: root.exists ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(root.exists ? Color.green : Color.secondary)
                            Text(root.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .font(.caption2)
                    }
                }
                Button("Add a folder in Settings…") { WindowManager.shared.showSettings() }
            }
        }
        .padding(24)
    }
}

// MARK: - Cards

struct HeroCard: View {
    let summary: UsageSummary
    var provider: Provider = .all

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(summary.range.title) · \(provider == .all ? "All providers" : provider.label) · \(summary.filter.label)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(Fmt.tokens(summary.totals.total))
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tokens")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(Fmt.cost(summary.totals.cost))
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                        Text("API-price estimate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .help("What these tokens would cost at Anthropic API list prices. Pro/Max subscriptions are not billed per token.")
                }
                StackedTokenBar(totals: summary.totals)
                    .frame(height: 7)
                HStack(spacing: 18) {
                    Stat("Requests", Fmt.full(summary.totals.requests))
                    Stat("Sessions", Fmt.full(summary.sessions))
                    Stat("Cache hit", Fmt.percent(summary.totals.cacheHitRate))
                    if summary.range != .today && summary.range != .window {
                        Stat("Active days", "\(summary.activeDays)")
                    }
                }
            }
        }
    }
}

struct TokenTiles: View {
    let totals: TokenTotals

    private struct Tile: Identifiable {
        let id: String
        let value: Int
        let color: Color
        let help: String
    }

    var body: some View {
        let tiles = [
            Tile(id: "Input", value: totals.input, color: Palette.input, help: "New prompt tokens sent without caching"),
            Tile(id: "Output", value: totals.output, color: Palette.output, help: "Tokens generated by the model"),
            Tile(id: "Cache write", value: totals.cacheWrite, color: Palette.cacheWrite, help: "Prompt tokens written to the prompt cache"),
            Tile(id: "Cache read", value: totals.cacheRead, color: Palette.cacheRead, help: "Prompt tokens served from the cache (cheapest)")
        ]
        let sum = max(totals.total, 1)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(tiles) { tile in
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Circle().fill(tile.color).frame(width: 8, height: 8)
                            Text(tile.id).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.percent(Double(tile.value) / Double(sum)))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(Fmt.tokens(tile.value))
                            .font(.system(.title3, design: .rounded).weight(.semibold))
                            .monospacedDigit()
                    }
                }
                .help("\(tile.help): \(Fmt.full(tile.value))")
            }
        }
    }
}

struct BlockCard: View {
    let block: BlockInfo
    /// Claude's own "Current session" share when synced with the Claude account.
    var sessionUsed: Double? = nil
    /// Claude's weekly limit when synced.
    var week: LimitWindow? = nil

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 30)) { context in
            let now = context.date
            let fraction = sessionUsed ?? block.progress(at: now)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Label("5-hour window", systemImage: "timer")
                            .font(.subheadline.weight(.semibold))
                        Text(sessionUsed != nil ? "\(Fmt.percent(fraction)) used" : "\(Fmt.percent(fraction)) elapsed")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.accentDark))
                        Spacer()
                        Text("resets in \(Fmt.duration(block.end.timeIntervalSince(now)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: min(fraction, 1))
                        .tint(fraction >= 0.9 && sessionUsed != nil ? Color.red : Palette.accent)
                    HStack(spacing: 18) {
                        Stat("Tokens", Fmt.tokens(block.totals.total))
                        Stat("Est. cost", Fmt.cost(block.totals.cost))
                        Stat("Burn rate", "\(Fmt.tokens(Int(block.burnRatePerHour(at: now))))/h")
                        Stat("Started", block.start.formatted(date: .omitted, time: .shortened))
                    }
                    if let used = MenuBarText.budgetShare(.fiveHour, tokens: block.totals.total) {
                        HStack(spacing: 6) {
                            Text("Tokens vs your 5h budget").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text(Fmt.percent(used)).font(.caption.weight(.semibold)).monospacedDigit()
                        }
                        ProgressView(value: min(used, 1))
                            .tint(used >= 0.9 ? Color.red : Palette.cacheWrite)
                    }
                    if let week, let reset = week.resetsAt {
                        HStack(spacing: 6) {
                            Text("Weekly limit").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(Fmt.percent(week.used)) used · resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                        }
                        ProgressView(value: min(week.used, 1))
                            .tint(week.used >= 0.9 ? Color.red : Palette.cacheWrite)
                    }
                    Text(block.syncedWithClaude
                         ? "Synced with your Claude account: the percentage, start and reset match Claude's own session bar. Tokens are from local logs, so chats on the web or phone add to the % but not to the token count."
                         : "Time elapsed in the window, from local Claude Code logs. Claude's own session % also counts chats on web, desktop and mobile against your plan limit, so it can differ. Turn on Sync with Claude account in Settings to match it.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .help("Claude plans meter usage in rolling 5-hour windows. This is an estimate from local logs across all tools.")
        }
    }
}

struct UsageChartCard: View {
    let summary: UsageSummary
    @AppStorage(PrefKey.chartMode) private var mode = "all"

    private struct Point: Identifiable {
        let date: Date
        let kind: String
        let value: Int
        var id: String { "\(date.timeIntervalSince1970)-\(kind)" }
    }

    private var kinds: [String] {
        mode == "io" ? ["Input", "Output"] : ["Input", "Output", "Cache write", "Cache read"]
    }

    private var colors: [Color] {
        mode == "io" ? [Palette.input, Palette.output]
            : [Palette.input, Palette.output, Palette.cacheWrite, Palette.cacheRead.opacity(0.6)]
    }

    private var points: [Point] {
        summary.buckets.flatMap { b -> [Point] in
            var p = [Point(date: b.start, kind: "Input", value: b.totals.input),
                     Point(date: b.start, kind: "Output", value: b.totals.output)]
            if mode != "io" {
                p.append(Point(date: b.start, kind: "Cache write", value: b.totals.cacheWrite))
                p.append(Point(date: b.start, kind: "Cache read", value: b.totals.cacheRead))
            }
            return p
        }
    }

    private var unit: Calendar.Component {
        switch summary.bucketUnit {
        case .hour: return .hour
        case .day: return .day
        case .week: return .weekOfYear
        }
    }

    private var strideCount: Int {
        switch summary.bucketUnit {
        // At most ~5 labels so "23 Jul"-style dates never overlap in the 370pt chart.
        case .hour: return summary.buckets.count <= 6 ? 1 : 6
        case .day: return summary.buckets.count <= 7 ? 1 : Int((Double(summary.buckets.count) / 5).rounded(.up))
        case .week: return max(1, Int((Double(summary.buckets.count) / 5).rounded(.up)))
        }
    }

    private var axisFormat: Date.FormatStyle {
        switch summary.bucketUnit {
        case .hour:
            return Date.FormatStyle().hour()
        case .day:
            if summary.buckets.count > 10 { return Date.FormatStyle().day().month(.abbreviated) }
            return Date.FormatStyle().weekday(.abbreviated)
        case .week:
            return Date.FormatStyle().month(.abbreviated).day()
        }
    }

    private var title: String {
        switch summary.bucketUnit {
        case .hour: return "Tokens per hour"
        case .day: return "Tokens per day"
        case .week: return "Tokens per week"
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label(title, systemImage: "chart.bar.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Picker("Series", selection: $mode) {
                        Text("All").tag("all")
                        Text("In/Out").tag("io")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 110)
                }
                Chart(points) { p in
                    BarMark(
                        x: .value("Time", p.date, unit: unit),
                        y: .value("Tokens", p.value)
                    )
                    .foregroundStyle(by: .value("Type", p.kind))
                }
                .chartForegroundStyleScale(domain: kinds, range: colors)
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Int.self) { Text(Fmt.tokens(v)) }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: unit, count: strideCount)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: axisFormat)
                    }
                }
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 160)
            }
        }
    }
}

struct BreakdownCard: View {
    let title: String
    let icon: String
    let items: [Breakdown]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.semibold))
                if items.isEmpty {
                    Text("No usage in this period")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let maxTotal = max(items.map { $0.totals.total }.max() ?? 1, 1)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            if item.source != nil {
                                Circle().fill(Palette.source(item.source)).frame(width: 7, height: 7)
                            }
                            Text(item.name)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(Fmt.tokens(item.totals.total))
                                .font(.callout.weight(.medium))
                                .monospacedDigit()
                            Text(Fmt.cost(item.totals.cost))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 62, alignment: .trailing)
                        }
                        BarFill(fraction: Double(item.totals.total) / Double(maxTotal),
                                color: Palette.source(item.source))
                    }
                    .help("Input \(Fmt.full(item.totals.input)) · Output \(Fmt.full(item.totals.output)) · Cache write \(Fmt.full(item.totals.cacheWrite)) · Cache read \(Fmt.full(item.totals.cacheRead)) · \(Fmt.full(item.totals.requests)) requests")
                }
            }
        }
    }
}
