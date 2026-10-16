#!/usr/bin/env bats
# Render tests for the slice 3 additions to home/.chezmoi.toml.tmpl
# (criteria 2.6 and 4).
#
#   data key   function          prompt text   default
#   repos_dir  promptStringOnce  Repos dir     parent of the source dir
#
# "Source dir" is the clone passed to `chezmoi init --source` (the repo
# root holding .chezmoiroot), so the default for a clone at
# ~/dev/workspace-setup is ~/dev, not the clone itself.
#
# sourceDir: the generated config must make a later plain `chezmoi apply`
# (no --source) use the same source. Checked with the pinned chezmoi: with
# a config holding only the generated TOML, `chezmoi source-path` must print
# <clone>/home. (chezmoi 2.73.1 honours .chezmoiroot whether sourceDir is
# the clone root or <clone>/home, so either value passes.)

load ../helpers/common

TEMPLATE="$REPO_ROOT/home/.chezmoi.toml.tmpl"

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    OUT_TOML="$TEST_TMP/generated.toml"
    EMPTY_SRC="$TEST_TMP/empty-source"
    mkdir -p "$EMPTY_SRC"
}

# init_template <config> <prompt flags...>: renders the config template as
# `chezmoi init --source <repo root>` would, output in $OUT_TOML.
init_template() {
    config=$1
    shift
    run "$CHEZMOI" --no-tty --source "$REPO_ROOT" --config "$config" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --init \
        --promptChoice "Role=work" \
        --promptChoice "Form=container" \
        --promptString "Name=$FAKE_NAME" \
        --promptString "GitHub identities=$FAKE_IDENTITIES" \
        --promptBool "CI=true" \
        "$@" <"$TEMPLATE"
    [ "$status" -ne 0 ] || printf '%s\n' "$output" >"$OUT_TOML"
}

# data_of <toml> <template>
data_of() {
    "$CHEZMOI" --no-tty --source "$EMPTY_SRC" --config "$1" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/state-read.boltdb" \
        execute-template "$2"
}

@test "config template: Repos dir prompt sets repos_dir" {
    init_template "$TEST_TMP/no-config.toml" --promptString "Repos dir=$HOME/code"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .repos_dir }}'
    expect_status 0
    expect_equal repos_dir "$HOME/code" "$output"
}

@test "config template: repos_dir defaults to the parent of the source dir" {
    init_template "$TEST_TMP/no-config.toml"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .repos_dir }}'
    expect_status 0
    expect_equal repos_dir "$(native_path "$(dirname "$REPO_ROOT")")" "$output"
}

@test "config template: an existing repos_dir is kept" {
    existing="$TEST_TMP/existing.toml"
    cat >"$existing" <<EOF
[data]
role = "work"
form = "container"
name = "$FAKE_NAME"
github_identities = "$FAKE_IDENTITIES"
ci = true
repos_dir = "$HOME/kept"
EOF
    init_template "$existing" --promptString "Repos dir=$HOME/other"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .repos_dir }}'
    expect_equal repos_dir "$HOME/kept" "$output"
}

@test "config template: records sourceDir, so a later plain apply uses the clone" {
    init_template "$TEST_TMP/no-config.toml" --promptString "Repos dir=$HOME/dev"
    expect_status 0
    grep -q 'sourceDir' "$OUT_TOML" || {
        printf 'no sourceDir in the generated config:\n%s\n' "$(cat "$OUT_TOML")" >&2
        return 1
    }
    # No --source: chezmoi must take it from the generated config.
    run "$CHEZMOI" --no-tty --config "$OUT_TOML" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/state-read.boltdb" \
        source-path
    expect_status 0
    expect_equal "source-path" "$(native_path "$REPO_ROOT/home")" "$output"
}

@test "profiles: every profile sets a fake repos_dir" {
    for profile in "$PROFILES_DIR"/*.toml; do
        run data_of "$profile" '{{ .repos_dir }}'
        expect_status 0
        [ -n "$output" ] || { echo "$(basename "$profile"): empty repos_dir" >&2; return 1; }
    done
}
