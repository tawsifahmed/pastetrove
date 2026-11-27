import SwiftUI

enum PickMode {
    case paste, plain, copy
}

/// Actions from the panel's gear menu (and ⌘,), carried out by the app.
enum PanelCommand {
    case about, settings, togglePause, feedback, updates, clearHistory, quit
}

enum Layout: String, CaseIterable {
    case plain, rich, grid

    var title: String {
        switch self {
        case .plain: "Plain List"
        case .rich: "Rich List"
        case .grid: "Grid View"
        }
    }

    var symbol: String {
        switch self {
        case .plain: "list.bullet"
        case .rich: "list.bullet.rectangle"
        case .grid: "square.grid.2x2"
        }
    }

    var cornerRadius: CGFloat {
        switch self {
        case .plain: 7
        case .rich: 9
        case .grid: 10
        }
    }
}

enum Filter: CaseIterable {
    case all, text, code, links, images, files, pinned

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .code: "Code"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }

    func matches(_ item: Item) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text && item.style != .code
        case .code: item.kind == .text && item.style == .code
        case .links: item.kind == .link
        case .images: item.kind == .image
        case .files: item.kind == .file
        case .pinned: item.pinned
        }
    }
}

final class Model: ObservableObject {
    let store: Store
    @Published private(set) var shown: [Item] = []
    @Published var selected = 0
    @Published var query = "" {
        didSet { if query != oldValue { selected = 0; undoArmed = false; apply() } }
    }
    @Published var filter = Filter.all {
        didSet { if filter != oldValue { selected = 0; apply() } }
    }
    @Published var layout = Settings.layout {
        didSet { Settings.layout = layout }
    }
    /// Counts opens, to focus the search field.
    @Published private(set) var opened = 0
    /// Counts jumps back to the top of the list.
    @Published private(set) var toTop = 0
    /// ⌘1–9 badges show only while ⌘ is held, numbered from the first visible item.
    @Published var paused = false
    /// A newer version waiting to be installed, shown in the gear menu.
    @Published var updateVersion: String?
    /// Grid View columns; more fit as the panel gets wider.
    @Published var gridColumns = 2
    @Published var commandHeld = false
    @Published var firstVisible = 0
    /// Items tapped with ⌘ + number while "Paste several at once" is on, in tap order.
    @Published var queue: [Item] = []
    /// Deleted items, newest last, for ⌘Z. In memory only, so they are gone when PasteTrove quits.
    private var trash: [Store.Deleted] = []
    /// A delete just happened: the footer offers ⌘Z. Typing in the search field or closing the panel ends it.
    @Published private(set) var undoArmed = false
    /// The item just copied with ⌘C, highlighted for a moment.
    @Published private(set) var flashID: Int64?
    private var all: [Item] = []
    /// While the panel is closed, new copies only mark the list stale; it is read again when the panel opens.
    private var isOpen = false
    private var stale = true
    /// Folded item text for search, made on the first search and kept per item.
    private var searchText: [Int64: String] = [:]

    init(store: Store) {
        self.store = store
    }

    var current: Item? {
        shown.indices.contains(selected) ? shown[selected] : nil
    }

    /// Items per row, for ↑ ↓ to move one row.
    var columns: Int { layout == .grid ? gridColumns : 1 }

    /// Keeps the same item selected when a new copy arrives while the panel is open.
    /// Images still waiting for their words; while searching, results can still grow.
    @Published var reading = 0

    /// An image's words were just read: search it again, now with them.
    func wordsRead(_ id: Int64) {
        searchText[id] = nil
        if query.isEmpty { stale = true } else { reload() }
    }

    func reload() {
        guard isOpen else {
            stale = true
            return
        }
        let keep = current?.id
        load()
        apply()
        if let keep, let index = shown.firstIndex(where: { $0.id == keep }) { selected = index }
    }

    /// The panel opens where you left off. After a new copy, or if a search or filter was on,
    /// it opens on the full list at the top with the newest item selected.
    func open() {
        isOpen = true
        opened += 1
        guard stale || !query.isEmpty || filter != .all else { return }
        if stale { load() }
        filter = .all
        query = ""
        apply()
        selected = 0
        toTop += 1
    }

    func close() {
        isOpen = false
        undoArmed = false
        queue = []
    }

    /// Adds the item, or takes it out if it is already queued.
    func toggleQueued(_ item: Item) {
        if let index = queue.firstIndex(where: { $0.id == item.id }) { queue.remove(at: index) } else { queue.append(item) }
    }

    /// One paste per group: text next to text joins into one, so a chat box never gets a ⏎ between them.
    static func pasteGroups(_ items: [Item]) -> [[Item]] {
        var groups: [[Item]] = []
        for item in items {
            if item.isText, groups.last?.last?.isText == true { groups[groups.count - 1].append(item) } else { groups.append([item]) }
        }
        return groups
    }

    private func load() {
        all = store.items()
        stale = false
        let ids = Set(all.map(\.id))
        searchText = searchText.filter { ids.contains($0.key) }
    }

    func move(_ step: Int) {
        guard !shown.isEmpty else { return }
        selected = max(0, min(shown.count - 1, selected + step))
    }

    func cycleFilter(_ step: Int) {
        let cases = Filter.allCases
        let index = cases.firstIndex(of: filter) ?? 0
        filter = cases[(index + step + cases.count) % cases.count]
    }

    func cycleLayout() {
        let cases = Layout.allCases
        layout = cases[((cases.firstIndex(of: layout) ?? 0) + 1) % cases.count]
    }

    func flash(_ item: Item) {
        flashID = item.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.flashID == item.id { self?.flashID = nil }
        }
    }

    func select(_ item: Item) {
        selected = shown.firstIndex { $0.id == item.id } ?? selected
    }

    func delete(_ item: Item? = nil) {
        guard let item = item ?? current else { return }
        if let deleted = store.snapshot(item.id) {
            trash.append(deleted)
            // The last 20 deletes, at most 100 MB.
            while trash.count > 20 || trash.reduce(0, { $0 + $1.bytes }) > 100_000_000 { trash.removeFirst() }
        }
        store.delete(item.id)
        queue.removeAll { $0.id == item.id }
        undoArmed = true
        reload()
    }

    /// ⌘Z right after a delete, or with an empty search field; otherwise ⌘Z undoes typing in the search field.
    var canUndoDelete: Bool { !trash.isEmpty && (undoArmed || query.isEmpty) }

    func undoDelete() {
        guard let deleted = trash.popLast() else { return }
        if store.restore(deleted) {
            reload()
            if let id = deleted.row.first as? Int64 { selected = shown.firstIndex { $0.id == id } ?? selected }
        }
        undoArmed = !trash.isEmpty
    }

    func togglePin(_ item: Item? = nil) {
        guard let item = item ?? current else { return }
        store.setPinned(item.id, !item.pinned)
        reload()
        select(item)
    }

    /// In-memory search: every word must appear, case and accents ignored.
    /// Text is folded once per item, so each key press is a plain literal search.
    private func apply() {
        let terms = query.split(separator: " ").map { Self.fold(String($0)) }
        shown = all.filter { item in
            filter.matches(item) && terms.allSatisfy { searchKey(item).range(of: $0, options: .literal) != nil }
        }
        selected = min(selected, max(shown.count - 1, 0))
    }

    private func searchKey(_ item: Item) -> String {
        if let hit = searchText[item.id] { return hit }
        let key = Self.fold(item.words.isEmpty ? item.text : item.text + "\n" + item.words)
        searchText[item.id] = key
        return key
    }

    static func fold(_ text: String) -> String {
        // Hyphens are dropped, so "wifi" finds "Wi-Fi" and "email" finds "e-mail".
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).compactMap { $0 == "-" ? nil : lookalikes[$0] ?? $0 })
    }

    /// Text read from images sometimes comes back with Cyrillic or Greek letters that look Latin ("НТТР"),
    /// so both sides of a search treat them as their Latin twins.
    private static let lookalikes: [Character: Character] = [
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o", "р": "p", "с": "c", "т": "t", "у": "y", "х": "x",
        "α": "a", "ε": "e", "ι": "i", "κ": "k", "ν": "v", "ο": "o", "ρ": "p", "τ": "t", "υ": "u", "χ": "x",
    ]
}
