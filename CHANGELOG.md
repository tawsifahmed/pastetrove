# Changelog

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
