import Foundation
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
