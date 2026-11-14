import AppKit
import CryptoKit

extension NSPasteboard.PasteboardType {
    /// Marker added to everything ClipStash writes, so the monitor can tell its own writes apart.
    static let clipStashOwn = NSPasteboard.PasteboardType("local.personal.clipstash.own")
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

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let pinLetters = "abcdefghijklmnoqrstuvwxyz".map(String.init)   // 'p' is reserved for ⌥P

    @Published private(set) var items: [ClipItem] = []
    var lastWrittenID: UUID?

    let dir: URL
    let blobsDir: URL
    private var file: URL { dir.appendingPathComponent("history-v2.json") }
    private var saveWork: DispatchWorkItem?

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("ClipStash", isDirectory: true)
        blobsDir = dir.appendingPathComponent("blobs", isDirectory: true)
        try? FileManager.default.createDirectory(at: blobsDir, withIntermediateDirectories: true)
        load()
        gcBlobs()   // drop files left behind by crashes or manual edits
    }

    // MARK: Persistence

    private func load() {
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) {
            items = decoded
            return
        }
        migrateV1()
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
        saveNow()
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.removeItem(at: oldImages)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: file, options: .atomic)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    // MARK: Blobs

    func putBlob(_ data: Data) -> String {
        let name = String(sha256(data).prefix(32)) + ".bin"
        let url = blobsDir.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) { try? data.write(to: url) }
        return name
    }

    func blobURL(_ name: String) -> URL { blobsDir.appendingPathComponent(name) }
    func blobData(_ name: String) -> Data? { try? Data(contentsOf: blobURL(name)) }

    private func gcBlobs() {
        let used = Set(items.flatMap { $0.contents.map(\.blob) })
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobsDir.path) else { return }
        for f in files where !used.contains(f) {
            try? FileManager.default.removeItem(at: blobsDir.appendingPathComponent(f))
        }
    }

    // MARK: Mutations

    func record(_ new: ClipItem) {
        if let i = items.firstIndex(where: { $0.key == new.key }) {
            items[i].lastCopiedAt = Date()
            items[i].numberOfCopies += 1
            if items[i].contents.isEmpty && !new.contents.isEmpty { items[i].contents = new.contents }
        } else {
            items.append(new)
        }
        enforceLimit()
        scheduleSave()
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
        let drop = Set(unpinned[limit...].map(\.id))
        items.removeAll { drop.contains($0.id) }
        gcBlobs()
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
        items.removeAll { ids.contains($0.id) }
        gcBlobs()
        scheduleSave()
    }

    /// Pins all given items if any is unpinned; otherwise unpins them all.
    func togglePin(_ ids: [UUID]) {
        let pinning = ids.contains { id in items.first { $0.id == id }?.pinned == false }
        for id in ids {
            guard let i = items.firstIndex(where: { $0.id == id }) else { continue }
            if pinning {
                if !items[i].pinned { items[i].pinned = true; items[i].pin = nextFreeLetter() }
            } else {
                items[i].pinned = false; items[i].pin = nil; items[i].title = nil
            }
        }
        enforceLimit()
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
