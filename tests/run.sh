#!/bin/sh
# Runs the repo's tests with the pinned tools from scripts/tools.lock,
# fetched into .cache/bin/ by scripts/fetch-tools.sh.
#
#   unit    bats files in tests/unit/ and tests/privacy.sh
#   render  bats files in tests/render/ (chezmoi into temp destinations)
#   lint    shellcheck on every tracked shell script, actionlint on
#           .github/workflows/
#   all     unit, render and lint; every mode runs even if one fails
#   system  reserved for slice 3
#
# Exits non-zero if any test or check fails. POSIX sh; render also runs
# under Git Bash on Windows.
#
# Usage: tests/run.sh <unit|render|lint|all>

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.cache/bin"
FETCH="$ROOT/scripts/fetch-tools.sh"

usage() {
    printf 'usage: %s <unit|render|lint|all>\n' "$(basename "$0")" >&2
    exit 2
}

say() {
    printf 'run.sh: %s\n' "$*"
}

# fetch <tool...>: fails the mode when a tool can't be provided.
fetch() {
    "$FETCH" "$@" || {
        say "cannot fetch $*"
        return 1
    }
}

# tool <name>: the cached binary, with .exe on Windows.
tool() {
    if [ -x "$BIN/$1.exe" ]; then
        printf '%s\n' "$BIN/$1.exe"
    else
        printf '%s\n' "$BIN/$1"
    fi
}

# run_bats <dir>: every *.bats file in <dir>; none is not a failure.
run_bats() {
    set -- "$ROOT/$1"/*.bats
    if [ ! -f "$1" ]; then
        say "no bats files in ${1%/*}"
        return 0
    fi
    "$BIN/bats" "$@"
}

mode_unit() {
    # Everything for this platform: the unit tests check run.sh's other
    # modes in a copy of the repo, which reuses this cache.
    fetch || return 1
    status_u=0
    run_bats tests/unit || status_u=1
    sh "$ROOT/tests/privacy.sh" || status_u=1
    return $status_u
}

mode_render() {
    fetch chezmoi bats-core || return 1
    run_bats tests/render
}

# shell_scripts: tracked shell scripts, one per line: *.sh, *.bash, *.bats,
# .githooks/*, and files under scripts/ and tests/ with a shell shebang.
# Fails when git can't list the tracked files.
shell_scripts() {
    # Unquoted paths, so non-ASCII names come out as they are.
    tracked=$(git -C "$ROOT" -c core.quotePath=false ls-files) || return 1
    printf '%s\n' "$tracked" | while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$ROOT/$f" ] || continue
        case $f in
            *.sh | *.bash | *.bats | .githooks/*)
                printf '%s\n' "$f"
                ;;
            scripts/* | tests/*)
                if head -n 1 "$ROOT/$f" |
                    grep -Eq '^#!.*([/ ](sh|bash|dash|ksh|bats))([[:space:]]|$)'; then
                    printf '%s\n' "$f"
                fi
                ;;
        esac
    done
}

mode_lint() {
    fetch shellcheck actionlint || return 1
    status_l=0
    files=$(shell_scripts) || {
        say "cannot list tracked files"
        return 1
    }
    if [ -n "$files" ]; then
        # One name per line; tracked script names have no newlines.
        printf '%s\n' "$files" | (cd "$ROOT" && tr '\n' '\0' |
            xargs -0 "$(tool shellcheck)") || status_l=1
    fi
    workflows=$(git -C "$ROOT" -c core.quotePath=false ls-files '.github/workflows/*.yml' \
        '.github/workflows/*.yaml') || {
        say "cannot list tracked workflows"
        return 1
    }
    if [ -n "$workflows" ]; then
        printf '%s\n' "$workflows" | (cd "$ROOT" && tr '\n' '\0' |
            xargs -0 "$(tool actionlint)" -shellcheck "$(tool shellcheck)") ||
            status_l=1
    fi
    [ $status_l -ne 0 ] || say "lint: shellcheck and actionlint clean"
    return $status_l
}

[ $# -eq 1 ] || usage
case $1 in
    unit | render | lint) modes=$1 ;;
    all) modes="unit render lint" ;;
    system)
        say "system tests are not yet implemented (slice 3)"
        exit 2
        ;;
    *) usage ;;
esac

failed=
for m in $modes; do
    say "== $m"
    "mode_$m" || failed="$failed $m"
done

if [ -n "$failed" ]; then
    say "FAILED:$failed"
    exit 1
fi
say "passed: $modes"
