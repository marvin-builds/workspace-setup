# Sourced by scripts/privacy-check.sh: everything read from git (scope,
# blobs, metadata, ignore files, emails). Uses $work, $top, $log_revs, die
# and say from the caller.
#
# $log_revs is "--all" or a list of commit shas, so it is expanded unquoted
# on purpose. Files written to $work:
#   commits  "<sha> <short sha>" per commit in scope
#   tags     tag object shas in scope, every tag of a nested chain
#   blobs/   one file per blob in scope, named by its object id

# Runs git on the checked repo without anything that changes what git
# reports: no system or global config, attributes or replace refs, and
# overrides for repo-local keys that change output or encoding.
g() {
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_NO_REPLACE_OBJECTS=1 GIT_ATTR_NOSYSTEM=1 \
        git -C "$top" \
        -c color.ui=never -c core.quotePath=false \
        -c log.showRoot=true -c log.showSignature=false \
        -c log.mailmap=false -c mailmap.file= -c mailmap.blob= \
        -c i18n.logOutputEncoding=UTF-8 -c diff.renames=false \
        "$@"
}

g_log() {
    # shellcheck disable=SC2086
    g log $log_revs "$@"
}

g_short() {
    g rev-parse --short "$1"
}

# tag_chain <object>: appends <object> and every tag it points to (nested
# tags) to $work/tags, and prints the first non-tag object.
tag_chain() {
    obj=$1
    while [ "$(g cat-file -t "$obj")" = tag ]; do
        printf '%s\n' "$obj" >>"$work/tags"
        obj=$(g cat-file tag "$obj" | sed -n '1s/^object //p')
        [ -n "$obj" ] || die "cannot read a tag object"
    done
    printf '%s\n' "$obj"
}

# resolve_scope [<rev>...]: sets $log_revs and writes commits and tags. Each
# revision is resolved to a sha, so nothing from the arguments reaches git
# as an option; an annotated tag stays in scope as its tag objects.
resolve_scope() {
    : >"$work/tags"
    log_revs=
    if [ $# -eq 0 ]; then
        log_revs=--all
        g for-each-ref --format='%(objecttype) %(objectname)' refs/tags |
            while read -r type obj; do
                [ "$type" = tag ] && tag_chain "$obj" >/dev/null
            done
    fi
    for rev in "$@"; do
        obj=$(g rev-parse --verify --quiet --end-of-options "$rev^{object}") ||
            die "not a revision: $rev"
        obj=$(tag_chain "$obj") || exit 1
        [ "$(g cat-file -t "$obj")" = commit ] ||
            die "not a commit or a tag of one: $rev"
        log_revs="$log_revs $obj"
    done
    sort -u "$work/tags" -o "$work/tags"
    g_log --format='%H %h' >"$work/commits" || die "git log failed"
}

# export_blobs <history|staged>: writes every blob in scope (reachable from
# the scope, or in the index) to $work/blobs/<object id>, deduplicated.
export_blobs() {
    if [ "$1" = staged ]; then
        g ls-files --format='%(objectname)'
    else
        # shellcheck disable=SC2086
        g rev-list --objects --no-object-names $log_revs
    fi >"$work/objects" || die "cannot list the objects in scope"
    g cat-file --batch-check='%(objecttype) %(objectname)' <"$work/objects" |
        awk '$1 == "blob" { print $2 }' | sort -u >"$work/blob-ids" ||
        die "cannot read the objects in scope"
    mkdir -p "$work/blobs"
    while read -r oid; do
        g cat-file blob "$oid" >"$work/blobs/$oid" || die "cannot read blob $oid"
    done <"$work/blob-ids"
}

# introduced_by <blob id>: the oldest commit in scope that adds the blob.
introduced_by() {
    g_log --find-object="$1" --diff-merges=first-parent --no-patch \
        --reverse --format=%h | head -n 1
}

# append_object <label> <file>: appends each non-empty line of <file> to
# <file>.txt in $work and <label> to the matching line of <file>.idx. The
# label comes from the caller, never from the data, and each object's output
# is read on its own, so no byte in it can start or hide a record. Control
# bytes become spaces so the scanner reads the text as text.
append_object() {
    awk -v label="$1" -v meta="$work/$2.txt" -v idx="$work/$2.idx" '
        { gsub(/[\001-\010\013-\037\177]/, " ") }
        $0 != "" { print >> meta; print label >> idx }
    ' || die "cannot write $2"
}

# Every path a commit adds or changes, merges against their first parent.
# Every path in any tree in scope is added by some commit in scope, so this
# covers all file and directory names.
commit_paths() {
    g diff-tree -r --root --no-commit-id --name-only -z \
        --diff-merges=first-parent "$1" | tr '\0' '\n'
}

# collect_metadata <history|staged>: writes meta.txt/meta.idx (text for the
# denylist scan) and paths.txt/paths.idx (for the ignore-file check). Each
# file starts with a fixed line, so magic bytes at the start of user data
# can't make the scanner skip it as binary.
collect_metadata() {
    for f in meta paths; do
        printf 'privacy-check metadata\n' >"$work/$f.txt"
        printf 'header\n' >"$work/$f.idx"
    done
    if [ "$1" = staged ]; then
        g ls-files -z | tr '\0' '\n' >"$work/object"
        append_object index meta <"$work/object"
        append_object index paths <"$work/object"
        return
    fi
    while read -r sha short; do
        g log -1 --format='%an%n%cn%n%B' "$sha" >"$work/object" ||
            die "git log failed"
        append_object "commit $short" meta <"$work/object"
        commit_paths "$sha" >"$work/object" || die "git diff-tree failed"
        append_object "commit $short" meta <"$work/object"
        append_object "commit $short" paths <"$work/object"
    done <"$work/commits"
    while read -r tag; do
        g cat-file tag "$tag" | awk '
            body { print; next }
            /^$/ { body = 1; next }
            /^tagger / { sub(/^tagger /, ""); sub(/ <[^>]*>.*$/, ""); print }
        ' >"$work/object" || die "cannot read tag $tag"
        append_object "tag $(g_short "$tag")" meta <"$work/object"
    done <"$work/tags"
}

# check_ignore_files: a .gitleaksignore or .betterleaksignore (any letter
# case, symlinks included) would let the repo hide its own findings, so any
# of them fails: in the work tree, the index, or the commits in scope
# (paths.txt). Only the file name and the commit are printed.
check_ignore_files() {
    is_ignore_file='{ n = split($0, p, "/"); b = tolower(p[n]) }
        b == ".gitleaksignore" || b == ".betterleaksignore"'
    {
        find "$top" -name .git -prune -o ! -type d -print
        g ls-files -z | tr '\0' '\n'
    } | awk "$is_ignore_file"' { print p[n] " in the work tree or index" }' |
        sort -u >"$work/ignored"
    awk "NR == FNR { what[NR] = \$0; next }
        $is_ignore_file { print p[n] \" in \" what[FNR] }" \
        "$work/paths.idx" "$work/paths.txt" | sort -u >>"$work/ignored"
    [ -s "$work/ignored" ] || return 0
    say "ignore files are not allowed, since they hide findings; remove them:"
    sed 's/^/privacy-check:   /' "$work/ignored"
    return 1
}

# Every author, committer and tagger email in scope must be a GitHub
# noreply address. Names the commit or tag, never the email.
check_emails() {
    g_log --format='commit %h%x09author%x09%ae%ncommit %h%x09committer%x09%ce' \
        >"$work/emails" || die "git log failed"
    while read -r tag; do
        email=$(g cat-file tag "$tag" | awk '
            /^$/ { exit }
            /^tagger / && match($0, /<[^>]*>/) { print substr($0, RSTART + 1, RLENGTH - 2) }
        ')
        [ -z "$email" ] ||
            printf 'tag %s\ttagger\t%s\n' "$(g_short "$tag")" "$email" >>"$work/emails"
    done <"$work/tags"
    awk -F '\t' -v re="$NOREPLY_RE" '
        $3 !~ re { printf "privacy-check:   %s: %s email is not a GitHub noreply address\n", $1, $2 }
    ' "$work/emails" >"$work/emails.out"
    if [ ! -s "$work/emails.out" ]; then
        say "emails: all author, committer and tagger emails are GitHub noreply addresses"
        return 0
    fi
    say "emails: non-noreply emails found:"
    cat "$work/emails.out"
    return 1
}
