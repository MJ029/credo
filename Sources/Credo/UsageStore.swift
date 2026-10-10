import Foundation
import SwiftUI
import TokenCore

enum AppPaths {
    static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Credo", isDirectory: true)
        migrateFromTokenMeter(base: base, to: dir)
        return dir
    }()

    static var pricingURL: URL { supportDirectory.appendingPathComponent("pricing.json") }

    /// Credo was called TokenMeter before 2.0: carry its history and pricing over once.
    private static func migrateFromTokenMeter(base: URL, to dir: URL) {
        let fm = FileManager.default
        let old = base.appendingPathComponent("TokenMeter", isDirectory: true)
        guard !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["history-v2.tsv", "pricing.json"] {
            let from = old.appendingPathComponent(name)
            if fm.fileExists(atPath: from.path) {
                try? fm.copyItem(at: from, to: dir.appendingPathComponent(name))
            }
        }
    }
}

enum PrefKey {
    static let refreshInterval = "refreshInterval"
    static let menuBarWindow = "menuBarWindow"
    static let menuBarShow = "menuBarShow"
    static let menuBarBasis5h = "menuBarBasis5h"
    static let syncClaude = "syncClaudeAccount"
    static func budget(_ window: MenuBarWindow) -> String { "budget.\(window.rawValue)" }
    static let widgetLevel = "widgetLevel"
    static let widgetRange = "widgetRange"
    static let widgetGlass = "widgetGlass"
    static let extraFolders = "extraFolders"
    static let selectedRange = "selectedRange"
    static let chartMode = "chartMode"
    static func widgetEnabled(_ kind: WidgetKind) -> String { "widget.\(kind.rawValue)" }
}

enum Prefs {
    static var extraFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: PrefKey.extraFolders) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: PrefKey.extraFolders) }
    }

    static var syncClaude: Bool { UserDefaults.standard.bool(forKey: PrefKey.syncClaude) }

    static var refreshInterval: Double {
        let v = UserDefaults.standard.double(forKey: PrefKey.refreshInterval)
        return v >= 10 ? v : 60
    }

    static func isWidgetEnabled(_ kind: WidgetKind) -> Bool {
        UserDefaults.standard.bool(forKey: PrefKey.widgetEnabled(kind))
    }

    static func setWidgetEnabled(_ kind: WidgetKind, _ on: Bool) {
        UserDefaults.standard.set(on, forKey: PrefKey.widgetEnabled(kind))
    }
}

enum RefreshMode: Sendable {
    case normal, rescan, clearHistory, reloadPricing
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published private(set) var snapshot: UsageSnapshot = .empty
    @Published private(set) var isScanning = false
    @Published private(set) var lastUpdated: Date?
    @Published var range: TimeRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: PrefKey.selectedRange) }
    }
    @Published var filter: SourceFilter = .all
    @Published var provider: Provider = .all

    private let engine = UsageEngine(supportDirectory: AppPaths.supportDirectory)
    /// Ticks every 30 seconds so countdowns (the menu bar's "time left") stay current
    /// even when the refresh interval is long.
    @Published private(set) var clock = Date()

    /// The menu bar title. The App's label reads this directly, so it changes the moment
    /// a setting, the data or the clock changes, with no restart.
    @Published private(set) var menuBarText = "Credo"

    /// Claude's own limits when Sync with Claude account is on.
    @Published private(set) var limits: ClaudeLimits?
    @Published private(set) var limitsError: LimitsError?
    @Published private(set) var isSyncingLimits = false

    /// How often Credo asks Claude for its limits.
    static let limitsInterval: TimeInterval = 180

    private var timer: Timer?
    private var clockTimer: Timer?
    private var queuedMode: RefreshMode?
    private var lastLimitsFetch = Date.distantPast
    private var defaultsObserver: NSObjectProtocol?

    private init() {
        range = TimeRange(rawValue: UserDefaults.standard.string(forKey: PrefKey.selectedRange) ?? "") ?? .today
    }

    var summary: UsageSummary {
        provider.isSupported ? snapshot.summary(range, filter) : UsageSummary(range: range, filter: filter)
    }
    var today: UsageSummary { snapshot.summary(.today, .all) }

    /// The popover's tool picker: All tools | CLI | Desktop.
    let availableFilters: [SourceFilter] = [.all, .cli, .desktop]

    func start() {
        syncLimits(force: true)
        refresh()
        scheduleTimer()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.settingsChanged() }
        }
        let c = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        c.tolerance = 5
        RunLoop.main.add(c, forMode: .common)
        clockTimer = c
    }

    func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: Prefs.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refresh(mode: RefreshMode = .normal) {
        if isScanning {
            if queuedMode == nil || mode != .normal { queuedMode = mode }
            return
        }
        isScanning = true
        let engine = self.engine
        let extras = Prefs.extraFolders
        let window = windowOverride(at: Date())
        Task.detached(priority: .utility) { [weak self] in
            switch mode {
            case .normal: break
            case .rescan: engine.resetScanState()
            case .clearHistory: engine.clearHistory()
            case .reloadPricing: engine.reloadPricing()
            }
            let snap = engine.refresh(extraFolders: extras, window: window)
            await self?.apply(snap)
        }
    }

    private func apply(_ snap: UsageSnapshot) {
        snapshot = snap
        lastUpdated = Date()
        isScanning = false
        updateMenuBarText()
        if let next = queuedMode {
            queuedMode = nil
            refresh(mode: next)
        }
    }

    // MARK: - Menu bar title

    func updateMenuBarText() {
        let text = MenuBarText.text(store: self)
        if text != menuBarText { menuBarText = text }
    }

    private var lastSyncSetting = Prefs.syncClaude

    /// Any setting changed (menu bar window, show, basis, budgets, sync…).
    private func settingsChanged() {
        let sync = Prefs.syncClaude
        if sync != lastSyncSetting {
            lastSyncSetting = sync
            if sync {
                syncLimits(force: true)
            } else {
                limits = nil
                limitsError = nil
                refresh()
            }
        }
        updateMenuBarText()
    }

    private func tick() {
        let now = Date()
        clock = now
        // Claude's window just reset: ask for the new one straight away.
        if let reset = limits?.fiveHour?.resetsAt, reset <= now, lastLimitsFetch < reset {
            syncLimits(force: true)
        } else {
            syncLimits()
        }
        updateMenuBarText()
    }

    // MARK: - Sync with Claude account

    /// Where the 5-hour window sits. With sync on and a fresh answer from Claude, Claude's reset
    /// time decides; otherwise nil, and the window is worked out from the logs.
    func windowOverride(at now: Date) -> WindowOverride? {
        guard Prefs.syncClaude, let limits else { return nil }
        if let start = limits.sessionStart(at: now) { return .start(start) }
        // Claude said no window was running. Trust that only while the answer is recent.
        if limits.fiveHour?.resetsAt == nil, now.timeIntervalSince(limits.fetchedAt) < Self.limitsInterval * 2 {
            return .noWindow
        }
        return nil
    }

    var isSynced: Bool { Prefs.syncClaude && limits != nil }

    /// Claude's 5-hour "Current session" share, while its window is running.
    func syncedSessionUsed(at now: Date) -> Double? {
        guard Prefs.syncClaude, let limits, limits.sessionStart(at: now) != nil else { return nil }
        return limits.fiveHour?.used
    }

    /// Claude's weekly limit, while its reset time is ahead.
    func syncedWeek(at now: Date) -> LimitWindow? {
        guard Prefs.syncClaude else { return nil }
        return limits?.week(at: now)
    }

    func syncLimits(force: Bool = false) {
        guard Prefs.syncClaude else { return }
        guard !isSyncingLimits else { return }
        let now = Date()
        var wait = Self.limitsInterval
        if limitsError == .rateLimited { wait *= 3 }
        guard force || now.timeIntervalSince(lastLimitsFetch) >= wait else { return }
        lastLimitsFetch = now
        isSyncingLimits = true
        Task.detached(priority: .utility) { [weak self] in
            let result = await ClaudeLimitsClient.fetch()
            await self?.applyLimits(result)
        }
    }

    private func applyLimits(_ result: Result<ClaudeLimits, LimitsError>) {
        isSyncingLimits = false
        guard Prefs.syncClaude else { return }
        let before = windowOverride(at: Date())
        switch result {
        case .success(let l):
            limits = l
            limitsError = nil
        case .failure(let e):
            limitsError = e
            // Keep the last answer while its window is still running; after that, fall back to logs.
            if let l = limits, l.sessionStart(at: Date()) == nil, l.week(at: Date()) == nil { limits = nil }
        }
        if windowOverride(at: Date()) != before { refresh() }
        updateMenuBarText()
    }
}
