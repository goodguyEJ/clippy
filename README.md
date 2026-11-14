# Clippy

A lightweight, keyboard-first clipboard history for macOS. It lives in the menu bar, records what you copy, and brings it back with one shortcut.

Personal project. Not affiliated with Microsoft.

## Features

- **Records text (plain and rich), images and files.** Copying the same thing again moves it to the top and counts the copy instead of adding a duplicate.
- **Popup on ⇧⌘V** (changeable) with type-to-search: Exact, Fuzzy, Regex or Mixed, with matches highlighted.
- **Paste straight into the app you were using**, with or without formatting.
- **Pins** with ⌥+letter shortcuts and custom titles. Pins never expire and survive Clear.
- **Preview** of full text or image, the source app, when it was copied and how often.
- **Privacy:**
  - skips password-manager content
  - ignore lists for apps (or record only listed apps), pasteboard types and regex patterns
  - pause, or ignore just the next copy
  - everything stays on your Mac
- **Settings window** for behavior, storage, appearance, pins, ignore rules and advanced options.
- Small: about 2,500 lines of Swift, no dependencies, roughly 70 MB of memory and 0% CPU at idle.

## Requirements

- macOS 14 Sonoma or later
- Xcode or the Command Line Tools (`xcode-select --install`). The full Xcode app isn't needed.

## Build and run

```bash
./build.sh
open build/Clippy.app
```

`build.sh` compiles `Sources/*.swift` with `swiftc`, assembles `build/Clippy.app` and signs it ad hoc for local use. To keep it, move `Clippy.app` to `/Applications`.

## Keyboard shortcuts

| In the popup | Action |
|---|---|
| Type | Search |
| ↑ ↓ (⌃P ⌃N, ⌃K ⌃J) | Move. Add ⇧ to select several |
| ⌘↑ ⌘↓, Home End | First / last |
| ↩ or click | Paste into the previous app (copy only if "Paste automatically" is off) |
| ⌥↩ | The opposite of ↩ |
| ⌥⇧↩ | Paste with the formatting setting inverted |
| ⌘1 … ⌘9 | Pick one of the first nine items |
| ⌥ + letter | Paste that pin |
| ⌥P | Pin / unpin |
| ⌥⌫ | Delete |
| ⌥⌘⌫ / ⌥⇧⌘⌫ | Clear history / clear everything, including pins (both ask first) |
| ⌘, | Settings |
| ⎋ | Clear search, then close |

| Menu bar icon | Action |
|---|---|
| Click | Open the popup |
| ⌥-click | Pause / resume recording |
| ⌥⇧-click | Ignore the next copy |
| Right-click | Menu |

## Permissions

**Accessibility** is needed only to paste automatically (Clippy presses ⌘V for you) and to open the popup at the text cursor. Without it, Clippy copies the item and you press ⌘V yourself. Turn it on in System Settings → Privacy & Security → Accessibility.

Because the app is signed ad hoc, macOS treats each rebuild as a new app, so you may need to turn the permission on again after rebuilding.

## Data and privacy

- History is stored in `~/Library/Application Support/Clippy/`: a JSON file plus a `blobs/` folder for images and rich text.
- If the history file is ever unreadable, it's kept as a dated backup instead of being overwritten.
- Clippy makes no network connections.

## Scripting

```bash
defaults write local.personal.clippy ignoreEvents -bool true          # pause recording
defaults write local.personal.clippy ignoreOnlyNextEvent -bool true   # skip the next copy
defaults write local.personal.clippy historySize -int 500
open clippy://open        # also: settings, pause, resume
```

## Project layout

| File | Contents |
|---|---|
| `Sources/main.swift` | App delegate, menu bar icon, URL scheme |
| `Sources/Monitor.swift` | Clipboard polling and ignore rules |
| `Sources/Model.swift` | History store, persistence, writing back to the clipboard |
| `Sources/Popup.swift` | Popup panel, list, keyboard handling, preview |
| `Sources/Search.swift` | Exact, fuzzy and regex matching |
| `Sources/Keys.swift` | Global shortcut, shortcut recorder, paste, text-cursor lookup |
| `Sources/SettingsWindow.swift` | Settings tabs |
| `Sources/Prefs.swift`, `Sources/Display.swift` | Preferences and display helpers |
