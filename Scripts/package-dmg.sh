#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/Xavucontrol"
PROJECT_PATH="$PROJECT_DIR/Xavucontrol.xcodeproj"
SCHEME="Xavucontrol"
CONFIGURATION="Release"
APP_NAME="Xavucontrol"
VOLUME_NAME="Xavucontrol"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_BUILD_DIR="$ROOT_DIR/Packaging/build"
DERIVED_DATA_DIR="$PACKAGE_BUILD_DIR/DerivedData"
STAGING_DIR="$PACKAGE_BUILD_DIR/staging"
TEMP_DMG="$PACKAGE_BUILD_DIR/${APP_NAME}-temp.dmg"
ICON_PATH="$ROOT_DIR/Xavucontrol/Xavucontrol/Assets.xcassets/AppIcon.appiconset/AppIcon-512.png"
BACKGROUND_RENDERER="$ROOT_DIR/scripts/render-dmg-background.swift"
SWIFT_MODULE_CACHE_DIR="$PACKAGE_BUILD_DIR/SwiftModuleCache"
SKIP_BUILD=0
APP_PATH=""

usage() {
  cat <<USAGE
Usage: scripts/package-dmg.sh [options]

Options:
  --skip-build          Use an existing app bundle instead of building Release.
  --app <path>          App bundle to package. Implies --skip-build.
  --help                Show this help.

Output:
  dist/Xavucontrol-<version>-beta.dmg
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build)
      SKIP_BUILD=1
      shift
      ;;
    --app)
      SKIP_BUILD=1
      APP_PATH="${2:-}"
      if [[ -z "$APP_PATH" ]]; then
        echo "--app requires a path" >&2
        exit 2
      fi
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    clean build
  APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
elif [[ -z "$APP_PATH" ]]; then
  APP_PATH="$DERIVED_DATA_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  echo "Build first or pass --app /path/to/Xavucontrol.app" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
RELEASE_LABEL="${VERSION} beta"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-beta.dmg"

rm -rf "$STAGING_DIR"
rm -f "$TEMP_DMG" "$DMG_PATH"
mkdir -p "$STAGING_DIR/.background" "$DIST_DIR" "$PACKAGE_BUILD_DIR"

ditto "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
mkdir -p "$SWIFT_MODULE_CACHE_DIR"
xcrun swift -module-cache-path "$SWIFT_MODULE_CACHE_DIR" "$BACKGROUND_RENDERER" "$STAGING_DIR/.background/background.png" "$ICON_PATH" "$RELEASE_LABEL"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -format UDRW \
  -quiet \
  "$TEMP_DMG"

ATTACH_OUTPUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TEMP_DMG")"
DEVICE="$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/Apple_HFS/ {print $1; exit}')"
MOUNT_DIR="/Volumes/$VOLUME_NAME"

cleanup() {
  if [[ -n "${DEVICE:-}" ]]; then
    hdiutil detach "$DEVICE" -quiet >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

if [[ ! -d "$MOUNT_DIR" ]]; then
  echo "Mounted DMG volume not found: $MOUNT_DIR" >&2
  exit 1
fi

osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 840, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set background picture of viewOptions to file ".background:background.png"
    set position of item "$APP_NAME.app" of container window to {190, 225}
    set position of item "Applications" of container window to {530, 225}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEVICE" -quiet
DEVICE=""

hdiutil convert "$TEMP_DMG" \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" \
  -quiet

rm -f "$TEMP_DMG"
echo "Created $DMG_PATH"
