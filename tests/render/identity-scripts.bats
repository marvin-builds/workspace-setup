#!/usr/bin/env bats
# Render tests for the run_onchange identity script templates (slice 2,
# review round 1: criteria 21, 27, 28).
#
#   home/.chezmoiscripts/run_onchange_after_git-identities.sh.tmpl
#   home/.chezmoiscripts/run_onchange_after_git-identities.ps1.tmpl

load ../helpers/common

SH_TMPL=home/.chezmoiscripts/run_onchange_after_git-identities.sh.tmpl
PS1_TMPL=home/.chezmoiscripts/run_onchange_after_git-identities.ps1.tmpl

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    CANARY="$TEST_TMP/canary"
    mkdir -p "$DEST"
}

# exec_tmpl <source root> <template path relative to it>: renders one
# template with $PROFILE, as chezmoi apply would.
exec_tmpl() {
    "$CHEZMOI" --no-tty --source "$1/home" --destination "$DEST" \
        --config "$PROFILE" --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" \
        execute-template --file "$1/$2"
}

# profile_with_ids <toml-escaped value>: a profile like personal-desktop
# whose github_identities is <value> (written as a TOML basic string).
profile_with_ids() {
    PROFILE="$TEST_TMP/profile.toml"
    grep -v '^github_identities' "$PROFILES_DIR/personal-desktop.toml" >"$PROFILE"
    printf 'github_identities = "%s"\n' "$1" >>"$PROFILE"
}

# ------------------------------------------- no code from prompt data (21)

@test "identity templates: render with valid data (control)" {
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    run exec_tmpl "$REPO_ROOT" "$SH_TMPL"
    expect_status 0
    run exec_tmpl "$REPO_ROOT" "$PS1_TMPL"
    expect_status 0
}

# expect_refused <toml-escaped value>: both templates and apply fail, the
# canary is never created and no identity file is written.
expect_refused() {
    profile_with_ids "$1"
    run exec_tmpl "$REPO_ROOT" "$SH_TMPL"
    expect_failure
    run exec_tmpl "$REPO_ROOT" "$PS1_TMPL"
    expect_failure
    run cz apply --force
    expect_failure
    [ ! -e "$CANARY" ] || { echo "data ran as code: canary created" >&2; return 1; }
    [ ! -e "$DEST/.config/git/identities" ] || {
        echo "identity files written from bad data" >&2
        return 1
    }
}

@test "identity templates: newline and here-doc terminator are refused" {
    expect_refused "$OWNER1=$EMAIL1\\nEOF\\ntouch $CANARY\\nEOF"
}

@test "identity templates: newline and PowerShell here-string end are refused" {
    expect_refused "$OWNER1=$EMAIL1\\n'@\\ntouch $CANARY\\n@'"
}

@test "identity templates: \$( command substitution is refused" {
    expect_refused "$OWNER1=\$(touch $CANARY)"
}

@test "identity templates: backtick command substitution is refused" {
    expect_refused "$OWNER1=\`touch $CANARY\`"
}

@test "identity templates: semicolon and quote are refused" {
    expect_refused "$OWNER1=$EMAIL1;touch $CANARY;'"
}

@test "identity templates: a tab between pairs is still accepted" {
    profile_with_ids "$OWNER1=$EMAIL1\\t$OWNER2=$EMAIL2"
    run exec_tmpl "$REPO_ROOT" "$SH_TMPL"
    expect_status 0
    run exec_tmpl "$REPO_ROOT" "$PS1_TMPL"
    expect_status 0
}

# ------------------------------------- source without a working tree (27)

@test "identity templates: source without git working tree fails naming the script" {
    src="$TEST_TMP/src"
    mkdir -p "$src"
    cp -R "$REPO_ROOT/home" "$src/home"
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    run "$CHEZMOI" --no-tty --no-pager --source "$src/home" --destination "$DEST" \
        --config "$PROFILE" --cache "$TEST_TMP/chezmoi-cache" \
        --persistent-state "$TEST_TMP/chezmoistate.boltdb" apply --force
    expect_failure
    [ "$status" -ne 127 ] || { echo "exit 127 instead of a clear message" >&2; return 1; }
    # chezmoi names its own script .chezmoiscripts/git-identities.sh, so the
    # repo path must appear (either separator: native paths on Windows),
    # and the shell's 127 must not.
    expect_output_matches '(^|[^A-Za-z])scripts[/\\]git-identities\.sh'
    expect_output_lacks 'exit status 127'
    expect_output_lacks ': not found'
}

# ------------------------------------------ rerun when logic changes (28)

@test "identity templates: rendered scripts change when git-identities.sh changes" {
    copy="$TEST_TMP/repo"
    mkdir -p "$copy"
    for e in "$REPO_ROOT"/* "$REPO_ROOT"/.[!.]*; do
        [ "${e##*/}" = .cache ] || cp -R "$e" "$copy/"
    done
    PROFILE="$PROFILES_DIR/personal-desktop.toml"
    sh_before=$(exec_tmpl "$copy" "$SH_TMPL")
    ps1_before=$(exec_tmpl "$copy" "$PS1_TMPL")
    printf '# a change in the logic\n' >>"$copy/scripts/git-identities.sh"
    sh_after=$(exec_tmpl "$copy" "$SH_TMPL")
    ps1_after=$(exec_tmpl "$copy" "$PS1_TMPL")
    [ "$sh_before" != "$sh_after" ] || {
        echo "sh template output ignores changes to scripts/git-identities.sh" >&2
        return 1
    }
    [ "$ps1_before" != "$ps1_after" ] || {
        echo "ps1 template output ignores changes to scripts/git-identities.sh" >&2
        return 1
    }
}
