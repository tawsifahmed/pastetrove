import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A small "Copied" note under the menu bar icon for a moment after each copy, showing what was saved.
/// Clicks pass through it and it never takes focus.
final class CopyPill {
    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    /// Counts shows, so a fade that ends after a newer copy never hides it.
    private var shown = 0

    init() {
        panel.float(EmptyView())
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        // Left out of screenshots and recordings: a quick screenshot right after a copy must not show the note.
        panel.sharingType = .none
    }

    func show(_ clip: Capture, below icon: NSRect) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: icon.midX, y: icon.midY)) })?.visibleFrame else { return }
        let host = NSHostingView(rootView: CopyPillView(clip: clip))
        let size = host.fittingSize
        panel.contentView = host
        let x = min(max(icon.midX - size.width / 2, screen.minX + 6), screen.maxX - size.width - 6)
        let frame = NSRect(x: x, y: icon.minY - 6 - size.height, width: size.width, height: size.height)
        // Slides down a little while it fades in, unless Reduce Motion is on.
        let slide = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 6.0
        panel.setFrame(frame.offsetBy(dx: 0, dy: slide), display: false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
            panel.animator().setFrame(frame, display: true)
        }
        shown += 1
        let current = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self, shown == current else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self.panel.animator().alphaValue = 0 }) {
                if self.shown == current { self.panel.orderOut(nil) }
            }
        }
    }
}

/// One compact size for every kind: an icon for what was copied, and "Copied".
struct CopyPillView: View {
    let clip: Capture

    var body: some View {
        HStack(spacing: 5) {
            icon.frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text("Copied").font(.system(size: 11, weight: .semibold))
            Spacer(minLength: 0)
        }
        .padding(.leading, 3)
        .frame(width: 92, height: 22)
        .background(Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12)))
        .padding(8)
    }

    @ViewBuilder private var icon: some View {
        switch clip.kind {
        case .image:
            if let data = clip.reps.first(where: { $0.0 == Store.thumbnailType })?.1, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                symbol("photo")
            }
        case .file:
            // The icon by type: reading the file itself could ask for folder access.
            let ext = (clip.text.split(separator: "\n").first.map { ($0 as NSString).pathExtension }) ?? ""
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)).resizable()
        case .link:
            symbol("link")
        case .text:
            switch TextStyle(clip.text) {
            case .color: Color(nsColor: TextStyle.color(from: clip.text) ?? .gray)
            case .code: symbol("chevron.left.forwardslash.chevron.right")
            case .markdown: symbol("number")
            case .plain:
                Text("T").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor)
            }
        }
    }

    /// A white symbol on the accent color, like a small app icon.
    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 8.5, weight: .bold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.accentColor)
    }
}
