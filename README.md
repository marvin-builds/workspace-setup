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
   `sudo apt-get` when git is missing. Nothing else is installed
   system-wide.
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

Options, passed after `sh -s --` when piping:
`bootstrap.sh [--source-dir DIR] [--repo URL] [-- <chezmoi init args>]`
(`WS_SOURCE_DIR` and `WS_REPO_URL` work too). Arguments after `--` go to
`chezmoi init` unchanged, for example `--promptString 'Name=...'`.

Afterwards `ws doctor` checks the machine against `tests/expect.yaml`
(rendered to `~/.config/ws/expect.tsv` for this OS, role and form), reports
drift from the source state, a `user.name` or `user.email` in
`~/.gitconfig`, and clones under the repos dir whose hooks aren't enabled.
Manual steps that remain are in [docs/new-machine.md](docs/new-machine.md).

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
Betterleaks) at the versions and checksums pinned in `scripts/tools.lock`
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
on Windows, `lint`, `system`, and the privacy checks with the denylist from the
`WS_DENYLIST` Actions secret (see [docs/new-machine.md](docs/new-machine.md)).
The privacy job also runs `scripts/privacy-check.sh text` on the branch
name and, for pull requests, on the title and body. The history job runs
`scripts/history-check.sh`, which fails when a branch contains merge
commits: rebase onto `main` instead of merging it in.
