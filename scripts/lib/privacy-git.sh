# Sourced by scripts/privacy-check.sh: reads the git side of the checks
# (scope, metadata, ignore files, emails). Uses $work, $top, $log_revs,
# $tag_objs, die and say from the caller.
#
# $log_revs is "--all" or a list of commit shas; $tag_objs lists the
# annotated tag objects in scope. Both are shas or a fixed option, so they
# are expanded unquoted on purpose.

IGNORE_FILES_RE='(^|/)[.](gitleaks|betterleaks)ignore$'

# log_in_scope <git log args...>
log_in_scope() {
    # shellcheck disable=SC2086
    git -C "$top" -c core.quotePath=false log $log_revs "$@"
}

# Lines of the form "\001<sha>" start a new object; every other non-empty
# line is metadata of that object. append_metadata <kind> reads that stream
# and appends each line to meta.txt and "<kind> <sha>" to meta.idx.
append_metadata() {
    awk -v kind="$1" -v meta="$work/meta.txt" -v idx="$work/meta.idx" '
        /^\001/ { sha = substr($0, 2); next }
        $0 != "" { print >> meta; print kind " " sha >> idx }
    ' || die "cannot write metadata"
}

# Writes $work/paths.txt: the paths each commit in scope changes, merges
# diffed against their first parent (see check_history in privacy-check.sh).
# Every path in any tree in scope is added by some commit in scope, so this
# covers all file and directory names.
list_paths() {
    log_in_scope --diff-merges=first-parent --format='%x01%h' --name-only \
        >"$work/paths.txt" || die "git log failed"
}

# Writes $work/meta.txt and $work/meta.idx: commit messages, author and
# committer names and paths, plus tagger names and messages of the tags in
# scope.
collect_metadata() {
    : >"$work/meta.txt"
    : >"$work/meta.idx"
    log_in_scope --format='%x01%h%n%an%n%cn%n%B' >"$work/log.txt" ||
        die "git log failed"
    append_metadata commit <"$work/log.txt"
    append_metadata commit <"$work/paths.txt"
    for tag in $tag_objs; do
        {
            printf '\001%s\n' "$(git -C "$top" rev-parse --short "$tag")"
            git -C "$top" cat-file tag "$tag" | awk '
                body { print; next }
                /^$/ { body = 1; next }
                /^tagger / { sub(/^tagger /, ""); sub(/ <[^>]*>.*$/, ""); print }
            '
        } >"$work/tag.txt" || die "cannot read tag $tag"
        append_metadata tag <"$work/tag.txt"
    done
}

# check_ignore_files <with_commits>: a .gitleaksignore or .betterleaksignore
# would let the repo hide its own findings, so any of them fails the check:
# in the work tree (tracked or not) or, when <with_commits> is 1, in the
# commits in scope. Only the file name and commit are printed.
check_ignore_files() {
    {
        find "$top" -name .git -prune -o -type f \
            \( -name .gitleaksignore -o -name .betterleaksignore \) -print
        git -C "$top" -c core.quotePath=false ls-files --cached
    } | grep -E "$IGNORE_FILES_RE" | sed 's|.*/||' | sort -u \
        | sed 's/$/ in the work tree/' >"$work/ignored"
    if [ "$1" = 1 ]; then
        awk -v re="$IGNORE_FILES_RE" '
            /^\001/ { sha = substr($0, 2); next }
            $0 ~ re { n = split($0, part, "/"); print part[n] " in commit " sha }
        ' "$work/paths.txt" | sort -u >>"$work/ignored"
    fi
    [ -s "$work/ignored" ] || return 0
    say "ignore files are not allowed, since they hide findings; remove them:"
    sed 's/^/privacy-check:   /' "$work/ignored"
    return 1
}

# Every author, committer and tagger email in scope must be a GitHub
# noreply address. Names the commit or tag, never the email.
check_emails() {
    log_in_scope --format='commit %h%x09author%x09%ae%ncommit %h%x09committer%x09%ce' \
        >"$work/emails" || die "git log failed"
    for tag in $tag_objs; do
        email=$(git -C "$top" cat-file tag "$tag" | awk '
            /^$/ { exit }
            /^tagger / && match($0, /<[^>]*>/) { print substr($0, RSTART + 1, RLENGTH - 2) }
        ')
        [ -z "$email" ] || printf 'tag %s\ttagger\t%s\n' \
            "$(git -C "$top" rev-parse --short "$tag")" "$email" >>"$work/emails"
    done
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
