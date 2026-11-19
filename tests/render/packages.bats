#!/usr/bin/env bats
# Render tests for the package installer script (slice 5, criteria 7, 12
# and 17). No test here runs the real sudo or apt-get: ws_isolate puts
# failing guards for them first on PATH, the template is executed against
# a recorder in place of scripts/install-apt.sh, and applies go to a temp
# destination, where the installer skips.
#
# Interface (the implementation follows this):
#
#   home/.chezmoiscripts/run_onchange_before_install-packages.sh.tmpl
#                       -> chezmoi target .chezmoiscripts/install-packages.sh
#
#   The template reads home/.chezmoidata/packages.yaml (.packages and
#   .apt_repos), keeps the entries whose roles and forms filters (missing
#   means all) match the machine's role and form and whose apt id is not
#   null, and renders a #!/bin/sh script that passes shellcheck and
#   embeds the sha256 of scripts/install-apt.sh and the filtered data, so
#   a change to either changes the rendered text.
#
#   The rendered script runs
#       "$CHEZMOI_WORKING_TREE/scripts/install-apt.sh" install
#   (directly or through sh) with the filtered data on stdin, in the format
#   of tests/unit/install-apt.bats: one `package<TAB><id>` line per id and
#   one `repo<TAB>...` line per apt_repos entry that a kept entry names
#   (each repo once; values of list fields, fingerprints included, joined
#   by single spaces in the order of packages.yaml;
#   architectures empty when absent). Line order is free. The data is not
#   shell code: it reaches install-apt.sh as text.
#
#   Destination guard (decided with the test writer): when
#   CHEZMOI_DEST_DIR is not CHEZMOI_HOME_DIR (a render into another
#   directory, as in every render test), the script prints one line
#   saying it skipped (the line contains "skip") and exits 0 without
#   running install-apt.sh.
#
#   .chezmoiignore excludes .chezmoiscripts/install-packages.sh on every
#   OS but Linux, like the shell base.
#
# Filtering is tested with tests/schema/fixtures/valid-filtered.yaml as
# packages.yaml in a copy of the source state.

load ../helpers/common

TMPL=home/.chezmoiscripts/run_onchange_before_install-packages.sh.tmpl
TARGET=.chezmoiscripts/install-packages.sh
FIXTURE="$REPO_ROOT/tests/schema/fixtures/valid-filtered.yaml"
TAB=$(printf '\t')

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    REC="$TEST_TMP/recorder"
    mkdir -p "$DEST" "$REC"
}

on_linux() {
    [ "$(uname -s)" = Linux ]
}

skip_unless_linux() {
    on_linux || skip "the package installer is Linux only (excluded elsewhere)"
}

require_template() {
    [ -f "$REPO_ROOT/$TMPL" ] && return 0
    echo "missing $TMPL" >&2
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

# fixture_source [<packages.yaml>]: a copy of the source state as a git
# work tree, with the fixture as packages.yaml and a recorder as
# scripts/install-apt.sh that writes its arguments to $REC/args and its
# stdin to $REC/stdin. Prints the root.
fixture_source() {
    src="$TEST_TMP/src"
    mkdir -p "$src/tests"
    cp -R "$REPO_ROOT/home" "$REPO_ROOT/scripts" "$REPO_ROOT/.chezmoiroot" "$src/"
    cp "$REPO_ROOT/tests/expect.yaml" "$src/tests/expect.yaml"
    mkdir -p "$src/home/.chezmoidata"
    cp "${1:-$FIXTURE}" "$src/home/.chezmoidata/packages.yaml"
    cat >"$src/scripts/install-apt.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >"$REC/args"
cat >"$REC/stdin"
EOF
    chmod +x "$src/scripts/install-apt.sh"
    git init -q "$src"
    printf '%s\n' "$src"
}

# run_rendered <script file> <source root>: runs a rendered script as
# chezmoi would on a machine whose destination is its home.
run_rendered() {
    run env CHEZMOI_WORKING_TREE="$2" CHEZMOI_SOURCE_DIR="$2/home" \
        CHEZMOI_DEST_DIR="$HOME" CHEZMOI_HOME_DIR="$HOME" sh "$1"
}

# sorted_data: the recorded stdin without comments and empty lines, sorted.
sorted_data() {
    grep -vE '^[[:space:]]*(#|$)' "$REC/stdin" | LC_ALL=C sort
}

REPO_A="repo${TAB}fixture-a${TAB}https://example.org/keys/fixture-a.asc${TAB}0123456789ABCDEF0123456789ABCDEF01234567 76543210FEDCBA9876543210FEDCBA9876543210${TAB}0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef${TAB}https://example.org/apt${TAB}stable${TAB}main${TAB}amd64 arm64"
REPO_B="repo${TAB}fixture-b${TAB}https://example.com/fixture-b.gpg${TAB}89ABCDEF0123456789ABCDEF0123456789ABCDEF${TAB}fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210${TAB}https://example.com/apt/ https://mirror.example.com/apt/${TAB}*${TAB}*${TAB}"

# expected_data <role> <form>: what the fixture yields, sorted.
expected_data() {
    role=$1
    form=$2
    {
        printf 'package\t%s\n' common-tool
        if [ "$role" = work ]; then
            printf 'package\t%s\n' work-tool repo-b-extra
        else
            printf 'package\t%s\n' personal-tool repo-a-tool
            printf '%s\n' "$REPO_A"
        fi
        case $form in desktop | wsl) printf 'package\t%s\n' desktop-tool ;; esac
        [ "$role-$form" != work-headless ] || printf 'package\t%s\n' work-headless-tool
        [ "$form" != container ] || printf 'package\t%s\n' repo-b-tool
        if [ "$role" = work ] || [ "$form" = container ]; then
            printf '%s\n' "$REPO_B"
        fi
    } | LC_ALL=C sort
}

# ------------------------------------------------- real data (7, 17)

t_renders() {
    skip_unless_linux
    require_template
    run exec_tmpl "$REPO_ROOT" "$1"
    expect_status 0
    printf '%s\n' "$output" >"$TEST_TMP/rendered.sh"
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$TEST_TMP/rendered.sh")"
    run sh -n "$TEST_TMP/rendered.sh"
    expect_status 0
    require_tool shellcheck
    run "$(tool_path shellcheck)" "$TEST_TMP/rendered.sh"
    expect_status 0
    sum=$(sha256sum "$REPO_ROOT/scripts/install-apt.sh" | cut -d ' ' -f 1)
    grep -qF "$sum" "$TEST_TMP/rendered.sh" || {
        echo "rendered script lacks the sha256 of scripts/install-apt.sh ($sum)" >&2
        return 1
    }
}

# t_filtered <profile>: the fixture's filtered ids and needed repos, and
# nothing else, reach install-apt.sh install.
t_filtered() {
    skip_unless_linux
    require_template
    p=$(basename "$1" .toml)
    src=$(fixture_source)
    exec_tmpl "$src" "$1" >"$TEST_TMP/rendered.sh" || {
        echo "template did not render with the fixture" >&2
        return 1
    }
    # A glob in the data must not expand to these.
    mkdir -p "$TEST_TMP/cwd"
    touch "$TEST_TMP/cwd/glob-a" "$TEST_TMP/cwd/glob-b"
    cd "$TEST_TMP/cwd" || return 1
    run_rendered "$TEST_TMP/rendered.sh" "$src"
    expect_status 0
    [ -f "$REC/args" ] || { echo "install-apt.sh was not run" >&2; return 1; }
    expect_equal "install-apt.sh arguments" install "$(cat "$REC/args")"
    expect_equal "data for $p" "$(expected_data "${p%%-*}" "${p#*-}")" "$(sorted_data)"
    expect_guard_untouched
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "packages $p: installer template renders, passes shellcheck, embeds the install-apt.sh sha256" -- t_renders "$profile"
    bats_test_function --description "packages $p: exactly the filtered ids and needed repos reach install-apt.sh (fixture)" -- t_filtered "$profile"
done

@test "packages: the real data passes git, gh, ripgrep, fzf, glow, file, mise, libatomic1 and their repos" {
    skip_unless_linux
    require_template
    [ -f "$REPO_ROOT/home/.chezmoidata/packages.yaml" ] || {
        echo "missing home/.chezmoidata/packages.yaml" >&2
        return 1
    }
    src=$(fixture_source "$REPO_ROOT/home/.chezmoidata/packages.yaml")
    exec_tmpl "$src" "$PROFILES_DIR/work-container.toml" >"$TEST_TMP/rendered.sh"
    run_rendered "$TEST_TMP/rendered.sh" "$src"
    expect_status 0
    expect_equal "package lines" "package${TAB}file
package${TAB}fzf
package${TAB}gh
package${TAB}git
package${TAB}glow
package${TAB}libatomic1
package${TAB}mise
package${TAB}ripgrep" "$(sorted_data | grep '^package')"
    expect_equal "repos" "charm github-cli mise" "$(sorted_data | awk -F '\t' '$1 == "repo" { print $2 }' | tr '\n' ' ' | sed 's/ $//')"
}

# --------------------------------------------- rerun on change (7)

@test "packages: the rendered script changes when install-apt.sh changes" {
    skip_unless_linux
    require_template
    src=$(fixture_source)
    before=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    printf '# a change in the logic\n' >>"$src/scripts/install-apt.sh"
    after=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    [ "$before" != "$after" ] || {
        echo "rendered script ignores changes to scripts/install-apt.sh" >&2
        return 1
    }
}

@test "packages: the rendered script changes when a kept apt id changes" {
    skip_unless_linux
    require_template
    src=$(fixture_source)
    before=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    sed -i 's/^    apt: common-tool$/    apt: common-tool-ng/' "$src/home/.chezmoidata/packages.yaml"
    after=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    [ "$before" != "$after" ] || {
        echo "rendered script ignores a changed apt id" >&2
        return 1
    }
}

@test "packages: the rendered script changes when a needed repo changes" {
    skip_unless_linux
    require_template
    src=$(fixture_source)
    before=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    sed -i 's/0123456789ABCDEF0123456789ABCDEF01234567/FEDCBA9876543210FEDCBA9876543210FEDCBA98/' \
        "$src/home/.chezmoidata/packages.yaml"
    after=$(exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml")
    [ "$before" != "$after" ] || {
        echo "rendered script ignores a changed repo fingerprint" >&2
        return 1
    }
}

# ------------------------------------------ destination guard (17)

# apply_to_dest <source root> <profile>: chezmoi apply into $DEST (not
# $HOME).
apply_to_dest() {
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$1/home" --destination "$DEST" --config "$2" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        apply --force
}

@test "packages: apply into another destination skips the installer with one line" {
    skip_unless_linux
    require_template
    src=$(fixture_source)
    apply_to_dest "$src" "$PROFILES_DIR/personal-desktop.toml"
    expect_status 0
    [ ! -e "$REC/args" ] || { echo "install-apt.sh ran for a destination other than home" >&2; return 1; }
    # Other installers skip too (slice 6: install-tools); count this one's.
    n=$(printf '%s\n' "$output" | grep -i 'skip' | grep -ci 'packages' || true)
    expect_equal "packages skip lines in the apply output" 1 "$n"
    expect_guard_untouched
}

@test "packages: apply with the real source runs no real sudo or apt-get" {
    for p in personal-desktop work-container; do
        apply_to_dest "$REPO_ROOT" "$PROFILES_DIR/$p.toml"
        expect_status 0
        expect_guard_untouched
    done
}

@test "packages: the rendered script skips when the destination is not home" {
    skip_unless_linux
    require_template
    src=$(fixture_source)
    exec_tmpl "$src" "$PROFILES_DIR/personal-desktop.toml" >"$TEST_TMP/rendered.sh"
    run env CHEZMOI_WORKING_TREE="$src" CHEZMOI_SOURCE_DIR="$src/home" \
        CHEZMOI_DEST_DIR="$DEST" CHEZMOI_HOME_DIR="$HOME" sh "$TEST_TMP/rendered.sh"
    expect_status 0
    [ ! -e "$REC/args" ] || { echo "install-apt.sh ran for a destination other than home" >&2; return 1; }
    expect_equal "output lines" 1 "$(printf '%s\n' "$output" | grep -c .)"
    expect_output_matches '[Ss]kip'
}

# --------------------------------------------- Linux only (12)

ignore_for() {
    "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$DEST" \
        --config "$PROFILES_DIR/personal-desktop.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --override-data "{\"chezmoi\":{\"os\":\"$1\"}}" \
        --file "$REPO_ROOT/home/.chezmoiignore"
}

@test "packages: .chezmoiignore excludes the installer on every OS but Linux" {
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
    expect_output_lacks "install-packages"
}

@test "packages: the installer is a managed script on Linux" {
    skip_unless_linux
    # shellcheck disable=SC2034 # read by cz
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    run cz managed --include=scripts
    expect_status 0
    printf '%s\n' "$output" | grep -qxF "$TARGET" || {
        printf 'installer not managed; scripts:\n%s\n' "$output" >&2
        return 1
    }
}
