# Security policy

PasteTrove stores everything you copy, so security reports are taken seriously.

## Report a vulnerability

Please do not open a public issue for a security problem.

Report it privately on GitHub: open the **Security** tab of this repository and click **Report a vulnerability**. You get an answer within 7 days.

Include the PasteTrove version (from **About PasteTrove**), your macOS version, and the steps to reproduce the problem.

## Supported versions

Only the latest release gets security fixes. PasteTrove offers new versions itself (Settings → Check Now), or update with `brew upgrade --cask pastetrove`, or download the latest [PasteTrove.dmg](https://github.com/tawsifahmed/pastetrove/releases/latest/download/PasteTrove.dmg).

## How PasteTrove handles your data

- History is stored only on your Mac, in `~/Library/Application Support/PasteTrove/history.sqlite`. PasteTrove has no account and no sync.
- The only network request is the update check: once a day (and when you choose Check Now), PasteTrove asks `api.github.com` for the latest release. It sends nothing from your history. Turn it off in Settings → Check for updates automatically.
- An update is installed only when the download matches the sha256 checksum GitHub publishes for it and macOS confirms the new app meets the running app's designated requirement: the same bundle ID and the same signing certificate. Otherwise the current app stays as it is.
- Items that password managers mark as secret or temporary ([nspasteboard.org](http://nspasteboard.org) markers) are never saved.
- PasteTrove needs Accessibility access only to press ⌘V in the app you paste into.
