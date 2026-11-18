#!/usr/bin/env bats
# shellcheck disable=SC2016 # chezmoi templates in single quotes, not shell
# home/.chezmoidata/packages.yaml (slice 5, criteria 1-6):
#
#   - the JSON Schema tests/schema/packages.schema.json is valid 2020-12 and
#     the real file passes it (criteria 4, 5);
#   - every negative fixture in tests/schema/fixtures/invalid-*.yaml fails
#     it, every valid-*.yaml and xref-*.yaml passes (criterion 5);
#   - what the schema can't check: every apt_repo names an apt_repos entry
#     and every apt_repos entry is used (criterion 6), proven on the
#     xref-*.yaml fixtures;
#   - the first entries and their repos (criteria 2, 3).
#
# Validator: jv (santhosh-tekuri/jsonschema, cmd/jv), pinned in
# scripts/tools.lock and fetched into .cache/bin by scripts/fetch-tools.sh
# like the other tools. Usage: jv <schema> <instance...>; a .yaml/.yml
# instance is read as YAML. Exit 0 when the schema compiles and every
# instance is valid, 1 otherwise; the output has "schema <path>: ok|failed"
# and "instance <path>: ok|failed" lines.
#
# YAML is read with the pinned chezmoi (include | fromYaml), as in
# expect-yaml.bats.

load ../helpers/common

PACKAGES="$REPO_ROOT/home/.chezmoidata/packages.yaml"
SCHEMA="$REPO_ROOT/tests/schema/packages.schema.json"
FIXTURES="$REPO_ROOT/tests/schema/fixtures"

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

# jv <args...>: the pinned validator.
jv() {
    require_tool jv || return 1
    "$(tool_path jv)" "$@"
}

require_packages() {
    [ -f "$PACKAGES" ] && return 0
    echo "missing home/.chezmoidata/packages.yaml" >&2
    return 1
}

# ---------------------------------------------------------------- schema

@test "schema: tests/schema/packages.schema.json declares JSON Schema 2020-12" {
    [ -f "$SCHEMA" ] || { echo "missing $SCHEMA" >&2; return 1; }
    run tmpl "{{ index (include \"$SCHEMA\" | fromJson) \"\$schema\" }}"
    expect_status 0
    expect_equal '$schema' 'https://json-schema.org/draft/2020-12/schema' "$output"
}

@test "schema: the real packages.yaml is valid" {
    require_packages
    run jv "$SCHEMA" "$PACKAGES"
    expect_status 0
    expect_output_matches '^instance .*packages\.yaml: ok$'
}

@test "schema: valid and cross-reference fixtures pass (control)" {
    set -- "$FIXTURES"/valid-*.yaml "$FIXTURES"/xref-*.yaml
    [ "$#" -ge 4 ] || { echo "expected at least 4 valid/xref fixtures, found $#" >&2; return 1; }
    run jv "$SCHEMA" "$@"
    expect_status 0
    expect_output_lacks ': failed'
}

# t_invalid <fixture>: the schema compiles and the fixture fails it.
t_invalid() {
    run jv "$SCHEMA" "$1"
    expect_status 1
    expect_output_matches '^schema .*: ok$'
    expect_output_matches "^instance .*$(basename "$1"): failed$"
}

for f in "$BATS_TEST_DIRNAME"/../schema/fixtures/invalid-*.yaml; do
    [ -f "$f" ] || continue
    n=$(basename "$f" .yaml)
    bats_test_function --description "schema: rejects fixture $n" -- t_invalid "$f"
done

@test "schema: has a negative fixture for each required case" {
    for n in missing-column fingerprint-lowercase fingerprint-short \
        fingerprint-spaces http-uri http-key-url unknown-package-key \
        unknown-repo-key unknown-top-key empty-id apt-repo-without-apt \
        fingerprints-empty fingerprints-duplicate fingerprints-not-list \
        fingerprints-one-bad fingerprint-singular key-sha256-missing \
        key-sha256-upper key-sha256-short key-missing key-unknown-field \
        key-flat; do
        [ -f "$FIXTURES/invalid-$n.yaml" ] || { echo "missing fixture invalid-$n.yaml" >&2; return 1; }
    done
}

# ------------------------------------------ cross references (criterion 6)

# The check: one error per line, or "ok".
XREF='
{{- $d := include "@PATH@" | fromYaml -}}
{{- $errs := list -}}
{{- $used := dict -}}
{{- range $name, $p := $d.packages -}}
{{-   if hasKey $p "apt_repo" -}}
{{-     $r := toString $p.apt_repo -}}
{{-     $_ := set $used $r true -}}
{{-     if not (hasKey $d.apt_repos $r) -}}
{{-       $errs = append $errs (printf "package %s: apt_repo %s is not in apt_repos" $name $r) -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- range $r, $_ := $d.apt_repos -}}
{{-   if not (hasKey $used $r) -}}
{{-     $errs = append $errs (printf "apt_repos %s is used by no package" $r) -}}
{{-   end -}}
{{- end -}}
{{- if $errs }}{{ join "\n" $errs }}{{ else }}ok{{ end -}}
'

# xref <yaml file>
xref() {
    tmpl "$(printf '%s' "$XREF" | sed "s|@PATH@|$1|")"
}

@test "xref: every apt_repo exists and every apt_repos entry is used" {
    require_packages
    run xref "$PACKAGES"
    expect_status 0
    expect_equal "cross references" ok "$output"
}

@test "xref: a dangling apt_repo is reported (fixture)" {
    run xref "$FIXTURES/xref-dangling.yaml"
    expect_status 0
    expect_output_matches 'apt_repo missing-repo is not in apt_repos'
}

@test "xref: an unused apt_repos entry is reported (fixture)" {
    run xref "$FIXTURES/xref-unused.yaml"
    expect_status 0
    expect_output_matches 'apt_repos unused-repo is used by no package'
}

@test "xref: valid fixtures pass (control)" {
    for f in "$FIXTURES"/valid-*.yaml; do
        run xref "$f"
        expect_status 0
        expect_equal "cross references of $(basename "$f")" ok "$output"
    done
}

# ---------------------------------------------- first entries (2, 3)

# entry <logical name>: apt|flatpak|apt_repo or -|roles?|forms?|columns
entry() {
    tmpl "{{ \$p := index (include \"$PACKAGES\" | fromYaml).packages \"$1\" }}{{ toJson \$p.apt }}|{{ toJson \$p.flatpak }}|{{ if hasKey \$p \"apt_repo\" }}{{ \$p.apt_repo }}{{ else }}-{{ end }}|{{ hasKey \$p \"roles\" }}|{{ hasKey \$p \"forms\" }}|{{ and (hasKey \$p \"apt\") (hasKey \$p \"flatpak\") (hasKey \$p \"winget\") (hasKey \$p \"scoop\") (hasKey \$p \"brew\") }}"
}

@test "packages.yaml: first entries, no filters, flatpak null (criterion 2)" {
    require_packages
    for want in \
        'git|"git"|null|-|false|false|true' \
        'gh|"gh"|null|github-cli|false|false|true' \
        'ripgrep|"ripgrep"|null|-|false|false|true' \
        'fzf|"fzf"|null|-|false|false|true' \
        'glow|"glow"|null|charm|false|false|true' \
        'file|"file"|null|-|false|false|true'; do
        name=${want%%|*}
        run entry "$name"
        expect_status 0
        expect_equal "packages.$name (apt|flatpak|apt_repo|roles|forms|all columns)" "${want#*|}" "$output"
    done
}

# repo <name>: key.url|key.fingerprints (sorted, space-separated)|uris|suites|components|key.sha256
repo() {
    tmpl "{{ \$r := index (include \"$PACKAGES\" | fromYaml).apt_repos \"$1\" }}{{ \$r.key.url }}|{{ join \" \" (sortAlpha \$r.key.fingerprints) }}|{{ join \" \" \$r.uris }}|{{ join \" \" \$r.suites }}|{{ join \" \" \$r.components }}|{{ \$r.key.sha256 }}"
}

@test "packages.yaml: apt_repos holds github-cli and charm" {
    require_packages
    run tmpl "{{ range \$k, \$_ := (include \"$PACKAGES\" | fromYaml).apt_repos }}{{ \$k }} {{ end }}"
    expect_status 0
    expect_equal "apt_repos names" "charm github-cli " "$output"
}

@test "packages.yaml: github-cli repo as in GitHub CLI's install_linux.md (criterion 3)" {
    require_packages
    run repo github-cli
    expect_status 0
    # GitHub lists both primary keys at the top of docs/install_linux.md;
    # every primary key is pinned (decision 32).
    expect_output_matches '^https://cli\.github\.com/packages/githubcli-archive-keyring\.(gpg|asc)\|2C6106201985B60E6C7AC87323F3D4EA75716059 7F38BBB59D064DBCB3D84D725612B36462313325\|https://cli\.github\.com/packages\|stable\|main\|[0-9a-f]{64}$'
}

@test "packages.yaml: charm repo as in Charm's README (criterion 3)" {
    require_packages
    run repo charm
    expect_status 0
    # Charm publishes no fingerprint; decision 33 records how it was read.
    expect_output_matches '^https://repo\.charm\.sh/apt/gpg\.key\|ED927B38BE981E53CA09153D03BBF595D4DFD35C\|https://repo\.charm\.sh/apt/\|\*\|\*\|[0-9a-f]{64}$'
}
