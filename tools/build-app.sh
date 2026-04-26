#!/usr/bin/env bash
# Build the standalone Beads.app, codesign with hardened runtime, and
# package as a DMG with a drag-to-Applications shortcut.
#
# Local / pre-release flow (this script):
#   1. CMake build (Release, universal arm64+x86_64)
#   2. Codesign with whatever identity is available
#        - $BEADS_SIGN_IDENTITY environment var, or
#        - Automatic Developer ID Application detection, or
#        - Ad-hoc fallback ("-") for local-machine-only testing
#   3. Build DMG (compressed, drag-to-Applications shortcut)
#   4. Codesign the DMG with the same identity
#
# Notarization is intentionally NOT in this script — it requires
# Apple ID credentials and the App Store Connect API stuff, which is
# best kept in a separate notarize.sh you run after testing the DMG
# locally and deciding it's ready to ship.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${REPO_DIR}/build-app"
DIST_DIR="${REPO_DIR}/dist"
APP_NAME="Beads"
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}.app"
ENTITLEMENTS="${REPO_DIR}/shell-app/${APP_NAME}.entitlements"

# Read version straight from CMakeLists so this stays in sync without a
# separate file to remember. CMake variable: BEADS_APP_VERSION.
APP_VERSION=$(grep -E '^\s*set\s*\(\s*BEADS_APP_VERSION\s+"' "${REPO_DIR}/CMakeLists.txt" \
              | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
[ -z "${APP_VERSION}" ] && APP_VERSION="1.0.0"

DMG_NAME="${APP_NAME}v${APP_VERSION}.dmg"
DMG_OUT="${DIST_DIR}/${DMG_NAME}"

log() { printf "\033[1;36m▶\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m⚠\033[0m %s\n" "$*"; }
err() { printf "\033[1;31m✗\033[0m %s\n" "$*" >&2; exit 1; }

# ─── 1. Build ────────────────────────────────────────────────────────────
log "Building ${APP_NAME}.app (Release, arm64+x86_64)"
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

# Skip the plugin target — this script is app-only. Pass -DNPPBEADS_BUILD_PLUGIN=ON
# alongside if you want both built in one go.
cmake .. \
    -DCMAKE_BUILD_TYPE=Release \
    -DNPPBEADS_BUILD_PLUGIN=OFF \
    -DNPPBEADS_BUILD_APP=ON \
    >/dev/null

cmake --build . --target Beads --config Release -- -j"$(sysctl -n hw.ncpu)"

[ -d "${APP_BUNDLE}" ] || err "Build did not produce ${APP_BUNDLE}"

# ─── 2. Pick a signing identity ──────────────────────────────────────────
# Priority:
#   1. $BEADS_SIGN_IDENTITY explicit override
#   2. Auto-discover Developer ID Application certificate
#   3. Ad-hoc ("-") — works only on the machine that signed
SIGN_IDENTITY="${BEADS_SIGN_IDENTITY:-}"

if [ -z "${SIGN_IDENTITY}" ]; then
    DEVID_LINE=$(security find-identity -v -p codesigning 2>/dev/null \
                 | grep -E "Developer ID Application" | head -1 || true)
    if [ -n "${DEVID_LINE}" ]; then
        SIGN_IDENTITY=$(echo "${DEVID_LINE}" | sed -E 's/^[[:space:]]*[0-9]+\)[[:space:]]+([A-F0-9]+).*/\1/')
        log "Auto-detected Developer ID identity: ${SIGN_IDENTITY}"
    else
        SIGN_IDENTITY="-"
        warn "No Developer ID found — using ad-hoc signature (works on this Mac only)"
    fi
fi

# ─── 3. Codesign the app ─────────────────────────────────────────────────
log "Code-signing ${APP_NAME}.app with hardened runtime"
codesign --force --deep --options runtime --timestamp \
    --entitlements "${ENTITLEMENTS}" \
    --sign "${SIGN_IDENTITY}" \
    "${APP_BUNDLE}" 2>&1 \
    | grep -vE "^${APP_BUNDLE}: replacing existing signature$" || true

codesign --verify --deep --strict --verbose=2 "${APP_BUNDLE}" 2>&1 | tail -3

# ─── 4. Build the DMG ────────────────────────────────────────────────────
log "Packaging ${DMG_NAME}"
mkdir -p "${DIST_DIR}"
rm -f "${DMG_OUT}"

DMG_STAGE=$(mktemp -d)
trap 'rm -rf "${DMG_STAGE}"' EXIT

# Stage: app + symlink to /Applications. Users drag-and-drop the icon
# onto the symlink to install. Standard macOS DMG convention.
cp -R "${APP_BUNDLE}" "${DMG_STAGE}/"
ln -s /Applications "${DMG_STAGE}/Applications"

# Build the DMG. UDZO = compressed, the smallest DMG format; UDBZ
# is smaller still but slower to mount on older Macs. UDZO is the
# safe default.
hdiutil create \
    -volname "${APP_NAME} ${APP_VERSION}" \
    -srcfolder "${DMG_STAGE}" \
    -ov \
    -format UDZO \
    -fs HFS+ \
    "${DMG_OUT}" >/dev/null

# ─── 5. Sign the DMG ─────────────────────────────────────────────────────
log "Code-signing ${DMG_NAME}"
codesign --force --sign "${SIGN_IDENTITY}" "${DMG_OUT}" 2>&1 | tail -3
codesign --verify --verbose=2 "${DMG_OUT}" 2>&1 | tail -3

# ─── 6. Summary ──────────────────────────────────────────────────────────
APP_SIZE=$(du -sh "${APP_BUNDLE}" | cut -f1)
DMG_SIZE=$(du -sh "${DMG_OUT}" | cut -f1)
DMG_SHA=$(shasum -a 256 "${DMG_OUT}" | cut -d' ' -f1)

cat <<EOF

────────────────────────────────────────────────────────────────────
  Beads.app:    ${APP_BUNDLE}
                ${APP_SIZE}, universal (arm64+x86_64)
  Beads DMG:    ${DMG_OUT}
                ${DMG_SIZE}
  SHA-256:      ${DMG_SHA}
  Identity:     ${SIGN_IDENTITY}
────────────────────────────────────────────────────────────────────

Next step: test the DMG by double-clicking it, dragging Beads to
Applications, and launching from Launchpad. If the signing identity
above is "-" (ad-hoc), the DMG will only work on THIS Mac.

For public release, set BEADS_SIGN_IDENTITY to your Developer ID
hash (from \`security find-identity -v -p codesigning\`) and re-run.
After that, run a separate notarize step with notarytool.

EOF
