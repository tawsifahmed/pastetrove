#!/bin/bash
# ./build.sh           build build/Clip.app
# ./build.sh install   build, copy to /Applications, relaunch
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/Clip.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Clip" "$APP/Contents/MacOS/Clip"
cp Info.plist "$APP/Contents/"
codesign --force -s - --identifier dev.clip.Clip "$APP"
if [[ "${1:-}" == "install" ]]; then
    pkill -x Clip && sleep 1 || true
    rm -rf /Applications/Clip.app && cp -R "$APP" /Applications/
    open /Applications/Clip.app
fi
echo "OK: $APP"
