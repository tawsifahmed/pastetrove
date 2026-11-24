import AppKit
import SwiftUI

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
        panel.float(PreviewWindow(model: model))
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
        PreviewPane(item: model.current, store: model.store).panelChrome()
    }
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
