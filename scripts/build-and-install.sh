#!/usr/bin/env bash
#
# build-and-install.sh — build a code-signed SayIt.app and install it to
# /Applications.
#
# Signing uses Automatic style (CODE_SIGN_STYLE=Automatic plus the
# DEVELOPMENT_TEAM from your gitignored Local.xcconfig; see README). If
# Automatic signing fails on provisioning, fall back to manual:
#   SIGN_MODE=manual CODE_SIGN_IDENTITY="Apple Development: YOUR NAME (XXXXXXXXXX)" \
#     scripts/build-and-install.sh
# Manual mode signs without a provisioning profile (allowed for non-App-Store
# macOS apps).
#
# Idempotent: safe to re-run. Each run regenerates the project, rebuilds, and
# overwrites the install.
# No notarization — that is only needed for public Developer ID distribution.

set -euo pipefail

# Repo root resolved relative to this script, so it works from any checkout.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCHEME="SayIt"
CONFIG="Release"
BUILD_DIR="${REPO}/build"
PRODUCT="${BUILD_DIR}/Build/Products/${CONFIG}/SayIt.app"
DEST="/Applications/SayIt.app"
# Manual-mode signing identity; override via env. Empty by default so each
# contributor supplies their own (no developer identity committed).
DEV_IDENTITY="${CODE_SIGN_IDENTITY:-}"
SIGN_MODE="${SIGN_MODE:-auto}"   # auto | manual

echo "==> [1/6] xcodegen generate"
xcodegen generate --spec "${REPO}/project.yml"

echo "==> [2/6] xcodebuild (${CONFIG}) — signing mode: ${SIGN_MODE}"
if [[ "${SIGN_MODE}" == "manual" ]]; then
  if [[ -z "${DEV_IDENTITY}" ]]; then
    echo "ERROR: SIGN_MODE=manual requires CODE_SIGN_IDENTITY to be set." >&2
    exit 1
  fi
  xcodebuild \
    -project "${REPO}/SayIt.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="${DEV_IDENTITY}" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    build
else
  xcodebuild \
    -project "${REPO}/SayIt.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIG}" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "${BUILD_DIR}" \
    -allowProvisioningUpdates \
    build
fi

echo "==> [3/6] locate product"
if [[ ! -d "${PRODUCT}" ]]; then
  echo "ERROR: build product not found: ${PRODUCT}" >&2
  exit 1
fi
echo "    product: ${PRODUCT}"

echo "==> [4/6] quit any running instance and overwrite-install to /Applications"
killall SayIt 2>/dev/null || true
rm -rf "${DEST}"
cp -R "${PRODUCT}" "${DEST}"

# Remove stray copies sharing the same bundle id: leftover .app bundles on disk
# pollute TCC (privacy grants) and LaunchServices (duplicate registration ->
# wrong app launched, permission confusion). Keep only /Applications/SayIt.app.
# Idempotent: rm -rf is a no-op when the target is absent.
echo "    cleaning duplicate bundle copies (keeping only ${DEST})"
# Release output inside the repo (already copied to /Applications).
rm -rf "${REPO}/build"
# Old products in Xcode DerivedData (may contain a same-bundle-id SayIt.app).
rm -rf "${HOME}/Library/Developer/Xcode/DerivedData/SayIt-"*

echo "==> [5/6] verify signature"
codesign --verify --strict "${DEST}"
codesign -dv --verbose=2 "${DEST}"

echo "==> [6/6] done"
echo ""
echo "Installed: ${DEST}"
echo "Notes:"
echo "  - If Gatekeeper blocks the first launch, right-click the app in Finder > Open."
echo "  - In System Settings > Privacy & Security, grant: Microphone and"
echo "    Accessibility (for text injection / global hotkeys)."
echo "  - Default: hold right Command to talk. The first local transcription"
echo "    downloads a model; you can use cloud STT in Settings meanwhile."
