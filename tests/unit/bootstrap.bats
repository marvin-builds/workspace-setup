#!/usr/bin/env bats
# shellcheck disable=SC2088,SC2016 # literal ~/ in messages; stub code in single quotes
# Tests for bootstrap.sh (slice 3, criteria 1-3).
#
# bootstrap.sh runs with a restricted PATH: a stub dir first, then a dir of
# symlinks to the system's commands without git, apt, apt-get, sudo, curl,
# wget, chezmoi, uname, id and docker. The stubs are:
#   uname    reports $STUB_UNAME_S for `uname` and `uname -s` when set,
#            otherwise the real uname
#   id       reports $STUB_UID for `id -u` (and root for `id -un` when it is
#            0) when set, otherwise the real id
#   sudo     logs "sudo <args>" to $STUB_LOG, then runs the command as the
#            test user (leading options and VAR=value are honoured)
#   apt-get  only where a test adds it; logs "apt-get <args>" and, on an
#            install naming git, puts the real git on the stub PATH
#   curl, wget  log and fail: the tests must not download anything
#   git      a symlink to the real git, left out to simulate a machine
#            without git
# chezmoi is a fake reporting the version pinned in scripts/tools.lock; it
# logs each call (CALL, then one "ARG <arg>" line per argument) to
# $STUB_CHEZMOI_LOG. Tests pre-place it as ~/.local/bin/chezmoi (kept, as
# it has the pinned version) or as the clone's .cache/bin/chezmoi, where
# `scripts/fetch-tools.sh chezmoi` accepts it without downloading.
#
# --repo is a local bare repo made from a copy of this work tree (tracked
# and untracked, not ignored files).
#
# Interface details the brief leaves open, defined here:
#   - root is detected with `id -u`, the OS with `uname -s` (or `uname`).
#   - bootstrap calls chezmoi by its installed path or with ~/.local/bin on
#     PATH; nothing else provides chezmoi.
#   - the chezmoi init call has `init`, `--apply` and `--source <dir>` (or
#     `--source=<dir>`), and the arguments after `--` come last, unchanged
#     and in order.
#   - an unknown option fails (non-zero exit).

load ../helpers/common

BOOTSTRAP="$REPO_ROOT/bootstrap.sh"

setup_file() {
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    fx="$BATS_FILE_TMPDIR"

    # The origin: a bare repo with one commit of this work tree.
    mkdir -p "$fx/tree"
    (cd "$REPO_ROOT" && git ls-files -co --exclude-standard -z |
        while IFS= read -r -d '' f; do [ -e "$f" ] && printf '%s\0' "$f"; done |
        tar --null -T - -cf -) | tar -xf - -C "$fx/tree"
    git -C "$fx/tree" init -q -b main
    git -C "$fx/tree" add -A
    git -C "$fx/tree" -c user.name=Test -c user.email=test@example.invalid \
        commit -q -m 'Fixture'
    git clone -q --bare "$fx/tree" "$fx/origin.git"

    # System commands without the ones the tests control.
    mkdir -p "$fx/sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            case $n in
                git | git-* | apt | apt-get | sudo | curl | wget | chezmoi | uname | id | docker) continue ;;
            esac
            [ -e "$fx/sysbin/$n" ] || [ -L "$fx/sysbin/$n" ] || ln -s "$f" "$fx/sysbin/$n"
        done
    done

    # Every system command name as a stub that only logs (criterion 21).
    mkdir -p "$fx/logbin"
    printf '#!/bin/sh\nprintf "%%s\\n" "${0##*/} $*" >>"$STUB_LOG"\n' >"$fx/logstub"
    chmod +x "$fx/logstub"
    for f in "$fx/sysbin"/* git apt-get sudo curl wget chezmoi uname id; do
        n=${f##*/}
        [ -e "$fx/logbin/$n" ] || ln -s "$fx/logstub" "$fx/logbin/$n"
    done
}

setup() {
    ws_isolate
    GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_GLOBAL
    [ -f "$BOOTSTRAP" ] || { echo "missing bootstrap.sh" >&2; return 1; }
    FX="$BATS_FILE_TMPDIR"
    SYSBIN="$FX/sysbin"
    STUBS="$TEST_TMP/stubs"
    mkdir -p "$STUBS"
    STUB_LOG="$TEST_TMP/stub.log"
    STUB_CHEZMOI_LOG="$TEST_TMP/chezmoi.log"
    : >"$STUB_LOG"
    : >"$STUB_CHEZMOI_LOG"
    export STUB_LOG STUB_CHEZMOI_LOG
    unset STUB_UNAME_S STUB_UID WS_SOURCE_DIR WS_REPO_URL

    # A per-test origin, so tests may add commits to it.
    ORIGIN="$TEST_TMP/origin.git"
    git clone -q --bare "$FX/origin.git" "$ORIGIN"
    SRC="$TEST_TMP/src/workspace-setup"
    PINNED=$(awk '$1 == "chezmoi" { print $2; exit }' "$REPO_ROOT/scripts/tools.lock")

    real_uname=$(command -v uname)
    real_id=$(command -v id)
    REAL_GIT=$(command -v git)

    cat >"$STUBS/uname" <<EOF
#!/bin/sh
if [ -n "\${STUB_UNAME_S:-}" ] && { [ \$# -eq 0 ] || [ "\$1" = -s ]; }; then
    echo "\$STUB_UNAME_S"
    exit 0
fi
exec "$real_uname" "\$@"
EOF
    cat >"$STUBS/id" <<EOF
#!/bin/sh
if [ -n "\${STUB_UID:-}" ]; then
    case "\$*" in
        -u) echo "\$STUB_UID"; exit 0 ;;
        -un | "-u -n" | "-n -u") [ "\$STUB_UID" = 0 ] && { echo root; exit 0; } ;;
    esac
fi
exec "$real_id" "\$@"
EOF
    cat >"$STUBS/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$STUB_LOG"
while [ $# -gt 0 ]; do
    case $1 in
        --) shift; break ;;
        -*) shift ;;
        *=*) export "$1"; shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
    for t in curl wget; do
        printf '#!/bin/sh\nprintf "%s %%s\\n" "$*" >>"$STUB_LOG"\necho "%s: network is disabled in tests" >&2\nexit 1\n' "$t" "$t" >"$STUBS/$t"
    done
    chmod +x "$STUBS"/*
    ln -s "$REAL_GIT" "$STUBS/git"
}

# add_apt: an apt-get stub that "installs" git by linking the real one.
add_apt() {
    cat >"$STUBS/apt-get" <<EOF
#!/bin/sh
printf 'apt-get %s\n' "\$*" >>"\$STUB_LOG"
case " \$* " in
    *" install "*" git "* | *" install "*" git") ln -sf "$REAL_GIT" "$STUBS/git" ;;
esac
exit 0
EOF
    chmod +x "$STUBS/apt-get"
}

# fake_chezmoi <path> <version> <variant>: the fake chezmoi binary.
fake_chezmoi() {
    mkdir -p "$(dirname "$1")"
    cat >"$1" <<EOF
#!/bin/sh
# fake chezmoi, variant $3
case "\${1:-}" in
    --version) echo "chezmoi version v$2, commit fake, built at 2026-01-01T00:00:00Z, built by test"; exit 0 ;;
esac
{ echo CALL; for a in "\$@"; do printf 'ARG %s\n' "\$a"; done; } >>"\$STUB_CHEZMOI_LOG"
exit 0
EOF
    chmod +x "$1"
}

# home_chezmoi: the pinned fake as ~/.local/bin/chezmoi.
home_chezmoi() {
    fake_chezmoi "$HOME/.local/bin/chezmoi" "$PINNED" home
}

# preclone: clones $ORIGIN to $SRC as a user would have.
preclone() {
    mkdir -p "$(dirname "$SRC")"
    git clone -q "$ORIGIN" "$SRC"
}

# bs <args...>: runs bootstrap.sh with the restricted PATH.
bs() {
    run env PATH="$STUBS:$SYSBIN" sh "$BOOTSTRAP" "$@"
}

# bs_default: the usual flags.
bs_default() {
    bs --source-dir "$SRC" --repo "$ORIGIN" "$@"
}

expect_no_clone() {
    [ ! -e "$SRC" ] || { echo "the source dir was created" >&2; return 1; }
}

expect_no_sudo() {
    if grep -q '^sudo' "$STUB_LOG"; then
        printf 'sudo was called:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    fi
}

expect_no_download() {
    if grep -qE '^(curl|wget)' "$STUB_LOG"; then
        printf 'bootstrap tried to download:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# chezmoi_calls: each logged call on one line, arguments joined by |.
chezmoi_calls() {
    awk '
        /^CALL$/ { if (n++) print line; line = ""; next }
        /^ARG / { a = substr($0, 5); line = (line == "" ? a : line "|" a) }
        END { if (n) print line }
    ' "$STUB_CHEZMOI_LOG"
}

# ---------------------------------------------------------- file shape

@test "bootstrap: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$BOOTSTRAP")"
    run sh -n "$BOOTSTRAP"
    expect_status 0
}

@test "bootstrap: defaults to the public repo URL" {
    grep -qF 'https://github.com/marvin-builds/workspace-setup.git' "$BOOTSTRAP" || {
        echo "bootstrap.sh lacks the default --repo URL" >&2
        return 1
    }
}

@test "bootstrap: README shows the curl | sh entry" {
    grep -qF 'curl -fsSL https://raw.githubusercontent.com/marvin-builds/workspace-setup/main/bootstrap.sh | sh' \
        "$REPO_ROOT/README.md" || {
        echo "README.md lacks the curl ... | sh line" >&2
        return 1
    }
}

@test "bootstrap: an unknown option fails" {
    home_chezmoi
    bs_default --no-such-option
    expect_failure
    expect_no_clone
}

# ------------------------------------------------------------- refusals

@test "bootstrap: refuses anything but Linux" {
    home_chezmoi
    STUB_UNAME_S=Darwin
    export STUB_UNAME_S
    bs_default
    expect_failure
    expect_output_matches 'Linux'
    expect_no_clone
    expect_no_sudo
    expect_equal "chezmoi calls" "" "$(chezmoi_calls)"
}

@test "bootstrap: refuses to run as root" {
    home_chezmoi
    STUB_UID=0
    export STUB_UID
    bs_default
    expect_failure
    expect_output_matches 'root'
    expect_no_clone
    expect_no_sudo
    expect_equal "chezmoi calls" "" "$(chezmoi_calls)"
}

# ------------------------------------------------------------------ git

@test "bootstrap: installs git with sudo apt-get when it is missing" {
    rm "$STUBS/git"
    add_apt
    home_chezmoi
    bs_default
    expect_status 0
    grep -E '^apt-get( .*)? install( .*)?$' "$STUB_LOG" | grep -E '(^| )-y( |$)' |
        grep -qE '(^| )git( |$)' || {
        printf 'no "apt-get install -y ... git"; log:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    }
    grep -qE '^sudo .*apt-get' "$STUB_LOG" || {
        printf 'apt-get did not run through sudo; log:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    }
    # Only git and its fetch prerequisites, nothing else system-wide.
    extra=$(grep -E '^apt-get( .*)? install' "$STUB_LOG" |
        tr ' ' '\n' | grep -vE '^(apt-get|install|-y|-q+|--yes|--quiet|--no-install-recommends|git|ca-certificates|curl|)$' || true)
    expect_equal "other packages installed" "" "$extra"
    [ -d "$SRC/.git" ] || { echo "no clone after installing git" >&2; return 1; }
}

@test "bootstrap: fails with a hint when git is missing and there is no apt" {
    rm "$STUBS/git"
    home_chezmoi
    bs_default
    expect_failure
    expect_output_matches 'git'
    expect_no_clone
    expect_no_sudo
}

@test "bootstrap: with git present, nothing is installed system-wide" {
    add_apt
    home_chezmoi
    bs_default
    expect_status 0
    expect_no_sudo
    if grep -q '^apt-get' "$STUB_LOG"; then
        printf 'apt-get was called:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# ---------------------------------------------------------------- clone

@test "bootstrap: clones --repo into --source-dir when it is absent" {
    home_chezmoi
    bs_default
    expect_status 0
    expect_equal "origin" "$ORIGIN" "$(git -C "$SRC" remote get-url origin)"
    expect_equal "HEAD" "$(git -C "$ORIGIN" rev-parse HEAD)" "$(git -C "$SRC" rev-parse HEAD)"
    expect_no_download
}

@test "bootstrap: default source dir is ~/dev/workspace-setup" {
    home_chezmoi
    bs --repo "$ORIGIN"
    expect_status 0
    expect_equal "origin" "$ORIGIN" "$(git -C "$HOME/dev/workspace-setup" remote get-url origin)"
}

@test "bootstrap: WS_SOURCE_DIR and WS_REPO_URL work like the flags" {
    home_chezmoi
    WS_SOURCE_DIR=$SRC
    WS_REPO_URL=$ORIGIN
    export WS_SOURCE_DIR WS_REPO_URL
    bs
    expect_status 0
    expect_equal "origin" "$ORIGIN" "$(git -C "$SRC" remote get-url origin)"
}

@test "bootstrap: starts from stdin, as with curl | sh" {
    home_chezmoi
    mkdir -p "$TEST_TMP/cwd"
    cd "$TEST_TMP/cwd"
    run env PATH="$STUBS:$SYSBIN" sh -s -- --source-dir "$SRC" --repo "$ORIGIN" <"$BOOTSTRAP"
    expect_status 0
    expect_equal "origin" "$ORIGIN" "$(git -C "$SRC" remote get-url origin)"
}

@test "bootstrap: an existing clone with the same origin is used as is" {
    home_chezmoi
    preclone
    head_before=$(git -C "$SRC" rev-parse HEAD)
    # Work in progress: a local commit, a modified and an untracked file.
    git -C "$SRC" -c user.name=Test -c user.email=test@example.invalid \
        commit -q --allow-empty -m 'Local work'
    local_head=$(git -C "$SRC" rev-parse HEAD)
    printf 'changed\n' >>"$SRC/README.md"
    printf 'mine\n' >"$SRC/wip.txt"
    readme=$(cksum <"$SRC/README.md")
    # And a newer commit upstream, which must not be pulled.
    git clone -q "$ORIGIN" "$TEST_TMP/other"
    git -C "$TEST_TMP/other" -c user.name=Test -c user.email=test@example.invalid \
        commit -q --allow-empty -m 'Upstream work'
    git -C "$TEST_TMP/other" push -q origin HEAD
    bs_default
    expect_status 0
    expect_equal "HEAD" "$local_head" "$(git -C "$SRC" rev-parse HEAD)"
    [ "$head_before" != "$local_head" ]
    expect_equal "modified file" "$readme" "$(cksum <"$SRC/README.md")"
    expect_equal "untracked file" mine "$(cat "$SRC/wip.txt")"
}

@test "bootstrap: an existing clone with another origin fails untouched" {
    home_chezmoi
    preclone
    git -C "$SRC" remote set-url origin "https://example.invalid/octo-one/other.git"
    printf 'mine\n' >"$SRC/wip.txt"
    head=$(git -C "$SRC" rev-parse HEAD)
    bs_default
    expect_failure
    expect_output_matches 'origin'
    expect_equal "HEAD" "$head" "$(git -C "$SRC" rev-parse HEAD)"
    expect_equal "untracked file" mine "$(cat "$SRC/wip.txt")"
    expect_equal "origin" "https://example.invalid/octo-one/other.git" "$(git -C "$SRC" remote get-url origin)"
    expect_equal "chezmoi calls" "" "$(chezmoi_calls)"
}

@test "bootstrap: an existing dir that is not a clone fails untouched" {
    home_chezmoi
    mkdir -p "$SRC"
    printf 'mine\n' >"$SRC/notes.txt"
    bs_default
    expect_failure
    [ ! -e "$SRC/.git" ] || { echo "bootstrap made the dir a git repo" >&2; return 1; }
    expect_equal "file" mine "$(cat "$SRC/notes.txt")"
    expect_equal "chezmoi calls" "" "$(chezmoi_calls)"
}

# -------------------------------------------------------------- chezmoi

@test "bootstrap: installs chezmoi from the clone's fetch-tools cache" {
    preclone
    fake_chezmoi "$SRC/.cache/bin/chezmoi" "$PINNED" cache
    bs_default
    expect_status 0
    [ -x "$HOME/.local/bin/chezmoi" ] || { echo "no ~/.local/bin/chezmoi" >&2; return 1; }
    cmp -s "$SRC/.cache/bin/chezmoi" "$HOME/.local/bin/chezmoi" || {
        echo "~/.local/bin/chezmoi is not the verified binary from .cache/bin" >&2
        return 1
    }
    expect_no_download
}

@test "bootstrap: keeps an installed chezmoi of the pinned version" {
    preclone
    fake_chezmoi "$SRC/.cache/bin/chezmoi" "$PINNED" cache
    home_chezmoi
    before=$(cksum <"$HOME/.local/bin/chezmoi")
    bs_default
    expect_status 0
    expect_equal "~/.local/bin/chezmoi" "$before" "$(cksum <"$HOME/.local/bin/chezmoi")"
    expect_no_download
}

@test "bootstrap: replaces an installed chezmoi of another version" {
    preclone
    fake_chezmoi "$SRC/.cache/bin/chezmoi" "$PINNED" cache
    fake_chezmoi "$HOME/.local/bin/chezmoi" 0.0.1 old
    bs_default
    expect_status 0
    cmp -s "$SRC/.cache/bin/chezmoi" "$HOME/.local/bin/chezmoi" || {
        echo "the old chezmoi was not replaced by the pinned one" >&2
        return 1
    }
}

@test "bootstrap: sets core.hooksPath=.githooks in the clone" {
    home_chezmoi
    bs_default
    expect_status 0
    expect_equal "core.hooksPath" .githooks "$(git -C "$SRC" config --local core.hooksPath)"
}

@test "bootstrap: runs chezmoi init --apply --source with the args after --" {
    home_chezmoi
    bs_default -- --promptString "Name=$FAKE_NAME" --promptChoice 'Role=work' --promptBool 'CI=true'
    expect_status 0
    call=$(chezmoi_calls | grep -E '(^|\|)init(\||$)' | head -n 1)
    [ -n "$call" ] || {
        printf 'no chezmoi init call; calls:\n%s\n' "$(chezmoi_calls)" >&2
        return 1
    }
    case "|$call|" in *"|--apply|"*) ;; *) echo "init lacks --apply: $call" >&2; return 1 ;; esac
    case "|$call|" in
        *"|--source|$SRC|"* | *"|--source=$SRC|"*) ;;
        *) echo "init lacks --source $SRC: $call" >&2; return 1 ;;
    esac
    case "$call" in
        *"|--promptString|Name=$FAKE_NAME|--promptChoice|Role=work|--promptBool|CI=true") ;;
        *) echo "the args after -- are not passed unchanged at the end: $call" >&2; return 1 ;;
    esac
}

# ---------------------------------------------------------- idempotency

# snapshot: everything a second run could change in the clone and home.
snapshot() {
    git -C "$SRC" rev-parse HEAD
    git -C "$SRC" log --all --oneline | wc -l
    git -C "$SRC" status --porcelain --ignored
    cat "$SRC/.git/config"
    (cd "$SRC" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort |
        while IFS= read -r f; do cksum "$f"; done)
    (cd "$HOME" && find . -type f | LC_ALL=C sort |
        while IFS= read -r f; do cksum "$f"; done)
}

@test "bootstrap: a second run succeeds and changes nothing" {
    home_chezmoi
    bs_default -- --promptString "Name=$FAKE_NAME"
    expect_status 0
    before=$(snapshot)
    : >"$STUB_LOG"
    bs_default -- --promptString "Name=$FAKE_NAME"
    expect_status 0
    expect_equal "state after the second run" "$before" "$(snapshot)"
    expect_no_sudo
    expect_no_download
}

# ------------------------------------------- review round 1 (21, 22)

# run_prefix <bytes>: the first <bytes> of bootstrap.sh through `sh -s`,
# every command on PATH a logging stub, in an empty home and work dir.
run_prefix() {
    head -c "$1" "$BOOTSTRAP" | (cd "$PWORK" && env -i HOME="$PHOME" PATH="$FX/logbin" \
        STUB_LOG="$STUB_LOG" "$SH" -s -- --source-dir "$PHOME/src" --repo "$ORIGIN") \
        >/dev/null 2>&1 || true
}

@test "bootstrap: no truncated download runs anything (21)" {
    SH=$(command -v sh)
    PHOME="$TEST_TMP/phome"
    PWORK="$TEST_TMP/pwork"
    mkdir -p "$PHOME" "$PWORK"
    # Control: the whole script does run commands.
    run_prefix "$(wc -c <"$BOOTSTRAP")"
    [ -s "$STUB_LOG" ] || { echo "control: the full script ran no command" >&2; return 1; }
    rm -rf "$PHOME" "$PWORK"
    mkdir -p "$PHOME" "$PWORK"
    : >"$STUB_LOG"
    # The complete length: up to the end of the last line that is not blank
    # or a comment. Shorter prefixes must run nothing.
    full=$(LC_ALL=C awk '{ len += length($0) + 1; if ($0 !~ /^[[:space:]]*(#|$)/) last = len - 1 } END { print last }' "$BOOTSTRAP")
    # Cut points: every line end, every 29th byte,
    # every byte of the last 300 (where the call to the body sits).
    cuts=$( {
        LC_ALL=C awk '{ len += length($0) + 1; print len }' "$BOOTSTRAP"
        i=0; while [ $i -lt "$full" ]; do echo $i; i=$((i + 29)); done
        i=$((full - 300)); [ $i -ge 0 ] || i=0
        while [ $i -lt "$full" ]; do echo $i; i=$((i + 1)); done
    } | awk -v max="$full" '$1 < max' | LC_ALL=C sort -nu)
    for n in $cuts; do
        run_prefix "$n"
        if [ -s "$STUB_LOG" ] || [ -n "$(ls -A "$PHOME")$(ls -A "$PWORK")" ]; then
            printf 'the first %s of %s bytes ran something; log:\n%s\nfiles: %s\ncut ends with:\n%s\n' \
                "$n" "$full" "$(cat "$STUB_LOG")" "$(ls -A "$PHOME") $(ls -A "$PWORK")" \
                "$(head -c "$n" "$BOOTSTRAP" | tail -n 2)" >&2
            return 1
        fi
    done
}

@test "bootstrap: CDPATH is ignored and a relative --source-dir works (22)" {
    home_chezmoi
    work="$TEST_TMP/work"
    decoy="$TEST_TMP/decoy"
    mkdir -p "$work" "$decoy/src/ws"
    printf 'decoy\n' >"$decoy/src/ws/file"
    cp -R "$ORIGIN" "$work/origin.git"
    git init -q --bare "$decoy/origin.git"
    cd "$work"
    CDPATH=$decoy
    export CDPATH
    bs --source-dir src/ws --repo origin.git
    unset CDPATH
    expect_status 0
    [ -d "$work/src/ws/.git" ] || { echo "no clone at $work/src/ws" >&2; return 1; }
    expect_equal "decoy" "file" "$(ls -A "$decoy/src/ws")"
    expect_equal "origin" "$work/origin.git" "$(git -C "$work/src/ws" remote get-url origin)"
    call=$(chezmoi_calls | grep -E '(^|\|)init(\||$)' | head -n 1)
    case "|$call|" in
        *"|--source|$work/src/ws|"* | *"|--source=$work/src/ws|"*) ;;
        *) echo "init lacks --source $work/src/ws: $call" >&2; return 1 ;;
    esac
}

@test "bootstrap: a rerun with the same relative local --repo succeeds (22)" {
    home_chezmoi
    work="$TEST_TMP/work"
    mkdir -p "$work"
    cp -R "$ORIGIN" "$work/origin.git"
    cd "$work"
    bs --source-dir src/ws --repo origin.git
    expect_status 0
    bs --source-dir src/ws --repo origin.git
    expect_status 0
    bs --source-dir "$work/src/ws" --repo ./origin.git
    expect_status 0
}
