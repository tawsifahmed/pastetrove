import SwiftUI

enum PickMode {
    case paste, plain, copy
}

/// Actions from the panel's gear menu (and ⌘,), carried out by the app.
enum PanelCommand {
    case about, settings, togglePause, updates, clearHistory, quit
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
        didSet { if query != oldValue { selected = 0; apply() } }
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
        store.delete(item.id)
        reload()
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
        let key = Self.fold(item.text)
        searchText[item.id] = key
        return key
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
