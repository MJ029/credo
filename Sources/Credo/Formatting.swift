import SwiftUI
import TokenCore

enum Fmt {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()

    /// 1234 -> "1.23K", 12_345_678 -> "12.3M"
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        switch abs(d) {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return trim(d / 1_000) + "K"
        case ..<1_000_000_000: return trim(d / 1_000_000) + "M"
        default: return trim(d / 1_000_000_000) + "B"
        }
    }

    static func full(_ n: Int) -> String {
        grouped.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func cost(_ c: Double) -> String {
        if c <= 0 { return "$0.00" }
        if c < 0.01 { return "<$0.01" }
        if c < 0.1 { return String(format: "$%.3f", c) }
        if c >= 10_000 { return "$" + trim(c / 1_000) + "K" }
        if c >= 1_000 { return "$" + full(Int(c.rounded())) }
        return String(format: "$%.2f", c)
    }

    static func percent(_ v: Double) -> String {
        let p = v * 100
        if p > 0 && p < 1 { return "<1%" }
        if p < 10 && p.rounded() != p { return String(format: "%.1f%%", p) }
        return String(format: "%.0f%%", p)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds / 60))
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private static func trim(_ v: Double) -> String {
        if v >= 100 { return String(format: "%.0f", v) }
        if v >= 10 { return String(format: "%.1f", v) }
        return String(format: "%.2f", v)
    }
}

enum Palette {
    static let accent = Color(red: 0.77, green: 0.38, blue: 0.25)
    static let accentDark = Color(red: 0.60, green: 0.29, blue: 0.18)
    static let input = Color(red: 0.18, green: 0.44, blue: 0.86)
    static let output = Color(red: 0.56, green: 0.27, blue: 0.79)
    static let cacheWrite = Color(red: 0.12, green: 0.56, blue: 0.53)
    static let cacheRead = Color.gray
    static let desktopCode = Color(red: 0.35, green: 0.34, blue: 0.84)

    static func source(_ s: UsageSource?) -> Color {
        guard let s else { return accent }
        switch s {
        case .claudeCodeCLI: return accent
        case .vscode: return input
        case .desktopCode: return desktopCode
        case .desktopAgent: return cacheWrite
        case .agentSDK: return .pink
        }
    }

    static let models: [Color] = [desktopCode, input, accent, .gray]
}

/// Which time window the menu bar item reports on.
enum MenuBarWindow: String, CaseIterable, Identifiable {
    case fiveHour = "5h", day, week, all

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fiveHour: return "5 hr"
        case .day: return "Day"
        case .week: return "Week"
        case .all: return "All"
        }
    }
}

/// What the menu bar item shows for that window.
enum MenuBarShow: String, CaseIterable, Identifiable {
    case usage, both, percent, full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .usage: return "Usage"
        case .both: return "Usage + %"
        case .percent: return "%"
        case .full: return "Usage + % + time"
        }
    }
}

/// The menu bar item: text only, no icon. Any window × usage / usage + % / % / usage + % + time left.
enum MenuBarText {
    static var window: MenuBarWindow {
        MenuBarWindow(rawValue: UserDefaults.standard.string(forKey: PrefKey.menuBarWindow) ?? "") ?? .fiveHour
    }

    static var show: MenuBarShow {
        MenuBarShow(rawValue: UserDefaults.standard.string(forKey: PrefKey.menuBarShow) ?? "") ?? .percent
    }

    /// For the 5-hour window, 100% can mean "window fully elapsed" (default) or a token budget.
    static var fiveHourUsesBudget: Bool {
        UserDefaults.standard.string(forKey: PrefKey.menuBarBasis5h) == "budget"
    }

    /// Budget in millions of tokens; 0 means not set.
    static func budget(_ window: MenuBarWindow) -> Double {
        UserDefaults.standard.double(forKey: PrefKey.budget(window))
    }

    /// Tokens as a share of the budget set for a window, or nil when no budget is set.
    static func budgetShare(_ window: MenuBarWindow, tokens: Int) -> Double? {
        let limit = budget(window) * 1_000_000
        return limit > 0 ? Double(tokens) / limit : nil
    }

    @MainActor
    static func usage(_ window: MenuBarWindow, store: UsageStore, now: Date) -> Int? {
        switch window {
        case .fiveHour:
            guard let block = store.snapshot.block, block.isActive(at: now) else { return nil }
            return block.totals.total
        case .day: return store.snapshot.summary(.today, .all).totals.total
        case .week: return store.snapshot.summary(.week, .all).totals.total
        case .all: return store.snapshot.summary(.all, .all).totals.total
        }
    }

    @MainActor
    static func percent(_ window: MenuBarWindow, store: UsageStore, now: Date) -> Double? {
        // Synced with Claude: show Claude's own limit percentages.
        if window == .fiveHour, store.isSynced {
            return store.syncedSessionUsed(at: now)
        }
        if window == .week, let week = store.syncedWeek(at: now) {
            return week.used
        }
        if window == .fiveHour && !fiveHourUsesBudget {
            guard let block = store.snapshot.block, block.isActive(at: now) else { return nil }
            return block.progress(at: now)
        }
        let limit = budget(window) * 1_000_000
        guard limit > 0, let used = usage(window, store: store, now: now) else { return nil }
        return Double(used) / limit
    }

    /// Time until the 5-hour window resets. Only the 5-hour window shows time left.
    @MainActor
    static func timeLeft(_ window: MenuBarWindow, store: UsageStore, now: Date) -> TimeInterval? {
        guard window == .fiveHour, let block = store.snapshot.block, block.isActive(at: now) else { return nil }
        return block.end.timeIntervalSince(now)
    }

    @MainActor
    static func text(store: UsageStore, now: Date = Date()) -> String {
        text(window: window, show: show, store: store, now: now)
    }

    @MainActor
    static func text(window: MenuBarWindow, show: MenuBarShow, store: UsageStore, now: Date = Date()) -> String {
        guard store.snapshot.recordCount > 0 else { return "Credo" }
        let used = usage(window, store: store, now: now)
        let pct = percent(window, store: store, now: now)
        if window == .fiveHour && used == nil { return "Credo" }   // no active 5-hour window
        let tokens = Fmt.tokens(used ?? 0)
        switch show {
        case .usage:
            return tokens
        case .percent:
            return pct.map { Fmt.percent($0) } ?? "–%"
        case .both:
            guard let pct else { return tokens }
            return "\(tokens) · \(Fmt.percent(pct))"
        case .full:
            var parts = [tokens]
            if let pct { parts.append(Fmt.percent(pct)) }
            if let left = timeLeft(window, store: store, now: now) {
                parts.append("\(Fmt.duration(left)) left")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// The desktop widgets offered in Settings › Widgets.
enum WidgetKind: String, CaseIterable, Identifiable {
    case summary, window, tools, cache, models, economy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .summary: return "Usage summary"
        case .window: return "5h window"
        case .tools: return "Tokens by tool"
        case .cache: return "Cache savings"
        case .models: return "Tokens by model"
        case .economy: return "Token economy"
        }
    }

    var detail: String {
        switch self {
        case .summary: return "Medium · tokens, cost, mix, 7 days"
        case .window: return "Small · battery-style ring"
        case .tools: return "Medium · icon rings per tool"
        case .cache: return "Small · cache hit and $ saved"
        case .models: return "Medium · share per model"
        case .economy: return "Medium · $ per request, session, day"
        }
    }

    var symbol: String {
        switch self {
        case .summary: return "chart.bar.xaxis"
        case .window: return "speedometer"
        case .tools: return "macwindow"
        case .cache: return "bolt.fill"
        case .models: return "cpu"
        case .economy: return "dollarsign.circle"
        }
    }

    var size: CGSize {
        switch self {
        case .summary: return CGSize(width: 320, height: 252)
        case .window, .cache: return CGSize(width: 170, height: 170)
        case .tools, .models, .economy: return CGSize(width: 360, height: 170)
        }
    }

    /// The summary widget is on by default, like the single widget in 1.x.
    var defaultOn: Bool { self == .summary }
}
