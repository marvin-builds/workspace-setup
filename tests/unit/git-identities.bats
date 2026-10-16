#!/usr/bin/env bats
# Unit tests for scripts/git-identities.sh (slice 2, criterion 9), run
# directly without chezmoi.
#
# Interface (the implementation follows this):
#
#   scripts/git-identities.sh <dest_dir> <pairs>
#
#   <dest_dir>  destination root chezmoi passes (its destDir). Identity files
#               go to <dest_dir>/.config/git/identities/<owner>, never under
#               $HOME unless <dest_dir> is $HOME.
#   <pairs>     one argument: owner=email pairs separated by spaces or tabs,
#               as in the github_identities data. Leading and trailing
#               whitespace and runs of spaces or tabs are tolerated. May be empty (removes every
#               identity file). Missing argument is a usage error, so a
#               broken call can't wipe the identities.
#
#   Each owner file holds `[user]` with `email = <email>`. The script also
#   writes <dest_dir>/.config/git/identities/.includes with every includeIf
#   line (criterion 31): per owner, the https://github.com/<owner>/**,
#   git@github.com:<owner>/** and ssh://git@github.com/<owner>/** forms,
#   letters case-folded as bracket classes ([Oo][Cc]...), digits and
#   hyphens literal, with path ~/.config/git/identities/<owner file>.
#   Conflict includes (path ~/.config/git/identities/.conflict, which sets
#   an empty user.name and user.email) make a repo with remotes of two
#   owners refuse to commit (criterion 24); they are folded the same way.
#   ~/.config/git/config only includes ~/.config/git/identities/.includes.
#   Every pair is validated before anything is written or removed:
#     - owner=email form with both sides non-empty,
#     - owner is a valid GitHub login (1-39 chars, letters, digits and
#       single hyphens, no leading or trailing hyphen),
#     - email matches ^[0-9]+\+[^@]+@users\.noreply\.github\.com$,
#     - owner not already given by an earlier pair (compared
#       case-insensitively, like GitHub logins); the second occurrence is
#       the one reported.
#   A bad pair: exit non-zero, a message containing "pair <n>" (1-based
#   position), never the pair's text, and nothing changed on disk.
#   Files for owners not in <pairs> are removed. A second run with the same
#   input changes nothing (no file rewritten) and prints the same output.

load ../helpers/common

SCRIPT="$REPO_ROOT/scripts/git-identities.sh"

setup() {
    ws_isolate
    DEST="$TEST_TMP/dest"
    IDS="$DEST/.config/git/identities"
    mkdir -p "$DEST"
    [ -x "$SCRIPT" ] || {
        echo "missing or not executable: scripts/git-identities.sh" >&2
        return 1
    }
}

# email_in <file>: the user.email the file sets.
email_in() {
    git config -f "$1" --get user.email
}

# expect_only_email <file> <email>: the file sets user.email to <email>,
# no user.name, and nothing else except conflict includes (criterion 24).
expect_only_email() {
    [ -f "$1" ] || { echo "missing identity file $1" >&2; return 1; }
    expect_equal "user.email in $1" "$2" "$(git config -f "$1" --get-all user.email)"
    other=$(git config -f "$1" --list | grep -v '^user\.email=' |
        grep -vE "$CONFLICT_KEY_RE" || true)
    expect_equal "other keys in $1" "" "$other"
}

# A conflict include as `git config --list` prints it.
CONFLICT_KEY_RE='^includeif\.hasconfig:remote\.\*\.url:[^=]*\.path=.*\.config/git/identities/\.conflict$'

# owner_files <dir>: number of identity files, not counting dot files such
# as .conflict or the generated .includes file.
owner_files() {
    [ -d "$1" ] || { echo 0; return 0; }
    find "$1" -type f ! -name '.*' | wc -l | tr -d ' '
}

# snapshot <dir>: every file with its checksum, sorted.
snapshot() {
    [ -d "$1" ] || return 0
    (cd "$1" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done)
}

@test "git-identities: valid pairs write one file per owner" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    expect_only_email "$IDS/$OWNER1" "$EMAIL1"
    expect_only_email "$IDS/$OWNER2" "$EMAIL2"
    expect_equal "files in identities dir" 2 "$(owner_files "$IDS")"
}

@test "git-identities: a single pair works" {
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1"
    expect_status 0
    expect_only_email "$IDS/$OWNER1" "$EMAIL1"
}

@test "git-identities: writes under dest_dir, not under HOME" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    [ ! -e "$HOME/.config/git" ] || {
        echo "script wrote under \$HOME/.config/git" >&2
        return 1
    }
    [ -f "$IDS/$OWNER1" ]
}

@test "git-identities: owner no longer in data has its file removed" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    run "$SCRIPT" "$DEST" "$OWNER2=$EMAIL2"
    expect_status 0
    [ ! -e "$IDS/$OWNER1" ] || { echo "stale file for $OWNER1 kept" >&2; return 1; }
    expect_only_email "$IDS/$OWNER2" "$EMAIL2"
}

@test "git-identities: empty pairs removes every identity file" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    run "$SCRIPT" "$DEST" ""
    expect_status 0
    expect_equal "files left" 0 "$(owner_files "$IDS")"
}

@test "git-identities: changed email for an existing owner is updated" {
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1"
    expect_status 0
    run "$SCRIPT" "$DEST" "$OWNER1=33333333+octo-one@users.noreply.github.com"
    expect_status 0
    expect_only_email "$IDS/$OWNER1" '33333333+octo-one@users.noreply.github.com'
}

@test "git-identities: second run changes nothing and prints the same output" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    first_output=$output
    before=$(snapshot "$DEST")
    touch "$TEST_TMP/marker"
    sleep 1
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    expect_equal "output of second run" "$first_output" "$output"
    expect_equal "files after second run" "$before" "$(snapshot "$DEST")"
    changed=$(find "$DEST" -newer "$TEST_TMP/marker")
    expect_equal "paths modified by second run" "" "$changed"
}

@test "git-identities: missing pairs argument is a usage error" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    run "$SCRIPT" "$DEST"
    expect_failure
    [ -f "$IDS/$OWNER1" ] || { echo "usage error removed identity files" >&2; return 1; }
}

@test "git-identities: no arguments is a usage error" {
    run "$SCRIPT"
    expect_failure
}

# expect_rejected <position> <secret text> <pairs>: the run fails, names
# "pair <position>", never prints <secret text>, and leaves a previously
# written state untouched.
expect_rejected() {
    position=$1
    secret=$2
    pairs=$3
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1"
    expect_status 0
    before=$(snapshot "$DEST")
    run "$SCRIPT" "$DEST" "$pairs"
    expect_failure
    expect_output_matches "pair $position([^0-9]|\$)"
    expect_output_lacks "$secret"
    expect_equal "files after rejected run" "$before" "$(snapshot "$DEST")"
}

@test "git-identities: pair without '=' is rejected by position" {
    expect_rejected 2 'octo-three' "$OWNER2=$EMAIL2 octo-three"
}

@test "git-identities: pair with empty owner is rejected by position" {
    expect_rejected 1 '44444444+nobody' "=44444444+nobody@users.noreply.github.com"
}

@test "git-identities: pair with empty email is rejected by position" {
    expect_rejected 2 'octo-three' "$OWNER2=$EMAIL2 octo-three="
}

@test "git-identities: owner with path characters is rejected" {
    expect_rejected 1 'sneaky' "../sneaky=$EMAIL2"
}

@test "git-identities: owner with a slash is rejected" {
    expect_rejected 2 'sneaky' "$OWNER2=$EMAIL2 octo/sneaky=$EMAIL2"
}

@test "git-identities: owner with leading hyphen is rejected" {
    expect_rejected 1 '-sneaky' "-sneaky=$EMAIL2"
}

@test "git-identities: owner with trailing hyphen is rejected" {
    expect_rejected 1 'sneaky-' "sneaky-=$EMAIL2"
}

@test "git-identities: owner with underscore is rejected" {
    expect_rejected 1 'sneaky_owner' "sneaky_owner=$EMAIL2"
}

@test "git-identities: owner longer than 39 characters is rejected" {
    long=abcdefghijabcdefghijabcdefghijabcdefghij # 40 chars
    expect_rejected 1 "$long" "$long=$EMAIL2"
}

@test "git-identities: owner of 39 characters is accepted" {
    owner=abcdefghijabcdefghijabcdefghijabcdefghi # 39 chars
    run "$SCRIPT" "$DEST" "$owner=$EMAIL1"
    expect_status 0
    expect_only_email "$IDS/$owner" "$EMAIL1"
}

@test "git-identities: non-noreply email is rejected" {
    expect_rejected 2 'private-mail.example' "$OWNER2=$EMAIL2 octo-three=someone@private-mail.example"
}

@test "git-identities: noreply email without numeric id is rejected" {
    expect_rejected 1 'octo-three@users' "octo-three=octo-three@users.noreply.github.com"
}

@test "git-identities: noreply lookalike domain is rejected" {
    expect_rejected 1 'evil.example' "octo-three=44444444+octo-three@users.noreply.github.com.evil.example"
}

@test "git-identities: duplicate owner is rejected at its second occurrence" {
    expect_rejected 3 '33333333+octo-one' "$OWNER1=$EMAIL1 $OWNER2=$EMAIL2 $OWNER1=33333333+octo-one@users.noreply.github.com"
}

@test "git-identities: duplicate owner differing only in case is rejected" {
    expect_rejected 2 '33333333+octo-one' "$OWNER1=$EMAIL1 Octo-One=33333333+octo-one@users.noreply.github.com"
}

@test "git-identities: leading, trailing and repeated whitespace is tolerated" {
    tab=$(printf '\t')
    run "$SCRIPT" "$DEST" "  $OWNER1=$EMAIL1 $tab  $OWNER2=$EMAIL2$tab "
    expect_status 0
    expect_only_email "$IDS/$OWNER1" "$EMAIL1"
    expect_only_email "$IDS/$OWNER2" "$EMAIL2"
    expect_equal "files in identities dir" 2 "$(owner_files "$IDS")"
}

@test "git-identities: whitespace-only pairs removes every identity file" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    run "$SCRIPT" "$DEST" "   "
    expect_status 0
    expect_equal "files left" 0 "$(owner_files "$IDS")"
}

# ------------------------------- matching and conflicts (24, 31)

# fold_re <owner>: an extended regex for the owner's case-folded pattern,
# each letter as [Xx] or [xX], digits and hyphens literal.
fold_re() {
    printf '%s\n' "$1" | awk '{
        out = ""
        for (i = 1; i <= length($0); i++) {
            c = substr($0, i, 1)
            u = toupper(c); l = tolower(c)
            if (u != l) out = out "\\[(" u l "|" l u ")\\]"
            else out = out c
        }
        print out
    }'
}

# includes_keys: every includeIf key and its path in the includes file,
# as `git config --list` prints them.
includes_keys() {
    git config -f "$IDS/.includes" --list | grep -i '^includeif\.'
}

# expect_owner_includes <owner>: the includes file has the three URL forms
# for <owner>, folded, each pointing to that owner's identity file.
expect_owner_includes() {
    [ -f "$IDS/.includes" ] || { echo "missing $IDS/.includes" >&2; return 1; }
    re=$(fold_re "$1")
    for form in 'https://github\.com/' 'git@github\.com:' 'ssh://git@github\.com/'; do
        line=$(includes_keys | grep -E "^includeif\.hasconfig:remote\.\*\.url:$form$re/\*\*\.path=" || true)
        [ -n "$line" ] || {
            printf 'includes lacks a folded %s pattern for %s; has:\n%s\n' "$form" "$1" "$(includes_keys)" >&2
            return 1
        }
        case $line in
            *"=~/.config/git/identities/$1") ;;
            *)
                printf 'include for %s (%s) points elsewhere: %s\n' "$1" "$form" "$line" >&2
                return 1
                ;;
        esac
    done
}

# all_include_patterns: the owner part of every hasconfig URL pattern in
# any file under the identities dir.
all_include_patterns() {
    for f in "$IDS"/* "$IDS"/.[!.]*; do
        [ -f "$f" ] || continue
        git config -f "$f" --list | grep -i '^includeif\.hasconfig:remote\.\*\.url:' || true
    done | sed -E 's#^includeif\.hasconfig:remote\.\*\.url:(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#/\*\*\.path=.*##'
}

# conflict_lines: every include, in any file, that points to .conflict.
conflict_lines() {
    for f in "$IDS"/* "$IDS"/.[!.]*; do
        [ -f "$f" ] || continue
        git config -f "$f" --list | grep -E "$CONFLICT_KEY_RE" || true
    done
}

# with_git_home <git args...>: git with HOME=$DEST and a git config that
# has what config.tmpl renders (name, useConfigOnly, the includes file).
with_git_home() {
    mkdir -p "$DEST/.config/git"
    printf '[user]\n\tname = Test User\n\tuseConfigOnly = true\n[include]\n\tpath = ~/.config/git/identities/.includes\n' \
        >"$DEST/.config/git/config"
    (
        unset XDG_CONFIG_HOME
        HOME=$DEST
        export HOME
        git "$@"
    )
}

# repo_with <dir> <url>...: a repo with one remote per url.
repo_with() {
    d=$1
    shift
    with_git_home init -q "$d"
    n=0
    for u in "$@"; do
        with_git_home -C "$d" remote add "r$n" "$u"
        n=$((n + 1))
    done
}

@test "git-identities: includes file has folded https, scp and ssh:// patterns per owner" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    expect_owner_includes "$OWNER1"
    expect_owner_includes "$OWNER2"
}

@test "git-identities: digits and hyphens stay literal in patterns" {
    run "$SCRIPT" "$DEST" "octo2-x9=44444444+octo2-x9@users.noreply.github.com"
    expect_status 0
    expect_owner_includes octo2-x9
}

@test "git-identities: every pattern, conflict includes too, is folded" {
    e3='33333333+octo-three@users.noreply.github.com'
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES octo-three=$e3"
    expect_status 0
    bad=$(all_include_patterns | sed -E 's/\[[A-Za-z]{2}\]//g' | grep '[A-Za-z]' || true)
    expect_equal "patterns with a bare letter" "" "$bad"
    [ -n "$(conflict_lines)" ] || { echo "no conflict includes for three owners" >&2; return 1; }
}

@test "git-identities: .conflict sets an empty name and email" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    c="$IDS/.conflict"
    [ -f "$c" ] || { echo "missing $c" >&2; return 1; }
    run git config -f "$c" --get user.name
    expect_status 0
    expect_equal "user.name in .conflict" "" "$output"
    run git config -f "$c" --get user.email
    expect_status 0
    expect_equal "user.email in .conflict" "" "$output"
}

@test "git-identities: a single owner has no conflict includes" {
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1"
    expect_status 0
    expect_owner_includes "$OWNER1"
    expect_equal "conflict includes" "" "$(conflict_lines)"
}

@test "git-identities: dropping an owner removes its includes" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1"
    expect_status 0
    expect_equal "conflict includes" "" "$(conflict_lines)"
    re=$(fold_re "$OWNER2")
    left=$(includes_keys | grep -E "$re" || true)
    expect_equal "includes of dropped owner" "" "$left"
}

@test "git-identities: any case and URL form of a remote gets the email" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    r="$TEST_TMP/repos"
    for url in "https://github.com/OCTO-one/x.git" \
        "ssh://git@github.com/Octo-One/x.git" \
        "git@github.com:oCTO-ONE/x.git"; do
        rm -rf "$r"
        repo_with "$r" "$url"
        expect_equal "email for $url" "$EMAIL1" "$(with_git_home -C "$r" config user.email || true)"
    done
}

@test "git-identities: a longer owner name doesn't match" {
    run "$SCRIPT" "$DEST" "$FAKE_IDENTITIES"
    expect_status 0
    repo_with "$TEST_TMP/r" "https://github.com/octo-onex/x.git"
    run with_git_home -C "$TEST_TMP/r" config user.email
    expect_failure
}

@test "git-identities: owners differing in case and URL form refuse to commit" {
    run "$SCRIPT" "$DEST" "$OWNER1=$EMAIL1 Octo-Two=$EMAIL2"
    expect_status 0
    repo_with "$TEST_TMP/a" "https://github.com/$OWNER1/x.git" "https://github.com/octo-two/x.git"
    run with_git_home -C "$TEST_TMP/a" commit -q --allow-empty -m 'Test commit'
    expect_failure
    repo_with "$TEST_TMP/b" "git@github.com:OCTO-ONE/x.git" "ssh://git@github.com/Octo-Two/x.git"
    run with_git_home -C "$TEST_TMP/b" commit -q --allow-empty -m 'Test commit'
    expect_failure
    # Control: one owner alone commits with its email.
    repo_with "$TEST_TMP/c" "ssh://git@github.com/Octo-Two/x.git"
    run with_git_home -C "$TEST_TMP/c" commit -q --allow-empty -m 'Test commit'
    expect_status 0
    expect_equal "author" "$EMAIL2" "$(with_git_home -C "$TEST_TMP/c" log -1 --format=%ae)"
}
