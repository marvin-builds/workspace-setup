#!/usr/bin/env bats
# Unit tests for the mise tool installer (slice 6, criteria 7-9 and 20):
# the template home/.chezmoiscripts/run_onchange_after_install-tools.sh.tmpl
# is rendered with the pinned chezmoi and the result is run with a stub
# mise. Nothing reaches the real mise, sudo or apt.
#
# Interface (the implementation follows this; rendering is covered in
# tests/render/tools.bats):
#
#   With CHEZMOI_DEST_DIR equal to CHEZMOI_HOME_DIR, the rendered script
#   runs `mise install --locked` once (more flags allowed, no tool names
#   needed) and exits with mise's status; mise's error output reaches the
#   caller, so a failed install names its cause. mise missing from PATH:
#   exit non-zero naming mise. No sudo, and MISE_DATA_DIR is left as it
#   is, so tools go under the user's mise data dir.
#
#   Otherwise (destination guard): one line containing "skip", exit 0,
#   mise not called.
#
# Stub mise (decided with the test writer): appends its arguments as one
# line to $MISE_LOG and MISE_DATA_DIR=<value> to $MISE_ENV_LOG; with
# STUB_MISE_FAIL set, prints "stub-mise: <value>" on stderr and exits 3;
# else exits 0.

load ../helpers/common

TMPL=home/.chezmoiscripts/run_onchange_after_install-tools.sh.tmpl

setup_file() {
    # System commands without mise and the guarded ones.
    sysbin="$BATS_FILE_TMPDIR/sysbin"
    mkdir -p "$sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            case $n in
                mise | sudo | apt | apt-get | su | doas) continue ;;
            esac
            [ -e "$sysbin/$n" ] || [ -L "$sysbin/$n" ] || ln -s "$f" "$sysbin/$n"
        done
    done
}

setup() {
    ws_isolate
    [ "$(uname -s)" = Linux ] || skip "the tool installer is Linux only"
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    SYSBIN="$BATS_FILE_TMPDIR/sysbin"
    STUBS="$TEST_TMP/stubs"
    mkdir -p "$STUBS"
    MISE_LOG="$TEST_TMP/mise.log"
    MISE_ENV_LOG="$TEST_TMP/mise-env.log"
    : >"$MISE_LOG"
    : >"$MISE_ENV_LOG"
    export MISE_LOG MISE_ENV_LOG
    unset STUB_MISE_FAIL MISE_DATA_DIR
    cat >"$STUBS/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_LOG"
printf 'MISE_DATA_DIR=%s\n' "${MISE_DATA_DIR:-}" >>"$MISE_ENV_LOG"
if [ -n "${STUB_MISE_FAIL:-}" ]; then
    printf 'stub-mise: %s\n' "$STUB_MISE_FAIL" >&2
    exit 3
fi
exit 0
EOF
    chmod +x "$STUBS/mise"
    RENDERED="$TEST_TMP/install-tools.sh"
}

# render: the template, rendered for personal-desktop, to $RENDERED.
render() {
    [ -f "$REPO_ROOT/$TMPL" ] || { echo "missing $TMPL" >&2; return 1; }
    "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$HOME" \
        --config "$PROFILES_DIR/personal-desktop.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --file "$REPO_ROOT/$TMPL" >"$RENDERED" || {
        echo "template did not render" >&2
        return 1
    }
    chmod +x "$RENDERED"
}

# run_installer <PATH> [<destination>]: runs the rendered script as chezmoi
# would; the destination defaults to the home.
run_installer() {
    run env PATH="$1" CHEZMOI_WORKING_TREE="$REPO_ROOT" \
        CHEZMOI_SOURCE_DIR="$REPO_ROOT/home" \
        CHEZMOI_DEST_DIR="${2:-$HOME}" CHEZMOI_HOME_DIR="$HOME" \
        "$RENDERED"
}

# install_calls: the logged mise calls whose first argument is install.
install_calls() {
    grep -E '^install( |$)' "$MISE_LOG" || true
}

@test "install-tools: runs mise install --locked once and succeeds (criteria 7, 20)" {
    render
    run_installer "$STUBS:$PATH"
    expect_status 0
    calls=$(install_calls)
    expect_equal "mise install calls" 1 "$(printf '%s' "$calls" | grep -c .)"
    printf '%s\n' "$calls" | grep -qE '(^| )--locked( |$)' || {
        printf 'mise install without --locked: %s\n' "$calls" >&2
        return 1
    }
    expect_guard_untouched
}

@test "install-tools: a failed mise install fails the script and names the cause (criteria 9, 20)" {
    render
    STUB_MISE_FAIL='no lockfile entry for aqua:sxyazi/yazi on linux-x64'
    export STUB_MISE_FAIL
    run_installer "$STUBS:$PATH"
    expect_failure
    expect_output_matches 'stub-mise: no lockfile entry for aqua:sxyazi/yazi on linux-x64'
    expect_guard_untouched
}

@test "install-tools: mise missing from PATH fails naming mise (criterion 9)" {
    render
    run_installer "$SYSBIN"
    expect_failure
    expect_output_matches 'mise'
}

@test "install-tools: another destination skips with one line, mise not called (criteria 8, 20)" {
    render
    run_installer "$STUBS:$PATH" "$TEST_TMP/dest"
    expect_status 0
    expect_equal "output lines" 1 "$(printf '%s\n' "$output" | grep -c .)"
    expect_output_matches '[Ss]kip'
    expect_equal "mise calls" "" "$(cat "$MISE_LOG")"
}

@test "install-tools: no sudo and the user's mise data dir (criterion 9)" {
    render
    bad=$(grep -vE '^[[:space:]]*#' "$RENDERED" | grep -nwE 'sudo|MISE_DATA_DIR|MISE_INSTALL_PATH' || true)
    expect_equal "sudo or install dir overrides in the script" "" "$bad"
    run_installer "$STUBS:$PATH"
    expect_status 0
    bad=$(grep -v '^MISE_DATA_DIR=$' "$MISE_ENV_LOG" || true)
    expect_equal "MISE_DATA_DIR seen by mise" "" "$bad"
    expect_guard_untouched
}
