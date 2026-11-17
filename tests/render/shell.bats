#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2088,SC2030,SC2031,SC2034 # bash -c strings expand in the child; ~/ is literal text; per-test variables; CHEZMOI is read by cz
# Render and behaviour tests for the shell base (slice 4, criteria 1-8 and
# 12-14), against a home rendered with chezmoi apply into a temp
# destination. The real ~/.bashrc is never read or written.
#
# Interfaces (the implementation follows this):
#
#   home/dot_bashrc (or dot_bashrc.tmpl if a template is needed)
#                       -> ~/.bashrc
#   home/dot_config/shell/{10-path,20-history,30-defaults,40-aliases,
#                          50-completion,60-editing,90-prompt}.sh
#                       -> ~/.config/shell/<same names>
#   home/.chezmoiscripts/run_once_after_migrate-20261113-old-rc-blocks.sh
#                       -> chezmoi target .chezmoiscripts/
#                          migrate-20261113-old-rc-blocks.sh
#
#   On every OS but Linux (decision 31), .chezmoiignore excludes .bashrc,
#   everything under .config/shell and the migration script: none is
#   rendered and the script is not in `chezmoi managed --include=scripts`.
#   On Linux all are. The ignore template is also rendered for darwin,
#   windows and freebsd via --override-data, so every host checks both
#   sides.
#
#   ~/.bashrc returns at once in a non-interactive shell, then sources
#   every readable ~/.config/shell/*.sh, then every readable
#   ~/.config/shell/local/*.sh, each dir in glob order. The location is
#   fixed: XDG_CONFIG_HOME is ignored (decision 28). The loop runs with
#   nullglob on and failglob off and restores both afterwards (decision
#   27). Files not ending in .sh are ignored. It holds no other logic: no
#   PATH, alias, PS1, HIST*, `set -o` or starship of its own (shopt only
#   for the glob options of the loop).
#
#   Drop-ins: each starts with a `# shellcheck shell=bash` line and passes
#   bash -n and shellcheck. Behaviour pinned here beyond the brief:
#     - 10-path.sh: ~/.local/bin is the first PATH entry when it was added.
#     - 20-history.sh: HISTCONTROL holds ignoreboth, histappend is on,
#       HISTSIZE >= 1000 and HISTFILESIZE >= 2000 (Ubuntu's skel values).
#     - 30-defaults.sh: checkwinsize is on.
#     - 40-aliases.sh: ll, la and l are aliases; with dircolors present,
#       ls and grep use --color=auto; ~/.bash_aliases is sourced when
#       present.
#     - 50-completion.sh: with /usr/share/bash-completion/bash_completion
#       present, its functions are loaded.
#     - 60-editing.sh: a shell started with -o vi ends up in emacs mode.
#     - 90-prompt.sh: with `starship` on PATH, the output of
#       `starship init bash` is evaluated; otherwise PS1 holds \u, \h and
#       \w (or \W).
#
# How bash is run: `env -i` with HOME=<render destination>, PATH=<stub
# dir>:/usr/bin:/bin and TERM=dumb, stdin from /dev/null and, where setsid
# exists, no controlling tty. bash's own job-control notices for an
# interactive shell without a tty ("cannot set terminal process group",
# "no job control") are filtered from stderr; anything else counts. The
# rendered home gets ~/.sudo_as_admin_successful so Ubuntu's
# /etc/bash.bashrc prints no sudo hint.
#
# Behaviour tests need bash -i and the Linux-only files, so they skip on
# every OS but Linux, where the exclusion tests run instead.

bats_require_minimum_version 1.5.0

load ../helpers/common

DROPINS="10-path 20-history 30-defaults 40-aliases 50-completion 60-editing 90-prompt"
MIGRATE_TARGET=.chezmoiscripts/migrate-20261113-old-rc-blocks.sh
TAB=$(printf '\t')

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    STUBS="$TEST_TMP/stubs"
    mkdir -p "$DEST" "$STUBS"
    SHELL_PATH="$STUBS:/usr/bin:/bin"
}

# on_linux: the host chezmoi renders for is Linux.
on_linux() {
    [ "$(uname -s)" = Linux ]
}

skip_unless_linux() {
    on_linux || skip "bash behaviour and Linux-only files (excluded on every OS but Linux)"
}

# render <profile>: applies the source state to $DEST with <profile>.
render() {
    # shellcheck disable=SC2034 # read by cz
    PROFILE=$1
    run cz apply --force
    expect_status 0
}

# render_home: personal-desktop rendered, ready for bash.
render_home() {
    render "$PROFILES_DIR/personal-desktop.toml"
    [ -f "$DEST/.bashrc" ] || { echo "no ~/.bashrc rendered" >&2; return 1; }
    touch "$DEST/.sudo_as_admin_successful"
}

# shell_bash <bash args...>: bash on the rendered home (see header);
# extra environment as WS_ENV="NAME=value ...".
shell_bash() {
    # shellcheck disable=SC2086 # WS_ENV is a list of assignments
    set -- env -i HOME="$DEST" PATH="$SHELL_PATH" TERM=dumb ${WS_ENV:-} bash "$@"
    if command -v setsid >/dev/null 2>&1; then
        setsid -w "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

# run_bash <bash args...>: shell_bash under bats' run, stderr separate and
# stripped of bash's job-control notices into $err.
run_bash() {
    run --separate-stderr shell_bash "$@"
    err=$(printf '%s\n' "$stderr" |
        grep -vE '^bash: (cannot set terminal process group|no job control in this shell)' |
        grep -v '^$' || true)
}

# expect_no_err
expect_no_err() {
    expect_equal "stderr of bash" "" "$err"
}

# path_count <PATH value> <dir>: how often <dir> is an entry.
path_count() {
    printf '%s\n' "$1" | tr ':' '\n' | grep -cxF -- "$2" || true
}

# value_of <name>: from $output lines NAME=value.
value_of() {
    printf '%s\n' "$output" | sed -n "s/^$1=//p" | tail -n 1
}

# ------------------------------------------- render (criteria 1, 13)

t_shell_files() {
    render "$1"
    if ! on_linux; then
        [ ! -e "$DEST/.bashrc" ] || { echo "~/.bashrc rendered on $(uname -s)" >&2; return 1; }
        [ ! -e "$DEST/.config/shell" ] || { echo "~/.config/shell rendered on $(uname -s)" >&2; return 1; }
        run cz managed --include=scripts
        expect_status 0
        expect_output_lacks "migrate-20261113-old-rc-blocks"
        return 0
    fi
    require_tool shellcheck
    sc=$(tool_path shellcheck)
    [ -f "$DEST/.bashrc" ] || { echo "no ~/.bashrc rendered" >&2; return 1; }
    run bash -n "$DEST/.bashrc"
    expect_status 0
    run "$sc" --shell=bash "$DEST/.bashrc"
    expect_status 0
    for d in $DROPINS; do
        f="$DEST/.config/shell/$d.sh"
        [ -f "$f" ] || { echo "no ~/.config/shell/$d.sh rendered" >&2; return 1; }
        grep -qxF '# shellcheck shell=bash' "$f" || {
            echo "$d.sh lacks the line '# shellcheck shell=bash'" >&2
            return 1
        }
        run bash -n "$f"
        expect_status 0
        run "$sc" "$f"
        expect_status 0
    done
    run cz managed --include=scripts
    expect_status 0
    printf '%s\n' "$output" | grep -qxF "$MIGRATE_TARGET" || {
        printf 'migration script not managed; scripts:\n%s\n' "$output" >&2
        return 1
    }
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "shell $p: bashrc and drop-ins render, pass bash -n and shellcheck (excluded on every OS but Linux)" -- t_shell_files "$profile"
done

# ignore_for <os>: home/.chezmoiignore rendered as if chezmoi ran on <os>.
ignore_for() {
    "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$DEST" \
        --config "$PROFILES_DIR/personal-desktop.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --override-data "{\"chezmoi\":{\"os\":\"$1\"}}" \
        --file "$REPO_ROOT/home/.chezmoiignore"
}

@test "shell: .chezmoiignore excludes the shell base on every OS but Linux (decision 31)" {
    for os in darwin windows freebsd; do
        run ignore_for "$os"
        expect_status 0
        for want in .bashrc .config/shell/** "$MIGRATE_TARGET"; do
            printf '%s\n' "$output" | grep -qxF -- "$want" || {
                printf '%s: .chezmoiignore lacks %s; rendered:\n%s\n' "$os" "$want" "$output" >&2
                return 1
            }
        done
    done
    run ignore_for linux
    expect_status 0
    bad=$(printf '%s\n' "$output" | grep -E '^(\.bashrc|\.config/shell.*|.*migrate-20261113.*)$' || true)
    expect_equal "shell base ignored on linux" "" "$bad"
}

@test "shell: the bashrc source is home/dot_bashrc" {
    [ -f "$REPO_ROOT/home/dot_bashrc" ] || [ -f "$REPO_ROOT/home/dot_bashrc.tmpl" ] || {
        echo "missing home/dot_bashrc" >&2
        return 1
    }
}

@test "shell: the bashrc holds only the drop-in loop (criterion 4)" {
    f="$REPO_ROOT/home/dot_bashrc"
    [ -f "$f" ] || f="$f.tmpl"
    [ -f "$f" ] || { echo "missing home/dot_bashrc" >&2; return 1; }
    bad=$(grep -v '^[[:space:]]*#' "$f" |
        grep -nE '(^|[^A-Za-z_])(PATH=|alias |PS1|HIST|set -o|starship|lesspipe|dircolors|bash_completion)|shopt.*(histappend|checkwinsize|globstar)' || true)
    expect_equal "logic beyond the loop in the bashrc" "" "$bad"
    grep -q 'shell/local' "$f" || { echo "the bashrc does not name shell/local" >&2; return 1; }
}

# ------------------------------------------------ PATH (criteria 5, 14)

@test "bash: ~/.local/bin is first in PATH, once" {
    skip_unless_linux
    render_home
    run_bash -ic 'printf "PATH=%s\n" "$PATH"'
    expect_status 0
    p=$(value_of PATH)
    expect_equal "~/.local/bin entries" 1 "$(path_count "$p" "$DEST/.local/bin")"
    expect_equal "first PATH entry" "$DEST/.local/bin" "${p%%:*}"
}

@test "bash: re-sourcing the bashrc keeps ~/.local/bin once" {
    skip_unless_linux
    render_home
    run_bash -ic '. ~/.bashrc; . "$HOME/.bashrc"; printf "PATH=%s\n" "$PATH"'
    expect_status 0
    expect_equal "~/.local/bin entries" 1 "$(path_count "$(value_of PATH)" "$DEST/.local/bin")"
}

@test "bash: a nested interactive bash keeps ~/.local/bin once" {
    skip_unless_linux
    render_home
    run_bash -ic 'bash -ic '\''printf "PATH=%s\n" "$PATH"'\'
    expect_status 0
    expect_equal "~/.local/bin entries" 1 "$(path_count "$(value_of PATH)" "$DEST/.local/bin")"
}

@test "bash: ~/.local/bin already later in PATH is not added again" {
    skip_unless_linux
    render_home
    SHELL_PATH="$STUBS:/usr/bin:$DEST/.local/bin:/bin"
    run_bash -ic 'printf "PATH=%s\n" "$PATH"'
    expect_status 0
    expect_equal "~/.local/bin entries" 1 "$(path_count "$(value_of PATH)" "$DEST/.local/bin")"
}

# ------------------------------------------ emacs mode (criteria 7, 14)

@test "bash: emacs mode is on, even in a shell started with -o vi" {
    skip_unless_linux
    render_home
    run_bash -i -o vi -c 'shopt -o emacs vi; true'
    expect_status 0
    expect_output_matches '^emacs[[:space:]]+on'
    expect_output_matches '^vi[[:space:]]+off'
}

# ------------------------------------- loop and local (criteria 3, 14)

@test "bash: managed drop-ins load before local ones, each dir in glob order" {
    skip_unless_linux
    render_home
    printf 'WS_ORDER="${WS_ORDER:-}m "\n' >"$DEST/.config/shell/99-probe.sh"
    mkdir -p "$DEST/.config/shell/local"
    printf 'WS_ORDER="${WS_ORDER:-}a "\n' >"$DEST/.config/shell/local/00-a.sh"
    printf 'WS_ORDER="${WS_ORDER:-}b "\n' >"$DEST/.config/shell/local/10-b.sh"
    printf 'WS_ORDER="${WS_ORDER:-}x "\n' >"$DEST/.config/shell/local/20-not-sourced.txt"
    run_bash -ic 'printf "ORDER=%s\n" "${WS_ORDER:-}"'
    expect_status 0
    expect_no_err
    expect_equal "load order" "m a b " "$(value_of ORDER)"
}

@test "bash: a local drop-in can override a managed alias" {
    skip_unless_linux
    render_home
    mkdir -p "$DEST/.config/shell/local"
    printf "alias ll='echo local-ll'\n" >"$DEST/.config/shell/local/00-override.sh"
    run_bash -ic 'alias ll'
    expect_status 0
    expect_output_matches 'local-ll'
}

@test "bash: an unreadable local drop-in is skipped without error" {
    skip_unless_linux
    [ "$(id -u)" -ne 0 ] || skip "root reads files without read permission"
    render_home
    mkdir -p "$DEST/.config/shell/local"
    printf 'WS_UNREADABLE=sourced\n' >"$DEST/.config/shell/local/50-secret.sh"
    chmod 000 "$DEST/.config/shell/local/50-secret.sh"
    run_bash -ic 'printf "U=%s\n" "${WS_UNREADABLE:-}"'
    expect_status 0
    expect_no_err
    expect_equal "unreadable drop-in" "" "$(value_of U)"
}

@test "bash: no local dir and no starship: no stderr and no stdout" {
    skip_unless_linux
    render_home
    PATH="$SHELL_PATH" command -v starship >/dev/null 2>&1 && skip "starship is in /usr/bin or /bin"
    [ ! -e "$DEST/.config/shell/local" ] || rm -rf "$DEST/.config/shell/local"
    run_bash -ic 'true'
    expect_status 0
    expect_no_err
    expect_equal "stdout" "" "$output"
}

@test "bash: an empty local dir: no stderr and no stdout" {
    skip_unless_linux
    render_home
    mkdir -p "$DEST/.config/shell/local"
    run_bash -ic 'true'
    expect_status 0
    expect_no_err
    expect_equal "stdout" "" "$output"
}

@test "bash: drop-ins load from ~/.config/shell even with XDG_CONFIG_HOME elsewhere (decision 28)" {
    skip_unless_linux
    render_home
    xdg="$TEST_TMP/xdg-elsewhere"
    mkdir -p "$xdg/shell/local" "$DEST/.config/shell/local"
    printf 'WS_WRONG=sourced\n' >"$xdg/shell/99-wrong.sh"
    printf 'WS_WRONG=sourced\n' >"$xdg/shell/local/50-wrong.sh"
    printf 'WS_LOCAL=sourced\n' >"$DEST/.config/shell/local/50-probe.sh"
    WS_ENV="XDG_CONFIG_HOME=$xdg" run_bash -ic 'alias ll >/dev/null && printf "LL=yes\n"; printf "LOCAL=%s\nWRONG=%s\n" "${WS_LOCAL:-}" "${WS_WRONG:-}"'
    expect_status 0
    expect_no_err
    expect_equal "managed drop-ins from ~/.config/shell" yes "$(value_of LL)"
    expect_equal "local drop-in from ~/.config/shell/local" sourced "$(value_of LOCAL)"
    expect_equal "drop-in from XDG_CONFIG_HOME/shell" "" "$(value_of WRONG)"
}

# ------------------------------------------------ failglob (decision 27)

@test "bash: with failglob on and no local dir, re-sourcing loads the drop-ins without error" {
    skip_unless_linux
    render_home
    rm -rf "$DEST/.config/shell/local"
    printf 'WS_PROBE_COUNT=$(( ${WS_PROBE_COUNT:-0} + 1 ))\n' >"$DEST/.config/shell/99-probe.sh"
    run_bash -ic 'shopt -s failglob; shopt -u nullglob; . ~/.bashrc; printf "N=%s\n" "${WS_PROBE_COUNT:-0}"; shopt -q failglob && printf "FG=on\n"; shopt -q nullglob && printf "NG=on\n"; true'
    expect_status 0
    expect_no_err
    expect_equal "managed drop-in loads (startup + re-source)" 2 "$(value_of N)"
    expect_equal "failglob after re-sourcing" on "$(value_of FG)"
    expect_equal "nullglob after re-sourcing" "" "$(value_of NG)"
}

@test "bash: the loop restores nullglob and failglob as they were" {
    skip_unless_linux
    render_home
    run_bash -ic 'shopt -u failglob; shopt -s nullglob; . ~/.bashrc; shopt -q failglob && printf "FG=on\n"; shopt -q nullglob && printf "NG=on\n"; true'
    expect_status 0
    expect_no_err
    expect_equal "failglob after re-sourcing" "" "$(value_of FG)"
    expect_equal "nullglob after re-sourcing" on "$(value_of NG)"
    # And the default state of a fresh shell: both off.
    run_bash -ic 'shopt -q failglob && printf "FG=on\n"; shopt -q nullglob && printf "NG=on\n"; true'
    expect_equal "failglob in a new shell" "" "$(value_of FG)"
    expect_equal "nullglob in a new shell" "" "$(value_of NG)"
}

# --------------------------------------------- non-interactive (2, 14)

@test "bash: a non-interactive shell sourcing the bashrc loads no drop-in" {
    skip_unless_linux
    render_home
    mkdir -p "$DEST/.config/shell/local"
    printf 'touch "$HOME/sourced-marker"\n' >"$DEST/.config/shell/local/00-marker.sh"
    run_bash -c '. ~/.bashrc; printf "PATH=%s\n" "$PATH"; alias ll >/dev/null 2>&1 && printf "LL=yes\n"; true'
    expect_status 0
    expect_equal "stderr" "" "$stderr"
    [ ! -e "$DEST/sourced-marker" ] || { echo "a local drop-in was sourced" >&2; return 1; }
    expect_equal "~/.local/bin entries" 0 "$(path_count "$(value_of PATH)" "$DEST/.local/bin")"
    expect_equal "alias ll" "" "$(value_of LL)"
}

# -------------------------------------------------- prompt (8, 14)

@test "bash: a starship on PATH has its init output evaluated" {
    skip_unless_linux
    render_home
    cat >"$STUBS/starship" <<'EOF'
#!/bin/sh
# Stub: `starship init bash` prints code that marks it was evaluated.
if [ "${1:-}" = init ] && [ "${2:-}" = bash ]; then
    echo 'WS_STARSHIP_STUB=evaluated'
fi
EOF
    chmod +x "$STUBS/starship"
    run_bash -ic 'printf "S=%s\n" "${WS_STARSHIP_STUB:-}"'
    expect_status 0
    expect_no_err
    expect_equal "starship init evaluated" evaluated "$(value_of S)"
}

@test "bash: without starship the prompt is user@host:dir" {
    skip_unless_linux
    render_home
    PATH="$SHELL_PATH" command -v starship >/dev/null 2>&1 && skip "starship is in /usr/bin or /bin"
    run_bash -ic 'printf "PS1=%s\n" "$PS1"'
    expect_status 0
    ps1=$(value_of PS1)
    case $ps1 in
        *'\u'*'\h'*) ;;
        *) echo "PS1 lacks \\u...\\h: $ps1" >&2; return 1 ;;
    esac
    case $ps1 in
        *'\w'* | *'\W'*) ;;
        *) echo "PS1 lacks \\w: $ps1" >&2; return 1 ;;
    esac
}

# ------------------------------------------ skel defaults (criterion 6)

@test "bash: history settings from Ubuntu's skel" {
    skip_unless_linux
    render_home
    run_bash -ic 'printf "HC=%s\nHS=%s\nHFS=%s\n" "$HISTCONTROL" "$HISTSIZE" "$HISTFILESIZE"; shopt -q histappend && printf "HA=on\n"; shopt -q checkwinsize && printf "CWS=on\n"; true'
    expect_status 0
    case $(value_of HC) in
        *ignoreboth*) ;;
        *) echo "HISTCONTROL lacks ignoreboth: $(value_of HC)" >&2; return 1 ;;
    esac
    expect_equal histappend on "$(value_of HA)"
    expect_equal checkwinsize on "$(value_of CWS)"
    [ "$(value_of HS)" -ge 1000 ] 2>/dev/null || { echo "HISTSIZE is '$(value_of HS)', want >= 1000" >&2; return 1; }
    [ "$(value_of HFS)" -ge 2000 ] 2>/dev/null || { echo "HISTFILESIZE is '$(value_of HFS)', want >= 2000" >&2; return 1; }
}

@test "bash: ll, la and l aliases, colour aliases with dircolors" {
    skip_unless_linux
    render_home
    run_bash -ic 'for a in ll la l; do alias "$a" >/dev/null && printf "A_%s=yes\n" "$a"; done; alias grep 2>/dev/null; alias ls 2>/dev/null; true'
    expect_status 0
    for a in ll la l; do
        expect_equal "alias $a" yes "$(value_of "A_$a")"
    done
    if [ -x /usr/bin/dircolors ]; then
        expect_output_matches "^alias grep='grep --color=auto'"
        expect_output_matches "^alias ls='ls --color=auto'"
    fi
}

@test "bash: ~/.bash_aliases is sourced when present" {
    skip_unless_linux
    render_home
    printf "alias ws-probe='echo probe'\n" >"$DEST/.bash_aliases"
    run_bash -ic 'alias ws-probe'
    expect_status 0
    expect_output_matches 'echo probe'
}

@test "bash: bash-completion is loaded when installed" {
    skip_unless_linux
    [ -r /usr/share/bash-completion/bash_completion ] || skip "bash-completion not installed"
    render_home
    run_bash -ic 'declare -F _init_completion >/dev/null || declare -F _comp_initialize >/dev/null && printf "BC=yes\n"; true'
    expect_status 0
    expect_equal "bash-completion functions" yes "$(value_of BC)"
}

# --------------------------------------- expect.yaml (criterion 12)

TSV_REL=.config/ws/expect.tsv

# smoke_of <id>: the smoke field of <id> in the rendered expect.tsv.
smoke_of() {
    awk -F '\t' -v id="$1" '$1 == id && $2 == "command" { print $5 }' "$DEST/$TSV_REL"
}

# run_smoke <id>: the smoke command as ws doctor runs it (sh -c, stdin
# /dev/null), on the rendered home.
run_smoke() {
    s=$(smoke_of "$1")
    [ -n "$s" ] || { echo "no smoke for $1 in expect.tsv" >&2; return 1; }
    run shell_sh_c "$s"
}

shell_sh_c() {
    set -- env -i HOME="$DEST" PATH="$SHELL_PATH" TERM=dumb sh -c "$1"
    if command -v setsid >/dev/null 2>&1; then
        setsid -w "$@" </dev/null
    else
        "$@" </dev/null
    fi
}

@test "expect.tsv: bashrc, shell and old-block checks on Linux, none elsewhere" {
    render "$PROFILES_DIR/personal-desktop.toml"
    tsv="$DEST/$TSV_REL"
    [ -f "$tsv" ] || { echo "no expect.tsv rendered" >&2; return 1; }
    if ! on_linux; then
        bad=$(cut -f 1 "$tsv" | grep -E '^(bashrc|shell-path|shell-emacs|old-block-.*)$' || true)
        expect_equal "Linux-only ids on $(uname -s)" "" "$bad"
        return 0
    fi
    grep -qxF "bashrc${TAB}file${TAB}~/.bashrc" "$tsv" || { echo "no bashrc file check" >&2; return 1; }
    for id in shell-path shell-emacs; do
        awk -F '\t' -v id="$id" '$1 == id && $2 == "command" && $3 == "bash" && $5 != "" { f = 1 } END { exit !f }' "$tsv" || {
            echo "no command check $id with a smoke" >&2
            return 1
        }
    done
    for f in bashrc zshrc; do
        for pair in 'ai-workspace|# >>> ai-workspace >>>' \
            'yazi|# >>> yazi-setup: y function >>>' \
            'lazygit|# >>> lazygit-setup: lg >>>'; do
            line="old-block-${pair%%|*}-$f${TAB}line${TAB}~/.$f${TAB}0${TAB}${pair#*|}"
            grep -qxF "$line" "$tsv" || {
                printf 'expect.tsv lacks [%s]; file:\n%s\n' "$line" "$(cat "$tsv")" >&2
                return 1
            }
        done
    done
}

@test "expect.tsv: shell-path and shell-emacs smokes pass on the rendered home" {
    skip_unless_linux
    render_home
    run_smoke shell-path
    expect_status 0
    run_smoke shell-emacs
    expect_status 0
}

@test "expect.tsv: the smokes fail on a bashrc without the shell base (control)" {
    skip_unless_linux
    render "$PROFILES_DIR/personal-desktop.toml"
    touch "$DEST/.sudo_as_admin_successful"
    rm -f "$DEST/.bashrc"
    : >"$DEST/.bashrc"
    run_smoke shell-path
    expect_failure
    run_smoke shell-emacs
    expect_failure
    # A bashrc that prepends blindly passes for one shell but not nested.
    printf 'PATH="$HOME/.local/bin:$PATH"\n' >"$DEST/.bashrc"
    run_smoke shell-path
    expect_failure
}

@test "expect.tsv: shell-path ignores the caller's PATH, even with ~/.local/bin twice (decision 26)" {
    skip_unless_linux
    render_home
    # As after a login shell: Ubuntu's ~/.profile prepends ~/.local/bin
    # again after sourcing the bashrc.
    SHELL_PATH="$DEST/.local/bin:$DEST/.local/bin:$STUBS:/usr/bin:/bin"
    run_smoke shell-path
    expect_status 0
    # Control: the same caller PATH with an empty bashrc still fails.
    : >"$DEST/.bashrc"
    run_smoke shell-path
    expect_failure
}

# ------------------------------- migration through chezmoi (criterion 9)

@test "migration: chezmoi apply removes the old blocks from the destination's .zshrc" {
    skip_unless_linux
    cp "$REPO_ROOT/tests/system/fixtures/old-rc" "$DEST/.zshrc"
    cp "$REPO_ROOT/tests/system/fixtures/old-rc" "$DEST/.bashrc"
    render "$PROFILES_DIR/personal-desktop.toml"
    cmp -s "$REPO_ROOT/tests/system/fixtures/old-rc.migrated" "$DEST/.zshrc" || {
        printf '.zshrc after apply:\n%s\n' "$(cat "$DEST/.zshrc")" >&2
        return 1
    }
    if grep -qE '^# >>> ' "$DEST/.bashrc"; then
        echo "~/.bashrc still holds an old block" >&2
        return 1
    fi
    [ ! -e "$HOME/.zshrc" ] || { echo "the script wrote to \$HOME instead of the destination" >&2; return 1; }
}
