#!/usr/bin/env bats
# Unit tests for scripts/history-check.sh: a pull request branch must not
# contain merge commits, so every branch stays a separate bump on main
# (rebase onto main instead of merging main in, e.g. with GitHub's
# "Update branch" button).
#
# Interface (the implementation follows this):
#
#   scripts/history-check.sh <base> [<head>]
#
#   Runs on the repo of the current directory. <head> defaults to HEAD.
#   Exit 0 when base..head holds no merge commit. Exit 1 when it does; the
#   output names each merge commit by short sha and says to rebase onto
#   <base>. Exit 2 on a usage error or a revision git can't resolve.

load ../helpers/common

CHECK="$REPO_ROOT/scripts/history-check.sh"

setup() {
    ws_isolate
    export GIT_AUTHOR_NAME="$FAKE_NAME" GIT_AUTHOR_EMAIL="$EMAIL1" \
        GIT_COMMITTER_NAME="$FAKE_NAME" GIT_COMMITTER_EMAIL="$EMAIL1"
    cd "$TEST_TMP" || return 1
    git init -q -b main repo
    cd repo || return 1
    commit base
}

# commit <name>: a commit that adds file <name>.
commit() {
    printf '%s\n' "$1" >"$1"
    git add "$1"
    git commit -q -m "Add $1"
}

@test "history-check: a linear branch passes" {
    git switch -q -c feature
    commit one
    commit two
    run "$CHECK" main
    expect_status 0
}

@test "history-check: a branch equal to the base passes" {
    run "$CHECK" main
    expect_status 0
}

@test "history-check: main merged into the branch fails and names the merge" {
    git switch -q -c feature
    commit one
    git switch -q main
    commit later
    git switch -q feature
    git merge -q --no-edit main
    merge=$(git rev-parse --short HEAD)
    run "$CHECK" main
    expect_status 1
    expect_output_matches "$merge"
    expect_output_matches 'rebase'
}

@test "history-check: merges already on the base don't count" {
    git switch -q -c side
    commit side
    git switch -q main
    git merge -q --no-ff --no-edit side
    git switch -q -c feature
    commit one
    run "$CHECK" main
    expect_status 0
}

@test "history-check: checks the given head instead of HEAD" {
    git switch -q -c feature
    commit one
    git switch -q main
    commit later
    git switch -q feature
    git merge -q --no-edit main
    git switch -q main
    run "$CHECK" main feature
    expect_status 1
}

@test "history-check: an unknown revision is exit 2" {
    run "$CHECK" no-such-branch
    expect_status 2
}

@test "history-check: no arguments is a usage error" {
    run "$CHECK"
    expect_status 2
    expect_output_matches 'usage'
}
