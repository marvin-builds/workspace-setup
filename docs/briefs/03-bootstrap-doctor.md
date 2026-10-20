# Slice 3: Bootstrap and `ws doctor`

Branch `slice-03-bootstrap-doctor`. See slice 3 in [the plan](../plan.md),
H4, M6, Q1 and gap 5 in the [plan review](../research/plan-review-2026-10.md),
and criteria 25 and 28 of the [slice 2 brief](02-test-harness.md).

## Goal

A fresh Linux machine gets from nothing to an applied setup with one
command, and `ws doctor` tells whether a machine matches what the repo
promises. The real bootstrap runs in CI in a minimal container as a
non-root user, then proves it is idempotent.

## Acceptance criteria

### Bootstrap

1. `bootstrap.sh` at the repo root, POSIX sh, startable as
   `curl -fsSL https://raw.githubusercontent.com/marvin-builds/workspace-setup/main/bootstrap.sh | sh`
   (README shows this). Usage:
   `bootstrap.sh [--source-dir DIR] [--repo URL] [-- <chezmoi init args>]`.
   - `--source-dir` (env `WS_SOURCE_DIR`), default `$HOME/dev/workspace-setup`:
     the clone that is both my dev clone and chezmoi's source.
   - `--repo` (env `WS_REPO_URL`), default
     `https://github.com/marvin-builds/workspace-setup.git`; a local path
     works too (tests).
   - Arguments after `--` go to `chezmoi init` unchanged (tests pass
     `--promptString`/`--promptChoice`/`--promptBool` there).
2. Steps, each skipped when already done:
   1. Fail clearly on anything but Linux, and when not run as a normal user
      (root is refused: it would set up root's home).
   2. If `git` is missing: on apt systems `sudo apt-get install -y git`
      (also `ca-certificates` and `curl` if missing); otherwise fail with a
      hint. Nothing else is installed system-wide.
   3. Clone `--repo` into `--source-dir` if it doesn't exist. An existing
      dir must be a git clone whose `origin` matches `--repo`, else fail;
      an existing clone is used as is (no pull, no reset: it may hold my
      work in progress).
   4. Install chezmoi to `~/.local/bin/chezmoi` via the clone's
      `scripts/fetch-tools.sh chezmoi` (version and sha256 from
      `scripts/tools.lock`, so there is one pin), copying the verified
      binary. An existing binary of the pinned version is kept.
   5. Set `core.hooksPath=.githooks` in the clone (hooks convention).
   6. `chezmoi init --apply --source <source-dir>` plus the passed args.
      Later plain `chezmoi apply` must use the same source: the config
      template records `sourceDir` (verify how chezmoi 2.73.1 persists it
      with `.chezmoiroot`).
3. Running `bootstrap.sh` again on a set-up machine succeeds and changes
   nothing (`chezmoi diff` empty, no new commits or files in the clone).

### Machine data

4. New prompt `repos_dir` (prompt text `Repos dir`), default: the parent
   of the source dir. Test profiles get a fake value under the test home.

### `expect.yaml` and the rendered check list

5. `tests/expect.yaml` holds a list of checks. Each has an `id` (unique,
   `[a-z0-9-]+`), exactly one kind, and optional filters `os`, `roles`,
   `forms` (lists; missing means all):
   - `command: <name>`: on PATH; optional `smoke: <command line>` that must
     exit 0, optional `source: <path>` the resolved command must equal.
   - `file: <path>`: exists. `absent: <path>`: doesn't exist.
   - `line: {file: <path>, text: <fixed string>, count: <n>}`: the file
     contains exactly `n` lines equal to `text` (catches duplicates).
   Paths may start with `~/`.
6. chezmoi renders `~/.config/ws/expect.tsv` from it at apply time, already
   filtered by OS, role and form: one check per line, tab-separated
   (`id`, kind, arguments). The template only filters and prints; it
   reads the file via `.chezmoi.workingTree`. It also emits one `file`
   check per GitHub identity file (and `.includes`, `.conflict`) from
   `github_identities`, so a hand-deleted identity file shows up (slice 2,
   criterion 28).
7. A unit test validates `tests/expect.yaml`: ids unique and well-formed,
   one kind per entry, no tab or newline in any value, filters only use
   known values.
8. First entries: `chezmoi` (source `~/.local/bin/chezmoi`, smoke
   `chezmoi --version`), `git` (smoke `git --version`), `ws` (source
   `~/.local/bin/ws`), `~/.config/git/config`, `~/.config/ws/expect.tsv`.

### `ws` and `ws doctor`

9. `~/.local/bin/ws` (POSIX sh dispatcher): `ws <cmd> [args]` runs
   `~/.local/libexec/ws/ws-<cmd>.<ext>`, choosing the interpreter by
   extension (`.sh` → `sh`; others reserved). Unknown or missing command:
   exit 2 and list the available ones.
10. `ws doctor` (`ws-doctor.sh`, POSIX sh) reads `expect.tsv` and prints
    one line per check, `ok`, `FAIL` or `WARN` plus the id, and a summary.
    Exit 0 when nothing failed, 1 otherwise; warnings don't fail. Extra
    checks beyond the file:
    - **Drift:** `chezmoi status` non-empty → `WARN` with a hint to
      `chezmoi diff`, then `chezmoi re-add` or `chezmoi merge`.
    - **`~/.gitconfig`:** a `user.name` or `user.email` there → `FAIL`,
      since it overrides the managed identities (slice 2, criterion 25).
      Doctor never prints the value.
    - **Hooks convention:** each git clone directly under `repos_dir` that
      has a `.githooks/` dir but no `core.hooksPath=.githooks` → `WARN`
      naming the clone.
    - A missing or unreadable `expect.tsv` → `FAIL` (not "all ok").
11. Doctor is unit-tested with bats against fake `expect.tsv` files and a
    fake home (every kind, every filter result, smoke failure, wrong
    source, duplicate lines, drift via a stub `chezmoi`).

### System test (layer 2)

12. `tests/run.sh system` (local, needs Docker) and a CI job `system` on
    `ubuntu-latest`:
    - Image `ubuntu:24.04` (matches my Pop!_OS 24.04) with only `sudo`,
      `curl` and `ca-certificates` added, and a non-root user with
      passwordless sudo. No git preinstalled: bootstrap must install it.
    - The repo is mounted read-only and used as `--repo` (local clone),
      with fake prompt values for each role (`personal`, `work`) and
      `form=container`.
    - Then: `ws doctor` exits 0; **idempotency 1:** `chezmoi apply` again
      and `chezmoi diff` is empty; **idempotency 2:** clear chezmoi's
      script state (`chezmoi state delete-bucket --bucket=scriptState`,
      verify the name), apply, then `ws doctor` and `chezmoi verify` clean
      and the `line` count checks still hold; **bootstrap again** succeeds
      with no change.
13. The `system` job is a required check candidate, so its name is stable.

## Files in scope

`bootstrap.sh`, `scripts/` (only if bootstrap needs a helper),
`home/.chezmoi.toml.tmpl`, `home/dot_local/bin/` (`ws`),
`home/dot_local/libexec/ws/` (`ws-doctor.sh`), the `expect.tsv` template
under `home/dot_config/ws/`, `tests/expect.yaml`, `tests/` (unit, render,
system), `tests/run.sh`, `.github/workflows/ci.yml`, `README.md`,
`docs/new-machine.md`, `docs/plan.md`.

## Out of scope

- Runner-VM CI job: slice 5, with the first flatpak package (decided with
  me: nothing needs systemd or flatpak yet).
- Warning when the last CI run is old: needs `gh`, later.
- `ws clone`, `ws help`, `ws config`: slice 9.
- Fixing `~/.gitconfig` automatically: slice 12 (doctor only reports).
- macOS and Windows bootstrap: later phases.

## Decisions

- Source dir is my dev clone (`~/dev/workspace-setup` by default), not
  `~/.local/share/chezmoi`: one copy, no drift between two clones.
- Entry is `curl … | sh`; it needs no git and verifies what it downloads.
  The chezmoi pin comes from `tools.lock` after cloning, so there is one
  pin to bump.
- `ws doctor` is POSIX sh reading a flat file chezmoi renders (plan
  decision, Q1), so a fresh machine needs no YAML parser.
- Unverified chezmoi details (persisting `sourceDir` with `.chezmoiroot`,
  the script-state bucket name, `init --apply` with a local source and
  prompt flags) are checked with the pinned chezmoi, not assumed.

### Decided with the test writer

14. **Clearing script state** means deleting both `scriptState` and
    `entryState`: in chezmoi 2.73.1 `run_onchange_` state lives in
    `entryState` (verified). Criterion 12's single bucket was incomplete.
15. **System test clone:** git refuses the read-only `/src` mount
    ("dubious ownership"), so `run-in-container.sh` writes `safe.directory`
    for `/src` into `/etc/gitconfig` before bootstrapping; `~/.gitconfig`
    stays clean for doctor. "No duplicates" after re-running scripts is
    checked by comparing checksums of `~/.config` and `~/.local/bin`.
16. **Interfaces** (documented in the test headers): `ws` and
    `ws-doctor.sh` are plain sh at `home/dot_local/bin/executable_ws` and
    `home/dot_local/libexec/ws/ws-doctor.sh`; `expect.tsv` fields per kind
    (`command`: id, name, source, smoke; `file`/`absent`: id, path;
    `line`: id, file, count, text; empty fields allowed, so a reader must
    not collapse tabs); doctor output `^(ok|FAIL|WARN) <id>` and a
    summary; doctor gets `repos_dir` from `chezmoi execute-template` and
    never applies; `run.sh system` builds `tests/system/` and runs
    `run-in-container.sh <role>` per role, never as root. `repos_dir`
    defaults to the parent of `.chezmoi.workingTree`.
17. The slice 2 test for a source without a git working tree also accepts
    an error naming `tests/expect.yaml`, since the check-list template
    renders first and fails just as clearly there.
18. A local `run.sh system` tests the committed `HEAD` (bootstrap clones
    `/src`); uncommitted changes need a commit first.

### Review round 1 (two reviewers; P = privacy, C = correctness)

19. **Included git config (P1):** the `~/.gitconfig` check reads with
    `--includes`, so a `user.name`/`user.email` from an `[include]`d file
    also fails. Still never prints values.
20. **No account names in doctor output (P3):** identity checks get
    numbered ids (`git-identity-1` …) and neither id nor detail text of
    any check names a GitHub owner, so pasting `ws doctor` output can't
    link my accounts. The same holds for drift output: doctor reports the
    number of drifted entries, not their paths.
21. **Truncated download (P2):** no prefix of `bootstrap.sh` may run
    anything; the body is one `{ … }` block (or equivalent) that sh only
    parses once complete.
22. **Robust paths in bootstrap (P4, C3):** `CDPATH` is ignored; a local
    `--repo` is resolved to an absolute path before cloning and comparing,
    so a rerun with the same relative path works.
23. **Doctor hints (P5)** never print a shell command built from a
    directory name; they name the clone and the setting to apply.
24. **`repos_dir` with `~` (C1):** doctor expands a leading `~/`, and the
    hooks check reports a missing `repos_dir` dir as `WARN`, not `ok`.
25. **Equivalent source paths (C2):** the `source` check compares files
    (`-ef`), so `~/.local/bin/` in PATH or a symlinked home pass.
26. **chezmoi missing (C4):** checks that need chezmoi say so ("chezmoi
    not on PATH; … not checked") as `WARN`, besides the `chezmoi` check's
    own `FAIL`.
27. **Hooks of clones owned by others (C7):** read
    `<clone>/.git/config` with `git config -f`, which needs no ownership
    check.
28. **`run.sh system` (P6, C5, C6):** a trap removes the temporary Docker
    config on every exit; the current Docker context is passed on via
    `DOCKER_CONTEXT` (read before switching config), so context-based
    setups keep working.

### Review round 3 (decided with me)

29. The hooks check reads a clone's config with `--includes`, so a
    `core.hooksPath` set through an `[include]` counts.
