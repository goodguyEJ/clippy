import AppKit
import SwiftUI
import Carbon.HIToolbox

// MARK: - Keyboard layout helpers

enum KeyLayout {
    /// The character a key code produces in the current (ASCII-capable) keyboard layout.
    static func character(for keyCode: Int) -> String? {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &dead, 4, &len, &chars)
            guard status == noErr, len > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: len)
        }
    }

    /// The key code that types `char` in the current layout (e.g. "v" on Dvorak is not kVK_ANSI_V).
    static func keyCode(for char: String) -> Int? {
        (0..<128).first { character(for: $0)?.lowercased() == char }
    }
}

enum HotKeyFormat {
    static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func carbon(_ f: NSEvent.ModifierFlags) -> Int {
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        if f.contains(.shift) { m |= shiftKey }
        return m
    }

    static func string(code: Int, mods: Int) -> String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + keyName(code)
    }

    static func keyName(_ c: Int) -> String {
        if let f = fKeys[c] { return f }
        switch c {
        case kVK_Return: return "↩"
        case kVK_Space: return "Space"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default: return KeyLayout.character(for: c)?.uppercased() ?? "#\(c)"
        }
    }
}

// MARK: - Global hotkey (Carbon, needs no permission)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    var action: (() -> Void)?
    private(set) var registrationFailed = false
    private var ref: EventHotKeyRef?
    private var installed = false
    private var current: (Int, Int)?

    var suspended = false {
        didSet { suspended ? unregister() : registerIfChanged(force: true) }
    }

    func registerIfChanged(force: Bool = false) {
        guard !suspended else { return }
        let want = (Prefs.hotKeyCode, Prefs.hotKeyMods)
        if !force, let c = current, c == want { return }
        installHandler()
        unregister()
        var r: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x434C5059), id: 1) // 'CLPY'
        let status = RegisterEventHotKey(UInt32(want.0), UInt32(want.1), id, GetApplicationEventTarget(), 0, &r)
        registrationFailed = status != noErr
        if !registrationFailed { ref = r; current = want }
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        current = nil
    }

    private func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKeyCenter.shared.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Click, then press the new shortcut. Esc cancels.
struct HotKeyRecorder: View {
    @AppStorage(K.hotKeyCode) private var code = kVK_ANSI_V
    @AppStorage(K.hotKeyMods) private var mods = cmdKey | shiftKey
    @State private var recording = false
    @State private var monitor: Any?
    @State private var failed = false

    var body: some View {
        HStack(spacing: 8) {
            Button(recording ? "Press shortcut…" : HotKeyFormat.string(code: code, mods: mods)) {
                recording ? stop() : start()
            }
            .frame(minWidth: 110)
            if code != kVK_ANSI_V || mods != cmdKey | shiftKey {
                Button("Reset") { code = kVK_ANSI_V; mods = cmdKey | shiftKey; refresh() }
                    .buttonStyle(.borderless)
            }
            if failed { Text("In use by another app").font(.caption).foregroundStyle(.orange) }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        HotKeyCenter.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if Int(e.keyCode) == kVK_Escape { stop(); return nil }
            let m = HotKeyFormat.carbon(e.modifierFlags)
            let isFKey = HotKeyFormat.fKeys[Int(e.keyCode)] != nil
            if m & (cmdKey | controlKey | optionKey) == 0 && !isFKey { NSSound.beep(); return nil }
            code = Int(e.keyCode)
            mods = m
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        refresh()
    }

    private func refresh() {
        DispatchQueue.main.async {
            HotKeyCenter.shared.suspended = false
            failed = HotKeyCenter.shared.registrationFailed
        }
    }
}

// MARK: - Paste simulation (needs Accessibility permission)

enum Paster {
    /// `app` is where the user was before opening the popup; nil means Clippy's own window.
    static func paste(into app: NSRunningApplication?) {
        guard AXIsProcessTrusted() else { askForAccessibility(); return }
        guard let app else {    // Clippy's own Settings window is the target
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { if NSApp.isActive { pressCmdV() } }
            return
        }
        if NSApp.isActive {     // Clippy became active after the popup opened, so focus has to go back first
            NSApp.hide(nil)
            app.activate()
        }
        pasteWhenFrontmost(app, triesLeft: 40)
    }

    /// Waits (up to ~1 s) for `app` to really be in front. Never sends ⌘V to a different app;
    /// if activation doesn't happen, the item simply stays on the clipboard.
    private static func pasteWhenFrontmost(_ app: NSRunningApplication, triesLeft: Int) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { pressCmdV() }
        } else if triesLeft > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { pasteWhenFrontmost(app, triesLeft: triesLeft - 1) }
        }
    }

    static func openAccessibilitySettings() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// One-time explanation; afterwards Clippy quietly falls back to copy-only.
    static func askForAccessibility() {
        guard !Prefs.d.bool(forKey: K.axPromptShown) else { return }
        Prefs.d.set(true, forKey: K.axPromptShown)
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Let Clippy paste for you?"
        a.informativeText = "The item is on your clipboard now, so ⌘V will paste it.\n\nTo paste automatically, turn on Clippy in System Settings → Privacy & Security → Accessibility. Clippy only uses this to press ⌘V and to find the text cursor."
        a.addButton(withTitle: "Open Settings")
        a.addButton(withTitle: "Not Now")
        if a.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
    }

    static func pressCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(KeyLayout.keyCode(for: "v") ?? kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

// MARK: - Text caret location (Accessibility)

enum Caret {
    static func rect() -> NSRect? {
        guard AXIsProcessTrusted() else { return nil }
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID() else { return nil }
        let el = f as! AXUIElement
        var range: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &range) == .success,
              let range else { return nil }
        var bounds: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success,
              let b = bounds, CFGetTypeID(b) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(b as! AXValue, .cgRect, &r), r != .zero else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}
