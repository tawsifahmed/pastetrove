import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var store: Store!
    private var model: Model!
    private var monitor: Monitor!
    private var panel: PanelController!
    private var hotkey: Hotkey!
    private var settings: SettingsController!
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private let openItem = NSMenuItem(title: "Open Clip", action: #selector(openPanel), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Recording", action: #selector(togglePause), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            store = try Store()
        } catch {
            fatalError("Clip: \(error.localizedDescription)")
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
        panel.onSettings = { [weak self] in self?.settings.show() }

        hotkey = Hotkey { [weak self] in self?.togglePanel(placement: Settings.placement) }
        hotkey.register(Settings.shortcut)

        settings = SettingsController(hotkey: hotkey, panelModel: model)
        settings.onClear = { [weak self] in self?.clearHistory() }
        settings.onLimits = { [weak self] in
            self?.store.trim(limit: Settings.historyLimit, imageLimit: Settings.imageLimit)
            self?.model.reload()
        }

        setupStatusItem()
        setupMainMenu()
        Settings.firstRun()
        if !AXIsProcessTrusted() { requestAccessibility() }
    }

    private func use(_ item: Item, _ mode: PickMode) {
        monitor.write(item, plain: mode == .plain)
        model.reload()
        guard mode != .copy, requestAccessibility() else { return }
        // Give the previous app a moment to take the keyboard back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { Self.pressCommandV() }
    }

    /// Pasting means sending ⌘V to another app, which macOS allows only with Accessibility access.
    @discardableResult
    private func requestAccessibility() -> Bool {
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

    private func togglePanel(placement: Placement) {
        let anchor: PanelController.Anchor
        switch placement {
        case .statusIcon: anchor = statusItem.button?.window.map { .below($0.frame) } ?? .center
        case .cursor: anchor = .cursor
        case .center: anchor = .center
        }
        panel.toggle(at: anchor)
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
            togglePanel(placement: .statusIcon)
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Clip")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        let menu = statusMenu
        menu.delegate = self
        let items = [
            openItem,
            NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","),
            .separator(),
            pauseItem,
            NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: ""),
            .separator(),
            NSMenuItem(title: "Quit Clip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
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
        openItem.title = "Open Clip    \(Settings.shortcut.label)"
        pauseItem.state = monitor.paused ? .on : .off
    }

    @objc private func openPanel() {
        togglePanel(placement: .statusIcon)
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func togglePause() {
        monitor.paused.toggle()
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
