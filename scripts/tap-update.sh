#!/usr/bin/env bash
#
# Update the version and sha256 of a cask in a Homebrew tap.
#
# Usage (environment variables):
#   TAP         tap repo (owner/repo, default rxliuli/homebrew-tap)
#   TOKEN       GitHub token with push access
#   CASK        cask name (matches Casks/<name>.rb in the tap)
#   VERSION     new version number
#   ARTIFACT    the file to hash (usually the .dmg)
#   CASK_PATH   optional, the cask file's path inside the tap (default Casks/<CASK>.rb)
#
# Rewrites only the version and sha256 lines and leaves the rest of the cask alone:
# livecheck, caveats and zap are often hand-written, and rewriting the whole file
# would wipe them. A missing cask is a hard failure - homepage, desc, caveats and zap
# are app specific, so generating them would generate the wrong thing.

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

# macOS only ships shasum; ubuntu has both
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

# When sed matches nothing it silently does nothing, and the "already current" notice
# below would then report success - so assert that both lines really were rewritten.
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
