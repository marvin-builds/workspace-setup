#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031,SC2088 # per-test changes to HOME/PATH are meant to stay in the test; ~/dev is literal data
# Tests for ws doctor (slice 3, criteria 10 and 11).
#
# Interface defined here:
#   source file   home/dot_local/libexec/ws/ws-doctor.sh (plain POSIX sh)
#   input         $HOME/.config/ws/expect.tsv (the path chezmoi renders;
#                 not $XDG_CONFIG_HOME), format as in
#                 tests/render/expect-tsv.bats: id, kind, then
#                   command <name> <source> <smoke>
#                   file <path> | absent <path>
#                   line <file> <count> <text>
#                 a leading ~/ in a path means $HOME/. Smoke lines run with sh.
#                 A line of an unknown kind or with too few fields is a FAIL.
#   output        one line per check: `ok`, `FAIL` or `WARN`, whitespace,
#                 the id, optionally whitespace and details. Extra checks
#                 (drift, ~/.gitconfig, hooks) use ids of their own; their
#                 problems are reported on such a line, and a hooks WARN
#                 names the clone (its directory name) on its line.
#                 The last line is a summary holding "<n> ok", "<n> FAIL" and
#                 "<n> WARN", counting the lines above.
#   exit status   0 when no FAIL, 1 otherwise (WARN alone is 0)
#   chezmoi       found on PATH; doctor only reads from it:
#                   `chezmoi status`                  drift when non-empty
#                   `chezmoi execute-template ...`    with a template naming
#                                                     .repos_dir, to get it
#                 It must never call apply, init, re-add, merge or update.
#   ~/.gitconfig  read only through git config -f; the value is never printed.
#   hooks         every git clone directly under repos_dir (a dir with .git)
#                 that has a .githooks/ dir but whose core.hooksPath is not
#                 .githooks gets a WARN.

load ../helpers/common

DOCTOR_SRC="$REPO_ROOT/home/dot_local/libexec/ws/ws-doctor.sh"
TAB=$(printf '\t')

setup() {
    ws_isolate
    [ -f "$DOCTOR_SRC" ] || { echo "missing home/dot_local/libexec/ws/ws-doctor.sh" >&2; return 1; }
    mkdir -p "$HOME/.local/libexec/ws" "$HOME/.config/ws" "$TEST_TMP/stubs" "$TEST_TMP/tools"
    DOCTOR="$HOME/.local/libexec/ws/ws-doctor.sh"
    cp "$DOCTOR_SRC" "$DOCTOR"
    TSV="$HOME/.config/ws/expect.tsv"
    : >"$TSV"

    # Stub chezmoi: logs its arguments, prints STUB_STATUS for status and
    # STUB_REPOS_DIR for execute-template.
    STUB_LOG="$TEST_TMP/chezmoi.log"
    REPOS="$TEST_TMP/repos"
    mkdir -p "$REPOS"
    STUB_STATUS=''
    STUB_REPOS_DIR=$REPOS
    export STUB_LOG STUB_STATUS STUB_REPOS_DIR
    cat >"$TEST_TMP/stubs/chezmoi" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_LOG"
for a in "$@"; do
    case $a in
        status) [ -z "$STUB_STATUS" ] || printf '%s\n' "$STUB_STATUS"; exit 0 ;;
        execute-template) printf '%s' "$STUB_REPOS_DIR"; exit 0 ;;
        --version) echo 'chezmoi version v2.73.1, commit stub, built at 2026-01-01T00:00:00Z, built by stub'; exit 0 ;;
    esac
done
exit 0
EOF
    # tool-a: a command for the command checks; fails with --fail.
    cat >"$TEST_TMP/tools/tool-a" <<'EOF'
#!/bin/sh
[ "${1:-}" != --fail ] || exit 1
echo tool-a
EOF
    chmod +x "$TEST_TMP/stubs/chezmoi" "$TEST_TMP/tools/tool-a"
    mkdir -p "$HOME/.local/bin"
    cp "$TEST_TMP/tools/tool-a" "$HOME/.local/bin/tool-b"
    PATH="$TEST_TMP/stubs:$TEST_TMP/tools:$HOME/.local/bin:$PATH"
    export PATH
}

# tsv <line>...: writes expect.tsv, one argument per line.
tsv() {
    printf '%s\n' "$@" >"$TSV"
}

doctor() {
    run sh "$DOCTOR"
}

# status_of <id>: the status word of the first line for <id>.
status_of() {
    printf '%s\n' "$output" | awk -v id="$1" '
        ($1 == "ok" || $1 == "FAIL" || $1 == "WARN") && $2 == id { print $1; exit }'
}

# expect_check <ok|FAIL|WARN> <id>
expect_check() {
    got=$(status_of "$2")
    [ "$got" = "$1" ] && return 0
    printf 'check %s: expected %s, got "%s"; output:\n%s\n' "$2" "$1" "$got" "$output" >&2
    return 1
}

# lines_with <status>: count of lines starting with that status word.
lines_with() {
    printf '%s\n' "$output" | grep -cE "^$1[[:space:]]" || true
}

# expect_summary: the last line counts the ok, FAIL and WARN lines.
expect_summary() {
    last=$(printf '%s\n' "$output" | tail -n 1)
    for s in ok FAIL WARN; do
        n=$(lines_with "$s")
        printf '%s\n' "$last" | grep -qE "(^|[^0-9])$n $s([^A-Za-z]|$)" || {
            printf 'summary "%s" lacks "%s %s"; output:\n%s\n' "$last" "$n" "$s" "$output" >&2
            return 1
        }
    done
}

# --------------------------------------------------------------- basics

@test "doctor: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$DOCTOR_SRC")"
    run sh -n "$DOCTOR_SRC"
    expect_status 0
}

# cmd-smoke-only has an empty source between two fields: with IFS=tab, a
# plain `read` would merge the fields (tab is IFS whitespace).
@test "doctor: every kind passing gives ok lines, a summary and exit 0" {
    touch "$HOME/present"
    printf 'x = 1\nother\na.*b [c]\n' >"$HOME/lines"
    tsv "cmd-full${TAB}command${TAB}tool-a${TAB}$TEST_TMP/tools/tool-a${TAB}tool-a --version" \
        "cmd-bare${TAB}command${TAB}tool-a${TAB}${TAB}" \
        "cmd-smoke-only${TAB}command${TAB}tool-a${TAB}${TAB}tool-a --version" \
        "cmd-tilde${TAB}command${TAB}tool-b${TAB}~/.local/bin/tool-b${TAB}" \
        "file-tilde${TAB}file${TAB}~/present" \
        "file-abs${TAB}file${TAB}$HOME/present" \
        "absent-ok${TAB}absent${TAB}~/gone" \
        "line-one${TAB}line${TAB}~/lines${TAB}1${TAB}x = 1" \
        "line-fixed${TAB}line${TAB}~/lines${TAB}1${TAB}a.*b [c]" \
        "line-zero${TAB}line${TAB}~/lines${TAB}0${TAB}not there"
    doctor
    expect_status 0
    for id in cmd-full cmd-bare cmd-smoke-only cmd-tilde file-tilde file-abs absent-ok line-one line-fixed line-zero; do
        expect_check ok "$id"
    done
    expect_equal "FAIL lines" 0 "$(lines_with FAIL)"
    expect_summary
}

# expect_fails <id> <tsv line>: that single check fails the run.
expect_fails() {
    tsv "$2"
    doctor
    expect_status 1
    expect_check FAIL "$1"
    expect_summary
}

@test "doctor: command not on PATH fails" {
    expect_fails cmd-missing "cmd-missing${TAB}command${TAB}no-such-tool-x${TAB}${TAB}"
}

@test "doctor: failing smoke command fails" {
    expect_fails cmd-smoke "cmd-smoke${TAB}command${TAB}tool-a${TAB}${TAB}tool-a --fail"
}

@test "doctor: wrong source fails" {
    expect_fails cmd-source "cmd-source${TAB}command${TAB}tool-a${TAB}~/.local/bin/tool-a${TAB}"
}

@test "doctor: source resolved through PATH order (first match counts)" {
    # tool-b also exists earlier on PATH: the resolved one is not ~/.local/bin's.
    cp "$TEST_TMP/tools/tool-a" "$TEST_TMP/tools/tool-b"
    expect_fails cmd-shadowed "cmd-shadowed${TAB}command${TAB}tool-b${TAB}~/.local/bin/tool-b${TAB}"
}

@test "doctor: missing file fails" {
    expect_fails file-missing "file-missing${TAB}file${TAB}~/not-there"
}

@test "doctor: present absent-path fails" {
    touch "$HOME/should-be-gone"
    expect_fails absent-there "absent-there${TAB}absent${TAB}~/should-be-gone"
}

@test "doctor: duplicate lines fail a count of 1" {
    printf 'x = 1\nx = 1\n' >"$HOME/dups"
    expect_fails line-dup "line-dup${TAB}line${TAB}~/dups${TAB}1${TAB}x = 1"
}

@test "doctor: a missing line fails a count of 1" {
    printf 'other\n' >"$HOME/l"
    expect_fails line-gone "line-gone${TAB}line${TAB}~/l${TAB}1${TAB}x = 1"
}

@test "doctor: a line check counts whole lines only" {
    printf 'x = 10\n x = 1\n' >"$HOME/l"
    expect_fails line-partial "line-partial${TAB}line${TAB}~/l${TAB}1${TAB}x = 1"
}

@test "doctor: unknown kind fails" {
    expect_fails odd "odd${TAB}socket${TAB}~/x"
}

@test "doctor: a line with too few fields fails" {
    expect_fails short "short${TAB}file"
}

@test "doctor: mixed results report each check and the right counts" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present" \
        "b-fail${TAB}file${TAB}~/missing" \
        "c-ok${TAB}absent${TAB}~/missing" \
        "d-fail${TAB}command${TAB}no-such-tool-x${TAB}${TAB}"
    doctor
    expect_status 1
    expect_check ok a-ok
    expect_check FAIL b-fail
    expect_check ok c-ok
    expect_check FAIL d-fail
    expect_summary
}

# -------------------------------------------------------- expect.tsv

@test "doctor: missing expect.tsv fails" {
    rm -f "$TSV"
    doctor
    expect_status 1
    expect_output_matches '^FAIL[[:space:]]'
    expect_output_matches 'expect\.tsv'
}

@test "doctor: unreadable expect.tsv fails" {
    [ "$(id -u)" -ne 0 ] || skip "root reads any file"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    chmod 000 "$TSV"
    doctor
    chmod 600 "$TSV"
    expect_status 1
    expect_output_matches '^FAIL[[:space:]]'
    expect_output_matches 'expect\.tsv'
}

@test "doctor: reads ~/.config/ws, not XDG_CONFIG_HOME" {
    touch "$HOME/present"
    tsv "home-tsv${TAB}file${TAB}~/present"
    mkdir -p "$XDG_CONFIG_HOME/ws"
    printf 'xdg-tsv\tfile\t~/missing\n' >"$XDG_CONFIG_HOME/ws/expect.tsv"
    doctor
    expect_status 0
    expect_check ok home-tsv
    expect_output_lacks xdg-tsv
}

# ---------------------------------------------------------------- drift

@test "doctor: drift is a WARN with a hint, and does not fail" {
    STUB_STATUS=' M .config/git/config'
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    expect_output_matches '^WARN[[:space:]]'
    expect_output_matches 'chezmoi diff'
    expect_output_matches 'chezmoi re-add'
    expect_output_matches 'chezmoi merge'
    expect_summary
}

@test "doctor: no drift, no WARN" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    expect_equal "WARN lines" 0 "$(lines_with WARN)"
    grep -qE '(^| )status( |$)' "$STUB_LOG" || { echo "doctor did not run chezmoi status" >&2; return 1; }
}

@test "doctor: only reads from chezmoi" {
    STUB_STATUS=' M .config/git/config'
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    if grep -qE '(^| )(apply|init|re-add|merge|update|add|forget|destroy|purge)( |$)' "$STUB_LOG"; then
        printf 'doctor ran a changing chezmoi command:\n%s\n' "$(cat "$STUB_LOG")" >&2
        return 1
    fi
}

# ---------------------------------------------------------- ~/.gitconfig

SECRET_EMAIL='sentinel-9f3a@example.invalid'
SECRET_NAME='Sentinel Name 7c1d'

@test "doctor: user.email in ~/.gitconfig fails without printing it" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    printf '[user]\n\temail = %s\n' "$SECRET_EMAIL" >"$HOME/.gitconfig"
    doctor
    expect_status 1
    expect_output_matches '^FAIL[[:space:]]'
    expect_output_matches 'gitconfig'
    expect_output_lacks "$SECRET_EMAIL"
    expect_output_lacks "sentinel-9f3a"
    expect_summary
}

@test "doctor: user.name in ~/.gitconfig fails without printing it" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    printf '[user]\n\tname = %s\n' "$SECRET_NAME" >"$HOME/.gitconfig"
    doctor
    expect_status 1
    expect_output_matches 'gitconfig'
    expect_output_lacks "$SECRET_NAME"
    expect_output_lacks "Sentinel"
}

@test "doctor: ~/.gitconfig without identity keys is fine" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    printf '[core]\n\teditor = vi\n[safe]\n\tdirectory = /src\n' >"$HOME/.gitconfig"
    doctor
    expect_status 0
    expect_equal "FAIL lines" 0 "$(lines_with FAIL)"
}

@test "doctor: no ~/.gitconfig is fine" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    expect_equal "FAIL lines" 0 "$(lines_with FAIL)"
}

# ---------------------------------------------------------------- hooks

# clone <name> [hooks-dir] [hooksPath]: a git repo under $REPOS.
clone() {
    git init -q "$REPOS/$1"
    [ -z "${2:-}" ] || mkdir -p "$REPOS/$1/.githooks"
    [ -z "${3:-}" ] || git -C "$REPOS/$1" config core.hooksPath "$3"
}

@test "doctor: a clone with .githooks but no hooksPath is a WARN naming it" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    clone needs-hooks yes
    clone has-hooks yes .githooks
    clone no-hooks-dir
    doctor
    expect_status 0
    printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -qF needs-hooks || {
        printf 'no WARN line naming needs-hooks; output:\n%s\n' "$output" >&2
        return 1
    }
    expect_output_lacks has-hooks
    expect_output_lacks no-hooks-dir
    expect_summary
}

@test "doctor: a hooksPath other than .githooks is a WARN" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    clone wrong-path yes .git/hooks
    doctor
    expect_status 0
    printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -qF wrong-path || {
        printf 'no WARN line naming wrong-path; output:\n%s\n' "$output" >&2
        return 1
    }
}

@test "doctor: only git clones directly under repos_dir are checked" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    mkdir -p "$REPOS/plain-dir/.githooks"
    mkdir -p "$REPOS/group"
    git init -q "$REPOS/group/nested-clone"
    mkdir -p "$REPOS/group/nested-clone/.githooks"
    doctor
    expect_status 0
    expect_equal "WARN lines" 0 "$(lines_with WARN)"
}

@test "doctor: a missing repos_dir is not a failure" {
    STUB_REPOS_DIR="$TEST_TMP/no-such-dir"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    expect_equal "FAIL lines" 0 "$(lines_with FAIL)"
}

# ------------------------------------------------------------ via ws

@test "doctor: ws doctor runs it with the same result" {
    ws_src="$REPO_ROOT/home/dot_local/bin/executable_ws"
    [ -f "$ws_src" ] || { echo "missing home/dot_local/bin/executable_ws" >&2; return 1; }
    cp "$ws_src" "$HOME/.local/bin/ws"
    chmod +x "$HOME/.local/bin/ws"
    tsv "b-fail${TAB}file${TAB}~/missing"
    run "$HOME/.local/bin/ws" doctor
    expect_status 1
    expect_check FAIL b-fail
}

# ------------------------------------------- review round 1 (19, 20, 23-27)

@test "doctor: user.email from an [include]d file in ~/.gitconfig fails without printing it (19)" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    printf '[user]\n\temail = %s\n\tname = %s\n' "$SECRET_EMAIL" "$SECRET_NAME" >"$HOME/.gitconfig-extra"
    printf '[include]\n\tpath = %s\n' "$HOME/.gitconfig-extra" >"$HOME/.gitconfig"
    doctor
    expect_status 1
    expect_output_matches 'gitconfig'
    expect_output_lacks "sentinel-9f3a"
    expect_output_lacks "Sentinel"
    expect_summary
}

# identity_tsv: identity file checks as the template renders them.
identity_tsv() {
    tsv "git-identities-includes${TAB}file${TAB}~/.config/git/identities/.includes" \
        "git-identities-conflict${TAB}file${TAB}~/.config/git/identities/.conflict" \
        "git-identity-1${TAB}file${TAB}~/.config/git/identities/$OWNER1" \
        "git-identity-2${TAB}file${TAB}~/.config/git/identities/$OWNER2"
}

# expect_no_owner: no GitHub owner name anywhere in the output, any case.
expect_no_owner() {
    if printf '%s\n' "$output" | grep -qiE 'octo-(one|two)'; then
        printf 'doctor output names an owner:\n%s\n' "$output" >&2
        return 1
    fi
}

@test "doctor: a missing identity file fails without naming the owner (20)" {
    identity_tsv
    mkdir -p "$HOME/.config/git/identities"
    touch "$HOME/.config/git/identities/.includes" "$HOME/.config/git/identities/.conflict" \
        "$HOME/.config/git/identities/$OWNER2"
    doctor
    expect_status 1
    expect_check FAIL git-identity-1
    expect_check ok git-identity-2
    expect_no_owner
}

@test "doctor: drift reports the number of entries, not their paths (20)" {
    STUB_STATUS=" M .config/git/identities/$OWNER1
 M .config/git/identities/$OWNER2"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    drift=$(printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -E '(^|[^0-9])2([^0-9]|$)' || true)
    [ -n "$drift" ] || { printf 'no WARN line with the count 2; output:\n%s\n' "$output" >&2; return 1; }
    expect_no_owner
    expect_output_lacks '.config/git/identities'
}

@test "doctor: the hooks hint names the clone, not a shell command built from it (23)" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    name="it's;odd"
    clone "$name" yes
    doctor
    expect_status 0
    line=$(printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -F "$name" || true)
    [ -n "$line" ] || { printf 'no WARN naming the clone; output:\n%s\n' "$output" >&2; return 1; }
    printf '%s\n' "$line" | grep -qF 'core.hooksPath' || {
        echo "the WARN does not name the setting: $line" >&2
        return 1
    }
    expect_output_lacks 'git -C'
}

@test "doctor: repos_dir ~/dev is expanded (24)" {
    STUB_REPOS_DIR='~/dev'
    REPOS="$HOME/dev"
    mkdir -p "$REPOS"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    clone tilde-clone yes
    doctor
    expect_status 0
    printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -qF tilde-clone || {
        printf 'no WARN naming tilde-clone; output:\n%s\n' "$output" >&2
        return 1
    }
}

@test "doctor: a missing repos_dir is a WARN, not ok (24)" {
    STUB_REPOS_DIR="$TEST_TMP/no-such-dir"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -qF 'no-such-dir' || {
        printf 'no WARN for the missing repos_dir; output:\n%s\n' "$output" >&2
        return 1
    }
    if printf '%s\n' "$output" | grep -E '^ok[[:space:]]' | grep -qF 'no-such-dir'; then
        printf 'missing repos_dir reported as ok; output:\n%s\n' "$output" >&2
        return 1
    fi
}

@test "doctor: source matches through a trailing slash in PATH (25)" {
    PATH="$TEST_TMP/stubs:$HOME/.local/bin/:$TEST_TMP/tools:$PATH"
    tsv "cmd-slash${TAB}command${TAB}tool-b${TAB}~/.local/bin/tool-b${TAB}"
    doctor
    expect_status 0
    expect_check ok cmd-slash
}

@test "doctor: source matches with a symlinked HOME (25)" {
    real_home=$HOME
    ln -s "$real_home" "$TEST_TMP/home-link"
    # PATH names the real dir, HOME the link.
    PATH="$TEST_TMP/stubs:$real_home/.local/bin:$TEST_TMP/tools:$PATH"
    HOME="$TEST_TMP/home-link"
    tsv "cmd-link${TAB}command${TAB}tool-b${TAB}~/.local/bin/tool-b${TAB}"
    doctor
    expect_status 0
    expect_check ok cmd-link
}

@test "doctor: without chezmoi, drift and hooks are WARNs saying so (26)" {
    # A PATH with git and the basics but no chezmoi.
    mkdir -p "$TEST_TMP/nochez"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            [ "$n" != chezmoi ] || continue
            [ -e "$TEST_TMP/nochez/$n" ] || [ -L "$TEST_TMP/nochez/$n" ] || ln -s "$f" "$TEST_TMP/nochez/$n"
        done
    done
    PATH="$TEST_TMP/tools:$TEST_TMP/nochez"
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    doctor
    expect_status 0
    warns=$(printf '%s\n' "$output" | grep -E '^WARN[[:space:]]' | grep -cE 'chezmoi (is )?not on PATH' || true)
    [ "$warns" -ge 2 ] || {
        printf 'want 2 WARNs (drift, hooks) saying chezmoi is not on PATH, got %s; output:\n%s\n' "$warns" "$output" >&2
        return 1
    }
    expect_equal "FAIL lines" 0 "$(lines_with FAIL)"
}

@test "doctor: hooksPath is read from a clone git distrusts for ownership (27)" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    clone foreign-owner yes .githooks
    # git's own switch for "owned by someone else" (dubious ownership).
    GIT_TEST_ASSUME_DIFFERENT_OWNER=1
    export GIT_TEST_ASSUME_DIFFERENT_OWNER
    doctor
    unset GIT_TEST_ASSUME_DIFFERENT_OWNER
    expect_status 0
    expect_output_lacks foreign-owner
}

@test "doctor: hooksPath set through a relative [include] in the clone's config counts" {
    touch "$HOME/present"
    tsv "a-ok${TAB}file${TAB}~/present"
    clone included-hooks yes
    printf '[core]\n\thooksPath = .githooks\n' >"$REPOS/included-hooks/.git/hooks.inc"
    git config -f "$REPOS/included-hooks/.git/config" include.path hooks.inc
    expect_equal "control: git sees it" .githooks "$(git -C "$REPOS/included-hooks" config --get core.hooksPath)"
    doctor
    expect_status 0
    expect_output_lacks included-hooks
}
