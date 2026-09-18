#!/usr/bin/env bash
#
# 归档 → 导出 → 校验 →（可选）上传到 App Store Connect。macOS 与 iOS 共用这一份，
# 差别只有 scheme / destination / 归档怎么签 / 产物后缀 / altool 的 --type。
#
# 用法（环境变量）：
#   PROJECT           .xcodeproj 路径（相对 WORKING_DIRECTORY）
#   SCHEME            要构建的 scheme（iOS 与 macOS 各一个）
#   PLATFORM          macos | ios
#   VERSION           MARKETING_VERSION，用于事后核对导出产物里的版本号
#   BUILD_NUMBER      CFBundleVersion（不给就按 x*10000 + y*100 + z 从 VERSION 推）
#   TEAM_ID           Apple Developer Team ID
#   RELEASE           true = 真上传；其它值 = 只演练到"通过 Apple 的校验"为止
#   WORKING_DIRECTORY 可选，monorepo 里项目所在目录（默认当前目录）
#   APPLE_CERTIFICATE_BASE64 / APPLE_CERTIFICATE_PASSWORD   合集 p12（见 signing-setup.sh）
#   APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER      ASC API key
#
#   scripts/asc.sh                     # 本机或 CI 直接跑
#
# 为什么归档阶段**不签名**（这是踩出来的，不是洁癖）：
#   * automatic 归档想要的是**开发**身份，本地没有就会让 Apple 现造一张 —— 别人
#     部署一次就烧一张证书（见 signing-setup.sh 顶部注释）。
#   * Xcode **不允许**在 automatic 签名下显式指定分发身份，硬指定直接报
#     "has conflicting provisioning settings ... has been manually specified"。
#   * macOS 又完全不能不签：entitlements 跟着签名走，不签就丢 sandbox，
#     ASC 校验会以 90296 拒收。
#   三个约束叠起来只剩一个解：macOS 用 ad-hoc 签（identity "-"，只为把
#   entitlements 带进归档），iOS 完全不签（它的 entitlements 全部来自 profile）。
#   真正的分发签名由下面的 export 步骤完成 —— 那一步用的是 cloud signing 提供的
#   `Cloud Managed Apple Distribution` 与托管 profile，**不需要**本地证书。

set -euo pipefail

# 脚本目录要在 cd 之前算出来：下面可能切到 WORKING_DIRECTORY，
# 那时相对的 $0 就指错地方了。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${WORKING_DIRECTORY:-.}"

PROJECT="${PROJECT:?PROJECT 是必须的（.xcodeproj 路径）}"
SCHEME="${SCHEME:?SCHEME 是必须的}"
PLATFORM="${PLATFORM:?PLATFORM 是必须的（macos | ios）}"
VERSION="${VERSION:?VERSION 是必须的}"
TEAM_ID="${TEAM_ID:?TEAM_ID 是必须的}"
RELEASE="${RELEASE:-false}"

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

case "$PLATFORM" in
  macos)
    DESTINATION='generic/platform=macOS'
    # 归档只为把 entitlements 带进去，不需要证书也不需要 profile
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
    fail "PLATFORM 只能是 macos 或 ios，收到的是 '${PLATFORM}'"
    ;;
esac

# ---- 签名物料 -----------------------------------------------------------
# source 而不是起子进程：它导出的 SIGNING_KEYCHAIN / ASC_KEY_PATH / ASC_KEY_ID
# 要能在本进程里直接读到。
# shellcheck source=./signing-setup.sh
. "$SCRIPT_DIR/signing-setup.sh"
setup APPLE_CERTIFICATE_BASE64
: "${ASC_KEY_PATH:?签名物料里没有拿到 ASC_KEY_PATH}"
: "${ASC_KEY_ID:?签名物料里没有拿到 ASC_KEY_ID}"
API_ISSUER="${APPLE_API_ISSUER:?APPLE_API_ISSUER 是必须的}"

AUTH=(
  -allowProvisioningUpdates
  -authenticationKeyPath "$ASC_KEY_PATH"
  -authenticationKeyID "$ASC_KEY_ID"
  -authenticationKeyIssuerID "$API_ISSUER"
)

# 产物留在 caller 的工作目录里（runner 是一次性的），而不是 mktemp —— 这样「演练
# 模式」跑完之后还能去翻 .pkg/.ipa 和 DistributionSummary。默认 build/apple-release,
# 可用 WORK_DIR 覆盖。
WORK_DIR="${WORK_DIR:-build/apple-release}"
mkdir -p "$WORK_DIR"
ARCHIVE_PATH="$WORK_DIR/${PLATFORM}.xcarchive"
EXPORT_PATH="$WORK_DIR/export-${PLATFORM}"

# keychain 是唯一会在 runner 上留下私钥的东西，必须清掉；产物则保留。
cleanup() {
  teardown
}
trap cleanup EXIT

# ---- 1. 归档 ------------------------------------------------------------
echo "::group::xcodebuild archive (${PLATFORM}, 不签名的归档)"
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

# macOS 的归档必须是 ad-hoc 签名且带着 entitlements —— 这是上面那段注释里的第 3 条
# 约束，也是历史上真被 ASC 用 90296 拒过一次的地方。所以在这里当场断言。
if [ "$PLATFORM" = macos ]; then
  APP="$(find "$ARCHIVE_PATH/Products/Applications" -maxdepth 1 -name '*.app' | head -1)"
  [ -n "$APP" ] || fail "归档里没有找到 .app"
  codesign --verify --verbose=2 "$APP"
  codesign -dv --verbose=2 "$APP" 2>&1 | grep -E 'Authority=|TeamIdentifier=' || true
  codesign -d --entitlements - --xml "$APP" | plutil -p -
  codesign -d --entitlements - --xml "$APP" | plutil -p - | grep -q 'com.apple.security.app-sandbox' \
    || fail "归档里的 app 缺 app-sandbox entitlement（ad-hoc 签名那行被谁删了？）"
fi

# ---- 2. 导出（真正签名的那一步）----------------------------------------
# manageAppVersionAndBuildNumber=false 关掉「导出时自动 +1 build 号」——
# 默认开着的话 Xcode 会把指定的 build 号改掉，发布就不可复现了。
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
[ -n "$ARTIFACT" ] || fail "导出目录里没有 ${ARTIFACT_GLOB}：$(ls -la "$EXPORT_PATH")"

# ---- 3. 核对产物 --------------------------------------------------------
# DistributionSummary 里有实际用的证书、profile、entitlements 和 build 号，
# 出问题时这一行就是最有用的线索。
echo "::group::导出的产物"
echo "artifact: $ARTIFACT"
if [ "$PLATFORM" = macos ]; then
  pkgutil --check-signature "$ARTIFACT"
fi
plutil -p "$EXPORT_PATH/DistributionSummary.plist" 2>/dev/null || true
echo "::endgroup::"

# ---- 4. 校验 + 上传 -----------------------------------------------------
# 校验（--validate-app）在**上传之前**让 Apple 过一遍，是这个脚本存在的意义之一：
# RELEASE=false 时整条流水线就跑到这里为止，即"演练到能通过 Apple 的校验"。
echo "::group::altool --validate-app"
xcrun altool --validate-app --type "$ALTOOL_TYPE" --file "$ARTIFACT" \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$API_ISSUER"
echo "::endgroup::"

if [ "$RELEASE" = true ]; then
  echo "::group::altool --upload-app"
  xcrun altool --upload-app --type "$ALTOOL_TYPE" --file "$ARTIFACT" \
    --apiKey "$ASC_KEY_ID" --apiIssuer "$API_ISSUER"
  echo "::endgroup::"
  echo "::notice title=已上传 App Store Connect::${SCHEME} ${VERSION} (${BUILD_NUMBER}) → ${ARTIFACT}"
else
  echo "::notice title=演练模式（未上传）::RELEASE != true，产物留在 ${ARTIFACT}"
fi
