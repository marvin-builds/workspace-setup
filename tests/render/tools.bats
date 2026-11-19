#!/usr/bin/env bats
# Render tests for the mise tool installer (slice 6, criteria 7, 8 and 19).
# No test here runs the real mise, sudo or apt-get: ws_isolate puts failing
# guards for them first on PATH, and applies go to a temp destination,
# where the installer skips. Its behaviour with a stub mise is tested in
# tests/unit/install-tools.bats.
#
# Interface (the implementation follows this):
#
#   home/.chezmoiscripts/run_onchange_after_install-tools.sh.tmpl
#                       -> chezmoi target .chezmoiscripts/install-tools.sh
#   home/dot_config/mise/config.toml and its lockfile (mise.lock or
#   config.lock, see tests/unit/mise-data.bats)
#                       -> ~/.config/mise/<same names>
#
#   The template renders a shell script (#!/bin/sh or bash) that is clean
#   under shellcheck and embeds the sha256 of config.toml and the lockfile
#   (as sha256sum prints them for the source files), so a change to either
#   changes the rendered text and chezmoi runs it again.
#
#   Destination guard (slice 5, decision 21): when CHEZMOI_DEST_DIR is not
#   CHEZMOI_HOME_DIR, the script prints one line containing "skip" and
#   naming the tools installer (the line contains "tools"; decided with
#   the test writer, so the packages and tools skip lines can be told
#   apart) and exits 0.
#
#   .chezmoiignore excludes .chezmoiscripts/install-tools.sh on every OS
#   but Linux.

load ../helpers/common

TMPL=home/.chezmoiscripts/run_onchange_after_install-tools.sh.tmpl
TARGET=.chezmoiscripts/install-tools.sh
MISE_DIR=home/dot_config/mise

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    mkdir -p "$DEST"
}

on_linux() {
    [ "$(uname -s)" = Linux ]
}

skip_unless_linux() {
    on_linux || skip "the tool installer is Linux only (excluded elsewhere)"
}

require_template() {
    [ -f "$REPO_ROOT/$TMPL" ] && return 0
    echo "missing $TMPL" >&2
    return 1
}

# lockfile_name: the lockfile's name in home/dot_config/mise.
lockfile_name() {
    for n in mise.lock config.lock; do
        [ ! -f "$REPO_ROOT/$MISE_DIR/$n" ] || { printf '%s\n' "$n"; return 0; }
    done
    echo "no mise.lock or config.lock in $MISE_DIR" >&2
    return 1
}

# exec_tmpl <source root> <profile>: renders the template as chezmoi apply
# would for a machine whose destination is its home.
exec_tmpl() {
    "$CHEZMOI" --no-tty --source "$1/home" --destination "$HOME" \
        --config "$2" --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --file "$1/$TMPL"
}

# copy_source: a copy of the source state as a git work tree; prints it.
copy_source() {
    src="$TEST_TMP/src"
    mkdir -p "$src/tests"
    cp -R "$REPO_ROOT/home" "$REPO_ROOT/scripts" "$REPO_ROOT/.chezmoiroot" "$src/"
    cp "$REPO_ROOT/tests/expect.yaml" "$src/tests/expect.yaml"
    git init -q "$src"
    printf '%s\n' "$src"
}

# ---------------------------------------------- renders (criteria 7, 19)

t_renders() {
    skip_unless_linux
    require_template
    run exec_tmpl "$REPO_ROOT" "$1"
    expect_status 0
    printf '%s\n' "$output" >"$TEST_TMP/rendered.sh"
    shebang=$(head -n 1 "$TEST_TMP/rendered.sh")
    case $shebang in
        '#!/bin/sh') run sh -n "$TEST_TMP/rendered.sh" ;;
        '#!/bin/bash' | '#!/usr/bin/env bash') run bash -n "$TEST_TMP/rendered.sh" ;;
        *) echo "unexpected shebang: $shebang" >&2; return 1 ;;
    esac
    expect_status 0
    require_tool shellcheck
    run "$(tool_path shellcheck)" "$TEST_TMP/rendered.sh"
    expect_status 0
    lock=$(lockfile_name)
    for f in config.toml "$lock"; do
        sum=$(sha256sum "$REPO_ROOT/$MISE_DIR/$f" | cut -d ' ' -f 1)
        grep -qF "$sum" "$TEST_TMP/rendered.sh" || {
            echo "rendered script lacks the sha256 of $MISE_DIR/$f ($sum)" >&2
            return 1
        }
    done
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "tools $p: installer template renders, passes shellcheck, embeds the config and lockfile sha256" -- t_renders "$profile"
done

# t_changes <file under home/dot_config/mise>: the rendered script changes
# when that file changes.
t_changes() {
    skip_unless_linux
    require_template
    src=$(copy_source)
    before=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    printf '# a change\n' >>"$src/$MISE_DIR/$1"
    after=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    [ "$before" != "$after" ] || {
        echo "rendered script ignores changes to $MISE_DIR/$1" >&2
        return 1
    }
}

@test "tools: the rendered script changes when the mise config changes" {
    t_changes config.toml
}

@test "tools: the rendered script changes when the lockfile changes" {
    skip_unless_linux
    lock=$(lockfile_name)
    t_changes "$lock"
}

# ------------------------------------------------ destination guard (8)

# apply_to_dest <source root> <profile>: chezmoi apply into $DEST.
apply_to_dest() {
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$1/home" --destination "$DEST" --config "$2" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        apply --force
}

@test "tools: apply into another destination skips the installer with one line, no real mise" {
    skip_unless_linux
    require_template
    apply_to_dest "$REPO_ROOT" "$PROFILES_DIR/personal-desktop.toml"
    expect_status 0
    n=$(printf '%s\n' "$output" | grep -i 'skip' | grep -ci 'tools' || true)
    expect_equal "tools skip lines in the apply output" 1 "$n"
    expect_guard_untouched
}

@test "tools: the config and the lockfile land in ~/.config/mise unchanged" {
    skip_unless_linux
    lock=$(lockfile_name)
    apply_to_dest "$REPO_ROOT" "$PROFILES_DIR/work-headless.toml"
    expect_status 0
    for f in config.toml "$lock"; do
        cmp -s "$REPO_ROOT/$MISE_DIR/$f" "$DEST/.config/mise/$f" || {
            echo "rendered .config/mise/$f differs from $MISE_DIR/$f or is missing" >&2
            return 1
        }
    done
}

# ------------------------------------------------------- Linux only (7)

ignore_for() {
    "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$DEST" \
        --config "$PROFILES_DIR/personal-desktop.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --override-data "{\"chezmoi\":{\"os\":\"$1\"}}" \
        --file "$REPO_ROOT/home/.chezmoiignore"
}

@test "tools: .chezmoiignore excludes the installer on every OS but Linux" {
    for os in darwin windows freebsd; do
        run ignore_for "$os"
        expect_status 0
        printf '%s\n' "$output" | grep -qxF -- "$TARGET" || {
            printf '%s: .chezmoiignore lacks %s; rendered:\n%s\n' "$os" "$TARGET" "$output" >&2
            return 1
        }
    done
    run ignore_for linux
    expect_status 0
    expect_output_lacks "install-tools"
}

@test "tools: the installer is a managed after script on Linux" {
    skip_unless_linux
    [ -f "$REPO_ROOT/$TMPL" ] || { echo "missing $TMPL (an after_ script)" >&2; return 1; }
    # shellcheck disable=SC2034 # read by cz
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    run cz managed --include=scripts
    expect_status 0
    printf '%s\n' "$output" | grep -qxF "$TARGET" || {
        printf 'installer not managed; scripts:\n%s\n' "$output" >&2
        return 1
    }
}
