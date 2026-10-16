#!/usr/bin/env bats
# Structural checks on .github/workflows/ci.yml (slice 2, criteria 11 and
# 12). actionlint (tests/run.sh lint) checks syntax; these check the
# brief's security and shape requirements by reading the file as text.

load ../helpers/common

CI="$REPO_ROOT/.github/workflows/ci.yml"

setup() {
    ws_isolate
    [ -f "$CI" ] || { echo "missing .github/workflows/ci.yml" >&2; return 1; }
}

# has <extended regex> <what>: some line of ci.yml matches.
has() {
    grep -qE -- "$1" "$CI" && return 0
    echo "ci.yml lacks $2 (/$1/)" >&2
    return 1
}

# run_blocks: prints every line that belongs to a `run:` value, inline or
# block scalar, prefixed with its line number.
run_blocks() {
    awk '
        function indent(s) { match(s, /^ */); return RLENGTH }
        inrun {
            if ($0 ~ /^[ \t]*$/ || indent($0) > runind) { print NR ": " $0; next }
            inrun = 0
        }
        /^[ \t]*(- )?run:/ {
            line = $0
            runind = indent(line)
            if (line ~ /^[ \t]*- /) runind += 2
            sub(/^[ \t]*(- )?run:[ \t]*/, "", line)
            if (line ~ /^[|>][-+0-9]*[ \t]*$/) inrun = 1
            else print NR ": " line
        }
    ' "$CI"
}

@test "ci.yml: triggers on push, pull_request, schedule and workflow_dispatch" {
    has '^[ ]{2}push:|^on:.*push' 'a push trigger'
    has '^[ ]{2}pull_request:|^on:.*pull_request' 'a pull_request trigger'
    has '^[ ]{2}schedule:' 'a schedule trigger'
    has 'cron:' 'a cron entry'
    has '^[ ]{2}workflow_dispatch:|^on:.*workflow_dispatch' 'a workflow_dispatch trigger'
}

@test "ci.yml: push is not limited to some branches" {
    # Either no branch filter or '**'.
    filter=$(awk '
        /^[ ]{2}push:/ { inpush = 1; next }
        inpush && /^[ ]{2}[^ ]/ { inpush = 0 }
        inpush && /branches(-ignore)?:/ { inb = 1; print; next }
        inpush && inb && /^[ ]{6}- / { print }
    ' "$CI")
    if [ -n "$filter" ]; then
        printf '%s\n' "$filter" | grep -qE "branches:.*['\"]\\*\\*['\"]|- ['\"]\\*\\*['\"]" || {
            printf 'push has a branch filter other than **:\n%s\n' "$filter" >&2
            return 1
        }
        if printf '%s\n' "$filter" | grep -q 'branches-ignore'; then
            echo "push uses branches-ignore" >&2
            return 1
        fi
    fi
}

@test "ci.yml: top-level permissions are contents: read" {
    awk '
        /^permissions:/ { inperm = 1; next }
        inperm && /^[^ ]/ { inperm = 0 }
        inperm && /^[ ]+contents:[ ]*read[ ]*$/ { ok = 1 }
        END { exit !ok }
    ' "$CI" || { echo "no top-level 'permissions: contents: read'" >&2; return 1; }
}

@test "ci.yml: no write permission anywhere" {
    run grep -nE '^[ ]*[a-z-]+:[ ]*write[ ]*$|write-all' "$CI"
    expect_status 1
}

@test "ci.yml: every action is pinned by a full commit sha" {
    bad=$(grep -nE '^[ ]*(- )?uses:' "$CI" |
        grep -vE 'uses:[ ]*["'\'']?\./' |
        grep -vE 'uses:[ ]*["'\'']?[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}["'\'']?([ ]+#.*)?[ ]*$' || true)
    expect_equal "unpinned uses: lines" "" "$bad"
    has 'uses:' 'any action (checkout at least)'
}

@test "ci.yml: fail-fast is false" {
    has '^[ ]+fail-fast:[ ]*false' 'fail-fast: false'
}

@test "ci.yml: has test, lint and privacy jobs" {
    has '^[ ]{2}test:' 'a test job'
    has '^[ ]{2}lint:' 'a lint job'
    has '^[ ]{2}privacy:' 'a privacy job'
}

@test "ci.yml: test job runs on ubuntu-latest and windows-latest" {
    has 'ubuntu-latest' 'ubuntu-latest'
    has 'windows-latest' 'windows-latest'
    has 'shell:[ ]*bash' 'shell: bash for Git Bash on Windows'
}

@test "ci.yml: runs tests/run.sh unit, render and lint" {
    has 'tests/run\.sh' 'a tests/run.sh call'
    has '(^|[^a-z])unit([^a-z]|$)' 'the unit mode'
    has '(^|[^a-z])render([^a-z]|$)' 'the render mode'
    has 'tests/run\.sh[ ]+lint' 'tests/run.sh lint'
}

@test "ci.yml: tool cache keyed on scripts/tools.lock" {
    has "hashFiles\\(['\"]scripts/tools\\.lock['\"]\\)" "a cache key from hashFiles('scripts/tools.lock')"
    has '\.cache/bin|\.cache' 'the .cache path'
}

@test "ci.yml: privacy job checks full history with the denylist secret" {
    has 'fetch-depth:[ ]*0' 'fetch-depth: 0'
    has 'secrets\.WS_DENYLIST' 'the WS_DENYLIST secret'
    has 'mktemp' 'a mktemp file for the denylist'
    has 'chmod[ ]+(0)?600|umask[ ]+(0)?077' 'mode 600 for the denylist file'
    has 'scripts/privacy-check\.sh[ ]+all' 'scripts/privacy-check.sh all'
    has 'always\(\)' 'a cleanup step that always runs'
}

@test "ci.yml: PR metadata and branch name go through privacy-check.sh text" {
    has 'scripts/privacy-check\.sh[ ]+text' 'scripts/privacy-check.sh text'
    has 'github\.event\.pull_request\.title' 'the PR title (via env:)'
    has 'github\.event\.pull_request\.body' 'the PR body (via env:)'
    has 'github\.(head_ref|ref_name)' 'the branch name (via env:)'
}

@test "ci.yml: no event data or secrets expanded inside run: (script injection)" {
    bad=$(run_blocks | grep -E '\$\{\{[^}]*(github\.event|github\.head_ref|github\.ref|github\.base_ref|inputs\.|secrets\.)' || true)
    expect_equal "run: lines with \${{ }} of event data or secrets" "" "$bad"
}

@test "ci.yml: run-block scanner sees the run: lines (self-check)" {
    n_lines=$(run_blocks | grep -c 'run\.sh\|privacy-check' || true)
    [ "$n_lines" -ge 2 ] || {
        echo "run_blocks found no run.sh or privacy-check lines; scanner broken?" >&2
        return 1
    }
}

# pull_request_types: the types list of the pull_request trigger, one per
# line (empty when there is no types filter).
pull_request_types() {
    awk '
        /^[ ]{2}pull_request:/ { inpr = 1; next }
        inpr && /^[ ]{2}[^ ]/ { inpr = 0 }
        inpr && /types:/ {
            line = $0
            sub(/.*types:[ ]*/, "", line)
            gsub(/[][,"'\'']/, " ", line)
            n = split(line, t, /[ ]+/)
            for (i = 1; i <= n; i++) if (t[i] != "") print t[i]
            intypes = 1
            next
        }
        inpr && intypes && /^[ ]+- / { l = $0; sub(/^[ ]+- [ ]*/, "", l); gsub(/["'\'']/, "", l); print l; next }
        inpr && intypes { intypes = 0 }
    ' "$CI"
}

@test "ci.yml: pull_request runs on edited, and still on opened, synchronize, reopened" {
    types=$(pull_request_types)
    for t in edited opened synchronize reopened; do
        printf '%s\n' "$types" | grep -qx "$t" || {
            printf 'pull_request types lack %s; types: %s\n' "$t" "$(printf '%s' "$types" | tr '\n' ' ')" >&2
            return 1
        }
    done
}
