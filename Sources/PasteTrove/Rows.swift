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

/// "1 item", "2 items".
func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

extension Item {
    var paths: [String] { text.split(separator: "\n").map(String.init) }
    var host: String? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host }
}
