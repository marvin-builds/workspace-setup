#!/bin/sh
# Sets up a fresh Linux machine from workspace-setup with one command:
#
#   curl -fsSL https://raw.githubusercontent.com/marvin-builds/workspace-setup/main/bootstrap.sh | sh
#
# Steps, each skipped when already done, so a second run changes nothing:
#   1. refuse anything but Linux, and root (it would set up root's home)
#   2. install git (and ca-certificates, curl) with sudo apt-get if git is
#      missing; nothing else is installed system-wide
#   3. clone the repo into the source dir; an existing clone with the same
#      origin is used as it is (no pull, no reset)
#   4. install the chezmoi pinned in scripts/tools.lock to
#      ~/.local/bin/chezmoi, downloaded and verified by the clone's
#      scripts/fetch-tools.sh
#   5. set core.hooksPath=.githooks in the clone
#   6. chezmoi init --apply --source <source dir>, plus the arguments
#      after --; the config records the source, so a later plain
#      `chezmoi apply` uses the clone too
#
# Usage: bootstrap.sh [--source-dir DIR] [--repo URL] [-- <chezmoi init args>]
#   --source-dir  (env WS_SOURCE_DIR) the clone that is both the dev clone
#                 and chezmoi's source; default ~/dev/workspace-setup
#   --repo        (env WS_REPO_URL) the repo to clone; a local path works
#                 too; default https://github.com/marvin-builds/workspace-setup.git
# With `curl | sh`, pass options as: ... | sh -s -- --source-dir DIR

# The whole script is one { ... } block: sh parses it only once the closing
# brace has arrived, so a download cut short runs nothing (not even a cut
# call to main).

{
set -eu

# A set CDPATH would make the relative `cd`s below go elsewhere.
unset CDPATH

DEFAULT_REPO=https://github.com/marvin-builds/workspace-setup.git

say() {
    printf 'bootstrap: %s\n' "$*"
}

die() {
    printf 'bootstrap: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat >&2 <<'EOF'
usage: bootstrap.sh [--source-dir DIR] [--repo URL] [-- <chezmoi init args>]
EOF
    exit 2
}

# ---------------------------------------------------------------- steps

check_platform() {
    os=$(uname -s)
    [ "$os" = Linux ] || die "only Linux is supported for now (this is $os)"
    [ "$(id -u)" -ne 0 ] ||
        die "run this as your normal user, not as root: it sets up the home of the user running it"
}

# is_installed <deb package>: dpkg knows it as installed.
is_installed() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q ' installed$'
}

ensure_git() {
    command -v git >/dev/null 2>&1 && return 0
    command -v apt-get >/dev/null 2>&1 ||
        die "git is missing and this is not an apt system; install git with your package manager, then run this again"
    command -v sudo >/dev/null 2>&1 ||
        die "git is missing and sudo is not available to install it; install git, then run this again"
    pkgs=git
    is_installed ca-certificates || pkgs="$pkgs ca-certificates"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        pkgs="$pkgs curl"
    fi
    say "installing $pkgs with sudo apt-get"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -q ||
        die "apt-get update failed"
    # shellcheck disable=SC2086 # a list of package names
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends $pkgs ||
        die "installing $pkgs failed"
    command -v git >/dev/null 2>&1 || die "git is still missing after apt-get install"
}

# norm_url <url>: the URL with GitHub's https, scp-like and ssh forms
# folded into one, so a clone made over ssh matches the https default.
norm_url() {
    u=$1
    case $u in
        https://github.com/*) u="github.com/${u#https://github.com/}" ;;
        git@github.com:*) u="github.com/${u#git@github.com:}" ;;
        ssh://git@github.com/*) u="github.com/${u#ssh://git@github.com/}" ;;
    esac
    u=${u%/}
    u=${u%.git}
    case $u in
        github.com/*) u=$(printf '%s\n' "$u" | tr '[:upper:]' '[:lower:]') ;;
    esac
    printf '%s\n' "$u"
}

ensure_clone() {
    if [ -e "$source_dir" ] || [ -L "$source_dir" ]; then
        [ -d "$source_dir" ] && [ -e "$source_dir/.git" ] ||
            die "$source_dir exists but is not a git clone; move it away or pass --source-dir"
        origin=$(git -C "$source_dir" remote get-url origin 2>/dev/null) ||
            die "$source_dir is a git clone without an origin remote; expected $repo"
        [ "$(norm_url "$origin")" = "$(norm_url "$repo")" ] ||
            die "$source_dir has origin $origin, expected $repo"
        say "using the existing clone $source_dir as it is"
        return 0
    fi
    say "cloning $repo into $source_dir"
    mkdir -p "$(dirname "$source_dir")"
    git clone -q -- "$repo" "$source_dir" || die "cloning $repo failed"
}

ensure_chezmoi() {
    lock="$source_dir/scripts/tools.lock"
    [ -f "$lock" ] || die "$lock is missing; is $source_dir a clone of workspace-setup?"
    version=$(awk '$1 == "chezmoi" { print $2; exit }' "$lock")
    [ -n "$version" ] || die "no chezmoi version in $lock"
    target="$HOME/.local/bin/chezmoi"
    if [ -x "$target" ]; then
        case $("$target" --version 2>/dev/null) in
            *"version v$version,"*)
                say "chezmoi $version is installed"
                return 0
                ;;
        esac
    fi
    say "installing chezmoi $version to $target"
    sh "$source_dir/scripts/fetch-tools.sh" chezmoi ||
        die "could not fetch chezmoi $version"
    cached="$source_dir/.cache/bin/chezmoi"
    [ -x "$cached" ] || die "fetch-tools.sh left no $cached"
    mkdir -p "$HOME/.local/bin"
    cp "$cached" "$target.new"
    chmod 755 "$target.new"
    mv "$target.new" "$target"
}

ensure_hooks() {
    current=$(git -C "$source_dir" config --local --get core.hooksPath 2>/dev/null) || current=
    [ "$current" = .githooks ] && return 0
    say "setting core.hooksPath=.githooks in $source_dir"
    git -C "$source_dir" config --local core.hooksPath .githooks
}

apply() {
    say "chezmoi init --apply --source $source_dir"
    "$HOME/.local/bin/chezmoi" init --apply --source "$source_dir" "$@" ||
        die "chezmoi init --apply failed"
}

# ----------------------------------------------------------------- main

main() {
    source_dir=${WS_SOURCE_DIR:-$HOME/dev/workspace-setup}
    repo=${WS_REPO_URL:-$DEFAULT_REPO}
    while [ $# -gt 0 ]; do
        case $1 in
            --source-dir)
                [ $# -ge 2 ] || usage
                source_dir=$2
                shift 2
                ;;
            --source-dir=*)
                source_dir=${1#--source-dir=}
                shift
                ;;
            --repo)
                [ $# -ge 2 ] || usage
                repo=$2
                shift 2
                ;;
            --repo=*)
                repo=${1#--repo=}
                shift
                ;;
            --)
                shift
                break
                ;;
            -h | --help) usage ;;
            *)
                printf 'bootstrap: unknown argument: %s\n' "$1" >&2
                usage
                ;;
        esac
    done
    [ -n "$source_dir" ] || die "the source dir is empty"
    [ -n "$repo" ] || die "the repo URL is empty"
    # Absolute paths, so the clone's origin and chezmoi's sourceDir don't
    # depend on where this ran, and a rerun from elsewhere still matches.
    case $source_dir in
        /*) ;;
        *) source_dir="$PWD/$source_dir" ;;
    esac
    case $repo in
        *://*) ;;
        *) [ ! -d "$repo" ] || repo=$(cd "$repo" && pwd) ;;
    esac

    check_platform
    ensure_git
    ensure_clone
    source_dir=$(cd "$source_dir" && pwd)
    ensure_chezmoi
    ensure_hooks
    apply "$@"

    case ":$PATH:" in
        *":$HOME/.local/bin:"*) ;;
        *) say "add ~/.local/bin to PATH (a new login shell does that on most distros)" ;;
    esac
    say "done; check the machine with: ws doctor"
}

main "$@"
}
