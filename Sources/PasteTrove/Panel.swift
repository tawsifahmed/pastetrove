import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

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
        didSet { selected = 0; apply() }
    }
    @Published var filter = Filter.all {
        didSet { selected = 0; apply() }
    }
    @Published var layout = Settings.layout {
        didSet { Settings.layout = layout }
    }
    @Published private(set) var opened = 0
    /// ⌘1–9 badges show only while ⌘ is held, numbered from the first visible item.
    @Published var paused = false
    /// Grid View columns; more fit as the panel gets wider.
    @Published var gridColumns = 2
    @Published var commandHeld = false
    @Published var firstVisible = 0
    /// The item just copied with ⌘C, highlighted for a moment.
    @Published private(set) var flashID: Int64?
    private var all: [Item] = []

    init(store: Store) {
        self.store = store
        reload()
    }

    var current: Item? {
        shown.indices.contains(selected) ? shown[selected] : nil
    }

    /// Items per row, for ↑ ↓ to move one row.
    var columns: Int { layout == .grid ? gridColumns : 1 }

    /// Keeps the same item selected when a new copy arrives while the panel is open.
    func reload() {
        let keep = current?.id
        all = store.items()
        apply()
        if let keep, let index = shown.firstIndex(where: { $0.id == keep }) { selected = index }
    }

    func reset() {
        filter = .all
        query = ""
        opened += 1
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
    private func apply() {
        let terms = query.split(separator: " ")
        shown = all.filter { item in
            filter.matches(item) && terms.allSatisfy {
                item.text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        selected = min(selected, max(shown.count - 1, 0))
    }
}

/// Borderless panels refuse key focus by default; the search field needs it.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The non-activating panel takes the keyboard while the app you came from stays active, so ⌘V lands there.
final class PanelController: NSObject, NSWindowDelegate {
    enum Anchor {
        case below(NSRect), cursor, center
    }

    var onPick: ((Item, PickMode) -> Void)?
    var onCopy: ((Item) -> Void)?
    var onCommand: ((PanelCommand) -> Void)?

    private let model: Model
    private let panel: FloatingPanel
    private let preview: PreviewController
    private var keyMonitor: Any?
    private var hiddenAt = Date.distantPast

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9, kVK_ANSI_0: 10,
    ]

    init(model: Model) {
        self.model = model
        panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: Settings.panelSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        preview = PreviewController(model: model)
        super.init()
        // Drag any edge to resize; the size is remembered.
        panel.minSize = NSSize(width: 340, height: 420)
        panel.maxSize = NSSize(width: 980, height: 2400)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let host = NSHostingView(rootView: PanelView(
            model: model,
            pick: { [weak self] item, mode in self?.pick(item, mode) },
            copy: { [weak self] item in self?.copy(item) },
            command: { [weak self] in self?.run($0) },
            togglePreview: { [weak self] in self?.togglePreview() }
        ))
        host.sizingOptions = []
        panel.contentView = host
    }

    /// `clicked`: a click on the status icon first hides an open panel by taking focus, so it must not reopen it right away.
    func toggle(at anchor: Anchor, clicked: Bool = false) {
        if panel.isVisible {
            hide()
        } else if !clicked || Date().timeIntervalSince(hiddenAt) > 0.3 {
            show(at: anchor)
        }
    }

    func show(at anchor: Anchor) {
        model.reset()
        let point: NSPoint
        if case let .below(rect) = anchor {
            point = NSPoint(x: rect.midX, y: rect.minY)
        } else {
            point = NSEvent.mouseLocation
        }
        guard let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame else { return }
        let saved = Settings.panelSize
        let width = min(saved.width, screen.width - 12)
        let height = min(saved.height, screen.height - 40)
        var frame = NSRect(x: 0, y: 0, width: width, height: height)
        switch anchor {
        case let .below(rect):
            frame.origin = NSPoint(x: rect.midX - width / 2, y: rect.minY - 6 - height)
        case .cursor:
            frame.origin = NSPoint(x: point.x - 24, y: point.y - height + 12)
        case .center:
            frame.origin = NSPoint(x: screen.midX - width / 2, y: screen.midY - height / 2)
        }
        panel.setFrame(Self.clamp(frame, to: screen), display: true)
        updateColumns()
        panel.makeKeyAndOrderFront(nil)
        model.commandHeld = NSEvent.modifierFlags.contains(.command)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                guard let self else { return event }
                if event.type == .flagsChanged {
                    model.commandHeld = event.modifierFlags.contains(.command)
                    return event
                }
                return handle(event) ? nil : event
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        preview.hide()
        panel.orderOut(nil)
        model.commandHeld = false
        hiddenAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    func windowDidResize(_ notification: Notification) {
        updateColumns()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        Settings.panelSize = panel.frame.size
    }

    /// Grid cards stay at least 170 points wide; a wider panel gets more columns.
    private func updateColumns() {
        let columns = max(2, Int((panel.frame.width - 24 + 10) / (170 + 10)))
        if model.gridColumns != columns { model.gridColumns = columns }
    }

    private func pick(_ item: Item, _ mode: PickMode) {
        hide()
        onPick?(item, mode)
    }

    /// Copies without closing the panel, like ⌘C in a list.
    private func copy(_ item: Item) {
        onCopy?(item)
        model.flash(item)
    }

    /// Pausing keeps the panel open; every other command opens a window or quits.
    private func run(_ command: PanelCommand) {
        if command != .togglePause { hide() }
        onCommand?(command)
    }

    func togglePreview() {
        preview.toggle(beside: panel.frame)
    }

    private static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, screen.minX + 6), screen.maxX - frame.width - 6)
        frame.origin.y = min(max(frame.minY, screen.minY + 6), screen.maxY - frame.height)
        return frame
    }

    private func handle(_ event: NSEvent) -> Bool {
        // While an input method composes text in the search field, ⏎, arrows and esc belong to it.
        if (panel.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let noModifiers = flags.intersection([.command, .shift, .control, .option]).isEmpty
        let grid = model.layout == .grid
        let key = Int(event.keyCode)

        switch key {
        case kVK_Escape:
            if model.query.isEmpty { hide() } else { model.query = "" }
            return true
        case kVK_DownArrow:
            model.move(command ? Int(Int32.max) : model.columns)
            return true
        case kVK_UpArrow:
            model.move(command ? -Int(Int32.max) : -model.columns)
            return true
        case kVK_LeftArrow where grid:
            model.move(-1)
            return true
        case kVK_RightArrow where grid:
            model.move(1)
            return true
        case kVK_PageDown:
            model.move(10)
            return true
        case kVK_PageUp:
            model.move(-10)
            return true
        case kVK_Tab:
            model.cycleFilter(shift ? -1 : 1)
            return true
        case kVK_Space where noModifiers && model.query.isEmpty:
            togglePreview()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let item = model.current { pick(item, command ? .copy : shift ? .plain : .paste) }
            return true
        case kVK_Delete where command:
            model.delete()
            return true
        default:
            break
        }

        if flags.contains(.control), key == kVK_ANSI_N || key == kVK_ANSI_P {
            model.move(key == kVK_ANSI_N ? model.columns : -model.columns)
            return true
        }
        guard command else { return false }
        switch key {
        case kVK_ANSI_C:
            // Text selected in the search field copies as usual; otherwise ⌘C copies the selected item.
            if let editor = panel.firstResponder as? NSTextView, editor.selectedRange().length > 0 { return false }
            guard let item = model.current else { return false }
            copy(item)
        case kVK_ANSI_P:
            model.togglePin()
        case kVK_ANSI_L:
            model.cycleLayout()
        case kVK_ANSI_Y:
            togglePreview()
        case kVK_ANSI_Comma:
            run(.settings)
        default:
            guard let number = Self.digits[key] else { return false }
            let index = model.firstVisible + number - 1
            guard model.shown.indices.contains(index) else { return true }
            // Copy and flash first, so you see which item it was, then close and paste.
            let item = model.shown[index]
            model.select(item)
            copy(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                // Skip if the panel closed meanwhile (you switched apps), so the paste never lands elsewhere.
                guard let self, panel.isVisible else { return }
                pick(item, shift ? .plain : .paste)
            }
        }
        return true
    }
}

/// Large preview of the selected item, shown beside the panel. It never takes focus, so typing stays in the search field.
final class PreviewController {
    private let panel: NSPanel

    init(model: Model) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PreviewWindow(model: model))
        host.sizingOptions = []
        panel.contentView = host
    }

    func toggle(beside main: NSRect) {
        if panel.isVisible {
            hide()
            return
        }
        guard let screen = (NSScreen.screens.first { $0.frame.intersects(main) } ?? NSScreen.main)?.visibleFrame else { return }
        let width: CGFloat = 520
        let height = min(main.height, 640)
        let left = main.minX - width - 8
        let x = left >= screen.minX ? left : main.maxX + 8
        panel.setFrame(NSRect(x: x, y: main.maxY - height, width: width, height: height), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }
}

struct PreviewWindow: View {
    @ObservedObject var model: Model

    var body: some View {
        PreviewPane(item: model.current, store: model.store)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    let pick: (Item, PickMode) -> Void
    let copy: (Item) -> Void
    let command: (PanelCommand) -> Void
    let togglePreview: () -> Void
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PanelBackground())
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .onAppear { searchFocused = true }
        .onChange(of: model.opened) { searchFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Type to Search…", text: $model.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                if model.paused {
                    Text("Paused")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .help("Recording is paused. Resume it from the gear menu.")
                }
                gearMenu
            }
            HStack(spacing: 4) {
                ForEach(Filter.allCases, id: \.self) { filter in
                    let active = model.filter == filter
                    Button { model.filter = filter } label: {
                        Text(filter.title)
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(active ? Color.accentColor : Color.primary.opacity(0.07)))
                            .foregroundStyle(active ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
    }

    private static let topAnchor = "list-top"

    private var gearMenu: some View {
        Menu {
            Button("About PasteTrove") { command(.about) }
            Button("Settings…") { command(.settings) }
                .keyboardShortcut(",", modifiers: .command)
            Divider()
            Button(model.paused ? "Resume Recording" : "Pause Recording") { command(.togglePause) }
            Button("Check for Updates…") { command(.updates) }
            Divider()
            Button("Clear History…") { command(.clearHistory) }
            Button("Quit PasteTrove") { command(.quit) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape").font(.system(size: 15))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("Settings and more")
    }

    @ViewBuilder private var content: some View {
        if model.shown.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.on.doc").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "No Clips Yet" : "No Matches").font(.headline).foregroundStyle(.secondary)
                Text(model.query.isEmpty ? "Copied items will appear here." : "Try other words or another filter.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // Scroll target above the padding, so "back to top" keeps the gap above the first row.
                        Color.clear.frame(height: 0).id(Self.topAnchor)
                        Group {
                            if model.layout == .grid {
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: model.gridColumns), spacing: 10) {
                                    cells
                                }
                            } else {
                                LazyVStack(spacing: model.layout == .rich ? 6 : 1) { cells }
                            }
                        }
                        .padding(model.layout == .grid ? 12 : 8)
                    }
                }
                .coordinateSpace(name: "list")
                .onPreferenceChange(FirstVisibleKey.self) { index in
                    let first = index == Int.max ? 0 : index
                    if model.firstVisible != first { model.firstVisible = first }
                }
                .onChange(of: model.opened) {
                    proxy.scrollTo(Self.topAnchor, anchor: .top)
                }
                .onChange(of: model.current?.id) {
                    // The first row (or first grid row) scrolls to the true top, padding included.
                    if model.selected < model.columns {
                        proxy.scrollTo(Self.topAnchor, anchor: .top)
                    } else if let id = model.current?.id {
                        proxy.scrollTo(id)
                    }
                }
            }
        }
    }

    private var cells: some View {
        ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, item in
            cell(item, index)
                .id(item.id)
                // One gesture, so a single click selects at once instead of waiting out the double-click delay.
                .onTapGesture {
                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { pick(item, .paste) } else { model.selected = index }
                }
                .contextMenu { menu(for: item) }
                .onHover { inside in (inside ? NSCursor.pointingHand : NSCursor.arrow).set() }
                .background(GeometryReader { geometry in
                    // Only rendered cells report; the smallest index whose top is in view wins.
                    Color.clear.preference(
                        key: FirstVisibleKey.self,
                        value: geometry.frame(in: .named("list")).minY >= -4 ? index : Int.max
                    )
                })
        }
    }

    @ViewBuilder private func menu(for item: Item) -> some View {
        Button("Paste") { pick(item, .paste) }
        if item.kind == .text || item.kind == .link {
            Button("Paste as Plain Text") { pick(item, .plain) }
        }
        Button("Copy") { copy(item) }
        Divider()
        Button("Preview") {
            model.select(item)
            togglePreview()
        }
        Button(item.pinned ? "Unpin" : "Pin") { model.togglePin(item) }
        if item.kind == .link, let url = URL(string: item.text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            Button("Open Link") { NSWorkspace.shared.open(url) }
        }
        if item.kind == .file {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting(item.paths.map { URL(fileURLWithPath: $0) })
            }
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item) }
    }

    @ViewBuilder private func cell(_ item: Item, _ index: Int) -> some View {
        let selected = index == model.selected
        let offset = index - model.firstVisible
        // ⌘1…⌘9 and ⌘0: the first ten visible items.
        let shortcut = model.commandHeld && (0..<10).contains(offset) ? offset + 1 : nil
        let flashing = model.flashID == item.id
        Group {
            switch model.layout {
            case .plain: PlainRow(item: item, shortcut: shortcut, selected: selected, store: model.store)
            case .rich: RichRow(item: item, shortcut: shortcut, selected: selected, store: model.store)
            case .grid: Card(item: item, shortcut: shortcut, selected: selected, store: model.store)
            }
        }
        .overlay {
            if flashing { CopiedFlash(cornerRadius: model.layout.cornerRadius) }
        }
        .scaleEffect(flashing ? 0.97 : 1)
        // While ⌘ is held, items without a number fade back so 1–9 stand out.
        .opacity(model.commandHeld && shortcut == nil ? 0.4 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.6), value: flashing)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: model.commandHeld)
    }

    private var footer: some View {
        HStack {
            Menu {
                Picker("Layout", selection: $model.layout) {
                    ForEach(Layout.allCases, id: \.self) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: model.layout.symbol)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Layout (⌘L)")
            .frame(width: 60, alignment: .leading)
            Spacer()
            Text("\(model.shown.count) items")
            Spacer()
            Button(action: togglePreview) { Image(systemName: "eye") }
                .buttonStyle(.plain)
                .help("Preview (Space)")
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

/// An image that fills whatever box it is given and is cropped to it, like CSS `object-fit: cover`,
/// so tall and wide images line up at the same size.
struct CoverImage: View {
    let image: NSImage
    let cornerRadius: CGFloat

    var body: some View {
        Color.clear
            .overlay(Image(nsImage: image).resizable().scaledToFill())
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
    }
}

/// Small leading mark for code, Markdown and color items.
struct StyleMark: View {
    let item: Item

    var body: some View {
        switch item.style {
        case .plain:
            EmptyView()
        case .color:
            Circle()
                .fill(Color(nsColor: TextStyle.color(from: item.text) ?? .gray))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2)))
                .frame(width: 12, height: 12)
        case .code, .markdown:
            Image(systemName: item.style.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

extension TextStyle {
    var symbol: String { self == .code ? "chevron.left.forwardslash.chevron.right" : "number" }
}

/// Green outline with a "Copied" label, shown briefly after ⌘C.
struct CopiedFlash: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(Color.green, lineWidth: 2.5)
            .overlay {
                Label("Copied", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
            }
            .transition(.opacity)
    }
}

struct FirstVisibleKey: PreferenceKey {
    static var defaultValue = Int.max

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = min(value, nextValue())
    }
}

/// The item's age, or a glowing ⌘ shortcut pill while ⌘ is held, plus the pin mark.
struct Badge: View {
    let item: Item
    let shortcut: Int?

    var body: some View {
        HStack(spacing: 4) {
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
            if let shortcut {
                Text("⌘\(shortcut % 10)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor))
                    .shadow(color: Color.accentColor.opacity(0.85), radius: 6)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else {
                Text(item.age)
            }
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
}

extension View {
    /// Soft accent glow around the selected item.
    func selectionGlow(_ selected: Bool, radius: CGFloat = 8) -> some View {
        shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: radius)
    }
}

struct PlainRow: View {
    let item: Item
    let shortcut: Int?
    let selected: Bool
    let store: Store

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 26, height: 26)
            content
            Spacer(minLength: 4)
            Badge(item: item, shortcut: shortcut)
        }
        .font(.system(size: 15.5))
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(
            RoundedRectangle(cornerRadius: Layout.plain.cornerRadius, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .selectionGlow(selected, radius: 6)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            StyleMark(item: item)
            Text(item.preview).lineLimit(1).font(item.style == .code ? .system(size: 14, design: .monospaced) : nil)
        case .link:
            Image(systemName: "link").font(.system(size: 13)).foregroundStyle(.blue)
            Text(item.preview).lineLimit(1).truncationMode(.middle)
        case .image:
            if let thumb = Cache.thumbnail(item, store: store, size: 240) {
                CoverImage(image: thumb, cornerRadius: 8)
                    .frame(width: 60, height: 40)
            }
            Text(item.text).foregroundStyle(.secondary)
        case .file:
            let paths = item.paths
            Image(nsImage: Cache.fileIcon(paths.first ?? "")).resizable().frame(width: 26, height: 26)
            Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct RichRow: View {
    let item: Item
    let shortcut: Int?
    let selected: Bool
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 18, height: 18)
                Text(Cache.appName(item.app)).lineLimit(1)
                Spacer(minLength: 4)
                Badge(item: item, shortcut: shortcut)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            ClipContent(item: item, store: store, lines: 5, imageHeight: 170, large: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.rich.cornerRadius, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.05))
        )
        .selectionGlow(selected)
        .contentShape(Rectangle())
    }
}

struct Card: View {
    let item: Item
    let shortcut: Int?
    let selected: Bool
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 12, height: 12)
                Text(Cache.appName(item.app)).lineLimit(1)
                Spacer(minLength: 2)
                Badge(item: item, shortcut: shortcut)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            Group {
                if item.kind == .image, let thumb = Cache.thumbnail(item, store: store, size: 600) {
                    // The clear frame sets the size; the image fills it whatever the column width is.
                    Color.clear.overlay(Image(nsImage: thumb).resizable().scaledToFill()).clipped()
                } else {
                    ClipContent(item: item, store: store, lines: 7, imageHeight: 100).padding(8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 124, maxHeight: 124, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: Layout.grid.cornerRadius, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: Layout.grid.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.grid.cornerRadius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1)
        )
        .selectionGlow(selected, radius: 10)
        .contentShape(Rectangle())
    }
}

/// Multi-line content used by the rich list and grid cards.
struct ClipContent: View {
    let item: Item
    let store: Store
    let lines: Int
    let imageHeight: CGFloat
    /// Rich List uses larger type than the compact grid cards.
    var large = false

    private var body12: CGFloat { large ? 14 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: large ? 6 : 4) {
            switch item.kind {
            case .text where item.style == .color:
                HStack(spacing: 8) {
                    StyleMark(item: item).scaleEffect(2.2).frame(width: 28, height: 28)
                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: body12, design: .monospaced))
                }
            case .text:
                if item.style != .plain {
                    Label(item.style == .code ? "Code" : "Markdown", systemImage: item.style.symbol)
                        .font(.system(size: large ? 11.5 : 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Text(String(item.text.prefix(lines * 120)))
                    .font(item.style == .code ? .system(size: body12 - 0.5, design: .monospaced) : .system(size: body12))
                    .lineLimit(lines)
            case .link:
                Label(item.host ?? "Link", systemImage: "link")
                    .font(.system(size: body12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: body12 - 1))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            case .image:
                if let thumb = Cache.thumbnail(item, store: store, size: 600) {
                    CoverImage(image: thumb, cornerRadius: 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: imageHeight)
                }
                Text(item.text).font(.system(size: 10)).foregroundStyle(.secondary)
            case .file:
                let paths = item.paths
                HStack(spacing: 8) {
                    let image = paths.count == 1 ? Cache.fileThumbnail(URL(fileURLWithPath: paths[0]), size: 200) : nil
                    Image(nsImage: image ?? Cache.fileIcon(paths.first ?? ""))
                        .resizable().scaledToFit().frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                            .font(.system(size: 12))
                            .lineLimit(2)
                        if paths.count > 1 {
                            Text("\(paths.count) files").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Item {
    var paths: [String] { text.split(separator: "\n").map(String.init) }
    var host: String? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
}

struct PreviewPane: View {
    let item: Item?
    let store: Store

    var body: some View {
        if let item {
            VStack(spacing: 0) {
                content(item).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                HStack(spacing: 6) {
                    Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 14, height: 14)
                    Text(Cache.appName(item.app))
                    Spacer()
                    Text(details(item))
                    Text(Date(timeIntervalSince1970: item.created).formatted(date: .abbreviated, time: .shortened))
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        } else {
            Text("No item selected").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func content(_ item: Item) -> some View {
        switch item.kind {
        case .text where item.style == .color:
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(nsColor: TextStyle.color(from: item.text) ?? .gray))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                    .frame(width: 180, height: 180)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 15, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .text:
            TextPreview(text: Cache.fullText(item, store: store))
        case .link:
            VStack(alignment: .leading, spacing: 10) {
                Label(item.host ?? "Link", systemImage: "link").font(.headline)
                Text(item.text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
        case .image:
            if let image = Cache.thumbnail(item, store: store, size: 1400) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        case .file:
            let urls = item.paths.map { URL(fileURLWithPath: $0) }
            if urls.count == 1, let image = Cache.fileThumbnail(urls[0], size: 1400) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(urls, id: \.self) { url in
                            HStack(spacing: 10) {
                                Image(nsImage: Cache.fileIcon(url.path)).resizable().frame(width: 32, height: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(url.lastPathComponent).font(.system(size: 13))
                                    Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
            }
        }
    }

    private func details(_ item: Item) -> String {
        switch item.kind {
        case .text:
            let text = Cache.fullText(item, store: store)
            let label = ["Text", "Code", "Markdown", "Color"][item.style.rawValue]
            return "\(label) · \(text.count) chars · \(text.split(whereSeparator: \.isNewline).count) lines ·"
        case .link: return "Link ·"
        case .image: return "\(item.text) ·"
        case .file:
            let count = item.paths.count
            return count == 1 ? "File ·" : "\(count) files ·"
        }
    }
}

/// NSTextView handles large text far better than SwiftUI Text.
struct TextPreview: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isRichText = false
            view.drawsBackground = false
            view.textContainerInset = NSSize(width: 10, height: 12)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.textColor = .labelColor
        view.scrollToBeginningOfDocument(nil)
    }
}

/// Frosted glass with a solid tint, so colorful windows behind never show through:
/// near-black in Dark mode, near-white in Light mode, following the system appearance.
struct PanelBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            VisualEffect()
            scheme == .dark ? Color.black.opacity(0.62) : Color.white.opacity(0.72)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        // The app is never active, so force the material on.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Small caches so scrolling never hits the disk twice for the same icon, thumbnail or text.
enum Cache {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]
    /// Files with no thumbnail (not an image, too large, unreadable), so redraws never ask the disk again.
    private static var noThumbnail: Set<String> = []
    /// Decoded thumbnails, bounded by memory; the cost of each is its pixel size.
    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.totalCostLimit = 150 * 1024 * 1024
        return cache
    }()
    private static let texts: NSCache<NSNumber, NSString> = {
        let cache = NSCache<NSNumber, NSString>()
        cache.countLimit = 30
        return cache
    }()
    private static let fileIcons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        return cache
    }()

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
