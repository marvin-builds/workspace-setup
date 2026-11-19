#!/usr/bin/env bats
# shellcheck disable=SC2016 # chezmoi templates and smoke text in single quotes, not shell
# mise's global config and its lockfile (slice 6, criteria 4-6, 15, 21,
# 18 and 24 for the README).
#
# Interface (the implementation follows this):
#
#   home/dot_config/mise/config.toml  -> ~/.config/mise/config.toml
#     [tools] lists exactly node, python, uv, starship and yazi. A key is
#     a short name (node) or a backend-qualified one (aqua:astral-sh/uv);
#     its short name is the part after the last ':' or '/'. A value is a
#     version string, a list (first entry counts) or a table with
#     `version`. node: the Active LTS major (26, or 26.x.y); python 3.14
#     (or 3.14.z); uv, starship, yazi: exact x.y.z. No ubi: or cargo: key.
#
#   The lockfile next to it, as mise names it for the global config:
#   exactly one of home/dot_config/mise/mise.lock or .../config.lock
#   (decided with the test writer: whichever the pinned mise uses). Read
#   as TOML: tools.<config key> is a table or a list of tables, each with
#   `version`, `backend` and platforms."linux-x64" / "linux-arm64" holding
#   a `checksum` (<algorithm>:<hex>); the platform may also be one dotted
#   key, "platforms.linux-x64" (lockfile_version 4, mise 2026.11). For every config tool, an entry whose
#   version is the config version or starts with it plus "." has both
#   Linux platforms with checksums (criterion 21). Backends: core:node,
#   core:python, aqua: or github: for the rest (criterion 4).
#
# TOML is read with the pinned chezmoi (include | fromToml); the checker is
# proven on inline fixtures, so a pass on the real files means something.

load ../helpers/common

MISE_DIR="$REPO_ROOT/home/dot_config/mise"
CONFIG="$MISE_DIR/config.toml"
EXPECT="$REPO_ROOT/tests/expect.yaml"
README="$REPO_ROOT/README.md"
TAB=$(printf '\t')

setup() {
    ws_isolate
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

require_config() {
    [ -f "$CONFIG" ] && return 0
    echo "missing home/dot_config/mise/config.toml" >&2
    return 1
}

# lockfile: prints the one lockfile next to the config; fails otherwise.
lockfile() {
    found=
    for n in mise.lock config.lock; do
        [ ! -f "$MISE_DIR/$n" ] || found="$found $MISE_DIR/$n"
    done
    # shellcheck disable=SC2086 # split on spaces; the paths have none
    set -- $found
    [ "$#" -eq 1 ] && { printf '%s\n' "$1"; return 0; }
    printf 'want exactly one of mise.lock and config.lock in home/dot_config/mise, found %s\n' "$#" >&2
    return 1
}

# config_tools <config.toml>: one line per tool, key<TAB>version.
config_tools() {
    tmpl "{{- range \$k, \$v := (include \"$1\" | fromToml).tools -}}
{{-   \$ver := \"\" -}}
{{-   if kindIs \"string\" \$v }}{{ \$ver = \$v -}}
{{-   else if kindIs \"slice\" \$v }}{{ \$ver = toString (first \$v) -}}
{{-   else if kindIs \"map\" \$v }}{{ \$ver = toString (dig \"version\" \"\" \$v) -}}
{{-   end -}}
{{ \$k }}{{ \"\\t\" }}{{ \$ver }}{{ \"\\n\" }}
{{- end -}}"
}

# lock_entries <lockfile>: one line per entry,
# key<TAB>version<TAB>backend<TAB>linux-x64 checksum<TAB>linux-arm64 checksum.
lock_entries() {
    tmpl "{{- \$l := include \"$1\" | fromToml -}}
{{- range \$k, \$v := (dig \"tools\" dict \$l) -}}
{{-   \$es := list \$v -}}
{{-   if kindIs \"slice\" \$v }}{{ \$es = \$v }}{{ end -}}
{{-   range \$es -}}
{{-     if kindIs \"map\" . -}}
{{ \$k }}{{ \"\\t\" }}{{ dig \"version\" \"\" . }}{{ \"\\t\" }}{{ dig \"backend\" \"\" . }}{{ \"\\t\" }}{{ or (dig \"platforms\" \"linux-x64\" \"checksum\" \"\" .) (dig \"platforms.linux-x64\" \"checksum\" \"\" .) }}{{ \"\\t\" }}{{ or (dig \"platforms\" \"linux-arm64\" \"checksum\" \"\" .) (dig \"platforms.linux-arm64\" \"checksum\" \"\" .) }}{{ \"\\n\" }}
{{-     end -}}
{{-   end -}}
{{- end -}}"
}

# lock_errors <config.toml> <lockfile>: one error per line; nothing when
# every config tool has a matching entry for both Linux platforms.
lock_errors() {
    cfg=$(config_tools "$1") || { echo "cannot read $1 as TOML"; return 0; }
    lk=$(lock_entries "$2") || { echo "cannot read $2 as TOML"; return 0; }
    [ -n "$cfg" ] || { echo "no tools in the config"; return 0; }
    printf '%s\n' "$cfg" | while IFS="$TAB" read -r key ver; do
        [ -n "$key" ] || continue
        entries=$(printf '%s\n' "$lk" | awk -F '\t' -v k="$key" -v v="$ver" \
            '$1 == k && ($2 == v || index($2, v ".") == 1)')
        if [ -z "$entries" ]; then
            echo "$key: no lock entry for version $ver"
            continue
        fi
        printf '%s\n' "$entries" | while IFS="$TAB" read -r _ lver backend x64 arm64; do
            [ -n "$backend" ] || echo "$key $lver: no backend"
            printf '%s\n' "$x64" | grep -qE '^[a-z0-9]+:[0-9a-f]{32,}$' ||
                echo "$key $lver: no checksum for linux-x64"
            printf '%s\n' "$arm64" | grep -qE '^[a-z0-9]+:[0-9a-f]{32,}$' ||
                echo "$key $lver: no checksum for linux-arm64"
        done
    done
}

# short <key>: the tool name without backend and owner.
short() {
    printf '%s\n' "${1##*[:/]}"
}

# version_of <short name>: the config version of that tool.
version_of() {
    config_tools "$CONFIG" | while IFS="$TAB" read -r key ver; do
        [ "$(short "$key")" != "$1" ] || printf '%s\n' "$ver"
    done
}

# ------------------------------------------------------- config (4, 6)

@test "mise config: lists exactly node, python, uv, starship and yazi (criterion 4)" {
    require_config
    run config_tools "$CONFIG"
    expect_status 0
    names=$(printf '%s\n' "$output" | while IFS="$TAB" read -r key _; do
        [ -z "$key" ] || short "$key"
    done | LC_ALL=C sort | tr '\n' ' ')
    expect_equal "tools" "node python starship uv yazi " "$names"
}

@test "mise config: node is the Active LTS major 26, python 3.14 (criterion 4)" {
    require_config
    node=$(version_of node)
    python=$(version_of python)
    printf '%s\n' "$node" | grep -qE '^26(\.[0-9]+){0,2}$' || {
        echo "node is '$node', want 26 or 26.x.y" >&2
        return 1
    }
    printf '%s\n' "$python" | grep -qE '^3\.14(\.[0-9]+)?$' || {
        echo "python is '$python', want 3.14 or 3.14.z" >&2
        return 1
    }
}

@test "mise config: uv, starship and yazi are pinned exactly (criterion 4)" {
    require_config
    for t in uv starship yazi; do
        v=$(version_of "$t")
        printf '%s\n' "$v" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || {
            echo "$t is '$v', want an exact x.y.z" >&2
            return 1
        }
    done
}

@test "mise config: no ubi: or cargo: backend (criterion 4)" {
    require_config
    run config_tools "$CONFIG"
    expect_status 0
    bad=$(printf '%s\n' "$output" | cut -f 1 | grep -E '^(ubi|cargo):' || true)
    expect_equal "ubi: or cargo: keys" "" "$bad"
}

@test "mise config and lockfile: nothing machine-specific (criterion 4)" {
    require_config
    lock=$(lockfile)
    bad=$(grep -nE '(^|[^A-Za-z0-9_])/(home|Users|root)/|[A-Za-z]:\\|~/' "$CONFIG" "$lock" || true)
    expect_equal "machine paths" "" "$bad"
}

# ---------------------------------------------------- lockfile (5, 21)

@test "mise lockfile: exactly one lockfile next to the config (criterion 5)" {
    require_config
    run lockfile
    expect_status 0
}

@test "mise lockfile: every config tool has checksums for linux-x64 and linux-arm64 (criterion 21)" {
    require_config
    lock=$(lockfile)
    run lock_errors "$CONFIG" "$lock"
    expect_status 0
    expect_equal "lockfile errors" "" "$output"
}

@test "mise lockfile: backends are core for node and python, aqua: or github: for the rest (criterion 4)" {
    require_config
    lock=$(lockfile)
    cfg=$(config_tools "$CONFIG")
    lk=$(lock_entries "$lock")
    printf '%s\n' "$cfg" | while IFS="$TAB" read -r key _; do
        [ -n "$key" ] || continue
        backends=$(printf '%s\n' "$lk" | awk -F '\t' -v k="$key" '$1 == k { print $3 }' | LC_ALL=C sort -u)
        [ -n "$backends" ] || { echo "$key: no lock entry" >&2; exit 1; }
        case $(short "$key") in
            node) want='^core:node$' ;;
            python) want='^core:python$' ;;
            *) want='^(aqua|github):' ;;
        esac
        bad=$(printf '%s\n' "$backends" | grep -vE "$want" || true)
        [ -z "$bad" ] || { echo "$key: backend $bad, want /$want/" >&2; exit 1; }
    done
}

# The checker itself, on fixtures.

# hex <char>: 64 times <char>, a fake sha256.
hex() {
    printf '%064d\n' 0 | tr 0 "$1"
}

write_fixture_config() {
    printf '[tools]\nnode = "26"\n"aqua:astral-sh/uv" = "0.9.1"\n' >"$TEST_TMP/config.toml"
}

# lock_fixture <uv arm64 platform line or empty>
lock_fixture() {
    {
        printf '[[tools.node]]\nversion = "26.1.0"\nbackend = "core:node"\n'
        printf '[tools.node.platforms.linux-x64]\nchecksum = "sha256:%s"\n' "$(hex a)"
        printf '[tools.node.platforms.linux-arm64]\nchecksum = "sha256:%s"\n' "$(hex b)"
        printf '[[tools."aqua:astral-sh/uv"]]\nversion = "0.9.1"\nbackend = "aqua:astral-sh/uv"\n'
        printf '[tools."aqua:astral-sh/uv".platforms.linux-x64]\nchecksum = "sha256:%s"\n' "$(hex c)"
        [ -z "$1" ] || printf '%s\n' "$1"
    } >"$TEST_TMP/mise.lock"
}

@test "lock checker: a complete fixture passes (control)" {
    write_fixture_config
    lock_fixture "$(printf '[tools."aqua:astral-sh/uv".platforms.linux-arm64]\nchecksum = "sha256:%s"' "$(hex d)")"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_status 0
    expect_equal "lockfile errors" "" "$output"
}

@test "lock checker: a missing platform is reported" {
    write_fixture_config
    lock_fixture ''
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_output_matches 'aqua:astral-sh/uv 0\.9\.1: no checksum for linux-arm64'
}

@test "lock checker: a tool missing from the lockfile is reported" {
    write_fixture_config
    printf '"aqua:starship/starship" = "1.24.0"\n' >>"$TEST_TMP/config.toml"
    lock_fixture "$(printf '[tools."aqua:astral-sh/uv".platforms.linux-arm64]\nchecksum = "sha256:%s"' "$(hex d)")"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_output_matches 'aqua:starship/starship: no lock entry'
}

@test "lock checker: a bumped config without mise lock is reported" {
    write_fixture_config
    sed -i 's/0\.9\.1/0.9.2/' "$TEST_TMP/config.toml"
    lock_fixture "$(printf '[tools."aqua:astral-sh/uv".platforms.linux-arm64]\nchecksum = "sha256:%s"' "$(hex d)")"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_output_matches 'aqua:astral-sh/uv: no lock entry for version 0\.9\.2'
}

@test "lock checker: the older table form (tools.<name> without a list) is read too" {
    printf '[tools]\nnode = "26"\n' >"$TEST_TMP/config.toml"
    {
        printf '[tools.node]\nversion = "26.1.0"\nbackend = "core:node"\n'
        printf '[tools.node.platforms.linux-x64]\nchecksum = "sha256:%s"\n' "$(hex a)"
    } >"$TEST_TMP/mise.lock"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_output_matches '^node 26\.1\.0: no checksum for linux-arm64$'
}

@test "lock checker: the lockfile_version 4 form (\"platforms.<platform>\" keys) is read" {
    printf '[tools]\nnode = "26"\n' >"$TEST_TMP/config.toml"
    {
        printf 'lockfile_version = 4\n\n[[tools.node]]\nversion = "26.1.0"\nbackend = "core:node"\n'
        printf '[tools.node."platforms.linux-x64"]\nchecksum = "sha256:%s"\n' "$(hex a)"
        printf '[tools.node."platforms.linux-arm64"]\nchecksum = "sha256:%s"\n' "$(hex b)"
    } >"$TEST_TMP/mise.lock"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_status 0
    expect_equal "lockfile errors" "" "$output"
    # Control: without the arm64 key the same form is reported.
    sed -i '/platforms.linux-arm64/,$d' "$TEST_TMP/mise.lock"
    run lock_errors "$TEST_TMP/config.toml" "$TEST_TMP/mise.lock"
    expect_output_matches '^node 26\.1\.0: no checksum for linux-arm64$'
}

# ------------------------------------------- expect.yaml in step (15)

@test "expect.yaml: mise-versions checks the config's node major and python minor (criterion 15)" {
    require_config
    node=$(version_of node)
    python=$(version_of python)
    major=${node%%.*}
    minor=$(printf '%s\n' "$python" | cut -d . -f 1-2)
    smoke=$(tmpl "{{ range (include \"$EXPECT\" | fromYaml).checks }}{{ if eq (toString .id) \"mise-versions\" }}{{ .smoke }}{{ end }}{{ end }}")
    for want in "v$major.*)" "\"Python $minor.\"*)"; do
        printf '%s\n' "$smoke" | grep -qF -- "$want" || {
            echo "mise-versions lacks [$want] for the config's node $node / python $python: $smoke" >&2
            return 1
        }
    done
}

# ----------------------------------------------------- README (18, 24)

@test "README: a Runtimes and tools section on mise, the lockfile and Renovate (criteria 18, 24)" {
    [ -f "$README" ] || { echo "missing README.md" >&2; return 1; }
    grep -qE '^#+ Runtimes and tools' "$README" || {
        echo "README.md has no 'Runtimes and tools' heading" >&2
        return 1
    }
    section=$(awk '/^#+ Runtimes and tools/ { s = 1; print; next } s && /^## / { s = 0 } s' "$README")
    for want in 'mise lock' 'mise.toml' 'Renovate'; do
        printf '%s\n' "$section" | grep -qF -- "$want" || {
            echo "the Runtimes and tools section does not mention: $want" >&2
            return 1
        }
    done
    # Criterion 18: the Renovate GitHub app is installed by hand.
    printf '%s\n' "$section" | grep -qiE 'Renovate[^.]*app|app[^.]*Renovate' || {
        echo "the Runtimes and tools section does not say the Renovate app is installed by hand" >&2
        return 1
    }
    grep -qF 'sudo apt upgrade' "$README" || {
        echo "README.md does not say apt packages update with sudo apt upgrade" >&2
        return 1
    }
}
