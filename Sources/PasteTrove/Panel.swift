import AppKit
import Carbon
import SwiftUI

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
    /// A flash is showing before a paste; a second ⏎ meanwhile is ignored.
    private var picking = false

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
        panel.delegate = self
        panel.float(PanelView(
            model: model,
            pick: { [weak self] item, mode in self?.flashThenPick(item, mode) },
            copy: { [weak self] item in self?.copy(item) },
            command: { [weak self] in self?.run($0) },
            togglePreview: { [weak self] in self?.togglePreview() }
        ))
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
        model.open()
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
        model.close()
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

    /// Flashes "Copied" on the item, then closes and pastes, so you see which item it was.
    /// If the panel closed meanwhile (you switched apps), it only copies, so the paste never lands elsewhere.
    private func flashThenPick(_ item: Item, _ mode: PickMode) {
        guard !picking else { return }
        picking = true
        model.select(item)
        model.flash(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            picking = false
            if panel.isVisible { pick(item, mode) } else { onCopy?(item) }
        }
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
            if let item = model.current { flashThenPick(item, command ? .copy : shift ? .plain : .paste) }
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
            flashThenPick(model.shown[index], shift ? .plain : .paste)
        }
        return true
    }
}

extension NSPanel {
    /// Clear, shadowed, floating on every Space, and showing `view`.
    func float(_ view: some View) {
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
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
        .panelChrome()
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
            Button(model.updateVersion.map { "Update to \($0)…" } ?? "Check for Updates…") { command(.updates) }
            Divider()
            Button("Clear History…") { command(.clearHistory) }
            Button("Quit PasteTrove") { command(.quit) }
                .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "gearshape").font(.system(size: 15))
                .overlay(alignment: .topTrailing) {
                    // An update is waiting.
                    if model.updateVersion != nil { Circle().fill(.orange).frame(width: 7, height: 7).offset(x: 2, y: -2) }
                }
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
                .onChange(of: model.toTop) {
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
        .modifier(HoverHighlight(cornerRadius: model.layout.cornerRadius, enabled: !selected && !flashing))
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
            if let version = model.updateVersion {
                Button("Update to \(version)", systemImage: "arrow.up") { command(.updates) }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .foregroundStyle(.tint)
                    .help("Install PasteTrove \(version)")
            } else {
                Text(counted(model.shown.count, "item"))
            }
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
        .animation(.easeOut(duration: 0.25), value: model.updateVersion)
    }
}

struct FirstVisibleKey: PreferenceKey {
    static var defaultValue = Int.max

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = min(value, nextValue())
    }
}

extension View {
    /// The panel's rounded glass window look.
    func panelChrome() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelBackground())
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }

    /// Soft accent glow around the selected item.
    func selectionGlow(_ selected: Bool, radius: CGFloat = 8) -> some View {
        shadow(color: selected ? Color.accentColor.opacity(0.45) : .clear, radius: radius)
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
