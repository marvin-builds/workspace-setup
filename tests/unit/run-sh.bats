#!/usr/bin/env bats
# Tests for tests/run.sh (slice 2, criterion 3). The system mode (slice 3)
# is tested in tests/unit/system.bats.
#
#   tests/run.sh <unit|render|lint|all>
#
# Mode exit codes are checked in a copy of the repo, so the tests can add a
# failing bats file or a bad script without touching the real tree. The
# copy keeps .cache/, so run.sh finds its tools without downloading.

load ../helpers/common

RUN="$REPO_ROOT/tests/run.sh"

setup() {
    ws_isolate
    [ -x "$RUN" ] || { echo "missing or not executable: tests/run.sh" >&2; return 1; }
}

# make_copy: a copy of the repo at $COPY with empty tests/unit and
# tests/render, as its own git repo with everything tracked.
make_copy() {
    COPY="$TEST_TMP/copy"
    mkdir -p "$COPY"
    cp -R "$REPO_ROOT/." "$COPY/"
    rm -rf "$COPY/.git" "$COPY/tests/unit" "$COPY/tests/render"
    mkdir -p "$COPY/tests/unit" "$COPY/tests/render"
    [ "${1:-}" = --no-git ] && return 0
    git -C "$COPY" init -q
    git -C "$COPY" add -A
}

# stub_privacy <exit code>: replaces the copy's tests/privacy.sh with a
# fast stub, so unit and all modes don't run the real privacy cases.
stub_privacy() {
    printf '#!/bin/sh\n# Stub for tests/unit/run-sh.bats.\necho "privacy stub exits %s"\nexit %s\n' \
        "$1" "$1" >"$COPY/tests/privacy.sh"
    chmod +x "$COPY/tests/privacy.sh"
    git -C "$COPY" add tests/privacy.sh
}

# add_bats <unit|render> <name> <true|false>: a one-test bats file.
add_bats() {
    printf '@test "%s" { %s; }\n' "$2" "$3" >"$COPY/tests/$1/$2.bats"
    git -C "$COPY" add "tests/$1/$2.bats"
}

@test "run.sh: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$RUN")"
}

@test "run.sh: unknown mode fails" {
    run "$RUN" no-such-mode
    expect_failure
    expect_output_matches '[Uu]sage|unit'
}

@test "run.sh: no mode fails with usage" {
    run "$RUN"
    expect_failure
    expect_output_matches '[Uu]sage|unit'
}

@test "run.sh: render exits non-zero when a render test fails" {
    make_copy
    cat >"$COPY/tests/render/pass.bats" <<'EOF'
@test "passes" { true; }
EOF
    cat >"$COPY/tests/render/fail.bats" <<'EOF'
@test "fails on purpose" { false; }
EOF
    run "$COPY/tests/run.sh" render
    expect_failure
    expect_output_matches 'fails on purpose'
}

@test "run.sh: render exits zero when every render test passes" {
    make_copy
    cat >"$COPY/tests/render/pass.bats" <<'EOF'
@test "passes on purpose" { true; }
EOF
    run "$COPY/tests/run.sh" render
    expect_status 0
    expect_output_matches 'passes on purpose'
}

@test "run.sh: lint flags an extensionless shell script under scripts/" {
    make_copy
    # shellcheck disable=SC2016 # the bait script's text, not expanded here
    printf '#!/bin/sh\nfor f in $(ls); do echo $f; done\n' >"$COPY/scripts/lint-bait"
    chmod +x "$COPY/scripts/lint-bait"
    git -C "$COPY" add scripts/lint-bait
    run "$COPY/tests/run.sh" lint
    expect_failure
    expect_output_matches 'lint-bait'
}

@test "run.sh: lint flags a bad *.sh script under tests/" {
    make_copy
    # shellcheck disable=SC2016 # the bait script's text, not expanded here
    printf '#!/bin/sh\necho $1\n[ $x == y ]\n' >"$COPY/tests/lint-bait.sh"
    git -C "$COPY" add tests/lint-bait.sh
    run "$COPY/tests/run.sh" lint
    expect_failure
    expect_output_matches 'lint-bait\.sh'
}

@test "run.sh: lint flags a broken workflow" {
    make_copy
    mkdir -p "$COPY/.github/workflows"
    cat >"$COPY/.github/workflows/lint-bait.yml" <<'EOF'
on: push
jobs:
  bait:
    runs-on: ubuntu-latest
    steps:
      - run: echo "${{ github.no_such_context_key }}"
        unknown-key: true
EOF
    git -C "$COPY" add .github/workflows/lint-bait.yml
    run "$COPY/tests/run.sh" lint
    expect_failure
    expect_output_matches 'lint-bait\.yml'
}

# ------------------------------------------------ exit propagation (30)

@test "run.sh: unit exits zero when unit tests and privacy.sh pass (control)" {
    make_copy
    stub_privacy 0
    add_bats unit unit-passes true
    run "$COPY/tests/run.sh" unit
    expect_status 0
    expect_output_matches 'unit-passes'
    expect_output_matches 'privacy stub exits 0'
}

@test "run.sh: unit exits non-zero when a unit bats file fails" {
    make_copy
    stub_privacy 0
    add_bats unit unit-passes true
    add_bats unit unit-fails false
    run "$COPY/tests/run.sh" unit
    expect_failure
    expect_output_matches 'unit-fails'
}

@test "run.sh: unit exits non-zero when privacy.sh fails" {
    make_copy
    stub_privacy 1
    add_bats unit unit-passes true
    run "$COPY/tests/run.sh" unit
    expect_failure
    expect_output_matches 'privacy stub exits 1'
}

@test "run.sh: all exits zero when every mode passes (control)" {
    make_copy
    stub_privacy 0
    add_bats unit unit-passes true
    add_bats render render-passes true
    run "$COPY/tests/run.sh" all
    expect_status 0
    expect_output_matches 'unit-passes'
    expect_output_matches 'render-passes'
}

@test "run.sh: all exits non-zero when only render fails" {
    make_copy
    stub_privacy 0
    add_bats unit unit-passes true
    add_bats render render-fails false
    run "$COPY/tests/run.sh" all
    expect_failure
    expect_output_matches 'render-fails'
}

@test "run.sh: all exits non-zero when only unit fails, and still runs render" {
    make_copy
    stub_privacy 0
    add_bats unit unit-fails false
    add_bats render render-passes true
    run "$COPY/tests/run.sh" all
    expect_failure
    expect_output_matches 'unit-fails'
    expect_output_matches 'render-passes'
}

# --------------------------------------------------------- lint (26)

@test "run.sh: lint passes with a non-shell file sorting last" {
    make_copy
    printf 'plain notes, not a script\n' >"$COPY/tests/zzzz-notes.txt"
    printf 'more notes\n' >"$COPY/zzzz-last.txt"
    git -C "$COPY" add tests/zzzz-notes.txt zzzz-last.txt
    run "$COPY/tests/run.sh" lint
    expect_status 0
}

@test "run.sh: lint fails outside a git repo" {
    make_copy --no-git
    run "$COPY/tests/run.sh" lint
    expect_failure
}

# ------------------------------------------- non-ASCII file names (34)

@test "run.sh: lint passes a clean script with a non-ASCII name (control)" {
    make_copy
    printf '#!/bin/sh\necho "fine"\n' >"$COPY/scripts/gööd.sh"
    git -C "$COPY" add "scripts/gööd.sh"
    run "$COPY/tests/run.sh" lint
    expect_status 0
}

@test "run.sh: lint lints a tracked script with a non-ASCII name" {
    make_copy
    # shellcheck disable=SC2016 # the bait script's text, not expanded here
    printf '#!/bin/sh\nfor f in $(ls); do echo $f; done\n' >"$COPY/scripts/bäd.sh"
    git -C "$COPY" add "scripts/bäd.sh"
    run "$COPY/tests/run.sh" lint
    expect_failure
    expect_output_matches 'bäd\.sh'
    expect_output_matches 'SC[0-9]{4}'
}
