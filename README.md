# workspace-setup

Scripted setup of my workspace (applications, configs, shell helpers) with
[chezmoi](https://www.chezmoi.io/). Linux first, built so Windows and macOS
can be added later.

Status: in progress, slice by slice. See [docs/plan.md](docs/plan.md).

## New machine

On a fresh Linux machine (CI tests Ubuntu 24.04), as your normal
user:

```sh
curl -fsSL https://raw.githubusercontent.com/marvin-builds/workspace-setup/main/bootstrap.sh | sh
```

`bootstrap.sh` does each step only if it isn't done yet, so running it
again changes nothing:

1. Refuses anything but Linux, and root (it sets up the home of the user
   running it).
2. Installs `git` (plus `ca-certificates` and `curl` if missing) with
   `sudo apt-get` when git is missing.
3. Clones this repo into `~/dev/workspace-setup`. That clone is both the
   dev clone and chezmoi's source; an existing clone with the same origin
   is used as it is (no pull, no reset).
4. Installs chezmoi to `~/.local/bin/chezmoi`, at the version and sha256
   pinned in `scripts/tools.lock` (downloaded and verified by
   `scripts/fetch-tools.sh`).
5. Sets `core.hooksPath=.githooks` in the clone.
6. Runs `chezmoi init --apply --source ~/dev/workspace-setup`, which asks
   for the machine data (role, form, name, GitHub identities, repos dir)
   once and records the source, so a later plain `chezmoi apply` uses the
   same clone.

The apply also installs the packages for the machine's role and form
(see [Packages](#packages)) with `sudo apt-get`, so the bootstrap needs
sudo rights; you may be asked for your password.

The apply replaces an existing `~/.bashrc` with the managed one. Back it
up first, or move lines that belong only to this machine into a file in
`~/.config/shell/local/`, which the managed bashrc sources.

Options, passed after `sh -s --` when piping:
`bootstrap.sh [--source-dir DIR] [--repo URL] [-- <chezmoi init args>]`
(`WS_SOURCE_DIR` and `WS_REPO_URL` work too). Arguments after `--` go to
`chezmoi init` unchanged, for example `--promptString 'Name=...'`.

Afterwards `ws doctor` checks the machine against `tests/expect.yaml`
(rendered to `~/.config/ws/expect.tsv` for this OS, role and form), reports
drift from the source state, a `user.name` or `user.email` in
`~/.gitconfig`, and clones under the repos dir whose hooks aren't enabled.
Manual steps that remain are in [docs/new-machine.md](docs/new-machine.md).

## Packages

What a machine gets from its package manager is listed in
[`home/.chezmoidata/packages.yaml`](home/.chezmoidata/packages.yaml): one
entry per tool with its id for each package manager (`apt`, `flatpak`,
`winget`, `scoop`, `brew`, `null` where it has none), optional `roles` and
`forms` filters, and the third-party apt repos, each with its signing key
under `key:` (`url`, the pinned `sha256` of the file and the pinned
primary key `fingerprints`). `tests/schema/packages.schema.json` describes the format.

On Linux, `chezmoi apply` installs the apt ids for this machine's role and
form with `sudo apt-get` (`scripts/install-apt.sh`), after adding the repos
they need as `/etc/apt/keyrings/ws-<repo>.gpg` and
`/etc/apt/sources.list.d/ws-<repo>.sources`. When a third-party repo is
needed, it first installs `gpg`, `curl` and `ca-certificates` if they are
missing. A downloaded key must match both pins, its sha256 as served and
the set of its primary key fingerprints, or the apply stops before
anything is written. When everything is installed, it runs no sudo at all
and downloads nothing, so a rerun works offline. If `apt-get update`
fails after repo files were written, they are put back as they were.
Other operating systems come in their own phases.

If a repo is already set up another way, for example with the vendor's
own `/etc/apt/sources.list.d/github-cli.list`, the apply stops before
writing anything and names that file, since apt refuses two sources for
the same URI with different keys. Remove that file (and its keyring), then
apply again. A migration that removes the old setup's vendor sources is
planned.

Removing an entry from `packages.yaml` does not uninstall the package: it
stays on machines that already have it. Remove it by hand with
`sudo apt-get remove <id>` if you want it gone.

`scripts/check-package-ids.sh` (needs Docker; CI job `packages`, also
weekly) checks in a fresh `ubuntu:24.04` container that every apt id has
an install candidate, with all repos added and no role or form filter.

When a vendor renews or replaces its key, the downloaded file no longer
matches `key.sha256`, and the weekly `packages` job fails until the pin is
updated. Check the new key (fingerprints, the vendor's published hash
where there is one), then bump `key.sha256` (and `key.fingerprints` if a key
was added). Machines that already have the repo keep using the keyring on
disk until then; the bump makes each of them download the new key on its
next apply.

## Setup after cloning

When you clone by hand instead of with the bootstrap, enable the privacy
hooks once per clone:

```sh
git config core.hooksPath .githooks
```

`pre-commit` runs `scripts/privacy-check.sh staged`; `pre-push` runs
`history` and `emails` on the commits being pushed, so local branches that
are never pushed don't block a push. Without revisions
(`scripts/privacy-check.sh all`) every ref is checked, as CI does. The first run downloads the pinned Betterleaks
(`scripts/tools.lock`) into the gitignored `.cache/bin/` via
`scripts/fetch-tools.sh`; nothing is installed system-wide.

The checks need a private denylist, which never lives in this repo:

- Path: `$WS_DENYLIST` if set, else `${XDG_CONFIG_HOME:-$HOME/.config}/ws/denylist`.
- Format: one extended regex per line, matched case-insensitively; lines
  starting with `#` and blank lines are ignored.
- A missing or empty denylist fails the check. Findings name the rule as
  `denylist-<n>`, where `n` is the line number, and never print the match.
- `.gitleaksignore` and `.betterleaksignore` files and inline
  `gitleaks:allow` comments are not honoured: an ignore file anywhere in the
  work tree or history fails the check.

## Running the tests

```sh
tests/run.sh unit     # bats tests in tests/unit/ and tests/privacy.sh
tests/run.sh render   # chezmoi renders of every tests/profiles/*.toml
tests/run.sh lint     # shellcheck on tracked shell scripts, actionlint
tests/run.sh all      # all three; must pass before a PR
tests/run.sh system   # needs Docker: the real bootstrap per role in a container
```

Each mode fetches what it needs (chezmoi, bats-core, shellcheck, actionlint,
Betterleaks, jv) at the versions and checksums pinned in `scripts/tools.lock`
into `.cache/bin/`. Tests render into temp dirs with fake profile data and
never touch your home. `render` also runs under Git Bash on Windows.

`system` builds `tests/system/` (`ubuntu:24.04` with only sudo, curl and
ca-certificates, a non-root user) and, for each role, mounts the repo
read-only, bootstraps from it, then runs `ws doctor`, applies again, clears
chezmoi's script state and applies once more, and bootstraps a second
time, each time checking that nothing changed. The bootstrap clones the
repo, so it tests the committed `HEAD`: commit your changes first. Docker
runs with an empty temporary config (only public images are pulled), keeping
your current Docker context and CLI plugins.

CI (`.github/workflows/ci.yml`) runs `unit` and `render` on Linux, `render`
on Windows, `lint`, `system`, `packages` (the apt id check above), and the privacy checks with the denylist from the
`WS_DENYLIST` Actions secret (see [docs/new-machine.md](docs/new-machine.md)).
The privacy job also runs `scripts/privacy-check.sh text` on the branch
name and, for pull requests, on the title and body. The history job runs
`scripts/history-check.sh`, which fails when a branch contains merge
commits: rebase onto `main` instead of merging it in.
