import AppKit
import CryptoKit
import Security
import SwiftUI

/// A published PasteTrove release, as the GitHub Releases API returns it.
struct Release: Decodable {
    let tag: String
    let notes: String?
    let page: URL
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let size: Int
        /// "sha256:<hex>", published by GitHub for each uploaded file.
        let digest: String?
        let url: URL

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case url = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", notes = "body", page = "html_url", assets
    }

    var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }

    /// The zip that the Homebrew cask also uses.
    var zip: Asset? { assets.first { $0.name == "PasteTrove-\(version).zip" } }
}

/// Checks GitHub Releases once a day for a newer PasteTrove, then downloads, verifies and installs it.
/// A download is installed only when its checksum matches and macOS confirms it is signed
/// with the same certificate as the running app; on any failure the current app stays as it is.
final class Updater {
    /// `PASTETROVE_UPDATE_URL` points the check at another feed, for tests.
    static let feed = URL(string: ProcessInfo.processInfo.environment["PASTETROVE_UPDATE_URL"]
        ?? "https://api.github.com/repos/tawsifahmed/pastetrove/releases/latest")!

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// A newer version that has not been installed yet, for the menus.
    private(set) var available: Release? {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private var checking = false
    private var timer: Timer?
    private let progress = UpdateProgress()

    /// Checks soon after launch, then every hour whether a day has passed since the last check.
    func start() {
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Settings.autoUpdate, Date().timeIntervalSince1970 - Settings.lastUpdateCheck > 86_400 else { return }
        check(manual: false)
    }

    /// `manual` (menu or Settings): also says "up to date" or why the check failed, and offers a skipped version again.
    func check(manual: Bool) {
        guard !checking else { return }
        checking = true
        var request = URLRequest(url: Self.feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let release = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async { [self] in
                checking = false
                handle(release, manual: manual)
            }
        }.resume()
    }

    private func handle(_ release: Release?, manual: Bool) {
        guard let release else {
            if manual { failed("PasteTrove couldn't reach GitHub. Check your internet connection and try again.", page: nil) }
            return
        }
        Settings.lastUpdateCheck = Date().timeIntervalSince1970
        guard Self.isNewer(release.version, than: Self.current) else {
            available = nil
            if manual { upToDate() }
            return
        }
        available = release
        if manual || release.version != Settings.skippedVersion { offer(release) }
    }

    func offer(_ release: Release) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "A new version of PasteTrove is available"
        alert.informativeText = "PasteTrove \(release.version) is ready. You have \(Self.current)."
        alert.accessoryView = Self.notesView(release.notes ?? "")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Check for updates automatically"
        alert.suppressionButton?.state = Settings.autoUpdate ? .on : .off
        alert.addButton(withTitle: "Install & Relaunch")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Skip This Version")
        let answer = alert.runModal()
        Settings.autoUpdate = alert.suppressionButton?.state == .on
        switch answer {
        case .alertFirstButtonReturn: install(release)
        case .alertThirdButtonReturn: Settings.skippedVersion = release.version
        default: break
        }
    }

    private func install(_ release: Release) {
        let app = Bundle.main.bundleURL
        guard let zip = release.zip else {
            return failed("This release has no PasteTrove-\(release.version).zip to install.", page: release.page)
        }
        guard Self.canReplace(app) else {
            return failed("PasteTrove can't update itself where it is now (\(app.deletingLastPathComponent().path)). Move it to Applications, or download the new version.", page: release.page)
        }
        let task = URLSession.shared.downloadTask(with: zip.url) { [weak self] file, _, error in
            // The downloaded file is deleted when this returns, so check and install it here.
            var failure: String?
            if let file {
                do {
                    try Self.replace(app, with: file, asset: zip, version: release.version)
                } catch {
                    failure = (error as? UpdateError)?.description ?? error.localizedDescription
                }
            } else if (error as? URLError)?.code == .cancelled {
                return DispatchQueue.main.async { self?.progress.close() }
            } else {
                failure = "The download stopped. Check your internet connection and try again."
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.progress.close()
                if let failure { self.failed(failure, page: release.page) } else { Self.relaunch(app) }
            }
        }
        progress.show(version: release.version, task: task)
        task.resume()
    }

    /// Checks the download and swaps it in with one atomic step. Throws a message for the person.
    private static func replace(_ app: URL, with download: URL, asset: Release.Asset, version: String) throws {
        let data = try Data(contentsOf: download, options: .mappedIfSafe)
        guard data.count == asset.size else { throw UpdateError("The download is incomplete.") }
        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:" + hash else { throw UpdateError("The download doesn't match the checksum GitHub published.") }
        }
        // Unpack on the same volume as the app, so the swap is a rename.
        let files = FileManager.default
        let dir = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: dir) }
        try run("/usr/bin/ditto", "-x", "-k", download.path, dir.path)
        let new = dir.appendingPathComponent("PasteTrove.app")
        guard let bundle = Bundle(url: new), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { throw UpdateError("The download doesn't contain PasteTrove \(version).") }
        guard signedLikeSelf(new) else { throw UpdateError("The download isn't signed by the PasteTrove developer, so it wasn't installed.") }
        // Gatekeeper would block an app that still carries the download flag.
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", new.path)
        _ = try files.replaceItemAt(app, withItemAt: new)
    }

    /// macOS's own code-signing check: the new app must meet the running app's designated requirement
    /// (the same bundle ID and the same signing certificate), and none of its files may be changed.
    static func signedLikeSelf(_ app: URL) -> Bool {
        var me: SecCode?, mine: SecStaticCode?, requirement: SecRequirement?, new: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &new) == errSecSuccess, let new
        else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(new, flags, requirement) == errSecSuccess
    }

    /// A copy running from the disk image, a folder this user can't write, or one macOS moved
    /// to a random place before first launch ("App Translocation") can't replace itself.
    private static func canReplace(_ app: URL) -> Bool {
        let files = FileManager.default
        return !app.path.contains("/AppTranslocation/")
            && files.isWritableFile(atPath: app.path)
            && files.isWritableFile(atPath: app.deletingLastPathComponent().path)
    }

    /// Opens the new app once this one has quit. The test settings (`PASTETROVE_DATA_DIR`, `PASTETROVE_UPDATE_URL`) carry over.
    private static func relaunch(_ app: URL) {
        var arguments = ["-n"]
        for key in ["PASTETROVE_DATA_DIR", "PASTETROVE_UPDATE_URL"] {
            if let value = ProcessInfo.processInfo.environment[key] { arguments += ["--env", "\(key)=\(value)"] }
        }
        let wait = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$@\""
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", wait, "sh"] + arguments + [app.path]
        try? shell.run()
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Unpacking the download failed.") }
    }

    /// 0.1.10 is newer than 0.1.9: each part compares as a number.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// Release notes as plain lines: no version heading, headings and bullets without Markdown marks.
    static func plainNotes(_ markdown: String) -> String {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") { return nil }
            var text = line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            return text
        }
        .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func notesView(_ notes: String) -> NSView {
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 130)
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.textContainerInset = NSSize(width: 6, height: 8)
            text.string = plainNotes(notes)
            text.font = .systemFont(ofSize: 12)
            text.textColor = .labelColor
        }
        return scroll
    }

    private func upToDate() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date"
        alert.informativeText = "PasteTrove \(Self.current) is the newest version."
        alert.runModal()
    }

    private func failed(_ message: String, page: URL?) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "PasteTrove couldn't update"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if page != nil { alert.addButton(withTitle: "Open Download Page") }
        if alert.runModal() == .alertSecondButtonReturn, let page { NSWorkspace.shared.open(page) }
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// The small "Updating PasteTrove" window with a progress bar and Cancel.
final class UpdateProgress: ObservableObject {
    @Published var fraction = 0.0
    @Published var status = ""
    private var window: NSWindow?
    private var task: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    func show(version: String, task: URLSessionDownloadTask) {
        self.task = task
        fraction = 0
        status = "Downloading \(version)…"
        observation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            DispatchQueue.main.async {
                self?.fraction = progress.fractionCompleted
                if progress.fractionCompleted >= 1 { self?.status = "Checking and installing…" }
            }
        }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: UpdateProgressView(model: self)))
            window.styleMask = [.titled]
            window.title = "Updating PasteTrove"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        task?.cancel()
    }

    func close() {
        observation = nil
        task = nil
        window?.orderOut(nil)
    }
}

struct UpdateProgressView: View {
    @ObservedObject var model: UpdateProgress

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 8) {
                Text("Updating PasteTrove").font(.headline)
                Text(model.status).foregroundStyle(.secondary)
                ProgressView(value: model.fraction)
                Text("PasteTrove checks the download, then relaunches by itself.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", action: model.cancel).disabled(model.fraction >= 1)
                }
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
