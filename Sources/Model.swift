import AppKit
import CryptoKit

extension NSPasteboard.PasteboardType {
    /// Marker added to everything Clippy writes, so the monitor can tell its own writes apart.
    static let clipStashOwn = NSPasteboard.PasteboardType("local.personal.clippy.own")
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
        load()
        gcBlobs()   // drop files left behind by crashes or manual edits (backups are respected)
    }

    var unpinnedCount: Int { items.lazy.filter { !$0.pinned }.count }

    // MARK: Persistence

    /// Decodes one item without failing the whole array.
    private struct Failable: Decodable {
        let item: ClipItem?
        init(from decoder: Decoder) { item = try? ClipItem(from: decoder) }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: file.path) else { migrateV1(); return }
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

    private struct LegacyItem: Decodable {
        var kind: String
        var text: String?
        var imageFile: String?
        var date: Date
        var pinned: Bool?
        var sourceApp: String?
    }

    /// Converts the first version's history.json + images/ folder.
    private func migrateV1() {
        let old = dir.appendingPathComponent("history.json")
        let oldImages = dir.appendingPathComponent("images")
        guard let data = try? Data(contentsOf: old),
              let list = try? JSONDecoder().decode([LegacyItem].self, from: data) else { return }
        var out: [ClipItem] = []
        for l in list {
            var item: ClipItem?
            if l.kind == "text", let t = l.text {
                item = ClipItem(kind: .text, text: t, firstCopiedAt: l.date, lastCopiedAt: l.date,
                                appName: l.sourceApp, key: ClipItem.textKey(t))
            } else if let f = l.imageFile, let png = try? Data(contentsOf: oldImages.appendingPathComponent(f)) {
                let b = putBlob(png)
                item = ClipItem(kind: .image, contents: [ClipContent(type: NSPasteboard.PasteboardType.png.rawValue, blob: b)],
                                firstCopiedAt: l.date, lastCopiedAt: l.date, appName: l.sourceApp, key: "i:" + b)
            }
            guard var it = item else { continue }
            if l.pinned == true { it.pinned = true }
            out.append(it)
        }
        items = out
        for i in items.indices where items[i].pinned { items[i].pin = nextFreeLetter() }
        saveNow(sync: true)
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: oldImages)
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

    func putBlob(_ data: Data) -> String {
        let name = blobName(for: data)
        let url = blobsDir.appendingPathComponent(name)
        let existing = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        if existing != data.count { try? data.write(to: url, options: .atomic) }   // also repairs a truncated file
        return name
    }

    func blobURL(_ name: String) -> URL { blobsDir.appendingPathComponent(name) }
    func blobData(_ name: String) -> Data? { try? Data(contentsOf: blobURL(name)) }

    private func gcBlobs() {
        var used = Set(items.flatMap { $0.contents.map(\.blob) })
        used.formUnion(blobsReferencedByBackups())
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path) else { return }
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(f))
        }
    }

    /// Blobs named in backup history files are kept, so a backup can still be restored by hand.
    private func blobsReferencedByBackups() -> Set<String> {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let re = try? NSRegularExpression(pattern: "[0-9a-f]{32}\\.bin") else { return [] }
        var out = Set<String>()
        for f in files where f.hasPrefix("history-v2.") && f != "history-v2.json" {
            guard let s = try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8) else { continue }
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
        enforceLimit()
        scheduleSave()
    }

    private func storeBlobs(_ blobs: [(type: String, data: Data)]) -> [ClipContent] {
        blobs.map { ClipContent(type: $0.type, blob: putBlob($0.data)) }
    }

    func bump(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].lastCopiedAt = Date()
        items[i].numberOfCopies += 1
        scheduleSave()
    }

    func enforceLimit() {
        let limit = Prefs.historySize
        let unpinned = items.filter { !$0.pinned }.sorted { $0.lastCopiedAt > $1.lastCopiedAt }
        guard unpinned.count > limit else { return }
        let dropped = unpinned[limit...]
        let drop = Set(dropped.map(\.id))
        items.removeAll { drop.contains($0.id) }
        if dropped.contains(where: { !$0.contents.isEmpty }) { gcBlobs() }
        scheduleSave()
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
        let hadBlobs = items.contains { ids.contains($0.id) && !$0.contents.isEmpty }
        items.removeAll { ids.contains($0.id) }
        if hadBlobs { gcBlobs() }
        scheduleSave()
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
        items[i].text = text
        items[i].contents = []          // edited content loses its original formatting
        items[i].key = ClipItem.textKey(text)
        scheduleSave()
    }

    func clear(includePins: Bool) {
        items.removeAll { includePins || !$0.pinned }
        if Prefs.clearSystemClipboard { NSPasteboard.general.clearContents() }
        gcBlobs()
        saveNow()
    }

    // MARK: Writing back to the pasteboard

    func write(_ list: [ClipItem], plain: Bool) {
        guard !list.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        if list.count == 1, let item = list.first {
            lastWrittenID = item.id
            switch item.kind {
            case .file where !plain:
                pb.writeObjects((item.fileURLs ?? []).compactMap { URL(string: $0) } as [NSURL])
            case .image:
                if let b = item.imageBlob, let png = blobData(b) {
                    pb.setData(png, forType: .png)
                    if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
                }
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
            if !plain && list.allSatisfy({ $0.kind == .file }) {
                pb.writeObjects(list.flatMap { ($0.fileURLs ?? []).compactMap { URL(string: $0) } } as [NSURL])
            } else {
                pb.setString(list.map(\.plainString).filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
            }
        }
        pb.setData(Data(), forType: .clipStashOwn)
    }
}
