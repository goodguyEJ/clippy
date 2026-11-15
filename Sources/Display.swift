import AppKit
import SwiftUI
import ImageIO

enum Display {
    static func title(_ item: ClipItem, special: Bool) -> String {
        if let t = item.title, !t.isEmpty { return t }
        switch item.kind {
        case .file: return item.fileNames.joined(separator: ", ")
        case .image: return "Image"
        case .text:
            let raw = String((item.text ?? "").prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
            if special {
                return raw.replacingOccurrences(of: "\r\n", with: "⏎")
                    .replacingOccurrences(of: "\n", with: "⏎")
                    .replacingOccurrences(of: "\t", with: "⇥")
                    .replacingOccurrences(of: " ", with: "·")
            }
            return raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
    }

    static let thumbnailCacheLimit = 32 << 20
    private static let thumbCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = thumbnailCacheLimit   // without a limit NSCache only shrinks under system memory pressure
        return c
    }()

    static func cachedThumbnail(_ blob: String, maxPixel: Int) -> NSImage? {
        thumbCache.object(forKey: "\(blob)@\(maxPixel)" as NSString)
    }

    /// Downsampled image. Thread-safe; `Thumbnail` calls it off the main thread.
    static func thumbnail(_ blob: String, maxPixel: Int, cache: Bool = true) -> NSImage? {
        let key = "\(blob)@\(maxPixel)" as NSString
        if let img = thumbCache.object(forKey: key) { return img }
        let url = HistoryStore.shared.blobURL(blob)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: CGFloat(cg.width) / 2, height: CGFloat(cg.height) / 2))
        if cache { thumbCache.setObject(img, forKey: key, cost: cg.width * cg.height * 4) }
        return img
    }

    private static var iconCache: [String: NSImage?] = [:]   // misses cached too: uninstalled apps would query Launch Services on every render

    static func appIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = iconCache[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
        iconCache[bundleID] = icon
        return icon
    }

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Decodes off the main thread: even a small thumbnail of a full-size screenshot takes ~150 ms to decode.
struct Thumbnail: View {
    let blob: String
    let maxPixel: Int
    var cache = true
    @State private var image: NSImage?

    init(blob: String, maxPixel: Int, cache: Bool = true) {
        self.blob = blob
        self.maxPixel = maxPixel
        self.cache = cache
        _image = State(initialValue: Display.cachedThumbnail(blob, maxPixel: maxPixel))   // cached: no placeholder flash
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
            }
        }
        .task(id: "\(blob)@\(maxPixel)") {
            if let cached = Display.cachedThumbnail(blob, maxPixel: maxPixel) { image = cached; return }
            let (blob, maxPixel, cache) = (blob, maxPixel, cache)
            image = await Task.detached(priority: .userInitiated) { Display.thumbnail(blob, maxPixel: maxPixel, cache: cache) }.value
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

enum Actions {
    static func confirmClear(all: Bool) {
        NSApp.activate()
        let a = NSAlert()
        a.messageText = all ? "Clear all history, including pinned items?" : "Clear clipboard history?"
        a.informativeText = all ? "This can't be undone." : "Pinned items are kept. This can't be undone."
        a.addButton(withTitle: all ? "Clear All" : "Clear")
        a.addButton(withTitle: "Cancel")
        if all { a.buttons.first?.hasDestructiveAction = true }
        if a.runModal() == .alertFirstButtonReturn { HistoryStore.shared.clear(includePins: all) }
    }

    static func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "A lightweight clipboard history for personal use."),
        ])
    }
}
