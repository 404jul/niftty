# Releasing Niftty

How a release goes from your machine to every installed copy of the app.

## The moving parts

- **GitHub Release** — each `vX.Y.Z` tag gets a Release page containing:
  - `Niftty-vX.Y.Z-arm64.dmg` (Apple Silicon) and `Niftty-vX.Y.Z-x86_64.dmg`
    (Intel) — drag-and-drop installer DMGs (app beside an Applications
    shortcut), notarized. `Niftty-vX.Y.Z-<arch>.zip` — the same app in the
    archive format Sparkle's updater downloads; separate archives per
    architecture keep updates about half the size of a universal binary.
  - `appcast-arm64.xml` and `appcast-x86_64.xml` — the update feeds.
- **Sparkle** — the updater framework built into the app. On each machine
  it fetches the feed for its own CPU architecture from
  `https://github.com/404jul/niftty/releases/latest/download/appcast-<arch>.xml`
  (a stable GitHub redirect to the newest release), compares versions, and
  installs the matching zip. Updates are verified with an EdDSA signature,
  so nobody but the key holder can push an update to users.
- **`.github/workflows/release.yml`** — does all of the above
  automatically when you push a version tag.

## One-time setup: Sparkle update-signing key

Updates are signed with an EdDSA (ed25519) key. The **private** key lives in
the `SPARKLE_PRIVATE_KEY` repository secret; the matching **public** key is
`SUPublicEDKey` in `macos/Ghostty-Info.plist`.

1. On a Mac (interactive GUI session — the tools use the Keychain):
   download the
   [Sparkle for Swift Package Manager zip](https://github.com/sparkle-project/Sparkle/releases/latest)
   and run `bin/generate_keys`. It stores the private key in your Keychain
   and prints the public key.
2. Put the printed public key into `SUPublicEDKey` in
   `macos/Ghostty-Info.plist`.
3. Export the private key: `bin/generate_keys -x sparkle-private-key.txt`.
   The file contains a single base64 line (44 characters for a modern key).
4. Set the `SPARKLE_PRIVATE_KEY` repository secret to that line — paste
   exactly the file contents, nothing else. Invisible characters (BOM,
   zero-width spaces) make Sparkle's decoder reject the key; the release
   workflow validates the secret format and fails fast with a message
   instead of publishing a broken appcast.

If you lose the private key you must generate a new pair, update
`SUPublicEDKey`, and ship one release installed manually before updates
work again.

## One-time setup: Apple code signing and notarization

The app is signed with a **Developer ID Application** certificate and
notarized by Apple, so downloads open without Gatekeeper warnings.

1. Create a Developer ID Application certificate at
   <https://developer.apple.com/account/resources/certificates/add>.
   Generate a CSR + private key (Keychain Access or `openssl req`), upload
   the CSR, download the `.cer`.
2. Combine the `.cer` and its private key into a `.p12`:
   `openssl x509 -in cert.cer -inform DER -out cert.pem && openssl pkcs12
-export -inkey key.pem -in cert.pem -out signing.p12`
3. Create an **App Store Connect API key** (developer.apple.com → Users
   and Access → Integrations, role Developer) for `notarytool`; note the
   Key ID, Issuer ID, and keep the `.p8`.
4. Add repository secrets:
   - `MAC_CERTIFICATE_P12` — base64 of the `.p12`
   - `MAC_CERTIFICATE_PASSWORD` — the `.p12` password
   - `MAC_SIGNING_IDENTITY` — the full identity string, e.g.
     `Developer ID Application: Your Name (ABCD12345)`
   - `APPLE_API_KEY` — base64 of the `.p8`
   - `APPLE_API_KEY_ID` — the API key ID
   - `APPLE_API_ISSUER_ID` — the issuer UUID

The release workflow imports the certificate into a temporary keychain,
signs each per-architecture bundle (see `scripts/package-macos-release.sh`,
`MAC_SIGNING_IDENTITY`), submits each zip to Apple's notary service with
`notarytool`, staples the ticket, and repackages. Local dry runs without
these secrets fall back to ad-hoc signing.

## Cutting a release

```sh
git tag v0.2.0
git push origin v0.2.0
```

That's it. The workflow builds the app (version stamped from the tag,
build number = commit count), splits it per architecture, signs the
archives, writes the appcasts, and publishes the GitHub Release. You can
also run it manually from the Actions tab ("Release" → "Run workflow",
enter `vX.Y.Z`).

Rules:

- Versions are strict semver `vX.Y.Z` — the workflow rejects anything else.
- Every release's build number (commit count) is higher than the last, so
  Sparkle always sees the new release as an update.
- Users' apps pick the release up on their next automatic update check.

## The repository must be public for updates to work

Sparkle (and anyone downloading the zips) fetches the appcast and
archives from `releases/latest/download/...` **anonymously**. On a
private repository those URLs return 404, so auto-update silently finds
nothing. Releases can still be cut from a private repo (CI works fine),
but flip the repo to public before expecting any installed app to see or
install updates: Settings → General → Danger Zone → Change visibility.
Going public requires no other changes.

## Caveats

- Releases are Developer ID signed and notarized, so fresh downloads
  open without Gatekeeper prompts.
- After publishing, `releases/latest/download/...` points at the new
  release within seconds (on public repos); clients check periodically
  (default once a day).

## Prediction history across updates

Predictions learned from commands are stored in
`~/.local/state/niftty/prediction/history.db`, **not** in `Niftty.app`.
Replacing the app bundle or its executable must not remove this file.
An older app build may be unable to read a newer database format, but
must leave it intact so upgrading again restores predictions.

When changing the history schema, migrate existing commands and ranking
data in a single SQLite transaction with `PRAGMA user_version`; never
drop an older database just because its ranking format changed. Keep a
unit test that opens a populated database from the previous format and
checks its history after the upgrade, and a rollback test for failures.

## Local dry run

To exercise the packaging step without publishing:

```sh
zig build -Doptimize=ReleaseFast
scripts/package-macos-release.sh zig-out/Niftty.app dist 0.0.0-local
```
