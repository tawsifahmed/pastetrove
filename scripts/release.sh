#!/bin/bash
# Builds the release files for the version in Info.plist:
#   dist/PasteTrove-<version>.zip  (used by the Homebrew cask)
#   dist/PasteTrove.dmg            (direct download; same name every release, so "latest" links never break)
# and writes the zip's sha256 into Casks/pastetrove.rb.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
scripts/build.sh universal
rm -rf dist && mkdir -p dist
ditto -c -k --keepParent build/PasteTrove.app "dist/PasteTrove-$VERSION.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build/PasteTrove.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PasteTrove $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/PasteTrove.dmg >/dev/null
SHA=$(shasum -a 256 "dist/PasteTrove-$VERSION.zip" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 .*/  sha256 \"$SHA\"/" Casks/pastetrove.rb
echo "OK: dist/PasteTrove-$VERSION.zip ($(du -h "dist/PasteTrove-$VERSION.zip" | cut -f1)), dist/PasteTrove.dmg, cask sha256 $SHA"
