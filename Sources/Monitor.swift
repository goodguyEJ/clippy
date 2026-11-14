import AppKit

final class ClipboardMonitor {
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    func start() {
        timer?.invalidate()
        let interval = Prefs.checkInterval
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = interval * 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount

        let types = pb.types ?? []
        let store = HistoryStore.shared

        // Our own write: bump the existing item, never create a new one.
        if types.contains(.clipStashOwn) {
            if let id = store.lastWrittenID { store.bump(id) }
            return
        }
        if Prefs.ignoreEvents { return }
        if Prefs.ignoreOnlyNextEvent { Prefs.ignoreOnlyNextEvent = false; return }

        let typeNames = Set(types.map(\.rawValue))
        if !typeNames.isDisjoint(with: Prefs.ignoredTypes) { return }

        let app = NSWorkspace.shared.frontmostApplication
        let bundleID = app?.bundleIdentifier
        let listed = bundleID.map { Prefs.ignoredApps.contains($0) } ?? false
        if Prefs.allowlistMode ? !listed : listed { return }

        func make(_ kind: ClipItem.Kind, key: String) -> ClipItem {
            ClipItem(kind: kind, application: bundleID, appName: app?.localizedName, key: key)
        }

        // Files (Finder also puts the file name on the pasteboard as text, so check files first)
        if typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            guard Prefs.saveFiles else { return }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                let strs = urls.map(\.absoluteString)
                var item = make(.file, key: "f:" + strs.joined(separator: "|"))
                item.fileURLs = strs
                store.record(item)
                return
            }
        }

        // Text, keeping rich representations
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard Prefs.saveText, s.utf8.count < 5_000_000 else { return }
            let range = NSRange(s.startIndex..., in: s)
            if Prefs.ignoreRegexes.contains(where: { $0.firstMatch(in: s, range: range) != nil }) { return }
            var item = make(.text, key: ClipItem.textKey(s))
            item.text = s
            for t in [NSPasteboard.PasteboardType.rtf, .html] where types.contains(t) {
                if let data = pb.data(forType: t), data.count < 10_000_000 {
                    item.contents.append(ClipContent(type: t.rawValue, blob: store.putBlob(data)))
                }
            }
            store.record(item)
            return
        }

        // Images
        guard Prefs.saveImages else { return }
        var png = pb.data(forType: .png)
        if png == nil, let tiff = pb.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        if let png, png.count < 25_000_000 {
            let blob = store.putBlob(png)
            var item = make(.image, key: "i:" + blob)
            item.contents = [ClipContent(type: NSPasteboard.PasteboardType.png.rawValue, blob: blob)]
            store.record(item)
        }
    }
}
