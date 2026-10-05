#!/usr/bin/env bash
#
# Archive → export → validate → (optionally) upload to App Store Connect. macOS and iOS share
# this one script; the only differences are the scheme / destination / how the archive is
# signed / the artifact suffix / altool's --type.
#
# Usage (environment variables):
#   PROJECT           path to the .xcodeproj (relative to WORKING_DIRECTORY)
#   SCHEME            scheme to build (one for iOS, one for macOS)
#   PLATFORM          macos | ios
#   VERSION           MARKETING_VERSION, used afterwards to check the exported artifact
#   BUILD_NUMBER      CFBundleVersion (when empty, derived from VERSION as x*10000 + y*100 + z)
#   TEAM_ID           Apple Developer Team ID
#   RELEASE           true = really upload; anything else = rehearse up to passing Apple's validation
#   WORKING_DIRECTORY optional, the project's directory in a monorepo (defaults to the cwd)
#   APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD   bundle p12 (see signing-setup.sh)
#   APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER      ASC API key
#
#   scripts/asc.sh                     # run directly, locally or in CI
#
# Why the archive step is **not signed** (learned the hard way, not fussiness):
#   * an automatic archive wants a *development* identity, and if none exists locally it has
#     Apple mint one - one certificate burned per deploy (see the top of signing-setup.sh).
#   * Xcode does **not** allow an explicitly given distribution identity together with
#     automatic signing; forcing it fails with "has conflicting provisioning settings ...
#     has been manually specified".
#   * macOS cannot go unsigned either: entitlements travel with the signature, an unsigned
#     archive loses its sandbox, and ASC rejects it with 90296.
#   The three constraints leave exactly one solution: sign macOS ad-hoc (identity "-", purely
#   so the entitlements make it into the archive) and leave iOS unsigned (its entitlements all
#   come from the profile). The real distribution signature happens in the export step below,
#   which uses the `Cloud Managed Apple Distribution` identity and managed profile supplied by
#   cloud signing - no local certificate needed.

set -euo pipefail

# The script directory has to be resolved before the cd below: that may move us to
# WORKING_DIRECTORY, at which point a relative $0 points at the wrong place.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKING_DIRECTORY:-.}"

PROJECT="${PROJECT:?PROJECT is required (path to the .xcodeproj)}"
SCHEME="${SCHEME:?SCHEME is required}"
PLATFORM="${PLATFORM:?PLATFORM is required (macos | ios)}"
VERSION="${VERSION:?VERSION is required}"
TEAM_ID="${TEAM_ID:?TEAM_ID is required}"
RELEASE="${RELEASE:-false}"

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

case "$PLATFORM" in
  macos)
    DESTINATION='generic/platform=macOS'
    # the archive only exists to carry the entitlements; it needs neither a certificate nor a profile
    ARCHIVE_SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=-)
    ARTIFACT_GLOB='*.pkg'
    ALTOOL_TYPE=macos
    ;;
  ios)
    DESTINATION='generic/platform=iOS'
    ARCHIVE_SIGNING=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
    ARTIFACT_GLOB='*.ipa'
    ALTOOL_TYPE=ios
    ;;
  *)
    fail "PLATFORM must be macos or ios, got '${PLATFORM}'"
    ;;
esac

# ---- signing material ---------------------------------------------------
# `source` rather than a subprocess: the SIGNING_KEYCHAIN / ASC_KEY_PATH / ASC_KEY_ID it
# exports have to be readable in this process.
# shellcheck source=./signing-setup.sh
. "$SCRIPT_DIR/signing-setup.sh"
setup APPLE_CERTIFICATE_BASE64
: "${ASC_KEY_PATH:?signing material did not provide ASC_KEY_PATH}"
: "${ASC_KEY_ID:?signing material did not provide ASC_KEY_ID}"
API_ISSUER="${APPLE_API_ISSUER:?APPLE_API_ISSUER is required}"

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$API_ISSUER"
)

# Products stay in the caller's working directory (runners are ephemeral) rather than in a
# mktemp - that way a rehearsal leaves the .pkg/.ipa and the DistributionSummary behind to be
# inspected. Defaults to build/apple-release and can be overridden with WORK_DIR.
WORK_DIR="${WORK_DIR:-build/apple-release}"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/${PLATFORM}.xcarchive"
EXPORT_PATH="$WORK_DIR/export-${PLATFORM}"

# The keychain is the only thing that leaves a private key behind on the runner, so it must
# be removed; the products are kept.
cleanup() {
  teardown
}
trap cleanup EXIT

# ---- 1. archive ---------------------------------------------------------
echo "::group::xcodebuild archive (${PLATFORM}, unsigned archive)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "$DESTINATION" \
  -archivePath "$ARCHIVE_PATH" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${ARCHIVE_SIGNING[@]}"
echo "::endgroup::"

# A macOS archive must be ad-hoc signed and carry the entitlements - constraint 3 from the
# comment block above, and something ASC really did reject once with 90296. So assert it here.
if [ "$PLATFORM" = macos ]; then
  APP="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$APP" ] || fail "no .app found in the archive"
  codesign --verify --verbose=2 "$APP"
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=' || true
  codesign -d --entitlements - --xml "$APP" | plutil -p -
  codesign -d --entitlements - --xml "$APP" | plutil -p - | grep -q 'com.apple.security.app-sandbox' \
    || fail "the archived app is missing the app-sandbox entitlement (did someone delete the ad-hoc signing line?)"
fi

# ---- 2. export (the step that really signs) -----------------------------
# manageAppVersionAndBuildNumber=false disables the "bump the build number on export"
# behaviour: left on, Xcode rewrites the build number we specified and the release is no
# longer reproducible.
cat >"$WORK_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${TEAM_ID}</string>
  <key>destination</key><string>export</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF

echo "::group::xcodebuild -exportArchive (${PLATFORM})"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$WORK_DIR/ExportOptions.plist" \
  "${AUTH[@]}"
echo "::endgroup::"

ARTIFACT="$(find "$EXPORT_PATH" -name "$ARTIFACT_GLOB" | head -1)"
[ -n "$ARTIFACT" ] || fail "no ${ARTIFACT_GLOB} in the export directory: $(ls -la "$EXPORT_PATH")"

# ---- 3. check the artifact ----------------------------------------------
# DistributionSummary holds the certificate, profile, entitlements and build number that were
# actually used, so when something goes wrong this line is the most useful lead.
echo "::group::exported artifact"
echo "artifact: $ARTIFACT"
if [ "$PLATFORM" = macos ]; then
  pkgutil --check-signature "$ARTIFACT"
fi
plutil -p "$EXPORT_PATH/DistributionSummary.plist" 2>/dev/null || true
echo "::endgroup::"

# ---- 4. validate + upload -----------------------------------------------
# Validation (--validate-app) lets Apple review the build *before* uploading, and that is one
# of the reasons this script exists: with RELEASE=false the whole pipeline stops here, i.e.
# "rehearse up to passing Apple's validation".
echo "::group::altool --validate-app"
xcrun altool --validate-app --type "$ALTOOL_TYPE" --file "$ARTIFACT" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$API_ISSUER"
echo "::endgroup::"

if [ "$RELEASE" = true ]; then
  echo "::group::altool --upload-app"
  xcrun altool --upload-app --type "$ALTOOL_TYPE" --file "$ARTIFACT" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$API_ISSUER"
  echo "::endgroup::"
  echo "::notice title=Uploaded to App Store Connect::${SCHEME} ${VERSION} (${BUILD_NUMBER}) → ${ARTIFACT}"
else
  echo "::notice title=Rehearsal (nothing uploaded)::RELEASE != true, artifact left at ${ARTIFACT}"
fi
