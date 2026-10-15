import Cocoa
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let index = AppIndex()
    private let usage = Usage(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Glasslight/usage.json"))
    private var search: SearchController!
    private var hotKey: HotKey!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        search = SearchController(index: index, usage: usage)
        index.onChange = { [weak self] in self?.search.indexDidChange() }
        index.start()
        hotKey = HotKey { [weak self] in self?.search.toggle() }
        hotKey.start()
        settings = SettingsWindowController(
            onChange: { [weak self] in self?.search.applyAppearance() },
            showPreview: { [weak self] in self?.search.showPreview() },
            hidePreview: { [weak self] in self?.search.endPreview() })
        setUpStatusItem()
        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.async { self.search.show() }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.async { self.settings.show() }
        }
    }

    /// Opening the app again (Finder, `open -a Glasslight`) shows the search bar.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if settings.isOpen { settings.show() } else { search.show() }
        return false
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "sparkle.magnifyingglass", accessibilityDescription: "Glasslight")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "Open Glasslight  (Double-tap Right ⌘)", action: #selector(openPanel), keyEquivalent: "").target = self
        if !hotKey.isActive {
            menu.addItem(withTitle: "Enable Shortcut (Allow Input Monitoring)…", action: #selector(enableShortcut),
                         keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(withTitle: "Rescan Applications", action: #selector(rescan), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Glasslight", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func openPanel() {
        DispatchQueue.main.async { self.search.show() }
    }

    @objc private func openSettings() {
        DispatchQueue.main.async { self.settings.show() }
    }

    @objc private func enableShortcut() {
        hotKey.requestAccess()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Glasslight: launch at login failed: \(error.localizedDescription)")
        }
    }

    @objc private func rescan() {
        index.rescan()
    }
}
