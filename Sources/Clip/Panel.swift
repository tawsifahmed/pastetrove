import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

enum PickMode {
    case paste, plain, copy
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

    var columns: Int { self == .grid ? 2 : 1 }
}

enum Filter: CaseIterable {
    case all, text, links, images, files, pinned

    var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .links: "Links"
        case .images: "Images"
        case .files: "Files"
        case .pinned: "Pinned"
        }
    }

    func matches(_ item: Item) -> Bool {
        switch self {
        case .all: true
        case .text: item.kind == .text
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
    private var all: [Item] = []

    init(store: Store) {
        self.store = store
        reload()
    }

    var current: Item? {
        shown.indices.contains(selected) ? shown[selected] : nil
    }

    func reload() {
        all = store.items()
        apply()
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

    func deleteCurrent() {
        guard let item = current else { return }
        store.delete(item.id)
        reload()
    }

    func togglePin() {
        guard let item = current else { return }
        store.setPinned(item.id, !item.pinned)
        reload()
        selected = shown.firstIndex { $0.id == item.id } ?? 0
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

    static let width: CGFloat = 380

    var onPick: ((Item, PickMode) -> Void)?
    var onSettings: (() -> Void)?

    private let model: Model
    private let panel: FloatingPanel
    private let preview: PreviewController
    private var keyMonitor: Any?
    private var hiddenAt = Date.distantPast

    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]

    init(model: Model) {
        self.model = model
        panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        preview = PreviewController(model: model)
        super.init()
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
            settings: { [weak self] in self?.openSettings() },
            togglePreview: { [weak self] in self?.togglePreview() }
        ))
        host.sizingOptions = []
        panel.contentView = host
    }

    func toggle(at anchor: Anchor) {
        if panel.isVisible {
            hide()
        } else if Date().timeIntervalSince(hiddenAt) > 0.3 {
            // A click on the status icon first hides the panel by taking focus; do not reopen it right away.
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
        let height = min(760, screen.height - 40)
        var frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
        switch anchor {
        case let .below(rect):
            frame.origin = NSPoint(x: rect.midX - Self.width / 2, y: rect.minY - 6 - height)
        case .cursor:
            frame.origin = NSPoint(x: point.x - 24, y: point.y - height + 12)
        case .center:
            frame.origin = NSPoint(x: screen.midX - Self.width / 2, y: screen.midY - height / 2)
        }
        panel.setFrame(Self.clamp(frame, to: screen), display: true)
        panel.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) == true ? nil : event
            }
        }
    }

    func hide() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        preview.hide()
        panel.orderOut(nil)
        hiddenAt = Date()
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func pick(_ item: Item, _ mode: PickMode) {
        hide()
        onPick?(item, mode)
    }

    private func openSettings() {
        hide()
        onSettings?()
    }

    private func togglePreview() {
        preview.toggle(beside: panel.frame)
    }

    private static func clamp(_ frame: NSRect, to screen: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, screen.minX + 6), screen.maxX - frame.width - 6)
        frame.origin.y = min(max(frame.minY, screen.minY + 6), screen.maxY - frame.height)
        return frame
    }

    private func handle(_ event: NSEvent) -> Bool {
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
            model.move(command ? Int(Int32.max) : model.layout.columns)
            return true
        case kVK_UpArrow:
            model.move(command ? -Int(Int32.max) : -model.layout.columns)
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
            model.deleteCurrent()
            return true
        default:
            break
        }

        if flags.contains(.control), key == kVK_ANSI_N || key == kVK_ANSI_P {
            model.move(key == kVK_ANSI_N ? model.layout.columns : -model.layout.columns)
            return true
        }
        guard command else { return false }
        switch key {
        case kVK_ANSI_P:
            model.togglePin()
        case kVK_ANSI_L:
            model.cycleLayout()
        case kVK_ANSI_Y:
            togglePreview()
        case kVK_ANSI_Comma:
            openSettings()
        default:
            guard let number = Self.digits[key], number <= model.shown.count else { return false }
            pick(model.shown[number - 1], shift ? .plain : .paste)
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
            .background(VisualEffect())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}

struct PanelView: View {
    @ObservedObject var model: Model
    let pick: (Item, PickMode) -> Void
    let settings: () -> Void
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
        .background(VisualEffect())
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
                Button(action: settings) { Image(systemName: "gearshape").font(.system(size: 15)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Settings (⌘,)")
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
                    Group {
                        if model.layout == .grid {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(Card.width), spacing: 10), count: 2), spacing: 10) {
                                cells
                            }
                        } else {
                            LazyVStack(spacing: model.layout == .rich ? 6 : 1) { cells }
                        }
                    }
                    .padding(model.layout == .grid ? 12 : 8)
                }
                .onChange(of: model.current?.id) {
                    if let id = model.current?.id { proxy.scrollTo(id) }
                }
            }
        }
    }

    private var cells: some View {
        ForEach(Array(model.shown.enumerated()), id: \.element.id) { index, item in
            cell(item, index)
                .id(item.id)
                .onTapGesture(count: 2) { pick(item, .paste) }
                .onTapGesture { model.selected = index }
        }
    }

    @ViewBuilder private func cell(_ item: Item, _ index: Int) -> some View {
        let selected = index == model.selected
        switch model.layout {
        case .plain: PlainRow(item: item, index: index, selected: selected, store: model.store)
        case .rich: RichRow(item: item, index: index, selected: selected, store: model.store)
        case .grid: Card(item: item, index: index, selected: selected, store: model.store)
        }
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

/// ⌘1–9 for the first nine items, age for the rest, plus the pin mark.
struct Badge: View {
    let item: Item
    let index: Int

    var body: some View {
        HStack(spacing: 4) {
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
            Text(index < 9 ? "⌘\(index + 1)" : item.age).monospacedDigit()
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }
}

struct PlainRow: View {
    let item: Item
    let index: Int
    let selected: Bool
    let store: Store

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 16, height: 16)
            content
            Spacer(minLength: 4)
            Badge(item: item, index: index)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.3) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder private var content: some View {
        switch item.kind {
        case .text:
            Text(item.preview).lineLimit(1)
        case .link:
            Image(systemName: "link").font(.system(size: 11)).foregroundStyle(.blue)
            Text(item.preview).lineLimit(1).truncationMode(.middle)
        case .image:
            if let thumb = Cache.thumbnail(item, store: store, size: 80) {
                Image(nsImage: thumb).resizable().scaledToFit().frame(height: 20)
            }
            Text(item.text).foregroundStyle(.secondary)
        case .file:
            let paths = item.paths
            Image(nsImage: NSWorkspace.shared.icon(forFile: paths.first ?? "")).resizable().frame(width: 16, height: 16)
            Text(paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

struct RichRow: View {
    let item: Item
    let index: Int
    let selected: Bool
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 14, height: 14)
                Text(Cache.appName(item.app)).lineLimit(1)
                Text("· \(item.age)")
                Spacer(minLength: 4)
                if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
                if index < 9 { Text("⌘\(index + 1)") }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            ClipContent(item: item, store: store, lines: 5, imageHeight: 120)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
    }
}

struct Card: View {
    static let width: CGFloat = 173

    let item: Item
    let index: Int
    let selected: Bool
    let store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(nsImage: Cache.appIcon(item.app)).resizable().frame(width: 12, height: 12)
                Text(Cache.appName(item.app)).lineLimit(1)
                Spacer(minLength: 2)
                Badge(item: item, index: index)
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05))
            Group {
                if item.kind == .image, let thumb = Cache.thumbnail(item, store: store, size: 500) {
                    Image(nsImage: thumb).resizable().scaledToFill().frame(width: Self.width, height: 118).clipped()
                } else {
                    ClipContent(item: item, store: store, lines: 7, imageHeight: 100).padding(8)
                }
            }
            .frame(width: Self.width, height: 118, alignment: .topLeading)
        }
        .frame(width: Self.width)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
    }
}

/// Multi-line content used by the rich list and grid cards.
struct ClipContent: View {
    let item: Item
    let store: Store
    let lines: Int
    let imageHeight: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch item.kind {
            case .text:
                Text(String(item.text.prefix(lines * 120)))
                    .font(.system(size: 11.5, design: .monospaced))
                    .lineLimit(lines)
            case .link:
                Label(item.host ?? "Link", systemImage: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .lineLimit(1)
                Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            case .image:
                if let thumb = Cache.thumbnail(item, store: store, size: 600) {
                    Image(nsImage: thumb).resizable().scaledToFit()
                        .frame(maxHeight: imageHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Text(item.text).font(.system(size: 10)).foregroundStyle(.secondary)
            case .file:
                let paths = item.paths
                HStack(spacing: 8) {
                    let image = paths.count == 1 ? Cache.fileThumbnail(URL(fileURLWithPath: paths[0]), size: 200) : nil
                    Image(nsImage: image ?? NSWorkspace.shared.icon(forFile: paths.first ?? ""))
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
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 32, height: 32)
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
            return "\(text.count) chars · \(text.split(whereSeparator: \.isNewline).count) lines ·"
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
    private static let images = NSCache<NSString, NSImage>()
    private static let texts = NSCache<NSNumber, NSString>()

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
        guard let png = store.data(item.id, type: NSPasteboard.PasteboardType.png.rawValue),
              let image = scaled(CGImageSourceCreateWithData(png as CFData, nil), size)
        else { return nil }
        images.setObject(image, forKey: key)
        return image
    }

    static func fileThumbnail(_ url: URL, size: Int) -> NSImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        let key = "file-\(url.path)-\(size)" as NSString
        if let hit = images.object(forKey: key) { return hit }
        guard let image = scaled(CGImageSourceCreateWithURL(url as CFURL, nil), size) else { return nil }
        images.setObject(image, forKey: key)
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

    private static func scaled(_ source: CGImageSource?, _ size: Int) -> NSImage? {
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: size,
        ] as CFDictionary
        guard let source, let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2))
    }
}
