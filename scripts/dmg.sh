#!/usr/bin/env bash
#
# Direct-download channel: Developer ID sign → DMG → notarize → staple. macOS only.
#
# Usage (environment variables):
#   PROJECT / SCHEME / VERSION / BUILD_NUMBER / WORKING_DIRECTORY
#   SIGNING_IDENTITY   optional; when empty the first Developer ID Application in the keychain is used
#   VOLUME_NAME        optional; DMG volume name (defaults to the .app name)
#   DMG_NAME           optional; output file name (defaults to <App>-macos.dmg)
#   WORK_DIR           optional; build product directory (defaults to build/apple-release)
#   APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD
#   APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER     for notarization
#
# The product path is written to DMG_PATH in $GITHUB_ENV (and echoed as a ::notice) so
# later steps (upload-artifact / GitHub Release / tap-update) can pick it up.
#
# The key differences from the asc path:
#   * the app here is really signed (Developer ID + hardened runtime). A direct download
#     embeds no provisioning profile, and without a profile there is no managed identity
#     to fall back on, so a valid certificate must exist locally - hence the identity is
#     pinned explicitly.
#   * the App Store path is the opposite: automatic signing rejects an explicitly given
#     distribution identity (Xcode fails with conflicting settings), and the identity comes
#     from cloud signing instead.
#   * notarization goes through notarytool + an ASC API key, so no build record has to exist
#     in App Store Connect.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKING_DIRECTORY:-.}"

PROJECT="${PROJECT:?PROJECT is required (path to the .xcodeproj)}"
SCHEME="${SCHEME:?SCHEME is required}"
VERSION="${VERSION:?VERSION is required}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# The build number shares the same formula as the Flutter line, so no repo keeps its own copy
if [ -z "${BUILD_NUMBER:-}" ]; then
  IFS='.' read -r major minor patch <<<"$VERSION"
  BUILD_NUMBER=$((major * 10000 + minor * 100 + patch))
  echo "::notice title=CFBundleVersion::derived ${BUILD_NUMBER} from VERSION=${VERSION}"
fi

# ---- signing material ---------------------------------------------------
# `source` rather than a subprocess: the SIGNING_KEYCHAIN / ASC_KEY_PATH it exports have
# to be visible in this process.
# shellcheck source=./signing-setup.sh
. "$SCRIPT_DIR/signing-setup.sh"
setup APPLE_CERTIFICATE_BASE64
: "${ASC_KEY_PATH:?signing material did not provide ASC_KEY_PATH}"
: "${ASC_KEY_ID:?signing material did not provide ASC_KEY_ID}"
API_ISSUER="${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}"

IDENTITY="${SIGNING_IDENTITY:-$(signing_identity 'Developer ID Application')}"
echo "::notice title=Signing identity::${IDENTITY}"

WORK_DIR="${WORK_DIR:-build/apple-release}"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/dmg.xcarchive"

cleanup() {
  teardown
}
trap cleanup EXIT

# ---- 1. archive (really signed with Developer ID) -----------------------
# PROVISIONING_PROFILE_SPECIFIER must **not** be passed here: it is a global build setting,
# so it would also demand a profile for SwiftPM resource bundles (such as
# LinkPureCore_LinkPureCore), and a pure resource bundle does not support one.
echo "::group::xcodebuild archive (Developer ID)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY"
echo "::endgroup::"

APP="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
[ -n "$APP" ] || fail "no .app found in the archive"
APP_NAME="$(basename "$APP" .app)"

# ---- 2. check the archive product ---------------------------------------
echo "::group::archive product"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|flags=' || true
# the Mac App Store requires universal; keep this channel consistent with it
lipo -info "$APP/Contents/MacOS/${APP_NAME}"
echo "::endgroup::"

# ---- 3. build the DMG ---------------------------------------------------
command -v create-dmg >/dev/null 2>&1 || brew install create-dmg
VOLUME_NAME="${VOLUME_NAME:-$APP_NAME}"
DMG_NAME="${DMG_NAME:-${APP_NAME}-macos.dmg}"
DMG_PATH="$WORK_DIR/$DMG_NAME"
rm -f "$DMG_PATH"

echo "::group::create-dmg"
create-dmg \
  --volname "$VOLUME_NAME" \
  --window-pos 200 120 \
  --window-size 660 400 \
  --icon-size 100 \
  --icon "$(basename "$APP")" 180 170 \
  --hide-extension "$(basename "$APP")" \
  --app-drop-link 480 170 \
  --codesign "$IDENTITY" \
  "$DMG_PATH" \
  "$APP"
codesign --verify --verbose=2 "$DMG_PATH"
echo "::endgroup::"

# ---- 4. notarize + staple -----------------------------------------------
echo "::group::notarytool + stapler"
xcrun notarytool submit "$DMG_PATH" \
  --key "$ASC_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$API_ISSUER" \
  --wait
xcrun stapler staple "$DMG_PATH"
# the staple really succeeded, rather than notarytool claiming it did
xcrun stapler validate "$DMG_PATH"
# Gatekeeper's final verdict. Kept as supplementary evidence rather than a hard gate:
# the assess daemon on the runner occasionally reports a false negative, and stapler
# validate has already passed by this point.
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" \
  || echo "::warning::spctl did not pass (stapler validate did, so this is usually a Gatekeeper state issue on the runner)"
echo "::endgroup::"

# Later steps (upload-artifact / GitHub Release / tap-update) need this path; also emit it
# as an action output so a caller can use it from another job.
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
export DMG_PATH
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'DMG_PATH=%s\n' "$DMG_PATH" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'dmg-path=%s\n' "$DMG_PATH" >>"$GITHUB_OUTPUT"
fi
echo "::notice title=Notarized DMG::${DMG_PATH}"
