# shellcheck shell=bash
# Variables are used by the test files that load this; status and output
# are set by bats' run.
# shellcheck disable=SC2034,SC2154
# Shared helpers for the bats tests under tests/unit and tests/render.
#
# Load with `load ../helpers/common` and call ws_isolate in setup(). It points
# HOME, the XDG dirs and TMPDIR into the test's own temp dir, sets
# GIT_CONFIG_NOSYSTEM=1 and drops git identity variables, so no test reads
# the real ~/.config/ws/denylist, the real git config or writes to the real
# home.
#
# Fake data only: the owners and emails below are not real accounts.

REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd)
TOOLS_BIN="$REPO_ROOT/.cache/bin"
PROFILES_DIR="$REPO_ROOT/tests/profiles"

# The home the tests were started with, kept before ws_isolate changes HOME.
WS_REAL_HOME=${WS_REAL_HOME:-$HOME}

FAKE_NAME='Test User'
OWNER1=octo-one
EMAIL1='11111111+octo-one@users.noreply.github.com'
OWNER2=octo-two
EMAIL2='22222222+octo-two@users.noreply.github.com'
FAKE_IDENTITIES="$OWNER1=$EMAIL1 $OWNER2=$EMAIL2"

ws_isolate() {
    TEST_TMP=$BATS_TEST_TMPDIR
    mkdir -p "$TEST_TMP/home" "$TEST_TMP/xdg-config" "$TEST_TMP/xdg-data" \
        "$TEST_TMP/xdg-state" "$TEST_TMP/xdg-cache" "$TEST_TMP/tmp"
    HOME="$TEST_TMP/home"
    XDG_CONFIG_HOME="$TEST_TMP/xdg-config"
    XDG_DATA_HOME="$TEST_TMP/xdg-data"
    XDG_STATE_HOME="$TEST_TMP/xdg-state"
    XDG_CACHE_HOME="$TEST_TMP/xdg-cache"
    TMPDIR="$TEST_TMP/tmp"
    GIT_CONFIG_NOSYSTEM=1
    export HOME XDG_CONFIG_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_CACHE_HOME \
        TMPDIR GIT_CONFIG_NOSYSTEM
    unset GIT_CONFIG_GLOBAL GIT_DIR GIT_WORK_TREE GIT_AUTHOR_NAME \
        GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL \
        WS_DENYLIST
}

# tool_path <name>: prints the cached binary (with .exe on Windows).
tool_path() {
    if [ -x "$TOOLS_BIN/$1" ]; then
        printf '%s\n' "$TOOLS_BIN/$1"
    elif [ -x "$TOOLS_BIN/$1.exe" ]; then
        printf '%s\n' "$TOOLS_BIN/$1.exe"
    else
        return 1
    fi
}

# require_tool <name>: fails the test with a hint when the tool isn't cached.
require_tool() {
    tool_path "$1" >/dev/null && return 0
    printf '%s is not in .cache/bin; run scripts/fetch-tools.sh (tests/run.sh does)\n' "$1" >&2
    return 1
}

# cz <chezmoi args...>: chezmoi on the repo's source state with $PROFILE as
# config, $DEST as destination and cache and state inside the test dir.
cz() {
    "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$REPO_ROOT/home" \
        --destination "$DEST" \
        --config "$PROFILE" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        "$@"
}

# expect_status <n>: after `run`, the exit status must be <n>.
expect_status() {
    [ "$status" -eq "$1" ] && return 0
    printf 'expected exit %s, got %s; output:\n%s\n' "$1" "$status" "$output" >&2
    return 1
}

# expect_failure: after `run`, the exit status must be non-zero.
expect_failure() {
    [ "$status" -ne 0 ] && return 0
    printf 'expected non-zero exit, got 0; output:\n%s\n' "$output" >&2
    return 1
}

# expect_output_matches <extended regex>
expect_output_matches() {
    printf '%s\n' "$output" | grep -qE -- "$1" && return 0
    printf 'output does not match /%s/; output:\n%s\n' "$1" "$output" >&2
    return 1
}

# expect_output_lacks <fixed string>
expect_output_lacks() {
    printf '%s\n' "$output" | grep -qF -- "$1" || return 0
    printf 'output must not contain "%s"; output:\n%s\n' "$1" "$output" >&2
    return 1
}

# expect_equal <label> <expected> <actual>
expect_equal() {
    [ "$2" = "$3" ] && return 0
    printf '%s: expected "%s", got "%s"\n' "$1" "$2" "$3" >&2
    return 1
}
