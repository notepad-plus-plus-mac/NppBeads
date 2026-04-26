#!/bin/bash
#
# Build, sign, and package the standalone Beads.app for distribution.
#
# Mirrors the layout of notepad-plus-plus-macos/tools/build-release.sh:
#   - Universal Release build of the .app lands in   build-release/
#   - Signed DMG lands in                            downloads/
#   - tools/build-release.sh is the single entry point
#
# Notarization is intentionally NOT in this script — it requires Apple ID
# credentials and is best kept in a separate notarize step you run after
# testing the DMG locally and deciding it's ready to ship publicly.
#
# Prerequisites:
#   1. Developer ID Application certificate installed in Keychain.
#      (For ad-hoc local-only builds, the script falls back to "-".)
#
# Usage:
#   ./tools/build-release.sh
#
# Environment variables (optional):
#   SIGNING_IDENTITY  - override signing identity (default: auto-detect
#                       Developer ID Application from Keychain; ad-hoc
#                       fallback if none found)
#

set -e

# ── Configuration ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build-release"
DOWNLOADS_DIR="$PROJECT_DIR/downloads"
ENTITLEMENTS="$PROJECT_DIR/shell-app/Beads.entitlements"

APP_NAME="Beads"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

# Read version from CMakeLists so this stays in sync with the source of
# truth (no separate manifest to forget).
APP_VERSION=$(grep -E '^\s*set\s*\(\s*BEADS_APP_VERSION\s+"' "$PROJECT_DIR/CMakeLists.txt" \
              | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "$APP_VERSION" ] && APP_VERSION="1.0.0"

DMG_NAME="${APP_NAME}v${APP_VERSION}.dmg"
DMG_OUT="$DOWNLOADS_DIR/$DMG_NAME"

# Auto-detect signing identity (same logic as the host's build-release.sh).
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning \
                       | grep "Developer ID Application" | head -1 \
                       | sed 's/.*"\(.*\)".*/\1/')
fi

# Ad-hoc fallback. Result will only run on this machine but is enough
# for local iterative testing.
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "WARNING: No Developer ID Application certificate found — using ad-hoc signature."
    echo "         The resulting DMG will only run on THIS Mac."
    SIGNING_IDENTITY="-"
fi

log()  { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
err()  { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ── 0. Regenerate DMG background image ──────────────────────────────────────
#
# The Python generator owns the canonical icon-position constants. The
# AppleScript in step 3 mirrors them (must stay in sync). Regenerating
# every run means nobody ships a stale background by accident.

log "Regenerating DMG background image"
/usr/bin/env python3 "$PROJECT_DIR/tools/generate-dmg-background.py" >/dev/null

# ── 1. Build (Release, universal arm64+x86_64) ───────────────────────────────

log "Building $APP_NAME.app (Release, arm64+x86_64) → $BUILD_DIR"

mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Skip the plugin target. The plugin has its own iterative build path
# (`build/` for Debug); the standalone gets its own Release-only
# directory to mirror the host's pattern.
cmake "$PROJECT_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DNPPBEADS_BUILD_PLUGIN=OFF \
    -DNPPBEADS_BUILD_APP=ON \
    >/dev/null

cmake --build . --target Beads --config Release -- -j"$(sysctl -n hw.ncpu)"

[ -d "$APP_BUNDLE" ] || err "Build did not produce $APP_BUNDLE"

# Strip debug symbols and any local symbol-table entries from the binary.
# `-x` keeps only globally-exported symbols (which AppKit needs for ObjC
# class lookup). The Release compile already passed -Os and the link
# already passed -dead_strip; this is the last layer of size reduction.
log "Stripping debug + local symbols"
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# ── 2. Codesign the app ──────────────────────────────────────────────────────

log "Code-signing $APP_NAME.app with hardened runtime"
codesign --force --deep --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGNING_IDENTITY" \
    "$APP_BUNDLE" 2>&1 | grep -vE "replacing existing signature$" || true

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -3

# ── 3. Build the DMG (with custom background + icon layout) ─────────────────
#
# Multi-step recipe ported from the host's build-release.sh:
#   3a. Force-refresh the bundled DMG background TIFF (dyld weirdness
#       otherwise picks up the previous one if the same path mounted before).
#   3b. Stage the app + create a writable UDRW image.
#   3c. Mount, add Applications symlink (must be added AFTER mount because
#       hdiutil -srcfolder dereferences symlinks at create time).
#   3d. Drive Finder via AppleScript to set window bounds, hide chrome,
#       set background image (read from inside the bundle), pin icon
#       positions. Without this step the DMG opens as a generic Finder
#       window with auto-arranged icons and no background.
#   3e. Hide / remove OS metadata that would otherwise leak into the DMG
#       window for users with "Show Hidden Files" enabled.
#   3f. ditto-restage from the mounted UDRW into a clean directory, then
#       hdiutil create -format UDZO from that. This produces a final
#       compressed DMG that preserves .DS_Store + chflags + the
#       Applications symlink.

log "Packaging $DMG_NAME → $DOWNLOADS_DIR"
mkdir -p "$DOWNLOADS_DIR"
rm -f "$DMG_OUT"

VOLUME_NAME="$APP_NAME"
MOUNT_POINT="/Volumes/$VOLUME_NAME"
DMG_TMP="/tmp/beads_dmg_rw_$$.dmg"
DMG_STAGE="/tmp/beads_dmg_stage_$$"
DMG_RESTAGE="/tmp/beads_dmg_restage_$$"

# Best-effort cleanup if a prior run left mounts behind.
hdiutil detach "$MOUNT_POINT" -force >/dev/null 2>&1 || true

# 3a. Force-refresh the bundled background TIFF. macOS Resources/ files
# can sometimes get cached at the codesign layer if the same path was
# signed before; copying explicitly guarantees the just-regenerated tiff
# is what ends up in the bundle for this DMG run.
cp -f "$PROJECT_DIR/resources/dmg-background.tiff" \
      "$APP_BUNDLE/Contents/Resources/dmg-background.tiff"

# 3b. Stage the app + size the writable image. +20MB headroom over the
# raw bundle size accommodates HFS+ overhead on small images.
rm -rf "$DMG_STAGE" && mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/"

STAGE_KB=$(du -sk "$DMG_STAGE" | awk '{print $1}')
DMG_SIZE_MB=$(( STAGE_KB / 1024 + 20 ))

hdiutil create \
    -srcfolder "$DMG_STAGE" \
    -volname "$VOLUME_NAME" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -format UDRW \
    -size ${DMG_SIZE_MB}m \
    "$DMG_TMP" >/dev/null

# 3c. Mount + add Applications symlink.
DEVICE=$(hdiutil attach -readwrite -noverify -noautoopen \
         -mountpoint "$MOUNT_POINT" "$DMG_TMP" \
         | grep -E '^/dev/' | head -1 | awk '{print $1}')
ln -s /Applications "$MOUNT_POINT/Applications"

# 3d. AppleScript: set the window's view options, background, icon
# positions. Coordinates here MUST match
# tools/generate-dmg-background.py (APP_ICON_CENTER / APPS_ICON_CENTER).
# Window bounds give a 600x680 viewport; the 600x640 background sits
# at the top with a small transparent strip below — that prevents a
# scrollbar and centers the Applications folder visually inside the
# lavender panel. Background path is HFS-style, relative to the
# volume root, pointing inside the app bundle.
log "Setting DMG window layout"
# Defensive close: Finder caches window state per volume name across
# detach/remount cycles. If a previous build left bounds cached for
# "Beads" — say, because an earlier DMG was opened by hand and resized —
# `open disk` here would re-use those bounds even though the .DS_Store
# is fresh, and `set the bounds to ...` further down can race with the
# cached state. Closing any pre-existing window for this volume before
# `open` guarantees a clean slate.
/usr/bin/osascript <<DEFENSIVECLOSE >/dev/null 2>&1 || true
tell application "Finder"
    try
        close (every window whose target is disk "${VOLUME_NAME}")
    end try
end tell
DEFENSIVECLOSE

/usr/bin/osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "${VOLUME_NAME}"
        open
        tell container window
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            set the bounds to {200, 120, 800, 800}
        end tell
        set theViewOptions to the icon view options of container window
        tell theViewOptions
            set arrangement to not arranged
            set icon size to 128
            set text size to 14
        end tell
        set background picture of theViewOptions to file "${APP_NAME}.app:Contents:Resources:dmg-background.tiff"
        set position of item "${APP_NAME}.app" of container window to {300, 130}
        set position of item "Applications" of container window to {300, 474}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT

sync

# 3e. Hide OS metadata from "Show Hidden Files" users.
rm -rf "$MOUNT_POINT/.fseventsd" "$MOUNT_POINT/.Trashes" 2>/dev/null || true
chflags hidden "$MOUNT_POINT/.DS_Store" 2>/dev/null || true
sync

# 3f. ditto-restage + final UDZO compress. ditto preserves the .DS_Store
# (which carries the icon positions), the Applications symlink, and the
# chflags hidden bits we just applied.
rm -rf "$DMG_RESTAGE" && mkdir -p "$DMG_RESTAGE"
/usr/bin/ditto "$MOUNT_POINT" "$DMG_RESTAGE"

hdiutil detach "$DEVICE" >/dev/null 2>&1 || hdiutil detach "$DEVICE" -force >/dev/null 2>&1

hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_RESTAGE" \
    -ov \
    -format UDZO \
    "$DMG_OUT" >/dev/null

rm -f "$DMG_TMP"
rm -rf "$DMG_STAGE" "$DMG_RESTAGE"

# ── 4. Sign the DMG ──────────────────────────────────────────────────────────

log "Code-signing $DMG_NAME"
codesign --force --sign "$SIGNING_IDENTITY" "$DMG_OUT" 2>&1 | tail -3
codesign --verify --verbose=2 "$DMG_OUT" 2>&1 | tail -3

# ── 5. Summary ───────────────────────────────────────────────────────────────

APP_SIZE=$(du -sh "$APP_BUNDLE" | cut -f1)
DMG_SIZE=$(du -sh "$DMG_OUT" | cut -f1)
DMG_SHA=$(shasum -a 256 "$DMG_OUT" | cut -d' ' -f1)

cat <<EOF

────────────────────────────────────────────────────────────────────
  $APP_NAME.app:    $APP_BUNDLE
                    $APP_SIZE, universal (arm64+x86_64)
  $APP_NAME DMG:    $DMG_OUT
                    $DMG_SIZE
  SHA-256:          $DMG_SHA
  Identity:         $SIGNING_IDENTITY
────────────────────────────────────────────────────────────────────

Next step: test the DMG by double-clicking it, dragging $APP_NAME to
Applications, and launching from Launchpad.

For public release, after testing, notarize the DMG separately:
  xcrun notarytool submit "$DMG_OUT" --keychain-profile NPP_NOTARIZE --wait
  xcrun stapler staple "$DMG_OUT"

If "Identity" above is "-" (ad-hoc), the DMG only works on this Mac.

EOF
