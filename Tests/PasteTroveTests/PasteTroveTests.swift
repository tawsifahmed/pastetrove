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
    let pasteboard = NSPasteboard(name: .init("pastetrove-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let monitor = Monitor(store: try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)")), pasteboard: pasteboard)
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

@Test func searchIgnoresCaseAndAccents() {
    #expect(Model.fold("Café ÉCLAIR") == "cafe eclair")
    #expect(Model.fold("Crème").contains(Model.fold("CREME")))
    #expect(Model.fold("НТТР/1.1 502").contains(Model.fold("http")))
    #expect(Model.fold("Wi-Fi: BlueDoor-5G").contains(Model.fold("wifi")))
}

@Test func countedNouns() {
    #expect(counted(1, "item") == "1 item")
    #expect(counted(0, "item") == "0 items")
    #expect(counted(17, "line") == "17 lines")
}

@Test func reopensWhereYouLeftOffUntilANewCopy() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
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

@Test func searchFindsImagesByTheirWords() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    let png = Data("not really a png".utf8)
    store.save(Capture(kind: .image, text: "Image 10×10", key: png, reps: [("public.png", png)]), app: nil, limit: 100, imageLimit: 10)
    let id = try #require(store.unreadImages().first)
    let model = Model(store: store)
    model.open()
    model.query = "invoice"
    #expect(model.shown.isEmpty)

    store.setWords(id, "INVOICE #4021\nTotal $13.50")
    model.wordsRead(id)
    #expect(model.shown.map(\.id) == [id] && store.unreadImages().isEmpty)
}

@Test func readsTheWordsInAnImage() throws {
    let image = NSImage(size: NSSize(width: 600, height: 160), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        ("INVOICE 4021 paid" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
        return true
    }
    let png = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
    #expect(ImageText.read(png)?.contains("INVOICE 4021") == true)
}

@Test func aHelperProcessReadsTheWordsAndQuits() async throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    let image = NSImage(size: NSSize(width: 600, height: 160), flipped: false) { rect in
        NSColor.white.setFill()
        rect.fill()
        ("RECEIPT 7788" as NSString).draw(at: NSPoint(x: 30, y: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 40)])
        return true
    }
    let png = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
    store.save(Capture(kind: .image, text: "Image", key: png, reps: [("public.png", png)]), app: nil, limit: 10, imageLimit: 10)
    // The app binary that `swift test` builds next to the tests.
    let binary = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".build/debug/PasteTrove")
    let reader = ImageText(store: store, helper: binary)
    await withCheckedContinuation { done in
        reader.onChange = { id, left in if id != nil, left == 0 { done.resume() } }
        reader.readNew()
    }
    #expect(store.items().first?.words.contains("RECEIPT 7788") == true)
}

@Test func severalPastesJoinNeighbouringText() {
    func item(_ id: Int64, _ kind: Kind) -> Item {
        Item(id: id, kind: kind, style: .plain, text: "\(id)", app: nil, created: 0, pinned: false)
    }
    let groups = Model.pasteGroups([item(1, .image), item(2, .text), item(3, .link), item(4, .image), item(5, .text)])
    #expect(groups.map { $0.map(\.id) } == [[1], [2, 3], [4], [5]])
}

@Test func aDragCarriesEachItemAndJoinsNeighbouringText() throws {
    setenv("PASTETROVE_DATA_DIR", NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)", 1)
    let store = try Store()
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let long = String(repeating: "x", count: 3000)
    for text in [long, "second"] {
        store.save(Capture(kind: .text, text: text, key: Data(text.utf8), reps: [("public.utf8-plain-text", Data(text.utf8))]),
                   app: nil, limit: 100, imageLimit: 10)
    }
    store.save(Capture(kind: .image, text: "Image 1×1", key: png, reps: [("public.png", png)]), app: nil, limit: 100, imageLimit: 10)
    store.save(Capture(kind: .file, text: "/tmp/a.txt", key: Data("f".utf8), reps: [("io.github.tawsifahmed.pastetrove.file-urls", Data("file:///tmp/a.txt".utf8))]),
               app: nil, limit: 100, imageLimit: 10)
    let items = store.items().reversed() as [Item]
    let entries = Monitor(store: store).dragWriters(items)

    #expect(entries.map(\.0.id) == [items[0].id, items[2].id, items[3].id])
    // The full text, not the list's first 2,000 characters.
    #expect((entries[0].1 as? NSPasteboardItem)?.string(forType: .string) == long + "\nsecond")
    #expect((entries[1].1 as? NSPasteboardItem)?.data(forType: .png) == png)
    #expect((entries[2].1 as? NSURL)?.path == "/tmp/a.txt")
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
