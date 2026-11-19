#!/usr/bin/env bats
# shellcheck disable=SC2016 # chezmoi templates in single quotes, not shell
# renovate.json at the repo root (slice 6, criterion 16). The JSON is read
# with the pinned chezmoi (include | fromJson). Whether Renovate itself
# accepts the file is checked in CI with the pinned
# renovate-config-validator (criterion 17, tests/unit/ci-workflow.bats),
# since the tests have no node runtime.
#
# Which updates need approval on the Dependency Dashboard is evaluated
# from the config as Renovate would apply it (decided with the test
# writer, a subset of Renovate's semantics): start from the top-level
# dependencyDashboardApproval, then the top-level major/minor/patch
# objects, then every packageRule in order. A rule applies to a dependency
# when it has no matchDepNames/matchPackageNames or names it in one of
# them, and to an update type when it has no matchUpdateTypes or lists
# it; an applying rule with dependencyDashboardApproval sets it. Other
# match fields are not evaluated, so rules for node and python name them
# with matchDepNames or matchPackageNames ("node", "python").

load ../helpers/common

RENOVATE="$REPO_ROOT/renovate.json"

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

require_renovate() {
    [ -f "$RENOVATE" ] && return 0
    echo "missing renovate.json at the repo root" >&2
    return 1
}

# approvals <renovate.json>: "<dep> <type> gated|open" for node and python
# and major, minor, patch, one per line.
APPROVALS='
{{- $c := include "@PATH@" | fromJson -}}
{{- range $dep := list "node" "python" -}}
{{-   range $t := list "major" "minor" "patch" -}}
{{-     $g := false -}}
{{-     if hasKey $c "dependencyDashboardApproval" }}{{ $g = get $c "dependencyDashboardApproval" }}{{ end -}}
{{-     $o := dig $t dict $c -}}
{{-     if and (kindIs "map" $o) (hasKey $o "dependencyDashboardApproval") }}{{ $g = get $o "dependencyDashboardApproval" }}{{ end -}}
{{-     range (dig "packageRules" list $c) -}}
{{-       $names := concat (dig "matchDepNames" list .) (dig "matchPackageNames" list .) -}}
{{-       $types := dig "matchUpdateTypes" list . -}}
{{-       if and (or (empty $names) (has $dep $names)) (or (empty $types) (has $t $types)) (hasKey . "dependencyDashboardApproval") -}}
{{-         $g = get . "dependencyDashboardApproval" -}}
{{-       end -}}
{{-     end -}}
{{ $dep }} {{ $t }} {{ if $g }}gated{{ else }}open{{ end }}{{ "\n" }}
{{-   end -}}
{{- end -}}
'

approvals() {
    tmpl "$(printf '%s' "$APPROVALS" | sed "s|@PATH@|$1|")"
}

# separation <renovate.json>: "<dep> separate|grouped" for node and python:
# the effective separateMinorPatch (default false), from the top level,
# then every packageRule in order that applies to the dep. Renovate decides
# the update type after this option, so a rule with matchUpdateTypes does
# not count.
SEPARATION='
{{- $c := include "@PATH@" | fromJson -}}
{{- range $dep := list "node" "python" -}}
{{-   $s := false -}}
{{-   if hasKey $c "separateMinorPatch" }}{{ $s = get $c "separateMinorPatch" }}{{ end -}}
{{-   range (dig "packageRules" list $c) -}}
{{-     $names := concat (dig "matchDepNames" list .) (dig "matchPackageNames" list .) -}}
{{-     if and (or (empty $names) (has $dep $names)) (empty (dig "matchUpdateTypes" list .)) (hasKey . "separateMinorPatch") -}}
{{-       $s = get . "separateMinorPatch" -}}
{{-     end -}}
{{-   end -}}
{{ $dep }} {{ if $s }}separate{{ else }}grouped{{ end }}{{ "\n" }}
{{- end -}}
'

separation() {
    tmpl "$(printf '%s' "$SEPARATION" | sed "s|@PATH@|$1|")"
}

# patch_errors <renovate.json>: one line per dep whose minors need approval
# and whose patches must not, but whose patches Renovate groups with the
# minors (separateMinorPatch false: the bucket proposes the highest
# version, a gated minor, so a patch never gets its own PR). Empty if none.
patch_errors() {
    a=$(approvals "$1") || { echo "cannot evaluate approvals"; return 0; }
    s=$(separation "$1") || { echo "cannot evaluate separateMinorPatch"; return 0; }
    for dep in node python; do
        printf '%s\n' "$a" | grep -qx "$dep minor gated" || continue
        printf '%s\n' "$a" | grep -qx "$dep patch open" || continue
        printf '%s\n' "$s" | grep -qx "$dep separate" ||
            echo "$dep: patches are grouped with gated minors; set separateMinorPatch: true for $dep"
    done
}

WANT_APPROVALS='node major gated
node minor open
node patch open
python major gated
python minor gated
python patch open'

# ----------------------------------------------------------- the file

@test "renovate.json: exists and is JSON" {
    require_renovate
    run tmpl "{{ include \"$RENOVATE\" | fromJson | kindOf }}"
    expect_status 0
    expect_equal "top level" map "$output"
}

@test "renovate.json: the mise manager is on and the Dependency Dashboard is not off" {
    require_renovate
    run tmpl "{{ \$c := include \"$RENOVATE\" | fromJson }}{{ if hasKey \$c \"enabledManagers\" }}{{ has \"mise\" \$c.enabledManagers }}{{ else }}true{{ end }}|{{ dig \"mise\" \"enabled\" true \$c }}|{{ dig \"dependencyDashboard\" true \$c }}"
    expect_status 0
    expect_equal "mise in enabledManagers|mise.enabled|dependencyDashboard" "true|true|true" "$output"
}

@test "renovate.json: custom mise file patterns, if any, include the global config" {
    require_renovate
    run tmpl "{{ \$c := include \"$RENOVATE\" | fromJson }}{{ \$p := concat (dig \"mise\" \"managerFilePatterns\" list \$c) (dig \"mise\" \"fileMatch\" list \$c) }}{{ if empty \$p }}defaults{{ else }}{{ join \"\\n\" \$p }}{{ end }}"
    expect_status 0
    [ "$output" = defaults ] && return 0
    printf '%s\n' "$output" | grep -qE 'dot_config.*mise.*config' || {
        printf 'mise file patterns do not name home/dot_config/mise/config.toml:\n%s\n' "$output" >&2
        return 1
    }
}

@test "renovate.json: lockFileMaintenance is enabled" {
    require_renovate
    run tmpl "{{ dig \"lockFileMaintenance\" \"enabled\" false (include \"$RENOVATE\" | fromJson) }}"
    expect_status 0
    expect_equal "lockFileMaintenance.enabled" true "$output"
}

@test "renovate.json: node majors and python minors and majors need approval, the rest not" {
    require_renovate
    run approvals "$RENOVATE"
    expect_status 0
    expect_equal "approvals" "$WANT_APPROVALS" "$output"
}

@test "renovate.json: python patches get their own PRs, not grouped with gated minors (review C1)" {
    require_renovate
    run patch_errors "$RENOVATE"
    expect_status 0
    expect_equal "minor/patch grouping errors" "" "$output"
}

# ------------------------------------------------- the evaluator itself

# fixture <json>: writes it and evaluates the approvals.
fixture() {
    printf '%s\n' "$1" >"$TEST_TMP/renovate.json"
    run approvals "$TEST_TMP/renovate.json"
    expect_status 0
}

@test "approvals: rules as the brief wants them pass (control)" {
    fixture '{"packageRules": [
      {"matchManagers": ["mise"], "matchDepNames": ["node"], "matchUpdateTypes": ["major"], "dependencyDashboardApproval": true},
      {"matchManagers": ["mise"], "matchDepNames": ["python"], "matchUpdateTypes": ["minor", "major"], "dependencyDashboardApproval": true}
    ]}'
    expect_equal "approvals" "$WANT_APPROVALS" "$output"
}

@test "approvals: a global approval gates everything" {
    fixture '{"dependencyDashboardApproval": true}'
    expect_output_matches '^node patch gated$'
    expect_output_matches '^python patch gated$'
}

@test "approvals: a top-level major object gates majors of every dependency" {
    fixture '{"major": {"dependencyDashboardApproval": true}}'
    expect_output_matches '^node major gated$'
    expect_output_matches '^python major gated$'
    expect_output_matches '^python minor open$'
}

@test "approvals: a rule without update types gates every type of its dependency" {
    fixture '{"packageRules": [{"matchPackageNames": ["node"], "dependencyDashboardApproval": true}]}'
    expect_output_matches '^node minor gated$'
    expect_output_matches '^python minor open$'
}

@test "approvals: a later rule overrides an earlier one" {
    fixture '{"packageRules": [
      {"matchUpdateTypes": ["major", "minor"], "dependencyDashboardApproval": true},
      {"matchDepNames": ["node"], "matchUpdateTypes": ["minor"], "dependencyDashboardApproval": false}
    ]}'
    expect_output_matches '^node minor open$'
    expect_output_matches '^python minor gated$'
}

# grouping <json>: writes it and runs patch_errors.
grouping() {
    printf '%s\n' "$1" >"$TEST_TMP/renovate.json"
    run patch_errors "$TEST_TMP/renovate.json"
    expect_status 0
}

PYTHON_GATE='{"matchDepNames": ["python"], "matchUpdateTypes": ["minor", "major"], "dependencyDashboardApproval": true}'

@test "grouping: python minors gated without separateMinorPatch are reported" {
    grouping "{\"packageRules\": [$PYTHON_GATE]}"
    expect_output_matches '^python: patches are grouped with gated minors'
}

@test "grouping: separateMinorPatch in a rule for python passes (control)" {
    grouping "{\"packageRules\": [{\"matchDepNames\": [\"python\"], \"separateMinorPatch\": true}, $PYTHON_GATE]}"
    expect_equal "grouping errors" "" "$output"
}

@test "grouping: a top-level separateMinorPatch passes (control)" {
    grouping "{\"separateMinorPatch\": true, \"packageRules\": [$PYTHON_GATE]}"
    expect_equal "grouping errors" "" "$output"
}

@test "grouping: separateMinorPatch in a rule with matchUpdateTypes does not count" {
    grouping "{\"packageRules\": [$PYTHON_GATE, {\"matchDepNames\": [\"python\"], \"matchUpdateTypes\": [\"patch\"], \"separateMinorPatch\": true}]}"
    expect_output_matches '^python: patches are grouped'
}

@test "grouping: a later rule turning separateMinorPatch off is reported" {
    grouping "{\"separateMinorPatch\": true, \"packageRules\": [$PYTHON_GATE, {\"matchDepNames\": [\"python\"], \"separateMinorPatch\": false}]}"
    expect_output_matches '^python: patches are grouped'
}

@test "grouping: node, with open minors, needs no separation (control)" {
    grouping '{"packageRules": [{"matchDepNames": ["node"], "matchUpdateTypes": ["major"], "dependencyDashboardApproval": true}]}'
    expect_equal "grouping errors" "" "$output"
}

# ======================================================================
# Slice 7 (criteria 10, 11): more managers and the pins they bump.
#
# Interface (the implementation follows this):
#
#   enabledManagers holds at least mise, github-actions and custom.regex.
#   customManagers: regex managers (customType "regex"). A manager applies
#   to a file when one of its managerFilePatterns (a "/regex/" or a glob)
#   or fileMatch regexes matches the file's path from the repo root. Each
#   of its matchStrings is applied to the whole file, every match counts
#   (Renovate's default matchStringsStrategy "any"). A field comes from
#   the named group of the same name, else from <field>Template (taken
#   literally: no handlebars). packageName falls back to depName.
#   The regexes are evaluated with Go's RE2 (chezmoi's regexFindAll),
#   close to the RE2 engine Renovate uses; named groups as (?<name>...).
#
#   - The externals file (home/.chezmoiexternal.toml or .toml.tmpl): a
#     match with datasource git-refs, currentValue main, currentDigest the
#     commit in the yazi-rs/plugins url, packageName
#     https://github.com/yazi-rs/plugins (optionally with .git).
#   - .github/workflows/ci.yml: a match with datasource npm, packageName
#     renovate and currentValue the version in "renovate@<v>", and one with
#     datasource node-version (or its old name node), packageName node and
#     currentValue the version in "node@<v>".
#   - The validator's node stays within major 24 (decided with the test
#     writer): a packageRule that names node (matchDepNames or
#     matchPackageNames), is kept off mise's node (matchManagers without
#     "mise", or matchFileNames naming .github/workflows/ci.yml) and sets
#     allowedVersions to one of: <25, <25.0.0, 24.x, ^24, ~24, or a
#     /^24.../ or /^v?24.../ regex.
#   - slice 6's three packageRules (all fields but description) stay, in
#     their order.
#   - Every `uses:` in .github/workflows/ is <action>@<40 hex> # vX[.Y[.Z]]
#     (local ./ and docker:// actions excepted).

TAB=$(printf '\t')

# managers_for <renovate.json> <path from the repo root>: the index of
# every regex manager whose file patterns match the path, one per line.
MANAGERS_FOR='
{{- $c := include "@PATH@" | fromJson -}}
{{- range $i, $m := (dig "customManagers" list $c) -}}
{{-   if eq (toString (dig "customType" "" $m)) "regex" -}}
{{-     range $p := (dig "managerFilePatterns" list $m) -}}
{{-       if regexMatch "^/.*/[a-z]*$" $p -}}
{{-         if regexMatch (regexReplaceAll "^/(.*)/[a-z]*$" $p "${1}") "@FILE@" }}R{{ $i }}{{ "\n" }}{{ end -}}
{{-       else -}}
G{{ $i }}{{ "\t" }}{{ $p }}{{ "\n" }}
{{-       end -}}
{{-     end -}}
{{-     range $p := (dig "fileMatch" list $m) -}}
{{-       if regexMatch $p "@FILE@" }}R{{ $i }}{{ "\n" }}{{ end -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
'

managers_for() {
    out=$(tmpl "$(printf '%s' "$MANAGERS_FOR" | sed -e "s|@PATH@|$1|" -e "s|@FILE@|$2|")") || return 1
    printf '%s\n' "$out" | while IFS="$TAB" read -r tag glob; do
        case $tag in
            R*) printf '%s\n' "${tag#R}" ;;
            G*)
                # shellcheck disable=SC2254 # a glob from the config
                case $2 in $glob) printf '%s\n' "${tag#G}" ;; esac
                ;;
        esac
    done | LC_ALL=C sort -u
}

# captures <renovate.json> <manager index> <file>: one line per match of
# any of the manager's matchStrings in the file:
# depName<TAB>packageName<TAB>datasource<TAB>currentValue<TAB>currentDigest.
CAPTURES='
{{- $c := include "@PATH@" | fromJson -}}
{{- $m := index (dig "customManagers" list $c) @IDX@ -}}
{{- $text := include "@CONTENT@" -}}
{{- range $s := (dig "matchStrings" list $m) -}}
{{-   range $hit := regexFindAll $s $text -1 -}}
{{-     $out := list -}}
{{-     range $f := list "depName" "packageName" "datasource" "currentValue" "currentDigest" -}}
{{-       $v := regexReplaceAll $s $hit (printf "${%s}" $f) -}}
{{-       if eq $v "" }}{{ $v = toString (dig (printf "%sTemplate" $f) "" $m) }}{{ end -}}
{{-       $out = append $out $v -}}
{{-     end -}}
{{-     if eq (index $out 1) "" }}{{ $out = list (index $out 0) (index $out 0) (index $out 2) (index $out 3) (index $out 4) }}{{ end -}}
{{ join "\t" $out }}{{ "\n" }}
{{-   end -}}
{{- end -}}
'

captures() {
    tmpl "$(printf '%s' "$CAPTURES" | sed -e "s|@PATH@|$1|" -e "s|@IDX@|$2|" -e "s|@CONTENT@|$3|")"
}

# all_captures <renovate.json> <repo root> <path from the root>: the
# captures of every regex manager that applies to the file.
all_captures() {
    idx=$(managers_for "$1" "$3") || { echo "cannot evaluate the file patterns" >&2; return 1; }
    for i in $idx; do
        captures "$1" "$i" "$2/$3" || { echo "manager $i: cannot apply its matchStrings" >&2; return 1; }
    done
}

# externals_path: the externals file's path from the repo root.
externals_path() {
    for n in home/.chezmoiexternal.toml home/.chezmoiexternal.toml.tmpl; do
        [ ! -f "$REPO_ROOT/$n" ] || { printf '%s\n' "$n"; return 0; }
    done
    echo "no home/.chezmoiexternal.toml(.tmpl)" >&2
    return 1
}

# expect_capture <label> <captures> <ERE for a whole line>
expect_capture() {
    printf '%s\n' "$2" | grep -qE -- "$3" && return 0
    printf '%s: no capture matches /%s/; captures (depName packageName datasource currentValue currentDigest):\n%s\n' \
        "$1" "$3" "$2" >&2
    return 1
}

@test "renovate.json: enabledManagers holds mise, github-actions and custom.regex (slice 7, criterion 10)" {
    require_renovate
    run tmpl "{{ range (dig \"enabledManagers\" list (include \"$RENOVATE\" | fromJson)) }}{{ . }}{{ \"\\n\" }}{{ end }}"
    expect_status 0
    for m in mise github-actions custom.regex; do
        printf '%s\n' "$output" | grep -qxF "$m" || {
            printf 'enabledManagers lacks %s:\n%s\n' "$m" "$output" >&2
            return 1
        }
    done
}

@test "renovate.json: a regex manager bumps the yazi plugin commit with git-refs on main (slice 7, criteria 10, 11)" {
    require_renovate
    ext=$(externals_path)
    commit=$(grep -oE 'yazi-rs/plugins/archive/[0-9a-f]{40}\.tar\.gz' "$REPO_ROOT/$ext" |
        head -n 1 | sed -E 's|.*/archive/([0-9a-f]{40}).*|\1|')
    [ -n "$commit" ] || { echo "no pinned yazi-rs/plugins url in $ext" >&2; return 1; }
    run all_captures "$RENOVATE" "$REPO_ROOT" "$ext"
    expect_status 0
    expect_capture "$ext" "$output" \
        "^[^$TAB]*${TAB}https://github\\.com/yazi-rs/plugins(\\.git)?${TAB}git-refs${TAB}main${TAB}$commit\$"
}

@test "renovate.json: a regex manager bumps the validator's renovate with npm (slice 7, criteria 10, 11)" {
    require_renovate
    ci=.github/workflows/ci.yml
    v=$(grep -oE 'renovate@[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/$ci" | head -n 1 | cut -d @ -f 2)
    [ -n "$v" ] || { echo "no renovate@<version> in $ci" >&2; return 1; }
    run all_captures "$RENOVATE" "$REPO_ROOT" "$ci"
    expect_status 0
    expect_capture "$ci" "$output" "^[^$TAB]*${TAB}renovate${TAB}npm${TAB}${v//./\\.}${TAB}\$"
}

@test "renovate.json: a regex manager bumps the validator's node with the node datasource (slice 7, criteria 10, 11)" {
    require_renovate
    ci=.github/workflows/ci.yml
    v=$(grep -oE 'node@[0-9]+\.[0-9]+\.[0-9]+' "$REPO_ROOT/$ci" | head -n 1 | cut -d @ -f 2)
    [ -n "$v" ] || { echo "no node@<version> in $ci" >&2; return 1; }
    run all_captures "$RENOVATE" "$REPO_ROOT" "$ci"
    expect_status 0
    expect_capture "$ci" "$output" "^[^$TAB]*${TAB}node${TAB}(node-version|node)${TAB}${v//./\\.}${TAB}\$"
}

# NODE24_RULES: allowedVersions of every packageRule that names node and
# is kept off mise's node.
NODE24_RULES='
{{- $c := include "@PATH@" | fromJson -}}
{{- range (dig "packageRules" list $c) -}}
{{-   $names := concat (dig "matchDepNames" list .) (dig "matchPackageNames" list .) -}}
{{-   $mgrs := dig "matchManagers" list . -}}
{{-   $files := join " " (dig "matchFileNames" list .) -}}
{{-   $offMise := or (and (not (empty $mgrs)) (not (has "mise" $mgrs))) (contains "ci.yml" $files) -}}
{{-   if and (has "node" $names) $offMise (hasKey . "allowedVersions") -}}
{{ get . "allowedVersions" }}{{ "\n" }}
{{-   end -}}
{{- end -}}
'

@test "renovate.json: the validator's node stays within major 24 (slice 7, criterion 10)" {
    require_renovate
    run tmpl "$(printf '%s' "$NODE24_RULES" | sed "s|@PATH@|$RENOVATE|")"
    expect_status 0
    printf '%s\n' "$output" | grep -qE '^(<25(\.0\.0)?|24\.x|\^24|~24|/\^v?24.*/)$' || {
        printf 'no packageRule for the CI node (off mise) with allowedVersions within 24; found:\n%s\n' "$output" >&2
        return 1
    }
}

SLICE6_RULES='{"matchDepNames":["python"],"matchManagers":["mise"],"separateMinorPatch":true}
{"dependencyDashboardApproval":true,"matchDepNames":["node"],"matchManagers":["mise"],"matchUpdateTypes":["major"]}
{"dependencyDashboardApproval":true,"matchDepNames":["python"],"matchManagers":["mise"],"matchUpdateTypes":["minor","major"]}'

@test "renovate.json: slice 6's packageRules are unchanged, in order (slice 7, criterion 10)" {
    require_renovate
    run tmpl "{{ range (dig \"packageRules\" list (include \"$RENOVATE\" | fromJson)) }}{{ toJson (omit . \"description\") }}{{ \"\\n\" }}{{ end }}"
    expect_status 0
    found=$(printf '%s\n' "$output" | grep -xF "$SLICE6_RULES" || true)
    expect_equal "slice 6 rules among the packageRules, in order" "$SLICE6_RULES" "$found"
}

@test "workflows: every action is pinned to a full commit sha with a version comment (slice 7, criteria 10, 11)" {
    found=0
    for f in "$REPO_ROOT"/.github/workflows/*.yml "$REPO_ROOT"/.github/workflows/*.yaml; do
        [ -f "$f" ] || continue
        bad=$(grep -nE '^[[:space:]]*(-[[:space:]]*)?uses:' "$f" |
            grep -vE 'uses:[[:space:]]*(\./|docker://)' |
            grep -vE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9]+(\.[0-9]+){0,2}[[:space:]]*$' || true)
        expect_equal "unpinned actions in ${f##*/}" "" "$bad"
        found=1
    done
    expect_equal "workflow files found" 1 "$found"
}

# ------------------------------------- the regex evaluator itself (11)

# regex_fixture <manager JSON> <file content>: a renovate.json with that
# one custom manager and a file home/.chezmoiexternal.toml with the
# content, in $TEST_TMP/fx; prints the captures for that file.
regex_fixture() {
    mkdir -p "$TEST_TMP/fx/home"
    printf '{"customManagers": [%s]}\n' "$1" >"$TEST_TMP/fx/renovate.json"
    printf '%s\n' "$2" >"$TEST_TMP/fx/home/.chezmoiexternal.toml"
    all_captures "$TEST_TMP/fx/renovate.json" "$TEST_TMP/fx" home/.chezmoiexternal.toml
}

FX_COMMIT=0123456789abcdef0123456789abcdef01234567
FX_URL="url = \"https://github.com/yazi-rs/plugins/archive/$FX_COMMIT.tar.gz\""

# fx_manager <file pattern JSON string>: the manager the brief describes.
fx_manager() {
    printf '%s' '{"customType": "regex", "managerFilePatterns": ['"$1"'],
  "matchStrings": ["https://github\\.com/yazi-rs/plugins/archive/(?<currentDigest>[0-9a-f]{40})\\.tar\\.gz"],
  "depNameTemplate": "yazi-rs/plugins", "packageNameTemplate": "https://github.com/yazi-rs/plugins",
  "datasourceTemplate": "git-refs", "currentValueTemplate": "main"}'
}

@test "regex evaluator: a manager as the brief wants it captures the commit (control)" {
    run regex_fixture "$(fx_manager '"/(^|/)\\.chezmoiexternal\\.toml(\\.tmpl)?$/"')" "$FX_URL"
    expect_status 0
    expect_equal "captures" "yazi-rs/plugins${TAB}https://github.com/yazi-rs/plugins${TAB}git-refs${TAB}main${TAB}$FX_COMMIT" "$output"
}

@test "regex evaluator: named groups win over templates, packageName falls back to depName" {
    m='{"customType": "regex", "fileMatch": ["\\.chezmoiexternal\\.toml$"],
      "matchStrings": ["(?<depName>yazi-rs/plugins)/archive/(?<currentDigest>[0-9a-f]{40})"],
      "depNameTemplate": "ignored", "datasourceTemplate": "git-refs", "currentValueTemplate": "main"}'
    run regex_fixture "$m" "$FX_URL"
    expect_status 0
    expect_equal "captures" "yazi-rs/plugins${TAB}yazi-rs/plugins${TAB}git-refs${TAB}main${TAB}$FX_COMMIT" "$output"
}

@test "regex evaluator: a glob file pattern applies the manager" {
    run regex_fixture "$(fx_manager '"home/.chezmoiexternal.toml*"')" "$FX_URL"
    expect_status 0
    expect_output_matches "${TAB}$FX_COMMIT\$"
}

@test "regex evaluator: a file pattern for another file captures nothing" {
    run regex_fixture "$(fx_manager '"/\\.chezmoiother\\.toml$/"')" "$FX_URL"
    expect_status 0
    expect_equal "captures" "" "$output"
    run regex_fixture "$(fx_manager '"home/other.toml"')" "$FX_URL"
    expect_status 0
    expect_equal "captures" "" "$output"
}

@test "regex evaluator: a matchString that doesn't match captures nothing" {
    run regex_fixture "$(fx_manager '"home/.chezmoiexternal.toml"')" \
        'url = "https://github.com/yazi-rs/plugins/archive/main.tar.gz"'
    expect_status 0
    expect_equal "captures" "" "$output"
}
