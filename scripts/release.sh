#!/bin/bash
# Builds the release files for the version in Info.plist:
#   dist/PasteTrove-<version>.zip  (used by the Homebrew cask)
#   dist/PasteTrove.dmg            (direct download; same name every release, so "latest" links never break)
# and writes the zip's sha256 into Casks/pastetrove.rb.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=$(plutil -extract CFBundleShortVersionString raw Info.plist)
scripts/build.sh universal
# An ad-hoc build could never update itself (the updater checks the certificate), so a release needs the real one.
[[ "$(codesign -dr - build.noindex/PasteTrove.app 2>&1)" == *"certificate leaf"* ]] \
    || { echo "Not signed with \"PasteTrove Local Signing\": run scripts/create-signing-cert.sh on the release Mac." >&2; exit 1; }
rm -rf dist && mkdir -p dist
ditto -c -k --keepParent build.noindex/PasteTrove.app "dist/PasteTrove-$VERSION.zip"
# Symbols for reading crash reports of this exact build; uploaded with the release, not part of the app.
ditto -c -k --keepParent build.noindex/PasteTrove.dSYM "dist/PasteTrove-$VERSION-dSYM.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build.noindex/PasteTrove.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "PasteTrove $VERSION" -srcfolder "$STAGE" -ov -format UDZO dist/PasteTrove.dmg >/dev/null
SHA=$(shasum -a 256 "dist/PasteTrove-$VERSION.zip" | cut -d' ' -f1)
sed -i '' -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 .*/  sha256 \"$SHA\"/" Casks/pastetrove.rb
echo "OK: dist/PasteTrove-$VERSION.zip ($(du -h "dist/PasteTrove-$VERSION.zip" | cut -f1)), dist/PasteTrove.dmg, dist/PasteTrove-$VERSION-dSYM.zip, cask sha256 $SHA"
