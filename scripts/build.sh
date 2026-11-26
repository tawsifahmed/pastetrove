#!/bin/bash
# scripts/build.sh            build build.noindex/PasteTrove.app for this Mac
# scripts/build.sh install    build, copy to /Applications, relaunch
# scripts/build.sh universal  build for Apple silicon and Intel (used by release.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
ARCH_FLAGS=()
[[ "${1:-}" == "universal" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}"
BIN="$(swift build -c release "${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}" --show-bin-path)/PasteTrove"
# ".noindex" keeps this copy out of Spotlight, so only the installed app shows there.
APP=build.noindex/PasteTrove.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PasteTrove"
# Ship without the symbol table (about 60% of the binary). The symbols go to a dSYM next to the app,
# which is not shipped and turns addresses in crash reports back into function names.
rm -rf build.noindex/PasteTrove.dSYM
dsymutil "$BIN" -o build.noindex/PasteTrove.dSYM
strip -x "$APP/Contents/MacOS/PasteTrove"
cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# Sign with the local certificate when it exists (stable permissions), otherwise ad hoc.
IDENTITY=-
security find-certificate -c "PasteTrove Local Signing" >/dev/null 2>&1 && IDENTITY="PasteTrove Local Signing"
# Hardened runtime: no injected libraries, so no other program can borrow PasteTrove's Accessibility access.
codesign --force --options runtime -s "$IDENTITY" --identifier io.github.tawsifahmed.PasteTrove "$APP"
if [[ "${1:-}" == "install" ]]; then
    pkill -x PasteTrove && sleep 1 || true
    rm -rf /Applications/PasteTrove.app && cp -R "$APP" /Applications/
    open /Applications/PasteTrove.app
fi
echo "OK: $APP"
