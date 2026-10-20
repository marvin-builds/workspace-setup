#!/usr/bin/env bats
# Tests for the ws dispatcher (slice 3, criterion 9).
#
# Interface defined here:
#   source file   home/dot_local/bin/executable_ws  (plain POSIX sh, no .tmpl)
#   installed as  ~/.local/bin/ws
#   commands      $HOME/.local/libexec/ws/ws-<cmd>.<ext>, found relative to
#                 $HOME (not to where ws itself lives)
#   .sh           run as `sh <file> <args...>`, so no exec bit is needed;
#                 other extensions are reserved and not run
#   exit status   the command's; 2 for no, unknown or missing command, and
#                 then the available commands (names without ws- and
#                 extension) are listed
#   <cmd>         a plain name; one holding / is refused like an unknown one
#
# The tests install the source files into a fake HOME.

load ../helpers/common

WS_SRC="$REPO_ROOT/home/dot_local/bin/executable_ws"
DOCTOR_SRC="$REPO_ROOT/home/dot_local/libexec/ws/ws-doctor.sh"

setup() {
    ws_isolate
    [ -f "$WS_SRC" ] || { echo "missing home/dot_local/bin/executable_ws" >&2; return 1; }
    LIBEXEC="$HOME/.local/libexec/ws"
    mkdir -p "$HOME/.local/bin" "$LIBEXEC"
    cp "$WS_SRC" "$HOME/.local/bin/ws"
    chmod +x "$HOME/.local/bin/ws"
    WS="$HOME/.local/bin/ws"
    # A command without exec bit: prints its arguments joined by |.
    cat >"$LIBEXEC/ws-hello.sh" <<'EOF'
out=hello
for a in "$@"; do out="$out|$a"; done
printf '%s\n' "$out"
EOF
    chmod 644 "$LIBEXEC/ws-hello.sh"
    printf 'exit 3\n' >"$LIBEXEC/ws-three.sh"
}

@test "ws: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$WS_SRC")"
    run sh -n "$WS_SRC"
    expect_status 0
}

@test "ws: runs ws-<cmd>.sh with sh and passes the arguments unchanged" {
    run "$WS" hello a 'b c' '' '*'
    expect_status 0
    expect_equal "output" 'hello|a|b c||*' "$output"
}

@test "ws: works from any directory" {
    mkdir -p "$TEST_TMP/elsewhere"
    cd "$TEST_TMP/elsewhere"
    run "$WS" hello x
    expect_status 0
    expect_equal "output" 'hello|x' "$output"
}

@test "ws: returns the command's exit status" {
    run "$WS" three
    expect_status 3
}

@test "ws: unknown command exits 2 and lists the available ones" {
    run "$WS" no-such-command
    expect_status 2
    expect_output_matches '(^|[^a-z-])hello([^a-z-]|$)'
    expect_output_matches '(^|[^a-z-])three([^a-z-]|$)'
}

@test "ws: no command exits 2 and lists the available ones" {
    run "$WS"
    expect_status 2
    expect_output_matches '(^|[^a-z-])hello([^a-z-]|$)'
}

@test "ws: other extensions are reserved and not run" {
    marker="$TEST_TMP/ran"
    printf '#!/bin/sh\ntouch "%s"\n' "$marker" >"$LIBEXEC/ws-other.py"
    chmod +x "$LIBEXEC/ws-other.py"
    run "$WS" other
    expect_failure
    [ ! -e "$marker" ] || { echo "ws ran ws-other.py" >&2; return 1; }
}

@test "ws: a command name with a slash is refused" {
    marker="$TEST_TMP/ran"
    mkdir -p "$LIBEXEC/ws-sub"
    printf 'touch "%s"\n' "$marker" >"$LIBEXEC/ws-sub/x.sh"
    run "$WS" sub/x
    expect_status 2
    [ ! -e "$marker" ] || { echo "ws ran a command from a subdirectory" >&2; return 1; }
}

@test "ws: doctor is dispatched to ws-doctor.sh" {
    [ -f "$DOCTOR_SRC" ] || { echo "missing home/dot_local/libexec/ws/ws-doctor.sh" >&2; return 1; }
    # A stand-in doctor proves the dispatch without depending on its checks.
    printf 'echo "doctor stand-in $#"\n' >"$LIBEXEC/ws-doctor.sh"
    run "$WS" doctor a b
    expect_status 0
    expect_equal "output" 'doctor stand-in 2' "$output"
}
