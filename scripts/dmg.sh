#!/usr/bin/env bash
#
# 直发渠道：Developer ID 签名 → DMG → 公证 → 盖章。macOS 专属。
#
# 用法（环境变量）：
#   PROJECT / SCHEME / VERSION / BUILD_NUMBER / WORKING_DIRECTORY
#   SIGNING_IDENTITY   可选；留空则从 keychain 里挑第一个 Developer ID Application
#   VOLUME_NAME        可选；DMG 卷名（默认取 .app 的名字）
#   DMG_NAME           可选；输出文件名（默认 <App>-macos.dmg）
#   WORK_DIR           可选；构建产物目录（默认 build/apple-release）
#   APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD
#   APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER     公证用
#
# 产物路径会写进 $GITHUB_ENV 的 DMG_PATH（同时 ::notice 打出来），供后续步骤
# （upload-artifact / GitHub Release / tap-update）使用。
#
# 跟 asc 那条路的关键差别：
#   * 这里的 app 是**真签名**（Developer ID + hardened runtime）。直发不嵌
#     provisioning profile，没有 profile 就没有"托管身份"可依赖，必须本地持有
#     一张有效证书 —— 所以身份是显式钉住的。
#   * 上架那条路正好相反：automatic 签名不接受显式分发身份（Xcode 直接报
#     conflicting settings），身份也由 cloud signing 提供。
#   * 公证走 notarytool + ASC API key，不需要 App Store Connect 里有构建记录。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKING_DIRECTORY:-.}"

PROJECT="${PROJECT:?PROJECT 是必须的（.xcodeproj 路径）}"
SCHEME="${SCHEME:?SCHEME 是必须的}"
VERSION="${VERSION:?VERSION 是必须的}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

# 发版号与 Flutter 那条线共用同一个公式，各仓库不再各写一份
if [ -z "${BUILD_NUMBER:-}" ]; then
  IFS='.' read -r major minor patch <<<"$VERSION"
  BUILD_NUMBER=$((major * 10000 + minor * 100 + patch))
  echo "::notice title=CFBundleVersion::按 VERSION=${VERSION} 推出 ${BUILD_NUMBER}"
fi

# ---- 签名物料 -----------------------------------------------------------
# source 而不是起子进程：它导出的 SIGNING_KEYCHAIN / ASC_KEY_PATH 要能在本进程用到。
# shellcheck source=./signing-setup.sh
. "$SCRIPT_DIR/signing-setup.sh"
setup APPLE_CERTIFICATE_BASE64
: "${ASC_KEY_PATH:?签名物料里没有拿到 ASC_KEY_PATH}"
: "${ASC_KEY_ID:?签名物料里没有拿到 ASC_KEY_ID}"
API_ISSUER="${APPLE_API_ISSUER:?APPLE_API_ISSUER 是必须的}"

IDENTITY="${SIGNING_IDENTITY:-$(signing_identity 'Developer ID Application')}"
echo "::notice title=签名身份::${IDENTITY}"

WORK_DIR="${WORK_DIR:-build/apple-release}"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/dmg.xcarchive"

cleanup() {
  teardown
}
trap cleanup EXIT

# ---- 1. 归档（带 Developer ID 真签名）-----------------------------------
# 这里**不能**传 PROVISIONING_PROFILE_SPECIFIER：它是全局构建设置，会连 SwiftPM 的
# 资源包（如 LinkPureCore_LinkPureCore）一起要求 profile，而那是纯资源包、不支持 profile。
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
[ -n "$APP" ] || fail "归档里没有找到 .app"
APP_NAME="$(basename "$APP" .app)"

# ---- 2. 核对归档产物 ----------------------------------------------------
echo "::group::归档产物"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=|flags=' || true
# 上 Mac App Store 要 universal；这个渠道也一并保持一致
lipo -info "$APP/Contents/MacOS/${APP_NAME}"
echo "::endgroup::"

# ---- 3. 打 DMG ----------------------------------------------------------
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

# ---- 4. 公证 + 盖章 -----------------------------------------------------
echo "::group::notarytool + stapler"
xcrun notarytool submit "$DMG_PATH" \
  --key "$ASC_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$API_ISSUER" \
  --wait
xcrun stapler staple "$DMG_PATH"
# 盖章是真的成功了，而不是 notarytool 说成功
xcrun stapler validate "$DMG_PATH"
# Gatekeeper 的最终判定。放在这里当"附加证据"而不是硬门：runner 上的 assess
# 守护进程状态偶尔会给出假阴性，而 stapler validate 已经过了。
spctl -a -t open --context context:primary-signature -v "$DMG_PATH" \
  || echo "::warning::spctl 未通过（stapler validate 已通过，通常是 runner 上的 Gatekeeper 状态问题）"
echo "::endgroup::"

# 后续步骤（upload-artifact / GitHub Release / tap-update）要用这个路径；
# 同时写成 action output，方便调用方在别的 job 里用。
DMG_PATH="$(cd "$(dirname "$DMG_PATH")" && pwd)/$(basename "$DMG_PATH")"
export DMG_PATH
if [ -n "${GITHUB_ENV:-}" ]; then
  printf 'DMG_PATH=%s\n' "$DMG_PATH" >>"$GITHUB_ENV"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  printf 'dmg-path=%s\n' "$DMG_PATH" >>"$GITHUB_OUTPUT"
fi
echo "::notice title=公证过的 DMG::${DMG_PATH}"
