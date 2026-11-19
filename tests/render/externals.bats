#!/usr/bin/env bats
# Render runs never download externals (slice 7, criteria 8 and 15).
#
# chezmoi 2.73.1 downloads an archive external whenever it reads the
# source state (apply, managed, diff, status, verify), also with
# `--exclude externals` (checked: the flag only filters what is written).
# A target in .chezmoiignore is not read, so nothing is downloaded.
#
# Interface (decided with the test writer):
#
#   The externals are skipped like the scripts' destination guard (slices
#   5 and 6): when the destination is not the home (`.chezmoi.destDir` ne
#   `.chezmoi.homeDir`, as in every render test, which applies into a temp
#   destination), .chezmoiignore (or a condition in
#   .chezmoiexternal.toml.tmpl) leaves them out, so no render test needs a
#   flag and none downloads. On the home of a Linux machine the piper
#   external is active; on any other OS it is left out (Linux only for
#   now, like yazi's install).
#
# Every test runs with ws_block_network, so a download fails with
# "connection refused". The active external is proven with a seeded
# chezmoi cache (<cache>/external/<sha256 of the url>, see
# tests/unit/externals-data.bats).

load ../helpers/common

setup() {
    ws_isolate
    ws_block_network
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    mkdir -p "$DEST"
}

# require_externals: the externals file exists (it is what is tested here).
require_externals() {
    for n in .chezmoiexternal.toml .chezmoiexternal.toml.tmpl; do
        [ ! -f "$REPO_ROOT/home/$n" ] || return 0
    done
    echo "missing home/.chezmoiexternal.toml(.tmpl)" >&2
    return 1
}

# plugin_url: the yazi-rs/plugins archive url in the externals file.
plugin_url() {
    for n in .chezmoiexternal.toml .chezmoiexternal.toml.tmpl; do
        [ -f "$REPO_ROOT/home/$n" ] || continue
        grep -oE 'https://github\.com/yazi-rs/plugins/archive/[0-9a-f]{40}\.tar\.gz' \
            "$REPO_ROOT/home/$n" | head -n 1
        return 0
    done
    return 1
}

# seed_plugin_cache: a fixture archive for the plugin url in the cache cz
# uses, so an active external is read without network.
seed_plugin_cache() {
    url=$(plugin_url)
    [ -n "$url" ] || { echo "no yazi-rs/plugins url in the externals file" >&2; return 1; }
    commit=$(printf '%s\n' "$url" | sed -E 's|.*/archive/([0-9a-f]+)\.tar\.gz$|\1|')
    top="$TEST_TMP/archive/plugins-$commit"
    mkdir -p "$top/piper.yazi" "$top/git.yazi" "$TEST_TMP/chezmoi-cache/external"
    printf 'return {}\n' >"$top/piper.yazi/main.lua"
    printf 'return {}\n' >"$top/git.yazi/main.lua"
    printf 'fixture\n' >"$top/README.md"
    tar -C "$TEST_TMP/archive" -czf \
        "$TEST_TMP/chezmoi-cache/external/$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1)" \
        "plugins-$commit"
}

# managed_at <destination> <profile> [<os>]: chezmoi managed for that
# destination, with chezmoi.os overridden when <os> is given.
managed_at() {
    override='{}'
    [ -z "${3:-}" ] || override="{\"chezmoi\":{\"os\":\"$3\"}}"
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$REPO_ROOT/home" --destination "$1" --config "$2" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        --override-data "$override" \
        managed --refresh-externals=never
}

# t_apply_offline <profile>: apply into a temp destination downloads
# nothing and creates no plugin.
t_apply_offline() {
    require_externals
    # shellcheck disable=SC2034 # read by cz
    PROFILE=$1
    run cz apply --force
    expect_status 0
    expect_output_lacks "127.0.0.1:9"
    [ ! -e "$DEST/.config/yazi/plugins" ] || {
        echo "apply into a temp destination created .config/yazi/plugins" >&2
        return 1
    }
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "externals $p: apply into a temp destination downloads nothing (criterion 15)" -- t_apply_offline "$profile"
done

@test "externals: managed and diff on a temp destination download nothing (criterion 15)" {
    require_externals
    # shellcheck disable=SC2034 # read by cz
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    run cz managed
    expect_status 0
    expect_output_lacks "piper.yazi"
    run cz diff
    expect_status 0
}

@test "externals: on a Linux home the piper external is active (criterion 8)" {
    [ "$(uname -s)" = Linux ] || skip "the host's OS decides chezmoi.os"
    require_externals
    seed_plugin_cache
    managed_at "$HOME" "$PROFILES_DIR/personal-headless.toml"
    expect_status 0
    printf '%s\n' "$output" | grep -qxF '.config/yazi/plugins/piper.yazi/main.lua' || {
        printf 'piper.yazi/main.lua is not managed on a Linux home; managed:\n%s\n' "$output" >&2
        return 1
    }
    expect_output_lacks "git.yazi"
}

@test "externals: on a home of any other OS the plugin is left out, nothing downloaded (criterion 8)" {
    require_externals
    for os in darwin windows; do
        managed_at "$HOME" "$PROFILES_DIR/personal-desktop.toml" "$os"
        expect_status 0
        expect_output_lacks "piper.yazi"
    done
}
