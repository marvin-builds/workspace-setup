#!/bin/sh
# Checks a git repo for private data before it reaches GitHub.
#
#   staged   scan the index for secrets and denylisted text
#   history  scan commits the same way, plus their metadata (messages,
#            author/committer/tagger names, paths, tag messages)
#   emails   every author, committer and tagger email must be a GitHub
#            noreply address
#   all      all three
#
# history, emails and all take optional revisions: only commits reachable
# from them, and the annotated tags among them (every tag of a nested
# chain), are checked (the pre-push hook passes the shas being pushed).
# Without revisions every ref and every annotated tag is checked, as CI does.
#
# Runs on the repo of the current directory. Content is read from git's
# objects (blobs), not from diffs. The scanner is Betterleaks: one scan with
# its default rules, one with only the denylist rules. The
# denylist (one extended regex per line, case-insensitive, '#' comments and
# blank lines ignored) is read from $WS_DENYLIST, else
# ${XDG_CONFIG_HOME:-$HOME/.config}/ws/denylist. It never lives in the repo.
#
# Output is safe for public CI logs: matches are redacted, rules are named
# denylist-<line number>, objects are named by short sha, and neither paths
# nor emails are printed.
#
# Usage: scripts/privacy-check.sh staged
#        scripts/privacy-check.sh <history|emails|all> [<rev>...]

set -u

TOOLS_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCANNER="$TOOLS_ROOT/.cache/bin/betterleaks"
FETCH="$TOOLS_ROOT/scripts/fetch-tools.sh"
LEAKS_EXIT=3 # distinguishes "leaks found" from scanner errors (exit 1)
NOREPLY_RE='^[0-9]+[+][^@]+@users[.]noreply[.]github[.]com$'

usage() {
    printf 'usage: %s staged\n       %s <history|emails|all> [<rev>...]\n' \
        "$(basename "$0")" "$(basename "$0")" >&2
    exit 2
}

die() {
    printf 'privacy-check: %s\n' "$*" >&2
    exit 1
}

say() {
    printf 'privacy-check: %s\n' "$*"
}

. "$TOOLS_ROOT/scripts/lib/privacy-denylist.sh"
. "$TOOLS_ROOT/scripts/lib/privacy-scan.sh"
. "$TOOLS_ROOT/scripts/lib/privacy-git.sh"

[ $# -ge 1 ] || usage
mode=$1
shift
case $mode in
    staged | history | emails | all) ;;
    *) usage ;;
esac
[ "$mode" != staged ] || [ $# -eq 0 ] || usage

top=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die "not inside a git work tree"

work=$(mktemp -d "${TMPDIR:-/tmp}/privacy-check.XXXXXX") ||
    die "cannot create a temp dir"
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM
work=$(cd "$work" && pwd) # absolute, since the scanner runs in a subdir

# Always goes through the fetch script: it is a no-op when the cached binary
# has the version from tools.lock and replaces it otherwise.
ensure_scanner() {
    "$FETCH" >&2 || die "cannot provide Betterleaks; run $FETCH and retry."
    [ -x "$SCANNER" ] || die "Betterleaks not found at $SCANNER; run $FETCH."
}

# check_content <staged|history>: blobs with both configs, then metadata
# (messages, names, paths, tags) with the denylist config.
check_content() {
    status_c=0
    export_blobs "$1"
    collect_metadata "$1"
    check_ignore_files || status_c=1
    scan_blobs "$1" "$1" || status_c=1
    scan_metadata "$1 metadata" || status_c=1
    return $status_c
}

# ------------------------------------------------------------------ main

if [ "$mode" != staged ]; then
    refuse_shallow
    resolve_scope "$@"
fi
if [ "$mode" != emails ]; then
    build_configs
    ensure_scanner
    prepare_scanner
fi

status=0
case $mode in
    staged) check_content staged || status=1 ;;
    history) check_content history || status=1 ;;
    emails) check_emails || status=1 ;;
    all)
        check_content staged || status=1
        rm -rf "$work/blobs"
        check_content history || status=1
        check_emails || status=1
        ;;
esac
exit $status
