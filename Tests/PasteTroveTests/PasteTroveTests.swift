import AppKit
import Testing
@testable import PasteTrove

@Test(arguments: [
    ("git status", TextStyle.code),
    ("func greet() {\n    return 1\n}", .code),
    ("# Title\n- one\n- two", .markdown),
    ("#5B4CF2", .color),
    ("rgb(91, 76, 242)", .color),
    ("Weekly sync on Thursday", .plain),
    ("- just one item", .plain),
])
func textStyle(text: String, style: TextStyle) {
    #expect(TextStyle(text) == style)
}

let day = 86400.0
let ages: [(Double, String)] = [
    (30, "now"), (300, "5m"), (3 * 3600, "3h"), (2 * day, "2d"), (8 * day, "1w"), (45 * day, "1mo"), (400 * day, "1y"),
]

@Test(arguments: ages)
func age(seconds: Double, label: String) {
    let item = Item(id: 1, kind: .text, style: .plain, text: "x", app: nil,
                    created: Date().timeIntervalSince1970 - seconds, pinned: false)
    #expect(item.age == label)
}

@Test func links() {
    #expect(Monitor.isLink("https://github.com/tawsifahmed/pastetrove"))
    #expect(Monitor.isLink("  http://example.com/a?b=c \n"))
    #expect(!Monitor.isLink("see https://example.com"))
    #expect(!Monitor.isLink("ftp://example.com"))
    #expect(!Monitor.isLink("example.com"))
}

@Test func otherAppsPrivateFolders() {
    let home = NSHomeDirectory()
    #expect(Cache.isOtherAppData(home + "/Library/Containers/ru.keepcoder.Telegram/Data/tmp/photo.jpg"))
    #expect(Cache.isOtherAppData(home + "/Library/Group Containers/group.com.apple.notes/a.png"))
    #expect(!Cache.isOtherAppData(home + "/Desktop/photo.jpg"))
    #expect(!Cache.isOtherAppData(home + "/Library/Caches/photo.jpg"))
}

@Test func keepsThePictureNotAnotherAppsTempFile() throws {
    setenv("PASTETROVE_DATA_DIR", NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)", 1)
    let pasteboard = NSPasteboard(name: .init("pastetrove-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let monitor = Monitor(store: try Store(), pasteboard: pasteboard)
    let pixel = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let png = try #require(pixel.representation(using: .png, properties: [:]))
    func copy(_ path: String, image: Bool) -> Kind? {
        let entry = NSPasteboardItem()
        entry.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        if image { entry.setData(png, forType: .png) }
        pasteboard.clearContents()
        pasteboard.writeObjects([entry])
        return monitor.read(pasteboard.types?.map(\.rawValue) ?? [])?.kind
    }
    let telegram = NSHomeDirectory() + "/Library/Containers/ru.keepcoder.Telegram/Data/tmp/photo.jpg"
    #expect(copy(telegram, image: true) == .image)
    #expect(copy(telegram, image: false) == .file)
    #expect(copy(NSHomeDirectory() + "/Desktop/photo.jpg", image: true) == .file)
}

@Test func hugeImagesAreSkippedWithoutDecoding() throws {
    setenv("PASTETROVE_DATA_DIR", NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)", 1)
    let pasteboard = NSPasteboard(name: .init("pastetrove-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let monitor = Monitor(store: try Store(), pasteboard: pasteboard)
    func copy(_ data: Data, _ type: NSPasteboard.PasteboardType) -> Capture? {
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        return monitor.read(pasteboard.types?.map(\.rawValue) ?? [])
    }
    let small = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    #expect(copy(try #require(small.representation(using: .png, properties: [:])), .png)?.text == "Image 3×2")
    #expect(copy(try #require(small.tiffRepresentation), .tiff)?.text == "Image 3×2")
    // A PNG header claiming 20,000 × 20,000 pixels (400 megapixels): skipped, never decoded.
    func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let bytes = Array(type.utf8) + body
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        func be(_ n: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: n >> $0) } }
        return be(UInt32(body.count)) + bytes + be(~crc)
    }
    let huge = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        + chunk("IHDR", [0x00, 0x00, 0x4E, 0x20, 0x00, 0x00, 0x4E, 0x20, 8, 6, 0, 0, 0])
        + chunk("IDAT", [0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01]) + chunk("IEND", []))
    #expect(copy(huge, .png) == nil)
}

@Test func searchIgnoresCaseAndAccents() {
    #expect(Model.fold("Café ÉCLAIR") == "cafe eclair")
    #expect(Model.fold("Crème").contains(Model.fold("CREME")))
}

@Test func countedNouns() {
    #expect(counted(1, "item") == "1 item")
    #expect(counted(0, "item") == "0 items")
    #expect(counted(17, "line") == "17 lines")
}

@Test func reopensWhereYouLeftOffUntilANewCopy() throws {
    setenv("PASTETROVE_DATA_DIR", NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)", 1)
    let store = try Store()
    func copy(_ text: String) {
        store.save(Capture(kind: .text, text: text, key: Data(text.utf8), reps: [("public.utf8-plain-text", Data(text.utf8))]),
                   app: nil, limit: 100, imageLimit: 10)
    }
    (1...10).forEach { copy("item \($0)") }
    let model = Model(store: store)

    model.open()
    #expect(model.selected == 0 && model.toTop == 1)
    model.selected = 6
    model.close()

    // Nothing new: same selection, no jump.
    model.open()
    #expect(model.selected == 6 && model.toTop == 1)
    model.close()

    // A new copy while closed: full list, newest first, jump to top.
    copy("item 11")
    model.reload()
    model.open()
    #expect(model.selected == 0 && model.toTop == 2 && model.current?.text == "item 11")

    // A search left on: cleared on the next open, back to the top.
    model.query = "item 3"
    model.close()
    model.open()
    #expect(model.query.isEmpty && model.shown.count == 11 && model.toTop == 3)
}

@Test func severalPastesJoinNeighbouringText() {
    func item(_ id: Int64, _ kind: Kind) -> Item {
        Item(id: id, kind: kind, style: .plain, text: "\(id)", app: nil, created: 0, pinned: false)
    }
    let groups = Model.pasteGroups([item(1, .image), item(2, .text), item(3, .link), item(4, .image), item(5, .text)])
    #expect(groups.map { $0.map(\.id) } == [[1], [2, 3], [4], [5]])
}

@Test func versionOrder() {
    #expect(Updater.isNewer("0.1.4", than: "0.1.3"))
    #expect(Updater.isNewer("0.1.10", than: "0.1.9"))
    #expect(Updater.isNewer("1.0", than: "0.9.9"))
    #expect(Updater.isNewer("0.2", than: "0.1.9"))
    #expect(!Updater.isNewer("0.1.3", than: "0.1.3"))
    #expect(!Updater.isNewer("0.1.3", than: "0.1.4"))
    #expect(!Updater.isNewer("0.1", than: "0.1.0"))
}

@Test func readsAGitHubRelease() throws {
    let json = """
    {"tag_name": "v0.1.4", "body": "## 0.1.4 - 2026-11-26\\n\\n### Fixes\\n- **open:** Shows the `panel`.",
     "html_url": "https://github.com/tawsifahmed/pastetrove/releases/tag/v0.1.4",
     "assets": [
       {"name": "PasteTrove.dmg", "size": 10, "digest": "sha256:aa", "browser_download_url": "https://example.com/PasteTrove.dmg"},
       {"name": "PasteTrove-0.1.4.zip", "size": 20, "digest": null, "browser_download_url": "https://example.com/PasteTrove-0.1.4.zip"}
     ]}
    """
    let release = try JSONDecoder().decode(Release.self, from: Data(json.utf8))
    #expect(release.version == "0.1.4")
    #expect(release.zip?.name == "PasteTrove-0.1.4.zip")
    #expect(release.zip?.digest == nil)
    #expect(Updater.plainNotes(release.notes ?? "") == "Fixes\n• open: Shows the panel.")
}

@Test func aRateLimitReplyIsNotARelease() {
    let json = #"{"message": "API rate limit exceeded", "documentation_url": "https://docs.github.com"}"#
    #expect((try? JSONDecoder().decode(Release.self, from: Data(json.utf8))) == nil)
}
