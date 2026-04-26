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

# ── 3. Build the DMG ─────────────────────────────────────────────────────────

log "Packaging $DMG_NAME → $DOWNLOADS_DIR"
mkdir -p "$DOWNLOADS_DIR"
rm -f "$DMG_OUT"

DMG_STAGE=$(mktemp -d)
trap 'rm -rf "$DMG_STAGE"' EXIT

# Stage: app + symlink to /Applications. Users drag-and-drop the icon
# onto the symlink to install. Standard macOS DMG convention.
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"

# Build the DMG. UDZO = compressed, the smallest commonly-used format.
hdiutil create \
    -volname "$APP_NAME $APP_VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "$DMG_OUT" >/dev/null

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
