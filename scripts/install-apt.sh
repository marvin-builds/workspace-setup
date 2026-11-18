#!/bin/sh
# Adds third-party apt repos and installs apt packages (slice 5,
# docs/briefs/05-packages.md). Run as the normal user: every privileged
# command goes through sudo, and with everything in place no sudo is
# called at all.
#
# Usage: install-apt.sh install|check <data
#
#   install  add the repos, install the ids that aren't installed
#   check    add the repos, apt-get update, fail listing the ids without an
#            install candidate; installs no package id (scripts/
#            check-package-ids.sh runs it in a fresh container)
#
# Data on stdin, one record per line, fields separated by one tab; empty
# lines and lines starting with # are ignored:
#
#   repo<TAB>name<TAB>key_url<TAB>fingerprints<TAB>key_sha256<TAB>uris<TAB>suites<TAB>components<TAB>architectures
#   package<TAB>apt id
#
# key_url, fingerprints and key_sha256 are an apt_repos entry's key.url,
# key.fingerprints and key.sha256 in packages.yaml.
#
# List fields (fingerprints, uris, suites, components, architectures) hold
# values separated by single spaces; architectures may be
# empty. Every line is validated before anything else happens, and the
# data is never evaluated as code: values are only arguments or file
# content.
#
# Per repo, before anything is written or apt-get is called, the repo's
# URIs must not be configured already in another sources file
# (sources.list, sources.list.d/*.list or *.sources other than the ws-*
# files): a vendor setup next to ours makes apt refuse every command, so
# the run stops naming the file. Foreign .sources files are read stanza
# by stanza; a stanza disabled with `Enabled:` (no, false, off, ...)
# doesn't count.
#
# The key is downloaded; its sha256 as served must be key_sha256 (checked
# before dearmoring), so a vendor's renewed key with the same fingerprints
# needs a new pin. It is dearmored when ASCII-armored. The set of its
# primary key fingerprints must equal the pinned set exactly: no pinned
# key missing and no extra key, so a key nobody pinned is never trusted. A
# repo whose keyring on disk already passes that check and whose .sources
# is current is not downloaded again, so a rerun works offline. The
# .sources file names the pinned key_sha256 in a comment, so a bumped pin
# changes it and forces a download. Every key
# is verified before the first file is written; a failed download or a
# mismatch stops the run naming the repo. Then
# /etc/apt/keyrings/ws-<name>.gpg and /etc/apt/sources.list.d/ws-<name>.sources
# are written when their content differs (temp file in the same
# directory, mode 644, root:root, rename; a failed write removes its temp
# file). When apt-get update fails after
# that, the files are put back as they were.
#
# Tools: with repos in the data, gpg, curl and ca-certificates are
# installed first when missing. A package counts as installed when a dpkg
# status line of it ends in " ok installed" (held and multi-arch packages
# too). apt-get update runs only when a repo file changed or a wanted id
# has no install candidate. Parsed apt output comes from LC_ALL=C.
#
# WS_APT_ROOT (tests only) is prefixed to the /etc/apt paths; Signed-By
# always names the real keyring path.

set -eu

PROG=install-apt
TAB=$(printf '\t')
APT_ROOT=${WS_APT_ROOT:-}
KEYRINGS=/etc/apt/keyrings
SOURCES=/etc/apt/sources.list.d

say() {
    printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
    say "$*"
    exit 1
}

usage() {
    printf 'usage: %s install|check <data\n' "$PROG" >&2
    exit 2
}

[ $# -eq 1 ] || usage
mode=$1
case $mode in
    install | check) ;;
    *) usage ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/install-apt.XXXXXX")
pending=
cleanup() {
    if [ -n "$pending" ]; then
        sudo rm -f "$pending" || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# ------------------------------------------------------------- the data

cat >"$work/data"

# Validates every line; prints "line <n>: <reason>" for the first bad one.
awk -F '\t' '
    function words_ok(s, re,    n, i, w) {
        if (s == "") return 0
        n = split(s, w, " ")
        # split collapses repeated spaces; the values must be single-spaced.
        if (s ~ /^ | $|  /) return 0
        for (i = 1; i <= n; i++) if (w[i] !~ re) return 0
        return 1
    }
    function fprs_ok(s,    n, i, f, seenf) {
        if (!words_ok(s, "^[0-9A-F]+$")) return 0
        n = split(s, f, " ")
        for (i = 1; i <= n; i++) {
            if (length(f[i]) != 40 || (f[i] in seenf)) return 0
            seenf[f[i]] = 1
        }
        return 1
    }
    function bad(why) {
        printf "line %d: %s\n", NR, why
        failed = 1
        exit 1
    }
    $0 == "" || /^#/ { next }
    $1 == "repo" {
        if (NF != 9) bad("a repo line has 9 fields, found " NF)
        if ($2 !~ /^[a-z0-9-]+$/) bad("bad repo name")
        if ($2 in seen) bad("repo " $2 " is listed twice")
        seen[$2] = 1
        if ($3 !~ /^https:\/\/[^[:space:]]+$/) bad("repo " $2 ": key_url must be https")
        if (!fprs_ok($4))
            bad("repo " $2 ": fingerprints must be unique, 40 upper-case hex digits each")
        if (length($5) != 64 || $5 !~ /^[0-9a-f]+$/)
            bad("repo " $2 ": key_sha256 must be 64 lower-case hex digits")
        if (!words_ok($6, "^https://[^[:space:]]+$")) bad("repo " $2 ": every uri must be https")
        if (!words_ok($7, "^[A-Za-z0-9*][A-Za-z0-9*._/+-]*$")) bad("repo " $2 ": bad suites")
        if (!words_ok($8, "^[A-Za-z0-9*][A-Za-z0-9*._/+-]*$")) bad("repo " $2 ": bad components")
        if ($9 != "" && !words_ok($9, "^[a-z0-9-]+$")) bad("repo " $2 ": bad architectures")
        next
    }
    $1 == "package" {
        if (NF != 2) bad("a package line has 2 fields, found " NF)
        if ($2 !~ /^[a-z0-9][a-z0-9+.-]+$/) bad("bad apt id")
        next
    }
    { bad("unknown record kind (want repo or package)") }
' "$work/data" >"$work/invalid" || {
    [ -s "$work/invalid" ] || die "cannot read the data"
    die "$(cat "$work/invalid")"
}

grep "^repo$TAB" "$work/data" >"$work/repos" || true
grep "^package$TAB" "$work/data" | cut -f 2 >"$work/ids" || true

command -v apt-get >/dev/null 2>&1 ||
    die "apt-get not found: the package installer needs Debian or Ubuntu"

# ------------------------------------------------------------- apt state

# installed <id>: a dpkg status line of the package ends in " ok installed"
# ("install" or "hold"; one line per architecture for multi-arch ones).
installed() {
    # shellcheck disable=SC2016 # a dpkg-query format, not shell
    LC_ALL=C dpkg-query -W -f '${Status}\n' "$1" 2>/dev/null |
        grep -q ' ok installed$'
}

# has_candidate <id>: apt-cache policy shows an install candidate.
has_candidate() {
    c=$(LC_ALL=C apt-cache policy "$1" 2>/dev/null |
        awk '$1 == "Candidate:" { print $2; exit }')
    [ -n "$c" ] && [ "$c" != "(none)" ]
}

# The files this run wrote: <path><TAB><backup of the old content, or
# empty when the file is new>.
journal="$work/journal"
: >"$journal"

# write_file <source> <target>: through a temp file in the target's
# directory, mode 644, root:root, then a rename. A failure removes the
# temp file.
write_file() {
    pending=$(sudo mktemp "${2%/*}/.${2##*/}.XXXXXX") || {
        pending=
        return 1
    }
    if ! { sudo cp "$1" "$pending" && sudo chmod 644 "$pending" &&
        sudo chown root:root "$pending" && sudo mv -f "$pending" "$2"; }; then
        sudo rm -f "$pending" || say "cannot remove the temp file $pending"
        pending=
        return 1
    fi
    pending=
}

# rollback: puts back what this run wrote, so a failed run never leaves
# apt with a broken repo.
rollback() {
    [ -s "$journal" ] || return 0
    say "putting back the repo files this run wrote"
    # Last write first: a repo's .sources (with the key pin) goes back
    # before its keyring, so an interrupted rollback never pairs an old
    # keyring with the new pin.
    awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$journal" >"$work/journal.rev"
    while IFS="$TAB" read -r dst backup; do
        if [ -n "$backup" ]; then
            write_file "$backup" "$dst" || say "cannot restore $dst"
        else
            sudo rm -f "$dst" || say "cannot remove $dst"
        fi
    done <"$work/journal.rev"
    : >"$journal"
}

updated=
apt_update() {
    if ! sudo DEBIAN_FRONTEND=noninteractive apt-get update; then
        rollback
        die "apt-get update failed"
    fi
    updated=1
}

# apt_install <id...>: updates first when one of them has no candidate
# (and the lists weren't updated in this run yet).
apt_install() {
    if [ -z "$updated" ]; then
        for id in "$@"; do
            has_candidate "$id" || {
                apt_update
                break
            }
        done
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" ||
        die "apt-get install failed: $*"
}

# ------------------------------------------------------------- repos

# primary_fprs <keyring>: the fingerprints of its primary keys (the fpr
# right after each pub; subkeys don't count), sorted, one per line.
primary_fprs() {
    gpg --batch --with-colons --show-keys "$1" 2>/dev/null |
        awk -F: '$1 == "pub" { p = 1; next } { if (p && $1 == "fpr") print $10; p = 0 }' |
        LC_ALL=C sort -u
}

# The two readers of foreign_check: each prints "<repo><TAB><uri>" for
# the first URI of a repo it finds (trailing / ignored) and nothing
# otherwise. Commented-out lines don't count.
#
# One-line style (sources.list, *.list): any word of a deb line.
# shellcheck disable=SC2016 # awk programs, not shell
FOREIGN_LIST='
    FILENAME == repos {
        n = split($6, u, " ")
        for (i = 1; i <= n; i++) { x = u[i]; sub(/\/+$/, "", x); want[x] = $2 }
        next
    }
    /^[ \t]*#/ { next }
    {
        m = split($0, w, /[ \t]+/)
        for (i = 1; i <= m; i++) {
            x = w[i]; sub(/\/+$/, "", x)
            if (x in want) { print want[x] "\t" x; exit }
        }
    }
'
# deb822 (*.sources): stanza by stanza, the URIs field (with or without a
# space after the colon, continuation lines included); a stanza with
# Enabled: no (or another false value of apt's booleans) doesn't count.
# shellcheck disable=SC2016 # awk programs, not shell
FOREIGN_DEB822='
    function check(s,    m, i, w, x) {
        m = split(s, w, /[ \t]+/)
        for (i = 1; i <= m; i++) {
            x = w[i]; sub(/\/+$/, "", x)
            if (hit == "" && (x in want)) hit = want[x] "\t" x
        }
    }
    function flush() {
        if (hit != "" && !disabled) { print hit; found = 1 }
        hit = ""; disabled = 0; field = ""
    }
    FILENAME == repos {
        n = split($6, u, " ")
        for (i = 1; i <= n; i++) { x = u[i]; sub(/\/+$/, "", x); want[x] = $2 }
        next
    }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { flush(); if (found) exit; next }
    /^[ \t]/ { if (field == "uris") check($0); next }
    {
        c = index($0, ":")
        if (!c) next
        field = tolower(substr($0, 1, c - 1))
        val = substr($0, c + 1)
        if (field == "uris") check(val)
        else if (field == "enabled") {
            # apt reads Enabled: as a boolean.
            gsub(/[ \t]/, "", val)
            if (tolower(val) ~ /^(no|false|off|without|disable|0)$/) disabled = 1
        }
    }
    END { if (!found) flush() }
'

# foreign_check: stops when a repo's URI is in a sources file that isn't
# ours (any but the ws-* files).
foreign_check() {
    for f in "$APT_ROOT/etc/apt/sources.list" "$APT_ROOT$SOURCES"/*.list \
        "$APT_ROOT$SOURCES"/*.sources; do
        [ -f "$f" ] || continue
        case ${f##*/} in ws-*) continue ;; esac
        case $f in
            *.sources) prog=$FOREIGN_DEB822 ;;
            *) prog=$FOREIGN_LIST ;;
        esac
        hit=$(awk -F '\t' "$prog" repos="$work/repos" "$work/repos" "$f") ||
            die "cannot read $f"
        [ -n "$hit" ] || continue
        die "repo ${hit%%"$TAB"*}: ${hit#*"$TAB"} is already configured in ${f#"$APT_ROOT"}; remove that source (a setup other than workspace-setup's), then run again. Nothing written."
    done
}

changed=

# put <source file> <target dir> <name>: writes the file when its content
# differs, keeping the old content for a rollback.
put() {
    dir="$APT_ROOT$2"
    dst="$dir/$3"
    if [ -f "$dst" ] && cmp -s "$1" "$dst"; then
        return 0
    fi
    [ -d "$dir" ] || sudo mkdir -p -m 755 "$dir" || die "cannot create $dir"
    backup=
    if [ -e "$dst" ]; then
        backup="$work/backup-$3"
        cp "$dst" "$backup" || die "cannot keep a copy of $dst"
    fi
    if ! write_file "$1" "$dst"; then
        rollback
        die "cannot write $dst"
    fi
    printf '%s\t%s\n' "$dst" "$backup" >>"$journal"
    say "wrote $2/$3"
    changed=1
}

if [ -s "$work/repos" ]; then
    foreign_check

    # gpg checks the fingerprints, curl downloads the keys; a minimal
    # Ubuntu lacks them.
    set --
    for tool in gpg curl ca-certificates; do
        installed "$tool" || set -- "$@" "$tool"
    done
    [ $# -eq 0 ] || apt_install "$@"
    command -v curl >/dev/null 2>&1 || die "curl not found: needed to download the repo keys"

    GNUPGHOME="$work/gnupg"
    export GNUPGHOME
    mkdir -m 700 "$GNUPGHOME"

    # Every key first: nothing is written unless all of them match.
    while IFS="$TAB" read -r _ name url fprs sha uris suites components archs; do
        {
            printf '# Written by workspace-setup (scripts/install-apt.sh).\n'
            printf '# Key: %s, sha256 %s\n' "$url" "$sha"
            printf 'Types: deb\n'
            printf 'URIs: %s\n' "$uris"
            printf 'Suites: %s\n' "$suites"
            printf 'Components: %s\n' "$components"
            [ -z "$archs" ] || printf 'Architectures: %s\n' "$archs"
            printf 'Signed-By: %s/ws-%s.gpg\n' "$KEYRINGS" "$name"
        } >"$work/$name.sources"
        # shellcheck disable=SC2086 # validated hex words, split on purpose
        want=$(printf '%s\n' $fprs | LC_ALL=C sort -u)
        key="$work/$name.gpg"
        disk="$APT_ROOT$KEYRINGS/ws-$name.gpg"
        if [ -f "$disk" ] && cmp -s "$work/$name.sources" "$APT_ROOT$SOURCES/ws-$name.sources" &&
            [ "$(primary_fprs "$disk")" = "$want" ]; then
            cp "$disk" "$key"
            continue
        fi
        raw="$work/$name.key"
        curl -fsSL --proto '=https' -o "$raw" "$url" ||
            die "repo $name: cannot download the key from $url"
        got=$(sha256sum "$raw" | cut -d ' ' -f 1) ||
            die "repo $name: cannot hash the key from $url"
        [ "$got" = "$sha" ] ||
            die "repo $name: the key from $url has sha256 $got, not the pinned $sha (renewed? check it and bump key.sha256 in packages.yaml); nothing written"
        if grep -qF -e '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$raw"; then
            gpg --batch --yes --dearmor -o "$key" "$raw" ||
                die "repo $name: the key from $url is not valid OpenPGP data"
        else
            cp "$raw" "$key"
        fi
        got=$(primary_fprs "$key") || got=
        [ -n "$got" ] || die "repo $name: the key from $url is not valid OpenPGP data"
        [ "$got" = "$want" ] ||
            die "repo $name: the key's primary fingerprints ($(printf '%s' "$got" | tr '\n' ' ')) are not the pinned set ($fprs); nothing written"
    done <"$work/repos"

    while IFS="$TAB" read -r _ name _; do
        put "$work/$name.gpg" "$KEYRINGS" "ws-$name.gpg"
        put "$work/$name.sources" "$SOURCES" "ws-$name.sources"
    done <"$work/repos"
fi

# ------------------------------------------------------------- packages

if [ "$mode" = check ]; then
    apt_update
    missing=
    while IFS= read -r id; do
        has_candidate "$id" || {
            say "no install candidate: $id"
            missing=1
        }
    done <"$work/ids"
    [ -z "$missing" ] || exit 1
    say "every id has an install candidate"
    exit 0
fi

[ -z "$changed" ] || apt_update

set --
while IFS= read -r id; do
    installed "$id" || set -- "$@" "$id"
done <"$work/ids"
[ $# -eq 0 ] || apt_install "$@"
