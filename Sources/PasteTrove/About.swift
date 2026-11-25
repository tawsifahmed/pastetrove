import AppKit
import SwiftUI

/// The About window: icon, version, build date, and a button that copies the version details.
final class AboutController {
    static let repositoryURL = URL(string: "https://github.com/tawsifahmed/pastetrove")!
    /// Lets people pick a bug report, a feature request or a private security report.
    static let newIssueURL = URL(string: "https://github.com/tawsifahmed/pastetrove/issues/new/choose")!
    static let roadmapURL = URL(string: "https://github.com/tawsifahmed/pastetrove/projects")!

    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct AboutView: View {
    @State private var copied = false

    private let info = Bundle.main.infoDictionary ?? [:]
    private var version: String { info["CFBundleShortVersionString"] as? String ?? "?" }
    private var build: String { info["CFBundleVersion"] as? String ?? "?" }
    private var built: Date? {
        try? Bundle.main.executableURL?.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("PasteTrove")
                .font(.system(size: 26, weight: .bold))
                .padding(.top, 6)
            Text("Version \(version) (\(build))")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            if let built {
                let ago = RelativeDateTimeFormatter().localizedString(for: built, relativeTo: Date())
                Text("\(built.formatted(date: .abbreviated, time: .shortened)) (\(ago))")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Button("GitHub") { NSWorkspace.shared.open(AboutController.repositoryURL) }
                Button(copied ? "Copied" : "Copy version info", action: copyVersion)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 16)
            Text(info["NSHumanReadableCopyright"] as? String ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
        }
        .padding(.horizontal, 40)
        .padding(.top, 34)
        .padding(.bottom, 24)
        .frame(width: 380)
    }

    private func copyVersion() {
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        let text = "PasteTrove \(version) (\(build))\nmacOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(chip)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}
