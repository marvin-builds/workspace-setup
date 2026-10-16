#!/usr/bin/env bats
# Render tests for home/.chezmoi.toml.tmpl (slice 2, criterion 5).
#
# chezmoi execute-template --init simulates the prompts; its --promptString,
# --promptChoice and --promptBool flags (checked against chezmoi 2.73.1
# --help) take "<prompt text>=<value>" pairs keyed by the prompt text, not
# by the data key. So the prompt texts are part of the contract:
#
#   data key           function            prompt text
#   role               promptChoiceOnce    Role          (personal, work)
#   form               promptChoiceOnce    Form          (desktop, headless, wsl, container)
#   name               promptStringOnce    Name
#   github_identities  promptStringOnce    GitHub identities
#   ci                 promptBoolOnce      CI            (default false)
#
# Prompt texts must not contain '=' or ',' (the flag splits on both).

load ../helpers/common

TEMPLATE="$REPO_ROOT/home/.chezmoi.toml.tmpl"

P_ROLE='Role'
P_FORM='Form'
P_NAME='Name'
P_IDS='GitHub identities'
P_CI='CI'

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    [ -f "$TEMPLATE" ] || { echo "missing home/.chezmoi.toml.tmpl" >&2; return 1; }
    OUT_TOML="$TEST_TMP/generated.toml"
    EMPTY_SRC="$TEST_TMP/empty-source"
    mkdir -p "$EMPTY_SRC"
}

# init_template <config> <chezmoi prompt flags...>: renders the config
# template as `chezmoi init` would, output in $OUT_TOML.
init_template() {
    config=$1
    shift
    run "$CHEZMOI" --no-tty --source "$REPO_ROOT/home" --config "$config" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --init "$@" <"$TEMPLATE"
    [ "$status" -ne 0 ] || printf '%s\n' "$output" >"$OUT_TOML"
}

# data_of <toml> <template>: renders <template> with <toml> as config,
# which also proves the TOML parses.
data_of() {
    "$CHEZMOI" --no-tty --source "$EMPTY_SRC" --config "$1" \
        --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/state-read.boltdb" \
        execute-template "$2"
}

@test "config template: prompts render to parseable TOML with the given values" {
    init_template "$TEST_TMP/no-config.toml" \
        --promptChoice "$P_ROLE=work" \
        --promptChoice "$P_FORM=wsl" \
        --promptString "$P_NAME=$FAKE_NAME" \
        --promptString "$P_IDS=$FAKE_IDENTITIES" \
        --promptBool "$P_CI=true"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .role }}|{{ .form }}|{{ .name }}|{{ .github_identities }}|{{ .ci }}|{{ printf "%T" .ci }}'
    expect_status 0
    expect_equal "data" "work|wsl|$FAKE_NAME|$FAKE_IDENTITIES|true|bool" "$output"
}

@test "config template: other choices render too" {
    init_template "$TEST_TMP/no-config.toml" \
        --promptChoice "$P_ROLE=personal" \
        --promptChoice "$P_FORM=container" \
        --promptString "$P_NAME=$FAKE_NAME" \
        --promptString "$P_IDS=$OWNER1=$EMAIL1" \
        --promptBool "$P_CI=true"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .role }}|{{ .form }}|{{ .github_identities }}'
    expect_status 0
    expect_equal "data" "personal|container|$OWNER1=$EMAIL1" "$output"
}

@test "config template: ci defaults to false" {
    init_template "$TEST_TMP/no-config.toml" \
        --promptChoice "$P_ROLE=personal" \
        --promptChoice "$P_FORM=desktop" \
        --promptString "$P_NAME=$FAKE_NAME" \
        --promptString "$P_IDS=$FAKE_IDENTITIES"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .ci }}|{{ printf "%T" .ci }}'
    expect_status 0
    expect_equal "ci" "false|bool" "$output"
}

@test "config template: role outside personal/work is refused" {
    init_template "$TEST_TMP/no-config.toml" \
        --promptChoice "$P_ROLE=boss" \
        --promptChoice "$P_FORM=desktop" \
        --promptString "$P_NAME=$FAKE_NAME" \
        --promptString "$P_IDS=$FAKE_IDENTITIES"
    expect_failure
}

@test "config template: form outside the four forms is refused" {
    init_template "$TEST_TMP/no-config.toml" \
        --promptChoice "$P_ROLE=work" \
        --promptChoice "$P_FORM=laptop" \
        --promptString "$P_NAME=$FAKE_NAME" \
        --promptString "$P_IDS=$FAKE_IDENTITIES"
    expect_failure
}

@test "config template: each form is a valid choice" {
    for form in desktop headless wsl container; do
        init_template "$TEST_TMP/no-config.toml" \
            --promptChoice "$P_ROLE=work" \
            --promptChoice "$P_FORM=$form" \
            --promptString "$P_NAME=$FAKE_NAME" \
            --promptString "$P_IDS=$FAKE_IDENTITIES"
        expect_status 0
        run data_of "$OUT_TOML" '{{ .form }}'
        expect_equal "form" "$form" "$output"
    done
}

@test "config template: prompts only once (existing values win)" {
    existing="$TEST_TMP/existing.toml"
    cat >"$existing" <<EOF
[data]
role = "personal"
form = "headless"
name = "$FAKE_NAME"
github_identities = "$OWNER2=$EMAIL2"
ci = true
EOF
    init_template "$existing" \
        --promptChoice "$P_ROLE=work" \
        --promptChoice "$P_FORM=wsl" \
        --promptString "$P_NAME=Other Person" \
        --promptString "$P_IDS=$OWNER1=$EMAIL1" \
        --promptBool "$P_CI=false"
    expect_status 0
    run data_of "$OUT_TOML" '{{ .role }}|{{ .form }}|{{ .name }}|{{ .github_identities }}|{{ .ci }}'
    expect_status 0
    expect_equal "data" "personal|headless|$FAKE_NAME|$OWNER2=$EMAIL2|true" "$output"
}
