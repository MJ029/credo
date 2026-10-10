import AppKit

/// Finds copies of earlier versions (TokenMeter, Credo's name before 2.0, and duplicate Credo apps)
/// and, with the user's OK, moves them to the Trash. Nothing is removed without asking, and items
/// go to the Trash rather than being deleted, so they can be put back.
@MainActor
enum LegacyCleanup {
    private static let declinedKey = "legacyCleanup.declined"

    /// Old apps and leftover data that can go.
    static func findLeftovers() -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let me = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        let installed = me.path.hasPrefix("/Applications/") || me.path.hasPrefix(home.appendingPathComponent("Applications").path + "/")

        var candidates = [
            URL(fileURLWithPath: "/Applications/TokenMeter.app"),
            home.appendingPathComponent("Applications/TokenMeter.app"),
        ]
        // A second Credo app only counts as a leftover when this copy is the installed one,
        // so a development build never offers to remove the installed app.
        if installed {
            candidates += [
                URL(fileURLWithPath: "/Applications/Credo.app"),
                home.appendingPathComponent("Applications/Credo.app"),
            ]
        }
        var found = candidates.filter {
            fm.fileExists(atPath: $0.path) && $0.resolvingSymlinksInPath().standardizedFileURL != me
        }
        // TokenMeter's data folder. Its history was copied into Credo's folder on first launch.
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? home.appendingPathComponent("Library/Application Support")
        let oldData = base.appendingPathComponent("TokenMeter", isDirectory: true)
        if fm.fileExists(atPath: oldData.path), fm.fileExists(atPath: AppPaths.supportDirectory.path) {
            found.append(oldData)
        }
        return found
    }

    static func offerIfNeeded() {
        let items = findLeftovers()
        guard !items.isEmpty else { return }
        let signature = items.map(\.path).sorted().joined(separator: "|")
        if UserDefaults.standard.string(forKey: declinedKey) == signature { return }

        let alert = NSAlert()
        alert.messageText = "Remove earlier versions of Credo?"
        alert.informativeText = "Credo found older copies that are no longer needed:\n\n"
            + items.map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            + "\n\nThey'll be moved to the Trash, so you can put them back. Your Credo history is kept."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            remove(items)
        case .alertThirdButtonReturn:
            UserDefaults.standard.set(signature, forKey: declinedKey)
        default:
            break
        }
    }

    static func remove(_ items: [URL]) {
        // Quit any old copy that is still running.
        let paths = Set(items.map { $0.standardizedFileURL.path })
        for app in NSWorkspace.shared.runningApplications {
            if let url = app.bundleURL?.standardizedFileURL, paths.contains(url.path) {
                app.terminate()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            NSWorkspace.shared.recycle(items) { _, error in
                guard error != nil else { return }
                Task { @MainActor in
                    let left = items.filter { FileManager.default.fileExists(atPath: $0.path) }
                    guard !left.isEmpty else { return }
                    let alert = NSAlert()
                    alert.messageText = "Some items couldn't be moved to the Trash"
                    alert.informativeText = "macOS didn't allow Credo to remove:\n\n"
                        + left.map { "• " + ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
                        + "\n\nDrag them to the Trash in Finder, or run the Credo installer and keep \u{201C}Remove previous versions first\u{201D} ticked."
                    alert.addButton(withTitle: "Show in Finder")
                    alert.addButton(withTitle: "OK")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.activateFileViewerSelecting(left)
                    }
                }
            }
        }
    }
}
