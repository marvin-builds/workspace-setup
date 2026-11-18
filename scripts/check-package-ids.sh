#!/bin/sh
# Checks that every apt id in packages.yaml has an install candidate on
# Ubuntu 24.04 (slice 5, criterion 19; CI job `packages`).
#
# Reads the file unfiltered (no role or form filter, so entries the
# container role leaves out are covered too), builds the data of
# scripts/install-apt.sh (one repo line per apt_repos entry, one package
# line per non-null apt id) and runs `install-apt.sh check` in a fresh
# ubuntu:24.04 container, which adds the repos the same way the installer
# does and fails listing the ids without a candidate. Needs Docker and
# network; nothing on this machine is changed. Docker runs with an empty
# temporary config (only a public image is pulled), so the caller's
# credential helpers and auths are never used; the CLI plugins, context
# definitions and current context are kept, like tests/run.sh system.
#
# Usage: scripts/check-package-ids.sh [<packages.yaml>]
#        Default: home/.chezmoidata/packages.yaml. Exit status: docker's.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
FILE=${1:-$ROOT/home/.chezmoidata/packages.yaml}
IMAGE=ubuntu:24.04

die() {
    printf 'check-package-ids: %s\n' "$*" >&2
    exit 1
}

command -v docker >/dev/null 2>&1 ||
    die "docker is not installed or not on PATH; the check runs in a container"
[ -f "$FILE" ] || die "no such file: $FILE"

if command -v chezmoi >/dev/null 2>&1; then
    chezmoi=chezmoi
elif [ -x "$ROOT/.cache/bin/chezmoi" ]; then
    chezmoi="$ROOT/.cache/bin/chezmoi"
else
    die "chezmoi not found on PATH or in .cache/bin; run scripts/fetch-tools.sh chezmoi"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/check-package-ids.XXXXXX")
trap 'rm -rf "$work"' EXIT
trap 'exit 1' HUP INT TERM

# An empty source state with the file as its only data.
mkdir -p "$work/src/.chezmoidata"
cp "$FILE" "$work/src/.chezmoidata/packages.yaml"

# shellcheck disable=SC2016 # a chezmoi template, not shell
template='
{{- range $name, $r := .apt_repos -}}
{{-   $archs := "" -}}
{{-   if hasKey $r "architectures" }}{{ $archs = join " " $r.architectures }}{{ end -}}
repo	{{ $name }}	{{ $r.key.url }}	{{ join " " $r.key.fingerprints }}	{{ $r.key.sha256 }}	{{ join " " $r.uris }}	{{ join " " $r.suites }}	{{ join " " $r.components }}	{{ $archs }}
{{ end -}}
{{- range $name, $p := .packages -}}
{{-   if $p.apt -}}
package	{{ $p.apt }}
{{ end -}}
{{- end -}}
'

"$chezmoi" --no-tty --source "$work/src" --config "$work/none.toml" \
    --cache "$work/cache" --persistent-state "$work/state.boltdb" \
    execute-template "$template" >"$work/data" ||
    die "cannot read $FILE"

# The data is saved before apt-get runs, so nothing in the preparation can
# read it from stdin.
# shellcheck disable=SC2016 # runs in the container
prepare='set -eu; cat >/tmp/ws-apt-data; export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq --no-install-recommends sudo curl ca-certificates >/dev/null; sh /src/scripts/install-apt.sh check </tmp/ws-apt-data'

# The current context, read with the caller's config before it is swapped
# out. A set DOCKER_HOST already says where to go.
context=
if [ -z "${DOCKER_HOST:-}" ]; then
    context=${DOCKER_CONTEXT:-$(docker context show 2>/dev/null || true)}
fi
user_config=${DOCKER_CONFIG:-$HOME/.docker}
mkdir "$work/docker-config"
for d in cli-plugins contexts; do
    [ ! -d "$user_config/$d" ] || ln -s "$user_config/$d" "$work/docker-config/$d"
done
DOCKER_CONFIG=$work/docker-config
export DOCKER_CONFIG
if [ -n "$context" ]; then
    DOCKER_CONTEXT=$context
    export DOCKER_CONTEXT
fi

status=0
docker run --rm -i -v "$ROOT:/src:ro" "$IMAGE" sh -c "$prepare" <"$work/data" ||
    status=$?
exit "$status"
