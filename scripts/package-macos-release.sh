#!/usr/bin/env bash
# Splits a universal Niftty.app into per-architecture copies and zips them
# for GitHub Releases. Sparkle updates then download only the slice the
# user's Mac needs, roughly halving the download size versus a universal
# archive.
#
# Usage: package-macos-release.sh <Niftty.app> <output-dir> <version>
#
# Produces <output-dir>/Niftty-v<version>-arm64.zip and
# <output-dir>/Niftty-v<version>-x86_64.zip. Each bundle is thinned with
# lipo and re-signed ad-hoc (same entitlements and hardened runtime as the
# build.zig resign step).
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "usage: $0 <Niftty.app> <output-dir> <version>" >&2
    exit 1
fi

app_path=$1
out_dir=$2
version=$3
root=$(cd "$(dirname "$0")/.." && pwd)

if [[ ! -d "$app_path" ]]; then
    echo "error: app bundle not found: $app_path" >&2
    exit 1
fi

mkdir -p "$out_dir"

for arch in arm64 x86_64; do
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    ditto "$app_path" "$work/Niftty.app"

    # Thin every universal Mach-O in the bundle: the app executable,
    # embedded frameworks (Sparkle), XPC services, and plug-ins. Files
    # that are already single-arch (or not Mach-O at all) are skipped.
    find "$work/Niftty.app" -type f -print0 | while IFS= read -r -d '' file; do
        if file -b "$file" | grep -q "Mach-O universal"; then
            lipo -thin "$arch" -output "$file.thinned" "$file"
            mv "$file.thinned" "$file"
        fi
    done

    # Ad-hoc re-sign: the signature sealed both architecture slices, so it
    # is invalid after thinning. Mirrors the resign step in
    # src/build/GhosttyXcodebuild.zig for the ReleaseLocal configuration.
    codesign --force --deep --sign - \
        --entitlements "$root/macos/GhosttyReleaseLocal.entitlements" \
        --options=runtime \
        "$work/Niftty.app"
    codesign --verify --deep "$work/Niftty.app"

    # Sanity check: nothing universal may remain, and the executable must
    # be exactly the requested architecture.
    remaining=$(find "$work/Niftty.app" -type f -exec file -b {} + | grep -c "Mach-O universal" || true)
    if [[ "$remaining" -ne 0 ]]; then
        echo "error: $arch bundle still contains universal binaries" >&2
        exit 1
    fi
    lipo -archs "$work/Niftty.app/Contents/MacOS/niftty" | grep -qx "$arch"

    zip_path="$out_dir/Niftty-v$version-$arch.zip"
    rm -f "$zip_path"
    ditto -c -k --sequesterRsrc --keepParent "$work/Niftty.app" "$zip_path"
    echo "packaged $zip_path"

    rm -rf "$work"
    trap - EXIT
done
