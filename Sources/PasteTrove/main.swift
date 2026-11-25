import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var model: Model!
    private var monitor: Monitor!
    private var panel: PanelController!
    private var hotkey: Hotkey!
    private var settings: SettingsController!
    private let about = AboutController()
    private let updater = Updater()
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var askedAccessibility = false
    /// A `pastetrove://` link that launched the app arrives before setup is done; it waits here.
    private var launchURLs: [URL] = []
    private let openItem = NSMenuItem(title: "Open PasteTrove", action: #selector(openPanel), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store()
        } catch {
            return showStartupError(error)
        }
        model = Model(store: store)
        monitor = Monitor(store: store)
        monitor.onCapture = { [weak self] in
            self?.model.reload()
            self?.copyFeedback()
        }
        monitor.start()

        panel = PanelController(model: model)
        panel.onPick = { [weak self] item, mode in self?.use(item, mode) }
        panel.onPickMany = { [weak self] items, mode in self?.use(items, mode) }
        panel.onCopy = { [weak self] item in self?.monitor.write(item, plain: false) }
        panel.onCommand = { [weak self] in self?.run($0) }

        hotkey = Hotkey { [weak self] in self?.togglePanel(placement: Settings.placement) }
        hotkey.register(Settings.shortcut)

        settings = SettingsController(hotkey: hotkey, panelModel: model)
        settings.onClear = { [weak self] in self?.clearHistory() }
        settings.onLimits = { [weak self] in
            self?.store.trim(limit: Settings.historyLimit, imageLimit: Settings.imageLimit)
            self?.model.reload()
        }
        settings.onCheckUpdates = { [weak self] in self?.checkForUpdates() }
        updater.onChange = { [weak self] in self?.model.updateVersion = self?.updater.available?.version }
        updater.start()

        setupStatusItem()
        setupMainMenu()
        Settings.firstRun()
        if !AXIsProcessTrusted() { requestAccessibility() }
        if !Settings.clipboardAllowed { explainClipboardAccess() }
        if !launchURLs.isEmpty { application(NSApp, open: launchURLs) }
    }

    /// A damaged or locked history file must not make a login item silently disappear.
    private func showStartupError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "PasteTrove can't open its history"
        alert.informativeText = """
            \(error.localizedDescription)

            The history is in \(Store.directory.path). Move that folder away (or delete it) and open PasteTrove again to start a new history.
            """
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Quit")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([Store.directory])
        }
        NSApp.terminate(nil)
    }

    /// Without "Always Allow", macOS shows an Allow/Deny prompt on every copy PasteTrove reads.
    private func explainClipboardAccess() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Let PasteTrove read the clipboard"
        alert.informativeText = """
            macOS asks for permission each time PasteTrove saves something you copied.

            To stop the prompts: copy something and click Allow once. Then open System Settings → \
            Privacy & Security → Paste from Other Apps, and set PasteTrove to Always Allow.
            """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.openClipboardPrivacySettings()
        }
    }

    /// Opening PasteTrove while it runs (from Spotlight, Finder or Launchpad) shows the panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.show(at: anchor(Settings.placement))
        return false
    }

    /// `pastetrove://open` opens the panel, for Shortcuts, Raycast or scripts.
    /// Optional query items: `layout=plain|rich|grid`, `preview=1`.
    /// `pastetrove://settings` and `pastetrove://about` open those windows.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard panel != nil else {
            launchURLs = urls
            return
        }
        guard let url = urls.first else { return }
        switch url.host {
        case "settings": return openSettings()
        case "about": return openAbout()
        case "open": break
        default: return
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let layout = query.first(where: { $0.name == "layout" })?.value.flatMap(Layout.init(rawValue:)) {
            model.layout = layout
        }
        panel.show(at: anchor(.statusIcon))
        if query.contains(where: { $0.name == "preview" && $0.value == "1" }) {
            panel.togglePreview()
        }
    }

    /// Pastes in tap order, one group at a time; the app reads the clipboard after each ⌘V, so wait before the next write.
    private func use(_ items: [Item], _ mode: PickMode) {
        if items.count == 1 { return use(items[0], mode) }
        guard AXIsProcessTrusted() else { return requestAccessibility() }
        let groups = Model.pasteGroups(items)
        func paste(_ index: Int) {
            guard groups.indices.contains(index) else { return }
            let group = groups[index]
            // Text after earlier text (an image between them) starts on a new line.
            let afterText = groups[..<index].contains { $0[0].isText }
            if group[0].isText, group.count > 1 || afterText {
                monitor.write(text: (afterText ? "\n" : "") + group.map(\.text).joined(separator: "\n"))
            } else {
                monitor.write(group[0], plain: mode == .plain)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.pressCommandV() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { paste(index + 1) }
        }
        paste(0)
    }

    private func use(_ item: Item, _ mode: PickMode) {
        monitor.write(item, plain: mode == .plain)
        guard mode != .copy else { return }
        // Without Accessibility access the item is only copied; you press ⌘V yourself.
        guard AXIsProcessTrusted() else {
            requestAccessibility()
            return
        }
        // Give the previous app a moment to take the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.pressCommandV() }
    }

    /// Pasting means sending ⌘V to another app, which macOS allows only with Accessibility access.
    /// The system prompt shows at most once per launch.
    private func requestAccessibility() {
        guard !askedAccessibility else { return }
        askedAccessibility = true
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cgSessionEventTap)
        }
    }

    private let copySound: NSSound? = {
        let sound = NSSound(named: "Pop")
        sound?.volume = 0.35
        return sound
    }()

    /// Sound plus a flip of the menu bar icon, so a copy is noticed without looking.
    private func copyFeedback() {
        if Settings.playSound {
            copySound?.stop()
            copySound?.play()
        }
        guard let button = statusItem.button else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        // Rotate around the icon's center, not the layer's default bottom-left corner.
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        let flip = CABasicAnimation(keyPath: "transform.rotation.y")
        flip.fromValue = 0
        flip.toValue = 2 * Double.pi
        flip.duration = 0.5
        flip.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(flip, forKey: "flip")
    }

    private func togglePanel(placement: Placement, clicked: Bool = false) {
        panel.toggle(at: anchor(placement), clicked: clicked)
    }

    private func anchor(_ placement: Placement) -> PanelController.Anchor {
        switch placement {
        case .statusIcon: statusItem.button?.window.map { .below($0.frame) } ?? .center
        case .cursor: .cursor
        case .center: .center
        }
    }

    /// Left click opens the panel, like PasteNow. Right click, ⌃-click or ⌥-click opens the menu.
    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
            || event?.modifierFlags.contains(.option) == true
        if wantsMenu {
            statusItem.menu = statusMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel(placement: .statusIcon, clicked: true)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = BrandMark.menuBarImage()
        statusItem.button?.setAccessibilityLabel("PasteTrove")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = statusMenu
        menu.delegate = self
        let items = [
            openItem,
            .separator(),
            NSMenuItem(title: "About PasteTrove", action: #selector(openAbout), keyEquivalent: ""),
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","),
            .separator(),
            pauseItem,
            NSMenuItem(title: "Send Feedback…", action: #selector(sendFeedback), keyEquivalent: ""),
            updatesItem,
            NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit PasteTrove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        for item in items {
            if item.action != #selector(NSApplication.terminate(_:)) { item.target = self }
            menu.addItem(item)
        }
    }

    /// An accessory app has no menu bar, but ⌘C / ⌘V / ⌘A in text fields and ⌘W still need these menu items.
    private func setupMainMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        openItem.title = "Open PasteTrove    \(Settings.shortcut.label)"
        pauseItem.state = monitor.paused ? .on : .off
        let version = updater.available?.version
        updatesItem.title = version.map { "Update to \($0)…" } ?? "Check for Updates…"
        updatesItem.image = version == nil ? nil : NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "Update available")?
            .withSymbolConfiguration(.init(pointSize: 7, weight: .regular).applying(.init(paletteColors: [.systemOrange])))
    }

    @objc private func openPanel() {
        togglePanel(placement: .statusIcon)
    }

    private func run(_ command: PanelCommand) {
        switch command {
        case .about: openAbout()
        case .settings: openSettings()
        case .togglePause: togglePause()
        case .feedback: sendFeedback()
        case .updates: checkForUpdates()
        case .clearHistory: clearHistory()
        case .quit: NSApp.terminate(nil)
        }
    }

    @objc private func openAbout() {
        about.show()
    }

    @objc private func openSettings() {
        settings.show()
    }

    /// Feedback lives on GitHub: new issues for problems and ideas, the roadmap board for what's planned.
    @objc private func sendFeedback() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Send Feedback"
        alert.informativeText = "Report a problem or suggest an idea on GitHub, or see what's planned and in progress."
        alert.addButton(withTitle: "Report or Suggest")
        alert.addButton(withTitle: "See Roadmap")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(AboutController.newIssueURL)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(AboutController.roadmapURL)
        default: break
        }
    }

    /// Offers the update that is already known, or asks GitHub now.
    @objc private func checkForUpdates() {
        if let release = updater.available { updater.offer(release) } else { updater.check(manual: true) }
    }

    @objc private func togglePause() {
        monitor.paused.toggle()
        model.paused = monitor.paused
    }

    @objc private func clearHistory() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned items are kept. This cannot be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.clear()
        model.reload()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
