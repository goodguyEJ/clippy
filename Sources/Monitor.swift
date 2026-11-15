import AppKit

final class ClipboardMonitor {
    private let pb: NSPasteboard
    private var lastChange: Int
    private var timer: Timer?
    private var lastFront = NSWorkspace.shared.frontmostApplication
    private var activatedSincePoll: [NSRunningApplication] = []
    private var observer: NSObjectProtocol?
    private let captureQueue = DispatchQueue(label: "local.personal.clippy.capture", qos: .utility)

    private struct Capture {
        var item: ClipItem
        var blobs: [(type: String, data: Data)] = []
        var imageData: Data?
    }

    init(pasteboard: NSPasteboard = .general) {
        pb = pasteboard
        lastChange = pasteboard.changeCount
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

    func check() {
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
        if types.contains(.clippyOwn) {
            if let id = store.lastWrittenID { store.bump(id) }
            return
        }
        if Prefs.ignoreEvents { return }

        let typeNames = Set(types.map(\.rawValue))
        if !typeNames.isDisjoint(with: Prefs.ignoredTypes) { return }

        // App rules apply to every app that could have made this copy.
        let ownID = Bundle.main.bundleIdentifier
        let ids = candidates.compactMap(\.bundleIdentifier).filter { $0 != ownID }
        if Prefs.allowlistMode {
            let allowed = Set(Prefs.allowedApps)
            guard !ids.isEmpty, ids.allSatisfy(allowed.contains) else { return }
        } else if ids.contains(where: Set(Prefs.ignoredApps).contains) {
            return
        }

        func make(_ kind: ClipItem.Kind, key: String) -> ClipItem {
            ClipItem(kind: kind, application: source?.bundleIdentifier, appName: source?.localizedName, key: key)
        }

        // Files (Finder also puts the file name on the pasteboard as text, so check files first)
        if typeNames.contains(NSPasteboard.PasteboardType.fileURL.rawValue) {
            guard Prefs.saveFiles else { return }
            let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                let strs = urls.map(\.absoluteString)
                var item = make(.file, key: "f:" + strs.joined(separator: "|"))
                item.fileURLs = strs
                enqueue { Capture(item: item) }
                return
            }
        }

        // Text, keeping rich representations
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard Prefs.saveText, s.utf8.count < 5_000_000 else { return }
            var item = make(.text, key: ClipItem.textKey(s))
            item.text = s
            var blobs: [(type: String, data: Data)] = []
            for t in [NSPasteboard.PasteboardType.rtf, .html] where types.contains(t) {
                if let data = pb.data(forType: t), data.count < 10_000_000 { blobs.append((t.rawValue, data)) }
            }
            let regexes = Prefs.ignoreRegexes
            let snapshot = item
            enqueue {
                // User-written patterns are time-limited; a timed-out pattern (nil) counts as a match: when unsure, don't record.
                regexes.contains { Search.firstMatch($0, in: s, timeout: 2) != false } ? nil : Capture(item: snapshot, blobs: blobs)
            }
            return
        }

        // Images
        guard Prefs.saveImages else { return }
        let png = pb.data(forType: .png)
        let tiff = png == nil ? pb.data(forType: .tiff) : nil
        guard png != nil || tiff != nil else { return }
        let base = make(.image, key: "")
        enqueue {
            // Converting, hashing and saving a large screenshot takes hundreds of ms, hence the background queue.
            guard let data = png ?? tiff.flatMap({ NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }),
                  data.count < 25_000_000 else { return nil }
            let name = store.putBlob(data)
            var item = base
            item.key = "i:" + name
            item.contents = [ClipContent(type: NSPasteboard.PasteboardType.png.rawValue, blob: name)]
            return Capture(item: item, imageData: data)
        }
    }

    /// Every copy goes through this one serial queue, even without background work, so copies are
    /// recorded, and "Ignore next copy" is used up, in the order they happened.
    private func enqueue(_ work: @escaping () -> Capture?) {
        let store = HistoryStore.shared
        let clearsBefore = store.clearCount
        // Only a copy made while "Ignore next copy" was on may use it up; one still being processed
        // when it was switched on must not swallow it and let the copy the user meant to hide through.
        let ignoreArmed = Prefs.ignoreOnlyNextEvent
        captureQueue.async {
            guard let capture = work() else { return }
            DispatchQueue.main.async {
                let cleared = store.clearCount != clearsBefore     // a Clear while this ran: the user wanted it gone too
                let ignored = ignoreArmed && Prefs.ignoreOnlyNextEvent
                if cleared || ignored {
                    if ignored && !cleared { Prefs.ignoreOnlyNextEvent = false }
                    store.removeUnusedBlobs(of: [capture.item])    // an image has already written its file
                    return
                }
                if let data = capture.imageData, let name = capture.item.imageBlob { store.keepBlob(name, data: data) }
                store.record(capture.item, blobs: capture.blobs)
            }
        }
    }
}
