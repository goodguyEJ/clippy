import AppKit
import SwiftUI
import ServiceManagement

enum InstallLocation {
    /// Launch at login and permissions are tied to the app's location; a copy run from Downloads, or from the
    /// randomized path macOS uses for apps it quarantined, tends to be moved or deleted later.
    static func isInApplications(_ bundleURL: URL) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }
}

final class WelcomeWindowController: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: WelcomeView { [weak self] in self?.window?.close() }))
            w.title = "Welcome to ClipStack"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { window = nil }
}

struct WelcomeView: View {
    let onDone: () -> Void
    @State private var axTrusted = AXIsProcessTrusted()
    @State private var loginOn = LaunchAtLogin.isOn
    @State private var loginError: String?
    private let inApplications = InstallLocation.isInApplications(Bundle.main.bundleURL)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to ClipStack").font(.title2.bold())
                    Text("Everything you copy, one shortcut away.").foregroundStyle(.secondary)
                }
            }
            step(Prefs.menuIcon.symbol, "ClipStack lives in your menu bar",
                 "Look for this icon at the top of your screen. On a full menu bar it can hide behind the camera notch.")
            let shortcut = HotKeyFormat.string(code: Prefs.hotKeyCode, mods: Prefs.hotKeyMods)
            if HotKeyCenter.shared.registrationFailed {
                step("keyboard", "Choose a shortcut in Settings", Paster.hotkeyFailureMessage(shortcut))
            } else {
                step("keyboard", "Press \(shortcut) to open your history",
                     "Type to search, then ↩ to paste. You can change the shortcut in Settings.")
            }
            VStack(alignment: .leading, spacing: 8) {
                step("hand.tap", "Let ClipStack paste for you (optional)",
                     "With Accessibility permission, ↩ pastes straight into the app you were using. Without it, ClipStack copies the item and you press ⌘V.")
                HStack(spacing: 10) {
                    Label(axTrusted ? "Allowed" : "Not allowed", systemImage: axTrusted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(axTrusted ? .green : .secondary)
                    if !axTrusted { Button("Open Accessibility Settings…") { Paster.openAccessibilitySettings() } }
                }
                .padding(.leading, 34)
            }
            Toggle("Open ClipStack when you log in", isOn: Binding(get: { loginOn }, set: { on in
                loginError = LaunchAtLogin.set(on)
                loginOn = LaunchAtLogin.isOn
            }))
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.secondary) }
            if !inApplications {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Move ClipStack to your Applications folder first, so launch at login and permissions keep working.")
                        .font(.callout)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
                }
            }
            HStack {
                Spacer()
                Button("Get Started", action: onDone).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        // Permission is granted in System Settings, so re-check when the user comes back.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            axTrusted = AXIsProcessTrusted()
            loginOn = LaunchAtLogin.isOn
        }
    }

    private func step(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 22).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
