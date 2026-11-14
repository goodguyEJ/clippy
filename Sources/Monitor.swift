import AppKit

final class ClipboardMonitor {
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?
    private var lastFront = NSWorkspace.shared.frontmostApplication
    private var activatedSincePoll: [NSRunningApplication] = []
    private var observer: NSObjectProtocol?

    init() {
        // Remember every app that comes to the front between polls: any of them could be
        // where a copy happened, even if the user switched away before the next poll.
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.activatedSincePoll.append(app)
            }
        }
    }

    deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

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
        let front = NSWorkspace.shared.frontmostApplication
        let candidates = ([lastFront] + activatedSincePoll + [front]).compactMap { $0 }
        let source = lastFront ?? front      // the app that was in front when this poll window began
        lastFront = front
        activatedSincePoll = []

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

        let typeNames = Set(types.map(\.rawValue))
        if !typeNames.isDisjoint(with: Prefs.ignoredTypes) { return }

        // App rules apply to every app that could have made this copy.
        let listed = Set(Prefs.ignoredApps)
        let ownID = Bundle.main.bundleIdentifier
        let ids = candidates.compactMap(\.bundleIdentifier).filter { $0 != ownID }
        if Prefs.allowlistMode {
            guard !ids.isEmpty, ids.allSatisfy(listed.contains) else { return }
        } else if ids.contains(where: listed.contains) {
            return
        }

        func make(_ kind: ClipItem.Kind, key: String) -> ClipItem {
            ClipItem(kind: kind, application: source?.bundleIdentifier, appName: source?.localizedName, key: key)
        }

        /// "Ignore next copy" is used up only by a copy that would otherwise have been saved.
        func commit(_ item: ClipItem, blobs: [(type: String, data: Data)] = []) {
            if Prefs.ignoreOnlyNextEvent { Prefs.ignoreOnlyNextEvent = false; return }
            store.record(item, blobs: blobs)
        }

        // Files (Finder also puts the file name on the pasteboard as text, so check files first)
        if typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            guard Prefs.saveFiles else { return }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                let strs = urls.map(\.absoluteString)
                var item = make(.file, key: "f:" + strs.joined(separator: "|"))
                item.fileURLs = strs
                commit(item)
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
            var blobs: [(type: String, data: Data)] = []
            for t in [NSPasteboard.PasteboardType.rtf, .html] where types.contains(t) {
                if let data = pb.data(forType: t), data.count < 10_000_000 { blobs.append((t.rawValue, data)) }
            }
            commit(item, blobs: blobs)
            return
        }

        // Images
        guard Prefs.saveImages else { return }
        var png = pb.data(forType: .png)
        if png == nil, let tiff = pb.data(forType: .tiff) {
            png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        if let png, png.count < 25_000_000 {
            commit(make(.image, key: "i:" + store.blobName(for: png)),
                   blobs: [(NSPasteboard.PasteboardType.png.rawValue, png)])
        }
    }
}
