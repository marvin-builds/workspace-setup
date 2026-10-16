#!/usr/bin/env bats
# Static and stubbed checks for the system test (slice 3, criteria 12, 13).
# The system test itself needs Docker and runs with `tests/run.sh system`;
# here a stub docker records what run.sh asks of it. The contract is in the
# header of tests/system/run-in-container.sh.

load ../helpers/common

RUN="$REPO_ROOT/tests/run.sh"
SYS="$REPO_ROOT/tests/system"
CI="$REPO_ROOT/.github/workflows/ci.yml"

setup_file() {
    # System commands without docker.
    mkdir -p "$BATS_FILE_TMPDIR/sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            [ "$n" != docker ] || continue
            [ -e "$BATS_FILE_TMPDIR/sysbin/$n" ] || [ -L "$BATS_FILE_TMPDIR/sysbin/$n" ] ||
                ln -s "$f" "$BATS_FILE_TMPDIR/sysbin/$n"
        done
    done
}

setup() {
    ws_isolate
    SYSBIN="$BATS_FILE_TMPDIR/sysbin"
    STUBS="$TEST_TMP/stubs"
    mkdir -p "$STUBS"
    DOCKER_LOG="$TEST_TMP/docker.log"
    : >"$DOCKER_LOG"
    export DOCKER_LOG
    unset DOCKER_RUN_STATUS
    # Stub docker: one log line per call; `run` exits $DOCKER_RUN_STATUS.
    # The context each call sees goes to $DOCKER_CTX_LOG; `context show`
    # prints DOCKER_CONTEXT or else $STUB_CONTEXT; `run` with
    # DOCKER_RUN_KILL set sends TERM to its caller (run.sh).
    DOCKER_CTX_LOG="$TEST_TMP/docker-ctx.log"
    : >"$DOCKER_CTX_LOG"
    export DOCKER_CTX_LOG
    unset DOCKER_RUN_KILL STUB_CONTEXT DOCKER_CONTEXT
    cat >"$STUBS/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$DOCKER_LOG"
printf '%s %s\n' "${1:-}" "${DOCKER_CONTEXT:-}" >>"$DOCKER_CTX_LOG"
case ${1:-} in
    context)
        [ "${2:-}" != show ] || printf '%s\n' "${DOCKER_CONTEXT:-${STUB_CONTEXT:-default}}"
        ;;
    run)
        [ -z "${DOCKER_RUN_KILL:-}" ] || { kill -TERM "$PPID"; sleep 1; }
        exit "${DOCKER_RUN_STATUS:-0}"
        ;;
esac
exit 0
EOF
    chmod +x "$STUBS/docker"
}

# ------------------------------------------------------------ Dockerfile

@test "system: Dockerfile is ubuntu:24.04" {
    [ -f "$SYS/Dockerfile" ] || { echo "missing tests/system/Dockerfile" >&2; return 1; }
    grep -qE '^FROM[[:space:]]+ubuntu:24\.04([@[:space:]]|$)' "$SYS/Dockerfile" || {
        echo "Dockerfile is not FROM ubuntu:24.04" >&2
        return 1
    }
}

@test "system: image adds only sudo, curl and ca-certificates" {
    # Joins continuation lines, then lists the words after `install`.
    pkgs=$(sed -e ':a' -e '/\\$/N; s/\\\n//; ta' "$SYS/Dockerfile" |
        grep -E 'apt-get[^&;]* install' |
        sed -E 's/.*apt-get[^&;]* install//; s/[&;].*//' |
        tr ' ' '\n' | grep -vE '^(-.*|)$' | LC_ALL=C sort -u | tr '\n' ' ')
    expect_equal "packages" "ca-certificates curl sudo " "$pkgs"
    if grep -v '^[[:space:]]*#' "$SYS/Dockerfile" | grep -qw 'git'; then
        echo "Dockerfile mentions git" >&2
        return 1
    fi
}

@test "system: image runs as a non-root user with passwordless sudo" {
    # The sudo rule itself is proven at run time: run-in-container.sh fails
    # unless `sudo -n true` works as the image's user.
    grep -qF '/etc/sudoers.d/' "$SYS/Dockerfile" || {
        echo "no sudoers.d rule for the test user" >&2
        return 1
    }
    grep -qE '^sudo -n true([[:space:]]|$)' "$SYS/run-in-container.sh" || {
        echo "run-in-container.sh does not check non-interactive sudo" >&2
        return 1
    }
    user=$(awk '$1 == "USER" { u = $2 } END { print u }' "$SYS/Dockerfile")
    [ -n "$user" ] && [ "$user" != root ] && [ "$user" != 0 ] || {
        echo "the image's last USER is '$user', want a non-root user" >&2
        return 1
    }
}

# --------------------------------------------------- run-in-container.sh

@test "system: run-in-container.sh is POSIX sh and covers every step" {
    f="$SYS/run-in-container.sh"
    [ -f "$f" ] || { echo "missing tests/system/run-in-container.sh" >&2; return 1; }
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$f")"
    run sh -n "$f"
    expect_status 0
    for want in 'bootstrap.sh' 'ws doctor' 'chezmoi apply' 'chezmoi diff' \
        'delete-bucket --bucket=scriptState' 'delete-bucket --bucket=entryState' \
        'chezmoi verify' 'Form=container'; do
        grep -qF -- "$want" "$f" || { echo "run-in-container.sh lacks: $want" >&2; return 1; }
    done
}

@test "system: run-in-container.sh refuses an unknown role" {
    run sh "$SYS/run-in-container.sh" boss
    expect_status 2
}

@test "system: run-in-container.sh uses fake data only" {
    f="$SYS/run-in-container.sh"
    grep -qF "$OWNER1" "$f" && grep -qF "$OWNER2" "$f" || {
        echo "expected the fake owners $OWNER1 and $OWNER2" >&2
        return 1
    }
    # Every noreply address is one of the fake ones.
    other=$(grep -oE '[0-9]+\+[A-Za-z0-9-]+@users\.noreply\.github\.com' "$f" |
        grep -vxF -e "$EMAIL1" -e "$EMAIL2" || true)
    expect_equal "other emails" "" "$other"
}

# ------------------------------------------------------ run.sh system

@test "run.sh: usage lists the system mode" {
    run "$RUN"
    expect_failure
    expect_output_matches 'system'
}

@test "run.sh: system builds tests/system and runs each role with the repo read-only at /src" {
    run env PATH="$STUBS:$SYSBIN" "$RUN" system
    expect_status 0
    grep -E '(^| )build( |$)' "$DOCKER_LOG" | grep -qF 'tests/system' || {
        printf 'no docker build of tests/system; log:\n%s\n' "$(cat "$DOCKER_LOG")" >&2
        return 1
    }
    for role in personal work; do
        line=$(grep -E '^run ' "$DOCKER_LOG" | grep -E "run-in-container\.sh $role\$" || true)
        [ -n "$line" ] || {
            printf 'no docker run for role %s; log:\n%s\n' "$role" "$(cat "$DOCKER_LOG")" >&2
            return 1
        }
        case $line in
            *"$REPO_ROOT:/src:ro"* | *"source=$REPO_ROOT,target=/src,readonly"* | *"src=$REPO_ROOT,dst=/src,readonly"*) ;;
            *) echo "role $role: repo not mounted read-only at /src: $line" >&2; return 1 ;;
        esac
        case $line in
            *"--user root"* | *"-u root"* | *"--user 0"* | *"-u 0"*)
                echo "role $role runs as root: $line" >&2
                return 1
                ;;
        esac
    done
}

@test "run.sh: system fails when a container run fails" {
    DOCKER_RUN_STATUS=1
    export DOCKER_RUN_STATUS
    run env PATH="$STUBS:$SYSBIN" "$RUN" system
    expect_failure
}

@test "run.sh: system without docker fails naming docker" {
    run env PATH="$SYSBIN" "$RUN" system
    expect_failure
    expect_output_matches '[Dd]ocker'
}

# -------------------------------------------------------------- ci.yml

# job_block <id>: the lines of a top-level job in ci.yml.
job_block() {
    awk -v id="$1" '
        /^jobs:/ { injobs = 1; next }
        injobs && /^[^ #]/ { injobs = 0 }
        injobs && $0 ~ "^  " id ":[ ]*$" { injob = 1; print; next }
        injob && /^  [^ #]/ { injob = 0 }
        injob { print }
    ' "$CI"
}

@test "ci.yml: a job named system runs tests/run.sh system on ubuntu-latest" {
    block=$(job_block system)
    [ -n "$block" ] || { echo "ci.yml has no job 'system'" >&2; return 1; }
    printf '%s\n' "$block" | grep -qE 'runs-on:[[:space:]]*ubuntu-latest' || {
        echo "job system does not run on ubuntu-latest" >&2
        return 1
    }
    printf '%s\n' "$block" | grep -qE 'tests/run\.sh[[:space:]]+system' || {
        echo "job system does not run tests/run.sh system" >&2
        return 1
    }
}

@test "ci.yml: the system job's check name is stable (criterion 13)" {
    block=$(job_block system)
    [ -n "$block" ] || { echo "ci.yml has no job 'system'" >&2; return 1; }
    # No matrix (it would add suffixes) and no name other than "system".
    if printf '%s\n' "$block" | grep -qE '^[ ]+matrix:'; then
        echo "job system has a matrix" >&2
        return 1
    fi
    name=$(printf '%s\n' "$block" | awk '/^    name:/ { sub(/^    name:[ ]*/, ""); gsub(/["'\'']/, ""); print; exit }')
    [ -z "$name" ] || expect_equal "job name" system "$name"
}

# ------------------------------------ review round 1 (criterion 28)

# expect_tmp_clean: run.sh left nothing in TMPDIR (the temp Docker config).
expect_tmp_clean() {
    left=$(ls -A "$TMPDIR")
    expect_equal "left in TMPDIR" "" "$left"
}

@test "run.sh: system removes its temp Docker config after success and failure (control)" {
    run env PATH="$STUBS:$SYSBIN" "$RUN" system
    expect_status 0
    expect_tmp_clean
    DOCKER_RUN_STATUS=1
    export DOCKER_RUN_STATUS
    run env PATH="$STUBS:$SYSBIN" "$RUN" system
    expect_failure
    expect_tmp_clean
}

@test "run.sh: system removes its temp Docker config when killed (trap)" {
    DOCKER_RUN_KILL=1
    export DOCKER_RUN_KILL
    run env PATH="$STUBS:$SYSBIN" "$RUN" system
    expect_failure
    expect_tmp_clean
}

@test "run.sh: system sets a trap that removes the temp Docker config" {
    grep -qE '^[[:space:]]*trap[[:space:]].*rm -[a-z]*r' "$RUN" || {
        echo "tests/run.sh has no trap removing a temp dir" >&2
        return 1
    }
}

@test "run.sh: system passes the current Docker context on via DOCKER_CONTEXT" {
    user_cfg="$TEST_TMP/user-docker"
    mkdir -p "$user_cfg"
    printf '{"currentContext": "ctx-test"}\n' >"$user_cfg/config.json"
    STUB_CONTEXT=ctx-test
    export STUB_CONTEXT
    run env PATH="$STUBS:$SYSBIN" DOCKER_CONFIG="$user_cfg" "$RUN" system
    expect_status 0
    for cmd in build run; do
        bad=$(awk -v c="$cmd" '$1 == c && $2 != "ctx-test"' "$DOCKER_CTX_LOG")
        expect_equal "docker $cmd calls without DOCKER_CONTEXT=ctx-test" "" "$bad"
    done
    grep -qE '^(build|run) ctx-test$' "$DOCKER_CTX_LOG" || {
        printf 'no docker build or run seen; log:\n%s\n' "$(cat "$DOCKER_CTX_LOG")" >&2
        return 1
    }
}
