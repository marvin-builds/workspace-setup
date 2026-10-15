# Review: workspace-setup plan vs. state-of-the-art research

Reviewed: `docs/plan.md` (+ `AGENTS.md`, `README.md`) at `6e9aada` (incl. new principle 7 "Same shortcuts on every OS", see §6),
against [state-of-the-art-2026-10.md](state-of-the-art-2026-10.md) (cited as R§x).
Labels: **[evidence]** = the research supports the change; **[taste]** = judgement call;
**[mine]** = my own inference, not in the research, verify before relying on it.

## 1. Verdict

The direction is sound and is the research's own "mainstream 2026 answer" for this goal:
chezmoi for files, templates, secrets and externals; mise for tools; small per-OS package
scripts run as `run_onchange_` (R§5.2, R§1.1, R§1.7). The research's preference for a custom
Python orchestrator comes from the existing code, not from evidence against chezmoi. The one
real cost it names ("Go-template logic gets hard to test") can be handled inside the plan, so
the greenfield choice stands. Ansible, Nix, image-based setups and `mise bootstrap` are all
rightly out (no native Windows, or too new and changing too fast, R§1.2–1.4, R§1.1). The plan's
testing design is already above the community median (R§2 item 18). The gaps are smaller:
lockfiles and automated version bumps, a chezmoi repo-layout trap, profile dimensions for
WSL and headless machines, script idempotence that `chezmoi diff` cannot see, and enforcing
the privacy checks in CI.

## 2. Recommended changes (ranked)

### High

**H1. Use `.chezmoiroot` and `.chezmoiversion`.** [evidence + mine]
- *Plan:* "The repo is the chezmoi source directory". The layout puts `tests/`, `docs/`,
  `bootstrap.sh` and `README.md` at the same root as `dot_config/`.
- *Change:* add `.chezmoiroot` with the content `home` and move all source state (`dot_*`,
  `.chezmoi*`, `.chezmoiscripts/`) under `home/`. The repo root keeps `bootstrap.sh`, `tests/`,
  `docs/` and `.github/`. Add `.chezmoiversion` to set the minimum chezmoi version. Update the
  layout block, and change `AGENTS.md` from "This repo is a chezmoi source directory" to say the
  source state is in `home/`.
- *Why:* twpayne/dotfiles, the chezmoi author's own repo, uses this pattern (R§2 item 2).
  Without it, every non-dot file at the root becomes a target in `$HOME` (`~/tests`, `~/docs`,
  `~/README.md`) unless you remember to list it in `.chezmoiignore`. That is a silent trap for
  every file added later [mine, based on how chezmoi treats source names].
- *Cost:* trivial now, annoying after slice 2. Do it in slice 1.

**H2. Lock mise tools and automate version bumps for everything pinned.** [evidence]
- *Plan:* the "Tools not in distro repos" row ("Prefer mise's binary backends (aqua/github)"),
  slice 6, slice 7 ("pinned version + checksum"), and the "Scheduled run" bullet.
- *Change:* (a) commit `mise.toml` and `mise.lock`. The installer runs `mise install --locked`,
  and CI uses `jdx/mise-action` with `GITHUB_TOKEN` set. Prefer `aqua:`, then `github:`, and
  never `ubi:`, which is deprecated (R§4.4). (b) Add Renovate (or Dependabot where it works).
  Use its mise manager for `mise.toml` and a regex custom manager for the version and sha256
  pairs in `.chezmoiexternal.toml.tmpl`, apt-repo pins and yazi plugin revisions (R§4.3, R§5.3;
  shunk031 has `renovate.yaml`, R§2 item 4). Bump PRs then run the full CI.
- *Why:* pinning without automated bumps conflicts directly with "low maintenance". The weekly
  run only reports breakage, while a bump PR fixes it and runs the tests first. `mise.lock`
  records checksums and attestations, so you don't have to maintain them by hand.
- *Cost:* about half a day. The Renovate mise-manager details are marked unsure in R§5.3, so
  check them.

**H3. Split profiles into two dimensions now: role × form.** [evidence + taste]
- *Plan:* Machine data has "`profile` (personal/work)"; `tests/profiles/*.toml (ci-personal, ci-work, ...)`.
- *Change:* use `role` (personal | work) and `form` (desktop | headless | wsl | container). In
  `packages.yaml`, entries get `forms:` and `roles:` filters, or tags in general. GNOME, fonts,
  flatpak and wezterm apply only to `form=desktop`. Test profiles become the product of the two
  dimensions, rendered in seconds. The minimal-container E2E then naturally tests `container`
  or `headless`.
- *Why:* the research lists base / desktop-gnome / work / personal / wsl / devcontainer as
  separate profile tags (R§5.1 item 2). felipecrs runs one installer across WSL, desktop and
  server, plus a "minimum mode" in devcontainers (R§1.5, R§2 item 3). Inside WSL, fonts and the
  terminal live on the Windows side. A one-dimensional `profile` would force the redesign the
  goal rules out.
- *Cost:* small now (a schema field plus a test-profile matrix). Large if it comes after slice 5.

**H4. Make every `run_onchange_` and `run_once_` script idempotent on its own, and test that.** [evidence + mine]
- *Plan:* Layer 2 says "`chezmoi apply` again with an assertion that `chezmoi diff` is empty (idempotency)".
- *Change:* a second `chezmoi apply` skips scripts whose hash did not change, so it never re-runs
  them. Add a step that clears chezmoi's script state (`chezmoi state delete-bucket
  --bucket=scriptState` [mine, check the bucket name]), applies again, and asserts there are no
  duplicate apt sources or keyrings, no duplicate rc lines, and that `ws doctor` and
  `chezmoi verify` stay clean. Add this rule to the slice template: each script detects state
  and skips what is already done.
- *Why:* "run_once confusion: a step that is not idempotent breaks the second machine or the
  re-run" (R§5.4). R§3.4 says idempotence means a second *run* reports zero changes. A hash
  change or a new machine with partial state re-runs the script, and in the plan's current test
  that path never runs.
- *Cost:* one more CI step and a few `expect.yaml` "count == 1" checks.

**H5. Enforce the privacy checks in CI, not only in a pre-commit hook.** [evidence]
- *Plan:* the "Confidentiality" row ("Local pre-commit check against it + gitleaks in CI") and slice 11.
- *Change:* (a) store the denylist as an encrypted Actions secret, write it to a temp file at
  job start, and run the same scanner. Pass it to gitleaks/Betterleaks as custom `[[rules]]`
  through `--config` from outside the repo (R§4.7.2, R§4.7.5). (b) Add a commit-metadata check:
  `git log --format='%ae %ce'` may contain only the GitHub noreply address. Set that address for
  this repo with `includeIf` (R§4.7.4). Run the check on PR titles, bodies and branch names
  where feasible. (c) Use Betterleaks, or note that gitleaks is "feature complete" with security
  fixes only (R§2 item 17). (d) Use `gitleaks git --staged`, because `protect`/`detect` are
  deprecated (R§4.7.2). (e) Move this check from slice 11 to slice 1 or 2. The repo is public
  from its first push.
- *Why:* hooks can be bypassed (`--no-verify`). Commit metadata is "the most-forgotten leak"
  (R§4.7.4). The goal explicitly asks for automated checks.
- *Cost:* small. Note that the CI denylist secret is the researcher's own design suggestion
  (R§4.7.5, unsure), not an established pattern.

### Medium

**M1. Keep logic out of Go templates and add a unit layer.** [evidence]
- *Plan:* the testing layers start at render; the WezTerm keybindings data "generates
  `wezterm.lua`"; installer scripts are rendered templates.
- *Change:* templates only turn data into lists or values. Logic such as the keybinding
  generator and conflict check, apt-repo handling and the settings merge goes in plain scripts.
  Make each script sourceable (with a `BASH_SOURCE` guard) and unit-test it with bats (Linux)
  or Pester later (Windows). Add a "Layer 0: unit" to the testing strategy.
- *Why:* this is the research's main argument against chezmoi ("Go-template logic gets hard to
  test", R§5.2), and shunk031 shows the fix: `install/<os>/*.sh` with bats + kcov (R§2 item 4, R§3.2).
- *Cost:* a convention plus one bats setup in slice 2.

**M2. Render tests on `windows-latest` from slice 2.** [evidence + mine]
- *Plan:* "Windows/macOS behavior before their CI jobs exist → Render tests meanwhile".
- *Change:* run layer 1 (render plus parse) on `windows-latest` from the start. It is free for
  a public repo (R§3.3). A Linux runner can probably not fake `.chezmoi.os`, so Windows template
  branches only render on Windows [mine, unsure].
- *Why:* this keeps the "without redesign" promise honest: path, line-ending and `.ps1` template
  errors show up while they are cheap to fix. The research's CI pyramid puts render on both
  OSes (R§5.1 item 8).
- *Cost:* one matrix entry, and a little work to keep render tests free of bash-only tooling.

**M3. Make the `settings.json` merge rules explicit.** [evidence]
- *Plan:* the "Files that other tools also write" row ("`modify_` templates that merge only the
  keys we own").
- *Change:* specify (a) array semantics per key: append-unique for `permissions.allow`/`deny`,
  replace elsewhere; (b) an ownership record, so a key the repo stops owning is removed and not
  orphaned; (c) the file is returned unchanged when nothing differs, which keeps `chezmoi diff`
  quiet; (d) a missing or empty file is handled on first apply; (e) the result is validated
  against `json.schemastore.org/claude-code-settings.json` in CI, where warnings on new keys are
  expected. Prefer the app's own layering first: plugin `enabledPlugins` and
  `extraKnownMarketplaces` (R§4.1, R§4.10). Add a rule that `~/.claude.json` and
  `~/.claude/projects/` are never tracked.
- *Why:* R§4.1 items 2–3 call array semantics "the usual trap". Without (b), removed settings
  linger forever.
- *Cost:* small, and mostly lives in the slice 10 tests.

**M4. Rc files on a machine that grew by hand: own them, with a local drop-in and a backup.** [evidence + taste]
- *Plan:* "`dot_bashrc.tmpl`, `dot_zshrc.tmpl` # thin: source ~/.config/shell/*.sh".
- *Change:* if the plan keeps owning the whole file, then (a) add an untracked
  `~/.config/shell/local/*.sh` drop-in for third-party installers (conda, sdkman and the like
  append to rc files), (b) have `ws doctor` flag foreign lines in owned rc files, and (c) before
  the first apply over existing files, back up every target from `chezmoi managed` to
  `~/.local/state/ws/backup-<ts>/` (R§4.8 "apply with backups"). The alternative is managed
  marker blocks inside user-owned rc files (R§5.1 item 4c), a matter of taste. Owning the whole
  file is simpler with chezmoi.
- *Why:* tools that append to rc files cause permanent `chezmoi diff` drift, or get silently
  overwritten. Cutover (slice 12) has no rollback today.
- *Cost:* small.

**M5. Check that package IDs exist and verify apt repos.** [evidence]
- *Plan:* the Layer 1 schema check ("every `packages.yaml` entry has an id or an explicit
  `null`") and the `apt_repos` fields (key URL, keyring path, source line).
- *Change:* (a) in the weekly job, check that each ID exists in its manager (`apt-cache policy`,
  `flatpak remote-info`, and later `winget show --id --exact`, `brew info`), as edjchapman does
  (R§2 item 13, R§3.1). (b) Add a `fingerprint` field to `apt_repos` and verify the downloaded
  key against it (R§5.1 item 2). (c) Write deb822 `.sources` files with `Signed-By`
  [mine: the Ubuntu 24.04+ default format]. (d) Define `packages.yaml` with a JSON Schema
  instead of an ad hoc check (R§3.1).
- *Cost:* small to medium.

**M6. Run E2E in the container as a non-root user with sudo.** [evidence]
- *Plan:* Layer 2 "minimal Docker image".
- *Change:* use `ubuntu:<your release>` with a created sudo user, or
  `mcr.microsoft.com/devcontainers/base:<os>` (it has a `vscode` user with sudo). Run
  `bootstrap.sh` as that user (felipecrs, R§2 item 3, R§3.3). For the later WSL branch, add stub
  `wslpath`/`wslvar` binaries to exercise it on Linux. Wrap any `gsettings` steps in
  `dbus-run-session` (R§3.3, R§4.5).
- *Why:* running as root hides missing `sudo` calls, permission problems and `$HOME`
  assumptions.
- *Cost:* trivial.

### Low

**L1. Name migrations so they can be added over time.** [evidence] The plan has "One idempotent
`run_once` migration script". Instead, use dated files
`.chezmoiscripts/run_once_after_migrate-<YYYYMMDD>-<topic>.sh`, each one detecting state and
skipping what is done (the Omakub pattern, R§4.8). This is the second hand-grown cleanup you
will need.

**L2. Make `ws` work on Windows by convention.** [evidence] `dot_local/bin/ws` has no extension,
so Windows needs `ws.cmd` or `ws.ps1` shims. Commands that must change the current shell (a
`cd` after `ws clone`) need thin per-shell wrappers. Keep a compatibility matrix with one row
per command and a column per shell, tested with `bash -ic`, `zsh -ic` and `pwsh -c` (renemarc,
R§2 item 8, R§4.6). Write this down now and implement it in the Windows phase.

**L3. Make drift visible and easy to pull back.** [evidence] Copies don't flow back into the repo
(R§5.3). Have `ws doctor` report `chezmoi status` and suggest `chezmoi re-add` or
`chezmoi merge`. Add this to the docs for slice 3.

**L4. Keep the CI budget explicit.** [evidence] Use 2–3 workflows at most, path filters for E2E,
`fail-fast: false`, and macOS only on demand (R§3.6; sebastienrousseau's ~50 workflows are
the warning, R§2 item 15). Add actionlint and shfmt to layer 1 (R§3.1).

## 3. Keep as is (confirmed by the research)

- chezmoi as the engine. No Nix, Ansible or image-based setup, and no `mise bootstrap` yet
  (re-check it in 2027, R§5.2).
- Data manifests with per-OS columns plus thin installers. mise for runtimes and GitHub
  binaries.
- `modify_` merges for co-owned JSON, which is never symlinked (R§4.1, R§5.4).
- Fonts and plugins as pinned chezmoi externals with checksums (R§4.3).
- Secrets from the password manager at apply time, with CI stubs (R§4.9).
- The testing ideas: render per profile, a minimal container instead of the dirty runner, a
  second-apply check, a weekly cron, an upgrade test from the old state (R§3.5 calls this
  "rarely done, most valuable"), a doctor that doubles as health check, and keybindings as
  data with conflict tests (R§4.2: "a repo-side test is the only guard"; GNOME does not
  detect conflicts).
- Helpers as files on PATH, picked by extension. The `ws` namespace.
- `.gitattributes` line endings. The Windows notes (OneDrive `$PROFILE`, encoding) are
  confirmed by R§4.6.

## 4. Gaps (not addressed at all)

1. **Bump workflow**: who updates pins, and how (see H2).
2. **What language `ws doctor` is written in, and how it reads `expect.yaml`.** Parsing YAML
   portably from sh or PowerShell on a fresh machine needs a parser. See Q1.
3. **Rollback or backup for the cutover** (M4c). Slice 12 only does `chezmoi diff` review.
4. **Scheduled workflows stop silently.** GitHub disables cron workflows in public repos after
   60 days without repo activity [mine]. A "low maintenance" repo will hit this. Use a
   keepalive, or accept it and document it.
5. **The bootstrap supply chain.** `bootstrap.sh` installs chezmoi, presumably with
   `get.chezmoi.io | sh`. Pin a version and verify the release checksum [mine]. The
   `.chezmoiversion` from H1 covers only the minimum version.
6. **SSH and git signing keys.** The research recommends the password manager's SSH agent
   over key files (R§4.9). The plan does not mention SSH at all.
7. **Removing things.** `absent` expectations are tested, but nothing describes how a dropped
   `packages.yaml` entry gets uninstalled. Either accept leftovers (and say so) or add an
   explicit `remove:` list.

## 5. Open questions (evidence is mixed)

**Q1. Implementation of `ws doctor` and `expect.yaml`.** Options: (a) Goss (`goss validate`,
YAML, Linux plus limited Windows, R§3.4); (b) chezmoi renders `expect.yaml` into a flat
per-machine file at apply time, already filtered by OS and profile, which a sh or PowerShell
doctor reads line by line; (c) Python through mise. *Recommendation:* (b). It stays a file
convention, needs no runtime before mise has run, and the filtering logic stays in the data.
Choose before slice 3.

**Q2. GNOME settings in scope?** *Recommendation:* yes, but narrow. Use curated per-key
`gsettings set` (it validates against the schema), never `dconf dump /`, and only for keys you
own: custom keybindings (with stable `customN` paths) and the conflicts the doctor already
checks. Test with `dbus-run-session` in CI (R§4.5, R§5.4). Apply only for `form=desktop`.
Extensions via `gext` cannot be pinned (R§2 item 16), so leave them in the manual checklist at
first.

**Q3. Bitwarden or 1Password?** Mixed evidence. Both are first-class in chezmoi (R§4.9).
*Recommendation:* pick the one whose SSH agent you will actually use. If it is Bitwarden,
prefer `rbw`, which caches and avoids repeated unlocks per apply. A matter of taste otherwise.

**Q4. bash, zsh or both?** No evidence either way. *Recommendation:* bash as the tested
baseline, with zsh rendered from the same drop-ins and covered by an `-ic` smoke test. Both
are cheap when profiles only source `~/.config/shell/*.sh`. Taste.

**Q5. Claude rules: link/copy from `ai_personal_dir`, or the plugin and marketplace route?**
The research prefers plugin plus marketplace via `enabledPlugins`/`extraKnownMarketplaces` as
"the cleanest convention" (R§4.10), which also shrinks the `modify_` merge. *Recommendation:*
plugin route, with copying only for rules the plugin mechanism cannot carry.

**Q6. Should the research's case for a custom Python orchestrator change anything?** Its
arguments (dry-run, changed/ok reporting, testable planner) are mostly met by `chezmoi diff`,
`chezmoi verify` and H4 plus M1. *Recommendation:* keep chezmoi. Reconsider only if, by
slice 5, installer logic has grown into Go templates despite M1.

## 6. Keybindings: principle 7 and the macOS modifier (added for `6e9aada`)

The research covers this only in R§4.2 and R§4.5. Most of this section is **[mine]**: tool
knowledge not checked against current docs. Check the details before you build on them.

### What the evidence supports

- **One data file that generates the config for each target, plus repo-side conflict tests.**
  This is exactly R§4.2's recommendation ("one data file of logical bindings … generate each
  target's config … then test"). GNOME does not detect conflicts reliably (mutter issue/MR,
  [verified]), and the research found **no off-the-shelf cross-target checker**. So the plan's
  custom render test is needed, not gold-plating. **Keep it.**
- **OS-reserved chords as a test input.** R§4.2(b) also checks generated chords against
  OS-reserved ones: GNOME `wm.keybindings`, `shell.keybindings`, `media-keys` and the custom
  list; Windows `Win+*`. Principle 7 says "the OS reserves the key" is a reason, but no test
  produces that reason. **Change [evidence]:** add a per-OS `reserved` list to the data file.
  On Linux, also read it live in `ws doctor` from `gsettings` (the plan already checks
  gsettings). The render test then fails when a binding hits a reserved chord *and* when an
  exception names a reason that is not in the reserved list.

### Which apps realistically share bindings [mine]

| Layer | Apps | Same on all OSes? | Generate from the data file? |
|---|---|---|---|
| OS / desktop | GNOME, Windows shell, macOS | No, by definition | **No.** Use it only as the `reserved` input. Customize GNOME just enough to free keys you need (Q2). |
| Terminal chrome | WezTerm | Yes, fully. Lua sees the OS (`wezterm.target_triple`), and all keys can be redefined | **Yes.** This is the main consumer, already in the plan. |
| TUI apps in the terminal | yazi, nvim/helix, fzf, glow | Yes, automatically: they only see what the terminal sends | Not needed. Their configs (`keymap.toml` and so on) are already one file per OS. The data file only has to *know* their keys for the shadowing test below. |
| Shell line editing | readline (bash), zle (zsh), PSReadLine (pwsh) | Possible: emacs mode is nearly identical in all three. PSReadLine on Windows defaults to `Windows` edit mode, so set `-EditMode Emacs` | Rely on emacs defaults. Generate only the few custom binds (fzf Ctrl+R/Ctrl+T come from fzf's own integrations, e.g. PSFzf on pwsh). Three syntaxes for a handful of lines is not worth a generator yet. |
| GUI editor | VS Code (if used) | Mostly. `keybindings.json` is one format with `ctrl`/`cmd` names. VS Code itself keeps keybindings **per platform** in Settings Sync (`settingsSync.keybindingsPerPlatform`), which is prior art showing the vendor expects them to differ | Only if you actually use it. The plan doesn't name an editor ("editor" in principle 7 is undefined). Decide which one before the generator grows a target for it. |
| Browser, Office, other GUI apps | n/a | Use OS conventions; not configurable as files | No. Out of scope; say so in the principle. |

**Consequence for the plan [taste, backed by the table]:** "same shortcut on every OS" is
cheap for the terminal and everything inside it, and expensive or impossible elsewhere.
Narrow principle 7 to "apps we configure through files". Start the generator with **one
target (WezTerm)**, and add a target only when a second real consumer exists. Otherwise the
generator becomes the maintenance burden (R§3.6, R§5.4 "keep the core small").

### A missing test: layer shadowing [mine]

The bug most likely to slip through is not a per-OS difference but **an outer layer swallowing
a key an inner layer needs**: a WezTerm binding on `ctrl+r` kills shell history search, and one
on `ctrl+shift+…` can hide a yazi binding. GNOME/IBus grabbing `ctrl+shift+e` from WezTerm is
the same kind of bug, and the plan already checks it via gsettings. Model the layers
explicitly (OS > terminal > shell/TUI). The render test fails when a terminal binding uses a
chord that the shell-editing or TUI tables declare. The same check covers the OS to terminal
direction, using the `reserved` list.

A related technical trap: legacy terminal encoding cannot tell `ctrl+shift+<letter>` from
`ctrl+<letter>`. So **TUI or shell bindings with Ctrl+Shift only work with the kitty keyboard
protocol / CSI u** (WezTerm `enable_kitty_keyboard`, and the app must support it). Either keep
Ctrl+Shift chords for the terminal-chrome layer only, which is the usual convention, or record
the protocol as a requirement and test it.

### Prior art for cross-OS keybinding sources [mine]

- **No tool generates app keymaps for several apps across OSes from one source** (consistent
  with R§4.2's "none surfaced"). Dotfile repos usually keep per-app files, with an OS branch
  inside the app's own config (WezTerm Lua, VS Code `cmd`/`ctrl`).
- **Modifier normalization at OS level** is the established alternative: **Kinto.sh** and its
  successor **Toshy** give Linux and Windows Mac-style shortcuts (the key next to the space bar
  does copy and paste everywhere). **Karabiner-Elements** remaps on macOS. **kanata** is a
  single-config key remapper for Linux, Windows and macOS. These solve "same *physical* keys"
  for *all* apps, at the cost of a system-wide daemon and driver (more lock-in, and drivers or
  privileges on each OS). Prior art worth knowing, but it conflicts with "low maintenance" and
  "no tool lock-in". Don't adopt it now.
- **Apps with a "primary modifier" alias:** WezTerm's defaults use `SUPER` on macOS and
  `CTRL|SHIFT` elsewhere. VS Code and browsers map Ctrl to Cmd. JetBrains ships separate
  "macOS" and "Windows/Linux" keymaps. The industry convention is a **per-OS modifier alias,
  not per-binding exceptions**.

### Open decision: macOS Ctrl vs Cmd

The plan frames Cmd as "a recorded exception per binding". **That framing is the thing to
change, whichever option you pick [evidence from prior art above + mine].**

- **(a) Ctrl everywhere.** The data is identical. But on macOS Ctrl collides with system
  chords (Ctrl+arrows switch Spaces, Ctrl+Space switches input source), and your configured
  apps then behave unlike every other Mac app. Physically, Mac Ctrl sits in the far corner,
  while Cmd sits where Alt is on a PC.
- **(b) A logical `mod` modifier**, resolved once per OS (`ctrl` on Linux/Windows, `cmd` on
  macOS), as **one recorded rule, not N exceptions**. The "differs without reason" test treats
  `mod` as the same everywhere. Shell and TUI bindings always use literal `ctrl`: in a
  terminal, Ctrl sends control characters, so line editing must stay Ctrl on every OS. Only
  app-chrome bindings (WezTerm tabs and panes, a GUI editor) use `mod`. On macOS, Cmd for
  chrome even removes chrome-vs-shell collisions, which is a bonus.
- **(c) An OS-level remap** (Karabiner/kanata/Toshy) so the physical keys match. See above;
  not recommended.

**Recommendation:** (b). Decide only the *data format* now: the `mod` alias plus the rule
"literal `ctrl` in the shell/TUI layers". Leave the actual macOS value to the macOS phase and
default it to `cmd`. Cost now: one alias in the schema and in the test. That keeps "macOS later
without redesign" true either way.
