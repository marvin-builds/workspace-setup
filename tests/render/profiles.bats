#!/usr/bin/env bats
# git_as_dest changes HOME only in its subshell, on purpose.
# shellcheck disable=SC2030,SC2031
# Render tests per profile in tests/profiles/ (slice 2, criteria 4, 6, 7, 8,
# 10). Every *.toml there is picked up automatically: each check is
# registered once per profile.
#
# Each test renders the repo's source state into its own temp destination
# with chezmoi apply (see cz in helpers/common.bash) and never uses the
# real home.

load ../helpers/common

GIT_TEMPLATE="$REPO_ROOT/home/dot_config/git/config.tmpl"

setup() {
    ws_isolate
    require_tool chezmoi
    CHEZMOI=$(tool_path chezmoi)
    DEST="$TEST_TMP/dest"
    mkdir -p "$DEST"
}

# render <profile>: applies the source state to $DEST with <profile>.
render() {
    # shellcheck disable=SC2034 # read by cz
    PROFILE=$1
    run cz apply --force
    expect_status 0
}

# git_as_dest <git args...>: git with HOME=$DEST, so it reads the rendered
# ~/.config/git/config, and no XDG_CONFIG_HOME pointing elsewhere.
git_as_dest() {
    (
        unset XDG_CONFIG_HOME
        HOME=$DEST
        export HOME
        git "$@"
    )
}

# repo_with_remote <dir> [<url>]: a fresh repo, with origin set to <url>.
repo_with_remote() {
    git_as_dest init -q "$1"
    [ -z "${2:-}" ] || git_as_dest -C "$1" remote add origin "$2"
}

# snapshot: every file under $DEST with its checksum, sorted.
snapshot() {
    (cd "$DEST" && find . -type f | LC_ALL=C sort | while read -r f; do cksum "$f"; done)
}

# ---------------------------------------------------------- per profile

t_renders() {
    render "$1"
    [ -f "$DEST/.config/git/config" ] || {
        echo "no ~/.config/git/config rendered" >&2
        return 1
    }
}

t_git_config() {
    render "$1"
    cfg="$DEST/.config/git/config"
    run git config -f "$cfg" --list
    expect_status 0
    expect_equal "user.name" "$FAKE_NAME" "$(git config -f "$cfg" --get user.name)"
    expect_equal "user.useConfigOnly" true "$(git config -f "$cfg" --type bool --get user.useConfigOnly)"
    run git config -f "$cfg" --get-all user.email
    expect_status 1
    [ ! -e "$DEST/.gitconfig" ] || { echo "\$HOME/.gitconfig was written" >&2; return 1; }
    # Criterion 31: the config holds exactly these keys; the includeIf
    # lines live in the generated identities/.includes file.
    keys=$(git config -f "$cfg" --name-only --list | LC_ALL=C sort | tr '\n' ' ')
    expect_equal "keys in the git config" "include.path user.name user.useconfigonly " "$keys"
    inc=$(git config -f "$cfg" --get include.path)
    case $inc in
        \~/.config/git/identities/.includes) ;;
        *) echo "include.path is '$inc', want it written as ~/.config/git/identities/.includes" >&2; return 1 ;;
    esac
    [ -f "$DEST/.config/git/identities/.includes" ] || {
        echo "the included identities/.includes file was not written" >&2
        return 1
    }
}

t_identity_files() {
    render "$1"
    ids="$DEST/.config/git/identities"
    expect_equal "$OWNER1 identity" "$EMAIL1" "$(git config -f "$ids/$OWNER1" --get-all user.email)"
    expect_equal "$OWNER2 identity" "$EMAIL2" "$(git config -f "$ids/$OWNER2" --get-all user.email)"
    expect_equal "identity files" 2 "$(find "$ids" -type f ! -name '.*' | wc -l | tr -d ' ')"
}

t_email_end_to_end() {
    render "$1"
    r="$TEST_TMP/repos"

    repo_with_remote "$r/https1" "https://github.com/$OWNER1/x.git"
    expect_equal "https $OWNER1" "$EMAIL1" "$(git_as_dest -C "$r/https1" config user.email)"

    repo_with_remote "$r/ssh1" "git@github.com:$OWNER1/x.git"
    expect_equal "ssh $OWNER1" "$EMAIL1" "$(git_as_dest -C "$r/ssh1" config user.email)"

    repo_with_remote "$r/https2" "https://github.com/$OWNER2/x.git"
    expect_equal "https $OWNER2" "$EMAIL2" "$(git_as_dest -C "$r/https2" config user.email)"

    run git_as_dest -C "$r/https1" commit -q --allow-empty -m 'Test commit'
    expect_status 0
    expect_equal "author of commit" "$EMAIL1" "$(git_as_dest -C "$r/https1" log -1 --format=%ae)"
    expect_equal "author name" "$FAKE_NAME" "$(git_as_dest -C "$r/https1" log -1 --format=%an)"
}

# expect_no_identity <repo dir>: no email, and committing fails over it.
expect_no_identity() {
    run git_as_dest -C "$1" config user.email
    expect_failure
    expect_equal "email in $1" "" "$output"
    run git_as_dest -C "$1" commit -q --allow-empty -m 'Test commit'
    expect_failure
    expect_output_matches '[Ee]mail|identity'
}

t_unknown_owner_no_email() {
    render "$1"
    r="$TEST_TMP/repos"
    repo_with_remote "$r/unknown" "https://github.com/octo-three/x.git"
    expect_no_identity "$r/unknown"
    repo_with_remote "$r/prefix" "https://github.com/${OWNER1}x/x.git"
    expect_no_identity "$r/prefix"
    repo_with_remote "$r/other-host" "https://example.invalid/$OWNER1/x.git"
    expect_no_identity "$r/other-host"
}

t_no_remote_no_email() {
    render "$1"
    repo_with_remote "$TEST_TMP/repos/none"
    expect_no_identity "$TEST_TMP/repos/none"
}

t_second_apply_no_change() {
    render "$1"
    before=$(snapshot)
    touch "$TEST_TMP/marker"
    sleep 1
    run cz apply --force
    expect_status 0
    expect_equal "files after second apply" "$before" "$(snapshot)"
    changed=$(find "$DEST" -newer "$TEST_TMP/marker")
    expect_equal "paths modified by second apply" "" "$changed"
    run cz diff
    expect_status 0
    expect_equal "chezmoi diff after apply" "" "$output"
}

for profile in "$PROFILES_DIR"/*.toml; do
    [ -f "$profile" ] || continue
    p=$(basename "$profile" .toml)
    bats_test_function --description "render $p: applies without error" -- t_renders "$profile"
    bats_test_function --description "render $p: git config parses with name, useConfigOnly, one include, no email" -- t_git_config "$profile"
    bats_test_function --description "render $p: identity files hold the emails" -- t_identity_files "$profile"
    bats_test_function --description "render $p: https and ssh remotes get the owner's email" -- t_email_end_to_end "$profile"
    bats_test_function --description "render $p: unknown owner has no email, commit fails" -- t_unknown_owner_no_email "$profile"
    bats_test_function --description "render $p: no remote has no email, commit fails" -- t_no_remote_no_email "$profile"
    bats_test_function --description "render $p: second apply changes nothing" -- t_second_apply_no_change "$profile"
done

# ------------------------------------------------------------- profiles

@test "profiles: all eight role-form profiles exist" {
    for role in personal work; do
        for form in desktop headless wsl container; do
            [ -f "$PROFILES_DIR/$role-$form.toml" ] || {
                echo "missing tests/profiles/$role-$form.toml" >&2
                return 1
            }
        done
    done
}

@test "profiles: each holds role and form from its name and the fake data" {
    empty_src="$TEST_TMP/empty-source"
    mkdir -p "$empty_src"
    for profile in "$PROFILES_DIR"/*.toml; do
        p=$(basename "$profile" .toml)
        run "$CHEZMOI" --no-tty --source "$empty_src" --config "$profile" \
            --cache "$TEST_TMP/chezmoi-cache" \
            --persistent-state "$TEST_TMP/state-read.boltdb" \
            execute-template '{{ .role }}-{{ .form }}|{{ .name }}|{{ .github_identities }}|{{ .ci }}'
        expect_status 0
        expect_equal "$p data" "$p|$FAKE_NAME|$FAKE_IDENTITIES|true" "$output"
    done
}

# ------------------------------------------------------ template shape

@test "git config template: no branching" {
    [ -f "$GIT_TEMPLATE" ] || { echo "missing home/dot_config/git/config.tmpl" >&2; return 1; }
    run grep -nE '\{\{-?[[:space:]]*(if|else|with)([[:space:]]|-?\}\})' "$GIT_TEMPLATE"
    expect_status 1
}

# ------------------------------------- two owners, changed data (24, 30)

# repo_with_remotes <dir> <url>...: origin, then upstream, remote2, ...
repo_with_remotes() {
    dir=$1
    shift
    git_as_dest init -q "$dir"
    i=0
    for url in "$@"; do
        case $i in 0) name=origin ;; 1) name=upstream ;; *) name=remote$i ;; esac
        git_as_dest -C "$dir" remote add "$name" "$url"
        i=$((i + 1))
    done
}

# expect_commit_refused <repo dir>
expect_commit_refused() {
    run git_as_dest -C "$1" commit -q --allow-empty -m 'Test commit'
    expect_failure
    expect_output_matches '[Ee]mpty ident|[Nn]ame|[Ee]mail|identity'
}

@test "two owners: https remotes of both owners refuse to commit" {
    render "$PROFILES_DIR/personal-desktop.toml"
    repo_with_remotes "$TEST_TMP/r" "https://github.com/$OWNER1/x.git" \
        "https://github.com/$OWNER2/x.git"
    expect_commit_refused "$TEST_TMP/r"
}

@test "two owners: mixed https and ssh remotes refuse to commit" {
    render "$PROFILES_DIR/personal-desktop.toml"
    repo_with_remotes "$TEST_TMP/r1" "https://github.com/$OWNER1/x.git" \
        "git@github.com:$OWNER2/x.git"
    expect_commit_refused "$TEST_TMP/r1"
    repo_with_remotes "$TEST_TMP/r2" "git@github.com:$OWNER2/x.git" \
        "https://github.com/$OWNER1/x.git"
    expect_commit_refused "$TEST_TMP/r2"
}

@test "two owners: one owner over https and ssh still commits with its email" {
    render "$PROFILES_DIR/personal-desktop.toml"
    repo_with_remotes "$TEST_TMP/r" "https://github.com/$OWNER2/x.git" \
        "git@github.com:$OWNER2/y.git"
    run git_as_dest -C "$TEST_TMP/r" commit -q --allow-empty -m 'Test commit'
    expect_status 0
    expect_equal "author email" "$EMAIL2" "$(git_as_dest -C "$TEST_TMP/r" log -1 --format=%ae)"
}

@test "two owners: known owner plus unrelated remote still commits" {
    render "$PROFILES_DIR/personal-desktop.toml"
    repo_with_remotes "$TEST_TMP/r" "https://github.com/$OWNER1/x.git" \
        "https://example.invalid/someone/x.git"
    run git_as_dest -C "$TEST_TMP/r" commit -q --allow-empty -m 'Test commit'
    expect_status 0
    expect_equal "author email" "$EMAIL1" "$(git_as_dest -C "$TEST_TMP/r" log -1 --format=%ae)"
}

@test "changed data: dropping an owner and re-applying removes its identity" {
    render "$PROFILES_DIR/personal-desktop.toml"
    ids="$DEST/.config/git/identities"
    [ -f "$ids/$OWNER2" ]
    one="$TEST_TMP/one-owner.toml"
    sed "s|^github_identities = .*|github_identities = \"$OWNER1=$EMAIL1\"|" \
        "$PROFILES_DIR/personal-desktop.toml" >"$one"
    render "$one"
    [ ! -e "$ids/$OWNER2" ] || { echo "identity of dropped owner kept" >&2; return 1; }
    expect_equal "$OWNER1 email" "$EMAIL1" "$(git config -f "$ids/$OWNER1" --get user.email)"
    # The dropped owner's repos now have no email.
    repo_with_remotes "$TEST_TMP/r" "https://github.com/$OWNER2/x.git"
    expect_no_identity "$TEST_TMP/r"
    # And the kept owner's repos still commit.
    repo_with_remotes "$TEST_TMP/k" "https://github.com/$OWNER1/x.git"
    run git_as_dest -C "$TEST_TMP/k" commit -q --allow-empty -m 'Test commit'
    expect_status 0
}

# ------------------------------------ case and URL forms (criterion 31)

@test "case and form: any case and URL form of a known owner gets the email" {
    render "$PROFILES_DIR/personal-desktop.toml"
    for url in "https://github.com/OCTO-one/x.git" \
        "ssh://git@github.com/Octo-One/x.git" \
        "git@github.com:Octo-One/x.git"; do
        d="$TEST_TMP/r-$(printf '%s' "$url" | cksum | cut -d ' ' -f 1)"
        repo_with_remotes "$d" "$url"
        expect_equal "email for $url" "$EMAIL1" "$(git_as_dest -C "$d" config user.email || true)"
    done
}

@test "case and form: a longer owner name gets no email" {
    render "$PROFILES_DIR/personal-desktop.toml"
    repo_with_remotes "$TEST_TMP/r" "https://github.com/octo-onex/x.git"
    expect_no_identity "$TEST_TMP/r"
    repo_with_remotes "$TEST_TMP/s" "ssh://git@github.com/OCTO-ONEX/x.git"
    expect_no_identity "$TEST_TMP/s"
}

# profile_mixed_case: personal-desktop with owner data Octo-Two.
profile_mixed_case() {
    p="$TEST_TMP/mixed-case.toml"
    sed "s|^github_identities = .*|github_identities = \"$OWNER1=$EMAIL1 Octo-Two=$EMAIL2\"|" \
        "$PROFILES_DIR/personal-desktop.toml" >"$p"
    printf '%s\n' "$p"
}

@test "case and form: data Octo-Two matches a remote of octo-two" {
    render "$(profile_mixed_case)"
    repo_with_remotes "$TEST_TMP/r" "https://github.com/octo-two/x.git"
    expect_equal "email" "$EMAIL2" "$(git_as_dest -C "$TEST_TMP/r" config user.email || true)"
}

@test "case and form: two owners differing in case and form refuse to commit" {
    render "$(profile_mixed_case)"
    repo_with_remotes "$TEST_TMP/a" "https://github.com/$OWNER1/x.git" \
        "https://github.com/octo-two/x.git"
    expect_commit_refused "$TEST_TMP/a"
    repo_with_remotes "$TEST_TMP/b" "https://github.com/$OWNER1/x.git" \
        "ssh://git@github.com/Octo-Two/x.git"
    expect_commit_refused "$TEST_TMP/b"
    repo_with_remotes "$TEST_TMP/c" "ssh://git@github.com/OCTO-ONE/x.git" \
        "git@github.com:octo-TWO/x.git"
    expect_commit_refused "$TEST_TMP/c"
}

# ----------------------------------------------------------- isolation

@test "isolation: helper points HOME, XDG and TMPDIR away from the real home" {
    [ "$HOME" != "$WS_REAL_HOME" ]
    case $HOME in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
    case $XDG_CONFIG_HOME in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
    case $TMPDIR in "$BATS_TEST_TMPDIR"/*) ;; *) return 1 ;; esac
    expect_equal GIT_CONFIG_NOSYSTEM 1 "$GIT_CONFIG_NOSYSTEM"
}

@test "isolation: a render leaves the real home untouched" {
    touch "$TEST_TMP/start"
    sleep 1
    render "$PROFILES_DIR/personal-desktop.toml"
    [ -f "$DEST/.config/git/config" ]
    # Everything a chezmoi render or git could write in a home. The whole
    # home isn't scanned: other programs write to it while tests run.
    newer=
    for p in .gitconfig .config/git .config/chezmoi .local/share/chezmoi \
        .local/state/chezmoi .cache/chezmoi; do
        [ -e "$WS_REAL_HOME/$p" ] || continue
        found=$(find "$WS_REAL_HOME/$p" -newer "$TEST_TMP/start" 2>/dev/null)
        newer="$newer$found"
    done
    expect_equal "files in the real home changed by the render" "" "$newer"
}
