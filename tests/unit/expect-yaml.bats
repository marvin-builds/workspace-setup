#!/usr/bin/env bats
# shellcheck disable=SC2016 # the validator is a chezmoi template, not shell
# Validates tests/expect.yaml (slice 3, criteria 5, 7 and 8).
#
# The YAML is parsed with the pinned chezmoi (execute-template, include,
# fromYaml), so no YAML tool is needed. The validator template below prints
# one error per line, or "ok". The negative cases prove it catches each
# kind of error, so a passing run on the real file means something.
#
# Format (defined here and in the header of tests/expect.yaml): a top-level
# key `checks` holding a list of mappings. Allowed keys: id, command, smoke,
# source, file, absent, line, os, roles, forms. smoke and source only with
# command; line is a mapping with exactly file, text (strings) and count
# (a non-negative integer).

load ../helpers/common

EXPECT="$REPO_ROOT/tests/expect.yaml"

# The validator: $path is replaced with the file to check.
VALIDATOR='
{{- $doc := include "@PATH@" | fromYaml -}}
{{- $errs := list -}}
{{- $kinds := list "command" "file" "absent" "line" -}}
{{- $allowed := list "id" "command" "smoke" "source" "file" "absent" "line" "os" "roles" "forms" -}}
{{- $known := dict "os" (list "linux" "darwin" "windows") "roles" (list "personal" "work") "forms" (list "desktop" "headless" "wsl" "container") -}}
{{- $seen := dict -}}
{{- if not (kindIs "map" $doc) -}}
{{-   $errs = append $errs "top level is not a mapping" -}}
{{- else if not (hasKey $doc "checks") -}}
{{-   $errs = append $errs "no checks key" -}}
{{- else if not (kindIs "slice" $doc.checks) -}}
{{-   $errs = append $errs "checks is not a list" -}}
{{- else -}}
{{-   range $i, $c := $doc.checks -}}
{{-     $where := printf "entry %d" $i -}}
{{-     if not (kindIs "map" $c) -}}
{{-       $errs = append $errs (printf "%s: not a mapping" $where) -}}
{{-       continue -}}
{{-     end -}}
{{-     $id := "" -}}
{{-     if hasKey $c "id" }}{{ $id = toString (get $c "id") }}{{ end -}}
{{-     if not (and (kindIs "string" (get $c "id")) (regexMatch "^[a-z0-9-]+$" $id)) -}}
{{-       $errs = append $errs (printf "%s: bad id %q" $where $id) -}}
{{-     else if hasKey $seen $id -}}
{{-       $errs = append $errs (printf "%s: duplicate id %s" $where $id) -}}
{{-     end -}}
{{-     $_ := set $seen $id true -}}
{{-     range $k, $v := $c -}}
{{-       if not (has $k $allowed) }}{{ $errs = append $errs (printf "%s: unknown key %s" $where $k) }}{{ end -}}
{{-     end -}}
{{-     $n := 0 -}}
{{-     range $kinds }}{{ if hasKey $c . }}{{ $n = add1 $n }}{{ end }}{{ end -}}
{{-     if ne $n 1 }}{{ $errs = append $errs (printf "%s: %d kinds, want exactly one" $where $n) }}{{ end -}}
{{-     if and (or (hasKey $c "smoke") (hasKey $c "source")) (not (hasKey $c "command")) -}}
{{-       $errs = append $errs (printf "%s: smoke or source without command" $where) -}}
{{-     end -}}
{{-     range (list "command" "smoke" "source" "file" "absent") -}}
{{-       if hasKey $c . -}}
{{-         if not (and (kindIs "string" (get $c .)) (ne (get $c .) "")) }}{{ $errs = append $errs (printf "%s: %s must be a non-empty string" $where .) }}{{ end -}}
{{-       end -}}
{{-     end -}}
{{-     if hasKey $c "line" -}}
{{-       $l := $c.line -}}
{{-       if not (kindIs "map" $l) -}}
{{-         $errs = append $errs (printf "%s: line must be a mapping" $where) -}}
{{-       else -}}
{{-         range $k, $v := $l -}}
{{-           if not (has $k (list "file" "text" "count")) }}{{ $errs = append $errs (printf "%s: line has unknown key %s" $where $k) }}{{ end -}}
{{-         end -}}
{{-         if not (and (kindIs "string" (get $l "file")) (ne (toString (get $l "file")) "")) }}{{ $errs = append $errs (printf "%s: line.file must be a non-empty string" $where) }}{{ end -}}
{{-         if not (and (hasKey $l "text") (kindIs "string" (get $l "text"))) }}{{ $errs = append $errs (printf "%s: line.text must be a string" $where) }}{{ end -}}
{{-         if or (kindIs "string" (get $l "count")) (not (regexMatch "^[0-9]+$" (toString (get $l "count")))) }}{{ $errs = append $errs (printf "%s: line.count must be a non-negative integer" $where) }}{{ end -}}
{{-       end -}}
{{-     end -}}
{{-     range $f, $vals := $known -}}
{{-       if hasKey $c $f -}}
{{-         $list := get $c $f -}}
{{-         if not (kindIs "slice" $list) -}}
{{-           $errs = append $errs (printf "%s: %s must be a list" $where $f) -}}
{{-         else -}}
{{-           range $list }}{{ if not (has (toString .) $vals) }}{{ $errs = append $errs (printf "%s: unknown %s value %v" $where $f .) }}{{ end }}{{ end -}}
{{-         end -}}
{{-       end -}}
{{-     end -}}
{{-     if regexMatch "(^|[^\\\\])(\\\\\\\\)*\\\\[tnr]" (toJson $c) -}}
{{-       $errs = append $errs (printf "%s: a value holds a tab or newline" $where) -}}
{{-     end -}}
{{-   end -}}
{{- end -}}
{{- if $errs }}{{ join "\n" $errs }}{{ else }}ok{{ end -}}
'

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    EMPTY_SRC="$TEST_TMP/empty-source"
    mkdir -p "$EMPTY_SRC"
}

# validate <yaml file>: runs the validator; output is "ok" or the errors.
validate() {
    tmpl=$(printf '%s' "$VALIDATOR" | sed "s|@PATH@|$1|")
    "$CHEZMOI" --no-tty --source "$EMPTY_SRC" --config "$TEST_TMP/none.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template "$tmpl"
}

# fixture <yaml text>: writes a fixture and validates it.
fixture() {
    printf '%s\n' "$1" >"$TEST_TMP/fixture.yaml"
    run validate "$TEST_TMP/fixture.yaml"
}

# expect_invalid <yaml text> <regex for the error>
expect_invalid() {
    fixture "$1"
    expect_status 0
    expect_output_matches "$2"
    [ "$output" != ok ] || { echo "validator accepted an invalid fixture" >&2; return 1; }
}

# --------------------------------------------------------- the real file

@test "expect.yaml: exists and is valid" {
    [ -f "$EXPECT" ] || { echo "missing tests/expect.yaml" >&2; return 1; }
    run validate "$EXPECT"
    expect_status 0
    expect_equal "validator output" ok "$output"
}

# entry_json <id>: the entry with that id as JSON, empty if none.
entry_json() {
    "$CHEZMOI" --no-tty --source "$EMPTY_SRC" --config "$TEST_TMP/none.toml" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template "{{ range (include \"$EXPECT\" | fromYaml).checks }}{{ if eq (toString .id) \"$1\" }}{{ toJson . }}{{ end }}{{ end }}"
}

@test "expect.yaml: first entries (criterion 8)" {
    expect_equal chezmoi '{"command":"chezmoi","id":"chezmoi","smoke":"chezmoi --version","source":"~/.local/bin/chezmoi"}' "$(entry_json chezmoi)"
    expect_equal git '{"command":"git","id":"git","smoke":"git --version"}' "$(entry_json git)"
    expect_equal ws '{"command":"ws","id":"ws","source":"~/.local/bin/ws"}' "$(entry_json ws)"
    [ -n "$(entry_json git-config)" ] || { echo "no git-config entry" >&2; return 1; }
    expect_equal git-config '{"file":"~/.config/git/config","id":"git-config"}' "$(entry_json git-config)"
    expect_equal expect-tsv '{"file":"~/.config/ws/expect.tsv","id":"expect-tsv"}' "$(entry_json expect-tsv)"
}

# ------------------------------------------------- the validator itself

@test "validator: accepts every kind and filter (control)" {
    fixture 'checks:
  - id: a-1
    command: sh
    smoke: sh -c true
    source: ~/bin/sh
  - id: b
    file: ~/x
    os: [linux, darwin, windows]
  - id: c
    absent: ~/y
    roles: [personal, work]
  - id: d
    line: {file: ~/z, text: "some text", count: 0}
    forms: [desktop, headless, wsl, container]'
    expect_status 0
    expect_equal "validator output" ok "$output"
}

@test "validator: duplicate id" {
    expect_invalid 'checks:
  - id: a
    file: ~/x
  - id: a
    file: ~/y' 'duplicate id'
}

@test "validator: malformed ids" {
    expect_invalid 'checks:
  - id: Upper
    file: ~/x' 'bad id'
    expect_invalid 'checks:
  - id: has_underscore
    file: ~/x' 'bad id'
    expect_invalid 'checks:
  - file: ~/x' 'bad id'
    expect_invalid 'checks:
  - id: 12
    file: ~/x' 'bad id'
}

@test "validator: no kind or two kinds" {
    expect_invalid 'checks:
  - id: a
    os: [linux]' '0 kinds'
    expect_invalid 'checks:
  - id: a
    file: ~/x
    absent: ~/y' '2 kinds'
}

@test "validator: smoke or source without command" {
    expect_invalid 'checks:
  - id: a
    file: ~/x
    smoke: "true"' 'without command'
}

@test "validator: unknown key" {
    expect_invalid 'checks:
  - id: a
    file: ~/x
    role: [work]' 'unknown key role'
}

@test "validator: tab or newline in a value" {
    expect_invalid 'checks:
  - id: a
    file: "~/x\ty"' 'tab or newline'
    expect_invalid 'checks:
  - id: a
    line: {file: ~/x, text: "a\nb", count: 1}' 'tab or newline'
    expect_invalid 'checks:
  - id: a
    command: sh
    smoke: |
      echo one
      echo two' 'tab or newline'
}

@test "validator: a backslash-t in a value is not a tab (control)" {
    fixture 'checks:
  - id: a
    file: '"'"'~/x\ty'"'"
    expect_status 0
    expect_equal "validator output" ok "$output"
}

@test "validator: unknown filter values" {
    expect_invalid 'checks:
  - id: a
    file: ~/x
    roles: [boss]' 'unknown roles value boss'
    expect_invalid 'checks:
  - id: a
    file: ~/x
    forms: [laptop]' 'unknown forms value laptop'
    expect_invalid 'checks:
  - id: a
    file: ~/x
    os: [freebsd]' 'unknown os value freebsd'
    expect_invalid 'checks:
  - id: a
    file: ~/x
    roles: work' 'roles must be a list'
}

@test "validator: malformed line checks" {
    expect_invalid 'checks:
  - id: a
    line: {file: ~/x, text: t}' 'count'
    expect_invalid 'checks:
  - id: a
    line: {file: ~/x, text: t, count: -1}' 'count'
    expect_invalid 'checks:
  - id: a
    line: {file: ~/x, text: t, count: "2"}' 'count'
    expect_invalid 'checks:
  - id: a
    line: {text: t, count: 1}' 'line.file'
    expect_invalid 'checks:
  - id: a
    line: {file: ~/x, count: 1}' 'line.text'
    expect_invalid 'checks:
  - id: a
    line: ~/x' 'line must be a mapping'
}

@test "validator: empty values" {
    expect_invalid 'checks:
  - id: a
    command: ""' 'non-empty'
}

@test "validator: wrong top level" {
    expect_invalid '- id: a
  file: ~/x' 'top level'
    expect_invalid 'other: 1' 'no checks key'
}
