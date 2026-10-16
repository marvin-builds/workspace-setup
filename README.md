# workspace-setup

Scripted setup of my workspace (applications, configs, shell helpers) with
[chezmoi](https://www.chezmoi.io/). Linux first, built so Windows and macOS
can be added later.

Status: in progress, slice by slice. See [docs/plan.md](docs/plan.md).

## Setup after cloning

Enable the privacy hooks once per clone:

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
```

Each mode fetches what it needs (chezmoi, bats-core, shellcheck, actionlint,
Betterleaks) at the versions and checksums pinned in `scripts/tools.lock`
into `.cache/bin/`. Tests render into temp dirs with fake profile data and
never touch your home. `render` also runs under Git Bash on Windows.

CI (`.github/workflows/ci.yml`) runs `unit` and `render` on Linux, `render`
on Windows, `lint`, and the privacy checks with the denylist from the
`WS_DENYLIST` Actions secret (see [docs/new-machine.md](docs/new-machine.md)).
The privacy job also runs `scripts/privacy-check.sh text` on the branch
name and, for pull requests, on the title and body.
