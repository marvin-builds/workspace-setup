# Slice 6: Runtimes and binary tools via mise

Branch `slice-06-mise`. See slice 6 in [the plan](../plan.md), principles 1
and 4, the "Tools not in distro repos" row of "Handling the hard cases", and
H2 in the [plan review](../research/plan-review-2026-10.md).

## Goal

Runtimes and tools that apt lacks, or whose version matters, come from
[mise](https://mise.jdx.dev): a global `mise.toml` lists them, a committed
lockfile pins the exact version and checksum per platform, and
`chezmoi apply` installs exactly that with `mise install --locked`. A new
interactive bash has them on PATH, and a project folder can ask for its own
versions (the reason mise is used: work projects need different node and
python versions side by side). Renovate opens bump PRs that update the
lockfile too.

Tools: node, python, uv, starship, yazi (with `ya`). mise itself comes from
its apt repo through `packages.yaml`.

## Acceptance criteria

### mise itself

1. `packages.yaml` gets an entry `mise` with `apt_repo: mise` and an
   `apt_repos.mise` entry: `https://mise.jdx.dev/deb`, suite `stable`,
   component `main`, architectures `amd64` and `arm64` (the repo's
   `Release` lists those two). Key from `https://mise.jdx.dev/gpg-key.pub`,
   fingerprint `24853EC9F655CE80B48E6C3A8B81C9D17413A06D` (published in
   mise's install docs as the release key; `gpg --show-keys` on the served
   key shows exactly this primary key, expiring 2028-01-02), key sha256
   pinned like the other repos. winget `jdx.mise`, scoop `mise`, brew
   `mise` where their ids are confirmed, else `null`; flatpak `null`.
2. mise's version is not pinned (decided with me): it updates with
   `sudo apt upgrade` like every apt package. Everything mise installs is
   pinned.
3. `expect.yaml`: `pkg-mise` (`source: /usr/bin/mise`, `mise --version`)
   and the keyring and `.sources` checks for `mise`, like slice 5's.

### Tool data

4. `home/dot_config/mise/config.toml` (mise's global config) lists the
   tools. Versions follow the current long-term line, decided with me:
   - `node`: the current Active LTS major (26 since 2026-10-28 per the
     release schedule; check before pinning);
   - `python`: 3.14, one minor behind the newest (3.15, released
     2026-10-09), see Decisions;
   - `uv`, `starship`, `yazi`: their latest release, pinned exactly.
   Backends: `aqua:` first, then `github:`, never `ubi:` or cargo
   (principle 4). node and python use mise's core plugins (precompiled
   python, no build from source). The file sets the lockfile on
   (`[settings] lockfile = true` or what the pinned mise needs) and
   nothing machine-specific.
5. The lockfile next to it (name as mise uses it for the global config)
   is committed and holds every tool for `linux-x64` and `linux-arm64`,
   with checksums. It is generated with `mise lock`, never edited by hand.
   **Check first:** that the mise version from the apt repo supports a
   lockfile for the global config and `install --locked` with it. If it
   doesn't, stop and report to the orchestrator before working around it.
6. `yazi` provides both `yazi` and `ya` on PATH.

### Installing

7. `home/.chezmoiscripts/run_onchange_after_install-tools.sh.tmpl` (Linux
   only via `.chezmoiignore`) runs `mise install --locked` and embeds the
   sha256 of the config and the lockfile, so a change to either reruns it.
   `after_`, so the config is written first; slice 5's `before_` script has
   installed mise by then.
8. Same destination guard as slice 5 (decision 21): when
   `CHEZMOI_DEST_DIR` differs from `CHEZMOI_HOME_DIR` it prints one line
   containing "skip" and exits 0.
9. No `sudo`. Tools go under the user's mise data dir. A failed install
   (missing lock entry, checksum mismatch, download error) exits non-zero
   naming the cause, so a machine without its tools never looks applied.
10. With everything installed, a rerun downloads nothing and changes
    nothing (mise skips installed versions).

### Shell

11. A drop-in `home/dot_config/shell/70-mise.sh` runs
    `eval "$(mise activate bash)"` when `mise` is on PATH, with no output
    and no error when it isn't. It sorts before `90-prompt.sh`, so a new
    interactive bash finds the mise-installed `starship` and gets the
    starship prompt (slice 4's prompt drop-in stays as is).
12. Nested shells and re-sourcing don't add duplicate PATH entries
    (as for `~/.local/bin` in slice 4).
13. Non-interactive use (cron, IDE, scripts) through mise shims is out of
    scope (see below).

### `expect.yaml`

14. Linux checks that node, python, uv, starship, yazi and ya resolve to a
    mise-installed binary in a new interactive bash and run their
    `--version` (or equivalent). They use a clean environment like
    `shell-path`, so the caller's PATH can't make them pass, and they fail
    for a same-named binary outside mise's install dir (e.g. the cargo
    yazi in `~/.cargo/bin`).
15. One check that the node and python majors/minors match the config,
    so a stale or hand-installed version is caught.

### Renovate

16. `renovate.json` at the repo root:
    - mise manager for the global config, with lockfile updates, so a bump
      PR changes the config and the lockfile together (Renovate's mise
      manager supports `mise.lock`; check that it finds the global config
      path, else configure `managerFilePatterns`);
    - node: minor and patch bumps as normal PRs, major bumps only on
      approval through the Dependency Dashboard (I decide when to move to
      the next major); python: patch bumps as normal PRs, minor and major
      bumps only on approval;
    - `lockFileMaintenance` enabled.
    The `apt_repos` key pins and the externals' regex managers stay out of
    this slice (slice 7 does externals; apt key pins have the weekly
    `packages` job).
17. A unit test validates `renovate.json` with Renovate's
    `renovate-config-validator` (pinned version) or, if it needs a runtime
    the tests don't have, the CI job runs it via mise-provided node.
18. I install the Renovate GitHub app myself; the README says so.

### CI and tests

19. Render tests for every profile: the install-tools script renders,
    embeds both hashes, and changes when the config or lockfile changes;
    the drop-in passes `bash -n` and shellcheck.
20. Unit tests for the install script with a stub `mise` (args recorded):
    destination guard, `install --locked` called, failure propagated.
21. A unit test checks that every tool in the config has lockfile entries
    for both Linux platforms, so a forgotten `mise lock` fails before CI.
22. System test (both roles): after bootstrap, `ws doctor` passes with the
    new checks; idempotency step 2 reruns the install script without
    changes. The container gets `GITHUB_TOKEN` (as `MISE_GITHUB_TOKEN`)
    in CI to avoid rate limits; it never appears in logs or files.
23. Shell render tests: with a stub `mise` on PATH, `70-mise.sh` evaluates
    its activate output; without it, no output.

### Docs

24. README: a "Runtimes and tools" section (mise, the global config, the
    lockfile, per-project versions via a project `mise.toml`, Renovate,
    how to bump by hand with `mise lock`). Carry-over from slice 5: apt
    packages update with `sudo apt upgrade`, not through the repo.
25. `docs/plan.md`: slice 5 status merged (PR #8); slice 6 status.

## Files in scope

`home/.chezmoidata/packages.yaml`, `home/dot_config/mise/`,
`home/dot_config/shell/70-mise.sh`, `home/.chezmoiscripts/` (install-tools
script), `home/.chezmoiignore`, `renovate.json`, `scripts/tools.lock` (if
the validator is a pinned download), `tests/` (expect.yaml, unit, render,
system), `.github/workflows/ci.yml`, `README.md`, `docs/plan.md`.

## Out of scope

- Removing the old installs on the real machine (node in `~/.local/bin`,
  python from linuxbrew, yazi and rustup via cargo): slice 12 inventory.
- yazi plugins and fonts: slice 7. App configs (starship, yazi): slice 8.
- Shims for non-interactive use: added when a real case needs them.
- Project-level `mise.toml` files: they belong to each project.
- Windows and macOS mise installs: their phases (the columns are filled).
- Renovate for apt key pins and externals: slice 7 / the weekly job.

## Decisions

- mise is kept (decided with me): professional work needs per-project
  node and python versions, which mise handles; dropping it in favour of
  chezmoi externals plus uv was considered.
- mise from its apt repo, unpinned (decided with me).
- Versions: current long-term line; majors only on my approval (decided
  with me). Renovate's approval gate covers python minors too (3.14 →
  3.15), since a python minor breaks compiled packages like a major.
- Python 3.14, not 3.15 (decided with me: use the newest only if my
  projects need no migration for it). Checked 2026-11-19: a project's
  pinned dependencies include C/Rust extensions that publish no 3.15
  Linux wheels yet, so on 3.15 they would build from source (pydantic-core
  needs a Rust toolchain). Move to 3.15 through the Dependency Dashboard
  once they do.
- Tools: just the five for now (decided with me).
- Renovate config in this slice; I install the app.

### Decided with the test writer

26. **Lockfile name:** exactly one of `mise.lock` or `config.lock` exists
    in `home/dot_config/mise/`, whichever the pinned mise uses for the
    global config.
27. **Config keys:** short or backend-qualified; the short name is the
    part after the last `:` or `/`. Locked versions equal the config's
    version or extend it (`26` → `26.x.y`).
28. **Lock entries:** a `backend` (`core:node`, `core:python`, else
    `aqua:` or `github:`) and an `<algorithm>:<hex>` checksum for
    `linux-x64` and `linux-arm64`.
29. **expect.yaml checks:** each tool is resolved in `env -i … bash -ic`
    and must lie under `$HOME/.local/share/mise/installs/`; python is
    checked as `python`. `mise-versions` matches `v26.` and
    `Python 3.14.`, kept in step with the config by a unit test.
    `mise-path-once`: each install dir is on PATH once, also after
    re-sourcing the bashrc and in a nested bash.
30. **Stub mise:** logs its arguments; `STUB_MISE_FAIL` makes it fail
    with that message. `mise` joins the failing guard stubs of
    `ws_isolate`. The skip line contains "skip" and "tools".
31. **Renovate:** approvals are read from top-level settings and
    `packageRules` in order; node and python are named via
    `matchDepNames` or `matchPackageNames`. A CI job validates
    `renovate.json` with `renovate@<exact version>` on mise's node.
32. **System test token:** the `system` job sets
    `MISE_GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`; `tests/run.sh`
    passes it into the containers by name only, and the container test
    fails if the token appears in any file under `$HOME` (never printed).
    A rerun must leave every version dir under mise's installs unchanged.

### Implementation round 1

33. **Lockfile (criterion 5):** mise 2026.11.10 supports a lockfile for
    the global config with `install --locked`. It is `mise.lock`, made
    with `mise lock --global` (mise refuses without `--global`), in
    lockfile format 4 with `"platforms.<os-arch>"` keys; the lock checker
    reads that and the nested form.
34. **Activation (criterion 11):** `mise activate bash` applies the
    environment at once (`_mise_hook --force`), so `bash -ic` finds the
    tools without a prompt. mise's python provides `python` and `python3`.
35. **libatomic1 (decided by the orchestrator):** node's official Linux
    builds need `libatomic.so.1`, which a minimal Ubuntu lacks, so
    `packages.yaml` gets `libatomic1` (apt only, no filters).
36. **Exact node and python pins (supersedes criterion 4's lines):**
    Renovate's mise manager (44.216.2) turns a partial version such as
    `26` with a locked version into `allowedVersions` within it and only
    refreshes the lockfile, so the next major never appears. So
    `config.toml` pins `node = "26.13.1"` and `python = "3.14.10"`. A dry
    run showed that an exact pin gets a minor PR and a major proposal; the
    approval gate itself (Dependency Dashboard) can't be shown locally
    and rests on the `packageRules` and their unit test. Lock-file
    maintenance stays on but does little.
37. **Validator (criterion 17):** renovate 44.216.2 needs node `^24.11`,
    so the CI job runs it with `mise exec node@24.22.3`; Renovate doesn't
    track that pin (`enabledManagers: ["mise"]`, so the github-actions
    manager is off until slice 7 widens the config).
38. **Non-Linux:** only the install script is excluded; the config and
    lockfile deploy everywhere and are inert without mise. The Windows
    and macOS phases add their platforms to the lock (`mise lock
    --platform …`) before installing there; otherwise `--locked` fails
    and a plain install rewrites the managed lockfile on every apply.

### Review round 1 (C = correctness, P = privacy/portability)

39. **Python patches (C1):** Renovate groups minor and patch updates by
    default and proposes only the highest, so with 3.15 out a 3.14 patch
    never got its own PR. The python rule sets `separateMinorPatch: true`;
    the Renovate unit test models the grouping.
40. **By-hand bump (C2, C3):** `mise lock` in the repo's
    `home/dot_config/mise` needs a one-time `mise trust` there (else
    "not trusted", and entering the folder warns); aqua tools are named in
    full (`mise lock aqua:starship/starship`). The README says so.
    Renovate is unaffected (`MISE_SAFE=1`).
41. **Accepted nits:** starship's and yazi's lock checksums come from
    mise's checksum service, not the projects' own files (P1; it is what
    `mise lock` records, and Renovate PRs show any change); `npx` resolves
    renovate's dependencies fresh in a read-only CI job (P2); CI installs
    only amd64, so arm64 entries are first exercised on an arm64 machine
    (P4; an arm64 system job is left for when one is in use).
