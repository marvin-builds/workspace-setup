#!/bin/sh
# Runs the repo's tests with the pinned tools from scripts/tools.lock,
# fetched into .cache/bin/ by scripts/fetch-tools.sh.
#
#   unit    bats files in tests/unit/ and tests/privacy.sh
#   render  bats files in tests/render/ (chezmoi into temp destinations)
#   lint    shellcheck on every tracked shell script, actionlint on
#           .github/workflows/
#   all     unit, render and lint; every mode runs even if one fails
#   system  needs Docker: builds tests/system/ and runs the real bootstrap
#           in a fresh container per role (tests/system/run-in-container.sh
#           has the contract). Tests the committed HEAD, since bootstrap
#           clones the repo; commit changes first. Not part of `all`.
#
# Exits non-zero if any test or check fails. POSIX sh; render also runs
# under Git Bash on Windows.
#
# Usage: tests/run.sh <unit|render|lint|all|system>

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="$ROOT/.cache/bin"
FETCH="$ROOT/scripts/fetch-tools.sh"

usage() {
    printf 'usage: %s <unit|render|lint|all|system>\n' "$(basename "$0")" >&2
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

SYSTEM_IMAGE=workspace-setup-system:local
SYSTEM_ROLES="personal work"

mode_system() {
    command -v docker >/dev/null 2>&1 || {
        say "system: docker is not installed or not on PATH"
        return 1
    }
    # The container clones /src, which needs the .git directory itself.
    [ -d "$ROOT/.git" ] || {
        say "system: $ROOT/.git is not a directory (a linked worktree?); run from the main clone"
        return 1
    }
    if [ -n "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
        say "system: uncommitted changes are not tested; the bootstrap clones HEAD"
    fi
    # The current context, read with the machine's own config before it is
    # swapped out, is passed on, so context-based setups keep working. A
    # set DOCKER_HOST already says where to go and conflicts with a context.
    context=
    if [ -z "${DOCKER_HOST:-}" ]; then
        context=${DOCKER_CONTEXT:-$(docker context show 2>/dev/null || true)}
    fi
    # Only public images are pulled, so an empty Docker config is enough,
    # and the machine's own (credential helpers, auth) is never used.
    # CLI plugins (buildx) and context definitions are linked in.
    docker_config=$(mktemp -d "${TMPDIR:-/tmp}/ws-docker-config.XXXXXX") || return 1
    trap 'rm -rf "$docker_config"' EXIT
    trap 'exit 1' HUP INT TERM
    user_config=${DOCKER_CONFIG:-$HOME/.docker}
    for d in cli-plugins contexts; do
        [ ! -d "$user_config/$d" ] || ln -s "$user_config/$d" "$docker_config/$d"
    done
    DOCKER_CONFIG=$docker_config
    export DOCKER_CONFIG
    if [ -n "$context" ]; then
        DOCKER_CONTEXT=$context
        export DOCKER_CONTEXT
    fi
    status_s=0
    docker build -t "$SYSTEM_IMAGE" "$ROOT/tests/system" || {
        say "system: docker build failed"
        status_s=1
    }
    if [ $status_s -eq 0 ]; then
        for role in $SYSTEM_ROLES; do
            say "system: role $role"
            docker run --rm \
                -v "$ROOT:/src:ro" "$SYSTEM_IMAGE" \
                sh /src/tests/system/run-in-container.sh "$role" || {
                say "system: role $role failed"
                status_s=1
            }
        done
    fi
    rm -rf "$docker_config"
    trap - EXIT HUP INT TERM
    [ $status_s -ne 0 ] || say "system: passed for roles $SYSTEM_ROLES"
    return $status_s
}

[ $# -eq 1 ] || usage
case $1 in
    unit | render | lint | system) modes=$1 ;;
    all) modes="unit render lint" ;;
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
