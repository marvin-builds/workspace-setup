#!/bin/sh
# Fails when a branch contains merge commits. Pull requests are rebased onto
# the default branch and merged with a merge commit, so each branch stays a
# separate bump on it; merging the default branch into a PR branch (for
# example with GitHub's "Update branch" button) would cross them.
#
# Runs on the repo of the current directory. Exit 0 when <base>..<head>
# holds no merge commit, 1 when it does (each named by short sha), 2 on a
# usage error or a revision git can't resolve.
#
# Usage: scripts/history-check.sh <base> [<head>]

set -u

usage() {
    printf 'usage: %s <base> [<head>]\n' "$(basename "$0")" >&2
    exit 2
}

[ $# -eq 1 ] || [ $# -eq 2 ] || usage
base=$1
head=${2:-HEAD}

for rev in "$base" "$head"; do
    git rev-parse --verify --quiet "$rev^{commit}" >/dev/null || {
        printf 'history-check: cannot resolve %s\n' "$rev" >&2
        exit 2
    }
done

merges=$(git rev-list --merges --abbrev-commit "$base..$head") || exit 2
if [ -n "$merges" ]; then
    printf 'history-check: merge commits in %s..%s:\n' "$base" "$head"
    printf '%s\n' "$merges" | sed 's/^/  /'
    printf 'history-check: rebase onto %s instead of merging it in\n' "$base"
    exit 1
fi
printf 'history-check: no merge commits in %s..%s\n' "$base" "$head"
