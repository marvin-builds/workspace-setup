#!/usr/bin/env bats
# Unit tests for the font linker (slice 7, criteria 4-6 and 17): the
# template home/.chezmoiscripts/run_onchange_after_link-fonts.sh.tmpl is
# rendered with the pinned chezmoi for a Linux desktop and the result is
# run with a stub mise and a stub fc-cache. Nothing reaches the real mise,
# fc-cache, sudo or apt.
#
# Interface (the implementation follows this; rendering is covered in
# tests/render/fonts.bats):
#
#   With CHEZMOI_DEST_DIR equal to CHEZMOI_HOME_DIR, the rendered script
#   asks mise for each font's install dir with `mise where <tool>`, the
#   tool named by its config key (github:JetBrains/JetBrainsMono,
#   github:ryanoasis/nerd-fonts; a trailing @<version> is fine), never a
#   hardcoded version or path. It then rebuilds the one dir it owns,
#   ${XDG_DATA_HOME:-~/.local/share}/fonts/ws (review round 1: with
#   XDG_DATA_HOME set, the links go there and nothing under
#   ~/.local/share; most tests run with it unset):
#     - afterwards the dir holds only symlinks (and subdirs, if any), one
#       to every .ttf and .otf file under each install dir (decided with
#       the test writer: every one, including variable fonts), none to
#       anything else; nothing it held before survives (stale links of an
#       older version, stray files);
#     - nothing outside that dir is created, changed or removed;
#     - then fc-cache runs once with the owned dir as an argument (flags
#       allowed), after the links are in place.
#   A rerun with nothing changed leaves the same links.
#   Failures exit non-zero and name the cause: `mise where` failing (its
#   error output reaches the caller), an install dir that doesn't exist
#   (the message names the tool or the dir), mise missing from PATH (the
#   message names mise), fc-cache failing (the message names fc-cache),
#   an install dir without any .ttf/.otf (the message names the font) and
#   a font search that fails, e.g. on an unreadable subdir or a failing
#   find (review round 1: no error hidden in a pipeline).
#   No sudo.
#
#   Otherwise (destination guard): one line containing "skip", exit 0,
#   neither mise nor fc-cache called, the owned dir not created.
#
# Stubs (decided with the test writer):
#   mise      appends its arguments as one line to $MISE_LOG. With
#             STUB_MISE_FAIL set: prints "stub-mise: <value>" on stderr,
#             exits 3. `where <tool>`: prints the tool's fixture install
#             dir, $FIXTURES/<mise-style name>/<version in its
#             `current` file>; with STUB_MISE_MISSING set to a substring
#             of the tool, prints "mise ERROR <tool> is not installed" on
#             stderr and exits 1; with STUB_MISE_NODIR set to a substring
#             of the tool, prints a dir that doesn't exist. Anything else
#             exits 0 silently.
#   fc-cache  appends its arguments to $FC_LOG and, for every argument
#             that is a dir, "<dir> <number of symlinks in it>" to
#             $FC_SEEN. With STUB_FC_FAIL set: prints
#             "stub-fc-cache: <value>" on stderr, exits 2.

load ../helpers/common

TMPL=home/.chezmoiscripts/run_onchange_after_link-fonts.sh.tmpl

setup_file() {
    # System commands without mise, fontconfig and the guarded ones.
    sysbin="$BATS_FILE_TMPDIR/sysbin"
    mkdir -p "$sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            case $n in
                mise | sudo | apt | apt-get | su | doas | fc-*) continue ;;
            esac
            [ -e "$sysbin/$n" ] || [ -L "$sysbin/$n" ] || ln -s "$f" "$sysbin/$n"
        done
    done
}

setup() {
    ws_isolate
    [ "$(uname -s)" = Linux ] || skip "the font linker is Linux only"
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    SYSBIN="$BATS_FILE_TMPDIR/sysbin"
    unset XDG_DATA_HOME STUB_MISE_FAIL STUB_MISE_MISSING STUB_MISE_NODIR STUB_FC_FAIL
    OWNED="$HOME/.local/share/fonts/ws"
    MISE_STUBS="$TEST_TMP/mise-stub"
    FC_STUBS="$TEST_TMP/fc-stub"
    mkdir -p "$MISE_STUBS" "$FC_STUBS"
    MISE_LOG="$TEST_TMP/mise.log"
    FC_LOG="$TEST_TMP/fc.log"
    FC_SEEN="$TEST_TMP/fc-seen.log"
    FIXTURES="$TEST_TMP/installs"
    : >"$MISE_LOG"
    : >"$FC_LOG"
    : >"$FC_SEEN"
    export MISE_LOG FC_LOG FC_SEEN FIXTURES
    cat >"$MISE_STUBS/mise" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_LOG"
if [ -n "${STUB_MISE_FAIL:-}" ]; then
    printf 'stub-mise: %s\n' "$STUB_MISE_FAIL" >&2
    exit 3
fi
[ "${1:-}" = where ] || exit 0
shift
tool=
for a in "$@"; do
    case $a in -*) ;; *) tool=$a ;; esac
done
case $tool in
    *JetBrainsMono*) name=github-jetbrains-jetbrainsmono ;;
    *nerd-fonts*) name=github-ryanoasis-nerd-fonts ;;
    *) printf 'mise ERROR %s is not in the config\n' "$tool" >&2; exit 1 ;;
esac
if [ -n "${STUB_MISE_MISSING:-}" ]; then
    case $tool in *"$STUB_MISE_MISSING"*)
        printf 'mise ERROR %s is not installed\n' "$tool" >&2
        exit 1 ;;
    esac
fi
if [ -n "${STUB_MISE_NODIR:-}" ]; then
    case $tool in *"$STUB_MISE_NODIR"*)
        printf '%s\n' "$FIXTURES/$name/0.0.0-missing"
        exit 0 ;;
    esac
fi
printf '%s\n' "$FIXTURES/$name/$(cat "$FIXTURES/$name/current")"
EOF
    cat >"$FC_STUBS/fc-cache" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$FC_LOG"
for a in "$@"; do
    [ -d "$a" ] || continue
    printf '%s %s\n' "${a%/}" "$(find "$a" -type l | wc -l | tr -d ' ')" >>"$FC_SEEN"
done
if [ -n "${STUB_FC_FAIL:-}" ]; then
    printf 'stub-fc-cache: %s\n' "$STUB_FC_FAIL" >&2
    exit 2
fi
exit 0
EOF
    chmod +x "$MISE_STUBS/mise" "$FC_STUBS/fc-cache"
    make_fixtures
    RENDERED="$TEST_TMP/link-fonts.sh"
}

# put <file>: creates a fixture file with some content.
put() {
    mkdir -p "$(dirname "$1")"
    printf 'fixture %s\n' "${1##*/}" >"$1"
}

# make_fixtures: install dirs laid out like the release assets, two
# JetBrains Mono versions (2.304 current) and one nerd-fonts version.
make_fixtures() {
    jb="$FIXTURES/github-jetbrains-jetbrainsmono"
    nf="$FIXTURES/github-ryanoasis-nerd-fonts"
    for f in fonts/ttf/JetBrainsMono-Regular.ttf fonts/ttf/JetBrainsMono-Bold.ttf \
        'fonts/variable/JetBrainsMono[wght].ttf' fonts/otf/JetBrainsMono-Italic.otf \
        fonts/webfonts/JetBrainsMono-Regular.woff2 OFL.txt AUTHORS.txt; do
        put "$jb/2.304/$f"
    done
    for f in fonts/ttf/JetBrainsMono-Regular.ttf fonts/ttf/JetBrainsMono-Thin.ttf OFL.txt; do
        put "$jb/2.305/$f"
    done
    printf '2.304\n' >"$jb/current"
    for f in SymbolsNerdFont-Regular.ttf SymbolsNerdFontMono-Regular.ttf \
        10-nerd-font-symbols.conf LICENSE README.md; do
        put "$nf/3.5.1/$f"
    done
    printf '3.5.1\n' >"$nf/current"
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

# run_linker [<PATH> [<destination>]]: runs the rendered script as chezmoi
# would; PATH defaults to both stubs first, the destination to the home.
run_linker() {
    run env PATH="${1:-$MISE_STUBS:$FC_STUBS:$PATH}" \
        CHEZMOI_WORKING_TREE="$REPO_ROOT" \
        CHEZMOI_SOURCE_DIR="$REPO_ROOT/home" \
        CHEZMOI_DEST_DIR="${2:-$HOME}" CHEZMOI_HOME_DIR="$HOME" \
        "$RENDERED"
}

# want_targets: the real paths of every .ttf/.otf of the current versions.
want_targets() {
    for name in github-jetbrains-jetbrainsmono github-ryanoasis-nerd-fonts; do
        d="$FIXTURES/$name/$(cat "$FIXTURES/$name/current")"
        find "$d" -type f \( -name '*.ttf' -o -name '*.otf' \) -exec realpath {} \;
    done | LC_ALL=C sort
}

# link_targets: the real paths the owned dir's symlinks point to.
link_targets() {
    find "$OWNED" -type l -exec realpath {} \; | LC_ALL=C sort
}

# links: "<link path> -> <target>" for every symlink in the owned dir.
links() {
    find "$OWNED" -type l | LC_ALL=C sort | while IFS= read -r l; do
        printf '%s -> %s\n' "$l" "$(readlink "$l")"
    done
}

# expect_owned_dir_exact: the owned dir holds only symlinks (and dirs),
# exactly one to each wanted font file, none dangling.
expect_owned_dir_exact() {
    [ -d "$OWNED" ] || { echo "owned dir $OWNED was not created" >&2; return 1; }
    other=$(find "$OWNED" -mindepth 1 ! -type l ! -type d)
    expect_equal "non-links in the owned dir" "" "$other"
    dangling=$(find "$OWNED" -xtype l)
    expect_equal "dangling links in the owned dir" "" "$dangling"
    expect_equal "link targets" "$(want_targets)" "$(link_targets)"
}

# home_snapshot: everything under the test's home and XDG dirs except
# the owned dir: path, type, and for files size, mtime and link target.
# Directories count by path only (creating the owned dir changes its
# parent's mtime).
home_snapshot() {
    for d in "$HOME" "$TEST_TMP"/xdg-*; do
        find "$d" -path "$OWNED" -prune -o \( -type d -printf '%p d\n' \) -o \
            -printf '%p %y %s %T@ %l\n'
    done | LC_ALL=C sort
}

# seed_neighbours: fonts and config next to the owned dir that must stay.
seed_neighbours() {
    put "$HOME/.local/share/fonts/user-font.ttf"
    put "$HOME/.local/share/fonts/other/Other-Regular.otf"
    put "$HOME/.local/share/fonts/wsx/keep.ttf"
    ln -s "$HOME/.local/share/fonts/user-font.ttf" "$HOME/.local/share/fonts/user-link.ttf"
    put "$HOME/.config/fontconfig/fonts.conf"
}

# ------------------------------------------------- linking (4, 17)

@test "link-fonts: links every .ttf/.otf of both fonts into the owned dir, nothing else (criteria 4, 17)" {
    render
    run_linker
    expect_status 0
    expect_owned_dir_exact
    expect_guard_untouched
}

@test "link-fonts: finds the fonts with mise where, by config key (criterion 4)" {
    render
    run_linker
    expect_status 0
    for key in github:JetBrains/JetBrainsMono github:ryanoasis/nerd-fonts; do
        grep -qE "^where( .*)? $key(@[^ ]+)?( |\$)" "$MISE_LOG" || {
            printf 'no "mise where %s"; mise calls:\n%s\n' "$key" "$(cat "$MISE_LOG")" >&2
            return 1
        }
    done
    bad=$(grep -vE '^[[:space:]]*#' "$RENDERED" | grep -nE '2\.304|3\.5\.1|/installs/' || true)
    expect_equal "hardcoded versions or install paths in the script" "" "$bad"
}

@test "link-fonts: runs fc-cache once on the owned dir, after linking (criteria 4, 17)" {
    render
    run_linker
    expect_status 0
    expect_equal "fc-cache calls" 1 "$(grep -c . "$FC_LOG")"
    n=$(want_targets | grep -c .)
    grep -qxF "$OWNED $n" "$FC_SEEN" || {
        printf 'fc-cache did not get %s with its %s links in place; seen:\n%s\ncalls:\n%s\n' \
            "$OWNED" "$n" "$(cat "$FC_SEEN")" "$(cat "$FC_LOG")" >&2
        return 1
    }
}

@test "link-fonts: stale links and stray files in the owned dir are removed (criteria 4, 17)" {
    render
    mkdir -p "$OWNED/old"
    ln -s /nonexistent/JetBrainsMono-2.303/JetBrainsMono-Regular.ttf "$OWNED/JetBrainsMono-Regular.ttf"
    ln -s "$FIXTURES/github-jetbrains-jetbrainsmono/2.305/fonts/ttf/JetBrainsMono-Thin.ttf" "$OWNED/old/JetBrainsMono-Thin.ttf"
    put "$OWNED/stray.ttf"
    run_linker
    expect_status 0
    expect_owned_dir_exact
}

@test "link-fonts: a font bump leaves no link of the older version (criteria 4, 17)" {
    render
    run_linker
    expect_status 0
    printf '2.305\n' >"$FIXTURES/github-jetbrains-jetbrainsmono/current"
    run_linker
    expect_status 0
    expect_owned_dir_exact
    old=$(link_targets | grep -F '/2.304/' || true)
    expect_equal "links into 2.304" "" "$old"
}

@test "link-fonts: nothing outside the owned dir is touched (criteria 4, 17)" {
    render
    seed_neighbours
    before=$(home_snapshot)
    run_linker
    expect_status 0
    expect_equal "home outside the owned dir" "$before" "$(home_snapshot)"
    # Fixtures are only linked, never changed.
    for f in "$FIXTURES"/*/*/*; do
        [ ! -L "$f" ] || { echo "a fixture became a link: $f" >&2; return 1; }
    done
}

@test "link-fonts: a rerun with nothing changed leaves the same links (criterion 6)" {
    render
    run_linker
    expect_status 0
    first=$(links)
    run_linker
    expect_status 0
    expect_equal "links after the rerun" "$first" "$(links)"
    expect_owned_dir_exact
}

# ------------------------------------------------- guard (5, 17)

@test "link-fonts: another destination skips with one line, nothing called or created (criteria 5, 17)" {
    render
    run_linker "$MISE_STUBS:$FC_STUBS:$PATH" "$TEST_TMP/dest"
    expect_status 0
    expect_equal "output lines" 1 "$(printf '%s\n' "$output" | grep -c .)"
    expect_output_matches '[Ss]kip'
    expect_equal "mise calls" "" "$(cat "$MISE_LOG")"
    expect_equal "fc-cache calls" "" "$(cat "$FC_LOG")"
    [ ! -e "$OWNED" ] || { echo "the owned dir was created" >&2; return 1; }
}

@test "link-fonts: no sudo (criterion 5)" {
    render
    bad=$(grep -vE '^[[:space:]]*#' "$RENDERED" | grep -nw 'sudo' || true)
    expect_equal "sudo in the script" "" "$bad"
    run_linker
    expect_status 0
    expect_guard_untouched
}

# ------------------------------------------------- failures (5, 17)

@test "link-fonts: a failing mise fails the script and names the cause (criteria 5, 17)" {
    render
    STUB_MISE_FAIL='cannot read the config'
    export STUB_MISE_FAIL
    run_linker
    expect_failure
    expect_output_matches 'stub-mise: cannot read the config'
}

@test "link-fonts: a font that isn't installed fails the script naming it (criteria 5, 17)" {
    render
    STUB_MISE_MISSING=nerd-fonts
    export STUB_MISE_MISSING
    run_linker
    expect_failure
    expect_output_matches 'nerd-fonts'
}

@test "link-fonts: an install dir that doesn't exist fails the script naming it (criteria 5, 17)" {
    render
    STUB_MISE_NODIR=JetBrainsMono
    export STUB_MISE_NODIR
    run_linker
    expect_failure
    expect_output_matches '[Jj]et[Bb]rains[Mm]ono'
}

@test "link-fonts: mise missing from PATH fails naming mise (criterion 5)" {
    render
    run_linker "$FC_STUBS:$SYSBIN"
    expect_failure
    expect_output_matches 'mise'
}

@test "link-fonts: a failing fc-cache fails the script and names it (criteria 5, 17)" {
    render
    STUB_FC_FAIL='no writable cache dir'
    export STUB_FC_FAIL
    run_linker
    expect_failure
    expect_output_matches 'fc-cache'
}

# ------------------------------------------------ review round 1

teardown() {
    # The unreadable-subdir test removes permissions; give them back so
    # bats can delete the temp dir.
    [ -z "${FIXTURES:-}" ] || chmod -R u+rwx "$FIXTURES" 2>/dev/null || true
}

@test "link-fonts: with XDG_DATA_HOME set, links go to its fonts/ws and nothing under ~/.local/share (review 1)" {
    render
    XDG_DATA_HOME="$TEST_TMP/xdg-custom"
    export XDG_DATA_HOME
    run_linker
    expect_status 0
    OWNED="$XDG_DATA_HOME/fonts/ws"
    expect_owned_dir_exact
    [ ! -e "$HOME/.local/share" ] || {
        printf 'something was created under ~/.local/share:\n%s\n' "$(find "$HOME/.local/share")" >&2
        return 1
    }
    n=$(want_targets | grep -c .)
    grep -qxF "$OWNED $n" "$FC_SEEN" || {
        printf 'fc-cache did not get %s; seen:\n%s\n' "$OWNED" "$(cat "$FC_SEEN")" >&2
        return 1
    }
}

@test "link-fonts: an install dir without any .ttf/.otf fails naming the font (criterion 5, review 1)" {
    render
    nf="$FIXTURES/github-ryanoasis-nerd-fonts"
    for f in 10-nerd-font-symbols.conf LICENSE README.md; do
        put "$nf/9.9.9/$f"
    done
    printf '9.9.9\n' >"$nf/current"
    run_linker
    expect_failure
    expect_output_matches 'nerd-fonts'
}

@test "link-fonts: an unreadable subdir in an install dir fails the script (criterion 5, review 1)" {
    [ "$(id -u)" -ne 0 ] || skip "root reads any dir"
    render
    chmod 000 "$FIXTURES/github-jetbrains-jetbrainsmono/2.304/fonts/variable"
    run_linker
    expect_failure
}

@test "link-fonts: a failing find fails the script (criterion 5, review 1)" {
    render
    real_find=$(command -v find)
    mkdir -p "$TEST_TMP/find-stub"
    # Prints what the real find prints, then fails as on an unreadable dir.
    cat >"$TEST_TMP/find-stub/find" <<EOF
#!/bin/sh
"$real_find" "\$@"
printf 'find: stub-find: Permission denied\n' >&2
exit 1
EOF
    chmod +x "$TEST_TMP/find-stub/find"
    run_linker "$TEST_TMP/find-stub:$MISE_STUBS:$FC_STUBS:$PATH"
    expect_failure
}
