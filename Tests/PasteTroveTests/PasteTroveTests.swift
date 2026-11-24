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
