import AppKit
import SwiftUI

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

/// Tap order while "Paste several at once" collects items; `Badge` shows it next to the ⌘ key.
struct QueueOrderKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var queueOrder: Int? {
        get { self[QueueOrderKey.self] }
        set { self[QueueOrderKey.self] = newValue }
    }
}

/// Green outline with a "Copied" label, shown briefly when an item is copied or pasted.
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

/// A thin accent ring that fades in under the pointer, with the pointing-hand cursor.
struct HoverHighlight: ViewModifier {
    let cornerRadius: CGFloat
    /// Off for the selected or flashing item, which already has its own highlight.
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay { HoverRing(cornerRadius: cornerRadius).opacity(enabled && hovering ? 1 : 0) }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { inside in
                hovering = inside
                (inside ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
    }
}

struct HoverRing: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape.fill(Color.accentColor.opacity(0.06))
            .overlay(shape.strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

/// The item's age, or a glowing ⌘ shortcut pill while ⌘ is held, plus the pin mark.
struct Badge: View {
    let item: Item
    let shortcut: Int?
    @Environment(\.queueOrder) private var order

    var body: some View {
        HStack(spacing: 4) {
            if item.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange) }
            if let order {
                Text("\(order)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor, in: Circle())
                    // The ring keeps it visible on a selected row, which is accent-colored too.
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
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
            ClipContent(item: item, store: store, lines: 5, large: true)
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
                    ClipContent(item: item, store: store, lines: 7).padding(8)
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
/// What a drag shows: an image's picture, or a small card with the item's content.
struct DragPreview: View {
    let item: Item
    let store: Store
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if item.kind == .image, let image = Cache.thumbnail(item, store: store, size: Store.thumbnailSize) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(maxWidth: 180, maxHeight: 180)
            } else {
                ClipContent(item: item, store: store, lines: 4)
                    .padding(10)
                    .frame(width: 220, alignment: .topLeading)
                    .background(scheme == .dark ? Color(white: 0.16) : Color.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct ClipContent: View {
    let item: Item
    let store: Store
    let lines: Int
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
                        .frame(height: 170)
                }
                Text(item.text).font(.system(size: 10)).foregroundStyle(.secondary)
            case .file:
                let paths = item.paths
                HStack(spacing: 8) {
                    // The thumbnail saved when it was copied: the list never opens the file.
                    let image = paths.count == 1 ? Cache.thumbnail(item, store: store, size: 200) : nil
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

/// "1 item", "2 items".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

extension Item {
    var paths: [String] { text.split(separator: "\n").map(String.init) }
    var isText: Bool { kind == .text || kind == .link }
    var host: String? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
}
