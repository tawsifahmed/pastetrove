import AppKit
import SwiftUI

/// Large preview of the selected item, shown beside the panel. It never takes focus, so typing stays in the search field.
final class PreviewController {
    private let panel: NSPanel
    private let zoom = ZoomBox()

    init(model: Model) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.float(PreviewWindow(model: model, zoom: zoom))
    }

    /// ⌘+ and ⌘−; false when no image preview is open.
    func zoom(in zoomIn: Bool) -> Bool {
        guard panel.isVisible, let scroll = zoom.scroll, scroll.window != nil else { return false }
        let target = scroll.magnification * (zoomIn ? 1.5 : 1 / 1.5)
        scroll.animator().magnification = min(max(target, scroll.minMagnification), scroll.maxMagnification)
        return true
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
    let zoom: ZoomBox

    var body: some View {
        PreviewPane(item: model.current, store: model.store, zoom: zoom).panelChrome()
    }
}

struct PreviewPane: View {
    let item: Item?
    let store: Store
    let zoom: ZoomBox

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
                ZoomImage(image: image, box: zoom) { Cache.thumbnail(item, store: store, size: 5000) }
            }
        case .file:
            let urls = item.paths.map { URL(fileURLWithPath: $0) }
            if urls.count == 1, let image = Cache.fileThumbnail(urls[0], size: 1400) {
                ZoomImage(image: image, box: zoom) { Cache.fileThumbnail(urls[0], size: 5000) }
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
            let label = ["Text", "Code", "Markdown", "Color"][item.style.rawValue]
            return "\(label) · \(Cache.textSize(item, store: store)) ·"
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

/// The preview's image scroll view, so ⌘+ and ⌘− in the panel can zoom it.
final class ZoomBox {
    weak var scroll: NSScrollView?
}

/// An image that fits the preview and zooms: pinch, double-click (fit ↔ 3×), ⌘+ and ⌘−, then scroll to move around.
/// It starts from the preview-size picture; the sharp full-size one is decoded only once you zoom in.
struct ZoomImage: NSViewRepresentable {
    let image: NSImage
    let box: ZoomBox
    let sharp: () -> NSImage?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        let view = FirstClickImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = view
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleClick(_:)))
        click.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(click)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.zoomed(_:)),
                                               name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        // Fits again once SwiftUI sizes the view, unless you zoomed in.
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.resized(_:)),
                                               name: NSView.frameDidChangeNotification, object: scroll)
        box.scroll = scroll
        context.coordinator.scroll = scroll
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        box.scroll = scroll
        context.coordinator.sharp = sharp
        guard let view = scroll.documentView as? NSImageView, context.coordinator.shown !== image else { return }
        context.coordinator.shown = image
        context.coordinator.sharpLoaded = false
        context.coordinator.fitted = false
        view.image = image
        view.frame = NSRect(origin: .zero, size: image.size)
        context.coordinator.fit()
    }

    final class Coordinator: NSObject {
        weak var scroll: NSScrollView?
        weak var shown: NSImage?
        var sharp: (() -> NSImage?)?
        var sharpLoaded = false
        /// False until the current image was fitted to a sized view.
        var fitted = false

        func fit() {
            guard let scroll, let size = scroll.documentView?.frame.size, size.width > 0, size.height > 0 else { return }
            let box = scroll.frame.size
            guard box.width > 32, box.height > 32 else { return }
            let fit = min((box.width - 32) / size.width, (box.height - 32) / size.height)
            scroll.minMagnification = fit
            scroll.maxMagnification = max(fit * 8, 4)
            scroll.magnification = fit
            fitted = true
        }

        @objc func doubleClick(_ click: NSClickGestureRecognizer) {
            guard let scroll, let view = scroll.documentView else { return }
            let point = view.convert(click.location(in: scroll), from: scroll)
            if scroll.magnification > scroll.minMagnification * 1.05 {
                scroll.animator().magnification = scroll.minMagnification
            } else {
                scroll.animator().setMagnification(min(scroll.minMagnification * 3, scroll.maxMagnification), centeredAt: point)
            }
            loadSharp()
        }

        @objc func resized(_ note: Notification) {
            guard let scroll, !fitted || scroll.magnification <= scroll.minMagnification * 1.01 else { return }
            fit()
        }

        @objc func zoomed(_ note: Notification) {
            loadSharp()
        }

        /// Swaps in the full-size picture at the same frame, so zooming in stays crisp.
        private func loadSharp() {
            guard !sharpLoaded, let view = scroll?.documentView as? NSImageView else { return }
            sharpLoaded = true
            if let image = sharp?() { view.image = image }
        }
    }
}

/// The preview never takes focus, so its first click must count, or a double-click would need three.
private final class FirstClickImageView: NSImageView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Keeps a picture smaller than the preview in its center instead of the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView?.frame.size else { return rect }
        if rect.width > document.width { rect.origin.x = (document.width - rect.width) / 2 }
        if rect.height > document.height { rect.origin.y = (document.height - rect.height) / 2 }
        return rect
    }
}
