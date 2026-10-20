#!/usr/bin/env bats
# shellcheck disable=SC2088 # literal ~/ paths are the expected data
# Render tests for ~/.config/ws/expect.tsv (slice 3, criteria 6 and 8) and
# the rendered ws files (criterion 9).
#
# expect.tsv format (the contract between the template under
# home/dot_config/ws/ and ws-doctor.sh): one check per line, no blank
# lines, fields separated by one tab, a fixed number of fields per kind:
#
#   <id> command <name> <source> <smoke>    5 fields; source and smoke may
#                                           be empty (empty smoke = trailing tab)
#   <id> file    <path>                     3 fields
#   <id> absent  <path>                     3 fields
#   <id> line    <file> <count> <text>      5 fields
#
# Paths are written as in expect.yaml (a leading ~/ stays ~/; ws doctor
# expands it against $HOME). Entries whose os/roles/forms filter excludes
# the machine are left out. The template also adds one `file` check per
# GitHub identity file: ~/.config/git/identities/<owner> for each owner in
# github_identities, plus .includes and .conflict (any unique ids).
#
# Filtering is tested with a fixture expect.yaml in a copy of the source
# state (home/, scripts/, .chezmoiroot), since the real file has no
# filtered entries yet.

load ../helpers/common

TAB=$(printf '\t')

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    mkdir -p "$DEST"
    TSV="$DEST/.config/ws/expect.tsv"
}

# render <profile> [<source root>]: applies the source state to $DEST and
# requires expect.tsv unless NO_TSV is set.
render() {
    root=${2:-$REPO_ROOT}
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$root/home" --destination "$DEST" --config "$1" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        apply --force
    expect_status 0
    [ -n "${NO_TSV:-}" ] || [ -f "$TSV" ] || { echo "no ~/.config/ws/expect.tsv rendered" >&2; return 1; }
}

# expect_line <exact line>: the TSV holds this line exactly once.
expect_line() {
    n=$(grep -cxF -- "$1" "$TSV" || true)
    [ "$n" -eq 1 ] && return 0
    printf 'expect.tsv holds %s copies of [%s]; file:\n%s\n' "$n" "$1" "$(cat "$TSV")" >&2
    return 1
}

# expect_no_id <id>
expect_no_id() {
    ! cut -f 1 "$TSV" | grep -qxF -- "$1" && return 0
    printf 'expect.tsv must not hold id %s; file:\n%s\n' "$1" "$(cat "$TSV")" >&2
    return 1
}

# has_file_check <path>: some `file` line checks <path>.
has_file_check() {
    awk -F '\t' -v p="$1" '$2 == "file" && $3 == p && NF == 3 { f = 1 } END { exit !f }' "$TSV" && return 0
    printf 'no file check for %s; file:\n%s\n' "$1" "$(cat "$TSV")" >&2
    return 1
}

# well_formed: every line has the fields of its kind and ids are unique.
well_formed() {
    bad=$(awk -F '\t' '
        $0 == "" { print NR ": blank line"; next }
        $1 !~ /^[a-z0-9-]+$/ { print NR ": bad id" }
        ($2 == "command" || $2 == "line") && NF != 5 { print NR ": " $2 " needs 5 fields, has " NF; next }
        ($2 == "file" || $2 == "absent") && NF != 3 { print NR ": " $2 " needs 3 fields, has " NF; next }
        $2 !~ /^(command|file|absent|line)$/ { print NR ": unknown kind " $2 }
        seen[$1]++ { print NR ": duplicate id " $1 }
    ' "$TSV")
    expect_equal "malformed expect.tsv lines" "" "$bad"
}

# ---------------------------------------------------------- real file

t_tsv_entries() {
    render "$1"
    well_formed
    expect_line "chezmoi${TAB}command${TAB}chezmoi${TAB}~/.local/bin/chezmoi${TAB}chezmoi --version"
    expect_line "git${TAB}command${TAB}git${TAB}${TAB}git --version"
    expect_line "ws${TAB}command${TAB}ws${TAB}~/.local/bin/ws${TAB}"
    expect_line "git-config${TAB}file${TAB}~/.config/git/config"
    expect_line "expect-tsv${TAB}file${TAB}~/.config/ws/expect.tsv"
}

t_tsv_identities() {
    render "$1"
    has_file_check "~/.config/git/identities/$OWNER1"
    has_file_check "~/.config/git/identities/$OWNER2"
    has_file_check "~/.config/git/identities/.includes"
    has_file_check "~/.config/git/identities/.conflict"
}

t_ws_rendered() {
    NO_TSV=1 render "$1"
    [ -f "$DEST/.local/bin/ws" ] || { echo "no ~/.local/bin/ws" >&2; return 1; }
    [ -f "$DEST/.local/libexec/ws/ws-doctor.sh" ] || { echo "no ~/.local/libexec/ws/ws-doctor.sh" >&2; return 1; }
    case $(uname -s) in
        MINGW* | MSYS*) ;;
        *) [ -x "$DEST/.local/bin/ws" ] || { echo "~/.local/bin/ws is not executable" >&2; return 1; } ;;
    esac
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "expect.tsv $p: well formed, holds the first entries" -- t_tsv_entries "$profile"
    bats_test_function --description "expect.tsv $p: a file check per identity file, .includes and .conflict" -- t_tsv_identities "$profile"
    bats_test_function --description "ws $p: dispatcher and doctor are rendered" -- t_ws_rendered "$profile"
done

@test "expect.tsv: a dropped owner's identity check goes away" {
    one="$TEST_TMP/one-owner.toml"
    sed "s|^github_identities = .*|github_identities = \"$OWNER1=$EMAIL1\"|" \
        "$PROFILES_DIR/personal-desktop.toml" >"$one"
    render "$one"
    has_file_check "~/.config/git/identities/$OWNER1"
    if grep -qF "identities/$OWNER2" "$TSV"; then
        printf 'check for dropped owner kept:\n%s\n' "$(cat "$TSV")" >&2
        return 1
    fi
}

@test "expect.tsv: the template reads expect.yaml via .chezmoi.workingTree" {
    tmpl=$(find "$REPO_ROOT/home/dot_config/ws" -name '*expect.tsv*' 2>/dev/null | head -n 1)
    [ -n "$tmpl" ] || { echo "no expect.tsv template under home/dot_config/ws/" >&2; return 1; }
    grep -q 'chezmoi.workingTree' "$tmpl" || { echo "$tmpl does not use .chezmoi.workingTree" >&2; return 1; }
}

# ------------------------------------------------ filtering (fixture)

FIXTURE_YAML='checks:
  - id: everywhere
    file: ~/all
  - id: only-work
    roles: [work]
    file: ~/work
  - id: only-personal
    roles: [personal]
    absent: ~/personal
  - id: only-container
    forms: [container]
    file: ~/container
  - id: desktop-or-wsl
    forms: [desktop, wsl]
    file: ~/dw
  - id: work-headless
    roles: [work]
    forms: [headless]
    file: ~/wh
  - id: only-linux
    os: [linux]
    command: sh
    smoke: sh -c true
  - id: only-darwin
    os: [darwin]
    command: sw_vers
  - id: only-windows
    os: [windows]
    command: cmd
    source: ~/cmd
  - id: not-windows
    os: [linux, darwin]
    line: {file: ~/l, text: "a  b", count: 2}
  - id: all-filters
    os: [linux, darwin, windows]
    roles: [personal, work]
    forms: [desktop, headless, wsl, container]
    absent: ~/never'

# fixture_source: a copy of the source state with FIXTURE_YAML as
# tests/expect.yaml, as a git work tree; prints its root.
fixture_source() {
    src="$TEST_TMP/src"
    mkdir -p "$src/tests"
    cp -R "$REPO_ROOT/home" "$REPO_ROOT/scripts" "$REPO_ROOT/.chezmoiroot" "$src/"
    printf '%s\n' "$FIXTURE_YAML" >"$src/tests/expect.yaml"
    git init -q "$src"
    printf '%s\n' "$src"
}

# member <word> <list...>
member() {
    w=$1
    shift
    for x in "$@"; do [ "$x" = "$w" ] && return 0; done
    return 1
}

t_filtered() {
    profile=$1
    p=$(basename "$profile" .toml)
    role=${p%%-*}
    form=${p#*-}
    mkdir -p "$TEST_TMP/empty-source"
    os=$("$CHEZMOI" --no-tty --source "$TEST_TMP/empty-source" --config "$profile" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/state-read.boltdb" \
        execute-template '{{ .chezmoi.os }}')
    src=$(fixture_source)
    render "$profile" "$src"
    well_formed

    expect_line "everywhere${TAB}file${TAB}~/all"
    expect_line "all-filters${TAB}absent${TAB}~/never"

    if [ "$role" = work ]; then
        expect_line "only-work${TAB}file${TAB}~/work"
        expect_no_id only-personal
    else
        expect_line "only-personal${TAB}absent${TAB}~/personal"
        expect_no_id only-work
    fi

    if [ "$form" = container ]; then
        expect_line "only-container${TAB}file${TAB}~/container"
    else
        expect_no_id only-container
    fi

    if member "$form" desktop wsl; then
        expect_line "desktop-or-wsl${TAB}file${TAB}~/dw"
    else
        expect_no_id desktop-or-wsl
    fi

    if [ "$role-$form" = work-headless ]; then
        expect_line "work-headless${TAB}file${TAB}~/wh"
    else
        expect_no_id work-headless
    fi

    case $os in
        linux)
            expect_line "only-linux${TAB}command${TAB}sh${TAB}${TAB}sh -c true"
            expect_no_id only-darwin
            expect_no_id only-windows
            expect_line "not-windows${TAB}line${TAB}~/l${TAB}2${TAB}a  b"
            ;;
        windows)
            expect_line "only-windows${TAB}command${TAB}cmd${TAB}~/cmd${TAB}"
            expect_no_id only-linux
            expect_no_id only-darwin
            expect_no_id not-windows
            ;;
        darwin)
            expect_line "only-darwin${TAB}command${TAB}sw_vers${TAB}${TAB}"
            expect_no_id only-linux
            expect_no_id only-windows
            expect_line "not-windows${TAB}line${TAB}~/l${TAB}2${TAB}a  b"
            ;;
    esac

    # Identity checks are still added on top of the fixture's entries.
    has_file_check "~/.config/git/identities/$OWNER1"
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "expect.tsv $p: filtered by os, role and form (fixture)" -- t_filtered "$profile"
done

# ------------------------------------------ review round 1 (criterion 20)

@test "expect.tsv: identity checks have numbered ids that name no owner" {
    render "$PROFILES_DIR/personal-desktop.toml"
    ids=$(awk -F '\t' '$3 ~ /identities\/[^.]/ { print $1 }' "$TSV" | LC_ALL=C sort | tr '\n' ' ')
    expect_equal "identity ids" "git-identity-1 git-identity-2 " "$ids"
    if cut -f 1 "$TSV" | grep -qiE 'octo-(one|two)'; then
        printf 'an id names an owner:\n%s\n' "$(cut -f 1 "$TSV")" >&2
        return 1
    fi
}
