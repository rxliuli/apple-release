#!/usr/bin/env bash
#
# Prepare the signing material into a temporary keychain - the only local material the App
# Store Connect path needs. There is exactly one copy of this logic; `asc` and `dmg` both call it.
#
# Usage:
#   scripts/signing-setup.sh setup <CERT_ENV_VAR>...
#   scripts/signing-setup.sh teardown
#
# Certificates are passed by **environment variable name** (the caller injects the values; this
# script never reads secrets itself), and the password is derived by the convention
# `<prefix>_BASE64` -> `<prefix>_PASSWORD`.
# After setup it writes to $GITHUB_ENV (when present):
#   SIGNING_KEYCHAIN   path of the temporary keychain
#   ASC_KEY_PATH       path of AuthKey_<keyId>.p8
#   ASC_KEY_ID         App Store Connect API key id
#
# Why the certificate has to be imported first (even for the App Store path): a GitHub macOS
# runner always starts with an empty keychain, and under automatic signing `xcodebuild archive`
# asks for a *development* certificate; with none locally it has Apple mint one - whose private
# key dies with the runner and can never be used again. One certificate burned per run, until
# Apple's certificate limit is hit. This really happened: 10 "Apple Development: Created via
# API" certificates in one day, after which every build started failing.
#
# What gets imported is normally a **bundle** p12 (development / distribution / installer /
# Developer ID all in one), shared across repos. So this deliberately **does not check expiry
# or pick an identity**: it is normal for a bundle to carry historic expired certificates, and
# using them to block a release would only produce false alarms; when the one that is actually
# needed has expired, the signing or export step fails outright.

# Works both as an executable (a standalone step in CI) and when `source`d (asc.sh calls it in
# the same process). The latter is required: variables exported by a subprocess do not reach the
# parent, and $GITHUB_ENV only affects **subsequent steps** - useless when calling yourself
# within one process.

set -euo pipefail

KEYCHAIN="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/apple-release-signing.keychain-db"
KEYCHAIN_PASSWORD=actions

fail() {
  echo "::error::$*" >&2
  exit 1
}

# $GITHUB_ENV only exists inside Actions; when run locally, skip it silently.
# Also export into the current process: when `source`d (asc.sh), the caller has to be able to
# read these values directly.
export_env() {
  if [ -n "${GITHUB_ENV:-}" ]; then
    printf '%s=%s\n' "$1" "$2" >>"$GITHUB_ENV"
  fi
  export "$1=$2"
}

# A secret may hold base64 whose trailing padding was lost, or the PEM text itself.
# `base64 --decode` alone is not enough: on truncated input it **silently drops bytes** - this
# bit us once. One missing '=' dropped 2 bytes, the PEM terminator became
# `-----END PRIVATE KEY---`, and xcodebuild / notarytool only reported an incomprehensible
# invalidPEMDocument minutes later.
decode_base64() {
  python3 -c 'import base64,sys; s=sys.argv[1].strip(); sys.stdout.buffer.write(s.encode()+b"\n" if "BEGIN PRIVATE KEY" in s else base64.b64decode(s+"="*(-len(s)%4)))' "$1"
}

teardown() {
  security delete-keychain "${SIGNING_KEYCHAIN:-$KEYCHAIN}" >/dev/null 2>&1 || true
  rm -rf "$HOME/private_keys"
  echo "Removed the temporary keychain and ~/private_keys"
}

# Pick a usable signing identity out of the keychain (prints its full name). The direct-download
# path (dmg) pins the identity explicitly; the App Store path (asc) does not need one, because
# its identity comes from cloud signing.
#
# Only **valid** identities are considered (-v): a bundle frequently holds expired certificates,
# and when an expired and a valid one share a CN, skipping this filter picks the expired one -
# which either fails signing or makes automatic signing go and mint a fresh one.
signing_identity() {
  local fragment="${1:?signing_identity needs an identity name fragment}"
  local valid names picked
  valid="$(security find-identity -v "${SIGNING_KEYCHAIN:-$KEYCHAIN}")"
  # When extracting the name, do not assume the line ends with a quote (an untrusted identity is
  # followed by `(CSSMERR_TP_NOT_TRUSTED)`, an expired one by `(CSSMERR_TP_CERT_EXPIRED)`), so take
  # only what is inside the first pair of quotes; and drop everything carrying CSSMERR_ outright -
  # an unusable identity must never be picked.
  names="$(printf '%s\n' "$valid" | grep -v 'CSSMERR_' | sed -n 's/^[[:space:]]*[0-9]*) [0-9A-Fa-f]\{1,\} "\([^"]*\)".*$/\1/p' || true)"
  # The trailing || true is not optional: grep returns 1 when nothing matches, and under
  # set -e + pipefail that kills the whole script on the assignment, so the error below never gets
  # a chance to print (confirmed: it really does exit silently).
  picked="$(printf '%s\n' "$names" | grep -F -- "$fragment" | head -1 || true)"
  [ -n "$picked" ] \
    || fail "no usable \"${fragment}\" identity in the keychain - signing (and everything that depends on it) needs one; without it Apple will mint a new certificate."
  printf '%s' "$picked"
}

setup() {
  local certs=()
  while [ $# -gt 0 ]; do
    certs+=("$1")
    shift
  done
  if [ ${#certs[@]} -eq 0 ] && [ -z "${APPLE_API_KEY:-}" ]; then
    fail "neither a certificate env var nor APPLE_API_KEY was given - this step would only prepare an empty keychain"
  fi

  # Clean up first, in case this runs again on the same runner (or a previous step left it behind)
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  # it locks itself after a few minutes by default; a release job routinely runs for tens of
  # minutes, and once locked it is guaranteed to fail.
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"

  # Put the temporary keychain first in the search list instead of replacing the list: the other
  # keychains on the runner still have to be resolvable (Apple's root certificates in the trust
  # chain live in the system keychain).
  # mapfile/readarray cannot be used here - macOS /bin/bash is stuck on 3.2 and has neither builtin.
  local existing=()
  while IFS= read -r line; do
    existing+=("$line")
  done < <(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
  if [ ${#existing[@]} -gt 0 ]; then
    security list-keychains -d user -s "$KEYCHAIN" "${existing[@]}"
  else
    security list-keychains -d user -s "$KEYCHAIN"
  fi
  security default-keychain -s "$KEYCHAIN"

  # Wrapped in an if rather than a plain for: under `set -u`, bash 3.2 errors with
  # `certs[@]: unbound variable` when expanding an empty array (only fixed in bash 4.4).
  local name pw_name value password dir
  if [ ${#certs[@]} -gt 0 ]; then
    for name in "${certs[@]}"; do
      case "$name" in
        *_BASE64) pw_name="${name%_BASE64}_PASSWORD" ;;
        *) pw_name="${name}_PASSWORD" ;;
      esac
      value="${!name:-}"
      password="${!pw_name:-}"
      [ -n "$value" ] || fail "$name is empty (is the secret missing?)"
      [ -n "$password" ] || fail "$pw_name is empty (was the secret set to an empty value?)"

      dir="$(mktemp -d)"
      decode_base64 "$value" >"$dir/cert.p12"

      # The raw output of the import is deliberately not redirected: it is only a few lines
      # ("1 key imported" / "1 certificate imported"), and when something fails later those lines
      # are the only direct evidence of whether the p12 held just a certificate or no private key.
      #
      # -A: let any program use the imported private key. This is a throwaway keychain on a
      # throwaway runner. Naming each caller individually with -T (codesign/security/productbuild)
      # looks tighter, but missing one of them (productbuild not trusted) makes it **silently hang**
      # on a keychain prompt that can never appear, ending in a job timeout - already been there.
      security import "$dir/cert.p12" -P "$password" -f pkcs12 -A -k "$KEYCHAIN" \
        || fail "failed to import $name (wrong password? or does the p12 hold a certificate but no private key?)"
      rm -rf "$dir"
    done
    # Running this against an empty keychain reports "The specified item could not be found",
    # so it has to stay after the imports.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  fi

  export_env SIGNING_KEYCHAIN "$KEYCHAIN"

  if [ -n "${APPLE_API_KEY:-}" ]; then
    [ -n "${APPLE_API_KEY_ID:-}" ] \
      || fail "APPLE_API_KEY_ID is empty (was the secret set to an empty value?) - both the file name and -authenticationKeyID would be wrong."
    mkdir -p "$HOME/private_keys"
    local key="$HOME/private_keys/AuthKey_${APPLE_API_KEY_ID}.p8"
    decode_base64 "$APPLE_API_KEY" >"$key"
    # Verify once right away, so a truncated base64 does not surface minutes later as
    # invalidPEMDocument
    openssl pkey -in "$key" -noout \
      || fail "APPLE_API_KEY did not decode to a valid PKCS#8 private key ($(wc -c <"$key" | tr -d ' ') bytes). Store the base64 of the .p8 file (including the trailing '='), or the PEM text itself."
    chmod 600 "$key"
    local size sha
    size="$(wc -c <"$key" | tr -d ' ')"
    sha="$(shasum -a 256 "$key" | cut -c1-12)"
    # Braces are kept deliberately: on macOS's bash 3.2 a multibyte character directly after an
    # unbraced ${VAR} is swallowed into the variable name. This line used to end with a full-width
    # comma and tripped exactly that, so the habit stays even though the separator is ASCII now.
    echo "::notice title=ASC API key::${APPLE_API_KEY_ID}, ${size} bytes, sha256 ${sha}"
    export_env ASC_KEY_PATH "$key"
    export_env ASC_KEY_ID "$APPLE_API_KEY_ID"
  fi
}

# Only dispatch from the command line when executed; when `source`d, just expose the functions
# (otherwise sourcing would run setup as a side effect).
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  case "${1:-}" in
    setup)
      shift
      setup "$@"
      ;;
    teardown)
      teardown
      ;;
    *)
      fail "usage: $(basename "$0") setup [<CERT_ENV_VAR>...] | teardown"
      ;;
  esac
fi
