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
