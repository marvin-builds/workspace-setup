#!/usr/bin/env bats
# shellcheck disable=SC2016 # chezmoi templates in single quotes, not shell
# The chezmoi externals file (slice 7, criteria 8 and 16). Nothing here
# reaches the network: ws_block_network makes every download fail, and the
# extraction test serves a fixture archive from chezmoi's own cache.
#
# Interface (the implementation follows this):
#
#   Exactly one of home/.chezmoiexternal.toml or .chezmoiexternal.toml.tmpl
#   (a .tmpl is rendered with a Linux test profile before it is read).
#   It has exactly one entry whose url is a yazi-rs/plugins archive:
#     url   https://github.com/yazi-rs/plugins/archive/<40 hex>.tar.gz
#     type  archive
#     no refreshPeriod (the URL is immutable)
#   Applied on its own from an archive laid out like GitHub's
#   (plugins-<commit>/<plugin>.yazi/..., README.md, LICENSE at the top),
#   it creates exactly ~/.config/yazi/plugins/piper.yazi/ with that
#   plugin's files and nothing else (no other plugin, no top-level file).
#
# chezmoi 2.73.1 keeps a downloaded archive in <cache>/external/<sha256 of
# the url> and with --refresh-externals=never reads it from there; the
# extraction test seeds that file (checked with the pinned chezmoi). If a
# chezmoi bump changes this, the test fails with "connection refused"
# instead of downloading.

load ../helpers/common

PLUGINS_URL_RE='^https://github\.com/yazi-rs/plugins/archive/[0-9a-f]{40}\.tar\.gz$'

setup() {
    ws_isolate
    ws_block_network
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    EMPTY_SRC="$TEST_TMP/empty-source"
    mkdir -p "$EMPTY_SRC"
}

# tmpl <template>: chezmoi execute-template on an empty source.
tmpl() {
    "$CHEZMOI" --no-tty --source "$EMPTY_SRC" --config "$TEST_TMP/none.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template "$1"
}

# externals_file: prints the one externals file in home/; fails otherwise.
externals_file() {
    found=
    for n in .chezmoiexternal.toml .chezmoiexternal.toml.tmpl; do
        [ ! -f "$REPO_ROOT/home/$n" ] || found="$found $REPO_ROOT/home/$n"
    done
    # shellcheck disable=SC2086 # split on spaces; the paths have none
    set -- $found
    [ "$#" -eq 1 ] && { printf '%s\n' "$1"; return 0; }
    printf 'want exactly one of home/.chezmoiexternal.toml and .toml.tmpl, found %s\n' "$#" >&2
    return 1
}

# externals_toml: the externals file as chezmoi reads it on Linux, to
# $TEST_TMP/externals.toml.
externals_toml() {
    f=$(externals_file) || return 1
    case $f in
        *.tmpl)
            "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --destination "$HOME" \
                --config "$PROFILES_DIR/personal-desktop.toml" \
                --cache "$TEST_TMP/chezmoi-cache" \
                --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
                execute-template --file "$f" >"$TEST_TMP/externals.toml" || {
                echo "$f does not render" >&2
                return 1
            }
            ;;
        *) cp "$f" "$TEST_TMP/externals.toml" ;;
    esac
}

# plugin_entries: one line per entry with a yazi-rs/plugins url:
# target<TAB>type<TAB>url<TAB>has refreshPeriod.
plugin_entries() {
    tmpl "{{- range \$k, \$e := (include \"$TEST_TMP/externals.toml\" | fromToml) -}}
{{-   if and (kindIs \"map\" \$e) (contains \"yazi-rs/plugins\" (toString (dig \"url\" \"\" \$e))) -}}
{{ \$k }}{{ \"\\t\" }}{{ dig \"type\" \"\" \$e }}{{ \"\\t\" }}{{ dig \"url\" \"\" \$e }}{{ \"\\t\" }}{{ hasKey \$e \"refreshPeriod\" }}{{ \"\\n\" }}
{{-   end -}}
{{- end -}}"
}

# plugin_entry: the one plugin entry line; fails unless there is exactly one.
plugin_entry() {
    externals_toml || return 1
    entries=$(plugin_entries) || { echo "cannot read the externals file as TOML" >&2; return 1; }
    n=$(printf '%s\n' "$entries" | grep -c . || true)
    [ "$n" -eq 1 ] || {
        printf 'want exactly one yazi-rs/plugins external, found %s:\n%s\n' "$n" "$entries" >&2
        return 1
    }
    printf '%s\n' "$entries"
}

@test "externals: exactly one externals file in home/ (criterion 8)" {
    run externals_file
    expect_status 0
}

@test "externals: one archive external for yazi-rs/plugins, pinned to a full commit (criteria 8, 16)" {
    entry=$(plugin_entry)
    type=$(printf '%s\n' "$entry" | cut -f 2)
    url=$(printf '%s\n' "$entry" | cut -f 3)
    expect_equal "type" archive "$type"
    printf '%s\n' "$url" | grep -qE "$PLUGINS_URL_RE" || {
        echo "url '$url' does not pin a full 40-character commit (want $PLUGINS_URL_RE)" >&2
        return 1
    }
}

@test "externals: the plugin external has no refreshPeriod (criteria 8, 16)" {
    entry=$(plugin_entry)
    expect_equal "refreshPeriod set" false "$(printf '%s\n' "$entry" | cut -f 4)"
}

# fixture_archive <commit> <file>: a tar.gz laid out like GitHub's archive
# of yazi-rs/plugins at that commit.
fixture_archive() {
    top="$TEST_TMP/archive/plugins-$1"
    mkdir -p "$top/piper.yazi" "$top/git.yazi" "$top/full-border.yazi"
    printf -- '-- fixture piper\nreturn {}\n' >"$top/piper.yazi/main.lua"
    printf '# piper (fixture)\n' >"$top/piper.yazi/README.md"
    printf -- '-- fixture git\nreturn {}\n' >"$top/git.yazi/main.lua"
    printf -- '-- fixture full-border\nreturn {}\n' >"$top/full-border.yazi/main.lua"
    printf '# plugins (fixture)\n' >"$top/README.md"
    printf 'MIT (fixture)\n' >"$top/LICENSE"
    tar -C "$TEST_TMP/archive" -czf "$2" "plugins-$1"
}

@test "externals: only piper.yazi is extracted, to ~/.config/yazi/plugins/piper.yazi (criteria 8, 16)" {
    entry=$(plugin_entry)
    key=$(printf '%s\n' "$entry" | cut -f 1)
    url=$(printf '%s\n' "$entry" | cut -f 3)
    commit=$(printf '%s\n' "$url" | sed -E 's|.*/archive/([0-9a-f]+)\.tar\.gz$|\1|')
    # A source with only this external, so nothing else needs a download.
    src="$TEST_TMP/xsrc"
    dest="$TEST_TMP/xdest"
    cache="$TEST_TMP/xcache"
    mkdir -p "$src" "$dest" "$cache/external"
    tmpl "{{ dict \"$key\" (index (include \"$TEST_TMP/externals.toml\" | fromToml) \"$key\") | toToml }}" \
        >"$src/.chezmoiexternal.toml"
    sum=$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1)
    fixture_archive "$commit" "$cache/external/$sum"
    : >"$TEST_TMP/x.toml"
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$src" --destination "$dest" --config "$TEST_TMP/x.toml" \
        --cache "$cache" --persistent-state "$TEST_TMP/x.boltdb" \
        apply --force --refresh-externals=never
    expect_status 0
    files=$(cd "$dest" && find . -type f | LC_ALL=C sort | tr '\n' ' ')
    expect_equal "files applied" "./.config/yazi/plugins/piper.yazi/README.md ./.config/yazi/plugins/piper.yazi/main.lua " "$files"
    cmp -s "$TEST_TMP/archive/plugins-$commit/piper.yazi/main.lua" \
        "$dest/.config/yazi/plugins/piper.yazi/main.lua" || {
        echo "piper.yazi/main.lua differs from the archive's" >&2
        return 1
    }
}

@test "externals: the seeded-cache fixture is what chezmoi reads (control)" {
    # Proves the cache layout the extraction test relies on: a minimal
    # external served from a seeded cache, without network.
    url='https://example.invalid/archive/0123456789abcdef0123456789abcdef01234567.tar.gz'
    src="$TEST_TMP/csrc"
    dest="$TEST_TMP/cdest"
    cache="$TEST_TMP/ccache"
    mkdir -p "$src" "$dest" "$cache/external"
    printf '[".config/yazi/plugins/piper.yazi"]\n    type = "archive"\n    url = "%s"\n    stripComponents = 2\n    include = ["*/piper.yazi/**"]\n' \
        "$url" >"$src/.chezmoiexternal.toml"
    fixture_archive 0123456789abcdef0123456789abcdef01234567 \
        "$cache/external/$(printf '%s' "$url" | sha256sum | cut -d ' ' -f 1)"
    : >"$TEST_TMP/c.toml"
    run "$CHEZMOI" --no-tty --no-pager --color false --progress false \
        --source "$src" --destination "$dest" --config "$TEST_TMP/c.toml" \
        --cache "$cache" --persistent-state "$TEST_TMP/c.boltdb" \
        apply --force --refresh-externals=never
    expect_status 0
    [ -f "$dest/.config/yazi/plugins/piper.yazi/main.lua" ] || {
        echo "the fixture external was not applied from the cache" >&2
        return 1
    }
    [ ! -e "$dest/.config/yazi/plugins/git.yazi" ] || {
        echo "the control external extracted another plugin" >&2
        return 1
    }
}
