import AppKit
import UniformTypeIdentifiers

/// Small caches so scrolling never hits the disk twice for the same icon, thumbnail or text.
enum Cache {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    /// Files with no thumbnail (not an image, too large, unreadable), so redraws never ask the disk again.
    private static var noThumbnail: Set<String> = []
    /// Decoded thumbnails, bounded by memory; the cost of each is its pixel size.
    private static let images: NSCache<NSString, NSImage> = make(cost: 150 * 1024 * 1024)
    private static let texts: NSCache<NSNumber, NSString> = make(count: 30)
    private static let sizes: NSCache<NSNumber, NSString> = make(count: 30)
    private static let fileIcons: NSCache<NSString, NSImage> = make(count: 300)

    private static func make<Key, Value>(count: Int = 0, cost: Int = 0) -> NSCache<Key, Value> {
        let cache = NSCache<Key, Value>()
        cache.countLimit = count
        cache.totalCostLimit = cost
        return cache
    }

    static func fileIcon(_ path: String) -> NSImage {
        if let hit = fileIcons.object(forKey: path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        fileIcons.setObject(icon, forKey: path as NSString)
        return icon
    }

    private static func cost(_ image: NSImage) -> Int {
        image.representations.first.map { $0.pixelsWide * $0.pixelsHigh * 4 } ?? 0
    }

    static func appIcon(_ bundleID: String?) -> NSImage {
        let key = bundleID ?? ""
        if let hit = icons[key] { return hit }
        let icon = appURL(bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
            ?? NSImage()
        icons[key] = icon
        return icon
    }

    static func appName(_ bundleID: String?) -> String {
        let key = bundleID ?? ""
        if let hit = names[key] { return hit }
        let name = appURL(bundleID).map { FileManager.default.displayName(atPath: $0.path) }?
            .replacingOccurrences(of: ".app", with: "") ?? "Unknown app"
        names[key] = name
        return name
    }

    static func thumbnail(_ item: Item, store: Store, size: Int) -> NSImage? {
        let key = "item-\(item.id)-\(size)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        // Lists read the small thumbnail saved at capture; only the large preview decodes the full image.
        let small = size <= Store.thumbnailSize ? store.data(item.id, type: Store.thumbnailType) : nil
        guard let data = small ?? store.data(item.id, type: NSPasteboard.PasteboardType.png.rawValue),
              let image = scaled(CGImageSourceCreateWithData(data as CFData, nil), size)
        else { return nil }
        images.setObject(image, forKey: key, cost: cost(image))
        return image
    }

    static func fileThumbnail(_ url: URL, size: Int) -> NSImage? {
        let key = "file-\(url.path)-\(size)"
        if let hit = images.object(forKey: key as NSString) { return hit }
        guard !noThumbnail.contains(key) else { return nil }
        // Skip huge files: decoding them would stall the list.
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
              let bytes = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes < 25_000_000,
              let image = scaled(CGImageSourceCreateWithURL(url as CFURL, nil), size)
        else {
            noThumbnail.insert(key)
            return nil
        }
        images.setObject(image, forKey: key as NSString, cost: cost(image))
        return image
    }

    static func fullText(_ item: Item, store: Store) -> String {
        let key = NSNumber(value: item.id)
        if let hit = texts.object(forKey: key) { return hit as String }
        let text = store.data(item.id, type: NSPasteboard.PasteboardType.string.rawValue)
            .flatMap { String(data: $0, encoding: .utf8) }
            .map { String($0.prefix(200_000)) } ?? item.text
        texts.setObject(text as NSString, forKey: key)
        return text
    }

    /// "N chars · N lines", counted once per item instead of on every redraw of the preview.
    static func textSize(_ item: Item, store: Store) -> String {
        let key = NSNumber(value: item.id)
        if let hit = sizes.object(forKey: key) { return hit as String }
        let text = fullText(item, store: store)
        let size = "\(counted(text.count, "char")) · \(counted(text.split(whereSeparator: \.isNewline).count, "line"))"
        sizes.setObject(size as NSString, forKey: key)
        return size
    }

    private static func appURL(_ bundleID: String?) -> URL? {
        bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    static func scaled(_ source: CGImageSource?, _ size: Int) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
