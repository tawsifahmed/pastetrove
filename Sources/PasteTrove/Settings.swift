import AppKit
import Carbon
import ServiceManagement
import SwiftUI

enum Settings {
    private static let defaults = UserDefaults.standard

    static var historyLimit: Int {
        get { defaults.object(forKey: "historyLimit") as? Int ?? 2000 }
        set { defaults.set(newValue, forKey: "historyLimit") }
    }

    static var imageLimit: Int {
        get { defaults.object(forKey: "imageLimit") as? Int ?? 200 }
        set { defaults.set(newValue, forKey: "imageLimit") }
    }

    static var shortcut: Shortcut {
        get {
            defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) } ?? .default
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: "shortcut") }
    }

    /// The panel's size, remembered after you resize it.
    static var panelSize: NSSize {
        get {
            let width = defaults.double(forKey: "panelWidth"), height = defaults.double(forKey: "panelHeight")
            return width > 0 && height > 0 ? NSSize(width: width, height: height) : NSSize(width: 460, height: 820)
        }
        set {
            defaults.set(newValue.width, forKey: "panelWidth")
            defaults.set(newValue.height, forKey: "panelHeight")
        }
    }

    /// Hold ⌘, tap numbers, let go to paste them all. Off: ⌘ + number pastes at once.
    static var multiPaste: Bool {
        get { defaults.bool(forKey: "multiPaste") }
        set { defaults.set(newValue, forKey: "multiPaste") }
    }

    static var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    static var layout: Layout {
        get { defaults.string(forKey: "layout").flatMap(Layout.init(rawValue:)) ?? .grid }
        set { defaults.set(newValue.rawValue, forKey: "layout") }
    }

    static var placement: Placement {
        get { defaults.string(forKey: "placement").flatMap(Placement.init(rawValue:)) ?? .statusIcon }
        set { defaults.set(newValue.rawValue, forKey: "placement") }
    }

    /// Checks GitHub once a day for a newer version.
    static var autoUpdate: Bool {
        get { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoUpdate") }
    }

    /// A version the person chose to skip; automatic checks stay quiet about it.
    static var skippedVersion: String? {
        get { defaults.string(forKey: "skippedVersion") }
        set { defaults.set(newValue, forKey: "skippedVersion") }
    }

    static var lastUpdateCheck: Double {
        get { defaults.double(forKey: "lastUpdateCheck") }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    /// macOS 15.4+ asks before every programmatic clipboard read unless the user picks "Always Allow".
    static var clipboardAllowed: Bool {
        if #available(macOS 15.4, *) {
            return NSPasteboard.general.accessBehavior == .alwaysAllow
        }
        return true
    }

    static func openClipboardPrivacySettings() {
        let url = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Pasteboard"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }

    /// Turns on launch at login the first time the app runs, so history is there after a restart.
    static func firstRun() {
        guard !defaults.bool(forKey: "didFirstRun") else { return }
        defaults.set(true, forKey: "didFirstRun")
        try? SMAppService.mainApp.register()
    }
}

/// Where the panel opens when the shortcut is pressed. A click on the status icon always opens it below the icon.
enum Placement: String, CaseIterable {
    case statusIcon, cursor, center

    var title: String {
        switch self {
        case .statusIcon: "Near Status Icon"
        case .cursor: "Near Cursor"
        case .center: "Center of Screen"
        }
    }
}

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier flags (cmdKey, shiftKey, ...).
    var modifiers: UInt32
    var key: String

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), key: "V")

    var label: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + key
    }
}

extension Shortcut {
    /// Builds a shortcut from a key press. Needs ⌘, ⌥ or ⌃ so plain typing never opens the panel.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        guard mods != 0 else { return nil }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        let key = names[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased() ?? "?"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, key: key)
    }
}

/// System-wide hotkey through Carbon, which still is the only public API that works without Accessibility access.
final class Hotkey {
    private static var action: (() -> Void)?
    private var ref: EventHotKeyRef?

    init(action: @escaping () -> Void) {
        Hotkey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Hotkey.action?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x5054_5256), id: 1)
        return RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

final class SettingsController: NSObject, ObservableObject, NSWindowDelegate {
    @Published var shortcut = Settings.shortcut
    @Published var recording = false
    @Published var shortcutError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var historyLimit = Settings.historyLimit {
        didSet { Settings.historyLimit = historyLimit; onLimits?() }
    }
    @Published var imageLimit = Settings.imageLimit {
        didSet { Settings.imageLimit = imageLimit; onLimits?() }
    }
    @Published var placement = Settings.placement {
        didSet { Settings.placement = placement }
    }
    @Published var playSound = Settings.playSound {
        didSet { Settings.playSound = playSound }
    }
    @Published var multiPaste = Settings.multiPaste {
        didSet { Settings.multiPaste = multiPaste }
    }
    @Published var clipboardAllowed = Settings.clipboardAllowed
    @Published var autoUpdate = Settings.autoUpdate {
        didSet { Settings.autoUpdate = autoUpdate }
    }

    var onClear: (() -> Void)?
    var onLimits: (() -> Void)?
    var onCheckUpdates: (() -> Void)?

    private let hotkey: Hotkey
    private let panelModel: Model
    private var window: NSWindow?
    private var keyMonitor: Any?

    init(hotkey: Hotkey, panelModel: Model) {
        self.hotkey = hotkey
        self.panelModel = panelModel
    }

    func show() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        clipboardAllowed = Settings.clipboardAllowed
        autoUpdate = Settings.autoUpdate
        if window == nil {
            let view = SettingsView(model: self, panel: panelModel)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "PasteTrove Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            self.window = window
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// A lower limit deletes the oldest unpinned items, so it asks first. `images` picks the image limit.
    func setLimit(_ value: Int, images: Bool) {
        let current = images ? imageLimit : historyLimit
        let extra = panelModel.store.unpinnedCount(kind: images ? .image : nil) - value
        if value < current, extra > 0 {
            let alert = NSAlert()
            alert.messageText = "Delete \(extra) older \(images ? "images" : "items")?"
            alert.informativeText = "PasteTrove keeps \(value) \(images ? "images" : "items") now. The oldest unpinned ones above that are deleted. Pinned items are kept. This cannot be undone."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        if images { imageLimit = value } else { historyLimit = value }
    }

    func setLaunchAtLogin(_ on: Bool) {
        if on {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func startRecording() {
        guard !recording else { return }
        recording = true
        shortcutError = nil
        // Free the current combo so pressing it again records it instead of opening the panel.
        hotkey.unregister()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.record(event)
            return nil
        }
    }

    private func record(_ event: NSEvent) {
        if Int(event.keyCode) != kVK_Escape {
            guard let new = Shortcut(event: event) else {
                shortcutError = "Use ⌘, ⌥ or ⌃ with a key."
                return
            }
            if hotkey.register(new) {
                shortcut = new
                Settings.shortcut = new
            } else {
                shortcutError = "\(new.label) is already used by another app."
            }
        }
        stopRecording()
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = false
        hotkey.register(shortcut)
    }

    func windowWillClose(_ notification: Notification) {
        if recording { stopRecording() }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsController
    @ObservedObject var panel: Model

    var body: some View {
        Form {
            Section {
                LabeledContent("Open PasteTrove") {
                    Button(model.recording ? "Press new shortcut…" : model.shortcut.label) { model.startRecording() }
                        .frame(minWidth: 150)
                }
                if let error = model.shortcutError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Picker("When appears", selection: $model.placement) {
                    ForEach(Placement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Layout", selection: $panel.layout) {
                    ForEach(Layout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent("Clipboard access") {
                    if model.clipboardAllowed {
                        Label("Always Allow", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Set to Always Allow…") { Settings.openClipboardPrivacySettings() }
                    }
                }
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Play sound when copying", isOn: $model.playSound)
                Toggle(isOn: $model.multiPaste) {
                    Text("Paste several at once")
                    Text("Hold ⌘, tap numbers or click items, then let go of ⌘ to paste them in order.")
                }
                Toggle(isOn: $model.autoUpdate) {
                    Text("Check for updates automatically")
                    Text("Once a day, from GitHub. Nothing from your clipboard is sent.")
                }
                LabeledContent("Version \(Updater.current)") {
                    Button("Check Now") { model.onCheckUpdates?() }
                }
            }
            Section("History") {
                Picker("Keep items", selection: Binding(get: { model.historyLimit }, set: { model.setLimit($0, images: false) })) {
                    ForEach([500, 1000, 2000, 5000, 10000], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Keep images", selection: Binding(get: { model.imageLimit }, set: { model.setLimit($0, images: true) })) {
                    ForEach([50, 100, 200, 500], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Pinned items", value: "Always kept")
                Button("Clear History…", role: .destructive) { model.onClear?() }
            }
            Section {
                Text("History is saved on this Mac and stays after a restart. Items that password managers mark as secret are never saved. To paste into other apps, PasteTrove needs Accessibility access: System Settings → Privacy & Security → Accessibility.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }
}
