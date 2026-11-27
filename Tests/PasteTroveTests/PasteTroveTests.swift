import AppKit
import CryptoKit
import SQLite3
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
    #expect(Cache.isOtherAppData("/private/var/folders/xy/T/TemporaryItems/photo.png"))
    // Lists use only the file type here: no folder-access prompts, no stalls on other disks.
    #expect(Cache.isProtected(home + "/Desktop/photo.jpg") && Cache.isProtected(home + "/Downloads/a.zip"))
    #expect(Cache.isProtected(home + "/Library/Mobile Documents/com~apple~CloudDocs/a.pdf") && Cache.isProtected("/Volumes/Backup/a.mov"))
    #expect(!Cache.isProtected(home + "/Projects/a.swift") && !Cache.isProtected("/private/tmp/a.png"))
}

@Test func aCopiedImageFileKeepsItsThumbnail() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    let pasteboard = NSPasteboard(name: .init("pastetrove-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let monitor = Monitor(store: store, pasteboard: pasteboard)
    let file = URL(fileURLWithPath: "/private/tmp/pastetrove-test-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: file) }
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 30, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    try #require(pixels.representation(using: .png, properties: [:])).write(to: file)
    pasteboard.clearContents()
    pasteboard.writeObjects([file as NSURL])
    let clip = try #require(monitor.read(pasteboard.types?.map(\.rawValue) ?? []))
    #expect(clip.kind == .file && clip.reps.contains { $0.0 == Store.thumbnailType })
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
    #expect(copy("/private/tmp/pastetrove-test-photo.jpg", image: true) == .file)
    #expect(copy("/private/var/folders/xy/T/TemporaryItems/photo.png", image: true) == .image)
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
    #expect((try? JSONDecoder().decode([Release].self, from: Data(json.utf8))) == nil)
}

@Test func anUpdateShowsTheNewsOfEveryVersionSinceYours() throws {
    func release(_ version: String, _ note: String, prerelease: Bool = false) -> String {
        let body = "## \(version)\\n- \(note)"
        return #"{"tag_name": "v"#.appending(version) + #"", "body": ""#.appending(body)
            + #"", "html_url": "https://example.com", "assets": [], "prerelease": "#.appending(String(prerelease)) + "}"
    }
    // Newest first, as GitHub lists them; the test app's own version counts as 0, so all are newer.
    let json = "[\(release("0.1.8", "Eight")), \(release("0.1.8-beta", "Beta", prerelease: true)), \(release("0.1.7", "Seven"))]"
    let newest = try #require(Updater.newest(try JSONDecoder().decode([Release].self, from: Data(json.utf8))))
    #expect(newest.version == "0.1.8")
    #expect(Updater.plainNotes(newest.notes ?? "") == "0.1.8\n• Eight\n\n0.1.7\n• Seven")
    // Kept across restarts as JSON, read back the same.
    let saved = try JSONDecoder().decode(Release.self, from: JSONEncoder().encode(newest))
    #expect(saved.version == "0.1.8" && saved.notes == newest.notes)
}

@Test func theUpdateNoticeNamesWhatIsNew() throws {
    let notes = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        .components(separatedBy: "\n## ").first { $0.hasPrefix("0.1.6") } ?? ""
    #expect(Array(Updater.topics(notes).prefix(4)) == ["search", "paste", "drag", "preview"])
    #expect(Updater.topics("Just a sentence.").isEmpty)
}

@Test func ignoredAppsAndPrivateMarkersAreSkipped() {
    let saved = Settings.ignoredApps
    defer { Settings.ignoredApps = saved }
    Settings.ignoredApps = ["com.example.bank"]
    let text = ["public.utf8-plain-text"]
    #expect(Monitor.skips(text, app: "com.example.bank"))
    #expect(!Monitor.skips(text, app: "com.apple.Notes"))
    #expect(!Monitor.skips(text, app: nil))
    #expect(Monitor.skips(text + ["org.nspasteboard.ConcealedType"], app: "com.apple.Notes"))
}

@Test func shortcutKeysInAppleOrder() {
    #expect(Shortcut.default.keys == ["⇧", "⌘", "V"])
    let all = Shortcut(keyCode: 0, modifiers: 0x1B00, key: "A") // Carbon cmdKey | shiftKey | optionKey | controlKey
    #expect(all.keys == ["⌃", "⌥", "⇧", "⌘", "A"] && all.label == "⌃⌥⇧⌘A")
}

@Test func undoBringsBackADeletedItemAsItWas() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    func copy(_ text: String) {
        store.save(Capture(kind: .text, text: text, key: Data(text.utf8), reps: [("public.utf8-plain-text", Data(text.utf8)), ("public.rtf", Data("rtf".utf8))]),
                   app: "com.apple.Notes", limit: 100, imageLimit: 10)
    }
    copy("keep me")
    copy("delete me")
    let model = Model(store: store)
    model.open()
    let item = try #require(model.shown.first { $0.text == "delete me" })
    store.setPinned(item.id, true)
    model.reload()
    model.delete(model.shown.first { $0.id == item.id })
    #expect(model.undoArmed && model.canUndoDelete && !model.shown.contains { $0.id == item.id })

    model.undoDelete()
    let back = try #require(model.shown.first { $0.id == item.id })
    #expect(back.text == "delete me" && back.pinned && back.app == "com.apple.Notes" && back.created == item.created)
    #expect(store.reps(item.id).count == 2 && model.current?.id == item.id && !model.canUndoDelete)
}

@Test func undoAfterTheSameCopyAgainAddsNoDuplicate() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    func copy(_ text: String) {
        store.save(Capture(kind: .text, text: text, key: Data(text.utf8), reps: [("public.utf8-plain-text", Data(text.utf8))]),
                   app: nil, limit: 100, imageLimit: 10)
    }
    copy("again")
    let model = Model(store: store)
    model.open()
    model.delete(model.shown[0])
    copy("again")
    model.reload()
    model.undoDelete()
    #expect(model.shown.filter { $0.text == "again" }.count == 1)
}

@Test func undoKeepsTheLastTwentyAndStepsAsideForTyping() throws {
    let store = try Store(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)"))
    for i in 1...21 {
        let text = "item \(i)"
        store.save(Capture(kind: .text, text: text, key: Data(text.utf8), reps: [("public.utf8-plain-text", Data(text.utf8))]),
                   app: nil, limit: 100, imageLimit: 10)
    }
    let model = Model(store: store)
    model.open()
    for _ in 1...21 { model.delete(model.shown[0]) }
    #expect(model.shown.isEmpty)
    // Typing in the search field: ⌘Z belongs to the text again.
    model.query = "x"
    #expect(!model.canUndoDelete)
    model.query = ""
    for _ in 1...21 { model.undoDelete() }
    // The very first delete fell out of the 20 kept.
    #expect(model.shown.count == 20 && !model.shown.contains { $0.text == "item 21" })
    model.close()
    #expect(!model.undoArmed)
}

private func tempDir() -> URL { URL(fileURLWithPath: NSTemporaryDirectory() + "pastetrove-test-\(UUID().uuidString)") }

/// Every byte PasteTrove wrote in the folder, database and journal included.
private func diskBytes(_ dir: URL) throws -> Data {
    try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("history.sqlite") }
        .reduce(Data()) { $0 + (try Data(contentsOf: $1)) }
}

@Test func theHistoryIsEncryptedOnDisk() throws {
    let dir = tempDir()
    let store = try Store(directory: dir)
    let secret = "pt-secret-1234"
    store.save(Capture(kind: .text, text: secret, key: Data(secret.utf8), reps: [("public.utf8-plain-text", Data(secret.utf8))]),
               app: nil, limit: 100, imageLimit: 10)
    let png = Data("pt-image-bytes".utf8)
    store.save(Capture(kind: .image, text: "Image 1×1", key: png, reps: [("public.png", png)]), app: nil, limit: 100, imageLimit: 10)
    let image = try #require(store.items().first { $0.kind == .image })
    store.setWords(image.id, "pt-words-5678")

    let items = store.items()
    #expect(items.contains { $0.text == secret } && items.contains { $0.words == "pt-words-5678" })
    #expect(store.data(image.id, type: "public.png") == png)
    let disk = try diskBytes(dir)
    for marker in [secret, "pt-image-bytes", "pt-words-5678"] { #expect(disk.range(of: Data(marker.utf8)) == nil) }
    // Copying the same thing again still finds the one item.
    store.save(Capture(kind: .text, text: secret, key: Data(secret.utf8), reps: [("public.utf8-plain-text", Data(secret.utf8))]),
               app: nil, limit: 100, imageLimit: 10)
    #expect(store.items().filter { $0.text == secret }.count == 1)
}

@Test func anOlderPlainHistoryIsEncryptedOnce() throws {
    let dir = tempDir()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(dir.appendingPathComponent("history.sqlite").path, &db)
    sqlite3_exec(db, """
        PRAGMA journal_mode = WAL;
        CREATE TABLE items (id INTEGER PRIMARY KEY, hash TEXT NOT NULL UNIQUE, kind INTEGER NOT NULL, text TEXT NOT NULL,
                            app TEXT, created REAL NOT NULL, pinned INTEGER NOT NULL DEFAULT 0, words TEXT, style INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE reps (item_id INTEGER NOT NULL REFERENCES items(id) ON DELETE CASCADE, type TEXT NOT NULL, data BLOB NOT NULL,
                           PRIMARY KEY (item_id, type));
        INSERT INTO items (id, hash, kind, text, created) VALUES (1, '\(SHA256.hash(data: Data([0]) + Data("pt-old-secret".utf8)).map { String(format: "%02x", $0) }.joined())', 0, 'pt-old-secret', 1);
        INSERT INTO reps VALUES (1, 'public.utf8-plain-text', CAST('pt-old-secret' AS BLOB));
        """, nil, nil, nil)
    sqlite3_close(db)

    let store = try Store(directory: dir)
    #expect(store.items().map(\.text) == ["pt-old-secret"] && store.data(1, type: "public.utf8-plain-text") == Data("pt-old-secret".utf8))
    #expect(try diskBytes(dir).range(of: Data("pt-old-secret".utf8)) == nil)
    // The old duplicate check carries over: the same copy again finds the same item.
    store.save(Capture(kind: .text, text: "pt-old-secret", key: Data("pt-old-secret".utf8), reps: [("public.utf8-plain-text", Data("pt-old-secret".utf8))]),
               app: nil, limit: 100, imageLimit: 10)
    #expect(store.items().count == 1)
}

@Test func aMissingKeyNeverTurnsTheHistoryIntoNoise() throws {
    let dir = tempDir()
    let store = try Store(directory: dir)
    store.save(Capture(kind: .text, text: "kept", key: Data("kept".utf8), reps: [("public.utf8-plain-text", Data("kept".utf8))]),
               app: nil, limit: 100, imageLimit: 10)
    // The key is only yours and never in a backup, so a backed-up history can't be read.
    let keyFile = dir.appendingPathComponent("history.key")
    #expect(try keyFile.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    #expect((try FileManager.default.attributesOfItem(atPath: keyFile.path)[.posixPermissions] as? Int) == 0o600)
    // Another key reads nothing and does not crash.
    #expect(try Store(directory: dir, key: SymmetricKey(size: .bits256)).items().isEmpty)
    // No key at all: refuse to open instead of making a new key.
    try FileManager.default.removeItem(at: dir.appendingPathComponent("history.key"))
    #expect(throws: (any Error).self) { try Store(directory: dir) }
}
