import Foundation

public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    /// The current 5-hour usage window (empty when no window is active).
    case window = "5h"
    case today, week, month, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .window: return "Current 5-hour window"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .all: return "All time"
        }
    }

    public var short: String {
        switch self {
        case .window: return "5 hr"
        case .today: return "Today"
        case .week: return "7D"
        case .month: return "30D"
        case .all: return "All"
        }
    }
}

public enum SourceFilter: Hashable, Sendable, Identifiable {
    case all
    /// Terminal, VS Code and SDK sessions.
    case cli
    /// Claude Desktop: Code tab and agent sessions.
    case desktop
    /// Every Claude Code surface (terminal, VS Code, Desktop Code tab) — comparable to Claude Code's Stats panel.
    case claudeCode
    case only(UsageSource)

    public var id: String { key }

    public var key: String {
        switch self {
        case .all: return "all"
        case .cli: return "cli-group"
        case .desktop: return "desktop-group"
        case .claudeCode: return "claude-code"
        case .only(let s): return s.rawValue
        }
    }

    public var label: String {
        switch self {
        case .all: return "All tools"
        case .cli: return "CLI"
        case .desktop: return "Desktop"
        case .claudeCode: return "Claude Code (all)"
        case .only(let s): return s.displayName
        }
    }

    public func matches(_ source: UsageSource) -> Bool {
        switch self {
        case .all: return true
        case .cli: return !source.isDesktop
        case .desktop: return source.isDesktop
        case .claudeCode: return source.isClaudeCode
        case .only(let s): return s == source
        }
    }
}

public struct TokenTotals: Sendable, Equatable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public var requests = 0
    public var cost: Double = 0
    public var saved: Double = 0

    public init() {}

    public var total: Int { input + output + cacheWrite + cacheRead }

    /// Share of prompt tokens served from cache.
    public var cacheHitRate: Double {
        let prompt = input + cacheWrite + cacheRead
        return prompt == 0 ? 0 : Double(cacheRead) / Double(prompt)
    }

    public mutating func add(_ r: UsageRecord) {
        input += r.input
        output += r.output
        cacheWrite += r.cacheWrite
        cacheRead += r.cacheRead
        requests += 1
        cost += r.cost
        saved += r.saved
    }
}

public struct Breakdown: Sendable, Identifiable {
    public var name: String
    public var source: UsageSource?
    public var totals: TokenTotals
    public var id: String { name }
}

public enum BucketUnit: Sendable {
    case hour, day, week
}

public struct SeriesBucket: Sendable, Identifiable {
    public var start: Date
    public var totals: TokenTotals
    public var id: Date { start }
}

public struct UsageSummary: Sendable {
    public var range: TimeRange
    public var filter: SourceFilter
    public var totals = TokenTotals()
    public var sessions = 0
    public var activeDays = 0
    public var byModel: [Breakdown] = []
    public var bySource: [Breakdown] = []
    public var byProject: [Breakdown] = []
    public var buckets: [SeriesBucket] = []
    public var bucketUnit: BucketUnit = .day

    public init(range: TimeRange, filter: SourceFilter) {
        self.range = range
        self.filter = filter
    }
}

/// Claude subscription usage resets on rolling 5-hour windows: a window starts with the first
/// message after the previous one ended (to the minute) and lasts five hours.
public struct BlockInfo: Sendable {
    public static let length: TimeInterval = 5 * 3600

    public var start: Date
    public var lastActivity: Date
    public var totals: TokenTotals
    /// True when the window's start came from Claude's own reset time (Sync with Claude account)
    /// rather than from the local logs.
    public var syncedWithClaude: Bool = false

    public var end: Date { start.addingTimeInterval(Self.length) }

    /// Where a window that begins with a message at `time` starts: that minute. Claude's reset
    /// times are minute-precise (e.g. a window started at 8:40 PM resets at 1:40 AM).
    public static func windowStart(for time: Date) -> Date {
        let t = time.timeIntervalSince1970
        return Date(timeIntervalSince1970: t - t.truncatingRemainder(dividingBy: 60))
    }

    public func isActive(at now: Date) -> Bool {
        now >= start && now < end
    }

    public func progress(at now: Date) -> Double {
        min(1, max(0, now.timeIntervalSince(start) / Self.length))
    }

    public func burnRatePerHour(at now: Date) -> Double {
        let elapsed = max(min(now, end).timeIntervalSince(start), 60)
        return Double(totals.total) / (elapsed / 3600)
    }
}

public struct RootStatus: Sendable, Identifiable, Equatable {
    public var path: String
    public var label: String
    public var exists: Bool
    public var fileCount: Int
    /// Which provider's tool writes these logs.
    public var provider: Provider = .anthropic
    /// False for folders Credo detects but can't read yet (OpenAI and Google tools).
    public var isTracked: Bool = true
    public var id: String { path }
}

public struct UsageSnapshot: Sendable {
    public var generatedAt: Date
    public var summaries: [String: UsageSummary]
    public var block: BlockInfo?
    public var sources: [UsageSource]
    public var fileCount: Int
    public var recordCount: Int
    public var roots: [RootStatus]

    public static let empty = UsageSnapshot(generatedAt: .distantPast, summaries: [:], block: nil,
                                            sources: [], fileCount: 0, recordCount: 0, roots: [])

    public static func key(_ range: TimeRange, _ filter: SourceFilter) -> String {
        "\(range.rawValue)|\(filter.key)"
    }

    public func summary(_ range: TimeRange, _ filter: SourceFilter) -> UsageSummary {
        summaries[Self.key(range, filter)] ?? UsageSummary(range: range, filter: filter)
    }
}
