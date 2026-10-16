#!/bin/sh
# Downloads pinned tools into the repo's .cache/bin/.
#
# Versions and checksums come from scripts/tools.lock (one normalised
# platform key per line); the release asset name for each tool and platform
# is built here. Every run checks the cached binary's version and replaces
# it when it differs from the lock. The download's sha256 is verified before
# anything is extracted. Nothing is installed system-wide.
#
# Tools: betterleaks, chezmoi, actionlint, shellcheck, bats-core (installed
# as .cache/bin/bats, with the bats-core tree in .cache/bats-core/).
# Platforms: Linux and macOS on amd64 and arm64, and Git Bash on Windows
# (MINGW*/MSYS*, platform windows_amd64, .zip assets, .exe binaries) for the
# tools that publish Windows builds.
#
# Usage: scripts/fetch-tools.sh [tool...]
#        Without tools: every tool with an entry for this platform.

set -eu

TOOLS="betterleaks chezmoi actionlint shellcheck bats-core"
REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOCK="$REPO_ROOT/scripts/tools.lock"
CACHE_DIR="$REPO_ROOT/.cache"
BIN_DIR="$CACHE_DIR/bin"

die() {
    printf 'fetch-tools: %s\n' "$*" >&2
    exit 1
}

say() {
    printf 'fetch-tools: %s\n' "$*" >&2
}

is_known_tool() {
    for known in $TOOLS; do
        [ "$1" = "$known" ] && return 0
    done
    return 1
}

for tool in "$@"; do
    is_known_tool "$tool" || die "unknown tool '$tool'; known: $TOOLS"
done

# ------------------------------------------------------------- platform

uname_s=$(uname -s)
uname_m=$(uname -m)
case $uname_s in
    Linux) os=linux ;;
    Darwin) os=darwin ;;
    MINGW* | MSYS*) os=windows ;;
    *) die "unsupported OS '$uname_s'; supported: Linux, Darwin, Git Bash on Windows (MINGW*/MSYS*)" ;;
esac
case $uname_m in
    x86_64 | amd64) arch=amd64 ;;
    aarch64 | arm64) arch=arm64 ;;
    *) die "unsupported CPU '$uname_m'; supported: x86_64, arm64" ;;
esac
platform="${os}_${arch}"
exe=
[ "$os" != windows ] || exe=.exe

[ -f "$LOCK" ] || die "missing $LOCK"

# lock_entry <tool>: prints "<version> <sha256>" for this platform (or the
# tool's platform-independent `any` entry), nothing if there is none.
lock_entry() {
    awk -v t="$1" -v p="$platform" '
        /^[ \t]*(#|$)/ { next }
        $1 == t && ($3 == p || $3 == "any") { print $2, $4; exit }
    ' "$LOCK"
}

# ------------------------------------------------------------ tool specs

# spec <tool> <version>: sets the release asset and its URL, the archive
# kind, the member to extract and the installed binary path.
spec() {
    case $1 in
        betterleaks)
            # Betterleaks names amd64 x64 in its assets.
            a=$arch
            [ "$a" != amd64 ] || a=x64
            asset="betterleaks_$2_${os}_$a.tar.gz"
            url="https://github.com/betterleaks/betterleaks/releases/download/v$2/$asset"
            member=betterleaks
            ;;
        chezmoi | actionlint)
            if [ "$os" = windows ]; then
                asset="$1_$2_${platform}.zip"
            else
                asset="$1_$2_${platform}.tar.gz"
            fi
            if [ "$1" = chezmoi ]; then
                url="https://github.com/twpayne/chezmoi/releases/download/v$2/$asset"
            else
                url="https://github.com/rhysd/actionlint/releases/download/v$2/$asset"
            fi
            member="$1$exe"
            ;;
        shellcheck)
            case $arch in
                amd64) a=x86_64 ;;
                arm64) a=aarch64 ;;
            esac
            asset="shellcheck-v$2.$os.$a.tar.xz"
            url="https://github.com/koalaman/shellcheck/releases/download/v$2/$asset"
            member="shellcheck-v$2/shellcheck"
            ;;
        bats-core)
            asset="bats-core-$2.tar.gz"
            url="https://github.com/bats-core/bats-core/archive/refs/tags/v$2.tar.gz"
            member="bats-core-$2"
            ;;
    esac
    case $1 in
        bats-core) bin="$BIN_DIR/bats" ;;
        *) bin="$BIN_DIR/$1$exe" ;;
    esac
}

# installed_version_ok <tool> <version>: the cached binary reports <version>.
installed_version_ok() {
    [ -x "$bin" ] || return 1
    case $1 in
        betterleaks)
            [ "$("$bin" version 2>/dev/null)" = "$2" ]
            ;;
        chezmoi)
            case $("$bin" --version 2>/dev/null) in
                *"version v$2,"*) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        actionlint)
            [ "$("$bin" -version 2>/dev/null | head -n 1)" = "$2" ]
            ;;
        shellcheck)
            "$bin" --version 2>/dev/null | grep -qx "version: $2"
            ;;
        bats-core)
            [ "$("$bin" --version 2>/dev/null)" = "Bats $2" ]
            ;;
    esac
}

# ------------------------------------------------------------- helpers

download() {
    say "downloading $asset"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$1" "$url" || die "download failed: $url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$1" "$url" || die "download failed: $url"
    else
        die "need curl or wget to download $asset"
    fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{ print $1 }'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{ print $1 }'
    else
        die "need sha256sum or shasum to verify $asset"
    fi
}

# extract <archive> <dir> <member>: only called after the checksum passed.
extract() {
    case $asset in
        *.tar.gz) tar -xzf "$1" -C "$2" "$3" ;;
        *.tar.xz) tar -xJf "$1" -C "$2" "$3" ;;
        *.zip)
            if command -v unzip >/dev/null 2>&1; then
                unzip -q -o "$1" "$3" -d "$2"
            elif command -v bsdtar >/dev/null 2>&1; then
                bsdtar -xf "$1" -C "$2" "$3"
            else
                die "need unzip or bsdtar to extract $asset"
            fi
            ;;
    esac || die "cannot extract '$3' from $asset"
}

# fetch <tool>: makes sure the pinned version is in .cache/bin.
fetch() {
    tool=$1
    # shellcheck disable=SC2046 # splits "<version> <sha256>"
    set -- $(lock_entry "$tool")
    [ $# -eq 2 ] || die "no $tool entry for platform $platform in $LOCK"
    version=$1
    sha256=$2
    spec "$tool" "$version"

    if installed_version_ok "$tool" "$version"; then
        return 0
    fi

    rm -rf "$work/dl" "$work/x"
    mkdir -p "$work/dl" "$work/x"
    download "$work/dl/$asset"
    actual=$(sha256_of "$work/dl/$asset")
    [ "$actual" = "$sha256" ] ||
        die "checksum mismatch for $asset: expected $sha256, got $actual"

    extract "$work/dl/$asset" "$work/x" "$member"
    mkdir -p "$BIN_DIR"
    if [ "$tool" = bats-core ]; then
        # bats needs its whole tree (libexec, lib); a wrapper in bin runs it.
        rm -rf "$CACHE_DIR/bats-core"
        mv "$work/x/$member" "$CACHE_DIR/bats-core"
        # shellcheck disable=SC2016 # the wrapper's code, expanded when it runs
        printf '%s\n' '#!/bin/sh' \
            '# Installed by scripts/fetch-tools.sh: runs the cached bats-core.' \
            'exec "$(dirname "$0")/../bats-core/bin/bats" "$@"' >"$bin.new"
    else
        [ -f "$work/x/$member" ] || die "$asset has no '$member'"
        mv "$work/x/$member" "$bin.new"
    fi
    chmod +x "$bin.new"
    mv "$bin.new" "$bin"
    installed_version_ok "$tool" "$version" ||
        die "installed $tool does not report version $version"
    say "installed $tool $version to $bin"
}

# ----------------------------------------------------------------- main

work=$(mktemp -d "${TMPDIR:-/tmp}/fetch-tools.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

if [ $# -eq 0 ]; then
    for tool in $TOOLS; do
        if [ -n "$(lock_entry "$tool")" ]; then
            set -- "$@" "$tool"
        else
            say "skipping $tool: no entry for platform $platform"
        fi
    done
fi

for tool in "$@"; do
    fetch "$tool"
done
