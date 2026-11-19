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

apt packages are not pinned: they update with the system, through
`sudo apt upgrade`, not through this repo. That includes mise itself.

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

## Runtimes and tools

Runtimes and tools that apt lacks, or whose version matters, come from
[mise](https://mise.jdx.dev) (installed from its apt repo, see
[Packages](#packages)): node, python, uv, starship and yazi (with `ya`).

- [`home/dot_config/mise/config.toml`](home/dot_config/mise/config.toml)
  is mise's global config (`~/.config/mise/config.toml`). It lists the
  tools, each at an exact version: node on its Active LTS line, python
  one minor behind the newest. Backends: mise's core plugins for
  node and python (precompiled python), `aqua:` for the rest.
- `mise.lock` next to it pins the exact version, download URL and
  checksum of every tool for `linux-x64` and `linux-arm64`. It is
  generated by `mise lock`, never edited by hand.
- On Linux, `chezmoi apply` runs `mise install --locked` (no `sudo`; tools
  go to `~/.local/share/mise/installs`) whenever the config or the
  lockfile changes. A missing lock entry, a checksum mismatch or a failed
  download fails the apply with mise's error.
- `~/.config/shell/70-mise.sh` activates mise in every interactive bash,
  so the tools are on PATH (each once, also in nested shells). Scripts,
  cron jobs and IDEs that start no interactive bash don't get them.

A project that needs other versions gets its own `mise.toml` (and
`mise.lock`) in its folder; mise switches to them on `cd`. Those files
belong to the project, not to this repo.

Bump a tool by hand: change its version in `config.toml`, then run
`mise lock <tool>` in `home/dot_config/mise`, check the diff and commit both
files. Name the tool as its key in `config.toml`, so the aqua tools in
full (`mise lock aqua:starship/starship`). mise treats that folder as a
project config: trust it once with `mise trust` there, otherwise
`mise lock` stops with "not trusted" (and an interactive shell entering
the folder warns about it). `tests/run.sh unit` fails when a tool has no lock entry for both
Linux platforms.

[Renovate](https://docs.renovatebot.com) does the same as pull requests
(`renovate.json`): a bump changes `config.toml` and `mise.lock` together,
and weekly lock file maintenance refreshes `mise.lock`. A new node major and a new python minor or
major are only opened after approval on the Dependency Dashboard issue.
The Renovate GitHub app is not set up by this repo: install it by hand
for this repository on GitHub. CI validates `renovate.json` with a pinned
`renovate-config-validator` on a node 24 from mise (job `renovate`).

### Fonts and plugins

- **Fonts.** JetBrains Mono and the Nerd Font Symbols are mise tools too
  (`github:` backend, the release asset as published; for nerd-fonts only
  `NerdFontsSymbolsOnly.tar.xz`). `mise.lock` pins their URL and checksum
  like any tool, and mise installs them on every Linux machine. On a
  desktop, `chezmoi apply` then links their `.ttf` and `.otf` files into
  `$XDG_DATA_HOME/fonts/ws` (`~/.local/share/fonts/ws` when
  `XDG_DATA_HOME` is unset) and runs `fc-cache` on it. The linker runs
  again whenever the mise config or lockfile changes, and then deletes
  and rebuilds that folder, so a bump leaves no old links. Nothing else
  under the fonts folder is touched. To relink without a change (say,
  after deleting the folder), clear chezmoi's record of run scripts with
  `chezmoi state delete-bucket --bucket=entryState` and run
  `chezmoi apply`; that reruns every `run_onchange_` script.
- **yazi plugins.** [`home/.chezmoiexternal.toml`](home/.chezmoiexternal.toml)
  makes chezmoi download the
  [yazi-rs/plugins](https://github.com/yazi-rs/plugins) archive of one
  commit and extract only `piper.yazi` to `~/.config/yazi/plugins/`. The
  full commit in the URL is the pin: the archive can't change under it, so
  there is no separate checksum and no refresh period. Linux only, and
  never when applying into another folder than the home (tests).

Renovate bumps both: a font like any mise tool (`config.toml` and
`mise.lock` in one PR), the plugin when `main` of yazi-rs/plugins moves on
(a PR that changes the commit in the URL). It also bumps the commit-pinned
GitHub Actions in `.github/workflows/` (with their `# vX.Y.Z` comments)
and the validator's `renovate` and `node` versions in `ci.yml`, that
`node` within major 24.

Bump by hand: a font as above (`mise lock github:JetBrains/JetBrainsMono`
after changing its version); the plugin by replacing the commit in the
URL with the newest one on `main`
(`gh api repos/yazi-rs/plugins/commits/main --jq .sha`), then
`chezmoi apply`.

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
your current Docker context and CLI plugins. The containers download the
mise tools from GitHub; a `MISE_GITHUB_TOKEN` set in the environment is
passed in by name (CI sets it) to avoid API rate limits.

CI (`.github/workflows/ci.yml`) runs `unit` and `render` on Linux, `render`
on Windows, `lint`, `system`, `packages` (the apt id check above), `renovate` (the config check above), and the privacy checks with the denylist from the
`WS_DENYLIST` Actions secret (see [docs/new-machine.md](docs/new-machine.md)).
The privacy job also runs `scripts/privacy-check.sh text` on the branch
name and, for pull requests, on the title and body. The history job runs
`scripts/history-check.sh`, which fails when a branch contains merge
commits: rebase onto `main` instead of merging it in.
