# apple-release

Shared scripts + thin GitHub Actions for publishing Apple apps:

- **`asc`** — archive → export → validate → (optionally) upload to App Store Connect (macOS and iOS)
- **`dmg`** — Developer ID sign → DMG → notarize → staple, for the direct-download channel
- **`tap-update`** — bump a Homebrew cask's `version` / `sha256`

The logic lives in `scripts/*.sh` and runs both in CI and locally; the actions are thin
pass-through wrappers. GitHub Actions only injects secrets and orchestrates.

**Why this exists:** every repo carried a near-identical `release.yml`, and they drifted
apart. The hard part was never the YAML — it was a handful of rules that only show up
when you get them wrong (see [Why it looks like this](#why-it-looks-like-this)).

## Usage

### App Store Connect (macOS and/or iOS)

```yaml
jobs:
  appstore:
    strategy:
      fail-fast: false
      matrix:
        include:
          - platform: macos
            scheme: LinkPureMac
          - platform: ios
            scheme: LinkPureIOS   # drop this entry if the app has no iOS target
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v6
      - run: brew install xcodegen && xcodegen generate   # project-specific, your side
      - uses: rxliuli/apple-release/asc@v1
        with:
          platform: ${{ matrix.platform }}
          scheme: ${{ matrix.scheme }}
          project: LinkPure.xcodeproj
          version: 1.2.3
          team-id: ABCDE12345
          release: 'true'          # 'false' = rehearsal: stop after Apple validates
          certificate-base64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}
          certificate-password: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          api-key: ${{ secrets.APPLE_API_KEY }}
          api-key-id: ${{ secrets.APPLE_API_KEY_ID }}
          api-issuer: ${{ secrets.APPLE_API_ISSUER }}
```

### Notarized DMG (direct download)

```yaml
      - uses: rxliuli/apple-release/dmg@v1
        id: dmg
        with:
          project: LinkPure.xcodeproj
          scheme: LinkPureMac
          version: 1.2.3
          certificate-base64: ${{ secrets.APPLE_CERTIFICATE_BASE64 }}
          certificate-password: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          api-key: ${{ secrets.APPLE_API_KEY }}
          api-key-id: ${{ secrets.APPLE_API_KEY_ID }}
          api-issuer: ${{ secrets.APPLE_API_ISSUER }}
      - uses: actions/upload-artifact@v7
        with:
          name: macos-dmg
          path: ${{ steps.dmg.outputs.dmg-path }}
```

### Homebrew cask

```yaml
      - uses: rxliuli/apple-release/tap-update@v1
        with:
          cask: linkpure
          version: 1.2.3
          artifact: LinkPure-macos.dmg
          token: ${{ secrets.TAP_GITHUB_TOKEN }}
```

### Locally

The scripts are plain shell — set the inputs as environment variables and run them.
No push-and-pray:

```sh
APPLE_CERTIFICATE_BASE64=... APPLE_CERTIFICATE_PASSWORD=... \
APPLE_API_KEY=... APPLE_API_KEY_ID=... APPLE_API_ISSUER=... \
PROJECT=LinkPure.xcodeproj SCHEME=LinkPureIOS PLATFORM=ios \
VERSION=1.2.3 TEAM_ID=ABCDE12345 RELEASE=false \
scripts/asc.sh
```

## Inputs

### `asc`

| Input | Description |
| --- | --- |
| `certificate-base64` / `certificate-password` | A **bundle** `.p12` — development / distribution / installer / Developer ID identities can all live in one file, shared across repos, so adding an app doesn't mean managing more certificates. |
| `api-key` / `api-key-id` / `api-issuer` | App Store Connect API key. The key needs the **Admin** role — cloud signing requires it. |
| `project` / `scheme` / `working-directory` | Project and scheme. |
| `platform` | `macos` or `ios`. |
| `version` / `build-number` | `build-number` defaults to `x*10000 + y*100 + z` derived from `version`. |
| `team-id` | Apple Developer Team ID. |
| `release` | `'true'` uploads; anything else rehearses (export + pass Apple's validation, no upload). |

### `dmg`

Same certificate/API-key inputs, plus `signing-identity` (defaults to the first
`Developer ID Application` in the keychain), `volume-name`, `dmg-name`.
The notarized `.dmg` path is exposed as `DMG_PATH` (env) and as the `dmg-path` output.

### `tap-update`

`cask`, `version`, `artifact`, `token`, plus optional `tap` (default `rxliuli/homebrew-tap`)
and `cask-path`. Only the `version` / `sha256` lines are rewritten — `livecheck`, `caveats`
and `zap` are often hand-written and must survive.

## Why it looks like this

1. **The App Store signing identity comes from cloud signing when no app certificate is
   available locally.** The export step (`-exportArchive` + `signingStyle: automatic` +
   API key) gets a managed profile from Apple, and signs with whichever distribution
   identity it can use: a valid `Apple Distribution` from the imported bundle when there
   is one, otherwise a `Cloud Managed Apple Distribution`. Both are accepted by App Store
   Connect — observed on real runs, with the same project, one of each. The certificate
   that is *always* used from the local bundle is the **installer** one, which signs the
   `.pkg` for macOS.
2. **The archive step deliberately does not sign the app**: macOS archives ad-hoc
   (`CODE_SIGN_IDENTITY=-`), iOS archives unsigned. All three constraints together leave
   exactly this one option:
   - automatic signing at archive time wants a **development** identity; with none in the
     keychain, Xcode asks Apple to mint one — whose private key dies with the runner, so
     every run burns a certificate until the account hits Apple's cap (this really
     happened: 10 `Apple Development: Created via API` certificates in one day);
   - Xcode **refuses** an explicitly specified distribution identity together with
     automatic signing (`has conflicting provisioning settings ... has been manually
     specified`);
   - macOS cannot go unsigned either: entitlements travel with the signature, so an
     unsigned archive loses its sandbox entitlements and App Store Connect rejects it
     with `90296`.
3. **The archive step must be able to find a local identity**, hence the certificate
   bundle is imported into a temporary keychain first.
4. **The API key decode has to repair base64 padding.** When the trailing `=` is lost,
   `base64 --decode` silently drops bytes, which surfaces minutes later as an
   unreadable `invalidPEMDocument`.
5. **`altool` is kept on purpose** (Apple has deprecated it): `--validate-app` asks Apple
   to check the build *before* uploading, and that is what makes the rehearsal mode
   possible. The App Store Connect API and Transporter have no equivalent pre-upload
   validation endpoint.
6. **Nothing is submitted for review.** Uploading a build and submitting it for review are
   two different things; the latter doesn't belong in a build pipeline.

## Known limitations

- **Rehearsal mode really talks to Apple** (`altool --validate-app`). So once a given
  `version + build-number` has been uploaded, a rehearsal fails on Apple's duplicate
  check:

  ```
  iris-code : ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE
  previousBundleVersion : 603
  ```

  That's expected — the build number really is taken. Re-releasing means bumping it.
- No review submission (see rule 6), and no SwiftPM `swift build` flavour: `dmg` archives
  an `.xcodeproj`. A SwiftPM package that assembles its own `.app` bundle isn't supported yet.

## Layout

```
scripts/asc.sh              archive → export → validate → (optional) upload
scripts/dmg.sh              archive (Developer ID) → dmg → notarize → staple
scripts/signing-setup.sh    certificate bundle + API key → temporary keychain
scripts/tap-update.sh       bump a cask's version / sha256
asc/action.yml              thin wrapper over scripts/asc.sh
dmg/action.yml              thin wrapper over scripts/dmg.sh
tap-update/action.yml       thin wrapper over scripts/tap-update.sh
```

Build products land in `build/apple-release/` (`.xcarchive`, export directory,
`DistributionSummary.plist`, and the `.dmg`), so a rehearsal leaves something to inspect.
