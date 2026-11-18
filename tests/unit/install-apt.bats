#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2030,SC2031 # stub bodies and $(...) test data are literal; per-test exports
# Unit tests for scripts/install-apt.sh (slice 5, criteria 8-11 and 16),
# run directly with stubs; nothing reaches the real sudo, apt or /etc/apt.
#
# Interface (the implementation follows this):
#
#   scripts/install-apt.sh install <data      add the repos, install the ids
#   scripts/install-apt.sh check <data        add the repos, apt-get update,
#                                             report ids without a candidate
#
#   No or another mode: usage error, exit 2, nothing done. POSIX sh, run as
#   the normal user; every privileged command goes through `sudo <command>`
#   (no sudo options).
#
#   Data on stdin, one record per line, fields separated by one tab, empty
#   lines and lines starting with # ignored:
#
#     repo<TAB><name><TAB><key_url><TAB><fingerprints><TAB><key_sha256><TAB><uris><TAB><suites><TAB><components><TAB><architectures>
#     package<TAB><apt id>
#
#   key_url, fingerprints and key_sha256 come from an apt_repos entry's
#   key.url, key.fingerprints and key.sha256 in packages.yaml (decision 47).
#
#   fingerprints, uris, suites, components and architectures hold one or
#   more values separated by single spaces; architectures may be empty (no
#   Architectures field). Every line is validated before anything is
#   downloaded, installed or written: kind repo (9 fields) or package (2
#   fields); name [a-z0-9-]+, unique; key_url and every uri
#   https://<no whitespace>; each fingerprint [0-9A-F]{40}, unique;
#   key_sha256 [0-9a-f]{64}; id
#   [a-z0-9][a-z0-9+.-]+. A bad line: exit non-zero naming "line <n>",
#   nothing called. Data is never evaluated as code: values are only ever
#   arguments or file content (a suite `*` stays `*`).
#
#   Paths: $WS_APT_ROOT (test-only override, default empty) is prefixed to
#   /etc/apt/keyrings/ws-<name>.gpg and
#   /etc/apt/sources.list.d/ws-<name>.sources. The Signed-By field always
#   names the unprefixed /etc/apt/keyrings/ws-<name>.gpg.
#
#   Per repo: the key is downloaded with curl (https only) to a temp file,
#   dearmored with `gpg --dearmor` when it holds
#   "-----BEGIN PGP PUBLIC KEY BLOCK-----", and the set of its primary key
#   fingerprints (the fpr right after each pub in `gpg --show-keys
#   --with-colons`; subkey fprs don't count) must equal the set in the
#   data exactly: no pinned key missing, no extra key (decision 32), and
#   the sha256 of the downloaded file as served must equal key_sha256
#   (decision 42).
#   Every repo's key is verified
#   before the first write: a failed download or a mismatch exits non-zero
#   naming the repo, and nothing is written for any repo.
#   Then the keyring (binary) and a deb822 .sources file
#   (Types: deb, URIs, Suites, Components, [Architectures], Signed-By) are
#   written only when their content differs: through a temp file in the
#   target directory and `sudo mv` onto the final name, mode 644, owner
#   set with `sudo chown root:root` (not `install -o`, which the stubs
#   can't fake).
#
#   Foreign sources (decision 35): in the same pass as the key checks,
#   before anything is written or apt-get is called, every repo's URIs are
#   looked up in $WS_APT_ROOT/etc/apt/sources.list,
#   sources.list.d/*.list and sources.list.d/*.sources, except the ws-*
#   files; a trailing / is ignored, commented-out lines don't count. A
#   match exits non-zero naming the repo and the file (its base name).
#   Rollback: when `apt-get update` fails after this run created or
#   replaced repo files, created files are removed, replaced ones get
#   their old content back, and the run fails.
#
#   No download when nothing changed (decision 36): a repo whose keyring
#   on disk passes the fingerprint-set check and whose .sources matches is
#   not downloaded; a keyring on disk that fails the check is downloaded
#   and replaced. The .sources file holds a comment line with the pinned
#   key_sha256 (decision 42), so a bumped pin changes the .sources and
#   forces a download.
#
#   Foreign .sources files are read stanza by stanza: a stanza with
#   `Enabled: no` doesn't count (decision 43), and a field name is
#   stripped also without a space after the colon (`URIs:https://...`,
#   decision 44). A failed write removes its own temp file, also when a
#   rollback follows (decision 45): only ws-<name>.gpg and
#   ws-<name>.sources files remain under the apt directories.
#
#   apt: installed means a dpkg status line ending in " ok installed"
#   (decision 38: "hold ok installed" too, and one line per architecture
#   for multi-arch packages); candidates come from `apt-cache policy`, run
#   with LC_ALL=C (decision 39). When the data has a repo, the tools gpg,
#   curl and ca-certificates (packages of those names) are installed
#   first, through the same check, when they aren't installed (criterion
#   10, decision 37); data without repos needs no tools. `apt-get
#   update` runs only when a repo file was written or a wanted id has no
#   candidate; `apt-get install -y --no-install-recommends <ids>` only for
#   ids not installed. With everything in place a run calls no sudo at
#   all (decided with the test writer: no password prompt on a no-op).
#   apt-get missing: exit non-zero naming apt-get, nothing called. A
#   failing apt-get exits non-zero.
#
#   check mode: adds the repos like install, runs `apt-get update` once,
#   then exits 1 listing each id whose `apt-cache policy` shows no
#   candidate (one per line, the id in the line), else 0. It never
#   installs a package id (the tools may be installed).
#
# Stubs (on PATH before a copy of the system commands without sudo, apt,
# apt-get, apt-cache, dpkg, dpkg-query, gpg, gpgv, curl, wget, chown):
#   sudo        logs, drops leading -options, makes the directories under
#               $WS_APT_ROOT writable, runs the command marked as
#               privileged, makes them read-only again. Without sudo no
#               file can be created, renamed or removed there.
#   apt-get     refuses to run unless privileged; update marks the lists
#               updated (fails with STUB_UPDATE_FAIL set); install marks
#               ids installed, unknown ids fail. STUB_APT_FAIL fails all.
#   apt-cache   policy: "Candidate: 1.0" for ids in $STATE/available, and
#               after an update also in $STATE/after-update; "Candidate:
#               (none)" for ids in $STATE/nocandidate; nothing else. Unless
#               LC_ALL=C, it answers in German, like apt in a German locale.
#   dpkg-query  -W [-f FMT] / -s for ids in $STATE/installed. Status
#               "install ok installed", or with STUB_STATUS_STYLE=hold
#               "hold ok installed", or with STUB_STATUS_STYLE=multiarch
#               one entry per architecture (amd64, i386).
#   gpg         --dearmor and --show-keys on fake key files: one FAKEKEY
#               (armored) or FAKEBIN (binary) line per primary key.
#   curl        serves $STATE/urls (url<TAB>file); other urls fail (22).
#   chown       refuses unless privileged; logs the inode of each path.

load ../helpers/common

SCRIPT="$REPO_ROOT/scripts/install-apt.sh"
TAB=$(printf '\t')

FPR_A=1111111111111111111111111111111111111111
SUB_A=2222222222222222222222222222222222222222
FPR_B=3333333333333333333333333333333333333333
SUB_B=4444444444444444444444444444444444444444
FPR_X=5555555555555555555555555555555555555555
SHA_X=abababababababababababababababababababababababababababababababab
FPR_G1=6666666666666666666666666666666666666666
SUB_G1=7777777777777777777777777777777777777777
FPR_G2=8888888888888888888888888888888888888888
SUB_G2=9999999999999999999999999999999999999999
URL_A=https://example.org/keys/alpha.asc
URL_B=https://example.com/beta.gpg
URL_G=https://example.net/gamma.asc

setup_file() {
    sysbin="$BATS_FILE_TMPDIR/sysbin"
    mkdir -p "$sysbin"
    for d in /usr/local/bin /usr/bin /bin; do
        [ -d "$d" ] || continue
        for f in "$d"/*; do
            n=${f##*/}
            case $n in
                sudo | apt | apt-get | apt-cache | dpkg | dpkg-query | gpg | gpgv | \
                    gpg2 | curl | wget | chown | su | doas) continue ;;
            esac
            [ -e "$sysbin/$n" ] || [ -L "$sysbin/$n" ] || ln -s "$f" "$sysbin/$n"
        done
    done
}

setup() {
    ws_isolate
    [ -f "$SCRIPT" ] || {
        echo "missing scripts/install-apt.sh" >&2
        return 1
    }
    STATE="$TEST_TMP/state"
    STUBS="$TEST_TMP/stubs"
    KEYS="$TEST_TMP/keys"
    APT_ROOT="$TEST_TMP/aptroot"
    CANARY="$TEST_TMP/canary"
    WORK="$TEST_TMP/work"
    mkdir -p "$STATE" "$STUBS" "$KEYS" "$APT_ROOT" "$WORK"
    : >"$STATE/calls.log"
    : >"$STATE/chown.log"
    : >"$STATE/installed"
    : >"$STATE/available"
    : >"$STATE/after-update"
    : >"$STATE/nocandidate"
    : >"$STATE/urls"
    # Files a glob in the working directory would expand to.
    touch "$WORK/glob-a" "$WORK/glob-b"
    make_stubs
    make_keys
    TPATH="$STUBS:$BATS_FILE_TMPDIR/sysbin"
    KR="$APT_ROOT/etc/apt/keyrings"
    SL="$APT_ROOT/etc/apt/sources.list.d"
    lock_root
}

# lock_root / unlock_root: the directories under the apt root are
# read-only except inside a sudo call, so only privileged commands can
# create, rename or remove files there. File modes are left alone.
lock_root() {
    find "$APT_ROOT" -type d -exec chmod a-w {} +
}

unlock_root() {
    find "$APT_ROOT" -type d -exec chmod u+w {} +
}

teardown() {
    chmod -R u+w "$TEST_TMP" 2>/dev/null || true
}

make_stubs() {
    cat >"$STUBS/sudo" <<EOF
#!/bin/sh
printf 'sudo %s\n' "\$*" >>"$STATE/calls.log"
while [ \$# -gt 0 ]; do
    case \$1 in
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
find "$APT_ROOT" -type d -exec chmod u+w {} +
env STUB_PRIVILEGED=1 "\$@"
rc=\$?
find "$APT_ROOT" -type d -exec chmod a-w {} +
exit \$rc
EOF
    cat >"$STUBS/apt-get" <<EOF
#!/bin/sh
printf 'apt-get%s %s\n' "\${STUB_PRIVILEGED:+(sudo)}" "\$*" >>"$STATE/calls.log"
[ -n "\${STUB_PRIVILEGED:-}" ] || { echo "E: apt-get needs root" >&2; exit 100; }
[ -z "\${STUB_APT_FAIL:-}" ] || exit 100
sub=
skip=
for a in "\$@"; do
    if [ -n "\$skip" ]; then skip=; continue; fi
    case \$a in
        -o | -c | -t | --option | --config-file | --target-release) skip=1 ;;
        -*) ;;
        *) if [ -z "\$sub" ]; then sub=\$a; elif [ "\$sub" = install ]; then
               if grep -qxF -- "\$a" "$STATE/available" ||
                   { [ -e "$STATE/updated" ] && grep -qxF -- "\$a" "$STATE/after-update"; }; then
                   printf '%s\n' "\$a" >>"$STATE/installed"
               else
                   echo "E: Unable to locate package \$a" >&2
                   exit 100
               fi
           fi ;;
    esac
done
case \$sub in
    update)
        [ -z "\${STUB_UPDATE_FAIL:-}" ] || { echo "E: The repository is not signed." >&2; exit 100; }
        touch "$STATE/updated" ;;
    install) ;;
    *) echo "apt-get stub: unsupported '\$sub'" >&2; exit 100 ;;
esac
exit 0
EOF
    cat >"$STUBS/apt-cache" <<EOF
#!/bin/sh
printf 'apt-cache %s\n' "\$*" >>"$STATE/calls.log"
[ "\${1:-}" = policy ] || { echo "apt-cache stub: only policy" >&2; exit 100; }
shift
if [ "\${LC_ALL:-}" = C ]; then
    l_inst=Installed l_cand=Candidate l_none='(none)' l_table='Version table'
else
    l_inst=Installiert l_cand=Installationskandidat l_none='(keine)' l_table=Versionstabelle
fi
for id in "\$@"; do
    case \$id in -*) continue ;; esac
    if grep -qxF -- "\$id" "$STATE/available" ||
        { [ -e "$STATE/updated" ] && grep -qxF -- "\$id" "$STATE/after-update"; }; then
        if grep -qxF -- "\$id" "$STATE/installed"; then inst=1.0; else inst=\$l_none; fi
        printf '%s:\n  %s: %s\n  %s: 1.0\n  %s:\n     1.0 500\n        500 https://example.org/apt stable/main amd64 Packages\n' \
            "\$id" "\$l_inst" "\$inst" "\$l_cand" "\$l_table"
    elif grep -qxF -- "\$id" "$STATE/nocandidate"; then
        printf '%s:\n  %s: %s\n  %s: %s\n  %s:\n' "\$id" "\$l_inst" "\$l_none" "\$l_cand" "\$l_none" "\$l_table"
    else
        echo "N: Unable to locate package \$id" >&2
    fi
done
exit 0
EOF
    cat >"$STUBS/dpkg-query" <<EOF
#!/bin/sh
printf 'dpkg-query %s\n' "\$*" >>"$STATE/calls.log"
mode=
fmt='\${binary:Package}\t\${Version}\n'
while [ \$# -gt 0 ]; do
    case \$1 in
        -W | --show) mode=W ;;
        -s | --status) mode=s ;;
        -f | --showformat) fmt=\$2; shift ;;
        -f*) fmt=\${1#-f}; fmt=\${fmt#=} ;;
        --showformat=*) fmt=\${1#--showformat=} ;;
        --) shift; break ;;
        -*) echo "dpkg-query stub: unsupported \$1" >&2; exit 2 ;;
        *) break ;;
    esac
    shift
done
case \${STUB_STATUS_STYLE:-} in
    hold) want=hold abbrev='hi ' archs=amd64 ;;
    multiarch) want=install abbrev='ii ' archs='amd64 i386' ;;
    *) want=install abbrev='ii ' archs= ;;
esac
rc=0
for id in "\$@"; do
    if grep -qxF -- "\$id" "$STATE/installed"; then
        for arch in \${archs:-amd64}; do
            name=\$id
            [ -z "\$archs" ] || [ "\${STUB_STATUS_STYLE:-}" != multiarch ] || name=\$id:\$arch
            if [ "\$mode" = s ]; then
                printf 'Package: %s\nStatus: %s ok installed\nArchitecture: %s\nVersion: 1.0\n\n' "\$id" "\$want" "\$arch"
            else
                out=\$(printf '%s' "\$fmt" | sed \
                    -e "s/\\\${Status}/\$want ok installed/g" \
                    -e "s/\\\${db:Status-Status}/installed/g" \
                    -e "s/\\\${db:Status-Want}/\$want/g" \
                    -e "s/\\\${db:Status-Abbrev}/\$abbrev/g" \
                    -e "s/\\\${binary:Package}/\$name/g" \
                    -e "s/\\\${Package}/\$id/g" \
                    -e "s/\\\${Architecture}/\$arch/g" \
                    -e "s/\\\${Version}/1.0/g")
                printf '%b' "\$out"
            fi
        done
    else
        echo "dpkg-query: no packages found matching \$id" >&2
        rc=1
    fi
done
exit \$rc
EOF
    cat >"$STUBS/gpg" <<EOF
#!/bin/sh
printf 'gpg %s\n' "\$*" >>"$STATE/calls.log"
op=
colons=
out=
in=
while [ \$# -gt 0 ]; do
    case \$1 in
        --dearmor) op=dearmor ;;
        --show-keys) op=show ;;
        --import-options) case \$2 in *show-only*) op=show ;; esac; shift ;;
        --import) [ -n "\$op" ] || op=import ;;
        --with-colons) colons=1 ;;
        -o | --output) out=\$2; shift ;;
        --output=*) out=\${1#--output=} ;;
        --homedir | --keyring | --list-options | --status-fd) shift ;;
        -) ;;
        -*) ;;
        *) in=\$1 ;;
    esac
    shift
done
if [ -n "\$in" ]; then data=\$(cat -- "\$in") || exit 2; else data=\$(cat); fi
lines=\$(printf '%s\n' "\$data" | grep -E '^FAKE(KEY|BIN) ')
armored=
printf '%s\n' "\$data" | grep -qxF -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' && armored=1
[ -n "\$lines" ] || { echo "gpg: no valid OpenPGP data found." >&2; exit 2; }
# One FAKE line per primary key: FAKE(KEY|BIN) <fpr> <subkey fpr> <label>.
case \$op in
    dearmor)
        [ -n "\$armored" ] || { echo "gpg: dearmoring failed: invalid armor" >&2; exit 2; }
        bin=\$(printf '%s\n' "\$lines" | sed 's/^FAKEKEY /FAKEBIN /')
        if [ -n "\$out" ] && [ "\$out" != - ]; then
            printf '%s\n' "\$bin" >"\$out"
        else
            printf '%s\n' "\$bin"
        fi
        ;;
    show)
        printf '%s\n' "\$lines" | while read -r _ fpr sub label; do
            if [ -n "\$colons" ]; then
                printf 'pub:-:4096:1:%s:1700000000:::-:::scSC::::::23::0:\n' "\$(printf %s "\$fpr" | cut -c25-40)"
                printf 'fpr:::::::::%s:\n' "\$fpr"
                printf 'uid:-::::1700000000::0000000000000000000000000000000000000000::Fake Key %s::::::::::0:\n' "\$label"
                printf 'sub:-:4096:1:%s:1700000000::::::e::::::23:\n' "\$(printf %s "\$sub" | cut -c25-40)"
                printf 'fpr:::::::::%s:\n' "\$sub"
            else
                printf 'pub   rsa4096 2023-11-14 [SC]\n      %s\nuid                      Fake Key %s\nsub   rsa4096 2023-11-14 [E]\n\n' "\$fpr" "\$label"
            fi
        done
        ;;
    *) echo "gpg stub: unsupported call" >&2; exit 2 ;;
esac
EOF
    cat >"$STUBS/curl" <<EOF
#!/bin/sh
out=
url=
while [ \$# -gt 0 ]; do
    case \$1 in
        -o | --output) out=\$2; shift ;;
        --output=*) out=\${1#--output=} ;;
        -H | --header | --proto | --retry | --max-time | -m | --connect-timeout | \
            -w | --write-out | -A | --user-agent | --retry-delay | --retry-max-time) shift ;;
        https://*) url=\$1 ;;
        http://* | ftp://*) url=\$1 ;;
    esac
    shift
done
printf 'curl %s\n' "\$url" >>"$STATE/calls.log"
src=\$(awk -F '\t' -v u="\$url" '\$1 == u { print \$2; exit }' "$STATE/urls")
[ -n "\$src" ] && [ -f "\$src" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
if [ -n "\$out" ] && [ "\$out" != - ]; then cat "\$src" >"\$out"; else cat "\$src"; fi
EOF
    cat >"$STUBS/chown" <<EOF
#!/bin/sh
printf 'chown%s %s\n' "\${STUB_PRIVILEGED:+(sudo)}" "\$*" >>"$STATE/calls.log"
[ -n "\${STUB_PRIVILEGED:-}" ] || { echo "chown: Operation not permitted" >&2; exit 1; }
owner=
for a in "\$@"; do
    case \$a in
        -*) ;;
        *) if [ -z "\$owner" ]; then owner=\$a; else
               printf '%s %s %s\n' "\$owner" "\$(stat -c %i -- "\$a")" "\$a" >>"$STATE/chown.log"
           fi ;;
    esac
done
exit 0
EOF
    chmod +x "$STUBS"/*
}

# make_keys: alpha armored, beta binary, gamma armored with two primary
# keys (like GitHub's keyring), all served by the curl stub.
make_keys() {
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nFAKEKEY %s %s alpha\n-----END PGP PUBLIC KEY BLOCK-----\n' \
        "$FPR_A" "$SUB_A" >"$KEYS/alpha.asc"
    printf 'FAKEBIN %s %s alpha\n' "$FPR_A" "$SUB_A" >"$KEYS/alpha.bin"
    printf 'FAKEBIN %s %s beta\n' "$FPR_B" "$SUB_B" >"$KEYS/beta.gpg"
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nFAKEKEY %s %s gamma-old\nFAKEKEY %s %s gamma-new\n-----END PGP PUBLIC KEY BLOCK-----\n' \
        "$FPR_G1" "$SUB_G1" "$FPR_G2" "$SUB_G2" >"$KEYS/gamma.asc"
    printf 'FAKEBIN %s %s gamma-old\nFAKEBIN %s %s gamma-new\n' "$FPR_G1" "$SUB_G1" "$FPR_G2" "$SUB_G2" >"$KEYS/gamma.bin"
    printf '%s\t%s\n%s\t%s\n%s\t%s\n' "$URL_A" "$KEYS/alpha.asc" "$URL_B" "$KEYS/beta.gpg" \
        "$URL_G" "$KEYS/gamma.asc" >"$STATE/urls"
    key_hashes
}

# key_hashes: SHA_A, SHA_B, SHA_G, the sha256 of each key file as served.
key_hashes() {
    SHA_A=$(sha256sum "$KEYS/alpha.asc" | cut -d ' ' -f 1)
    SHA_B=$(sha256sum "$KEYS/beta.gpg" | cut -d ' ' -f 1)
    SHA_G=$(sha256sum "$KEYS/gamma.asc" | cut -d ' ' -f 1)
}

# repo_line <name> <url> <fprs> <sha256> <uris> <suites> <components> <archs>
repo_line() {
    printf 'repo\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"
}

# ALPHA_REPO / GAMMA_REPO / BETA_REPO [<fprs> [<sha256>]]: the repo line
# with the key's real fingerprints and sha256 unless given.
ALPHA_REPO() { repo_line alpha "$URL_A" "${1:-$FPR_A}" "${2:-$SHA_A}" https://example.org/apt stable main 'amd64 arm64'; }
GAMMA_REPO() { repo_line gamma "$URL_G" "${1:-$FPR_G1 $FPR_G2}" "${2:-$SHA_G}" https://example.net/apt stable main ''; }
BETA_REPO() { repo_line beta "$URL_B" "${1:-$FPR_B}" "${2:-$SHA_B}" 'https://example.com/apt/ https://mirror.example.com/apt/' '*' '*' ''; }

# data <lines...>: writes the stdin data file.
data() {
    DATA="$TEST_TMP/data"
    printf '%s\n' "$@" >"$DATA"
}

# tools_installed: gpg, curl and ca-certificates are installed.
tools_installed() {
    printf 'gpg\ncurl\nca-certificates\n' >>"$STATE/installed"
}

# standard_data: two repos, an id from alpha only after an update, an id
# with a candidate, an id already installed; curl and ca-certificates are
# installed, gpg is not.
standard_data() {
    data "$(ALPHA_REPO)" "$(BETA_REPO)" "package${TAB}alpha-tool" \
        "package${TAB}plain-tool" "package${TAB}git"
    printf 'git\ncurl\nca-certificates\n' >>"$STATE/installed"
    printf 'plain-tool\ngpg\ngit\ncurl\nca-certificates\n' >>"$STATE/available"
    printf 'alpha-tool\n' >>"$STATE/after-update"
}

# inst <mode>: runs the script with the stubs, $DATA on stdin, in $WORK.
inst() {
    run env PATH="$TPATH" WS_APT_ROOT="$APT_ROOT" sh -c 'cd "$1" && shift && exec sh "$@"' \
        sh "$WORK" "$SCRIPT" "$@" <"$DATA"
}

calls() { cat "$STATE/calls.log"; }

# count_calls <extended regex>
count_calls() {
    grep -cE -- "$1" "$STATE/calls.log" || true
}

reset_calls() {
    : >"$STATE/calls.log"
}

# apt_files: every file under the apt root, sorted.
apt_files() {
    (cd "$APT_ROOT" && find . -type f | LC_ALL=C sort)
}

# fields <sources file>: its non-comment, non-empty lines, sorted.
fields() {
    grep -vE '^[[:space:]]*(#|$)' "$1" | LC_ALL=C sort
}

expect_calls_lack() {
    n=$(count_calls "$1")
    [ "$n" -eq 0 ] && return 0
    printf 'unexpected %s call(s) matching /%s/; calls:\n%s\n' "$n" "$1" "$(calls)" >&2
    return 1
}

expect_nothing_written() {
    expect_equal "files under the apt root" "" "$(apt_files)"
}

# ------------------------------------------------------------- interface

@test "install-apt: is a POSIX sh script" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$SCRIPT")"
    run sh -n "$SCRIPT"
    expect_status 0
}

@test "install-apt: no mode or an unknown mode is a usage error" {
    standard_data
    inst
    expect_status 2
    inst upgrade
    expect_status 2
    expect_equal "calls" "" "$(calls)"
}

@test "install-apt: empty data does nothing" {
    data ''
    inst install
    expect_status 0
    expect_calls_lack '^(sudo|apt-get|curl|gpg)'
    expect_nothing_written
}

# ------------------------------------------------- first run (8, 9, 10)

@test "install-apt: first run writes the keyrings, binary, from armored and binary keys" {
    standard_data
    inst install
    expect_status 0
    expect_equal "files" "./etc/apt/keyrings/ws-alpha.gpg
./etc/apt/keyrings/ws-beta.gpg
./etc/apt/sources.list.d/ws-alpha.sources
./etc/apt/sources.list.d/ws-beta.sources" "$(apt_files)"
    cmp -s "$KEYS/alpha.bin" "$KR/ws-alpha.gpg" || { echo "ws-alpha.gpg is not the dearmored key" >&2; return 1; }
    cmp -s "$KEYS/beta.gpg" "$KR/ws-beta.gpg" || { echo "ws-beta.gpg is not the binary key as served" >&2; return 1; }
}

@test "install-apt: first run writes deb822 sources with Signed-By" {
    standard_data
    inst install
    expect_status 0
    expect_equal "ws-alpha.sources" "Architectures: amd64 arm64
Components: main
Signed-By: /etc/apt/keyrings/ws-alpha.gpg
Suites: stable
Types: deb
URIs: https://example.org/apt" "$(fields "$SL/ws-alpha.sources")"
    expect_equal "ws-beta.sources" "Components: *
Signed-By: /etc/apt/keyrings/ws-beta.gpg
Suites: *
Types: deb
URIs: https://example.com/apt/ https://mirror.example.com/apt/" "$(fields "$SL/ws-beta.sources")"
}

@test "install-apt: written files are mode 644, chowned to root through sudo" {
    standard_data
    inst install
    expect_status 0
    for f in "$KR/ws-alpha.gpg" "$KR/ws-beta.gpg" "$SL/ws-alpha.sources" "$SL/ws-beta.sources"; do
        expect_equal "mode of $f" 644 "$(stat -c %a "$f")"
        ino=$(stat -c %i "$f")
        awk -v i="$ino" '($1 == "root:root" || $1 == "0:0") && $2 == i { f = 1 } END { exit !f }' \
            "$STATE/chown.log" || {
            printf 'no sudo chown root:root of %s (inode %s); chown log:\n%s\n' "$f" "$ino" "$(cat "$STATE/chown.log")" >&2
            return 1
        }
    done
}

@test "install-apt: files are moved into place from a temp file in the same directory" {
    standard_data
    inst install
    expect_status 0
    for f in "$KR/ws-alpha.gpg" "$SL/ws-beta.sources"; do
        awk -v dst="$f" '
            $1 == "sudo" && $2 == "mv" && $NF == dst {
                src = $(NF - 1)
                d = dst; sub(/\/[^\/]*$/, "", d)
                s = src; sub(/\/[^\/]*$/, "", s)
                if (s == d && src != dst) ok = 1
            }
            END { exit !ok }
        ' "$STATE/calls.log" || {
            printf 'no "sudo mv <temp in same dir> %s"; calls:\n%s\n' "$f" "$(calls)" >&2
            return 1
        }
    done
}

@test "install-apt: first run updates once and installs only the missing ids" {
    standard_data
    inst install
    expect_status 0
    expect_equal "apt-get update calls" 1 "$(count_calls '^apt-get\(sudo\) .*update')"
    installs=$(grep -E '^apt-get\(sudo\) .*install' "$STATE/calls.log")
    [ -n "$installs" ] || { printf 'no apt-get install; calls:\n%s\n' "$(calls)" >&2; return 1; }
    printf '%s\n' "$installs" | while IFS= read -r l; do
        case " $l " in *" -y "*) ;; *) echo "install without -y: $l" >&2; exit 1 ;; esac
        case " $l " in *" --no-install-recommends "*) ;; *) echo "install without --no-install-recommends: $l" >&2; exit 1 ;; esac
        case " $l " in *" git "*) echo "installed git, which was installed: $l" >&2; exit 1 ;; esac
    done
    for id in alpha-tool plain-tool; do
        grep -qxF "$id" "$STATE/installed" || { echo "$id not installed" >&2; return 1; }
    done
}

@test "install-apt: every apt-get call goes through sudo" {
    standard_data
    inst install
    expect_status 0
    expect_calls_lack '^apt-get '
    expect_calls_lack '^chown '
}

@test "install-apt: gpg is installed first when missing (criterion 10)" {
    standard_data
    inst install
    expect_status 0
    gi=$(grep -nE '^apt-get\(sudo\) .*install.* gpg( |$)' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    g1=$(grep -nE '^gpg ' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    [ -n "$gi" ] || { printf 'gpg was not installed; calls:\n%s\n' "$(calls)" >&2; return 1; }
    [ -z "$g1" ] || [ "$gi" -lt "$g1" ] || {
        printf 'gpg used (line %s) before it was installed (line %s); calls:\n%s\n' "$g1" "$gi" "$(calls)" >&2
        return 1
    }
}

@test "install-apt: an installed gpg is not installed again" {
    standard_data
    tools_installed
    inst install
    expect_status 0
    expect_calls_lack '^apt-get.* install.* gpg( |$)'
}

# ------------------------------------------------------ second run (9)

@test "install-apt: second run calls no sudo, apt-get update or install and changes nothing" {
    standard_data
    inst install
    expect_status 0
    before=$(cd "$APT_ROOT" && find . -type f -exec cksum {} + | LC_ALL=C sort)
    touch "$TEST_TMP/marker"
    sleep 1
    reset_calls
    inst install
    expect_status 0
    expect_calls_lack '^apt-get'
    expect_calls_lack '^sudo'
    expect_equal "files after the second run" "$before" \
        "$(cd "$APT_ROOT" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
    expect_equal "paths modified by the second run" "" "$(find "$APT_ROOT" -newer "$TEST_TMP/marker")"
}

@test "install-apt: a new id with a candidate is installed without an update" {
    standard_data
    inst install
    expect_status 0
    printf 'new-tool\n' >>"$STATE/available"
    printf 'package\tnew-tool\n' >>"$DATA"
    reset_calls
    inst install
    expect_status 0
    expect_calls_lack '^apt-get.* update'
    expect_equal "install calls" 1 "$(count_calls '^apt-get\(sudo\) .*install.* new-tool( |$)')"
    expect_calls_lack '^apt-get.* install.* (git|plain-tool|alpha-tool)( |$)'
}

@test "install-apt: a new id without a candidate triggers an update first" {
    standard_data
    inst install
    expect_status 0
    rm -f "$STATE/updated"
    printf 'late-tool\n' >>"$STATE/after-update"
    printf 'package\tlate-tool\n' >>"$DATA"
    reset_calls
    inst install
    expect_status 0
    u=$(grep -nE '^apt-get\(sudo\) .*update' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    i=$(grep -nE '^apt-get\(sudo\) .*install.* late-tool( |$)' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    [ -n "$u" ] && [ -n "$i" ] && [ "$u" -lt "$i" ] || {
        printf 'want update before install of late-tool; calls:\n%s\n' "$(calls)" >&2
        return 1
    }
}

@test "install-apt: a changed sources file is rewritten and triggers an update" {
    standard_data
    inst install
    expect_status 0
    unlock_root
    printf 'Types: deb\nURIs: https://example.net/other\n' >"$SL/ws-beta.sources"
    lock_root
    reset_calls
    inst install
    expect_status 0
    grep -qxF 'Signed-By: /etc/apt/keyrings/ws-beta.gpg' "$SL/ws-beta.sources" || {
        echo "ws-beta.sources was not rewritten" >&2
        return 1
    }
    expect_equal "apt-get update calls" 1 "$(count_calls '^apt-get\(sudo\) .*update')"
}

@test "install-apt: a changed keyring is rewritten" {
    standard_data
    inst install
    expect_status 0
    unlock_root
    printf 'stale\n' >"$KR/ws-alpha.gpg"
    lock_root
    inst install
    expect_status 0
    cmp -s "$KEYS/alpha.bin" "$KR/ws-alpha.gpg" || { echo "ws-alpha.gpg was not rewritten" >&2; return 1; }
}

# ------------------------------------------------- fail closed (8)

# expect_fail_closed <repo name>: non-zero exit naming the repo, no file
# under the apt root, no apt-get call.
expect_fail_closed() {
    expect_failure
    expect_output_matches "(^|[^a-z-])$1([^a-z-]|$)"
    expect_nothing_written
    expect_calls_lack '^apt-get'
}

@test "install-apt: a fingerprint mismatch writes nothing and fails naming the repo" {
    data "$(ALPHA_REPO)" "$(BETA_REPO "$FPR_X")" "package${TAB}plain-tool"
    tools_installed
    printf 'plain-tool\n' >>"$STATE/available"
    inst install
    expect_fail_closed beta
}

@test "install-apt: a subkey fingerprint is not accepted for the primary key" {
    data "$(ALPHA_REPO "$SUB_A")"
    tools_installed
    inst install
    expect_fail_closed alpha
}

@test "install-apt: a keyring with two primary keys passes with both pinned (decision 32)" {
    data "$(GAMMA_REPO)"
    tools_installed
    inst install
    expect_status 0
    cmp -s "$KEYS/gamma.bin" "$KR/ws-gamma.gpg" || { echo "ws-gamma.gpg is not the dearmored two-key keyring" >&2; return 1; }
}

@test "install-apt: pinned fingerprints match in any order" {
    data "$(GAMMA_REPO "$FPR_G2 $FPR_G1")"
    tools_installed
    inst install
    expect_status 0
    [ -f "$KR/ws-gamma.gpg" ] || { echo "no ws-gamma.gpg" >&2; return 1; }
}

@test "install-apt: an extra primary key in the keyring fails closed" {
    data "$(ALPHA_REPO)" "$(GAMMA_REPO "$FPR_G1")"
    tools_installed
    inst install
    expect_fail_closed gamma
}

@test "install-apt: a pinned key missing from the keyring fails closed" {
    data "$(ALPHA_REPO "$FPR_A $FPR_X")"
    tools_installed
    inst install
    expect_fail_closed alpha
}

@test "install-apt: a subkey pinned next to both primary keys fails closed" {
    data "$(GAMMA_REPO "$FPR_G1 $FPR_G2 $SUB_G1")"
    tools_installed
    inst install
    expect_fail_closed gamma
}

@test "install-apt: a failed download writes nothing and fails naming the repo" {
    printf '%s\t%s\n' "$URL_A" "$KEYS/alpha.asc" >"$STATE/urls"
    data "$(ALPHA_REPO)" "$(BETA_REPO)"
    tools_installed
    inst install
    expect_fail_closed beta
}

@test "install-apt: a key that is not OpenPGP data writes nothing and fails" {
    printf '<html>not a key</html>\n' >"$KEYS/alpha.asc"
    data "$(ALPHA_REPO)"
    tools_installed
    inst install
    expect_fail_closed alpha
}

# ------------------------------------------------------ privileges (11)

@test "install-apt: without apt-get it fails naming apt-get and calls nothing" {
    rm -f "$STUBS/apt-get"
    standard_data
    inst install
    expect_failure
    expect_output_matches 'apt-get'
    expect_calls_lack '^(sudo|curl|gpg)'
    expect_nothing_written
}

@test "install-apt: a failing apt-get install fails the run" {
    standard_data
    tools_installed
    run env PATH="$TPATH" WS_APT_ROOT="$APT_ROOT" STUB_APT_FAIL=1 sh "$SCRIPT" install <"$DATA"
    expect_failure
}

# ------------------------------------------------ data is not code (16)

# expect_refused <data line>: non-zero exit naming line 1, no canary,
# nothing called.
expect_refused() {
    data "$1"
    inst install
    expect_failure
    expect_output_matches 'line 1([^0-9]|$)'
    [ ! -e "$CANARY" ] || { echo "data ran as code: canary created" >&2; return 1; }
    expect_calls_lack '^(sudo|curl|gpg|apt-get)'
    expect_nothing_written
}

@test "install-apt: an id with command substitution is refused" {
    expect_refused "package${TAB}\$(touch $CANARY)"
}

@test "install-apt: an id with backticks is refused" {
    expect_refused "package${TAB}\`touch $CANARY\`"
}

@test "install-apt: an id with a semicolon is refused" {
    expect_refused "package${TAB}git;touch $CANARY"
}

@test "install-apt: a repo name with a path is refused" {
    expect_refused "$(repo_line ../evil "$URL_A" "$FPR_A" "$SHA_A" https://example.org/apt stable main '')"
}

@test "install-apt: an http key_url is refused" {
    expect_refused "$(repo_line alpha http://example.org/keys/alpha.asc "$FPR_A" "$SHA_A" https://example.org/apt stable main '')"
}

@test "install-apt: an http uri is refused" {
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A" "$SHA_A" http://example.org/apt stable main '')"
}

@test "install-apt: a lower-case or short fingerprint is refused" {
    expect_refused "$(repo_line alpha "$URL_A" 111111111111111111111111111111111111111 "$SHA_A" https://example.org/apt stable main '')"
    expect_refused "$(repo_line alpha "$URL_A" abcdefabcdefabcdefabcdefabcdefabcdefabcd "$SHA_A" https://example.org/apt stable main '')"
}

@test "install-apt: a bad, empty or duplicate fingerprint in the list is refused" {
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A 1234" "$SHA_A" https://example.org/apt stable main '')"
    expect_refused "$(repo_line alpha "$URL_A" '' "$SHA_A" https://example.org/apt stable main '')"
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A $FPR_A" "$SHA_A" https://example.org/apt stable main '')"
}

@test "install-apt: an unknown kind or a wrong field count is refused" {
    expect_refused "pkg${TAB}git"
    expect_refused "package${TAB}git${TAB}extra"
    expect_refused "repo${TAB}alpha${TAB}$URL_A"
}

@test "install-apt: a bad line later in the data stops the run before anything is done" {
    data "$(ALPHA_REPO)" "package${TAB}plain-tool" "package${TAB}bad id"
    inst install
    expect_failure
    expect_output_matches 'line 3([^0-9]|$)'
    expect_calls_lack '^(sudo|curl|gpg|apt-get)'
    expect_nothing_written
}

@test "install-apt: a suite * stays literal with files in the working directory" {
    data "$(BETA_REPO)"
    tools_installed
    inst install
    expect_status 0
    grep -qxF 'Suites: *' "$SL/ws-beta.sources" && grep -qxF 'Components: *' "$SL/ws-beta.sources" || {
        printf 'glob expanded; ws-beta.sources:\n%s\n' "$(cat "$SL/ws-beta.sources")" >&2
        return 1
    }
}

@test "install-apt: comments and empty lines in the data are ignored" {
    data '# a comment' '' "package${TAB}git"
    printf 'git\n' >>"$STATE/installed"
    inst install
    expect_status 0
    expect_calls_lack '^(sudo|apt-get)'
}

# ------------------------------------------------- check mode (19)

@test "install-apt check: all ids with a candidate pass; repos added, ids not installed" {
    standard_data
    inst check
    expect_status 0
    [ -f "$SL/ws-alpha.sources" ] && [ -f "$KR/ws-beta.gpg" ] || {
        printf 'check mode did not add the repos; files:\n%s\n' "$(apt_files)" >&2
        return 1
    }
    expect_equal "apt-get update calls" 1 "$(count_calls '^apt-get\(sudo\) .*update')"
    expect_calls_lack '^apt-get.* install.* (alpha-tool|plain-tool|git)( |$)'
}

@test "install-apt check: an id without a candidate fails, naming it" {
    standard_data
    printf 'package\tgone-tool\n' >>"$DATA"
    inst check
    expect_status 1
    expect_output_matches '(^|[^a-z-])gone-tool([^a-z-]|$)'
    expect_output_lacks 'plain-tool'
    expect_calls_lack '^apt-get.* install.* gone-tool'
}

@test "install-apt check: a fingerprint mismatch fails closed too" {
    data "$(ALPHA_REPO "$FPR_X")" "package${TAB}alpha-tool"
    tools_installed
    inst check
    expect_fail_closed alpha
}

# ------------------------------------ foreign sources (decision 35)

# foreign <path under /etc/apt> <content>: a file another tool wrote.
foreign() {
    unlock_root
    mkdir -p "$(dirname "$APT_ROOT/etc/apt/$1")"
    printf '%s\n' "$2" >"$APT_ROOT/etc/apt/$1"
    lock_root
}

# expect_foreign_stop <repo> <file name>: non-zero exit naming the repo
# and the file; nothing but the foreign files under the apt root; no
# sudo or apt-get call.
expect_foreign_stop() {
    expect_failure
    expect_output_matches "(^|[^a-z-])$1([^a-z-]|$)"
    expect_output_matches "$(printf '%s' "$2" | sed 's/\./\\./g')"
    bad=$(apt_files | grep -E '/ws-[^/]*$' || true)
    expect_equal "ws-* files written despite a foreign source" "" "$bad"
    expect_calls_lack '^(sudo|apt-get)'
}

@test "install-apt: a vendor .list with signed-by for the same URI stops the run" {
    foreign sources.list.d/vendor-alpha.list \
        'deb [arch=amd64 signed-by=/etc/apt/keyrings/vendor.gpg] https://example.org/apt stable main'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha vendor-alpha.list
}

@test "install-apt: a deb822 .sources for the same URI stops the run" {
    foreign sources.list.d/vendor-beta.sources 'Types: deb
URIs: https://mirror.example.com/apt/
Suites: *
Components: *
Signed-By: /usr/share/keyrings/vendor-beta.gpg'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop beta vendor-beta.sources
}

@test "install-apt: an entry in sources.list itself stops the run" {
    foreign sources.list 'deb http://archive.ubuntu.com/ubuntu noble main
deb https://example.org/apt stable main'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha sources.list
}

@test "install-apt: a trailing-slash difference still counts as the same URI" {
    foreign sources.list.d/vendor-alpha.list 'deb https://example.org/apt/ stable main'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha vendor-alpha.list
}

@test "install-apt: a missing trailing slash on beta's URI still counts" {
    foreign sources.list.d/vendor-beta.list 'deb [signed-by=/etc/apt/keyrings/b.gpg] https://example.com/apt * *'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop beta vendor-beta.list
}

@test "install-apt: commented-out lines and unrelated URIs don't stop the run" {
    foreign sources.list '# deb https://example.org/apt stable main
deb http://archive.ubuntu.com/ubuntu noble main'
    foreign sources.list.d/old-alpha.list '#deb [signed-by=/etc/apt/keyrings/x.gpg] https://example.org/apt stable main'
    foreign sources.list.d/ubuntu.sources 'Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg'
    foreign sources.list.d/other.list 'deb https://example.org/apt-other stable main'
    standard_data
    inst install
    expect_status 0
    [ -f "$SL/ws-alpha.sources" ] && [ -f "$SL/ws-beta.sources" ] || {
        printf 'repo files missing; files:\n%s\n' "$(apt_files)" >&2
        return 1
    }
}

@test "install-apt: its own ws-* files don't count as foreign" {
    standard_data
    inst install
    expect_status 0
    # A changed own file is rewritten, not reported.
    unlock_root
    printf 'Types: deb\nURIs: https://example.org/apt\nSuites: old\nComponents: main\n' >"$SL/ws-alpha.sources"
    lock_root
    inst install
    expect_status 0
    grep -qxF 'Suites: stable' "$SL/ws-alpha.sources" || { echo "ws-alpha.sources not rewritten" >&2; return 1; }
}

# ------------------------------------------- rollback (decision 35)

@test "install-apt: a failed apt-get update removes the repo files the run created" {
    standard_data
    tools_installed
    export STUB_UPDATE_FAIL=1
    inst install
    expect_failure
    expect_nothing_written
    expect_calls_lack '^apt-get.* install.* (alpha-tool|plain-tool)( |$)'
}

@test "install-apt: a failed apt-get update restores replaced files and removes new ones" {
    standard_data
    inst install
    expect_status 0
    unlock_root
    printf 'Types: deb\nURIs: https://example.net/older\n' >"$SL/ws-beta.sources"
    lock_root
    old_beta=$(cat "$SL/ws-beta.sources")
    alpha_before=$(cksum "$KR/ws-alpha.gpg" "$SL/ws-alpha.sources")
    printf '%s\n' "$(GAMMA_REPO)" >>"$DATA"
    export STUB_UPDATE_FAIL=1
    inst install
    expect_failure
    expect_equal "ws-beta.sources after the rollback" "$old_beta" "$(cat "$SL/ws-beta.sources")"
    expect_equal "untouched alpha files" "$alpha_before" "$(cksum "$KR/ws-alpha.gpg" "$SL/ws-alpha.sources")"
    [ ! -e "$KR/ws-gamma.gpg" ] && [ ! -e "$SL/ws-gamma.sources" ] || {
        printf 'new gamma files left after a failed update; files:\n%s\n' "$(apt_files)" >&2
        return 1
    }
}

# ------------------------------------- no needless download (36)

@test "install-apt: with keyrings and sources in place nothing is downloaded" {
    standard_data
    inst install
    expect_status 0
    reset_calls
    inst install
    expect_status 0
    expect_calls_lack '^curl'
}

@test "install-apt: a rerun works offline when nothing changed" {
    standard_data
    inst install
    expect_status 0
    : >"$STATE/urls"
    inst install
    expect_status 0
}

@test "install-apt: a keyring on disk that fails the set check is downloaded and replaced" {
    standard_data
    inst install
    expect_status 0
    unlock_root
    cp "$KEYS/beta.gpg" "$KR/ws-alpha.gpg"
    lock_root
    reset_calls
    inst install
    expect_status 0
    expect_equal "downloads of alpha's key" 1 "$(count_calls "^curl $URL_A\$")"
    cmp -s "$KEYS/alpha.bin" "$KR/ws-alpha.gpg" || { echo "ws-alpha.gpg was not replaced" >&2; return 1; }
}

# --------------------------------------------- curl first (37)

@test "install-apt: curl and ca-certificates are installed before the first download" {
    standard_data
    : >"$STATE/installed"
    printf 'git\ngpg\n' >>"$STATE/installed"
    inst install
    expect_status 0
    ci=$(grep -nE '^apt-get\(sudo\) .*install.* curl( |$)' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    [ -n "$ci" ] || { printf 'curl was not installed; calls:\n%s\n' "$(calls)" >&2; return 1; }
    grep -E '^apt-get\(sudo\) .*install.* ca-certificates( |$)' "$STATE/calls.log" >/dev/null || {
        printf 'ca-certificates was not installed; calls:\n%s\n' "$(calls)" >&2
        return 1
    }
    d1=$(grep -nE '^curl ' "$STATE/calls.log" | head -n 1 | cut -d: -f1)
    [ -z "$d1" ] || [ "$ci" -lt "$d1" ] || {
        printf 'downloaded (line %s) before curl was installed (line %s); calls:\n%s\n' "$d1" "$ci" "$(calls)" >&2
        return 1
    }
}

# ------------------------------------------ installed status (38)

@test "install-apt: held packages count as installed, no sudo" {
    standard_data
    inst install
    expect_status 0
    reset_calls
    export STUB_STATUS_STYLE=hold
    inst install
    expect_status 0
    expect_calls_lack '^sudo'
}

@test "install-apt: a multi-arch package with two status lines counts as installed, no sudo" {
    standard_data
    inst install
    expect_status 0
    reset_calls
    export STUB_STATUS_STYLE=multiarch
    inst install
    expect_status 0
    expect_calls_lack '^sudo'
}

# ------------------------------------------------- locale (39)

@test "install-apt: apt-cache policy is read under LC_ALL=C (German locale)" {
    standard_data
    inst install
    expect_status 0
    printf 'new-tool\n' >>"$STATE/available"
    printf 'package\tnew-tool\n' >>"$DATA"
    reset_calls
    export LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8
    inst install
    expect_status 0
    expect_calls_lack '^apt-get.* update'
    expect_equal "install calls" 1 "$(count_calls '^apt-get\(sudo\) .*install.* new-tool( |$)')"
}

@test "install-apt check: a Candidate (none) id fails, also in a German locale" {
    standard_data
    printf 'stale-tool\n' >>"$STATE/nocandidate"
    printf 'package\tstale-tool\n' >>"$DATA"
    export LANG=de_DE.UTF-8 LC_ALL=de_DE.UTF-8
    inst check
    expect_status 1
    expect_output_matches '(^|[^a-z-])stale-tool([^a-z-]|$)'
    expect_output_lacks 'plain-tool'
}

# --------------------------------------------- key sha256 (decision 42)

@test "install-apt: a key with the right fingerprints but the wrong sha256 fails closed" {
    data "$(ALPHA_REPO)" "$(BETA_REPO "$FPR_B" "$SHA_X")"
    tools_installed
    inst install
    expect_fail_closed beta
}

@test "install-apt: a malformed key_sha256 is refused" {
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A" "$(printf '%s' "$SHA_A" | tr a-f A-F)" https://example.org/apt stable main '')"
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A" "${SHA_A%?}" https://example.org/apt stable main '')"
    expect_refused "$(repo_line alpha "$URL_A" "$FPR_A" '' https://example.org/apt stable main '')"
}

@test "install-apt: the .sources file holds the pinned key sha256 in a comment" {
    standard_data
    inst install
    expect_status 0
    for pair in "alpha:$SHA_A" "beta:$SHA_B"; do
        n=${pair%%:*}
        h=${pair#*:}
        expect_equal "comment lines with the sha256 in ws-$n.sources" 1 \
            "$(grep -cE "^#.*$h" "$SL/ws-$n.sources" || true)"
    done
}

@test "install-apt: a renewed key with a bumped sha256 pin is downloaded and written" {
    standard_data
    inst install
    expect_status 0
    # The vendor renews the key: same fingerprints, new file.
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: renewed\n\nFAKEKEY %s %s alpha-renewed\n-----END PGP PUBLIC KEY BLOCK-----\n' \
        "$FPR_A" "$SUB_A" >"$KEYS/alpha.asc"
    new_sha=$(sha256sum "$KEYS/alpha.asc" | cut -d ' ' -f 1)
    data "$(ALPHA_REPO "$FPR_A" "$new_sha")" "$(BETA_REPO)" "package${TAB}alpha-tool" \
        "package${TAB}plain-tool" "package${TAB}git"
    reset_calls
    inst install
    expect_status 0
    expect_equal "downloads of alpha's key" 1 "$(count_calls "^curl $URL_A\$")"
    printf 'FAKEBIN %s %s alpha-renewed\n' "$FPR_A" "$SUB_A" >"$TEST_TMP/renewed.bin"
    cmp -s "$TEST_TMP/renewed.bin" "$KR/ws-alpha.gpg" || { echo "renewed key not written to ws-alpha.gpg" >&2; return 1; }
    grep -qE "^#.*$new_sha" "$SL/ws-alpha.sources" || { echo "ws-alpha.sources lacks the new pin" >&2; return 1; }
    expect_calls_lack "^curl $URL_B\$"
}

@test "install-apt: a bumped pin that the served key doesn't match fails closed" {
    standard_data
    inst install
    expect_status 0
    before=$(cd "$APT_ROOT" && find . -type f -exec cksum {} + | LC_ALL=C sort)
    data "$(ALPHA_REPO "$FPR_A" "$SHA_X")" "$(BETA_REPO)"
    reset_calls
    inst install
    expect_failure
    expect_output_matches '(^|[^a-z-])alpha([^a-z-]|$)'
    expect_equal "files after the failed run" "$before" \
        "$(cd "$APT_ROOT" && find . -type f -exec cksum {} + | LC_ALL=C sort)"
    expect_calls_lack '^apt-get'
}

@test "install-apt check: a wrong key sha256 fails closed too" {
    data "$(ALPHA_REPO "$FPR_A" "$SHA_X")" "package${TAB}alpha-tool"
    tools_installed
    inst check
    expect_fail_closed alpha
}

# ------------------------------- disabled stanzas (43), Field:value (44)

@test "install-apt: a .sources stanza with Enabled: no for the URI is not foreign" {
    foreign sources.list.d/vendor-alpha.sources 'Types: deb
URIs: https://example.org/apt
Suites: stable
Components: main
Enabled: no
Signed-By: /etc/apt/keyrings/vendor.gpg'
    standard_data
    inst install
    expect_status 0
    [ -f "$SL/ws-alpha.sources" ] || { echo "ws-alpha.sources not written" >&2; return 1; }
}

@test "install-apt: one disabled and one enabled stanza for the URI is still foreign" {
    foreign sources.list.d/vendor-alpha.sources 'Types: deb
URIs: https://example.org/apt
Suites: stable
Components: main
Enabled: no

Types: deb
URIs: https://example.org/apt/
Suites: stable
Components: main
Signed-By: /etc/apt/keyrings/vendor.gpg'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha vendor-alpha.sources
}

@test "install-apt: a disabled stanza for the URI and an enabled one for another URI is not foreign" {
    foreign sources.list.d/vendor-mixed.sources 'Types: deb
URIs: https://example.org/apt
Suites: stable
Components: main
Enabled: no

Types: deb
URIs: https://example.org/apt-other
Suites: stable
Components: main'
    standard_data
    inst install
    expect_status 0
}

@test "install-apt: URIs:https://... without a space is foreign" {
    foreign sources.list.d/vendor-alpha.sources 'Types:deb
URIs:https://example.org/apt
Suites:stable
Components:main'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha vendor-alpha.sources
}

# ------------------------------------ temp files on failure (45)

# expect_only_final_files: nothing but ws-<name>.gpg and ws-<name>.sources
# (and the given foreign files) under the apt root, so no temp file is
# left anywhere.
expect_only_final_files() {
    bad=$(apt_files | grep -vE '^\./etc/apt/(keyrings/ws-[a-z0-9-]+\.gpg|sources\.list\.d/ws-[a-z0-9-]+\.sources)$' || true)
    expect_equal "temp or other files left under the apt root" "" "$bad"
}

# fail_chown / fail_mv: every privileged chown, or every mv onto a ws-*
# name, fails.
fail_chown() {
    cat >"$STUBS/chown" <<EOF
#!/bin/sh
printf 'chown(fail) %s\n' "\$*" >>"$STATE/calls.log"
exit 1
EOF
    chmod +x "$STUBS/chown"
}

fail_mv() {
    cat >"$STUBS/mv" <<EOF
#!/bin/sh
for last in "\$@"; do :; done
case \${last##*/} in
    ws-*) printf 'mv(fail) %s\n' "\$*" >>"$STATE/calls.log"; exit 1 ;;
esac
exec "$BATS_FILE_TMPDIR/sysbin/mv" "\$@"
EOF
    chmod +x "$STUBS/mv"
}

@test "install-apt: a failed chown leaves no temp file and fails" {
    standard_data
    tools_installed
    fail_chown
    inst install
    expect_failure
    expect_only_final_files
}

@test "install-apt: a failed rename leaves no temp file and fails" {
    standard_data
    tools_installed
    fail_mv
    inst install
    expect_failure
    expect_only_final_files
}

@test "install-apt: a failed write during an update with rollback leaves no temp file" {
    standard_data
    inst install
    expect_status 0
    unlock_root
    printf 'Types: deb\nURIs: https://example.net/older\n' >"$SL/ws-beta.sources"
    lock_root
    printf '%s\n' "$(GAMMA_REPO)" >>"$DATA"
    fail_mv
    inst install
    expect_failure
    expect_only_final_files
}

# ------------------- Enabled: as an apt boolean (decision 48 a)

# t_disabled_value <value>: a stanza for alpha's URI with Enabled: <value>
# is disabled, so not foreign.
t_disabled_value() {
    foreign sources.list.d/vendor-alpha.sources "Types: deb
URIs: https://example.org/apt
Suites: stable
Components: main
Enabled: $1
Signed-By: /etc/apt/keyrings/vendor.gpg"
    standard_data
    inst install
    expect_status 0
    [ -f "$SL/ws-alpha.sources" ] || { echo "ws-alpha.sources not written with Enabled: $1" >&2; return 1; }
}

for v in false 0 off No FALSE Off without disable; do
    bats_test_function --description "install-apt: a stanza with Enabled: $v is not foreign (decision 48)" -- t_disabled_value "$v"
done

@test "install-apt: a stanza with Enabled: yes for the URI is foreign" {
    foreign sources.list.d/vendor-alpha.sources 'Types: deb
URIs: https://example.org/apt
Suites: stable
Components: main
Enabled: yes'
    standard_data
    tools_installed
    inst install
    expect_foreign_stop alpha vendor-alpha.sources
}

# ------------------------- rollback order (decision 48 b)

@test "install-apt: a rollback restores the .sources file before the keyring" {
    standard_data
    inst install
    expect_status 0
    old_gpg=$(cksum <"$KR/ws-alpha.gpg")
    old_src=$(cksum <"$SL/ws-alpha.sources")
    # A renewed key with a bumped pin replaces both alpha files.
    printf -- '-----BEGIN PGP PUBLIC KEY BLOCK-----\nComment: renewed\n\nFAKEKEY %s %s alpha-renewed\n-----END PGP PUBLIC KEY BLOCK-----\n' \
        "$FPR_A" "$SUB_A" >"$KEYS/alpha.asc"
    new_sha=$(sha256sum "$KEYS/alpha.asc" | cut -d ' ' -f 1)
    data "$(ALPHA_REPO "$FPR_A" "$new_sha")" "$(BETA_REPO)" "package${TAB}git"
    reset_calls
    export STUB_UPDATE_FAIL=1
    inst install
    expect_failure
    expect_equal "ws-alpha.gpg after the rollback" "$old_gpg" "$(cksum <"$KR/ws-alpha.gpg")"
    expect_equal "ws-alpha.sources after the rollback" "$old_src" "$(cksum <"$SL/ws-alpha.sources")"
    # Privileged calls after the failed update whose last argument is a
    # final alpha file: the first one for the .sources must come first.
    order=$(awk -v kr="$KR/ws-alpha.gpg" -v sl="$SL/ws-alpha.sources" '
        /^apt-get\(sudo\) .*update/ { failed = 1; next }
        failed && $1 == "sudo" && $NF == sl && !s { s = NR; print "sources " NR }
        failed && $1 == "sudo" && $NF == kr && !k { k = NR; print "keyring " NR }
    ' "$STATE/calls.log")
    s=$(printf '%s\n' "$order" | awk '$1 == "sources" { print $2 }')
    k=$(printf '%s\n' "$order" | awk '$1 == "keyring" { print $2 }')
    [ -n "$s" ] && [ -n "$k" ] || {
        printf 'no privileged restore of both alpha files seen after the update; calls:\n%s\n' "$(calls)" >&2
        return 1
    }
    [ "$s" -lt "$k" ] || {
        printf 'keyring restored (line %s) before the .sources (line %s); calls:\n%s\n' "$k" "$s" "$(calls)" >&2
        return 1
    }
}
