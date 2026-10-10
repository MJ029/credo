import AppKit
import SwiftUI
import TokenCore

/// NSHostingView for widget panels. Widgets never become the active window, so the
/// view must accept the first click, otherwise macOS swallows it and nothing can be dragged.
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transparent layer on top of each widget: left-drag moves the widget anywhere on screen,
/// right-click opens the widget menu. Positions are remembered per widget.
final class WidgetDragView: NSView {
    var menuProvider: (() -> NSMenu)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            showMenu(event)
        } else {
            window?.performDrag(with: event)
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        showMenu(event)
    }

    private func showMenu(_ event: NSEvent) {
        guard let menu = menuProvider?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

struct WidgetDragLayer: NSViewRepresentable {
    let menuProvider: () -> NSMenu

    func makeNSView(context: Context) -> WidgetDragView {
        let view = WidgetDragView()
        view.menuProvider = menuProvider
        return view
    }

    func updateNSView(_ nsView: WidgetDragView, context: Context) {
        nsView.menuProvider = menuProvider
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, state: NSControl.StateValue = .off, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        self.target = self
        self.state = state
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() { handler() }
}

@MainActor
final class WindowManager: NSObject {
    static let shared = WindowManager()

    private var panels: [WidgetKind: NSPanel] = [:]
    private var settingsWindow: NSWindow?

    // MARK: Desktop widgets

    func restoreWidgets() {
        for kind in WidgetKind.allCases where Prefs.isWidgetEnabled(kind) {
            show(kind)
        }
    }

    func setWidget(_ kind: WidgetKind, visible: Bool) {
        Prefs.setWidgetEnabled(kind, visible)
        SettingsModel.shared.syncFromSystem()
        if visible { show(kind) } else { panels[kind]?.orderOut(nil) }
    }

    /// Re-applies placement (desktop level vs floating) and light/dark glass to every widget.
    func applyWidgetStyle() {
        for panel in panels.values { style(panel) }
    }

    private func style(_ panel: NSPanel) {
        let defaults = UserDefaults.standard
        let floating = defaults.string(forKey: PrefKey.widgetLevel) == "floating"
        panel.level = floating
            ? .floating
            : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        switch defaults.string(forKey: PrefKey.widgetGlass) ?? "light" {
        case "dark": panel.appearance = NSAppearance(named: .darkAqua)
        case "system": panel.appearance = nil
        default: panel.appearance = NSAppearance(named: .aqua)
        }
    }

    private func show(_ kind: WidgetKind) {
        let panel = panels[kind] ?? makePanel(kind)
        panels[kind] = panel
        style(panel)
        panel.orderFrontRegardless()
    }

    private func makePanel(_ kind: WidgetKind) -> NSPanel {
        let size = NSSize(width: kind.size.width, height: kind.size.height)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.contentView = DraggableHostingView(
            rootView: DesktopWidget(kind: kind).environmentObject(UsageStore.shared))

        let autosave = "CredoWidget.\(kind.rawValue)"
        if panel.setFrameUsingName(autosave) {
            panel.setContentSize(size)
        } else if let screen = NSScreen.main {
            // First launch: stack widgets down the right edge of the screen.
            let vf = screen.visibleFrame
            let index = WidgetKind.allCases.firstIndex(of: kind) ?? 0
            let column = CGFloat(index / 3)
            let row = CGFloat(index % 3)
            let x = vf.maxX - 24 - 380 * (column + 1) + (380 - size.width)
            let y = vf.maxY - 24 - size.height - row * 270
            panel.setFrameOrigin(NSPoint(x: x, y: max(vf.minY + 24, y)))
        }
        panel.setFrameAutosaveName(autosave)
        return panel
    }

    /// Right-click menu for a widget.
    func widgetMenu(for kind: WidgetKind) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(ClosureMenuItem("Refresh now") { UsageStore.shared.refresh() })
        let periodItem = NSMenuItem(title: "Show period", action: nil, keyEquivalent: "")
        let periods = NSMenu()
        let current = UserDefaults.standard.string(forKey: PrefKey.widgetRange) ?? TimeRange.all.rawValue
        for range in TimeRange.allCases {
            periods.addItem(ClosureMenuItem(range.title, state: range.rawValue == current ? .on : .off) {
                UserDefaults.standard.set(range.rawValue, forKey: PrefKey.widgetRange)
            })
        }
        periodItem.submenu = periods
        menu.addItem(periodItem)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Widget settings…") { WindowManager.shared.showSettings() })
        menu.addItem(ClosureMenuItem("Hide this widget") { WindowManager.shared.setWidget(kind, visible: false) })
        return menu
    }

    // MARK: Settings

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 580, height: 700),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false)
            window.title = "Credo Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(
                rootView: SettingsView().environmentObject(UsageStore.shared))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
