# Releasing Niftty

How a release goes from your machine to every installed copy of the app.

## The moving parts

- **GitHub Release** — each `vX.Y.Z` tag gets a Release page containing:
  - `Niftty-vX.Y.Z-arm64.zip` (Apple Silicon) and `Niftty-vX.Y.Z-x86_64.zip`
    (Intel). Separate archives per architecture keep downloads about half
    the size of a universal binary.
  - `appcast-arm64.xml` and `appcast-x86_64.xml` — the update feeds.
- **Sparkle** — the updater framework built into the app. On each machine
  it fetches the feed for its own CPU architecture from
  `https://github.com/404jul/niftty/releases/latest/download/appcast-<arch>.xml`
  (a stable GitHub redirect to the newest release), compares versions, and
  installs the matching zip. Updates are verified with an EdDSA signature,
  so nobody but the key holder can push an update to users.
- **`.github/workflows/release.yml`** — does all of the above
  automatically when you push a version tag.

## One-time setup (already done in this repo, keep for reference)

1. An EdDSA keypair was generated with Sparkle's `generate_keys`. The
   **public** key is `SUPublicEDKey` in `macos/Ghostty-Info.plist` — it
   must never change after users install a build, or updates will be
   rejected.
2. The **private** key is in `.sparkle-private-eddsa-key` (gitignored).
   Add its contents as a repository secret named `SPARKLE_PRIVATE_KEY`
   (Settings → Secrets and variables → Actions), and back the file up
   somewhere safe (password manager). If you lose it, installed apps can
   never be updated in place again.

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

## Caveats

- The app is **ad-hoc signed** (no Apple Developer account), so a fresh
  download may need right-click → *Open* the first time. Updates installed
  by Sparkle do not hit this prompt.
- After publishing, `releases/latest/download/...` points at the new
  release within seconds; clients check periodically (default once a day).

## Local dry run

To exercise the packaging step without publishing:

```sh
zig build -Doptimize=ReleaseFast
scripts/package-macos-release.sh zig-out/Niftty.app dist 0.0.0-local
```
