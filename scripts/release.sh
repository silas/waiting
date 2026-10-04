#!/bin/bash
# Builds a notarized Waiting.app, zips it into $UPDATES_DIR and regenerates the Sparkle appcast
# there, and builds a notarized build/release/Waiting.dmg for the website's download link. Upload
# both with `make upload` afterwards.
#
# The DMG stays out of $UPDATES_DIR because generate_appcast would treat it as another update.
#
# $UPDATES_DIR must keep every past release zip and the current appcast.xml, so generate_appcast
# can keep the history and build deltas. Point it at a persistent directory, not build/.
#
# One-time setup:
#   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys  (EdDSA key → login Keychain)
#   xcrun notarytool store-credentials waiting-notary
set -euo pipefail

cd "$(dirname "$0")/.."

UPDATES_DIR="${UPDATES_DIR:-build/updates}"
NOTARY_PROFILE="${NOTARY_PROFILE:-waiting-notary}"
RELEASE_DIR=build/release
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin

setting() {
    xcodebuild -project mac.xcodeproj -scheme Mac -configuration Release -showBuildSettings 2>/dev/null \
        | awk -v key="$1" '$1 == key { print $3; exit }'
}
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
zip="$UPDATES_DIR/Waiting-$version.zip"

if [[ -e "$zip" ]]; then
    echo "error: $zip already exists. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
    exit 1
fi
if grep -q REPLACE_WITH_GENERATE_KEYS_OUTPUT Mac/Info.plist; then
    echo "error: set SUPublicEDKey in Mac/Info.plist (see generate_keys above)." >&2
    exit 1
fi

echo "Releasing Waiting $version ($build)"
rm -rf "$RELEASE_DIR"
mkdir -p "$RELEASE_DIR" "$UPDATES_DIR"

xcodebuild archive -project mac.xcodeproj -scheme Mac -configuration Release \
    -derivedDataPath build -archivePath "$RELEASE_DIR/Waiting.xcarchive" -quiet
xcodebuild -exportArchive -archivePath "$RELEASE_DIR/Waiting.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$RELEASE_DIR/export" -quiet
app="$RELEASE_DIR/export/Waiting.app"

ditto -c -k --keepParent "$app" "$RELEASE_DIR/notarize.zip"
xcrun notarytool submit "$RELEASE_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$app"
ditto -c -k --keepParent "$app" "$zip"

# Drag-to-install disk image, signed with the same Developer ID as the app
dmg="$RELEASE_DIR/Waiting.dmg"
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application: .*\)$/\1/p')
if [[ -z "$identity" ]]; then
    echo "error: $app isn't signed with a Developer ID Application certificate." >&2
    exit 1
fi
mkdir "$RELEASE_DIR/dmg"
ditto "$app" "$RELEASE_DIR/dmg/Waiting.app"
ln -s /Applications "$RELEASE_DIR/dmg/Applications"
diskutil image create from --format ULFO --volumeName Waiting "$RELEASE_DIR/dmg" "$dmg" >/dev/null
codesign --sign "$identity" --timestamp "$dmg"
xcrun notarytool submit "$dmg" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$dmg"

"$SPARKLE_BIN/generate_appcast" --download-url-prefix https://releases.waiting.dev/ "$UPDATES_DIR"

echo
echo "Built $zip and $dmg. Upload them with: make upload"
