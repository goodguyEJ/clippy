import AppKit
import CryptoKit

extension NSPasteboard.PasteboardType {
    /// Marker added to everything Clippy writes, so the monitor can tell its own writes apart.
    static let clippyOwn = NSPasteboard.PasteboardType("local.personal.clippy.own")
}

func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// One extra pasteboard representation (RTF, HTML, PNG…) stored as a content-addressed blob file.
struct ClipContent: Codable, Equatable {
    var type: String
    var blob: String
}

struct ClipItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case text, image, file }

    var id = UUID()
    var kind: Kind
    var text: String?             // plain text (text items)
    var fileURLs: [String]?       // file items
    var contents: [ClipContent] = []
    var firstCopiedAt = Date()
    var lastCopiedAt = Date()
    var numberOfCopies = 1
    var pinned = false
    var pin: String?              // letter shortcut (⌥+letter) when pinned
    var title: String?            // custom title for pins
    var application: String?      // source app bundle ID
    var appName: String?
    var key: String               // dedup key

    var fileNames: [String] { (fileURLs ?? []).compactMap { URL(string: $0)?.lastPathComponent } }
    var filePaths: [String] { (fileURLs ?? []).compactMap { URL(string: $0)?.path } }
    var imageBlob: String? { contents.first { $0.type == NSPasteboard.PasteboardType.png.rawValue }?.blob }
    var isRich: Bool { kind == .text && !contents.isEmpty }

    var plainString: String {
        switch kind {
        case .file: filePaths.joined(separator: "\n")
        case .text: text ?? ""
        case .image: ""
        }
    }

    var searchText: String {
        let body = kind == .file ? fileNames.joined(separator: " ") : (text ?? "")
        if let title, !title.isEmpty { return title + " " + body }
        return body
    }

    static func textKey(_ s: String) -> String { "t:" + sha256(Data(s.utf8)) }
}

extension ClipItem {
    /// Tolerant decoding: missing fields fall back to defaults, so adding a field later
    /// never makes an existing history file unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let now = Date()
        self.init(
            id: (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID(),
            kind: try c.decode(Kind.self, forKey: .kind),
            text: try? c.decodeIfPresent(String.self, forKey: .text),
            fileURLs: try? c.decodeIfPresent([String].self, forKey: .fileURLs),
            contents: ((try? c.decodeIfPresent([ClipContent].self, forKey: .contents)) ?? nil) ?? [],
            firstCopiedAt: ((try? c.decodeIfPresent(Date.self, forKey: .firstCopiedAt)) ?? nil) ?? now,
            lastCopiedAt: ((try? c.decodeIfPresent(Date.self, forKey: .lastCopiedAt)) ?? nil) ?? now,
            numberOfCopies: ((try? c.decodeIfPresent(Int.self, forKey: .numberOfCopies)) ?? nil) ?? 1,
            pinned: ((try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? nil) ?? false,
            pin: try? c.decodeIfPresent(String.self, forKey: .pin),
            title: try? c.decodeIfPresent(String.self, forKey: .title),
            application: try? c.decodeIfPresent(String.self, forKey: .application),
            appName: try? c.decodeIfPresent(String.self, forKey: .appName),
            key: ((try? c.decodeIfPresent(String.self, forKey: .key)) ?? nil) ?? "")
        if key.isEmpty {
            switch kind {
            case .text: key = ClipItem.textKey(text ?? "")
            case .file: key = "f:" + (fileURLs ?? []).joined(separator: "|")
            case .image: key = "i:" + (imageBlob ?? id.uuidString)
            }
        }
    }
}

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let pinLetters = "abcdefghijklmnoqrstuvwxyz".map(String.init)   // 'p' is reserved for ⌥P

    @Published private(set) var items: [ClipItem] = []
    var lastWrittenID: UUID?
    private(set) var clearCount = 0
    private var backupBlobs: Set<String> = []       // read once at launch: backups can be large
    private var tiffProviders: [TIFFProvider] = []  // kept alive while their images are on the clipboard

    let dir: URL
    let blobsDir: URL
    private var file: URL { dir.appendingPathComponent("history-v2.json") }
    private var saveWork: DispatchWorkItem?
    private let ioQueue = DispatchQueue(label: "local.personal.clippy.save", qos: .utility)

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("Clippy", isDirectory: true)
        blobsDir = dir.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        protectDataFolder()
        load()
        backupBlobs = blobsReferencedByBackups()
        // "Clear history when quitting" must also hold after a crash or force quit, when quit-time code never ran.
        if Prefs.clearOnQuit {
            items.removeAll { !$0.pinned }
            saveNow(sync: true)
        }
        enforceLimit()
        gcBlobs()   // drop files left behind by crashes or manual edits (backups are respected)
    }

    /// Clipboard history can hold passwords: keep it out of other accounts' reach and out of Time Machine,
    /// where cleared items would otherwise survive in old backups.
    private func protectDataFolder() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = dir
        try? url.setResourceValues(values)
    }

    var unpinnedCount: Int { items.lazy.filter { !$0.pinned }.count }

    // MARK: Persistence

    /// Decodes one item without failing the whole array.
    private struct Failable: Decodable {
        let item: ClipItem?
        init(from decoder: Decoder) { item = try? ClipItem(from: decoder) }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let data = try Data(contentsOf: file)
            let decoded = try JSONDecoder().decode([Failable].self, from: data)
            items = decoded.compactMap(\.item)
            if items.count < decoded.count {
                backupHistoryFile(reason: "partial")
                NSLog("Clippy: \(decoded.count - items.count) history items couldn't be read; original kept as a backup")
            }
        } catch {
            // Never start over silently: keep the original file next to the new one.
            backupHistoryFile(reason: "unreadable")
            NSLog("Clippy: history file couldn't be read (\(error)); original kept as a backup")
        }
    }

    private func backupHistoryFile(reason: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dest = dir.appendingPathComponent("history-v2.\(reason)-\(stamp).json")
        try? FileManager.default.copyItem(at: file, to: dest)
    }

    /// Encodes and writes on a background queue so large histories never stall the UI.
    /// `sync: true` is for quitting, when the write must finish first.
    func saveNow(sync: Bool = false) {
        saveWork?.cancel()
        saveWork = nil
        let snapshot = items
        let target = file
        let job = {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: target, options: .atomic)
        }
        if sync { ioQueue.sync(execute: job) } else { ioQueue.async(execute: job) }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    // MARK: Blobs

    func blobName(for data: Data) -> String { String(sha256(data).prefix(32)) + ".bin" }

    /// Only touches the file system, so the monitor calls it off the main thread for large images.
    func putBlob(_ data: Data) -> String {
        let name = blobName(for: data)
        let url = blobsDir.appendingPathComponent(name)
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if existing != data.count { try? data.write(to: url, options: .atomic) }   // also repairs a truncated file
        return name
    }

    func blobURL(_ name: String) -> URL { blobsDir.appendingPathComponent(name) }
    func blobData(_ name: String) -> Data? { try? Data(contentsOf: blobURL(name)) }

    /// Full scan of the blobs folder; only for launch and Clear. Deletes and evictions use `removeUnusedBlobs`.
    /// Runs on ioQueue, behind any queued `keepBlob` rewrite that would otherwise restore a cleared file.
    private func gcBlobs() {
        var used = Set(items.flatMap { $0.contents.map(\.blob) })
        used.formUnion(backupBlobs)
        let folder = blobsDir
        ioQueue.async {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for f in files where !used.contains(f) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
        }
    }

    private func backupFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasPrefix("history-v2.") && $0 != "history-v2.json" }.map { dir.appendingPathComponent($0) }
    }

    private func deleteBackups() {
        for url in backupFiles() { try? FileManager.default.removeItem(at: url) }
        backupBlobs = []
    }

    /// Deletes the files of removed items that nothing else uses. Queued after a save, so a crash can't
    /// leave the saved history pointing at files that are already gone. Returns whether it saved.
    @discardableResult
    func removeUnusedBlobs(of removed: [ClipItem]) -> Bool {
        var used = Set(items.flatMap { $0.contents.map(\.blob) })
        used.formUnion(backupBlobs)
        let names = Set(removed.flatMap { $0.contents.map(\.blob) }).subtracting(used)
        guard !names.isEmpty else { return false }
        saveNow()
        let folder = blobsDir
        ioQueue.async { for n in names { try? FileManager.default.removeItem(at: folder.appendingPathComponent(n)) } }
        return true
    }

    /// The same content can be recorded again while its file is still queued for deletion, after `putBlob`
    /// already saw the file and skipped writing it. ioQueue is serial, so this check runs after that delete.
    func keepBlob(_ name: String, data: Data) {
        let url = blobURL(name)
        ioQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// Blobs named in backup history files are kept, so a backup can still be restored by hand.
    private func blobsReferencedByBackups() -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "[0-9a-f]{32}\\.bin") else { return [] }
        var out = Set<String>()
        for url in backupFiles() {
            guard let s = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
                if let r = Range(m.range, in: s) { out.insert(String(s[r])) }
            }
        }
        return out
    }

    // MARK: Mutations

    /// `blobs` are extra representations; they're only written to disk when actually stored.
    func record(_ new: ClipItem, blobs: [(type: String, data: Data)] = []) {
        if let i = items.firstIndex(where: { $0.key == new.key }) {
            items[i].lastCopiedAt = Date()
            items[i].numberOfCopies += 1
            if items[i].contents.isEmpty && !blobs.isEmpty { items[i].contents = storeBlobs(blobs) }
        } else {
            var item = new
            if !blobs.isEmpty { item.contents = storeBlobs(blobs) }
            items.append(item)
        }
        if !enforceLimit() { scheduleSave() }
    }

    private func storeBlobs(_ blobs: [(type: String, data: Data)]) -> [ClipContent] {
        blobs.map { blob in
            let name = putBlob(blob.data)
            keepBlob(name, data: blob.data)
            return ClipContent(type: blob.type, blob: name)
        }
    }

    func bump(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastCopiedAt = Date()
        items[i].numberOfCopies += 1
        scheduleSave()
    }

    /// Returns whether it already saved (it does when evicted items had files to delete).
    @discardableResult
    func enforceLimit() -> Bool {
        let limit = Prefs.historySize
        let cutoff = Prefs.forgetAfterDays > 0 ? Date().addingTimeInterval(-Double(Prefs.forgetAfterDays) * 86_400) : .distantPast
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        let dropped = unpinned.enumerated().filter { $0.offset >= limit || $0.element.lastCopiedAt < cutoff }.map(\.element)
        guard !dropped.isEmpty else { return false }
        let drop = Set(dropped.map(\.id))
        items.removeAll { drop.contains($0.id) }
        if removeUnusedBlobs(of: dropped) { return true }
        scheduleSave()
        return false
    }

    func sorted(_ by: SortBy) -> [ClipItem] {
        switch by {
        case .lastCopiedAt: items.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        case .firstCopiedAt: items.sorted { $0.firstCopiedAt > $1.firstCopiedAt }
        case .numberOfCopies: items.sorted {
            $0.numberOfCopies != $1.numberOfCopies ? $0.numberOfCopies > $1.numberOfCopies : $0.lastCopiedAt > $1.lastCopiedAt
        }
        }
    }

    func delete(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        if !removeUnusedBlobs(of: removed) { scheduleSave() }
    }

    /// Pins all given items if any is unpinned; otherwise unpins them all.
    /// An unpinned item counts as just used, so it isn't evicted straight away as the "oldest" item.
    func togglePin(_ ids: [UUID]) {
        let pinning = ids.contains { id in items.first { $0.id == id }?.pinned == false }
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if pinning {
                if !items[i].pinned { items[i].pinned = true; items[i].pin = nextFreeLetter() }
            } else {
                items[i].pinned = false
                items[i].pin = nil
                items[i].title = nil
                items[i].lastCopiedAt = Date()
            }
        }
        scheduleSave()
    }

    func nextFreeLetter() -> String? {
        let used = Set(items.compactMap(\.pin))
        return Self.pinLetters.first { !used.contains($0) }
    }

    func setPinLetter(_ id: UUID, _ letter: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if let letter, let j = items.firstIndex(where: { $0.pin == letter && $0.id != id }) { items[j].pin = nil }
        items[i].pin = letter
        scheduleSave()
    }

    func setTitle(_ id: UUID, _ title: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].title = title.isEmpty ? nil : title
        scheduleSave()
    }

    func setText(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].kind == .text else { return }
        let old = items[i]
        items[i].text = text
        items[i].contents = []          // edited content loses its original formatting
        items[i].key = ClipItem.textKey(text)
        if !removeUnusedBlobs(of: [old]) { scheduleSave() }    // the old formatting still holds the old text
    }

    /// Recovery backups only exist after a history file failed to load and may hold pins that couldn't be read,
    /// so only a Clear the user asks for removes them; the automatic clear-on-quit keeps them.
    func clear(includePins: Bool, deleteRecoveryBackups: Bool = true) {
        clearCount += 1
        items.removeAll { includePins || !$0.pinned }
        if Prefs.clearSystemClipboard { NSPasteboard.general.clearContents() }
        if deleteRecoveryBackups { deleteBackups() }
        saveNow()
        gcBlobs()
    }

    // MARK: Writing back to the pasteboard

    func write(_ list: [ClipItem], plain: Bool, to pb: NSPasteboard = .general) {
        guard !list.isEmpty else { return }
        pb.clearContents()
        tiffProviders = []
        if list.count == 1, let item = list.first {
            lastWrittenID = item.id
            switch item.kind {
            case .file where !plain:
                pb.writeObjects((item.fileURLs ?? []).compactMap { URL(string: $0) } as [NSURL])
            case .image:
                if let b = item.imageBlob, let png = blobData(b) { pb.writeObjects([imagePasteboardItem(png)]) }
            default:
                pb.setString(item.plainString, forType: .string)
                if !plain {
                    for c in item.contents {
                        if let data = blobData(c.blob) { pb.setData(data, forType: .init(c.type)) }
                    }
                }
            }
        } else {
            lastWrittenID = nil
            if list.allSatisfy({ $0.kind == .image }) {
                pb.writeObjects(list.compactMap { $0.imageBlob.flatMap(blobData) }.map(imagePasteboardItem))
            } else if !plain && list.allSatisfy({ $0.kind == .file }) {
                pb.writeObjects(list.flatMap { ($0.fileURLs ?? []).compactMap { URL(string: $0) } } as [NSURL])
            } else {
                pb.setString(list.map(\.plainString).filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
            }
        }
        pb.addTypes([.clippyOwn], owner: nil)
        pb.setData(Data(), forType: .clippyOwn)
    }

    /// PNG right away; TIFF only when an app asks for it, because building a TIFF of a large screenshot
    /// takes a noticeable moment on every paste.
    private func imagePasteboardItem(_ png: Data) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = TIFFProvider(png: png)
        provider.onFinished = { [weak self] done in DispatchQueue.main.async { self?.tiffProviders.removeAll { $0 === done } } }
        tiffProviders.append(provider)
        item.setDataProvider(provider, forTypes: [.tiff])
        return item
    }
}

private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
    let png: Data
    var onFinished: ((TIFFProvider) -> Void)?
    init(png: Data) { self.png = png }
    /// The clipboard moved on, so the image no longer has to stay in memory.
    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) { onFinished?(self) }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { item.setData(tiff, forType: type) }
    }
}
