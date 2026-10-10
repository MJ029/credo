import SwiftUI
import AppKit
import TokenCore

@main
struct CredoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore.shared

    init() {
        // `Credo.app/Contents/MacOS/Credo --report` prints a text summary and exits.
        if CommandLine.arguments.contains("--report") {
            let engine = UsageEngine(supportDirectory: AppPaths.supportDirectory)
            let snapshot = engine.refresh(extraFolders: Prefs.extraFolders)
            print(Report.text(snapshot))
            exit(0)
        }
        // `Credo --limits` asks Claude for your plan limits once and prints them (tests the sync).
        if CommandLine.arguments.contains("--limits") {
            switch ClaudeLimitsClient.fetchBlocking() {
            case .success(let l):
                func line(_ name: String, _ w: LimitWindow?) -> String {
                    guard let w else { return "\(name): no data" }
                    let reset = w.resetsAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "no window running"
                    return "\(name): \(Fmt.percent(w.used)) used · resets \(reset)"
                }
                print("Claude limits (synced \(l.fetchedAt.formatted(date: .omitted, time: .standard)))")
                print(line("5-hour session", l.fiveHour))
                print(line("Weekly", l.sevenDay))
                exit(0)
            case .failure(let e):
                print("Sync failed: \(e.message)")
                exit(1)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(store)
        } label: {
            // Read straight from the store so the title changes the moment a setting does.
            Text(store.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        var defaults: [String: Any] = [PrefKey.widgetRange: TimeRange.all.rawValue]
        for kind in WidgetKind.allCases {
            defaults[PrefKey.widgetEnabled(kind)] = kind.defaultOn
        }
        UserDefaults.standard.register(defaults: defaults)

        UsageStore.shared.start()
        WindowManager.shared.restoreWidgets()
        // Offer to remove older copies (TokenMeter, duplicate Credo apps) once Credo is up.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            LegacyCleanup.offerIfNeeded()
        }
    }
}
