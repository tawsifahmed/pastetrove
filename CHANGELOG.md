# Changelog

## 0.1.4 - 2026-11-25

### Features
- **paste:** ⏎, ⇧⏎, ⌘⏎, double-click and right-click Paste flash "Copied" on the item before the panel closes, like ⌘1–⌘0, so you see which item was used.
- **lists:** A thin outline fades in under the pointer in all three layouts.

## 0.1.3 - 2026-11-25

### Features
- **updates:** PasteTrove updates itself. Once a day it checks GitHub for a new version and asks before installing. Install & Relaunch downloads it, checks the checksum and that it is signed by the PasteTrove developer, then swaps it in and relaunches. Turn the daily check off in Settings, or use Check Now there.
- **size:** The app is about half as big on disk (3.3 MB to 1.7 MB) and smaller to download (under 1 MB). Search speed is unchanged.

### Fixes
- **open:** Opening PasteTrove while it runs (from Spotlight, Finder or Launchpad) shows the panel. Before, nothing happened.
- **links:** A `pastetrove://` link that starts PasteTrove no longer crashes it. The link opens the panel or Settings once the app is ready.
- **build:** Spotlight shows one PasteTrove on a Mac that builds the app from source. Local builds go to `build.noindex/`.

## 0.1.2 - 2026-11-24

### Features
- **panel:** Opens where you left off, with the same scroll position and selection. After a new copy, it opens at the top with the new item selected.
- **paste:** Pasting an item keeps its place in the history.
- **lists:** Older items show short ages: 1w, 1mo and 1y.

### Fixes
- **panel:** Readable in Light mode, and the first row no longer touches the top edge when the panel opens.
- **search:** Much faster with a large history: about 23 ms per key at 10,000 items (was 287 ms).
- **speed:** Copies made while the panel is closed cost almost nothing. Pasting a large image no longer builds a large TIFF copy each time. ⌘1–⌘0 writes the clipboard once.
- **keys:** Pressing the shortcut twice quickly opens the panel again.
- **lists:** The "Copied" outline matches the row corners in Plain List. File rows no longer read the disk on every redraw. Counts say "1 item" and "1 line".

## 0.1.1 - 2026-11-24

### Features
- **panel:** Near-black glass background, so colorful windows behind no longer tint the panel.
- **panel:** Resizable: drag any edge, and the size is remembered. Grid View adds columns as the panel gets wider.
- **lists:** Bigger rows, icons and text. Images fill a fixed rounded box (cropped to fit), so tall and wide screenshots line up.
- **keys:** ⌘0 pastes the tenth visible item. While ⌘ is held, the numbers glow and other items fade back. ⌘1–9 and ⌘0 show the "Copied" flash before pasting.
- **links:** `pastetrove://settings` and `pastetrove://about` open those windows.

### Fixes
- **paste:** A damaged item never empties your clipboard, and a failed save is undone completely.
- **panel:** The selection stays on the same item when a copy arrives while the panel is open.
- **search:** Return commits Japanese, Chinese and other input-method text instead of pasting.
- **keys:** ⌘+number no longer pastes into another app if you switch apps during the flash.
- **speed:** Lighter history loading, a memory-bounded image cache, cached file icons, no thumbnails for very large files, lighter database writes.
- **startup:** If the history file can't be opened, PasteTrove explains it instead of quitting silently.

## 0.1.0 - 2026-11-24

First release.

### Features
- **history:** Saves text, rich text, code, Markdown, colors, links, images and files, with the app each item came from. History stays after a restart.
- **panel:** Opens under the menu bar icon or with ⇧⌘V. Type to search, ⏎ to paste into the app you were using, ⇧⏎ to paste as plain text.
- **layouts:** Plain List, Rich List and Grid View, plus a large preview window (Space or ⌘Y).
- **filters:** All, Text, Code, Links, Images, Files and Pinned. Code, Markdown and color values are recognized when they are saved.
- **keys:** Hold ⌘ to show 1–9 on the visible items and paste one. ⌘C copies with a "Copied" flash. ⌘P pins, ⌘⌫ deletes.
- **menus:** Right-click an item for Paste, Copy, Preview, Pin, Open Link, Show in Finder and Delete. The gear menu has About, Settings, Pause Recording, Check for Updates, Clear History and Quit.
- **settings:** Changeable shortcut, where the panel appears, layout, launch at login, copy sound, history limits (with a confirmation before a lower limit deletes items).
- **privacy:** Skips items that password managers mark as secret. Everything stays on this Mac.
- **install:** Universal build (Apple silicon and Intel), disk image, and a Homebrew cask in this repository.
