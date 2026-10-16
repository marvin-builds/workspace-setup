# Workspace setup plan

Goal: a fresh machine reaches my full workspace (applications, configs, shell
helpers, AI tooling) with one bootstrap command, and every later change is
applied the same way. Linux first; Windows and macOS are added later without
restructuring.

This plan is the hand-off for implementation sessions. Work through the slices
in order; each slice is one branch and one PR. Background:
[research](research/state-of-the-art-2026-10.md) and
[review of this plan](research/plan-review-2026-10.md) (cited as H1, M3, …).

## Architecture

**Engine: [chezmoi](https://www.chezmoi.io/).** One static binary on Linux,
Windows and macOS. It handles dotfiles, OS templating, password-manager
secrets and scripts that rerun when their inputs change. The chezmoi source
state lives in `home/` (`.chezmoiroot`), so the repo root can hold the
bootstrap, tests and docs without them landing in `$HOME`.
`.chezmoiversion` sets the minimum chezmoi version.

Principles:

1. **Declarative data, imperative adapters.** What a machine gets lives in
   data files (`packages.yaml`, `mise.toml`, chezmoi externals). Only small
   per-OS scripts know *how* to install.
2. **One entry point.** `bootstrap.sh` (later `bootstrap.ps1`) installs a
   pinned, checksum-verified chezmoi and runs `chezmoi init --apply`.
   Afterwards `chezmoi apply` is the only command that changes the machine.
   Everything is idempotent: every script detects existing state and skips
   what is done, because a changed hash or a half-set-up machine re-runs it.
3. **Logical names, per-OS ids.** `packages.yaml` maps `firefox` to
   `{apt, flatpak, winget, scoop, brew}`. A new OS fills a column.
4. **Everything pinned, bumps automated.** Tools in `mise.toml` + `mise.lock`
   (installed with `mise install --locked`; `aqua:` backend first, then
   `github:`, never the deprecated `ubi:`). Fonts and plugins as chezmoi
   externals with version + sha256. Renovate opens bump PRs for all of them,
   and CI tests each bump.
5. **Helpers are files, not shell functions.** Executables on PATH, picked by
   extension, so bash and PowerShell share them. Per-shell profiles only
   set PATH, aliases and prompt init.
6. **Logic in scripts, not templates.** Templates only turn data into values
   and lists. Anything with branching (keybinding generator, settings merge,
   apt repo handling) is a plain script that unit tests can call.
7. **Cross-platform tools first:** starship, mise, git, ripgrep, fzf, yazi,
   wezterm, Nerd Fonts.
8. **Public repo, nothing private in it.** Secrets come from Bitwarden at
   apply time; machine- and employer-specific values come from
   chezmoi prompt data or a private overlay. Automated checks enforce this
   in CI from the first push (see slice 1).
9. **Same shortcuts on every OS.** In the apps configured through files, a
   key does the same thing on Linux, Windows and macOS, as far as the OS
   allows. Keybindings come from one data file that generates each app's
   config; WezTerm is the first and, for now, only generated target. A new
   target is added only when a second real consumer exists. Rules:
   - App-chrome bindings (terminal tabs and panes, a GUI editor) use a
     logical `mod` modifier, resolved once per OS (`ctrl` on Linux/Windows,
     `cmd` on macOS). That one rule is not an OS difference.
   - Shell and TUI bindings always use a literal `ctrl`, because a terminal
     sends Ctrl keys as control characters. Ctrl+Shift chords stay in the
     terminal-chrome layer.
   - Shell line editing uses emacs mode in bash and PowerShell
     (PSReadLine `-EditMode Emacs`), so it matches without a generator.
   - Any other per-OS difference is a rare exception in the data file with a
     reason from the OS's `reserved` list.
   - Desktops, browsers and office apps follow their OS conventions and are
     out of scope.

### Repo layout (target)

```
bootstrap.sh                        # POSIX sh: installs pinned chezmoi (+git), verifies checksum, runs init --apply
.chezmoiroot                        # "home": source state lives in home/
renovate.json                       # bump PRs: mise, externals (version + sha256), plugin revisions
home/.chezmoiversion                # minimum chezmoi version
home/.chezmoi.toml.tmpl             # one-time prompts -> chezmoi data (see "Machine data")
home/.chezmoidata/packages.yaml     # logical app -> per-OS ids, apt repos, role/form filters
home/.chezmoidata/keybindings.yaml  # logical bindings, `mod` alias, per-OS reserved chords
home/.chezmoiexternal.toml.tmpl     # pinned downloads: fonts, plugins (version + checksum)
home/.chezmoiignore                 # per-OS / per-role / per-form exclusions
home/.chezmoiscripts/linux/         # run_onchange_* installers (hash of their data in the template)
home/dot_config/                    # app configs (git, starship, mise, wezterm, yazi, shell drop-ins)
home/dot_config/mise/config.toml    # tools; mise.lock next to it
home/dot_bashrc.tmpl                # thin: source ~/.config/shell/*.sh and local/*.sh
home/dot_local/bin/ws               # dispatcher: `ws <cmd>` runs libexec/ws-<cmd>.<ext>
home/dot_local/libexec/ws/          # ws subcommands (doctor, clone, config, help, ...)
home/dot_local/bin/slice            # generic: runs the current repo's scripts/slice.<ext>
tests/run.sh                        # test entry point: unit | render | system | all
tests/profiles/*.toml               # chezmoi config per test profile (role x form)
tests/expect.yaml                   # what a finished machine must have; read by `ws doctor`
.github/workflows/ci.yml
docs/new-machine.md                 # manual steps that can't be scripted
```

Keep `bootstrap.sh` POSIX-only and never hardcode `apt` or `/home/...`
outside Linux-specific scripts and templates; that keeps macOS and Windows
cheap to add.

### Machine data (chezmoi prompts)

Asked once by `.chezmoi.toml.tmpl`, overridable in tests via `--config`:

- `role`: personal | work
- `form`: desktop | headless | wsl | container. GNOME settings, fonts,
  flatpak and wezterm apply only to `desktop`. In WSL, fonts and the
  terminal live on the Windows side.
- `name`, `repos_dir`, `notes_dir`, `ai_personal_dir`, `github_owners`
  (for `ws clone`)
- `github_identities`: space-separated `owner=email` pairs, one per GitHub
  account, each with its noreply address. There is no global `email`: the
  git config sets `user.useConfigOnly = true` and includes the matching
  identity per remote (`includeIf hasconfig:remote.*.url`). Owners and
  emails never appear in tracked files. Provided `~/.gitconfig` sets no
  `user.name` or `user.email` (git reads it after `~/.config/git/config`,
  so its values win), a repo without a known owner, or with remotes of two
  known owners, refuses to commit instead of using a wrong email. Slice 3's
  `ws doctor` flags such values in `~/.gitconfig`; slice 12's migration
  removes them.
- `ci` (true in tests: stub secrets, skip interactive steps)

`packages.yaml` entries filter with `roles:` and `forms:`. Replaces the old
`~/.config/ai-workspace/config.json`.

### Handling the hard cases (found in the old repo)

| Case | Approach |
|---|---|
| Third-party apt repos with signing keys (e.g. Charm for glow) | `packages.yaml` has an `apt_repos` section (key URL, key fingerprint, keyring path, deb822 source); the Linux installer verifies the key and adds the repo before installing. Data, not code. |
| Tools not in distro repos (yazi built via cargo + rustup before) | mise `aqua:`/`github:` backends, locked in `mise.lock`. Fall back to cargo via mise only if no binary exists. |
| Pinned plugin revisions (yazi piper plugin) | chezmoi external (git-repo or archive) pinned to a revision, or a `run_onchange` that calls `ya pkg` with the pinned rev from data. Renovate bumps the revision. |
| Fonts (Nerd Font Symbols; JetBrains Mono is used but never installed) | chezmoi externals with pinned version + checksum into `~/.local/share/fonts`, `run_onchange` → `fc-cache`. |
| Files that other tools also write (`~/.claude/settings.json`) | Prefer the app's own layering (Claude plugins and marketplaces). For the rest, `modify_` templates that merge only the keys we own, with explicit array rules and an ownership record (M3). Never track `~/.claude.json` or `~/.claude/projects/`. |
| Configs we fully own (wezterm.lua, starship, yazi) | Own the whole file; offer a `require`/include of an untracked local file for machine tweaks. Resolve the old duplicate Ctrl+Shift+E binding. |
| Rc files on a hand-grown machine | Own bashrc, source an untracked `~/.config/shell/local/*.sh` drop-in for third-party installers; `ws doctor` flags foreign lines (M4). |
| Claude plugin marketplace + plugin install, rules from ai-personal | Plugin and marketplace route via `enabledPlugins`/`extraKnownMarketplaces`; `run_onchange` keyed on the ai-personal revision; copy only what a plugin can't carry. |
| Old rc marker blocks (`# >>> ai-workspace >>>`, yazi `y` block) and `ws-*` functions | Dated, idempotent migration scripts (`run_once_after_migrate-<YYYYMMDD>-<topic>.sh`) remove them; `ws-*` are replaced by `ws <cmd>`. |
| Confidentiality (old `.denylist`) | Denylist outside the repo (password manager or `~/.config/...`, never committed). Checked by a pre-commit hook, by `ws doctor` and in CI (see slice 1). |
| Multi-repo cloning (old `clone`) | `ws clone` using `github_owners` and `repos_dir` from chezmoi data. |
| Windows specifics (OneDrive-redirected PowerShell profile paths, BOM/encoding, Git's `file.exe`, WSL rename/hostname, `ws.cmd`/`ws.ps1` shims) | Out of scope until the Windows phase; recorded here so they aren't rediscovered. |

Command names: everything workspace-related goes under `ws` to avoid
collisions (`ws doctor`, `ws clone`, `ws config`, `ws help`). Generic
project helpers that are useful outside the workspace (`slice`) stay
standalone and follow the file convention: run the repo's `scripts/slice.*`,
interpreter picked by extension.

## Testing strategy

Test-driven: every change starts as a failing expectation.

- **`tests/expect.yaml`** describes the finished machine: commands on PATH,
  files that exist, config values, per role/form/OS. `ws doctor` checks the
  live machine against it, so it is test, health check and documentation at
  once.
- **Layer 0, unit (seconds):** scripts are sourceable and tested with bats
  (Pester later on Windows): keybinding generator and checks, settings
  merge, apt repo handling.
- **Layer 1, render (seconds):** `chezmoi apply --source . --destination $TMP
  --config tests/profiles/<p>.toml` for every role × form profile; validate
  output with the target tools (`bash -n`, shellcheck, TOML/YAML parse,
  `git config -f`); JSON Schema for `packages.yaml` (every entry has an id or
  an explicit `null` per supported OS); actionlint. Runs on `ubuntu-latest`
  and `windows-latest` from the start, so Windows template branches render
  while they are cheap to fix.
- **Privacy checks (seconds, every push):** Betterleaks (or gitleaks) with
  default rules, the private denylist as custom rules passed from outside
  the repo (in CI from an encrypted Actions secret), and a check that every
  commit author and committer email is the GitHub noreply address.
- **Layer 2, minimal container (minutes):** in CI and locally, the real
  `bootstrap.sh` runs inside a minimal Docker image as a non-root user with
  sudo, then `ws doctor`. Then the idempotency checks:
  1. `chezmoi apply` again; `chezmoi diff` must be empty.
  2. Clear chezmoi's script state so every `run_onchange_`/`run_once_`
     script runs again, apply, and assert no duplicates (apt sources,
     keyrings, rc lines) and a clean `ws doctor` and `chezmoi verify`. A
     plain second apply skips scripts, so step 1 alone proves little.

  The minimal image matters: `ubuntu-latest` ships git, node, python, gh and
  more, so a forgotten install passes on the bare runner.
- **Layer 3, runner VM (minutes):** the same flow directly on `ubuntu-latest`
  (full VM with sudo) only for what a container can't do: flatpak, systemd.
- **Upgrade test:** one system run starts from a fixture of the old repo's
  state (old rc marker blocks, `ws-*` functions, a pre-filled
  `~/.claude/settings.json`) and asserts the migration cleans it up and merges
  keep foreign keys. Fresh installs alone never exercise this path.
- **Scheduled run:** CI also runs weekly, so upstream breakage (moved URLs,
  changed checksums, renamed packages) shows up without a commit. GitHub
  disables scheduled workflows after 60 days without repo activity; Renovate
  PRs keep the repo active, and `ws doctor` warns if the last CI run is old.
- **Behavior, not just existence:** expectations can name a smoke command
  (`<tool> --version`, `wezterm ls-fonts`) and expectations about where a tool
  comes from (e.g. the mise path), not only "on PATH".
- **Intent as data, checked by the tool itself.** Where correctness depends
  on how settings combine across OSes or layers, describe the intent once as
  data and test the effective result. Example from the old repo: Ctrl+Shift+E
  was bound to split in the base WezTerm config and to the shell launcher
  only on Windows, so Linux silently got split. Keybindings live in one data
  file (`mod+shift+e: launcher`) that generates `wezterm.lua`. A test fails
  on:
  - duplicate chords per OS
  - required bindings missing on any OS
  - a binding that differs between OSes without a reason from the `reserved`
    list (`mod` counts as the same everywhere)
  - a chord in an OS's `reserved` list (GNOME keybinding schemas, Windows
    `Win+*`)
  - layer shadowing: a terminal binding on a chord the shell-editing or TUI
    tables declare (e.g. WezTerm on `ctrl+r` kills shell history search)

  CI asserts the effective binding via `WEZTERM_CONFIG_FILE=... wezterm
  show-keys` (confirm it runs headless).
- **TDD loop:** add expectation (red) → add manifest/config/template (green)
  → `tests/run.sh unit render` on every change → `tests/run.sh system` before
  commit → CI on push.
- **Real-machine checks in `ws doctor`:** values filled from secrets are
  non-empty, `gh`/Claude are logged in, desktop shortcuts (GNOME/IBus via
  `gsettings`) don't grab bindings the terminal needs (read live as the
  Linux `reserved` list), denylist hits, and drift (`chezmoi status`, with
  a hint to `chezmoi re-add`). Run `chezmoi diff` before every real apply.
- **Not automated:** hardware, GNOME look and feel, sign-ins, pressing the
  key itself. Listed in `docs/new-machine.md`.

### What the tests catch and what they can't

Catch: template errors per OS/role/form, invalid generated configs, manifest
gaps, committed secrets, denylisted names and private commit emails, failing
fresh installs (package names, apt repos, ordering), missing
commands/files/values, non-idempotent scripts, upstream breakage (at the next
run), broken merges, keybinding conflicts and shadowing.

Can't catch, with the mitigation:

| Gap | Mitigation |
|---|---|
| Tools preinstalled on the runner hide missing installs | Minimal container (layer 2), source-path expectations |
| Behavior (prompt looks, GUI start, font rendering) | Smoke commands; rest in the manual checklist |
| Applying to an existing, drifted machine | Upgrade test; `chezmoi diff` before real applies; backup before cutover |
| Distro differences from the runner | Local container matching my distro; `ws doctor` on the real machine |
| Real secrets and sign-ins (CI uses stubs) | Real-machine `ws doctor` checks |
| Incomplete `expect.yaml` (untested = unlisted) | Parity slice; every item starts as an expectation |
| Leftovers after removing a manifest entry | Explicit `absent` expectations where it matters |
| Desktop intercepting shortcuts | `gsettings` check in `ws doctor`; manual key test |
| Confidential names (secret scanners only know token patterns) | Out-of-repo denylist in pre-commit, `ws doctor` and CI |
| Windows/macOS behavior before their CI jobs exist | Render tests on `windows-latest` meanwhile |
- **Later OSes:** add `windows-latest` / `macos-latest` system jobs to the CI
  matrix plus a profile file. Free and unlimited for a public repo. Keep it
  to two or three workflows with path filters and `fail-fast: false`.

## Slices

Each slice: write the expectation/test first, implement, `tests/run.sh all`
green, PR.

1. **Repo hygiene.** *Status: merged (PR #1), see
   [brief](briefs/01-repo-hygiene.md).* README, AGENTS.md (source state in `home/`),
   `.chezmoiroot`, `home/.chezmoiversion`, `.gitattributes` (LF for `*.sh`,
   CRLF for `*.ps1`), `.gitignore`, MIT license. Privacy checks before
   the first push: Betterleaks config, denylist as custom rules from outside
   the repo, staged-file scan as pre-commit hook, commit-email check, noreply
   email set for this repo via `includeIf`.
2. **Test harness + CI skeleton.** *Status: implemented on
   `slice-02-test-harness`, see [brief](briefs/02-test-harness.md); in
   review as a PR. Known limitation: issue #2.* `tests/run.sh` (unit and render modes),
   bats setup, `tests/profiles/` for role × form, minimal
   `.chezmoi.toml.tmpl`, one managed file (git config) as the first
   red→green case. CI runs layers 0 and 1 on `ubuntu-latest` and
   `windows-latest`, the privacy checks (denylist from an Actions secret)
   and actionlint.
3. **Bootstrap + `ws doctor`.** POSIX `bootstrap.sh` (installs a pinned
   chezmoi with checksum check, accepts a local source path for tests),
   `expect.yaml` format (incl. smoke commands, source paths, `absent`,
   role/form filters), `ws` dispatcher + `ws doctor` (drift report included),
   CI system job in a minimal container as a non-root user with both
   idempotency checks, runner-VM job, weekly schedule. Hooks convention:
   a repo that ships `.githooks/` gets `core.hooksPath=.githooks`;
   bootstrap applies it to the setup repo it cloned, and `ws doctor`
   flags clones with `.githooks/` but without the setting. Git identity:
   `ws doctor` flags a `user.name` or `user.email` in `~/.gitconfig` (it
   overrides the managed XDG config) and checks that an identity file
   exists in `~/.config/git/identities/` for every owner in
   `github_identities` (`chezmoi apply` doesn't repair a deleted one).
4. **Shell base.** Thin bashrc sourcing `~/.config/shell/*.sh` and the
   untracked `local/` drop-in, PATH for `~/.local/bin`, starship, emacs-mode
   line editing, first dated migration script that removes the old marker
   blocks and `ws-*` functions.
5. **Packages.** `packages.yaml` JSON Schema + Linux installer (apt, apt repos
   with key fingerprint and deb822 sources, flatpak), role/form filtering,
   weekly check that every package id exists (M5). First entries: git, gh,
   ripgrep, fzf, glow (Charm repo), `file`.
6. **Runtimes and binary tools via mise.** `mise.toml` + `mise.lock`,
   `mise install --locked`, `jdx/mise-action` with `GITHUB_TOKEN` in CI.
   node, python, uv, and yazi (check the aqua registry first). Replaces
   rustup/cargo builds. Renovate config for mise.
7. **Fonts and pinned externals.** Nerd Font Symbols, JetBrains Mono, yazi
   plugins pinned to a revision. Renovate regex managers for the version +
   sha256 pairs and plugin revisions.
8. **App configs.** git, wezterm (own file + local override, install via its
   apt repo), yazi, glow. Red first: `keybindings.yaml` with
   `mod+shift+e: launcher` on all OSes, `mod` alias, per-OS `reserved`
   lists and the shell/TUI tables; unit tests for duplicates, missing
   required bindings, unexplained per-OS differences, reserved chords and
   layer shadowing; `wezterm show-keys` assertion in CI. Then generate
   `wezterm.lua` from it. Add the `gsettings` shortcut check to `ws doctor`.
9. **ws helpers.** `ws clone`, `ws config`, `ws help`, standalone `slice`.
   `ws clone` applies the hooks convention from slice 3 to every clone.
10. **AI/Claude wiring.** Marketplace + plugin install via `enabledPlugins`/
    `extraKnownMarketplaces`, `settings.json` merge via `modify_` template
    with the rules from M3 (array semantics, ownership record, no diff when
    unchanged, missing file, schemastore validation in CI).
11. **Secrets.** Bitwarden via `rbw` (caches the unlock, so one apply doesn't
    prompt repeatedly) and chezmoi's `rbw` template functions, with a fake
    `rbw` on PATH in CI; the denylist as a Bitwarden item that chezmoi
    renders to `~/.config/ws/denylist` (mode 600) on apply; SSH and signing
    keys through Bitwarden's SSH agent.
12. **Parity and cutover.** Walk the old repo's inventory, confirm every item
    is covered by `expect.yaml`, upgrade test from the old repo's state,
    `chezmoi diff` review, backup of every target from `chezmoi managed` to
    `~/.local/state/ws/backup-<timestamp>/` (restoring it is the rollback),
    run on the real machine, real-machine `ws doctor` (secrets, sign-ins,
    shortcuts). Follows the steps in "Migration from the old setup". The
    migration removes `user.name` and `user.email` from `~/.gitconfig`, so
    the per-owner identities from slice 2 take effect.

Later phases: **Windows** (`bootstrap.ps1`, winget/scoop columns, PowerShell
profile incl. OneDrive paths and encoding, `ws.cmd`/`ws.ps1` shims and a
per-command × per-shell compatibility matrix, WSL as `form=wsl`,
`windows-latest` system job, privacy check decodes UTF-16 files, which
PowerShell 5 writes by default) and **macOS** (brew column + `brew bundle`,
Xcode CLT in bootstrap, `defaults write` settings, `macos-latest` CI). macOS
details, including the value of `mod`, are decided once a Mac is actually in
use; until then only the data formats keep room for it.

## Migration from the old setup

The old repo stays the live setup until the new one has reached parity, and
is retired machine by machine.

1. **While building (slices 1–11).** The old repo keeps running the real
   machines; the new repo is tested only in containers and CI. The old repo
   gets fixes only, no new features. A fix there also gets an expectation in
   the new repo, so it isn't lost.
2. **Inventory (`docs/migration.md`, slice 12 or earlier).** Every item the
   old repo sets up (installers, rc blocks, commands, Claude wiring, machine
   config, private files) with its replacement in the new repo (slice and
   `expect.yaml` entry) or a note that it is dropped. Private values move
   out of the old repo's untracked files: the denylist into Bitwarden,
   `config/repos.local.txt` into the `github_owners` and `repos_dir` prompts.
3. **Cutover per machine.** Linux first, one machine at a time:
   1. `git status` clean in the old repo, nothing unpushed.
   2. Back up every target from `chezmoi managed`.
   3. Run `bootstrap.sh`, review `chezmoi diff`, apply. The dated migration
      scripts remove the old rc blocks and `ws-*` functions.
   4. `ws doctor` clean, then the manual checklist in
      `docs/new-machine.md`.
   5. Rollback if needed: restore the backup and re-run the old repo's
      setup.
4. **Machines the new repo can't serve yet** (Windows, WSL until the
   Windows phase) stay on the old repo. The old repo is archived only after
   the last machine is cut over.
5. **After cutover.** Archive the old repo on GitHub (read-only, kept for
   reference). Update the global AI rules that name the old repo as the
   setup repo (in ai-personal) to point to this one.

## Decisions

- License: MIT.
- GitHub repo: created public and first pushed after slice 1's privacy
  checks pass (each push still needs explicit go-ahead).
- `ws doctor` reads a flat per-machine file that chezmoi renders from
  `expect.yaml` at apply time (filtered by OS, role and form), so a fresh
  machine needs no YAML parser.
- Shell: bash only. zsh is not planned.
- GNOME settings are in scope, narrowly: curated `gsettings` keys for
  `form=desktop`, no `dconf dump /`; extensions stay manual.
- Password manager: Bitwarden via `rbw`.

## Open decisions

- Removing packages: accept leftovers or add an explicit `remove:` list.
  Decide in slice 5.
- Everything macOS-specific: decided when a Mac is actually in use.
