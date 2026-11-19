#!/usr/bin/env bats
# Render tests for the font linker (slice 7, criteria 3 and 15). No test
# here runs the real mise, fc-cache, sudo or apt-get: ws_isolate puts
# failing guards for mise, sudo and apt first on PATH, applies go to a temp
# destination, where the linker skips, and ws_block_network keeps chezmoi
# from downloading externals. Its behaviour with a stub mise and fc-cache
# is tested in tests/unit/link-fonts.bats.
#
# Interface (the implementation follows this):
#
#   home/.chezmoiscripts/run_onchange_after_link-fonts.sh.tmpl
#                       -> chezmoi target .chezmoiscripts/link-fonts.sh
#   (an after_ script whose name sorts after install-tools, so it runs
#   once the fonts are installed).
#
#   The template renders a shell script (#!/bin/sh or bash) that is clean
#   under shellcheck and embeds the sha256 of home/dot_config/mise/
#   config.toml and of its lockfile (as sha256sum prints them for the
#   source files), so a font bump reruns it.
#
#   .chezmoiignore excludes .chezmoiscripts/link-fonts.sh on every OS but
#   Linux and on every form but desktop.

load ../helpers/common

TMPL=home/.chezmoiscripts/run_onchange_after_link-fonts.sh.tmpl
TARGET=.chezmoiscripts/link-fonts.sh
MISE_DIR=home/dot_config/mise

setup() {
    ws_isolate
    ws_block_network
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    mkdir -p "$DEST"
}

skip_unless_linux() {
    [ "$(uname -s)" = Linux ] || skip "the font linker is Linux only (excluded elsewhere)"
}

require_template() {
    [ -f "$REPO_ROOT/$TMPL" ] && return 0
    echo "missing $TMPL" >&2
    return 1
}

# form_of <profile>: the profile's form.
form_of() {
    sed -n 's/^form = "\(.*\)"$/\1/p' "$1"
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

# --------------------------------------------- renders (criteria 3, 15)

# t_renders <profile>: on a Linux desktop the template renders a script
# that passes the syntax check and shellcheck and embeds both sha256;
# other forms don't get the script (see t_managed).
t_renders() {
    skip_unless_linux
    [ "$(form_of "$1")" = desktop ] || skip "the font linker is desktop only"
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

# t_managed <profile>: the linker is a managed script exactly on desktop.
t_managed() {
    skip_unless_linux
    require_template
    # shellcheck disable=SC2034 # read by cz
    PROFILE=$1
    run cz managed --include=scripts
    expect_status 0
    if [ "$(form_of "$1")" = desktop ]; then
        printf '%s\n' "$output" | grep -qxF "$TARGET" || {
            printf 'font linker not managed on a desktop; scripts:\n%s\n' "$output" >&2
            return 1
        }
    else
        expect_output_lacks "link-fonts"
    fi
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "fonts $p: linker template renders on desktop, passes shellcheck, embeds the config and lockfile sha256" -- t_renders "$profile"
    bats_test_function --description "fonts $p: the linker is managed on desktop only" -- t_managed "$profile"
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
        echo "rendered linker ignores changes to $MISE_DIR/$1" >&2
        return 1
    }
}

@test "fonts: the rendered linker changes when the mise config changes (criterion 3)" {
    t_changes config.toml
}

@test "fonts: the rendered linker changes when the lockfile changes (criterion 3)" {
    skip_unless_linux
    lock=$(lockfile_name)
    t_changes "$lock"
}

@test "fonts: the linker sorts after the tool installer (criterion 3)" {
    require_template
    first=$(printf '%s\n%s\n' "$(basename "$TMPL")" run_onchange_after_install-tools.sh.tmpl |
        LC_ALL=C sort | head -n 1)
    expect_equal "first after_ script" run_onchange_after_install-tools.sh.tmpl "$first"
}

# ---------------------------------------------- destination guard (5)

@test "fonts: apply into another destination skips the linker with one line, no real mise" {
    skip_unless_linux
    require_template
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$REPO_ROOT/home" --destination "$DEST" \
        --config "$PROFILES_DIR/personal-desktop.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        apply --force
    expect_status 0
    n=$(printf '%s\n' "$output" | grep -i 'skip' | grep -ci 'font' || true)
    expect_equal "font skip lines in the apply output" 1 "$n"
    expect_guard_untouched
}

# ------------------------------------------- Linux desktop only (3, 15)

# ignore_for <os> <profile>: .chezmoiignore rendered for that OS and profile.
ignore_for() {
    "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$DEST" \
        --config "$2" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --override-data "{\"chezmoi\":{\"os\":\"$1\"}}" \
        --file "$REPO_ROOT/home/.chezmoiignore"
}

@test "fonts: .chezmoiignore excludes the linker on every OS but Linux, and on Linux on every form but desktop" {
    for profile in "$PROFILES_DIR"/*.toml; do
        p=$(basename "$profile" .toml)
        for os in linux darwin windows freebsd; do
            run ignore_for "$os" "$profile"
            expect_status 0
            if [ "$os" = linux ] && [ "$(form_of "$profile")" = desktop ]; then
                expect_output_lacks "link-fonts"
            else
                printf '%s\n' "$output" | grep -qxF -- "$TARGET" || {
                    printf '%s on %s: .chezmoiignore lacks %s; rendered:\n%s\n' "$p" "$os" "$TARGET" "$output" >&2
                    return 1
                }
            fi
        done
    done
}
