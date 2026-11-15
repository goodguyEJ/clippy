import AppKit
import SwiftUI
import ServiceManagement
import UniformTypeIdentifiers
import Carbon.HIToolbox

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Clippy Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            StorageTab().tabItem { Label("Storage", systemImage: "externaldrive") }
            AppearanceTab().tabItem { Label("Appearance", systemImage: "paintbrush") }
            PinsTab().tabItem { Label("Pins", systemImage: "pin") }
            IgnoreTab().tabItem { Label("Ignore", systemImage: "nosign") }
            AdvancedTab().tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 620, height: 560)
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.caption).foregroundStyle(.secondary) }
}

// MARK: - General

struct GeneralTab: View {
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var axTrusted = AXIsProcessTrusted()
    @AppStorage(K.searchMode) private var searchMode: SearchMode = .exact
    @AppStorage(K.pasteAutomatically) private var pasteAuto = true
    @AppStorage(K.pasteWithoutFormatting) private var plain = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLaunchAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Caption("Waiting for your approval in System Settings → General → Login Items.")
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(.link)
                    }
                }
                if let loginError { Caption(loginError) }
                LabeledContent("Open Clippy") { HotKeyRecorder() }
            }
            Section("Search") {
                Picker("Search mode", selection: $searchMode) {
                    ForEach(SearchMode.allCases) { Text($0.label).tag($0) }
                }
                Caption("Exact: matches the text you type. Fuzzy: letters in order (\"gml\" finds \"gmail\"). Regex: regular expressions. Mixed: exact, then regex, then fuzzy.")
            }
            Section("Behavior") {
                Toggle("Paste automatically", isOn: $pasteAuto)
                Caption("On: ↩ pastes into the app you were using and ⌥↩ only copies. Off: the reverse.")
                Toggle("Paste without formatting", isOn: $plain)
                Caption("⌥⇧↩ always does the opposite of this setting.")
            }
            Section("Accessibility") {
                LabeledContent("Permission") {
                    HStack(spacing: 6) {
                        Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axTrusted ? .green : .orange)
                        Text(axTrusted ? "Granted" : "Not granted")
                    }
                }
                Button("Open Accessibility Settings…") { Paster.openAccessibilitySettings() }
                Caption("Needed only to paste automatically and to open the popup at the text cursor. After rebuilding Clippy, macOS may ask again.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            axTrusted = AXIsProcessTrusted()
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

// MARK: - Storage

struct StorageTab: View {
    @AppStorage(K.saveText) private var saveText = true
    @AppStorage(K.saveImages) private var saveImages = true
    @AppStorage(K.saveFiles) private var saveFiles = true
    @AppStorage(K.historySize) private var size = 200
    @AppStorage(K.sortBy) private var sortBy: SortBy = .lastCopiedAt
    @AppStorage(K.forgetAfterDays) private var forgetDays = 0
    @State private var draft = 200

    var body: some View {
        Form {
            Section("Save") {
                Toggle("Text (plain and rich)", isOn: $saveText)
                Toggle("Images", isOn: $saveImages)
                Toggle("Files", isOn: $saveFiles)
            }
            Section("History") {
                LabeledContent("Keep") {
                    HStack {
                        TextField("", value: $draft, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .onSubmit { applySize() }
                        Stepper("", value: $draft, in: 1...999).labelsHidden()
                        Text("items")
                        if draft != size {
                            Button("Apply") { applySize() }
                            Button("Cancel") { draft = size }.buttonStyle(.borderless)
                        }
                    }
                }
                Caption("1–999. Pinned items don't count toward this. You'll be asked before anything is removed.")
                Picker("Forget unpinned items after", selection: Binding(get: { forgetDays }, set: { setForgetDays($0) })) {
                    Text("Never").tag(0)
                    Text("1 day").tag(1)
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                }
                Picker("Sort by", selection: $sortBy) {
                    ForEach(SortBy.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Location") {
                Text(HistoryStore.shared.dir.path).font(.caption).textSelection(.enabled)
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.shared.dir]) }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = size }
    }

    private func setForgetDays(_ days: Int) {
        if days > 0 {
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
            let old = HistoryStore.shared.items.filter { !$0.pinned && $0.lastCopiedAt < cutoff }.count
            if old > 0 {
                let a = NSAlert()
                a.messageText = "Remove \(old) item\(old == 1 ? "" : "s") older than \(days) day\(days == 1 ? "" : "s")?"
                a.informativeText = "Pinned items are kept. This can't be undone."
                a.addButton(withTitle: "Remove")
                a.addButton(withTitle: "Cancel")
                a.buttons.first?.hasDestructiveAction = true
                guard a.runModal() == .alertFirstButtonReturn else { return }
            }
        }
        forgetDays = days
    }

    private func applySize() {
        let newSize = min(999, max(1, draft))
        draft = newSize
        guard newSize != size else { return }
        let excess = HistoryStore.shared.unpinnedCount - newSize
        if excess > 0 {
            let a = NSAlert()
            a.messageText = "Remove the \(excess) oldest item\(excess == 1 ? "" : "s")?"
            a.informativeText = "History currently has \(HistoryStore.shared.unpinnedCount) unpinned items. Pinned items are kept. This can't be undone."
            a.addButton(withTitle: "Remove")
            a.addButton(withTitle: "Cancel")
            a.buttons.first?.hasDestructiveAction = true
            guard a.runModal() == .alertFirstButtonReturn else { draft = size; return }
        }
        size = newSize
    }
}

// MARK: - Appearance

struct AppearanceTab: View {
    @AppStorage(K.popupPosition) private var position: PopupPosition = .cursor
    @AppStorage(K.pinPosition) private var pinPosition: PinPosition = .top
    @AppStorage(K.imageHeight) private var imageHeight = 40.0
    @AppStorage(K.previewDelay) private var previewDelay = 1.5
    @AppStorage(K.highlightMatch) private var highlight: HighlightStyle = .bold
    @AppStorage(K.showSpecialSymbols) private var special = false
    @AppStorage(K.showAppIcons) private var appIcons = true
    @AppStorage(K.showSearch) private var showSearch = true
    @AppStorage(K.showTitle) private var showTitle = false
    @AppStorage(K.showFooter) private var showFooter = true
    @AppStorage(K.menuIcon) private var menuIcon: MenuIcon = .list
    @AppStorage(K.showRecentInMenuBar) private var showRecent = false
    @AppStorage(K.hideMenuBarIcon) private var hideIcon = false

    var body: some View {
        Form {
            Section("Popup") {
                Picker("Open popup", selection: $position) {
                    ForEach(PopupPosition.allCases) { Text($0.label).tag($0) }
                }
                if position == .caret { Caption("Uses Accessibility. Falls back to the mouse cursor when an app doesn't report its text cursor.") }
                Picker("Pinned items", selection: $pinPosition) {
                    ForEach(PinPosition.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                LabeledContent("Image height") {
                    HStack { Slider(value: $imageHeight, in: 16...160, step: 4).frame(width: 200); Text("\(Int(imageHeight)) pt").monospacedDigit().frame(width: 50) }
                }
                LabeledContent("Preview delay") {
                    HStack {
                        Slider(value: $previewDelay, in: 0...5, step: 0.25).frame(width: 200)
                        Text(previewDelay == 0 ? "Off" : String(format: "%.2g s", previewDelay)).monospacedDigit().frame(width: 50)
                    }
                }
                Toggle("Show search field", isOn: $showSearch)
                if !showSearch { Caption("Typing still filters the list.") }
                Toggle("Show title", isOn: $showTitle)
                Toggle("Show footer", isOn: $showFooter)
            }
            Section("Rows") {
                Picker("Highlight matches", selection: $highlight) {
                    ForEach(HighlightStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Show special symbols (· for space, ⏎ for newline, ⇥ for tab)", isOn: $special)
                Toggle("Show application icons", isOn: $appIcons)
            }
            Section("Menu bar") {
                Picker("Icon", selection: $menuIcon) {
                    ForEach(MenuIcon.allCases) { Image(systemName: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Show latest copy next to the icon", isOn: $showRecent)
                Toggle("Hide menu bar icon", isOn: $hideIcon)
                if hideIcon { Caption("Use the shortcut to open Clippy. Open the app again from Finder to get back to Settings.") }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pins

struct PinsTab: View {
    @ObservedObject private var store = HistoryStore.shared

    var body: some View {
        let pins = store.items.filter(\.pinned).sorted { ($0.pin ?? "~") < ($1.pin ?? "~") }
        VStack(alignment: .leading, spacing: 8) {
            if pins.isEmpty {
                Spacer()
                Text("No pinned items yet. Select an item in the popup and press ⌥P to pin it.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                HStack(spacing: 8) {
                    Text("Shortcut").frame(width: 80, alignment: .leading)
                    Text("Title").frame(width: 150, alignment: .leading)
                    Text("Content")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                List {
                    ForEach(pins) { PinRow(item: $0) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                Caption("Press ⌥ and the letter in the popup to paste a pin. Editing the content removes its original formatting.")
            }
        }
        .padding()
    }
}

struct PinRow: View {
    let item: ClipItem
    private var store: HistoryStore { HistoryStore.shared }

    var body: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { item.pin ?? "" },
                                          set: { store.setPinLetter(item.id, $0.isEmpty ? nil : $0) })) {
                Text("None").tag("")
                ForEach(HistoryStore.pinLetters, id: \.self) { Text("⌥" + $0.uppercased()).tag($0) }
            }
            .labelsHidden()
            .frame(width: 80)
            TextField("Title", text: Binding(get: { item.title ?? "" }, set: { store.setTitle(item.id, $0) }))
                .frame(width: 150)
            if item.kind == .text {
                TextField("Content", text: Binding(get: { item.text ?? "" }, set: { store.setText(item.id, $0) }), axis: .vertical)
                    .lineLimit(1...3)
            } else {
                Text(item.kind == .image ? "Image" : item.fileNames.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { store.togglePin([item.id]) } label: { Image(systemName: "pin.slash") }
                .buttonStyle(.borderless).help("Unpin")
            Button { store.delete([item.id]) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete")
        }
    }
}

// MARK: - Ignore

struct IgnoreTab: View {
    @State private var section = 0
    @AppStorage(K.ignoreAllAppsExceptListed) private var allowlist = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $section) {
                Text("Applications").tag(0)
                Text("Pasteboard Types").tag(1)
                Text("Regular Expressions").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch section {
            case 0:
                Picker("", selection: $allowlist) {
                    Text("Ignore copies from these apps").tag(false)
                    Text("Only record copies from these apps").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // Separate lists: the ignore list's password-manager defaults must never become an allowlist.
                if allowlist {
                    StringListEditor(key: K.allowedApps, kind: .apps).id(K.allowedApps)
                } else {
                    StringListEditor(key: K.ignoredApps, kind: .apps, defaults: Prefs.defaultIgnoredApps).id(K.ignoredApps)
                }
            case 1:
                Caption("Copies that include any of these pasteboard types are never recorded. Password managers use these to mark private data.")
                StringListEditor(key: K.ignoredTypes, kind: .text("com.example.private-type"), defaults: Prefs.defaultIgnoredTypes)
                    .id(K.ignoredTypes)
            default:
                Caption("Text matching any of these regular expressions is never recorded. For example, \\b\\d{4}([ -]?\\d{4}){3}\\b matches card numbers.")
                StringListEditor(key: K.ignoreRegexes, kind: .text("regular expression")).id(K.ignoreRegexes)
            }
        }
        .padding()
    }
}

struct StringListEditor: View {
    enum Kind { case apps, text(String) }
    let key: String
    let kind: Kind
    var defaults: [String]? = nil

    @State private var values: [String] = []
    @State private var selection: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(values.indices, id: \.self) { i in
                    row(i).tag(i)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                Spacer()
                if let defaults { Button("Restore Defaults") { values = defaults; save() } }
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
        .onAppear { values = Prefs.d.stringArray(forKey: key) ?? [] }
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        switch kind {
        case .apps:
            let bid = values.indices.contains(i) ? values[i] : ""
            HStack(spacing: 6) {
                if let icon = Display.appIcon(bid) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                Text(Display.appName(bid))
                Text(bid).font(.caption).foregroundStyle(.secondary)
            }
        case .text(let placeholder):
            TextField(placeholder, text: Binding(
                get: { values.indices.contains(i) ? values[i] : "" },
                set: { if values.indices.contains(i) { values[i] = $0; save() } }))
            .font(.system(.body, design: .monospaced))
        }
    }

    private func add() {
        switch kind {
        case .apps:
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.application]
            panel.allowsMultipleSelection = true
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                if let bid = Bundle(url: url)?.bundleIdentifier, !values.contains(bid) { values.append(bid) }
            }
        case .text:
            values.append("")
            selection = values.count - 1
        }
        save()
    }

    private func remove() {
        guard let s = selection, values.indices.contains(s) else { return }
        values.remove(at: s)
        selection = nil
        save()
    }

    private func save() {
        Prefs.d.set(values.filter { !$0.isEmpty }, forKey: key)
    }
}

// MARK: - Advanced

struct AdvancedTab: View {
    @AppStorage(K.ignoreEvents) private var paused = false
    @AppStorage(K.clearOnQuit) private var clearOnQuit = false
    @AppStorage(K.clearSystemClipboard) private var clearSystem = false
    @AppStorage(K.clipboardCheckInterval) private var interval = 0.5

    var body: some View {
        Form {
            Section {
                Toggle("Pause recording (ignore all new copies)", isOn: $paused)
                Caption("Shortcut: ⌥-click the menu bar icon. ⌥⇧-click ignores only the next copy.")
                Toggle("Clear history when quitting (keeps pins)", isOn: $clearOnQuit)
                Toggle("Also clear the system clipboard when clearing history", isOn: $clearSystem)
                LabeledContent("Check clipboard every") {
                    HStack {
                        Slider(value: $interval, in: 0.1...2, step: 0.1).frame(width: 200)
                        Text(String(format: "%.1f s", interval)).monospacedDigit().frame(width: 44)
                    }
                }
                Caption("The popup never takes focus from the app you're working in.")
            }
            Section("Scripting") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("defaults write local.personal.clippy ignoreEvents -bool true")
                    Text("defaults write local.personal.clippy ignoreOnlyNextEvent -bool true")
                    Text("defaults write local.personal.clippy historySize -int 500")
                    Text("open clippy://open    (also: settings, pause)")
                }
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
