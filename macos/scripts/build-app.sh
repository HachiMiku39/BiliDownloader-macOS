#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="${1:-$PROJECT/dist}"
mkdir -p "$DESTINATION"
DESTINATION="$(cd "$DESTINATION" && pwd)"
# Select a full Xcode locally if Command Line Tools is the global default.
# This never changes xcode-select's machine-wide setting.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    for candidate in /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            export DEVELOPER_DIR="$candidate/Contents/Developer"
            break
        fi
    done
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PROJECT/.build/ModuleCache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
if [[ -n "${BILIMAC_BINARY:-}" ]]; then
    BINARY="$BILIMAC_BINARY"
else
    xcrun swift build --package-path "$PROJECT" -c release
    BIN_DIR="$(xcrun swift build --package-path "$PROJECT" -c release --show-bin-path)"
    BINARY="$BIN_DIR/BiliMac"
fi
if [[ -e "$DESTINATION/BiliDownloader.app" ]]; then
    echo "Destination already exists: $DESTINATION/BiliDownloader.app. Choose an empty output directory." >&2
    exit 1
fi
# Build/sign away from cloud-synced folders, which may add FinderInfo while
# codesign is running. Archives are produced from this verified staging copy.
STAGING="$(mktemp -d)"
trap 'rm -r "$STAGING"' EXIT
APP="$STAGING/BiliDownloader.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/BiliMac"
cp "$PROJECT/Info.plist" "$APP/Contents/Info.plist"
cp "$PROJECT/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/"
cp "$PROJECT/../LICENSE" "$APP/Contents/Resources/LICENSE"
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
xcrun swift "$PROJECT/scripts/make-icon.swift" "$STAGING/AppIcon.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$STAGING/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$STAGING/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -r "$ICONSET" "$STAGING/AppIcon.png"
# Ad-hoc signing allows local execution. Distribution requires the owner's
# Developer ID certificate and notarization; this script uses no credentials.
for attribute in com.apple.FinderInfo com.apple.ResourceFork; do
    xattr -dr "$attribute" "$APP" 2>/dev/null || true
done
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DESTINATION/BiliDownloader-macOS.zip"
ln -s /Applications "$STAGING/Applications"
cp "$PROJECT/../MACOS.md" "$STAGING/使用说明.md"
hdiutil create -volname BiliDownloader -srcfolder "$STAGING" -format UDZO "$DESTINATION/BiliDownloader-macOS.dmg" >/dev/null
ditto --norsrc --noextattr "$APP" "$DESTINATION/BiliDownloader.app"
echo "Built $DESTINATION/BiliDownloader.app, .zip and .dmg"
