import SwiftUI
import AppKit
import ServiceManagement
import TokenCore

/// Settings-screen state. Kept in a class (not @State) because @State needs the SwiftUI
/// macro plugin, which only ships with full Xcode — not the Command Line Tools.
@MainActor
final class SettingsModel: ObservableObject {
    static let shared = SettingsModel()

    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var loginError: String?
    @Published var extraFolders: [String] = Prefs.extraFolders
    @Published var confirmClear = false
    @Published var widgetsOn: [String: Bool] = [:]
    /// Menu bar budgets per window, in millions of tokens (0 = not set).
    @Published var budgets: [String: Double] = [:]

    init() {
        syncFromSystem()
    }

    func syncFromSystem() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        extraFolders = Prefs.extraFolders
        var on: [String: Bool] = [:]
        for kind in WidgetKind.allCases { on[kind.rawValue] = Prefs.isWidgetEnabled(kind) }
        widgetsOn = on
        var b: [String: Double] = [:]
        for w in MenuBarWindow.allCases { b[w.rawValue] = MenuBarText.budget(w) }
        budgets = b
    }

    func budgetBinding(for window: MenuBarWindow) -> Binding<Double> {
        Binding(
            get: { self.budgets[window.rawValue] ?? 0 },
            set: { value in
                let clean = max(0, value)
                UserDefaults.standard.set(clean, forKey: PrefKey.budget(window))
                self.budgets[window.rawValue] = clean
            })
    }

    func binding(for kind: WidgetKind) -> Binding<Bool> {
        Binding(
            get: { self.widgetsOn[kind.rawValue] ?? false },
            set: { WindowManager.shared.setWidget(kind, visible: $0) })
    }
}

struct SettingsView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WidgetSettings()
                .tabItem { Label("Widgets", systemImage: "square.grid.2x2") }
        }
        .frame(width: 580, height: 700)
        .onAppear { SettingsModel.shared.syncFromSystem() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @EnvironmentObject var store: UsageStore
    @ObservedObject private var model = SettingsModel.shared

    @AppStorage(PrefKey.refreshInterval) private var refreshInterval: Double = 60
    @AppStorage(PrefKey.menuBarWindow) private var mbWindow = MenuBarWindow.fiveHour.rawValue
    @AppStorage(PrefKey.menuBarShow) private var mbShow = MenuBarShow.percent.rawValue
    @AppStorage(PrefKey.menuBarBasis5h) private var mbBasis = "time"
    @AppStorage(PrefKey.syncClaude) private var syncClaude = false

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .onChange(of: model.launchAtLogin) { enabled in setLaunchAtLogin(enabled) }
                if let error = model.loginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Picker("Refresh every", selection: $refreshInterval) {
                    Text("15 seconds").tag(15.0)
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                }
                .onChange(of: refreshInterval) { _ in store.scheduleTimer() }
            }

            Section {
                Toggle("Sync with Claude account", isOn: $syncClaude)
                if syncClaude {
                    SyncStatusRow()
                }
            } header: {
                Text("Claude account")
            } footer: {
                Text("Reads Claude Code's sign-in from your Keychain and asks Claude for your plan's 5-hour and weekly limits every 3 minutes, so Credo's 5-hour window, percentage and reset time match Claude's own. It only reads usage and never renews the sign-in. The service it uses is unofficial; if it stops working, Credo goes back to working the window out from your logs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Time window", selection: $mbWindow) {
                    ForEach(MenuBarWindow.allCases) { w in Text(w.label).tag(w.rawValue) }
                }
                .pickerStyle(.segmented)
                let window = MenuBarWindow(rawValue: mbWindow) ?? .fiveHour
                Picker("Show", selection: $mbShow) {
                    // Time left only applies to the 5-hour window.
                    ForEach(MenuBarShow.allCases.filter { $0 != .full || window == .fiveHour }) { o in
                        Text(o.label).tag(o.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mbWindow) { w in
                    if w != MenuBarWindow.fiveHour.rawValue && mbShow == MenuBarShow.full.rawValue {
                        mbShow = MenuBarShow.both.rawValue
                    }
                }
                let synced = syncClaude && store.isSynced
                if mbShow != MenuBarShow.usage.rawValue && synced && (window == .fiveHour || window == .week) {
                    Text(window == .fiveHour
                         ? "Synced with Claude: 100% is your plan's 5-hour limit, the same as Claude's \u{201C}Current session\u{201D} bar."
                         : "Synced with Claude: 100% is your plan's weekly limit. Tokens are Credo's last 7 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if mbShow != MenuBarShow.usage.rawValue {
                    if window == .fiveHour {
                        Picker("100% equals", selection: $mbBasis) {
                            Text("Time elapsed in window").tag("time")
                            Text("Token budget").tag("budget")
                        }
                        Text("Claude's own \u{201C}Current session\u{201D} % counts all your Claude use (web, desktop and mobile chats plus Claude Code) against your plan's limit. To show exactly that %, turn on Sync with Claude account above. Without it, pick Token budget and enter the tokens you usually have per 5-hour session to approximate it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if window != .fiveHour || mbBasis == "budget" {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("\(window.label) budget")
                                Text(window == .week ? "e.g. your weekly allowance" : "100% = this many tokens")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("Budget", value: model.budgetBinding(for: window), format: .number)
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(width: 90)
                            Text("M tokens").foregroundStyle(.secondary)
                        }
                    }
                }
                if mbShow == MenuBarShow.full.rawValue && window == .fiveHour {
                    Text("Time left until this 5-hour window resets.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Menu bar preview")
                    Spacer()
                    // Reads the budgets via the model so the preview updates as you type.
                    let _ = model.budgets
                    Text(store.menuBarText)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            } header: {
                Text("Menu bar shows")
            } footer: {
                Text("Text only, no icon. Any time window works with usage, usage + percentage or percentage. The 5-hour window can also show time left.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Data sources") {
                ForEach([Provider.anthropic, .openai, .google]) { provider in
                    Text(provider.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    let roots = store.snapshot.roots.filter { $0.provider == provider }
                    if roots.isEmpty {
                        Text("Checking…").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(roots) { root in
                        DataSourceRow(root: root,
                                      removable: model.extraFolders.contains(root.path),
                                      remove: { removeFolder(root.path) })
                    }
                }
                HStack {
                    Button("Add folder…") { addFolder() }
                    Spacer()
                    Button("Rescan all logs") { store.refresh(mode: .rescan) }
                }
                Text("\(Fmt.full(store.snapshot.recordCount)) API calls tracked from \(store.snapshot.fileCount) Claude log files. Credo keeps its own history, so totals survive Claude Code's automatic cleanup of old transcripts. OpenAI and Google folders are detected but not counted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cost estimates") {
                Text("Costs are estimated at Anthropic API list prices (USD per million tokens). On a Pro or Max plan you aren't billed per token — treat this as the value of what you used.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Edit pricing.json") { NSWorkspace.shared.open(AppPaths.pricingURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.pricingURL]) }
                    Spacer()
                    Button("Reload prices") { store.refresh(mode: .reloadPricing) }
                }
            }

            Section("History") {
                HStack {
                    Text("Saved in ~/Library/Application Support/Credo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear history…", role: .destructive) { model.confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear Credo's saved history?", isPresented: $model.confirmClear) {
            Button("Clear history", role: .destructive) { store.refresh(mode: .clearHistory) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Usage will be rebuilt from the Claude logs that still exist on disk. Older totals that Claude Code has already cleaned up will be lost.")
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            model.loginError = nil
        } catch {
            model.loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != model.launchAtLogin { model.launchAtLogin = actual }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Choose a folder that contains Claude .jsonl session logs"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !model.extraFolders.contains(url.path) {
            model.extraFolders.append(url.path)
            Prefs.extraFolders = model.extraFolders
            store.refresh()
        }
    }

    private func removeFolder(_ path: String) {
        model.extraFolders.removeAll { $0 == path }
        Prefs.extraFolders = model.extraFolders
        store.refresh()
    }
}

// MARK: - Widgets

private struct WidgetSettings: View {
    @ObservedObject private var model = SettingsModel.shared

    @AppStorage(PrefKey.widgetLevel) private var widgetLevel = "desktop"
    @AppStorage(PrefKey.widgetGlass) private var widgetGlass = "light"
    @AppStorage(PrefKey.widgetRange) private var widgetRange = TimeRange.all.rawValue

    var body: some View {
        Form {
            Section("On the desktop") {
                Picker("Placement", selection: $widgetLevel) {
                    Text("On the desktop, behind windows").tag("desktop")
                    Text("Floating above all windows").tag("floating")
                }
                .onChange(of: widgetLevel) { _ in WindowManager.shared.applyWidgetStyle() }
                Picker("Glass style", selection: $widgetGlass) {
                    Text("Light glass").tag("light")
                    Text("Dark glass").tag("dark")
                    Text("Match system").tag("system")
                }
                .onChange(of: widgetGlass) { _ in WindowManager.shared.applyWidgetStyle() }
                Picker("Period", selection: $widgetRange) {
                    ForEach(TimeRange.allCases) { r in Text(r.title).tag(r.rawValue) }
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(WidgetKind.allCases) { kind in
                        WidgetCard(kind: kind, isOn: model.binding(for: kind))
                    }
                }
                .padding(.vertical, 4)
            } header: {
                HStack {
                    Text("Widgets")
                    Spacer()
                    let count = model.widgetsOn.values.filter { $0 }.count
                    Text("\(count) of \(WidgetKind.allCases.count) on desktop")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Turn a widget on to place it on the desktop. Drag widgets to arrange them; right-click one for quick options.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// A widget in Settings › Widgets: glass preview thumbnail, name, size and an on/off switch.
private struct WidgetCard: View {
    let kind: WidgetKind
    @Binding var isOn: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color(white: 0.80)
                GlowBackground()
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.6), lineWidth: 1)
                    )
                    .frame(width: kind.size.width > 200 ? 170 : 80, height: 64)
                    .overlay(
                        Image(systemName: kind.symbol)
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    )
            }
            .frame(height: 96)
            .clipped()
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title).font(.callout.weight(.semibold))
                    Text(kind.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Toggle("Show \(kind.title) on desktop", isOn: $isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(10)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        )
    }
}

/// One log folder in Settings › General › Data sources.
private struct DataSourceRow: View {
    let root: RootStatus
    let removable: Bool
    let remove: () -> Void

    private var status: String {
        guard root.exists else { return "not found" }
        if root.isTracked { return "\(root.fileCount) logs" }
        return "found · not counted yet"
    }

    private var symbol: String {
        guard root.exists else { return "circle.dashed" }
        return root.isTracked ? "checkmark.circle.fill" : "clock.fill"
    }

    private var tint: Color {
        guard root.exists else { return .secondary }
        return root.isTracked ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(root.label)
                Text(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
            if removable {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this folder")
            }
        }
        .help(root.isTracked ? "" : "Credo will count \(root.label) usage in a future version.")
    }
}

/// Status of Sync with Claude account: last answer, or what went wrong.
struct SyncStatusRow: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        let now = store.clock
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(store.limitsError == nil && store.limits != nil ? Color.green
                      : store.limitsError == nil ? Color.gray : Color.orange)
                .frame(width: 8, height: 8)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                if let l = store.limits {
                    Text(sessionLine(l, now: now)).font(.callout)
                    if let w = l.week(at: now), let reset = w.resetsAt {
                        Text("Weekly \(Fmt.percent(w.used)) used · resets \(reset.formatted(.dateTime.weekday(.abbreviated).hour().minute()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Synced \(l.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                } else if store.limitsError == nil {
                    Text(store.isSyncingLimits ? "Checking with Claude…" : "Waiting for the first sync…").font(.callout)
                }
                if let e = store.limitsError {
                    Text(e.message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Button("Sync now") { store.syncLimits(force: true) }
                .disabled(store.isSyncingLimits)
        }
    }

    private func sessionLine(_ l: ClaudeLimits, now: Date) -> String {
        guard let five = l.fiveHour else { return "5-hour session: no data" }
        guard let reset = five.resetsAt, reset > now else { return "No 5-hour session running" }
        return "Session \(Fmt.percent(five.used)) used · resets \(reset.formatted(date: .omitted, time: .shortened))"
    }
}
