#!/usr/bin/env bats
# Tests for scripts/tools.lock and scripts/fetch-tools.sh (slice 2,
# criteria 1 and 2).
#
# Interface assumed (from the brief):
#
#   scripts/fetch-tools.sh [tool...]
#
#   Tool names are the lock's first column: betterleaks, chezmoi,
#   actionlint, shellcheck, bats-core. No arguments fetches all of them.
#   Binaries end up in <repo>/.cache/bin/ (bats-core as .cache/bin/bats).
#   The lock keeps one line per asset: <tool> <version> <platform> <sha256>;
#   platform keys are linux_amd64, linux_arm64, darwin_amd64, darwin_arm64
#   and windows_amd64 for every tool, Betterleaks included (its asset names
#   keep x64); bats-core has one line with the key `any`.
#
# Most tests run a copy of scripts/ in a temp "repo" with fake curl, wget,
# uname and extractors first on PATH, so they need no network: the fake
# download is junk, which must fail the checksum before anything is
# extracted. The "real fetch" tests download the pinned tools for the
# current platform into the repo's gitignored .cache/.

load ../helpers/common

LOCK="$REPO_ROOT/scripts/tools.lock"

setup() {
    ws_isolate
    ROOT="$TEST_TMP/root"
    FAKE="$TEST_TMP/fakebin"
    LOG="$TEST_TMP/download.log"
    XLOG="$TEST_TMP/extract.log"
    mkdir -p "$ROOT" "$FAKE"
    cp -R "$REPO_ROOT/scripts" "$ROOT/scripts"
    : >"$LOG"
    : >"$XLOG"
    make_fakes
}

# Fake downloaders log every call and write junk where the download should
# go. Fake extractors log and fail: none may run after a bad checksum.
# Fake uname answers -s and -m from FAKE_UNAME_S / FAKE_UNAME_M when set.
make_fakes() {
    real_uname=$(command -v uname)
    cat >"$FAKE/curl" <<EOF
#!/bin/sh
printf 'curl %s\n' "\$*" >>"$LOG"
[ -n "\${FAKE_DOWNLOAD_FAIL:-}" ] && exit 22
out=
while [ \$# -gt 0 ]; do
    case \$1 in
        -o | --output) out=\$2; shift ;;
        --output=*) out=\${1#--output=} ;;
    esac
    shift
done
if [ -n "\$out" ] && [ "\$out" != - ]; then
    printf 'not the real asset\n' >"\$out"
else
    printf 'not the real asset\n'
fi
EOF
    cat >"$FAKE/wget" <<EOF
#!/bin/sh
printf 'wget %s\n' "\$*" >>"$LOG"
[ -n "\${FAKE_DOWNLOAD_FAIL:-}" ] && exit 8
out=
while [ \$# -gt 0 ]; do
    case \$1 in
        -O) out=\$2; shift ;;
        -O*) out=\${1#-O} ;;
        -qO) out=\$2; shift ;;
        -qO*) out=\${1#-qO} ;;
        --output-document=*) out=\${1#--output-document=} ;;
    esac
    shift
done
if [ -n "\$out" ] && [ "\$out" != - ]; then
    printf 'not the real asset\n' >"\$out"
else
    printf 'not the real asset\n'
fi
EOF
    for x in tar unzip xz gzip bsdtar 7z; do
        cat >"$FAKE/$x" <<EOF
#!/bin/sh
printf '$x %s\n' "\$*" >>"$XLOG"
exit 1
EOF
    done
    cat >"$FAKE/uname" <<EOF
#!/bin/sh
case "\${1:-}" in
    -s) [ -n "\${FAKE_UNAME_S:-}" ] && { echo "\$FAKE_UNAME_S"; exit 0; } ;;
    -m) [ -n "\${FAKE_UNAME_M:-}" ] && { echo "\$FAKE_UNAME_M"; exit 0; } ;;
esac
exec "$real_uname" "\$@"
EOF
    chmod +x "$FAKE"/*
}

# fetch_fake <uname -s> <uname -m> <tool...>: runs the copied script with
# the fakes first on PATH.
fetch_fake() {
    s=$1
    m=$2
    shift 2
    run env PATH="$FAKE:$PATH" FAKE_UNAME_S="$s" FAKE_UNAME_M="$m" \
        "$ROOT/scripts/fetch-tools.sh" "$@"
}

# expect_bad_checksum_flow <binary> <asset suffix>: the run downloaded an
# asset whose URL ends in <asset suffix>, failed on the checksum, extracted
# nothing and installed nothing.
expect_bad_checksum_flow() {
    expect_failure
    expect_output_matches '[Cc]hecksum'
    grep -qF -- "$2" "$LOG" || {
        printf 'no download of %s; downloads:\n%s\n' "$2" "$(cat "$LOG")" >&2
        return 1
    }
    [ ! -s "$XLOG" ] || {
        printf 'extracted before the checksum passed:\n%s\n' "$(cat "$XLOG")" >&2
        return 1
    }
    [ ! -e "$ROOT/.cache/bin/$1" ] && [ ! -e "$ROOT/.cache/bin/$1.exe" ] || {
        echo "$1 installed despite a bad checksum" >&2
        return 1
    }
}

expect_no_download() {
    [ ! -s "$LOG" ] && return 0
    printf 'unexpected download:\n%s\n' "$(cat "$LOG")" >&2
    return 1
}

# ------------------------------------------------------------ tools.lock

# lock_has <tool> <version> <platform|*> <sha256>
lock_has() {
    awk -v t="$1" -v v="$2" -v p="$3" -v s="$4" '
        $1 == t && $2 == v && (p == "*" || $3 == p) && $4 == s && NF == 4 { found = 1 }
        END { exit !found }
    ' "$LOCK" && return 0
    echo "tools.lock lacks: $1 $2 $3 $4" >&2
    return 1
}

@test "tools.lock: chezmoi 2.73.1 for five platforms" {
    lock_has chezmoi 2.73.1 linux_amd64 a3f958acb7d0e5d53fa43c2eec9bc8ae3b4fba8bcbfdce29a8881ca3ffc20a53
    lock_has chezmoi 2.73.1 linux_arm64 e60275b27f505ae2086bfb87b144eacf7377a89803120f6bd933d1852a93b0c6
    lock_has chezmoi 2.73.1 darwin_amd64 0ec1869c60752644863bc4690878a290455f0d35c6e9b200ca4a822b35d2be54
    lock_has chezmoi 2.73.1 darwin_arm64 19a8d9778d90476cc2f0463be69e9d82e2b91ba7b2361dbfc5348f243b1ba731
    lock_has chezmoi 2.73.1 windows_amd64 29c48a8d403f590cfacf16fbf9db3c2dc0a8ebe8b744db64bac6057c0266c65d
}

@test "tools.lock: actionlint 1.7.12 for five platforms" {
    lock_has actionlint 1.7.12 linux_amd64 8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    lock_has actionlint 1.7.12 linux_arm64 325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6
    lock_has actionlint 1.7.12 darwin_amd64 5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
    lock_has actionlint 1.7.12 darwin_arm64 aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    lock_has actionlint 1.7.12 windows_amd64 6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9
}

@test "tools.lock: shellcheck 0.11.0 for four platforms" {
    lock_has shellcheck 0.11.0 linux_amd64 8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198
    lock_has shellcheck 0.11.0 linux_arm64 12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588
    lock_has shellcheck 0.11.0 darwin_amd64 3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6
    lock_has shellcheck 0.11.0 darwin_arm64 56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79
}

@test "tools.lock: bats-core 1.14.0 source tarball under key any" {
    lock_has bats-core 1.14.0 any bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177
}

@test "tools.lock: betterleaks 1.9.0 checksums kept under normalised keys" {
    lock_has betterleaks 1.9.0 linux_arm64 1d39116e0a58dc94574715e2aa12a2dbd5062f193eee3fec011fef6ba06bd13b
    lock_has betterleaks 1.9.0 linux_amd64 f8b185a39ffcece2a1ca82bf3a4e7435cd81963ffd16b7a9128daf75f35f6de7
    lock_has betterleaks 1.9.0 darwin_arm64 83dd7eaab13d44a1e8e347a17064cdef153a1478db473276d41b38d55613d3f2
    lock_has betterleaks 1.9.0 darwin_amd64 68dfd83458d9e7f90663daa7a81c7f944083b170dae82e4f5f8d0581ed519ef1
}

@test "tools.lock: every entry has four fields and a sha256" {
    bad=$(awk '
        /^[ \t]*(#|$)/ { next }
        NF != 4 || $4 !~ /^[0-9a-f]+$/ || length($4) != 64 { print NR ": " $0 }
    ' "$LOCK")
    expect_equal "malformed lock lines" "" "$bad"
}

@test "tools.lock: platform keys are normalised" {
    bad=$(awk '
        /^[ \t]*(#|$)/ { next }
        $1 == "bats-core" { if ($3 != "any") print NR ": " $0; next }
        $3 !~ /^(linux_amd64|linux_arm64|darwin_amd64|darwin_arm64|windows_amd64)$/ { print NR ": " $0 }
    ' "$LOCK")
    expect_equal "lines with a non-normalised platform key" "" "$bad"
}

@test "tools.lock: one line per tool and platform" {
    dups=$(awk '!/^[ \t]*(#|$)/ { print $1, $3 }' "$LOCK" | sort | uniq -d)
    expect_equal "duplicate tool/platform lines" "" "$dups"
}

# ------------------------------------------- checksum before extraction

@test "fetch-tools: chezmoi linux amd64 checksum mismatch fails before extraction" {
    fetch_fake Linux x86_64 chezmoi
    expect_bad_checksum_flow chezmoi chezmoi_2.73.1_linux_amd64.tar.gz
}

@test "fetch-tools: chezmoi linux arm64 asset name" {
    fetch_fake Linux aarch64 chezmoi
    expect_bad_checksum_flow chezmoi chezmoi_2.73.1_linux_arm64.tar.gz
}

@test "fetch-tools: chezmoi darwin arm64 asset name" {
    fetch_fake Darwin arm64 chezmoi
    expect_bad_checksum_flow chezmoi chezmoi_2.73.1_darwin_arm64.tar.gz
}

@test "fetch-tools: chezmoi on Git Bash (MINGW64) uses the windows_amd64 zip" {
    fetch_fake MINGW64_NT-10.0-19045 x86_64 chezmoi
    expect_bad_checksum_flow chezmoi chezmoi_2.73.1_windows_amd64.zip
}

@test "fetch-tools: chezmoi on MSYS uses the windows_amd64 zip" {
    fetch_fake MSYS_NT-10.0-19045 x86_64 chezmoi
    expect_bad_checksum_flow chezmoi chezmoi_2.73.1_windows_amd64.zip
}

@test "fetch-tools: actionlint linux amd64 checksum mismatch fails before extraction" {
    fetch_fake Linux x86_64 actionlint
    expect_bad_checksum_flow actionlint actionlint_1.7.12_linux_amd64.tar.gz
}

@test "fetch-tools: actionlint darwin amd64 asset name" {
    fetch_fake Darwin x86_64 actionlint
    expect_bad_checksum_flow actionlint actionlint_1.7.12_darwin_amd64.tar.gz
}

@test "fetch-tools: actionlint on Git Bash uses the windows_amd64 zip" {
    fetch_fake MINGW64_NT-10.0-19045 x86_64 actionlint
    expect_bad_checksum_flow actionlint actionlint_1.7.12_windows_amd64.zip
}

@test "fetch-tools: shellcheck linux x86_64 checksum mismatch fails before extraction" {
    fetch_fake Linux x86_64 shellcheck
    expect_bad_checksum_flow shellcheck shellcheck-v0.11.0.linux.x86_64.tar.xz
}

@test "fetch-tools: shellcheck linux aarch64 asset name" {
    fetch_fake Linux aarch64 shellcheck
    expect_bad_checksum_flow shellcheck shellcheck-v0.11.0.linux.aarch64.tar.xz
}

@test "fetch-tools: shellcheck darwin aarch64 asset name" {
    fetch_fake Darwin arm64 shellcheck
    expect_bad_checksum_flow shellcheck shellcheck-v0.11.0.darwin.aarch64.tar.xz
}

@test "fetch-tools: shellcheck on Git Bash fails clearly without downloading" {
    fetch_fake MINGW64_NT-10.0-19045 x86_64 shellcheck
    expect_failure
    expect_output_matches 'windows_amd64|[Ww]indows|platform'
    expect_no_download
    [ ! -s "$XLOG" ]
}

@test "fetch-tools: bats-core checksum mismatch fails before extraction" {
    fetch_fake Linux x86_64 bats-core
    expect_bad_checksum_flow bats v1.14.0.tar.gz
    grep -qF bats-core "$LOG"
}

@test "fetch-tools: betterleaks keeps its asset naming" {
    fetch_fake Linux x86_64 betterleaks
    expect_bad_checksum_flow betterleaks betterleaks_1.9.0_linux_x64.tar.gz
}

# -------------------------------------------------- unknown inputs

@test "fetch-tools: unknown OS fails clearly without downloading" {
    fetch_fake SunOS x86_64 chezmoi
    expect_failure
    expect_output_matches '[Uu]nsupported|[Uu]nknown'
    expect_output_matches 'SunOS'
    expect_no_download
}

@test "fetch-tools: unknown CPU fails clearly without downloading" {
    fetch_fake Linux riscv64 chezmoi
    expect_failure
    expect_output_matches '[Uu]nsupported|[Uu]nknown'
    expect_output_matches 'riscv64'
    expect_no_download
}

@test "fetch-tools: unknown tool name fails without downloading" {
    fetch_fake Linux x86_64 no-such-tool
    expect_failure
    expect_output_matches 'no-such-tool'
    expect_no_download
}

@test "fetch-tools: failed download fails and installs nothing" {
    run env PATH="$FAKE:$PATH" FAKE_UNAME_S=Linux FAKE_UNAME_M=x86_64 \
        FAKE_DOWNLOAD_FAIL=1 "$ROOT/scripts/fetch-tools.sh" chezmoi
    expect_failure
    [ ! -s "$XLOG" ]
    [ ! -e "$ROOT/.cache/bin/chezmoi" ]
}

@test "fetch-tools: stale cached version is replaced, not reused" {
    mkdir -p "$ROOT/.cache/bin"
    cat >"$ROOT/.cache/bin/chezmoi" <<'EOF'
#!/bin/sh
echo 'chezmoi version v2.0.0, commit 0000000, built at 2020-01-01T00:00:00Z'
EOF
    chmod +x "$ROOT/.cache/bin/chezmoi"
    fetch_fake Linux x86_64 chezmoi
    expect_failure
    expect_output_matches '[Cc]hecksum'
    grep -qF chezmoi_2.73.1_linux_amd64.tar.gz "$LOG" || {
        echo "stale chezmoi was not re-downloaded" >&2
        return 1
    }
    [ ! -s "$XLOG" ]
}

# ---------------------------------------- real fetch (current platform)

# The real fetch writes to the repo's own gitignored .cache/.
real_fetch() {
    run "$REPO_ROOT/scripts/fetch-tools.sh" "$@"
    expect_status 0
}

@test "fetch-tools: real chezmoi fetch installs version 2.73.1" {
    real_fetch chezmoi
    require_tool chezmoi
    run "$(tool_path chezmoi)" --version
    expect_status 0
    expect_output_matches '2\.73\.1'
}

@test "fetch-tools: real actionlint fetch installs version 1.7.12" {
    real_fetch actionlint
    require_tool actionlint
    run "$(tool_path actionlint)" -version
    expect_status 0
    expect_output_matches '1\.7\.12'
}

@test "fetch-tools: real shellcheck fetch installs version 0.11.0" {
    real_fetch shellcheck
    require_tool shellcheck
    run "$(tool_path shellcheck)" --version
    expect_status 0
    expect_output_matches '0\.11\.0'
}

@test "fetch-tools: real bats-core fetch installs bats 1.14.0" {
    real_fetch bats-core
    require_tool bats
    run "$TOOLS_BIN/bats" --version
    expect_status 0
    expect_output_matches '1\.14\.0'
}

@test "fetch-tools: cached matching version is reused without downloading" {
    real_fetch chezmoi
    require_tool chezmoi
    mkdir -p "$ROOT/.cache/bin"
    cp "$(tool_path chezmoi)" "$ROOT/.cache/bin/"
    run env PATH="$FAKE:$PATH" FAKE_DOWNLOAD_FAIL=1 \
        "$ROOT/scripts/fetch-tools.sh" chezmoi
    expect_status 0
    expect_no_download
}

@test "fetch-tools: no arguments covers every tool" {
    real_fetch
    for t in betterleaks chezmoi actionlint shellcheck bats; do
        [ -x "$TOOLS_BIN/$t" ] || [ -x "$TOOLS_BIN/$t.exe" ] || {
            echo "no-argument fetch left out $t" >&2
            return 1
        }
    done
    # With everything cached, a no-argument run downloads nothing ...
    rm -rf "$ROOT/.cache"
    cp -R "$REPO_ROOT/.cache" "$ROOT/.cache"
    run env PATH="$FAKE:$PATH" FAKE_DOWNLOAD_FAIL=1 "$ROOT/scripts/fetch-tools.sh"
    expect_status 0
    expect_no_download
    # ... and a missing tool is fetched by it.
    for pair in chezmoi:chezmoi_2.73.1 actionlint:actionlint_1.7.12 \
        shellcheck:shellcheck-v0.11.0 betterleaks:betterleaks_1.9.0; do
        t=${pair%%:*}
        asset=${pair#*:}
        rm -rf "$ROOT/.cache"
        cp -R "$REPO_ROOT/.cache" "$ROOT/.cache"
        rm -f "$ROOT/.cache/bin/$t" "$ROOT/.cache/bin/$t.exe"
        : >"$LOG"
        run env PATH="$FAKE:$PATH" "$ROOT/scripts/fetch-tools.sh"
        grep -qF "$asset" "$LOG" || {
            printf 'no-argument run did not fetch missing %s; downloads:\n%s\n' "$t" "$(cat "$LOG")" >&2
            return 1
        }
    done
}
