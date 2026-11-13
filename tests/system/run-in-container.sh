#!/bin/sh
# System test (layer 2, slice 3 criterion 12), run inside the image from
# tests/system/Dockerfile as user `tester`, once per role.
#
# Contract for `tests/run.sh system` (local, needs Docker; CI job `system`):
#   1. docker build tests/system (this directory is the build context).
#   2. For each role in personal and work, a fresh container:
#        docker run --rm -v <repo root>:/src:ro <image> \
#            sh /src/tests/system/run-in-container.sh <role>
#      (an equivalent read-only bind mount at /src is fine). The image's
#      default user is tester; the container must not run as root.
#   3. Fail when docker is missing or any run fails.
#
# /src must be the repo's own work tree with its .git directory (not a
# linked worktree), since it is cloned as --repo. The bootstrap clones the
# committed HEAD, so uncommitted changes are not part of a local run.
#
# Fake data only: owners octo-one and octo-two, name Test User.

set -eu

role=${1:-}
case $role in
    personal | work) ;;
    *)
        echo "usage: run-in-container.sh <personal|work>" >&2
        exit 2
        ;;
esac

REPO=/src
CLONE="$HOME/dev/workspace-setup"
NAME='Test User'
IDS='octo-one=11111111+octo-one@users.noreply.github.com octo-two=22222222+octo-two@users.noreply.github.com'
PATH="$HOME/.local/bin:$PATH"
export PATH

# The mounted repo belongs to the host user, so git would refuse to clone
# it ("dubious ownership"). Trust it in the system config: environment
# config doesn't reach the local transport's upload-pack, and ~/.gitconfig
# is what ws doctor checks. Test setup only, not part of the bootstrap.
trust_src() {
    printf '[safe]\n\tdirectory = %s\n\tdirectory = %s/.git\n' "$REPO" "$REPO" |
        sudo tee /etc/gitconfig >/dev/null
}

step() {
    printf '\n== system test (%s): %s\n' "$role" "$*"
}

fail() {
    printf 'system test (%s): FAIL: %s\n' "$role" "$*" >&2
    exit 1
}

# bootstrap: the curl | sh entry, with the script on stdin.
bootstrap() {
    sh -s -- --repo "$REPO" --source-dir "$CLONE" -- \
        --promptChoice "Role=$role" \
        --promptChoice "Form=container" \
        --promptString "Name=$NAME" \
        --promptString "GitHub identities=$IDS" \
        --promptBool "CI=true" \
        --promptString "Repos dir=$HOME/dev" <"$REPO/bootstrap.sh"
}

# snapshot: what a second bootstrap could change.
snapshot() {
    git -C "$CLONE" rev-parse HEAD
    git -C "$CLONE" log --all --oneline | wc -l
    git -C "$CLONE" status --porcelain --ignored
    cat "$CLONE/.git/config"
    (cd "$HOME" && find . -type f ! -name 'chezmoistate.boltdb' \
        ! -path './dev/workspace-setup/.git/*' | LC_ALL=C sort |
        while IFS= read -r f; do cksum "$f"; done)
}

# config_files: checksums of every file under ~/.config and ~/.local/bin.
# Re-run scripts that append instead of replacing (duplicate lines) change
# them; a valid file like identities/.includes may repeat lines on purpose,
# so a plain duplicate-line check would be wrong.
config_files() {
    (cd "$HOME" && find .config .local/bin -type f ! -name 'chezmoistate.boltdb' |
        LC_ALL=C sort | while IFS= read -r f; do cksum "$f"; done)
}

script_state() {
    chezmoi state get-bucket --bucket=scriptState
}

# ----------------------------------------------------------------------

step "minimal image"
[ "$(id -u)" -ne 0 ] || fail "running as root"
if command -v git >/dev/null 2>&1; then
    fail "git is preinstalled; bootstrap must install it"
fi
sudo -n true || fail "no passwordless sudo"
trust_src || fail "cannot write /etc/gitconfig"

step "bootstrap"
bootstrap || fail "bootstrap.sh failed"
command -v git >/dev/null 2>&1 || fail "git was not installed"
[ "$(command -v chezmoi)" = "$HOME/.local/bin/chezmoi" ] ||
    fail "chezmoi is not ~/.local/bin/chezmoi"
[ "$(chezmoi source-path)" = "$CLONE/home" ] ||
    fail "chezmoi does not use the clone as its source"

step "ws doctor"
ws doctor || fail "ws doctor after bootstrap"

step "idempotency 1: apply again, diff empty"
chezmoi apply || fail "second chezmoi apply"
d=$(chezmoi diff) || fail "chezmoi diff"
[ -z "$d" ] || fail "chezmoi diff not empty after apply: $d"

step "idempotency 2: clear script state, apply, doctor, verify"
# chezmoi 2.73.1 keeps run_once_ scripts in scriptState and run_onchange_
# scripts in entryState (checked: clearing scriptState alone does not
# rerun a run_onchange_ script). Clearing both reruns every script.
[ -n "$(script_state | tr -d '{}[:space:]')" ] ||
    fail "bucket scriptState is empty after apply; wrong bucket name?"
config_before=$(config_files)
chezmoi state delete-bucket --bucket=scriptState || fail "delete-bucket scriptState"
chezmoi state delete-bucket --bucket=entryState || fail "delete-bucket entryState"
[ -z "$(script_state | tr -d '{}[:space:]')" ] || fail "scriptState still holds entries"
chezmoi apply || fail "apply after clearing the script state"
[ -n "$(script_state | tr -d '{}[:space:]')" ] || fail "scripts did not run again"
ws doctor || fail "ws doctor after re-running the scripts"
chezmoi verify || fail "chezmoi verify after re-running the scripts"
[ "$config_before" = "$(config_files)" ] ||
    fail "re-running the scripts changed files under ~/.config or ~/.local/bin"

step "bootstrap again changes nothing"
before=$(snapshot)
bootstrap || fail "second bootstrap.sh failed"
after=$(snapshot)
[ "$before" = "$after" ] || {
    printf '%s\n' "$before" >/tmp/before
    printf '%s\n' "$after" >/tmp/after
    diff /tmp/before /tmp/after >&2 || true
    fail "second bootstrap changed the machine"
}
d=$(chezmoi diff) || fail "chezmoi diff"
[ -z "$d" ] || fail "chezmoi diff not empty after the second bootstrap: $d"
ws doctor || fail "ws doctor after the second bootstrap"

printf '\nsystem test (%s): passed\n' "$role"
