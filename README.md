# Clip

A small, fast clipboard history for macOS. Clip saves everything you copy (text, code, rich text, links, screenshots, files) and brings it back with one click or one shortcut.

- Native Swift and AppKit/SwiftUI. No dependencies, about 1,700 lines of code.
- Lives in the menu bar. Uses almost no CPU when idle.
- History is saved on your Mac and stays after a restart.
- Nothing leaves your Mac. There is no network code.

## Use

Click the Clip icon in the menu bar, or press **⇧⌘V** (you can change it in Settings). Type to search, press **⏎** to paste into the app you were using.

When you copy something, Clip plays a short sound and the menu bar icon flips. You can turn off the sound in Settings.

Right-click the icon (or ⌥-click) for the menu: Settings, Pause Recording, Clear History, Quit.

### Layouts

Pick a layout from the button in the bottom-left corner of the panel, or press ⌘L.

| Layout | Shows |
|---|---|
| Plain List | One line per item. The most items on screen. |
| Rich List | Source app, age, and up to 5 lines of text or a large image thumbnail. |
| Grid View | Cards in two columns. Best for screenshots and images. |

Press **Space** (with an empty search field) or ⌘Y to open a large preview beside the panel.

### Keys

| Key | Action |
|---|---|
| Type | Search (every word must match) |
| ↑ ↓, ⌃N ⌃P | Move selection (← → also move in Grid View) |
| ⌘↑ ⌘↓, Page Up/Down | Jump to top/bottom, move by 10 |
| ⏎ | Paste |
| ⇧⏎ | Paste as plain text |
| ⌘⏎ | Copy only, do not paste |
| ⌘1 … ⌘9 | Paste item 1–9 |
| Space, ⌘Y | Preview |
| ⇥ / ⇧⇥ | Next / previous filter (All, Text, Links, Images, Files, Pinned) |
| ⌘P | Pin or unpin (pinned items stay at the top and are never removed) |
| ⌘⌫ | Delete item |
| ⌘L | Next layout |
| ⌘, | Settings |
| esc | Clear search, then close |

Double-click an item to paste it.

## Install

Requirements: macOS 14 or later, Xcode 15 or later (or the Swift 5.10+ command line tools).

```bash
git clone https://github.com/tawsifahmed/clip.git Clip
cd Clip
./build.sh install    # builds, copies Clip.app to /Applications and starts it
```

`./build.sh` alone builds `build/Clip.app` without installing it.

On first start:

1. macOS asks for **Accessibility** access. Clip needs it to send ⌘V to the app you paste into. Without it, Clip still copies the item, and you press ⌘V yourself.
2. Clip turns on **Launch at login**. You can turn it off in Settings.

The build is signed ad hoc (no Apple developer certificate). After you rebuild, macOS can ask for Accessibility access again. If pasting stops working, remove Clip from System Settings → Privacy & Security → Accessibility and add it again.

## Settings

Open from the gear in the panel, the right-click menu, or ⌘, in the panel.

- **Open Clip**: click the button, then press the new shortcut. It must include ⌘, ⌥ or ⌃. Press esc to cancel.
- **When appears**: where the shortcut opens the panel: near the status icon (default), near the cursor, or in the center of the screen.
- **Layout**: Plain List, Rich List or Grid View.
- **Launch at login** and **Play sound when copying**
- **Keep items**: 500 to 10,000 (default 2,000). **Keep images**: 50 to 500 (default 200). The oldest unpinned items are removed first.
- **Clear History**: removes all unpinned items.

## Privacy

- Clip ignores items that password managers mark as secret or temporary ([nspasteboard.org](http://nspasteboard.org) markers, used by 1Password, Bitwarden, KeePassXC and others).
- History is stored in `~/Library/Application Support/Clip/clip.sqlite`. Delete that file to remove all history.

## How it works

| Part | File | What it does |
|---|---|---|
| Clipboard watcher | `Monitor.swift` | Reads `NSPasteboard.changeCount` every 0.25 s (macOS has no change event). Saves new content with the app it came from. Writes items back for pasting. |
| Storage | `Store.swift` | SQLite. `items` has the small rows the list needs. `reps` has the raw clipboard data per type (plain text, RTF, HTML, PNG, file URLs), loaded only to preview or paste. Same content copied again moves to the top instead of making a duplicate (SHA-256 key). |
| Panel | `Panel.swift` | A non-activating floating panel, so the app you came from stays active and receives the paste. Three layouts, preview window, in-memory search. |
| Shortcut and settings | `Settings.swift` | Global hotkey through Carbon `RegisterEventHotKey`, shortcut recorder, limits, launch at login through `SMAppService`. |
| App | `main.swift` | Menu bar icon, copy sound and icon flip, and the ⌘V key event that pastes. |

## License

[MIT](LICENSE)
