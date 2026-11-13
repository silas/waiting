#!/bin/bash
# Builds a notarized Waiting.app, zips it into build/release/updates with a Sparkle appcast, and
# builds a notarized build/release/Waiting.dmg. Publish all three as a GitHub release with
# `make upload` afterwards.
#
# Each release is a GitHub release tagged v<version>. The app's feed is the latest release's
# appcast.xml (https://github.com/silas/waiting/releases/latest/download/appcast.xml), and its
# enclosure points at that release's zip. generate_appcast gives every item the same download URL
# prefix, so the appcast holds only the newest version (--maximum-versions 1) and is generated
# fresh each time. The DMG stays out of the updates directory because generate_appcast would treat
# it as another update. Delta updates are off: the app is only a few MB zipped.
#
# One-time setup:
#   build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys  (EdDSA key → login Keychain)
#   xcrun notarytool store-credentials waiting-notary
#   gh auth login
set -euo pipefail

cd "$(dirname "$0")/.."

REPO=silas/waiting
NOTARY_PROFILE="${NOTARY_PROFILE:-waiting-notary}"
RELEASE_DIR=build/release
UPDATES_DIR="$RELEASE_DIR/updates"
SPARKLE_BIN=build/SourcePackages/artifacts/sparkle/Sparkle/bin

setting() {
    xcodebuild -project mac.xcodeproj -scheme Mac -configuration Release -showBuildSettings 2>/dev/null \
        | awk -v key="$1" '$1 == key { print $3; exit }'
}
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
tag="v$version"
zip="$UPDATES_DIR/Waiting-$version.zip"

if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
    echo "error: release $tag already exists. Bump MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
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

"$SPARKLE_BIN/generate_appcast" --maximum-versions 1 --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$REPO/releases/download/$tag/" "$UPDATES_DIR"

echo
echo "Built $zip and $dmg. Publish them with: make upload"
