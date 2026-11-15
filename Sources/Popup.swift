import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

// MARK: - Model

struct PopupRow: Identifiable {
    let item: ClipItem
    let shortcut: String?
    var id: UUID { item.id }
}

/// Appearance settings captured when the popup opens.
struct PopupLook {
    let showSearch = Prefs.showSearch
    let showTitle = Prefs.showTitle
    let showAppIcons = Prefs.showAppIcons
    let showFooter = Prefs.showFooter
    let special = Prefs.showSpecialSymbols
    let imageHeight = CGFloat(Prefs.imageHeight)
    let highlight = Prefs.highlight
    let mode = Prefs.searchMode
    let pinsOnTop = Prefs.pinPosition == .top
}

final class PopupModel: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { refresh(resetCursor: true) } } }
    @Published private(set) var rows: [PopupRow] = []
    @Published private(set) var cursor = 0
    @Published private(set) var selection: Set<UUID> = []
    /// A new value even for the same row, so jumping back to an off-screen row still scrolls.
    struct ScrollRequest: Equatable { let id: UUID; let serial: Int }
    @Published var scrollTarget: ScrollRequest?
    private var scrollSerial = 0
    private(set) var numbered: [UUID] = []      // ⌘1–9 targets
    private(set) var dividerAfter: Int?         // index after which the pins/history divider is drawn
    private(set) var regex: NSRegularExpression?
    let look = PopupLook()
    var onCursorChange: ((ClipItem?) -> Void)?

    private var anchor = 0
    private var lowered: [UUID: String] = [:]
    private var loweredShort: [UUID: String] = [:]
    private var lastMouse = NSEvent.mouseLocation
    private var sub: AnyCancellable?

    init() {
        refresh(resetCursor: true)
        sub = HistoryStore.shared.$items.dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh(resetCursor: false) }
    }

    func refresh(resetCursor: Bool) {
        let all = HistoryStore.shared.sorted(Prefs.sortBy)
        let raw = query.trimmingCharacters(in: .whitespaces)
        let q = raw.lowercased()
        // Compile from the text as typed: lowercasing would turn \S into \s, \D into \d, etc.
        regex = (look.mode == .regexp || look.mode == .mixed) && !raw.isEmpty
            ? try? NSRegularExpression(pattern: raw, options: [.caseInsensitive]) : nil
        // A pathological regex the user types must not freeze the popup: once this budget is spent,
        // remaining items skip the regex step.
        let regexBudget = Date().addingTimeInterval(0.25)
        let prevCursorID = rows.indices.contains(cursor) ? rows[cursor].id : nil
        let prevAnchorID = rows.indices.contains(anchor) ? rows[anchor].id : nil

        func filter(_ list: [ClipItem]) -> [ClipItem] {
            guard !q.isEmpty else { return list }
            var scored: [(item: ClipItem, score: Int, order: Int)] = []
            for (i, it) in list.enumerated() {
                let hay: String
                if let cached = lowered[it.id] { hay = cached } else {
                    hay = String(it.searchText.prefix(10_000)).lowercased()
                    lowered[it.id] = hay
                }
                let short: String
                if let cached = loweredShort[it.id] { short = cached } else {
                    short = String(hay.prefix(2_000))
                    loweredShort[it.id] = short
                }
                let re = Date() < regexBudget ? regex : nil
                if let s = Search.score(hay, short, q, mode: look.mode, regex: re) { scored.append((it, s, i)) }
            }
            return scored.sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }.map(\.item)
        }

        let pins = filter(all.filter(\.pinned)).map { PopupRow(item: $0, shortcut: $0.pin.map { "⌥" + $0.uppercased() }) }
        let hist = filter(all.filter { !$0.pinned })
        let histRows = hist.enumerated().map { PopupRow(item: $1, shortcut: $0 < 9 ? "⌘\($0 + 1)" : nil) }
        numbered = hist.prefix(9).map(\.id)
        rows = look.pinsOnTop ? pins + histRows : histRows + pins
        dividerAfter = (!pins.isEmpty && !histRows.isEmpty) ? (look.pinsOnTop ? pins.count - 1 : histRows.count - 1) : nil

        if resetCursor {
            let firstHistory = (look.pinsOnTop && q.isEmpty && !histRows.isEmpty) ? pins.count : 0
            setCursor(firstHistory, extend: false)
        } else {
            // Keep the cursor and selection anchor on the same items after deletes, pins or new copies.
            let ids = Set(rows.map(\.id))
            selection = selection.intersection(ids)
            let last = max(0, rows.count - 1)
            cursor = prevCursorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? min(cursor, last)
            anchor = prevAnchorID.flatMap { id in rows.firstIndex { $0.id == id } } ?? cursor
            if selection.isEmpty, rows.indices.contains(cursor) { selection = [rows[cursor].id] }
            if current?.id != prevCursorID { onCursorChange?(current) }
        }
    }

    var current: ClipItem? { rows.indices.contains(cursor) ? rows[cursor].item : nil }
    var selectedItems: [ClipItem] { rows.filter { selection.contains($0.id) }.map(\.item) }

    func setCursor(_ i: Int, extend: Bool, scroll: Bool = true) {
        guard !rows.isEmpty else { cursor = 0; selection = []; onCursorChange?(nil); return }
        let c = max(0, min(rows.count - 1, i))
        cursor = c
        if extend {
            let a = min(max(anchor, 0), rows.count - 1)
            let lo = min(a, c), hi = max(a, c)
            selection = Set(rows[lo...hi].map(\.id))
        } else {
            anchor = c
            selection = [rows[c].id]
        }
        if scroll {
            scrollSerial += 1
            scrollTarget = ScrollRequest(id: rows[c].id, serial: scrollSerial)
        }
        onCursorChange?(rows[c].item)
    }

    func move(_ delta: Int, extend: Bool) { setCursor(cursor + delta, extend: extend) }

    /// Called when the popup closes: stops refreshing on every copy and frees the search caches.
    func detach() {
        sub = nil
        onCursorChange = nil
        lowered = [:]
        loweredShort = [:]
    }

    /// Follows the mouse only when it actually moved, so rows scrolling under a still
    /// pointer (keyboard navigation, or opening at the cursor) don't steal the selection.
    func hover(_ i: Int) {
        let m = NSEvent.mouseLocation
        guard m != lastMouse else { return }
        lastMouse = m
        guard selection.count <= 1, i != cursor else { return }
        setCursor(i, extend: false, scroll: false)
    }
}

// MARK: - Views

enum FooterAction { case clear, clearAll, settings, about, quit }

struct PopupView: View {
    @ObservedObject var model: PopupModel
    let onClick: (Int, NSEvent.ModifierFlags) -> Void
    let onFooter: (FooterAction) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        let look = model.look
        VStack(spacing: 0) {
            if look.showTitle || look.showSearch || !model.query.isEmpty {
                header(look)
                Divider()
            }
            if model.rows.isEmpty {
                Spacer()
                Text(model.query.isEmpty ? "Nothing copied yet" : "No matches").foregroundStyle(.secondary)
                Spacer()
            } else {
                list(look)
            }
            if look.showFooter {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    private func header(_ look: PopupLook) -> some View {
        HStack(spacing: 8) {
            if look.showTitle {
                Text("ClipStack").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            }
            if look.showSearch {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type to search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
            } else if !model.query.isEmpty {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(model.query).font(.system(size: 14))
            }
            Spacer(minLength: 0)
            if Prefs.ignoreEvents {
                Image(systemName: "pause.circle.fill").foregroundStyle(.orange).help("Recording is paused")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func list(_ look: PopupLook) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { i, row in
                        RowView(row: row, selected: model.selection.contains(row.id), query: model.query, regex: model.regex, look: look)
                            .id(row.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onClick(i, NSEvent.modifierFlags) }
                            .onHover { if $0 { model.hover(i) } }
                        if i == model.dividerAfter { Divider().padding(.vertical, 3) }
                    }
                }
                .padding(5)
            }
            .onChange(of: model.scrollTarget) { _, target in
                if let target { proxy.scrollTo(target.id) }
            }
        }
    }

    private var footer: some View {
        let items: [(String, String, FooterAction)] = [
            ("Clear", "⌥⌘⌫", .clear), ("Clear All", "⌥⇧⌘⌫", .clearAll),
            ("Settings…", "⌘,", .settings), ("About", "", .about), ("Quit", "⌘Q", .quit),
        ]
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                ForEach(items, id: \.0) { t, k, a in
                    Button { onFooter(a) } label: {
                        Text(t) + Text(k.isEmpty ? "" : " " + k).foregroundColor(.secondary)
                    }
                }
            }
            HStack(spacing: 10) {
                ForEach(items, id: \.0) { t, k, a in
                    Button(t) { onFooter(a) }.help(k)
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .lineLimit(1)
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }
}

struct RowView: View {
    let row: PopupRow
    let selected: Bool
    let query: String
    let regex: NSRegularExpression?
    let look: PopupLook

    private var secondary: Color { selected ? .white.opacity(0.75) : .secondary }

    var body: some View {
        let item = row.item
        let title = Display.title(item, special: look.special)
        HStack(spacing: 8) {
            if look.showAppIcons {
                if let icon = Display.appIcon(item.application) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            content(item, title: title)
            Spacer(minLength: 4)
            if item.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(secondary) }
            if let s = row.shortcut { Text(s).font(.system(size: 11)).foregroundStyle(secondary) }
        }
        .font(.system(size: 13))
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Color.accentColor : .clear))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(item, title: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func content(_ item: ClipItem, title: String) -> some View {
        switch item.kind {
        case .image:
            if let b = item.imageBlob {
                Thumbnail(blob: b, maxPixel: Int(look.imageHeight * 4))
                    .frame(maxWidth: 320, maxHeight: look.imageHeight, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            if item.title != nil || item.imageBlob == nil {
                highlighted(title).lineLimit(1)
            }
        case .file:
            Image(systemName: item.fileNames.count > 1 ? "doc.on.doc" : "doc").foregroundStyle(secondary)
            highlighted(title).lineLimit(1).truncationMode(.middle)
        case .text:
            highlighted(title).lineLimit(1).truncationMode(.tail)
        }
    }

    private func highlighted(_ s: String) -> Text {
        var a = AttributedString(s)
        let q = query.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            for r in Search.ranges(in: s, query: q, mode: look.mode, regex: regex) {
                guard let ar = Range(r, in: a) else { continue }
                switch look.highlight {
                case .bold: a[ar].inlinePresentationIntent = .stronglyEmphasized
                case .italic: a[ar].inlinePresentationIntent = .emphasized
                case .underline: a[ar].swiftUI.underlineStyle = .single
                case .color: a[ar].swiftUI.foregroundColor = selected ? .yellow : .orange
                }
            }
        }
        return Text(a)
    }

    private func accessibilityText(_ item: ClipItem, title: String) -> String {
        var parts: [String] = []
        if item.pinned { parts.append("Pinned") }
        switch item.kind {
        case .image: parts.append("Image")
        case .file: parts.append("File: " + title)
        case .text: parts.append(String((item.text ?? "").prefix(200)))
        }
        if let s = row.shortcut { parts.append("Shortcut " + s) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Panel + controller

final class PopupPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

final class PopupController: NSObject, NSWindowDelegate {
    private var panel: PopupPanel?
    private lazy var model = PopupModel()
    private var previousApp: NSRunningApplication?
    private var copyOnly = false
    private let preview = PreviewController()
    var statusItemFrame: () -> NSRect? = { nil }
    var openSettings: () -> Void = {}

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(fromStatusItem: Bool = false) {
        isOpen ? close() : show(fromStatusItem: fromStatusItem)
    }

    /// `copyOnly` is for popups opened by a clipstack:// link, which any app or page can send.
    func show(fromStatusItem: Bool = false, copyOnly: Bool = false) {
        if isOpen { panel?.makeKeyAndOrderFront(nil); return }
        self.copyOnly = copyOnly
        let front = NSWorkspace.shared.frontmostApplication
        // nil means ClipStack itself (e.g. its Settings window) is the paste target.
        previousApp = front?.processIdentifier == getpid() ? nil : front
        if front == nil { self.copyOnly = true }    // no known target, so never send ⌘V blind
        let caret = (!fromStatusItem && Prefs.popupPosition == .caret) ? Caret.rect() : nil

        model = PopupModel()
        let d = Prefs.d
        let size = NSSize(width: max(280, d.double(forKey: K.popupWidth)), height: max(200, d.double(forKey: K.popupHeight)))
        let p = PopupPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { p.standardWindowButton(b)?.isHidden = true }
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.minSize = NSSize(width: 280, height: 200)
        p.backgroundColor = .clear
        p.isOpaque = false
        p.sharingType = .none       // keep clipboard history out of screen shares and recordings
        p.delegate = self

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        let host = NSHostingView(rootView: PopupView(
            model: model,
            onClick: { [weak self] i, flags in self?.click(i, flags) },
            onFooter: { [weak self] a in self?.footer(a) }))
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            host.topAnchor.constraint(equalTo: effect.topAnchor),
            host.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        p.contentView = effect
        p.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        model.onCursorChange = { [weak self, weak p] item in
            guard let self, let p else { return }
            self.preview.schedule(item, parent: p)
        }

        position(p, fromStatusItem: fromStatusItem, caret: caret)
        panel = p
        p.makeKeyAndOrderFront(nil)
        preview.schedule(model.current, parent: p)
    }

    private func position(_ p: NSWindow, fromStatusItem: Bool, caret: NSRect?) {
        let size = p.frame.size
        let mode = fromStatusItem ? PopupPosition.statusItem : Prefs.popupPosition
        let mouse = NSEvent.mouseLocation
        var origin = NSPoint(x: mouse.x - 20, y: mouse.y - size.height + 10)
        var ref = mouse
        let d = Prefs.d

        if mode == .statusItem, let f = statusItemFrame() {
            origin = NSPoint(x: f.minX, y: f.minY - size.height - 4)
            ref = NSPoint(x: f.midX, y: f.minY)
        } else if mode == .caret, let c = caret {
            origin = NSPoint(x: c.minX, y: c.minY - size.height - 4)
            ref = c.origin
        } else if mode == .center {
            let s = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
            if let vf = s?.visibleFrame { origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2) }
        } else if mode == .lastPosition, d.object(forKey: K.popupX) != nil {
            origin = NSPoint(x: d.double(forKey: K.popupX), y: d.double(forKey: K.popupY))
            ref = NSPoint(x: origin.x + 10, y: origin.y + 10)
        }

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(ref, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens.first
        else { return }   // displays can be momentarily absent while they reconfigure
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX + 6), vf.maxX - size.width - 6)
        origin.y = min(max(origin.y, vf.minY + 6), vf.maxY - size.height - 6)
        p.setFrameOrigin(origin)
    }

    func close() {
        guard let p = panel else { return }
        panel = nil
        preview.hide()
        model.detach()
        let f = p.frame
        let d = Prefs.d
        d.set(f.width, forKey: K.popupWidth)
        d.set(f.height, forKey: K.popupHeight)
        d.set(f.minX, forKey: K.popupX)
        d.set(f.minY, forKey: K.popupY)
        p.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Actions

    private func click(_ i: Int, _ flags: NSEvent.ModifierFlags) {
        if flags.contains(.shift) && !flags.contains(.option) {
            model.setCursor(i, extend: true, scroll: false)
            return
        }
        model.setCursor(i, extend: false, scroll: false)
        perform(model.selectedItems, flags: flags)
    }

    /// Return / click. "Paste automatically" sets the default; ⌥ inverts it;
    /// ⌥⇧ always pastes, with the formatting setting inverted.
    private func perform(_ items: [ClipItem], flags: NSEvent.ModifierFlags) {
        guard !items.isEmpty else { return }
        let opt = flags.contains(.option), shift = flags.contains(.shift)
        var paste = Prefs.pasteAutomatically
        var plain = Prefs.pasteWithoutFormatting
        if opt && shift { paste = true; plain.toggle() } else if opt { paste.toggle() }
        if copyOnly { paste = false }
        HistoryStore.shared.write(items, plain: plain)
        let target = previousApp
        close()
        if paste { Paster.paste(into: target) }
    }

    private func footer(_ a: FooterAction) {
        close()
        switch a {
        case .clear: Actions.confirmClear(all: false)
        case .clearAll: Actions.confirmClear(all: true)
        case .settings: openSettings()
        case .about: Actions.about()
        case .quit: NSApp.terminate(nil)
        }
    }

    private static let digitKeys: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
        kVK_ANSI_Keypad1: 1, kVK_ANSI_Keypad2: 2, kVK_ANSI_Keypad3: 3, kVK_ANSI_Keypad4: 4, kVK_ANSI_Keypad5: 5,
        kVK_ANSI_Keypad6: 6, kVK_ANSI_Keypad7: 7, kVK_ANSI_Keypad8: 8, kVK_ANSI_Keypad9: 9,
    ]

    private func handleKey(_ e: NSEvent) -> Bool {
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = f.contains(.command), opt = f.contains(.option), shift = f.contains(.shift), ctrl = f.contains(.control)
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let last = model.rows.count - 1
        // Let an input method (Japanese, Chinese, accents…) finish composing before ↩, ⎋ or arrows act as commands.
        if let tv = panel?.firstResponder as? NSTextView, tv.hasMarkedText() { return false }

        switch Int(e.keyCode) {
        case kVK_DownArrow: cmd ? model.setCursor(last, extend: shift) : model.move(1, extend: shift); return true
        case kVK_UpArrow: cmd ? model.setCursor(0, extend: shift) : model.move(-1, extend: shift); return true
        case kVK_End: model.setCursor(last, extend: shift); return true
        case kVK_Home: model.setCursor(0, extend: shift); return true
        case kVK_PageDown: model.move(8, extend: shift); return true
        case kVK_PageUp: model.move(-8, extend: shift); return true
        case kVK_Escape:
            if !model.query.isEmpty { model.query = "" } else { close() }
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            perform(model.selectedItems, flags: f)
            return true
        case kVK_Delete:
            if opt && cmd { close(); Actions.confirmClear(all: shift); return true }
            if opt { HistoryStore.shared.delete(model.selection); return true }
            if !model.look.showSearch && !cmd {
                if !model.query.isEmpty { model.query.removeLast() }
                return true
            }
            return false
        default: break
        }

        if ctrl && !cmd && !opt {
            switch ch {
            case "n", "j": model.move(1, extend: shift); return true
            case "p", "k": model.move(-1, extend: shift); return true
            default: break
            }
        }

        if opt && !cmd && !ctrl && ch.count == 1 {
            if ch == "p" { HistoryStore.shared.togglePin(model.selectedItems.map(\.id)); return true }
            if let row = model.rows.first(where: { $0.item.pin == ch }) {
                perform([row.item], flags: shift ? [.option, .shift] : [])   // ⌥⇧+letter = paste with formatting inverted
                return true
            }
        }

        if cmd && !ctrl {
            // Physical number keys, so this works on AZERTY and other layouts too.
            if let n = Self.digitKeys[Int(e.keyCode)] {
                if model.numbered.indices.contains(n - 1),
                   let item = model.rows.first(where: { $0.id == model.numbered[n - 1] })?.item {
                    perform([item], flags: f.intersection([.option, .shift]))
                }
                return true
            }
            let edit: [String: Selector] = [
                "a": #selector(NSText.selectAll(_:)), "c": #selector(NSText.copy(_:)),
                "x": #selector(NSText.cut(_:)), "v": #selector(NSText.paste(_:)),
                "z": Selector(("undo:")),
            ]
            switch ch {
            case ",": close(); openSettings(); return true
            case "q": NSApp.terminate(nil); return true
            default:
                if let sel = edit[ch] { _ = panel?.firstResponder?.tryToPerform(sel, with: nil); return true }
            }
        }

        // Search field hidden: still filter as you type.
        if !model.look.showSearch && !cmd && !ctrl, let chars = e.characters, !chars.isEmpty,
           Int(e.keyCode) != kVK_Tab,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            model.query += chars
            return true
        }
        return false
    }
}

// MARK: - Preview

final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class PreviewController {
    private var panel: NSPanel?
    private var work: DispatchWorkItem?

    func schedule(_ item: ClipItem?, parent: NSWindow) {
        hide()
        let delay = Prefs.previewDelay
        guard let item, delay > 0 else { return }
        let w = DispatchWorkItem { [weak self, weak parent] in
            guard let self, let parent, parent.isVisible else { return }
            self.show(item, parent: parent)
        }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func hide() {
        work?.cancel()
        work = nil
        if let p = panel {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        }
        panel = nil
    }

    private func show(_ item: ClipItem, parent: NSWindow) {
        let size = NSSize(width: 400, height: 420)
        let p = NonKeyPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.sharingType = .none
        p.level = parent.level
        p.contentView = NSHostingView(rootView: PreviewView(item: item))
        let pf = parent.frame
        guard let vf = (parent.screen ?? NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        var x = pf.maxX + 6
        if x + size.width > vf.maxX { x = pf.minX - size.width - 6 }
        let y = max(pf.maxY - size.height, vf.minY)
        p.setFrameOrigin(NSPoint(x: x, y: y))
        parent.addChildWindow(p, ordered: .above)
        panel = p
    }
}

struct PreviewView: View {
    let item: ClipItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                switch item.kind {
                case .image:
                    if let b = item.imageBlob {
                        Thumbnail(blob: b, maxPixel: 900, cache: false)   // one preview at a time; not worth cache space
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                case .file:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(item.filePaths, id: \.self) { Label($0, systemImage: "doc").font(.system(size: 12)) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .text:
                    ScrollView {
                        Text(String((item.text ?? "").prefix(30_000)))
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            Divider()
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                if let t = item.title { meta("Title", t) }
                meta("Application", item.appName ?? item.application ?? "Unknown")
                meta("First copied", item.firstCopiedAt.formatted(date: .abbreviated, time: .shortened))
                meta("Last copied", item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened))
                meta("Copies", "\(item.numberOfCopies)")
                if item.isRich { meta("Format", "Rich text") }
            }
            .font(.system(size: 11))
            Text("⌥P \(item.pinned ? "unpin" : "pin")  ·  ⌥⌫ delete  ·  ⌥⇧↩ paste \(Prefs.pasteWithoutFormatting ? "with" : "without") formatting")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 400, height: 420)
        .background(VisualEffect())
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func meta(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).lineLimit(1)
        }
    }
}
