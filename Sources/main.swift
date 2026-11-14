// ClipStash — a lightweight clipboard history for the macOS menu bar. Personal use.
// Build with ./build.sh

import AppKit
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = ClipboardMonitor()
    private let popup = PopupController()
    private var subs = Set<AnyCancellable>()
    private var lastHistorySize = 0
    private var lastInterval = 0.0

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.target = self
            b.action = #selector(statusClicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageLeading
        }

        popup.statusItemFrame = { [weak self] in self?.statusItem.button?.window?.frame }
        popup.openSettings = { SettingsWindowController.shared.show() }
        HotKeyCenter.shared.action = { [weak self] in self?.popup.toggle() }
        HotKeyCenter.shared.registerIfChanged()

        lastHistorySize = Prefs.historySize
        lastInterval = Prefs.checkInterval
        monitor.start()

        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.prefsChanged() }
            .store(in: &subs)
        HistoryStore.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshStatusItem() }
            .store(in: &subs)
        refreshStatusItem()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again (e.g. when the menu bar icon is hidden) opens Settings.
        SettingsWindowController.shared.show()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if Prefs.clearOnQuit { HistoryStore.shared.clear(includePins: false) }
        HistoryStore.shared.saveNow(sync: true)
    }

    private func prefsChanged() {
        refreshStatusItem()
        HotKeyCenter.shared.registerIfChanged()
        if Prefs.historySize != lastHistorySize {
            lastHistorySize = Prefs.historySize
            HistoryStore.shared.enforceLimit()
        }
        if Prefs.checkInterval != lastInterval {
            lastInterval = Prefs.checkInterval
            monitor.start()
        }
    }

    // MARK: Menu bar icon

    @objc private func statusClicked() {
        guard let e = NSApp.currentEvent else { return }
        let f = e.modifierFlags
        if e.type == .rightMouseUp || f.contains(.control) { showMenu(); return }
        if f.contains(.option) && f.contains(.shift) { Prefs.ignoreOnlyNextEvent.toggle(); return }
        if f.contains(.option) { Prefs.ignoreEvents.toggle(); return }
        popup.toggle(fromStatusItem: true)
    }

    private func refreshStatusItem() {
        guard let item = statusItem, let b = item.button else { return }
        item.isVisible = !Prefs.hideMenuBarIcon
        let paused = Prefs.ignoreEvents, skipNext = Prefs.ignoreOnlyNextEvent
        let img = NSImage(systemSymbolName: Prefs.menuIcon.symbol, accessibilityDescription: "ClipStash")
        img?.isTemplate = true
        b.image = img
        b.appearsDisabled = paused || skipNext
        b.toolTip = paused ? "ClipStash: recording paused (⌥-click to resume)"
            : skipNext ? "ClipStash: ignoring the next copy"
            : "ClipStash (\(HotKeyFormat.string(code: Prefs.hotKeyCode, mods: Prefs.hotKeyMods)))"
        if Prefs.showRecentInMenuBar, let latest = HistoryStore.shared.sorted(.lastCopiedAt).first {
            let t = Display.title(latest, special: false)
            b.title = " " + (t.count > 24 ? String(t.prefix(23)) + "…" : t)
        } else {
            b.title = ""
        }
    }

    private func showMenu() {
        let m = NSMenu()
        let show = m.addItem(withTitle: "Show History", action: #selector(showPopup), keyEquivalent: "")
        show.toolTip = HotKeyFormat.string(code: Prefs.hotKeyCode, mods: Prefs.hotKeyMods)

        let recent = HistoryStore.shared.sorted(.lastCopiedAt).prefix(5)
        if !recent.isEmpty {
            m.addItem(.separator())
            for it in recent {
                let t = Display.title(it, special: false)
                let mi = m.addItem(withTitle: t.count > 50 ? String(t.prefix(49)) + "…" : t,
                                   action: #selector(copyRecent(_:)), keyEquivalent: "")
                mi.representedObject = it.id
            }
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Pause Recording", action: #selector(togglePause), keyEquivalent: "").state = Prefs.ignoreEvents ? .on : .off
        m.addItem(withTitle: "Ignore Next Copy", action: #selector(toggleIgnoreNext), keyEquivalent: "").state = Prefs.ignoreOnlyNextEvent ? .on : .off
        m.addItem(.separator())
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        m.addItem(withTitle: "About ClipStash", action: #selector(about), keyEquivalent: "")
        m.addItem(withTitle: "Quit ClipStash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for mi in m.items where mi.action != #selector(NSApplication.terminate(_:)) { mi.target = self }

        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func showPopup() { popup.show(fromStatusItem: true) }
    @objc private func togglePause() { Prefs.ignoreEvents.toggle() }
    @objc private func toggleIgnoreNext() { Prefs.ignoreOnlyNextEvent.toggle() }
    @objc private func openSettings() { SettingsWindowController.shared.show() }
    @objc private func about() { Actions.about() }
    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let it = HistoryStore.shared.items.first(where: { $0.id == id }) else { return }
        HistoryStore.shared.write([it], plain: Prefs.pasteWithoutFormatting)
    }

    // MARK: URL scheme: clipstash://open | settings | pause | resume

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: s) else { return }
        switch url.host {
        case "open": popup.show()
        case "settings": SettingsWindowController.shared.show()
        case "pause": Prefs.ignoreEvents = true
        case "resume": Prefs.ignoreEvents = false
        default: break
        }
    }

    // MARK: Main menu (invisible for a menu bar app, but makes ⌘C/⌘V/⌘W work in Settings)

    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ClipStash", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ClipStash", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let winItem = NSMenuItem()
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
    }
}

Prefs.registerDefaults()
let app = NSApplication.shared

// One copy at a time: two instances would overwrite each other's history and delete each other's files.
// This runs before anything touches the history store.
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
    .contains(where: { $0.processIdentifier != getpid() }) {
    app.setActivationPolicy(.accessory)
    NSApp.activate()
    let a = NSAlert()
    a.messageText = "ClipStash is already running"
    a.informativeText = "Quit the other copy first: right-click its menu bar icon and choose Quit ClipStash."
    a.runModal()
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
