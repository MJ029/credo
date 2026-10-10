import Foundation

/// Turns raw records into pre-computed summaries for every (range × tool) combination.
public enum Aggregator {

    struct BucketLayout {
        var unit: BucketUnit
        var start: Date
        var startDay: Int
        var count: Int
        /// First local day included in the range (nil = everything).
        var rangeStartDay: Int?
        /// Exact start instant (used by the 5-hour window instead of a day boundary).
        var rangeStart: Date? = nil
    }

    struct Accumulator {
        var summary: UsageSummary
        var models: [String: TokenTotals] = [:]
        var sources: [UsageSource: TokenTotals] = [:]
        var projects: [String: TokenTotals] = [:]
        var sessions = Set<String>()
        var days = Set<Int>()
        var buckets: [TokenTotals]

        init(summary: UsageSummary, bucketCount: Int) {
            self.summary = summary
            self.buckets = Array(repeating: TokenTotals(), count: bucketCount)
        }

        mutating func add(_ r: UsageRecord, model: String, day: Int, bucket: Int?) {
            summary.totals.add(r)
            models[model, default: TokenTotals()].add(r)
            sources[r.source, default: TokenTotals()].add(r)
            projects[r.project, default: TokenTotals()].add(r)
            sessions.insert(r.sessionId)
            days.insert(day)
            if let bucket { buckets[bucket].add(r) }
        }

        func finish(_ layout: BucketLayout, calendar: Calendar) -> UsageSummary {
            var s = summary
            s.sessions = sessions.count
            s.activeDays = days.count
            s.byModel = models
                .map { Breakdown(name: $0.key, source: nil, totals: $0.value) }
                .sorted { $0.totals.total > $1.totals.total }
            s.bySource = sources
                .map { Breakdown(name: $0.key.displayName, source: $0.key, totals: $0.value) }
                .sorted { $0.totals.total > $1.totals.total }
            s.byProject = Array(projects
                .map { Breakdown(name: $0.key, source: nil, totals: $0.value) }
                .sorted { $0.totals.total > $1.totals.total }
                .prefix(15))
            s.bucketUnit = layout.unit
            s.buckets = buckets.enumerated().map { item in
                SeriesBucket(start: Aggregator.bucketDate(item.offset, layout, calendar), totals: item.element)
            }
            return s
        }
    }

    public static func snapshot(records: [UsageRecord], roots: [RootStatus], fileCount: Int,
                                window: WindowOverride? = nil,
                                now: Date = Date(), calendar: Calendar = .current) -> UsageSnapshot {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        let tz = calendar.timeZone
        let dayNumbers = sorted.map { localDay($0.timestamp, tz) }

        var prettyCache: [String: String] = [:]
        let models: [String] = sorted.map { r in
            if let cached = prettyCache[r.model] { return cached }
            let p = ModelNames.pretty(r.model)
            prettyCache[r.model] = p
            return p
        }

        let present = Set(sorted.map { $0.source })
        let sources = UsageSource.allCases.filter { present.contains($0) }
        let filters: [SourceFilter] = [.all, .cli, .desktop, .claudeCode] + sources.map { SourceFilter.only($0) }
        // For each tool, the accumulators (filter indices) its records belong to.
        var targets: [UsageSource: [Int]] = [:]
        for source in UsageSource.allCases {
            targets[source] = filters.indices.filter { filters[$0].matches(source) }
        }

        var summaries: [String: UsageSummary] = [:]
        let block: BlockInfo?
        switch window {
        case .start(let start)?: block = anchoredBlock(sorted, start: start)
        case .noWindow?: block = nil
        case nil: block = latestBlock(sorted)
        }
        let timestamps = sorted.map { $0.timestamp.timeIntervalSince1970 }
        for range in TimeRange.allCases {
            let layout = range == .window
                ? windowLayout(block: block, now: now)
                : bucketLayout(range, first: sorted.first?.timestamp, now: now, calendar: calendar)
            let startIndex: Int
            if let start = layout.rangeStart {
                startIndex = lowerBound(timestamps, start.timeIntervalSince1970)
            } else {
                startIndex = layout.rangeStartDay.map { lowerBound(dayNumbers, $0) } ?? 0
            }
            var accs = filters.map { Accumulator(summary: UsageSummary(range: range, filter: $0), bucketCount: layout.count) }
            if startIndex < sorted.count {
                for i in startIndex..<sorted.count {
                    let r = sorted[i]
                    let bucket = bucketIndex(r, day: dayNumbers[i], layout: layout)
                    for a in targets[r.source] ?? [0] {
                        accs[a].add(r, model: models[i], day: dayNumbers[i], bucket: bucket)
                    }
                }
            }
            for (i, f) in filters.enumerated() {
                summaries[UsageSnapshot.key(range, f)] = accs[i].finish(layout, calendar: calendar)
            }
        }

        return UsageSnapshot(generatedAt: now, summaries: summaries, block: block,
                             sources: sources, fileCount: fileCount, recordCount: records.count, roots: roots)
    }

    // MARK: - Helpers

    static func localDay(_ date: Date, _ tz: TimeZone) -> Int {
        let t = date.timeIntervalSince1970 + Double(tz.secondsFromGMT(for: date))
        return Int((t / 86_400).rounded(.down))
    }

    /// Five hourly buckets over the active 5-hour window. With no active window the range
    /// starts "now", so the 5 hr view is empty rather than showing stale usage.
    static func windowLayout(block: BlockInfo?, now: Date) -> BucketLayout {
        let start: Date
        if let block, block.isActive(at: now) {
            start = block.start
        } else {
            start = now
        }
        return BucketLayout(unit: .hour, start: start, startDay: 0, count: 5, rangeStartDay: nil, rangeStart: start)
    }

    static func lowerBound<T: Comparable>(_ values: [T], _ target: T) -> Int {
        var lo = 0, hi = values.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if values[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    static func bucketLayout(_ range: TimeRange, first: Date?, now: Date, calendar: Calendar) -> BucketLayout {
        let tz = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }

        switch range {
        case .window:
            // The 5-hour window is laid out by windowLayout(block:now:); without a block it is empty.
            return windowLayout(block: nil, now: now)
        case .today:
            let d = localDay(today, tz)
            return BucketLayout(unit: .hour, start: today, startDay: d, count: 24, rangeStartDay: d)
        case .week:
            let s = daysAgo(6)
            let d = localDay(s, tz)
            return BucketLayout(unit: .day, start: s, startDay: d, count: 7, rangeStartDay: d)
        case .month:
            let s = daysAgo(29)
            let d = localDay(s, tz)
            return BucketLayout(unit: .day, start: s, startDay: d, count: 30, rangeStartDay: d)
        case .all:
            let firstDay = calendar.startOfDay(for: min(first ?? now, now))
            let firstNum = localDay(firstDay, tz)
            let span = localDay(today, tz) - firstNum + 1
            if span <= 120 {
                return BucketLayout(unit: .day, start: firstDay, startDay: firstNum, count: max(span, 1), rangeStartDay: nil)
            }
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: firstDay)?.start ?? firstDay
            let ws = localDay(weekStart, tz)
            let weeks = (localDay(today, tz) - ws) / 7 + 1
            return BucketLayout(unit: .week, start: weekStart, startDay: ws, count: max(weeks, 1), rangeStartDay: nil)
        }
    }

    static func bucketIndex(_ r: UsageRecord, day: Int, layout: BucketLayout) -> Int? {
        let idx: Int
        switch layout.unit {
        case .hour:
            idx = Int((r.timestamp.timeIntervalSince(layout.start) / 3600).rounded(.down))
        case .day:
            idx = day - layout.startDay
        case .week:
            let delta = day - layout.startDay
            idx = delta < 0 ? -1 : delta / 7
        }
        return (idx >= 0 && idx < layout.count) ? idx : nil
    }

    static func bucketDate(_ i: Int, _ layout: BucketLayout, _ calendar: Calendar) -> Date {
        switch layout.unit {
        case .hour: return layout.start.addingTimeInterval(Double(i) * 3600)
        case .day: return calendar.date(byAdding: .day, value: i, to: layout.start) ?? layout.start
        case .week: return calendar.date(byAdding: .day, value: i * 7, to: layout.start) ?? layout.start
        }
    }

    /// Most recent 5-hour usage window across all tools.
    /// Claude's 5-hour window starts with the first message after the previous window ended
    /// (to the minute) and lasts five hours. From local logs this is only right when that first
    /// message was logged on this Mac; Sync with Claude account gives the exact window. Records
    /// without a real timestamp are left out so they can't start or inflate a window.
    static func latestBlock(_ sorted: [UsageRecord]) -> BlockInfo? {
        var block: BlockInfo?
        for r in sorted where r.timestampKnown {
            if var b = block, r.timestamp < b.end {
                b.totals.add(r)
                b.lastActivity = r.timestamp
                block = b
            } else {
                var b = BlockInfo(start: BlockInfo.windowStart(for: r.timestamp), lastActivity: r.timestamp,
                                  totals: TokenTotals())
                b.totals.add(r)
                block = b
            }
        }
        return block
    }

    /// The 5-hour window as Claude reports it: from `start` for five hours, with the tokens of
    /// every logged response inside it. It may hold no tokens if the window was started by
    /// something Credo can't see (a chat on the web, say).
    static func anchoredBlock(_ sorted: [UsageRecord], start: Date) -> BlockInfo {
        var b = BlockInfo(start: start, lastActivity: start, totals: TokenTotals(), syncedWithClaude: true)
        let end = b.end
        for r in sorted where r.timestampKnown && r.timestamp >= start && r.timestamp < end {
            b.totals.add(r)
            b.lastActivity = r.timestamp
        }
        return b
    }
}

public enum Report {
    public static func text(_ s: UsageSnapshot) -> String {
        func money(_ v: Double) -> String { String(format: "$%.2f", v) }
        var out = "Credo — \(s.recordCount) API calls from \(s.fileCount) log files\n"
        for root in s.roots {
            out += "  [\(root.exists ? "x" : " ")] \(root.label): \(root.path) (\(root.fileCount) files)\n"
        }
        for range in TimeRange.allCases {
            let sum = s.summary(range, .all)
            let t = sum.totals
            out += "\n\(range.title): \(t.total) tokens | in \(t.input) out \(t.output) cache-write \(t.cacheWrite) cache-read \(t.cacheRead) | \(t.requests) requests, \(sum.sessions) sessions | ≈\(money(t.cost))\n"
            for b in sum.bySource {
                out += "    \(b.name): \(b.totals.total) tokens ≈\(money(b.totals.cost))\n"
            }
            for b in sum.byModel.prefix(6) {
                out += "    · \(b.name): \(b.totals.total) tokens ≈\(money(b.totals.cost))\n"
            }
        }
        if let b = s.block, b.isActive(at: Date()) {
            out += "\nActive 5h window since \(b.start): \(b.totals.total) tokens ≈\(money(b.totals.cost))\n"
        }
        return out
    }
}
