#!/usr/bin/env bats
# shellcheck disable=SC2030,SC2031 # per-test exports for the docker stub
# Unit tests for scripts/check-package-ids.sh (slice 5, criterion 19) with
# a stub docker; the real check needs Docker and network and runs in the
# CI job `packages` (tests/unit/ci-workflow.bats).
#
# Interface (the implementation follows this):
#
#   scripts/check-package-ids.sh [<packages.yaml>]
#
#   Default file: <repo>/home/.chezmoidata/packages.yaml. Reads it
#   unfiltered (no role or form filter) with chezmoi (from PATH, else
#   <repo>/.cache/bin) and builds the data of scripts/install-apt.sh
#   (format in tests/unit/install-apt.bats): one `repo` line for every
#   apt_repos entry and one `package` line for every non-null apt id.
#   It then runs one fresh container:
#
#       docker run --rm -i -v <repo root>:/src:ro ubuntu:24.04 <command>
#
#   (options in any order, an equivalent --volume/--interactive spelling
#   is fine) with the data on docker's stdin, where <command> prepares the
#   container (sudo, curl, ca-certificates) and runs
#   `sh /src/scripts/install-apt.sh check`. Exit status: docker's. Without
#   docker: non-zero, naming docker, nothing run.
#
#   Docker config (decision 40), like `tests/run.sh system`: docker runs
#   with DOCKER_CONFIG set to a new empty temp directory (no config.json,
#   so no credential helpers or auths of the caller), holding links to the
#   caller's cli-plugins and contexts when present; the current context
#   (DOCKER_CONTEXT, else `docker context show` read with the caller's
#   config) is passed on as DOCKER_CONTEXT unless DOCKER_HOST is set. The
#   temp directory is removed afterwards, also on failure.

load ../helpers/common

SCRIPT="$REPO_ROOT/scripts/check-package-ids.sh"
FIXTURE="$REPO_ROOT/tests/schema/fixtures/valid-filtered.yaml"
TAB=$(printf '\t')

setup_file() {
    sysbin="$BATS_FILE_TMPDIR/sysbin"
    mkdir -p "$sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            case $n in docker | sudo | apt | apt-get) continue ;; esac
            [ -e "$sysbin/$n" ] || [ -L "$sysbin/$n" ] || ln -s "$f" "$sysbin/$n"
        done
    done
}

setup() {
    ws_isolate
    [ -f "$SCRIPT" ] || {
        echo "missing scripts/check-package-ids.sh" >&2
        return 1
    }
    require_tool chezmoi
    STUBS="$TEST_TMP/stubs"
    LOG="$TEST_TMP/docker.log"
    IN="$TEST_TMP/docker.stdin"
    mkdir -p "$STUBS"
    : >"$LOG"
    ln -s "$(tool_path chezmoi)" "$STUBS/chezmoi"
    # The stub records, per call, the docker config it sees: its
    # directory, whether it holds a config.json, where its cli-plugins
    # link points, and DOCKER_CONTEXT.
    CFG_LOG="$TEST_TMP/docker-config.log"
    : >"$CFG_LOG"
    cat >"$STUBS/docker" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$LOG"
cfg=\${DOCKER_CONFIG:-}
json=no
[ -z "\$cfg" ] || [ ! -e "\$cfg/config.json" ] || json=yes
plugins=\$( [ -n "\$cfg" ] && [ -e "\$cfg/cli-plugins" ] && cd "\$cfg/cli-plugins" && pwd -P)
printf '%s\t%s\t%s\t%s\t%s\n' "\${1:-}" "\$cfg" "\$json" "\$plugins" "\${DOCKER_CONTEXT:-}" >>"$CFG_LOG"
case \${1:-} in
    context) [ "\${2:-}" != show ] || printf '%s\n' "\${DOCKER_CONTEXT:-\${STUB_CONTEXT:-default}}" ;;
    run) cat >"$IN"; exit "\${DOCKER_RUN_STATUS:-0}" ;;
esac
exit 0
EOF
    chmod +x "$STUBS/docker"
    TPATH="$STUBS:$BATS_FILE_TMPDIR/sysbin"
}

check() {
    run env PATH="$TPATH" sh "$SCRIPT" "$@"
}

run_line() {
    grep -E '^run( |$)' "$LOG"
}

@test "check-package-ids: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$SCRIPT")"
    run sh -n "$SCRIPT"
    expect_status 0
}

@test "check-package-ids: one fresh ubuntu:24.04 container, repo read-only, install-apt.sh check" {
    check "$FIXTURE"
    expect_status 0
    expect_equal "docker run calls" 1 "$(run_line | wc -l | tr -d ' ')"
    l=" $(run_line) "
    for want in ' --rm ' ' ubuntu:24.04 ' "$REPO_ROOT:/src:ro" 'install-apt.sh check'; do
        case $l in *"$want"*) ;; *) echo "docker run lacks '$want': $l" >&2; return 1 ;; esac
    done
    case $l in
        *' -i '* | *' --interactive '* | *' -i'[a-z]*' '*) ;;
        *) echo "docker run does not pass stdin (-i): $l" >&2; return 1 ;;
    esac
}

@test "check-package-ids: every repo and every apt id, unfiltered, reach the container" {
    check "$FIXTURE"
    expect_status 0
    got=$(grep -vE '^[[:space:]]*(#|$)' "$IN" | LC_ALL=C sort)
    want=$({
        printf 'package\t%s\n' common-tool work-tool personal-tool desktop-tool \
            work-headless-tool repo-a-tool repo-b-tool repo-b-extra
        printf 'repo\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' fixture-a \
            https://example.org/keys/fixture-a.asc \
            '0123456789ABCDEF0123456789ABCDEF01234567 76543210FEDCBA9876543210FEDCBA9876543210' \
            0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
            https://example.org/apt stable main 'amd64 arm64'
        printf 'repo\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' fixture-b \
            https://example.com/fixture-b.gpg 89ABCDEF0123456789ABCDEF0123456789ABCDEF \
            fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210 \
            'https://example.com/apt/ https://mirror.example.com/apt/' '*' '*' ''
    } | LC_ALL=C sort)
    expect_equal "data on docker's stdin" "$want" "$got"
}

@test "check-package-ids: defaults to the real packages.yaml" {
    [ -f "$REPO_ROOT/home/.chezmoidata/packages.yaml" ] || {
        echo "missing home/.chezmoidata/packages.yaml" >&2
        return 1
    }
    check
    expect_status 0
    for id in git gh ripgrep fzf glow file; do
        grep -qxF "package${TAB}$id" "$IN" || { echo "no package line for $id" >&2; return 1; }
    done
    for r in github-cli charm; do
        grep -qE "^repo${TAB}$r${TAB}" "$IN" || { echo "no repo line for $r" >&2; return 1; }
    done
}

@test "check-package-ids: a failing container fails the check" {
    export DOCKER_RUN_STATUS=1
    check "$FIXTURE"
    expect_failure
}

@test "check-package-ids: without docker it fails naming docker" {
    rm -f "$STUBS/docker"
    check "$FIXTURE"
    expect_failure
    expect_output_matches '[Dd]ocker'
}

# ------------------------------------------ docker config (decision 40)

# user_docker_config: a caller's docker config with auths, a context and
# CLI plugins; exported as DOCKER_CONFIG.
user_docker_config() {
    USER_CFG="$TEST_TMP/user-docker"
    mkdir -p "$USER_CFG/cli-plugins" "$USER_CFG/contexts"
    printf '{"auths": {"registry.example.com": {"auth": "ZmFrZTpmYWtl"}}, "currentContext": "ctx-test"}\n' \
        >"$USER_CFG/config.json"
    DOCKER_CONFIG=$USER_CFG
    STUB_CONTEXT=ctx-test
    export DOCKER_CONFIG STUB_CONTEXT
    unset DOCKER_CONTEXT DOCKER_HOST
}

# run_cfg <field>: field of the docker run call in the config log
# (2 dir, 3 config.json yes/no, 4 cli-plugins target, 5 DOCKER_CONTEXT).
run_cfg() {
    awk -F '\t' -v f="$1" '$1 == "run" { print $f; exit }' "$CFG_LOG"
}

@test "check-package-ids: docker runs with an empty temp DOCKER_CONFIG, not the caller's" {
    user_docker_config
    check "$FIXTURE"
    expect_status 0
    dir=$(run_cfg 2)
    [ -n "$dir" ] || { printf 'docker run without DOCKER_CONFIG; log:\n%s\n' "$(cat "$CFG_LOG")" >&2; return 1; }
    [ "$dir" != "$USER_CFG" ] || { echo "docker run used the caller's DOCKER_CONFIG" >&2; return 1; }
    expect_equal "config.json in the docker config of docker run" no "$(run_cfg 3)"
}

@test "check-package-ids: the temp docker config keeps the CLI plugins and the context" {
    user_docker_config
    check "$FIXTURE"
    expect_status 0
    expect_equal "cli-plugins seen by docker run" "$(cd "$USER_CFG/cli-plugins" && pwd -P)" "$(run_cfg 4)"
    expect_equal "DOCKER_CONTEXT seen by docker run" ctx-test "$(run_cfg 5)"
}

@test "check-package-ids: the temp docker config is removed after success and failure" {
    user_docker_config
    check "$FIXTURE"
    expect_status 0
    dir=$(run_cfg 2)
    [ -n "$dir" ] && [ ! -e "$dir" ] || { echo "temp docker config '$dir' left behind" >&2; return 1; }
    : >"$CFG_LOG"
    export DOCKER_RUN_STATUS=1
    check "$FIXTURE"
    expect_failure
    dir=$(run_cfg 2)
    [ -n "$dir" ] && [ ! -e "$dir" ] || { echo "temp docker config '$dir' left after a failure" >&2; return 1; }
}
