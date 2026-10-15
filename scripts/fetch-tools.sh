#!/bin/sh
# Downloads the pinned Betterleaks release into the repo's .cache/bin/.
#
# Version and checksums come from scripts/tools.lock. The archive's sha256 is
# verified before it is extracted. Nothing is installed system-wide.
#
# Usage: scripts/fetch-tools.sh

set -eu

TOOL=betterleaks
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK="$REPO_ROOT/scripts/tools.lock"
BIN_DIR="$REPO_ROOT/.cache/bin"
BIN="$BIN_DIR/$TOOL"

die() {
    printf 'fetch-tools: %s\n' "$*" >&2
    exit 1
}

case $(uname -s) in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    *) die "unsupported OS '$(uname -s)'; supported: Linux, Darwin" ;;
esac
case $(uname -m) in
    x86_64 | amd64) arch=x64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported CPU '$(uname -m)'; supported: x86_64, arm64" ;;
esac
platform="${os}_${arch}"

[ -f "$LOCK" ] || die "missing $LOCK"
set -- $(awk -v t="$TOOL" -v p="$platform" \
    '$1 == t && $3 == p { print $2, $4; exit }' "$LOCK")
[ $# -eq 2 ] || die "no $TOOL entry for $platform in $LOCK"
version=$1
sha256=$2

if [ -x "$BIN" ] && [ "$("$BIN" version 2>/dev/null)" = "$version" ]; then
    exit 0
fi

asset="${TOOL}_${version}_${platform}.tar.gz"
url="https://github.com/$TOOL/$TOOL/releases/download/v$version/$asset"

work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

printf 'fetch-tools: downloading %s\n' "$asset" >&2
if command -v curl >/dev/null 2>&1; then
    curl -fsSL -o "$work/$asset" "$url" || die "download failed: $url"
elif command -v wget >/dev/null 2>&1; then
    wget -q -O "$work/$asset" "$url" || die "download failed: $url"
else
    die "need curl or wget to download $asset"
fi

if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    actual=$(shasum -a 256 "$work/$asset" | awk '{ print $1 }')
else
    die "need sha256sum or shasum to verify $asset"
fi
[ "$actual" = "$sha256" ] ||
    die "checksum mismatch for $asset: expected $sha256, got $actual"

mkdir -p "$work/x"
tar -xzf "$work/$asset" -C "$work/x" "$TOOL" || die "$asset has no '$TOOL' binary"
mkdir -p "$BIN_DIR"
mv "$work/x/$TOOL" "$BIN.new"
chmod +x "$BIN.new"
mv "$BIN.new" "$BIN"
printf 'fetch-tools: installed %s %s to %s\n' "$TOOL" "$version" "$BIN" >&2
