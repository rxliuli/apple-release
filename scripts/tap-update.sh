#!/usr/bin/env bash
#
# 更新 Homebrew tap 里某个 cask 的 version 与 sha256。
#
# 用法（环境变量）：
#   TAP         tap 仓库（owner/repo，默认 rxliuli/homebrew-tap）
#   TOKEN       有 push 权限的 GitHub token
#   CASK        cask 名（对应 tap 里的 Casks/<name>.rb）
#   VERSION     新版本号
#   ARTIFACT    要算 sha256 的文件（通常是 .dmg）
#   CASK_PATH   可选，cask 文件在 tap 里的相对路径（默认 Casks/<CASK>.rb）
#
# 只改 version / sha256 两行，不覆盖 cask 里其它内容 —— livecheck、caveats、zap
# 都可能是手写的，整篇重写会把它们抹掉。cask 不存在就直接失败：模板里的
# homepage / desc / caveats / zap 是每个 app 特有的，自动生成只会生成错的东西。

set -euo pipefail

TAP="${TAP:-rxliuli/homebrew-tap}"
CASK="${CASK:?CASK is required (cask name)}"
VERSION="${VERSION:?VERSION is required}"
ARTIFACT="${ARTIFACT:?ARTIFACT is required (the file being released, used to compute sha256)}"
TOKEN="${TOKEN:?TOKEN is required (a GitHub token with push access)}"
CASK_PATH="${CASK_PATH:-Casks/${CASK}.rb}"

fail() {
  echo "::error::$*" >&2
  exit 1
}

[ -f "$ARTIFACT" ] || fail "file not found: $ARTIFACT"

# macOS 只有 shasum，ubuntu 两个都有
if command -v sha256sum >/dev/null 2>&1; then
  SHA="$(sha256sum "$ARTIFACT" | cut -d' ' -f1)"
else
  SHA="$(shasum -a 256 "$ARTIFACT" | cut -d' ' -f1)"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --depth 1 "https://x-access-token:${TOKEN}@github.com/${TAP}.git" "$WORK/tap" >/dev/null
FILE="$WORK/tap/$CASK_PATH"
[ -f "$FILE" ] || fail "${TAP} has no ${CASK_PATH} - a new cask has to be written by hand (the app-specific fields in the template cannot be generated)"

sed -i.bak -E "s|^  version \".*\"$|  version \"${VERSION}\"|" "$FILE"
sed -i.bak -E "s|^  sha256 \".*\"$|  sha256 \"${SHA}\"|" "$FILE"
rm -f "$FILE.bak"

# sed 没匹配上时会静默什么都不做，然后被下面那句 "已经是最新" 误报成成功 ——
# 所以这里显式确认两行真的被改掉了。
grep -qE "^  version \"${VERSION}\"$" "$FILE" || fail "could not rewrite the version line (did the cask format change?)"
grep -qE "^  sha256 \"${SHA}\"$" "$FILE" || fail "could not rewrite the sha256 line (did the cask format change?)"

cd "$WORK/tap"
git add "$CASK_PATH"
if git diff --cached --quiet; then
  echo "::notice title=cask already current::${CASK} is already v${VERSION} / ${SHA}"
  exit 0
fi

git -c user.name="github-actions[bot]" \
    -c user.email="github-actions[bot]@users.noreply.github.com" \
    commit -m "chore: bump ${CASK} to v${VERSION}" >/dev/null
git push
echo "::notice title=cask updated::${TAP} ${CASK} → v${VERSION} (sha256 ${SHA})"
