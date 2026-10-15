#!/bin/sh
# Tests for slice 1: repo skeleton files and scripts/privacy-check.sh.
#
# POSIX sh until slice 2 brings bats and tests/run.sh. Each privacy case runs
# in its own temp dir with a throwaway git repo, a throwaway denylist passed
# via WS_DENYLIST, and HOME, XDG_CONFIG_HOME and TMPDIR pointed into that dir,
# so the real ~/.config/ws/denylist and global git config are never read.
#
# Usage: sh tests/privacy.sh
# Prints one "ok"/"not ok" line per case and exits non-zero on any failure.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
CHECK="$REPO_ROOT/scripts/privacy-check.sh"

# Distinctive fake denylisted word. The denylist entry is a regex and matching
# is case-insensitive, so the content uses a different case than the entry.
DENY_WORD=zorblaxcorp
DENY_ENTRY='zorblax(corp|inc)'
DENY_CONTENT='Built for ZorblaxCorp only'
# setup_case writes the entry on line 3 of the throwaway denylist (after a
# comment and a blank line), so a hit must report rule id denylist-3.
DENY_RULE=denylist-3

NOREPLY_EMAIL='12345678+octotest@users.noreply.github.com'
PRIVATE_EMAIL='jane.doe@private-mail.example'

# Fake GitHub personal access token: ghp_ + 36 high-entropy alnum chars.
# Betterleaks v1.9.0 reports it on its own under the default rule github-pat
# (a lone AWS key id is not reported: aws-access-token needs a matching
# secret key nearby). Assembled at runtime so this file never contains the
# full token and the repo's own history scan stays clean.
gh_head=ghp_
gh_tail=8kQz3Rw7NvXp2LmY9TbH4sJc6DfG1aEuK5oV
FAKE_GH_PAT="${gh_head}${gh_tail}"

passed=0
failed=0

# ---------------------------------------------------------------- helpers

ok() {
    passed=$((passed + 1))
    printf 'ok - %s\n' "$1"
}

not_ok() {
    failed=$((failed + 1))
    printf 'not ok - %s\n' "$1"
    shift
    for line in "$@"; do
        printf '#   %s\n' "$line"
    done
}

# Runs one case function in a subshell with its own temp dir. The function
# prints the failure reason on fd 3 and returns non-zero to fail.
run_case() {
    name=$1
    fn=$2
    reason_file=$(mktemp)
    if (
        CASE_DIR=$(mktemp -d)
        trap 'rm -rf "$CASE_DIR"' EXIT
        trap 'exit 1' HUP INT TERM
        setup_case
        "$fn"
    ) 3>"$reason_file"; then
        ok "$name"
    else
        reason=$(cat "$reason_file")
        not_ok "$name" "${reason:-no reason given}"
    fi
    rm -f "$reason_file"
}

fail() {
    printf '%s\n' "$*" >&3
    return 1
}

# Creates the isolated environment inside $CASE_DIR (called in the subshell).
setup_case() {
    mkdir -p "$CASE_DIR/home" "$CASE_DIR/xdg" "$CASE_DIR/tmp" "$CASE_DIR/repo"
    HOME="$CASE_DIR/home"
    XDG_CONFIG_HOME="$CASE_DIR/xdg"
    TMPDIR="$CASE_DIR/tmp"
    WS_DENYLIST="$CASE_DIR/denylist"
    GIT_CONFIG_NOSYSTEM=1
    export HOME XDG_CONFIG_HOME TMPDIR WS_DENYLIST GIT_CONFIG_NOSYSTEM
    unset GIT_AUTHOR_EMAIL GIT_COMMITTER_EMAIL GIT_AUTHOR_NAME \
        GIT_COMMITTER_NAME GIT_DIR GIT_WORK_TREE 2>/dev/null || true
    OUT="$CASE_DIR/out.txt"

    {
        printf '# throwaway denylist for tests\n'
        printf '\n'
        printf '%s\n' "$DENY_ENTRY"
    } >"$WS_DENYLIST"

    REPO="$CASE_DIR/repo"
    git -C "$REPO" init -q
    git -C "$REPO" symbolic-ref HEAD refs/heads/main
    git -C "$REPO" config user.name 'Test User'
    git -C "$REPO" config user.email "$NOREPLY_EMAIL"
    git -C "$REPO" config commit.gpgsign false
}

# commit <message> <file> <content>: writes, stages and commits a file.
commit_file() {
    printf '%s\n' "$3" >"$REPO/$2"
    git -C "$REPO" add "$2"
    git -C "$REPO" commit -q -m "$1"
}

# stage_file <file> <content>
stage_file() {
    printf '%s\n' "$2" >"$REPO/$1"
    git -C "$REPO" add "$1"
}

# make_dirty_side_branch: main gets a clean commit; branch "backup" (not
# checked out afterwards) gets a commit with a private author email and a
# denylisted word (in that order). Sets $main_sha, $side_sha (tip of backup)
# and $priv_sha/$priv_short (the private-email commit, parent of the tip).
make_dirty_side_branch() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    main_sha=$(git -C "$REPO" rev-parse HEAD)
    git -C "$REPO" checkout -q -b backup
    git -C "$REPO" -c user.email="$PRIVATE_EMAIL" commit -q --allow-empty \
        -m 'Backup before rewrite'
    commit_file 'Old notes' notes.txt "$DENY_CONTENT"
    side_sha=$(git -C "$REPO" rev-parse HEAD)
    priv_sha=$(git -C "$REPO" rev-parse HEAD~1)
    priv_short=$(git -C "$REPO" rev-parse --short=7 HEAD~1)
    git -C "$REPO" checkout -q main
}

ZERO_SHA=0000000000000000000000000000000000000000
HOOK_PRE_PUSH="$REPO_ROOT/.githooks/pre-push"

# push_hook <stdin text>: runs the real pre-push hook (from its place in this
# repo, not copied) with the throwaway repo as cwd, output to $OUT, sets $rc.
push_hook() {
    if [ ! -x "$HOOK_PRE_PUSH" ]; then
        fail "hook missing or not executable: .githooks/pre-push"
        return 1
    fi
    rc=0
    printf '%s' "$1" >"$CASE_DIR/push-stdin"
    (cd "$REPO" && "$HOOK_PRE_PUSH" origin "https://example.invalid/repo.git" \
        <"$CASE_DIR/push-stdin") >"$OUT" 2>&1 || rc=$?
    return 0
}

# check <mode> [rev...]: runs the script under test in $REPO, output to $OUT,
# sets $rc.
check() {
    if [ ! -f "$CHECK" ]; then
        fail "script missing: scripts/privacy-check.sh"
        return 1
    fi
    if [ ! -x "$CHECK" ]; then
        fail "script not executable: scripts/privacy-check.sh"
        return 1
    fi
    rc=0
    (cd "$REPO" && "$CHECK" "$@") >"$OUT" 2>&1 || rc=$?
    return 0
}

expect_rc_zero() {
    [ "$rc" -eq 0 ] && return 0
    fail "$1: expected exit 0, got $rc; output: $(head -c 400 "$OUT" | tr '\n' ' ')"
}

expect_rc_nonzero() {
    [ "$rc" -ne 0 ] && return 0
    fail "$1: expected non-zero exit, got 0"
}

# expect_absent <label> <text>: the text must not appear in the output.
expect_absent() {
    if grep -qiF -- "$2" "$OUT"; then
        fail "$1: output leaks '$2'"
        return 1
    fi
}

expect_no_deny_word() {
    expect_absent "$1" zorblax
}

# Evidence that a failure is a real finding, not an error such as a usage
# message or a missing script.

# expect_shown <label> <what> <extended regex>
expect_shown() {
    grep -qE -- "$3" "$OUT" && return 0
    fail "$1: output lacks $2; output: $(head -c 400 "$OUT" | tr '\n' ' ')"
}

expect_deny_rule() {
    expect_shown "$1" "rule id $DENY_RULE" "(^|[^0-9A-Za-z-])$DENY_RULE([^0-9]|\$)"
}

expect_secret_rule() {
    expect_shown "$1" "rule id github-pat" 'github-pat'
}

# expect_commit <label> <short sha>
expect_commit() {
    expect_shown "$1" "commit $2" "$2"
}

expect_denylist_hint() {
    grep -qi denylist "$OUT" && return 0
    fail "$1: no hint mentioning the denylist; output: $(head -c 400 "$OUT" | tr '\n' ' ')"
}

expect_tmp_empty() {
    if [ -n "$(ls -A "$TMPDIR")" ]; then
        fail "$1: temp files left in TMPDIR: $(ls -A "$TMPDIR" | tr '\n' ' ')"
        return 1
    fi
}

# --------------------------------------------------------- privacy cases

case_clean_commit_passes() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file notes.txt 'Another harmless line.'
    check all || return 1
    expect_rc_zero "all" || return 1
    expect_no_deny_word "all"
}

case_staged_deny_word_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file notes.txt "$DENY_CONTENT"
    check staged || return 1
    expect_rc_nonzero "staged" || return 1
    expect_no_deny_word "staged" || return 1
    expect_deny_rule "staged"
}

case_old_commit_deny_word_fails_history() {
    commit_file 'Add notes' notes.txt "$DENY_CONTENT"
    commit_file 'Clean notes' notes.txt 'Nothing to see here.'
    check staged || return 1
    expect_rc_zero "staged (word only in history)" || return 1
    expect_no_deny_word "staged" || return 1
    check history || return 1
    expect_rc_nonzero "history" || return 1
    expect_no_deny_word "history" || return 1
    expect_deny_rule "history"
}

case_private_author_email_fails() {
    git -C "$REPO" config user.email "$PRIVATE_EMAIL"
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    sha=$(git -C "$REPO" rev-parse --short=7 HEAD)
    check emails || return 1
    expect_rc_nonzero "emails" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL" || return 1
    expect_absent "emails" "private-mail" || return 1
    expect_commit "emails" "$sha"
}

case_private_committer_email_fails() {
    printf 'x\n' >"$REPO/README.md"
    git -C "$REPO" add README.md
    GIT_COMMITTER_EMAIL="$PRIVATE_EMAIL" git -C "$REPO" commit -q -m 'Add readme'
    sha=$(git -C "$REPO" rev-parse --short=7 HEAD)
    check emails || return 1
    expect_rc_nonzero "emails" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL" || return 1
    expect_commit "emails" "$sha"
}

case_private_email_on_other_branch_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" checkout -q -b side
    git -C "$REPO" config user.email "$PRIVATE_EMAIL"
    commit_file 'Side change' side.txt 'side'
    sha=$(git -C "$REPO" rev-parse --short=7 HEAD)
    git -C "$REPO" checkout -q -
    check emails || return 1
    expect_rc_nonzero "emails (git log --all)" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL" || return 1
    expect_commit "emails" "$sha"
}

case_noreply_email_passes() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    commit_file 'Add notes' notes.txt 'More harmless text.'
    check emails || return 1
    expect_rc_zero "emails"
}

case_missing_denylist_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    rm -f "$WS_DENYLIST"
    check staged || return 1
    expect_rc_nonzero "staged with WS_DENYLIST pointing to missing file" || return 1
    expect_denylist_hint "staged"
}

case_default_denylist_path_missing_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    unset WS_DENYLIST
    check history || return 1
    expect_rc_nonzero "history without WS_DENYLIST and no XDG denylist" || return 1
    expect_denylist_hint "history"
}

case_default_denylist_path_is_used() {
    # Without WS_DENYLIST the script must read $XDG_CONFIG_HOME/ws/denylist.
    mkdir -p "$XDG_CONFIG_HOME/ws"
    mv "$WS_DENYLIST" "$XDG_CONFIG_HOME/ws/denylist"
    unset WS_DENYLIST
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file notes.txt "$DENY_CONTENT"
    check staged || return 1
    expect_rc_nonzero "staged with XDG denylist" || return 1
    expect_no_deny_word "staged" || return 1
    expect_deny_rule "staged"
}

case_empty_denylist_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    printf '# only a comment\n\n   \n' >"$WS_DENYLIST"
    check staged || return 1
    expect_rc_nonzero "staged with denylist of only comments/blanks" || return 1
    expect_denylist_hint "staged"
}

case_fake_github_token_fails_staged() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file config.ini "github_token = $FAKE_GH_PAT"
    check staged || return 1
    expect_rc_nonzero "staged with fake GitHub token" || return 1
    expect_absent "staged" "$FAKE_GH_PAT" || return 1
    expect_absent "staged" "$gh_tail" || return 1
    expect_secret_rule "staged"
}

case_no_temp_files_left() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    check staged || return 1
    expect_rc_zero "staged (clean)" || return 1
    expect_tmp_empty "after passing staged" || return 1
    stage_file notes.txt "$DENY_CONTENT"
    check staged || return 1
    expect_rc_nonzero "staged (deny word)" || return 1
    expect_deny_rule "staged (deny word)" || return 1
    expect_tmp_empty "after failing staged" || return 1
    check history || return 1
    expect_tmp_empty "after history" || return 1
    printf '# empty\n' >"$WS_DENYLIST"
    check staged || return 1
    expect_rc_nonzero "staged (empty denylist)" || return 1
    expect_denylist_hint "staged (empty denylist)" || return 1
    expect_tmp_empty "after empty-denylist error"
}

# ------------------------------------------- revision scope (<mode> <rev>)

case_emails_rev_skips_unreachable_branch() {
    make_dirty_side_branch
    check emails main || return 1
    expect_rc_zero "emails main (private email only on backup)" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL"
}

case_emails_rev_fails_when_reachable() {
    make_dirty_side_branch
    check emails backup || return 1
    expect_rc_nonzero "emails backup" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL" || return 1
    expect_commit "emails backup" "$priv_short"
}

case_history_rev_skips_unreachable_branch() {
    make_dirty_side_branch
    check history main || return 1
    expect_rc_zero "history main (word only on backup)" || return 1
    expect_no_deny_word "history"
}

case_history_rev_fails_when_reachable() {
    make_dirty_side_branch
    check history "$side_sha" || return 1
    expect_rc_nonzero "history <backup sha>" || return 1
    expect_no_deny_word "history" || return 1
    expect_deny_rule "history <backup sha>"
}

case_history_no_rev_covers_all_refs() {
    make_dirty_side_branch
    check history || return 1
    expect_rc_nonzero "history with no rev (word only on backup)" || return 1
    expect_no_deny_word "history" || return 1
    expect_deny_rule "history with no rev"
}

# ------------------------------------------------------ pre-push behaviour

case_pre_push_clean_branch_passes() {
    make_dirty_side_branch
    push_hook "refs/heads/main $main_sha refs/heads/main $ZERO_SHA
" || return 1
    expect_rc_zero "pre-push main (dirty backup branch not pushed)" || return 1
    expect_no_deny_word "pre-push" || return 1
    expect_absent "pre-push" "$PRIVATE_EMAIL"
}

case_pre_push_dirty_branch_fails() {
    make_dirty_side_branch
    push_hook "refs/heads/backup $side_sha refs/heads/backup $ZERO_SHA
" || return 1
    expect_rc_nonzero "pre-push backup" || return 1
    expect_no_deny_word "pre-push" || return 1
    expect_absent "pre-push" "$PRIVATE_EMAIL" || return 1
    expect_deny_rule "pre-push backup"
}

case_pre_push_private_email_fails() {
    # Push only up to the private-email commit, which has no denylisted word,
    # so the email check alone must catch it.
    make_dirty_side_branch
    push_hook "refs/heads/backup $priv_sha refs/heads/backup $ZERO_SHA
" || return 1
    expect_rc_nonzero "pre-push backup~1 (private email only)" || return 1
    expect_absent "pre-push" "$PRIVATE_EMAIL" || return 1
    expect_commit "pre-push backup~1" "$priv_short"
}

case_pre_push_deletion_passes() {
    make_dirty_side_branch
    push_hook "(delete) $ZERO_SHA refs/heads/backup $side_sha
" || return 1
    expect_rc_zero "pre-push deleting backup" || return 1
    expect_no_deny_word "pre-push"
}

case_pre_push_empty_stdin_passes() {
    make_dirty_side_branch
    push_hook "" || return 1
    expect_rc_zero "pre-push with nothing to push" || return 1
    expect_no_deny_word "pre-push"
}

# ------------------------------------- review round 1 (criteria 11 to 15)

# add_deny_entry <regex>: appends an entry to the throwaway denylist and sets
# $added_rule to its rule id (denylist-<line number>).
add_deny_entry() {
    printf '%s\n' "$1" >>"$WS_DENYLIST"
    added_rule="denylist-$(wc -l <"$WS_DENYLIST" | tr -d ' ')"
}

# expect_rule <label> <rule id>: the output shows that exact rule id.
expect_rule() {
    expect_shown "$1" "rule id $2" "(^|[^0-9A-Za-z-])$2([^0-9]|\$)"
}

# staged_deny_hit <file> <content>: a staged file with a denylisted word must
# fail `staged` with rule id denylist-3 and without the word.
staged_deny_hit() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    mkdir -p "$(dirname "$REPO/$1")"
    stage_file "$1" "$2"
    check staged || return 1
    expect_rc_nonzero "staged $1" || return 1
    expect_no_deny_word "staged $1" || return 1
    expect_deny_rule "staged $1"
}

# 11: Betterleaks' default allowlists and filters must not drop denylist hits.

case_deny_hit_in_svg() {
    staged_deny_hit logo.svg '<svg><text>ZorblaxCorp</text></svg>'
}

case_deny_hit_in_lock_file() {
    staged_deny_hit package-lock.json '{ "name": "ZorblaxCorp" }'
}

case_deny_hit_in_vendor_dir() {
    staged_deny_hit vendor/lib/readme.txt "$DENY_CONTENT"
}

case_deny_hit_home_path() {
    add_deny_entry '/home/zorblaxuser'
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file setup.sh 'cd /home/zorblaxuser/dev'
    check staged || return 1
    expect_rc_nonzero "staged /home/<user> path" || return 1
    expect_no_deny_word "staged" || return 1
    expect_rule "staged" "$added_rule"
}

# 12: no suppression from inside the repo.

case_inline_allow_comments_ignored() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    for marker in betterleaks:allow gitleaks:allow; do
        stage_file c.txt "ZorblaxCorp $marker"
        check staged || return 1
        expect_rc_nonzero "staged with $marker" || return 1
        expect_no_deny_word "staged with $marker" || return 1
        expect_deny_rule "staged with $marker" || return 1
        git -C "$REPO" rm -q --cached c.txt
    done
}

case_untracked_gitleaksignore_fails() {
    commit_file 'Add notes' c.txt "$DENY_CONTENT"
    sha=$(git -C "$REPO" rev-parse HEAD)
    printf '%s:c.txt:%s:1\n' "$sha" "$DENY_RULE" >"$REPO/.gitleaksignore"
    check history || return 1
    expect_rc_nonzero "history with untracked .gitleaksignore" || return 1
    expect_no_deny_word "history" || return 1
    expect_shown "history" "the name .gitleaksignore" '\.gitleaksignore'
}

case_committed_betterleaksignore_fails() {
    commit_file 'Add notes' c.txt "$DENY_CONTENT"
    sha=$(git -C "$REPO" rev-parse HEAD)
    commit_file 'Ignore finding' .betterleaksignore "$sha:c.txt:$DENY_RULE:1"
    check history || return 1
    expect_rc_nonzero "history with committed .betterleaksignore" || return 1
    expect_no_deny_word "history" || return 1
    expect_shown "history" "the name .betterleaksignore" '\.betterleaksignore'
}

# 13: content added only by a merge commit.

case_evil_merge_fails_history() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" checkout -q -b side
    commit_file 'Side change' side.txt 'side'
    git -C "$REPO" checkout -q main
    commit_file 'Main change' main.txt 'main'
    git -C "$REPO" merge -q --no-ff --no-commit side >/dev/null 2>&1
    stage_file evil.txt "$DENY_CONTENT"
    git -C "$REPO" commit -q -m 'Merge side'
    git -C "$REPO" rev-parse -q --verify HEAD^2 >/dev/null ||
        { fail "fixture: HEAD is not a merge commit"; return 1; }
    check history || return 1
    expect_rc_nonzero "history with word only in a merge" || return 1
    expect_no_deny_word "history" || return 1
    expect_deny_rule "history"
}

# 14: metadata is checked against the denylist.

# history_deny_hit <label> [rev...]: history (or all <rev>) must fail with
# denylist-3 and without the word.
history_deny_hit() {
    label=$1
    shift
    check "$@" || return 1
    expect_rc_nonzero "$label" || return 1
    expect_no_deny_word "$label" || return 1
    expect_deny_rule "$label"
}

case_commit_message_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" commit -q --allow-empty -m "$DENY_CONTENT"
    history_deny_hit "history with word in commit message" history
}

case_author_name_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    GIT_AUTHOR_NAME='ZorblaxCorp Bot' git -C "$REPO" commit -q --allow-empty \
        -m 'Routine update'
    history_deny_hit "history with word in author name" history
}

case_committer_name_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    GIT_COMMITTER_NAME='ZorblaxCorp Bot' git -C "$REPO" commit -q --allow-empty \
        -m 'Routine update'
    history_deny_hit "history with word in committer name" history
}

case_file_path_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    commit_file 'Add notes' zorblaxcorp-notes.txt 'Nothing to see here.'
    history_deny_hit "history with word in file name" history
}

case_dir_path_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    mkdir -p "$REPO/ZorblaxInc"
    commit_file 'Add notes' ZorblaxInc/notes.txt 'Nothing to see here.'
    history_deny_hit "history with word in directory name" history
}

# make_annotated_tag <message> [git -c option...]: clean commit on main and an
# annotated tag v1 on it. Sets $tag_sha (the tag object) and $tag_short.
make_annotated_tag() {
    msg=$1
    shift
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" "$@" tag -a v1 -m "$msg"
    tag_sha=$(git -C "$REPO" rev-parse refs/tags/v1)
    tag_short=$(git -C "$REPO" rev-parse --short=7 refs/tags/v1)
}

case_tag_message_fails_all_tag() {
    make_annotated_tag "$DENY_CONTENT"
    history_deny_hit "all v1 with word in tag message" all v1
}

case_tag_message_fails_pre_push() {
    make_annotated_tag "$DENY_CONTENT"
    push_hook "refs/tags/v1 $tag_sha refs/tags/v1 $ZERO_SHA
" || return 1
    expect_rc_nonzero "pre-push refs/tags/v1" || return 1
    expect_no_deny_word "pre-push" || return 1
    expect_deny_rule "pre-push refs/tags/v1"
}

case_tagger_name_fails() {
    make_annotated_tag 'Release one' -c user.name='ZorblaxCorp Bot'
    history_deny_hit "history v1 with word in tagger name" history v1
}

case_tagger_email_fails_emails() {
    make_annotated_tag 'Release one' -c user.email="$PRIVATE_EMAIL"
    check emails v1 || return 1
    expect_rc_nonzero "emails v1 with private tagger email" || return 1
    expect_absent "emails v1" "$PRIVATE_EMAIL" || return 1
    expect_absent "emails v1" "private-mail" || return 1
    expect_shown "emails v1" "the tag ($tag_short or v1)" \
        "$tag_short|(^|[^0-9A-Za-z.])v1([^0-9A-Za-z.]|\$)"
}

# 15: paths are never printed for a finding.

case_paths_never_printed() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    mkdir -p "$REPO/qqdirmarker"
    commit_file 'Add notes' qqdirmarker/qqpathmarker.txt "$DENY_CONTENT"
    sha=$(git -C "$REPO" rev-parse --short=7 HEAD)
    check history || return 1
    expect_rc_nonzero "history" || return 1
    expect_deny_rule "history" || return 1
    expect_commit "history" "$sha" || return 1
    expect_absent "history" qqpathmarker || return 1
    expect_absent "history" qqdirmarker || return 1
    expect_no_deny_word "history" || return 1
    commit_file 'Clean notes' qqdirmarker/qqpathmarker.txt 'Nothing here.'
    stage_file qqstagedmarker.txt "$DENY_CONTENT"
    stage_file qqsecretmarker.ini "github_token = $FAKE_GH_PAT"
    check staged || return 1
    expect_rc_nonzero "staged" || return 1
    expect_deny_rule "staged" || return 1
    expect_secret_rule "staged" || return 1
    expect_shown "staged" "the word index" 'index' || return 1
    expect_absent "staged" qqstagedmarker || return 1
    expect_absent "staged" qqsecretmarker || return 1
    expect_absent "staged" "$gh_tail" || return 1
    expect_no_deny_word "staged"
}

# 16 (scanner version checked on every run) is not tested here: it needs a
# stub binary in the repo's own .cache/bin/, which tests must not touch.

# ------------------------------------- review round 2 (criteria 17 to 22)

# staged_then_history_hit <label>: $REPO has a staged denylist hit in
# notes.txt. `staged` must fail, then after committing it `history` must
# fail, both with denylist-3 and without the word.
staged_then_history_hit() {
    check staged || return 1
    expect_rc_nonzero "staged ($1)" || return 1
    expect_no_deny_word "staged ($1)" || return 1
    expect_deny_rule "staged ($1)" || return 1
    git -C "$REPO" commit -q -m 'Add notes'
    check history || return 1
    expect_rc_nonzero "history ($1)" || return 1
    expect_no_deny_word "history ($1)" || return 1
    expect_deny_rule "history ($1)"
}

case_attr_no_diff_hides_nothing() {
    commit_file 'Add attributes' .gitattributes '*.txt -diff'
    stage_file notes.txt "$DENY_CONTENT"
    staged_then_history_hit '*.txt -diff'
}

case_attr_binary_hides_nothing() {
    commit_file 'Add attributes' .gitattributes '*.txt binary'
    stage_file notes.txt "$DENY_CONTENT"
    staged_then_history_hit '*.txt binary'
}

case_nul_byte_file_scanned() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    printf 'ZorblaxCorp\000\n' >"$REPO/notes.txt"
    git -C "$REPO" add notes.txt
    staged_then_history_hit 'file with NUL byte'
}

case_color_ui_always() {
    git -C "$REPO" config color.ui always
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file notes.txt "$DENY_CONTENT"
    staged_then_history_hit 'color.ui=always'
}

case_log_showroot_false() {
    git -C "$REPO" config log.showRoot false
    commit_file 'Add notes' notes.txt "$DENY_CONTENT"
    history_deny_hit "history, single root commit, log.showRoot=false" history
}

# make_replaced_commit: main has a clean commit, then $bad (word in message,
# private author email), which a replace ref hides behind a clean commit.
make_replaced_commit() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" -c user.email="$PRIVATE_EMAIL" commit -q --allow-empty \
        -m "$DENY_CONTENT"
    bad=$(git -C "$REPO" rev-parse HEAD)
    bad_short=$(git -C "$REPO" rev-parse --short=7 HEAD)
    clean=$(git -C "$REPO" commit-tree -p HEAD~1 -m clean 'HEAD^{tree}')
    git -C "$REPO" replace "$bad" "$clean"
}

case_replace_ref_pre_push() {
    make_replaced_commit
    push_hook "refs/heads/main $bad refs/heads/main $ZERO_SHA
" || return 1
    expect_rc_nonzero "pre-push of a replaced commit" || return 1
    expect_no_deny_word "pre-push" || return 1
    expect_absent "pre-push" "$PRIVATE_EMAIL" || return 1
    expect_deny_rule "pre-push of a replaced commit"
}

case_replace_ref_emails() {
    make_replaced_commit
    check emails "$bad" || return 1
    expect_rc_nonzero "emails <replaced commit>" || return 1
    expect_absent "emails" "$PRIVATE_EMAIL" || return 1
    expect_commit "emails <replaced commit>" "$bad_short"
}

case_hit_names_introducing_commit_and_blob() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    commit_file 'Add notes' notes.txt "$DENY_CONTENT"
    intro_short=$(git -C "$REPO" rev-parse --short=7 HEAD)
    blob_short=$(git -C "$REPO" rev-parse --short=7 HEAD:notes.txt)
    commit_file 'Later change' other.txt 'Unrelated.'
    commit_file 'Even later' other.txt 'Still unrelated.'
    check history || return 1
    expect_rc_nonzero "history" || return 1
    expect_no_deny_word "history" || return 1
    expect_deny_rule "history" || return 1
    expect_commit "history (introducing commit)" "$intro_short" || return 1
    expect_shown "history" "blob $blob_short" "$blob_short"
}

# 19: ignore files as symlinks and in any letter case.

case_symlinked_gitleaksignore_fails() {
    commit_file 'Add notes' c.txt "$DENY_CONTENT"
    sha=$(git -C "$REPO" rev-parse HEAD)
    printf '%s:c.txt:%s:1\n' "$sha" "$DENY_RULE" >"$CASE_DIR/fp"
    ln -s ../fp "$REPO/.gitleaksignore"
    check history || return 1
    expect_rc_nonzero "history with symlinked .gitleaksignore" || return 1
    expect_no_deny_word "history" || return 1
    expect_shown "history" "the name .gitleaksignore" '\.gitleaksignore'
}

case_mixed_case_gitleaksignore_fails() {
    commit_file 'Add notes' c.txt "$DENY_CONTENT"
    sha=$(git -C "$REPO" rev-parse HEAD)
    printf '%s:c.txt:%s:1\n' "$sha" "$DENY_RULE" >"$REPO/.GitleaksIgnore"
    check history || return 1
    expect_rc_nonzero "history with .GitleaksIgnore" || return 1
    expect_no_deny_word "history" || return 1
    expect_shown "history" "the name .GitleaksIgnore" '\.[Gg]itleaks[Ii]gnore'
}

# 20: control bytes in metadata neither hide a line nor reach the output.

case_control_byte_in_message() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    printf 'Subject\n\n\001ZorblaxCorp\n' >"$CASE_DIR/msg"
    git -C "$REPO" commit -q --allow-empty -F "$CASE_DIR/msg"
    history_deny_hit "history with control byte before word" history || return 1
    if grep -q "$(printf '\001')" "$OUT"; then
        fail "history: output contains byte 0x01"
        return 1
    fi
}

# 21: every tag object in a chain is checked.

make_nested_tag() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    git -C "$REPO" -c user.email="$PRIVATE_EMAIL" tag -a inner -m "$DENY_CONTENT"
    inner_short=$(git -C "$REPO" rev-parse --short=7 refs/tags/inner)
    git -C "$REPO" -c advice.nestedTag=false tag -a outer -m outer inner \
        2>/dev/null
    git -C "$REPO" tag -d inner >/dev/null
    outer_short=$(git -C "$REPO" rev-parse --short=7 refs/tags/outer)
}

case_nested_tag_history() {
    make_nested_tag
    history_deny_hit "history outer (word in inner tag)" history outer
}

case_nested_tag_emails() {
    make_nested_tag
    check emails outer || return 1
    expect_rc_nonzero "emails outer (private inner tagger)" || return 1
    expect_absent "emails outer" "$PRIVATE_EMAIL" || return 1
    expect_shown "emails outer" "the tag ($inner_short, $outer_short or a tag name)" \
        "$inner_short|$outer_short|(^|[^0-9A-Za-z.])(inner|outer)([^0-9A-Za-z.]|\$)"
}

# 22: staged paths are checked.

case_staged_path_fails() {
    commit_file 'Add readme' README.md 'Just a harmless readme.'
    stage_file zorblaxinc.txt 'Nothing to see here.'
    check staged || return 1
    expect_rc_nonzero "staged with word in file name" || return 1
    expect_no_deny_word "staged" || return 1
    expect_deny_rule "staged"
}

# ----------------------------------------------------------- hook checks

# hook_calls <hook> <mode>: hook file runs privacy-check.sh with <mode>.
hook_calls() {
    grep -E "privacy-check\.sh[\"']?[[:space:]]+[\"']?$2([\"'[:space:]]|$)" \
        "$REPO_ROOT/.githooks/$1" >/dev/null
}

case_hooks() {
    for hook in pre-commit pre-push; do
        f="$REPO_ROOT/.githooks/$hook"
        [ -f "$f" ] || { fail ".githooks/$hook missing"; return 1; }
        [ -x "$f" ] || { fail ".githooks/$hook not executable"; return 1; }
    done
    hook_calls pre-commit staged ||
        { fail "pre-commit does not call privacy-check.sh staged"; return 1; }
    hook_calls pre-push history ||
        { fail "pre-push does not call privacy-check.sh history"; return 1; }
    hook_calls pre-push emails ||
        fail "pre-push does not call privacy-check.sh emails"
}

# ------------------------------------------------------ file-level checks

case_chezmoiroot() {
    f="$REPO_ROOT/.chezmoiroot"
    [ -f "$f" ] || { fail ".chezmoiroot missing"; return 1; }
    [ "$(cat "$f")" = home ] || fail ".chezmoiroot is '$(cat "$f")', want 'home'"
}

case_chezmoiversion() {
    f="$REPO_ROOT/home/.chezmoiversion"
    [ -f "$f" ] || { fail "home/.chezmoiversion missing"; return 1; }
    [ "$(cat "$f")" = 2.73.1 ] ||
        fail "home/.chezmoiversion is '$(cat "$f")', want '2.73.1'"
}

# attr_is <path> <attr> <value>: git check-attr reports <value> for <path>.
attr_is() {
    got=$(git -C "$REPO_ROOT" check-attr "$2" -- "$1" | sed 's/^.*: //')
    [ "$got" = "$3" ] && return 0
    fail ".gitattributes: $2 for $1 is '$got', want '$3'"
}

case_gitattributes() {
    [ -f "$REPO_ROOT/.gitattributes" ] || { fail ".gitattributes missing"; return 1; }
    attr_is README.md text auto || return 1
    attr_is tests/privacy.sh eol lf || return 1
    attr_is scripts/privacy-check.sh eol lf || return 1
    attr_is scripts/some-extensionless-tool eol lf || return 1
    attr_is .githooks/pre-commit eol lf || return 1
    attr_is .githooks/pre-push eol lf || return 1
    attr_is home/some/setup.ps1 eol crlf
}

case_gitignore() {
    [ -f "$REPO_ROOT/.gitignore" ] || { fail ".gitignore missing"; return 1; }
    for p in .cache/bin/betterleaks .DS_Store Thumbs.db notes.txt.swp; do
        git -C "$REPO_ROOT" check-ignore -q --no-index -- "$p" ||
            { fail ".gitignore does not ignore $p"; return 1; }
    done
    git -C "$REPO_ROOT" check-ignore -q --no-index -- scripts/privacy-check.sh &&
        { fail ".gitignore ignores scripts/privacy-check.sh"; return 1; }
    return 0
}

case_license() {
    f="$REPO_ROOT/LICENSE"
    [ -f "$f" ] || { fail "LICENSE missing"; return 1; }
    grep -q '^MIT License' "$f" || { fail "LICENSE is not MIT"; return 1; }
    grep -qF 'Copyright (c) 2026 Marvin Mai' "$f" ||
        fail "LICENSE lacks 'Copyright (c) 2026 Marvin Mai'"
}

# -------------------------------------------------------------------- run

run_case "file: .chezmoiroot contains home" case_chezmoiroot
run_case "file: home/.chezmoiversion contains 2.73.1" case_chezmoiversion
run_case "file: .gitattributes text=auto, lf for sh/scripts/hooks, crlf for ps1" case_gitattributes
run_case "file: .gitignore covers .cache/ and editor/OS litter" case_gitignore
run_case "file: LICENSE is MIT with 2026 Marvin Mai" case_license
run_case "hooks: pre-commit runs staged, pre-push runs history and emails" case_hooks
run_case "all: clean commit and clean staged change pass" case_clean_commit_passes
run_case "staged: denylisted word (regex, other case) fails, redacted" case_staged_deny_word_fails
run_case "history: denylisted word only in old commit fails, redacted" case_old_commit_deny_word_fails_history
run_case "emails: private author email fails, names commit not email" case_private_author_email_fails
run_case "emails: private committer email fails" case_private_committer_email_fails
run_case "emails: private email on another branch fails" case_private_email_on_other_branch_fails
run_case "emails: noreply email passes" case_noreply_email_passes
run_case "denylist: WS_DENYLIST pointing to missing file fails with hint" case_missing_denylist_fails
run_case "denylist: no WS_DENYLIST and no default file fails with hint" case_default_denylist_path_missing_fails
run_case "denylist: default XDG path is used without WS_DENYLIST" case_default_denylist_path_is_used
run_case "denylist: only comments and blanks fails with hint" case_empty_denylist_fails
run_case "staged: fake GitHub token (github-pat) fails, redacted" case_fake_github_token_fails_staged
run_case "cleanup: no temp files left on pass, fail and error paths" case_no_temp_files_left
run_case "scope: emails <rev> ignores private email on unreachable branch" case_emails_rev_skips_unreachable_branch
run_case "scope: emails <rev> fails when private email is reachable" case_emails_rev_fails_when_reachable
run_case "scope: history <rev> ignores word on unreachable branch" case_history_rev_skips_unreachable_branch
run_case "scope: history <rev> fails when word is reachable, redacted" case_history_rev_fails_when_reachable
run_case "scope: history without rev covers all refs" case_history_no_rev_covers_all_refs
run_case "pre-push: clean branch passes while a dirty branch exists locally" case_pre_push_clean_branch_passes
run_case "pre-push: dirty branch fails, redacted" case_pre_push_dirty_branch_fails
run_case "pre-push: private email in pushed commits fails, names commit" case_pre_push_private_email_fails
run_case "pre-push: deletion line passes" case_pre_push_deletion_passes
run_case "pre-push: empty stdin passes" case_pre_push_empty_stdin_passes
run_case "11: denylist hit in *.svg fails staged" case_deny_hit_in_svg
run_case "11: denylist hit in package-lock.json fails staged" case_deny_hit_in_lock_file
run_case "11: denylist hit under vendor/ fails staged" case_deny_hit_in_vendor_dir
run_case "11: denylist entry matching /home/<user> fails staged" case_deny_hit_home_path
run_case "12: inline betterleaks:allow / gitleaks:allow are ignored" case_inline_allow_comments_ignored
run_case "12: untracked .gitleaksignore fails history, named" case_untracked_gitleaksignore_fails
run_case "12: committed .betterleaksignore fails history, named" case_committed_betterleaksignore_fails
run_case "13: content added only by a merge fails history" case_evil_merge_fails_history
run_case "14: word in commit message fails history" case_commit_message_fails
run_case "14: word in author name fails history" case_author_name_fails
run_case "14: word in committer name fails history" case_committer_name_fails
run_case "14: word in file name fails history" case_file_path_fails
run_case "14: word in directory name fails history" case_dir_path_fails
run_case "14: word in annotated tag message fails all v1" case_tag_message_fails_all_tag
run_case "14: word in annotated tag message fails pre-push of the tag" case_tag_message_fails_pre_push
run_case "14: word in tagger name fails history v1" case_tagger_name_fails
run_case "14: private tagger email fails emails v1" case_tagger_email_fails_emails
run_case "15: finding output never contains file or dir paths" case_paths_never_printed
run_case "18: .gitattributes '*.txt -diff' hides nothing" case_attr_no_diff_hides_nothing
run_case "18: .gitattributes '*.txt binary' hides nothing" case_attr_binary_hides_nothing
run_case "17: file with a NUL byte is scanned" case_nul_byte_file_scanned
run_case "18: color.ui=always does not hide hits" case_color_ui_always
run_case "18: log.showRoot=false does not hide a root commit" case_log_showroot_false
run_case "18: replace ref does not hide a pushed commit (pre-push)" case_replace_ref_pre_push
run_case "18: replace ref does not hide a private email (emails <rev>)" case_replace_ref_emails
run_case "17: history hit names introducing commit and blob" case_hit_names_introducing_commit_and_blob
run_case "19: symlinked .gitleaksignore fails history, named" case_symlinked_gitleaksignore_fails
run_case "19: .GitleaksIgnore (mixed case) fails history, named" case_mixed_case_gitleaksignore_fails
run_case "20: control byte in commit message: hit, no 0x01 in output" case_control_byte_in_message
run_case "21: nested tag message fails history outer" case_nested_tag_history
run_case "21: nested tag private tagger email fails emails outer" case_nested_tag_emails
run_case "22: word in staged file name fails staged" case_staged_path_fails

total=$((passed + failed))
printf '\n%d of %d passed, %d failed\n' "$passed" "$total" "$failed"
[ "$failed" -eq 0 ]
