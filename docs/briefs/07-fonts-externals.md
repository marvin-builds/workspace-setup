# Slice 7: Fonts and pinned externals

Branch `slice-07-externals`. See slice 7 in [the plan](../plan.md),
principle 4, the "Fonts" and "Pinned plugin revisions" rows of "Handling the
hard cases", and [the slice 6 brief](06-mise.md) (mise, its lockfile and
Renovate config, which this slice builds on).

## Goal

A desktop machine gets JetBrains Mono and the Nerd Font Symbols, and every
Linux machine gets the yazi `piper` plugin, each pinned to an exact version
or commit with its integrity checked. Renovate opens bump PRs for them and
for the other pins it can see (GitHub Actions, the Renovate validator), so
nothing pinned goes stale silently.

## Why the plan changed

The plan said: fonts and plugins as chezmoi externals with version + sha256,
bumped by Renovate regex managers. The hosted Renovate app can't do that
(checked in Renovate's docs, 2026-11-19): a regex manager updates only a
version (`currentValue`) or a git digest (`currentDigest`), never a file
checksum next to it, and the `postUpgradeTasks` that could recompute one
are blocked on the hosted app. Decided with me:

- **Fonts come from mise** (`github:` backend). Their checksums live in
  `mise.lock`, and Renovate's mise manager bumps config and lockfile
  together, as slice 6 already does for node and python.
- **The yazi plugin is a chezmoi external pinned to a git commit.** The
  commit hash is the integrity pin, so no separate sha256 is needed, and
  Renovate's `git-refs` digest updates bump it.

## Acceptance criteria

### Fonts

1. `home/dot_config/mise/config.toml` gets two `github:` tools, pinned
   exactly, latest release (checked 2026-11-19; recheck before pinning):
   - `github:JetBrains/JetBrainsMono` `2.304`, asset `JetBrainsMono-<v>.zip`;
   - `github:ryanoasis/nerd-fonts` `3.5.1`, asset
     `NerdFontsSymbolsOnly.tar.xz` (the repo has many assets, so the entry
     selects this one, e.g. with `asset_pattern`).
   `mise.lock` holds both for `linux-x64` and `linux-arm64` with checksums,
   generated with `mise lock --global`, never by hand. Slice 6's
   lock-coverage unit test covers them without changes.
   **Check first:** that the pinned mise installs a release asset that
   contains no executable (fonts only) without failing, records its
   checksum in the lock for both platforms, and that Renovate's mise
   manager (44.216.2 or the pinned validator's version) finds `github:`
   tools and updates their lock entries. If any of these fails, stop and
   report to the orchestrator before working around it.
2. mise downloads the fonts on every form (a few MB), so the container
   system test exercises the download and checksum. Only linking them is
   desktop-only.
3. `home/.chezmoiscripts/run_onchange_after_link-fonts.sh.tmpl` (Linux and
   `form=desktop` only, via `.chezmoiignore`) runs after the install-tools
   script (name sorts after it) and embeds the sha256 of the mise config
   and lockfile, so a font bump reruns it.
4. It owns one directory, `~/.local/share/fonts/ws/` (name may differ, but
   one dir the script fully owns): it rebuilds it each run with symlinks to
   the `.ttf`/`.otf` files of the locked font versions under mise's install
   dir (found through `mise where <tool>`, not a hardcoded version), then
   runs `fc-cache` on it. Links of an older version don't survive a bump.
   Nothing outside that directory is touched.
5. Same destination guard as slices 5 and 6: when `CHEZMOI_DEST_DIR`
   differs from `CHEZMOI_HOME_DIR`, it prints one line containing "skip"
   and exits 0. No `sudo`. A missing font install or failing `fc-cache`
   exits non-zero naming the cause.
6. A rerun with nothing changed produces the same directory contents.
7. `packages.yaml` gets `fontconfig` (provides `fc-cache`, `fc-list`) with
   `forms: [desktop]`, unless an existing entry already pulls it in.

### yazi plugin

8. `home/.chezmoiexternal.toml` (or `.toml.tmpl` if it needs OS
   filtering) has an `archive` external for
   `https://github.com/yazi-rs/plugins/archive/<commit>.tar.gz`, pinned to
   a full 40-character commit (current `main`, `1ef5fe0…` on
   2026-11-10; recheck), extracting only `piper.yazi` to
   `~/.config/yazi/plugins/piper.yazi`. No `refreshPeriod` (the URL is
   immutable). Linux only for now, like yazi's install.
9. The wiring in `yazi.toml` that uses piper is slice 8 (app configs).

### Renovate

10. `renovate.json`: `enabledManagers` widens from `["mise"]` to also
    cover:
    - a custom regex manager for the plugin commit in the externals file
      (`datasource: git-refs`, `currentValue: main`, `currentDigest` = the
      commit), so a new commit on `main` opens a PR that changes the URL;
    - `github-actions`, for the digest-pinned actions in
      `.github/workflows/` (keep `# vX.Y.Z` comments in step);
    - a custom regex manager for the validator pins in `ci.yml`
      (`renovate@<version>` via the npm datasource, `node@<version>` via
      the node datasource, within node 24 since the validator needs it).
    Keep slice 6's packageRules unchanged.
11. The Renovate unit test checks: each regex manager's `matchStrings`
    match the current files and capture the pinned value; every pinned
    action in the workflows is a full commit sha with a version comment.
12. The CI validator job still passes.

### `expect.yaml`

13. `fonts-jetbrains-mono` and `fonts-nerd-symbols` (Linux,
    `forms: [desktop]`): `fc-list` lists the family (`JetBrains Mono`,
    `Symbols Nerd Font`) from a file under the owned font dir.
14. `yazi-piper` (Linux): `~/.config/yazi/plugins/piper.yazi/main.lua`
    exists.

### Tests

15. Render tests for every profile, without network: the link-fonts script
    renders only for Linux desktop profiles, embeds both hashes and changes
    when the config or lockfile changes, passes `bash -n` and shellcheck.
    Render runs exclude externals (`--exclude externals` or equivalent), so
    they never download.
16. A unit test parses the externals file: the plugin URL pins a full
    commit sha, no `refreshPeriod`, only `piper.yazi` is extracted.
17. Unit tests for the link script with a stub `mise` (prints a fixture
    install dir per tool) and a stub `fc-cache`: guard, owned dir rebuilt
    with links to the fixture fonts, stale links removed, nothing outside
    the owned dir touched, failure of either stub propagated.
18. System test (both roles, container form): mise installs the fonts from
    the lock; the piper external is applied; idempotency step 2 passes.
    The desktop-only linking is covered by the unit tests and by
    `ws doctor` on a real desktop.

### Docs

19. README: fonts and plugins in the "Runtimes and tools" section (or a
    new one): how they are pinned, how Renovate bumps them, how to bump by
    hand.
20. `docs/plan.md`: slice 6 merged (PR #9); slice 7 status; principle 4
    and the two "hard cases" rows reflect the decisions above.

## Files in scope

`home/dot_config/mise/`, `home/.chezmoiexternal.toml*`,
`home/.chezmoiscripts/` (link-fonts script), `home/.chezmoiignore`,
`home/.chezmoidata/packages.yaml`, `renovate.json`, `tests/` (expect.yaml,
unit, render, system, run.sh if render needs the externals exclusion),
`.github/workflows/ci.yml` (only if a check needs it), `README.md`,
`docs/plan.md`.

## Out of scope

- yazi config and the piper previewer wiring, wezterm font config: slice 8.
- `scripts/tools.lock` (sha256 per asset, same Renovate limit): stays
  bumped by hand; revisit if it becomes a burden.
- apt key sha256 pins: the weekly `packages` job, as before.
- Fonts on Windows/WSL/macOS: their phases (in WSL, fonts live on the
  Windows side).
- A desktop-form system test: the container has no desktop; unit tests and
  real-machine `ws doctor` cover it.

## Decisions

- Fonts via mise and its lockfile; plugin as a commit-pinned chezmoi
  external without extra checksum (decided with me, 2026-11-19, after the
  Renovate check above).
- Plugins: only piper for now (decided with me).
