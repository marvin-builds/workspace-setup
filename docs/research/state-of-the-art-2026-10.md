# Reproducible personal machine setup from one public repo — state of the art, October 2026

Research date: 2026-10-15. Sources are linked inline. Confidence markers:
**[verified]** = read in primary source (docs, repo file, workflow);
**[reported]** = secondary source / search summary / community post;
**[unsure]** = my inference or not confirmed, check before relying on it.

Context: the author's old setup repo already has a stdlib-only Python
core (`bootstrap/`), per-app installers (`applications/<app>/install_<app>.py`),
a `doctor` command, a gitignored `.denylist` with a committed `.denylist.example`,
managed shell blocks, a JSON permissions-fragment merge for Claude Code, and CI
on `ubuntu-latest` + `windows-latest`. The recommendation in §5 is written
against that baseline.

---

## 1. Approaches (solution families)

### 1.1 Dotfile managers (file placement + templating)

| Tool | Model | Windows | Notes |
|---|---|---|---|
| **chezmoi** | Copies/renders files from a source dir; Go templates; `run_once_`/`run_onchange_` scripts; externals; password-manager functions; `modify_` scripts for partial edits | Yes, first-class (no symlinks needed) | Most expressive and the de-facto cross-platform choice. Comparison table: only chezmoi has password-manager integration + externals [verified](https://chezmoi.io/comparison-table/) |
| **yadm** | `$HOME` is a git work tree; alternates by `##os.Linux` suffix; templates; encryption | Yes | Gentler learning curve, fewer features [reported](https://www.mintlify.com/twpayne/chezmoi/advanced/migrating-from-another-dotfile-manager) |
| **GNU Stow / dotbot / rcm** | Symlink farms | Stow: poor; dotbot: yes; rcm: no [verified](https://chezmoi.io/comparison-table/) | Simple, but symlinks break apps that rewrite their config (atomic save replaces the link) and need Developer Mode/admin on Windows |
| **mise `[dotfiles]` / `mise bootstrap`** (new in 2026) | Tracks files *in place*, autosave history, two-way sync via git remote; bootstrap also installs packages (apt, dnf, brew, winget, scoop, flatpak…), apt sources, services, macOS defaults, systemd user units, tools | Yes (winget/scoop named) | Shipped June 2026 (v2026.6.6), left "experimental" mid-2026, commands renamed several times in ~7 weeks [reported](https://github.com/ray-manaloto/dotfiles/issues/448); `plan --detailed-exitcode` and `status --missing` are CI-friendly [verified](https://mise.jdx.dev/bootstrap.html). Author explicitly discourages auto-sync to a **public** repo and admits the secret-in-intermediate-commit problem [verified](https://jdx.dev/posts/2026-09-07-dotfiles-that-save-themselves/) |

**Who it suits:** chezmoi for anyone who needs Windows + templates + secrets
today. mise bootstrap is the most interesting newcomer (one TOML for tools +
packages + dotfiles) but is young and churning; watch it, don't bet on it yet.

### 1.2 Configuration management (Ansible, also Salt/Puppet)

- Strengths: huge module library (`apt_repository`, `community.general.dconf`,
  `flatpak`, `win_*` modules), built-in idempotence semantics (`changed=0`),
  Molecule for container tests [reported](https://reintech.io/blog/ansible-playbook-testing-with-molecule).
- Weaknesses: control node does not run natively on Windows (WSL only)
  [unsure — long-standing fact, not re-checked]; YAML + Jinja programming gets
  heavy; slow; poor fit for dotfiles per several users
  [reported](https://piefed.jeena.net/post/30645). Common split: Ansible for
  packages, chezmoi for dotfiles [reported](https://dev.to/seds/automating-and-testing-dotfiles-with-ansible-and-github-s-workflow-2pp2).
- Exemplars: [geerlingguy/mac-dev-playbook](https://github.com/geerlingguy/mac-dev-playbook),
  [TechDufus/dotfiles](https://github.com/TechDufus/dotfiles).
- Suits: people who already know Ansible, Linux/macOS-only fleets.

### 1.3 Declarative/functional (Nix + home-manager, nix-darwin, system-manager)

- Strengths: typed, evaluated config (typo in an option fails before anything
  is written), atomic generations with rollback, `nix flake check` as a
  hermetic CI gate, ~500 home-manager program modules
  [reported, survey](https://github.com/kkiyama117/dotfiles3/blob/main/docs/references/others/2026-06-29-dotfiles-comparative-survey.md).
  [numtide/system-manager](https://github.com/numtide/system-manager) brings
  NixOS-style `/etc` + systemd management to other distros (1.0 announced)
  [reported](https://discourse.nixos.org/t/system-manager-1-0-configure-your-linux-distribution-fearlessly-numtide/74111).
- Weaknesses: **no native Windows** (WSL only); on Ubuntu GNOME, Nix-installed
  GUI apps miss the app menu/icons without `targets.genericLinux.enable` and
  fiddling [reported](https://levelup.gitconnected.com/nix-home-manager-discoveries-and-learnings-ed42bfa1cd33),
  [wiki](https://wiki.nixos.org/wiki/Home-manager); the GNOME Terminal module
  silently writes dconf [reported](https://git.grimmauld.de/Grimmauld/home-manager/raw/commit/70f7c9f35510ac9482db5276e34a628ead8372ca/README.md);
  steep learning curve; secrets need sops-nix/agenix since the store is
  world-readable. Determinate Systems stopped shipping upstream Nix via its
  installer in 2026 [reported](https://determinate.systems/blog/installer-dropping-upstream/) — vendor drift to watch.
- Real exits: caarlos0 (GoReleaser author) went Ansible → Nix → back to a
  plain `./setup` shell script, finding Nix "overkill"
  [reported](https://www.vibeindex.ai/skills/caarlos0/dotfiles/code-simplifier).
- Suits: Linux/macOS users willing to make Nix *the* platform. Conflicts with
  "conventions over tool lock-in" and with Windows-native.

### 1.4 Image-based / immutable (Universal Blue/Bluefin, bootc, BlueBuild)

- Build your OS as an OCI image (Containerfile + `just`/`ujust` recipes), switch
  with `bootc switch`, packages at build time, user apps via Flatpak/Brew/distrobox
  [reported](https://blue-build.org/learn/universal-blue).
- Strong reproducibility and rollback; the image build *is* the test.
- Fedora-based, not Debian/Ubuntu; no answer for Windows/macOS; dotfiles still
  need a separate tool [reported](https://universal-blue.discourse.group/t/how-to-make-bluefin-configuration-declarative/611).
- Suits: Linux-only users happy to leave Ubuntu. Not this goal.

### 1.5 Devcontainers / Codespaces

- Per-project dev environments; VS Code/Codespaces "dotfiles repository"
  setting runs your installer in every container. Felipecrs auto-switches to a
  "minimum mode" inside devcontainers [verified](https://github.com/felipecrs/dotfiles).
- Complements, never replaces, a host setup (no GNOME, fonts, desktop apps).
- Worth supporting as a *profile* (`devcontainer`/`server`), and as a test
  target (the `mcr.microsoft.com/devcontainers/base:*` images are a cheap clean
  Linux user env — see §3).

### 1.6 Custom scripts ("opinionated installers")

- Examples: [basecamp/omakub](https://github.com/basecamp/omakub) (Ubuntu +
  GNOME, bash, `install/`, `applications/`, `defaults/`, timestamped
  `migrations/`, `uninstall/`) — **archived 2026-08-30**, continued as the
  community fork *Omabuntu* [verified archive](https://github.com/basecamp/omakub),
  [reported fork](https://gitblind.noratr.app/omakasui/omabuntu);
  mathiasbynens, holman (topical layout), caarlos0.
- Strength: zero lock-in, full control, easiest to read in two years.
  Weakness: you build idempotence, drift detection, dry-run, and testing yourself.
- Omakub's demise is itself a lesson: a big one-person/one-company bash
  installer is expensive to maintain across Ubuntu releases.

### 1.7 Cross-platform reality check (2026)

| Need | Linux (Ubuntu) | Windows | macOS |
|---|---|---|---|
| Dotfiles | any | chezmoi, own scripts, mise | any |
| OS packages | apt (+ third-party repos with keyrings), flatpak | **winget** (built into runner images since windows-2025 [reported](https://backiee.wasmer.app/https_github_com/Cyberboss/install-winget)), scoop (no admin, portable) | brew |
| Dev tools / GH binaries | mise (aqua/github backends) | mise works natively | mise |
| Declarative OS settings | dconf/gsettings | WinGet Configuration (DSC v3), registry | `defaults write`, nix-darwin |
| Shell | bash/zsh | PowerShell 7 | zsh |

Only chezmoi, mise and hand-written Python/PowerShell genuinely span all three
without WSL.

---

## 2. Notable projects (with the pattern worth copying)

1. **[twpayne/chezmoi](https://github.com/twpayne/chezmoi)** — the tool. Copy its CI shape: `macos`, `ubuntu`, `windows` runners **plus** `assets/docker/test.sh <distro>` for Alpine/Arch/Fedora containers [reported, survey](https://github.com/kkiyama117/dotfiles3/blob/main/docs/references/others/2026-06-29-dotfiles-comparative-survey.md).
2. **[twpayne/dotfiles](https://github.com/twpayne/dotfiles)** — `.chezmoiroot` keeps source state in `home/` so the repo root holds README/installer/tests; `.chezmoiversion` pins the tool; secrets from 1Password via `op` [verified].
3. **[felipecrs/dotfiles](https://github.com/felipecrs/dotfiles)** — one-command Ubuntu bootstrap (WSL/desktop/server, 20.04–24.04). CI matrix `variant × os` runs `scripts/test.sh` which `docker run`s `mcr.microsoft.com/devcontainers/base:<os>` as a non-root user, rsyncs the repo in, runs `install.sh`, sources `~/.profile`. **Simulates WSL by installing fake `wslpath`/`wslvar` stubs and GNOME by `apt install gnome-shell`** — a cheap way to test platform branches [verified, read `ci.yaml` + `scripts/test.sh`].
4. **[shunk031/dotfiles](https://github.com/shunk031/dotfiles)** — chezmoi + mise; install logic in `install/<os>/*.sh` separate from dotfiles, each sourceable (`BASH_SOURCE` guard) and unit-tested with **bats + kcov coverage**; separate E2E workflows per OS (Ubuntu 26.04 container, macOS, Rocky) with path filters; client/server profile matrix; weekly scheduled E2E to catch upstream drift; shell-startup benchmark published to Pages [verified](https://dev.to/shunk031/testable-dotfiles-management-building-development-environment-with-chezmoi-pbn), workflows listed via API.
5. **[geerlingguy/mac-dev-playbook](https://github.com/geerlingguy/mac-dev-playbook)** — the canonical **idempotence check**: run the playbook twice, grep `changed=0.*failed=0`; uninstall the runner's preinstalled Homebrew/browsers first so the test starts closer to a fresh machine; weekly cron [verified, read `ci.yml`].
6. **[anishathalye/dotbot](https://github.com/anishathalye/dotbot)** + **[anishathalye/dotfiles](https://github.com/anishathalye/dotfiles)** — cheapest possible E2E: `HOME=~/scratch ./install` on a runner, weekly [reported, survey].
7. **[upnt/dotfiles](https://github.com/upnt/dotfiles)** — minimal Windows CI: `windows-2025` runner, `winget install twpayne.chezmoi`, add `%LOCALAPPDATA%\Microsoft\WinGet\Links` to `GITHUB_PATH`, `chezmoi init && chezmoi doctor` [verified, read workflow].
8. **[renemarc/dotfiles](https://github.com/renemarc/dotfiles)** — cross-shell command set for Bash/Zsh/PowerShell with a published **compatibility matrix per command** (✅/❌/⚠️). Unmaintained since 2023, but the matrix-as-contract idea is excellent [verified].
9. **[basecamp/omakub](https://github.com/basecamp/omakub)** (archived) — Ubuntu GNOME layout: `install/`, `applications/`, `defaults/`, `themes/`, `uninstall/`, and **timestamped `migrations/` run if newer than the last recorded update** — the simplest migration mechanism around [verified layout; migration mechanism reported](https://docsearch.algolia.com/mcp/docs/repo/basecamp/omakub).
10. **[jdx/mise](https://github.com/jdx/mise)** — tool versions as data (`mise.toml` + `mise.lock` with checksums and GitHub attestation verification), `jdx/mise-action` for CI; `mise bootstrap` for whole-machine setup [verified](https://mise.jdx.dev/dev-tools/backends/github.html).
11. **[dustinlyons/nixos-config](https://github.com/dustinlyons/nixos-config)** / **[Misterio77/nix-starter-configs](https://github.com/Misterio77/nix-starter-configs)** — best starting points if you ever go Nix; `build.yml` builds every host config in CI.
12. **[Mic92/dotfiles](https://github.com/Mic92/dotfiles)** — `nix flake check` with custom `checks` as the strongest static guarantee [reported, survey].
13. **[edjchapman/dotfiles](https://github.com/edjchapman/dotfiles)** — renders templates against **synthetic per-machine data** (`chezmoi execute-template --init --override-data '{…}'`) and validates every package name against the package manager — a pattern for "package manifest is valid" tests [reported, survey].
14. **[sneivandt/dotfiles](https://github.com/sneivandt/dotfiles)** — small repo, but CI has explicit **profile × OS** jobs and **round-trip** jobs for Linux and Windows, plus a CI-contract checker and actionlint pinned by checksum [verified, read `ci.yml`].
15. **[sebastienrousseau/dotfiles](https://github.com/sebastienrousseau/dotfiles)** — chezmoi "workstation control plane" with ~50 workflows incl. drift detection, Windows smoke test (`tools/ci/windows-smoke-test.ps1`), secrets scan. Instructive as a *cautionary* upper bound of CI sprawl for one person [verified workflow list].
16. **[essembeh/gnome-extensions-cli](https://github.com/essembeh/gnome-extensions-cli)** (`gext`) — install/enable GNOME extensions by UUID from a list; picks the version compatible with the running shell (so: not pinnable) [reported](https://pypi.org/project/gnome-extensions-cli).
17. **[gitleaks/gitleaks](https://github.com/gitleaks/gitleaks)** → **Betterleaks** — gitleaks is declared "feature complete" (security fixes only) and its author launched the drop-in-compatible **Betterleaks** in March 2026 [verified README note](https://github.com/gitleaks/gitleaks), [reported](https://bleepingcomputer.com/news/security/betterleaks-a-new-open-source-secrets-scanner-to-replace-gitleaks).
18. **Survey worth reading:** [kkiyama117 "Famous Dotfiles — Comparative Survey" (2026-06-29)](https://github.com/kkiyama117/dotfiles3/blob/main/docs/references/others/2026-06-29-dotfiles-comparative-survey.md) — a third-party, AI-assisted survey of ~25 repos' CI patterns; its conclusion: "the community's median CI is run `./install` in a fresh runner and check the exit code." Spot-checked two of its claims (geerlingguy, upnt) and they held.

---

## 3. Testing state of the art

There is no framework for this; good repos combine cheap layers. Ordered by
cost/benefit:

### 3.1 Static layer (seconds, every push)
- Linters: `shellcheck`, `shfmt -d`, `actionlint`, `yamllint`, `taplo fmt --check`, `stylua --check`, `editorconfig-checker`; PowerShell: `PSScriptAnalyzer` + parse check (`[System.Management.Automation.Language.Parser]::ParseFile`) [reported, survey].
- **Schema validation of config data**: JSON Schema for your own manifests; Claude Code publishes `https://json.schemastore.org/claude-code-settings.json` (may lag new keys) [verified](https://code.claude.com/docs/en/settings); Windows Terminal and VS Code also have schemas.
- **Render-only tests**: render every template for each (OS × profile) with synthetic data and validate the output parses (TOML/JSON/Lua). chezmoi: `chezmoi execute-template --init --override-data` and `chezmoi apply --dry-run --source .`; mise: `mise bootstrap --dry-run`, `mise bootstrap plan --detailed-exitcode` (0/2/1) [verified](https://mise.jdx.dev/bootstrap.html).
- **Semantic checks** (custom, cheap, high value): keybinding conflict detection across terminal/editor/GNOME tables generated per OS; "every package in the manifest exists" (`apt-cache policy`, `winget show --id`, `brew info --json`); privacy denylist scan (§4.7).

### 3.2 Unit layer
- Make install steps pure functions of (desired state, observed state) → actions; test the planner without touching the machine. In bash, the `BASH_SOURCE` guard + bats (`bats-core/bats-action`) is the norm; bats `--filter-tags` maps nicely to profiles [reported, survey]. In Python (this repo): `unittest` with a fake filesystem root (`HOME`/`APPDATA` pointed at a tmp dir).

### 3.3 Fresh-install E2E (minutes, on PR + weekly cron)
- **Linux containers**: `ubuntu:24.04`/`26.04` or `mcr.microsoft.com/devcontainers/base:*` (has a non-root `vscode` user with sudo) — felipecrs pattern; stub platform probes (`wslpath`) to exercise WSL branches. Containers lack systemd/dbus/GNOME session, so those steps must be skippable or mocked.
- **GitHub-hosted runners** per OS (`ubuntu-24.04`, `windows-2025`, `macos-15`) — free for public repos; dirty (lots preinstalled), so either uninstall conflicting things first (geerlingguy) or point `HOME`/`USERPROFILE` at a scratch dir (dotbot).
- **dconf/gsettings in CI**: wrap with `dbus-run-session -- …`; for a real compositor use `mutter --headless --virtual-monitor 1920x1080` under a private D-Bus session (pattern used for GTK tests) [reported](https://pygobject.gnome.org/guide/testing.html). Full gnome-shell in a container needs many mocked services (accountsservice, upower, NM, polkit) [reported](https://blogs.gnome.org/shell-dev/2022) — usually not worth it; assert dconf keys instead.
- **Local disposable machines** (manual, before releases): Windows Sandbox (winget's own `SandboxTest.ps1` shows the pattern) [reported](https://github.com/kcastellino/winget-pkgs/blob/master/doc/tools/SandboxTest.md); a GNOME desktop VM (quickemu/virt-manager/incus VM) snapshot of a fresh Ubuntu install; Tart for macOS [unsure on details].

### 3.4 Idempotence & convergence
- Run the installer **twice**; second run must report zero changes (Ansible `changed=0` grep; chezmoi: `chezmoi verify` exits 0 when target matches source; `chezmoi diff` empty; mise: `plan --detailed-exitcode` == 0) [verified geerlingguy; chezmoi verify reported].
- Health check command: `doctor` that reports tools present + versions, config drift, denylist hits; Goss (`goss validate`, YAML assertions, Linux + limited Windows) if you want a declarative assertion file [reported](https://www.admin-magazine.com/Archive/2025/89/Server-validation-with-Goss). Post-install smoke probes: `zsh -i -c exit`, `bash -ic exit`, `pwsh -NoProfile -Command ". $PROFILE"`, `nvim --headless +qa`, `wezterm show-keys` [unsure exact flag].

### 3.5 Upgrade/migration tests (rarely done, most valuable for "hand-grown machine")
- Build a fixture image of the **old** setup (or the previous release tag of your repo), then run the new installer on top and assert: leftovers removed, no duplicated shell blocks, merged JSON keeps foreign keys, second run clean. sneivandt's "round-trip" jobs are the closest public example. Pin the old tag as a test input so the test stays meaningful.

### 3.6 Cost control
- Path-filtered workflows per OS (shunk031), weekly cron for slow E2E, `fail-fast: false`, macOS only on demand. Avoid the sebastienrousseau failure mode (50 workflows to babysit).

---

## 4. Hard problems and best known solutions

### 4.1 JSON configs co-owned by apps (Claude Code, VS Code, Windows Terminal)
- **Problem is real:** Claude Code itself writes `~/.claude/settings.json` (from `/config`, `/model`), and if the file is generated/read-only the change silently lasts one session; `~/.claude.json` holds sign-in, MCP servers and per-project trust and must not be tracked [verified](https://code.claude.com/docs/en/settings). Symlinking such files means the app either writes into your repo (noise, possible private data) or breaks the link on atomic save.
- **Best options, in order of preference:**
  1. **Use the app's own layering** when it exists: Windows Terminal **JSON fragments** in `%LOCALAPPDATA%\Microsoft\Windows Terminal\Fragments\<app>\*.json` can add profiles/schemes and `updates` existing profiles by GUID (UTF-8, every colour required for schemes) [verified](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions); Claude Code: project `.claude/settings.json`, plugins/marketplaces (`enabledPlugins`, `extraKnownMarketplaces`), `CLAUDE_CONFIG_DIR` to relocate the whole dir [verified]; git: `[include]`/`includeIf`; shells: `conf.d/` dirs; wezterm: Lua `require` of a local untracked file.
  2. **Owned-keys merge**: the repo declares only the keys it owns; the installer deep-merges them into the live file, preserves everything else, writes only if changed (no diff noise), and records which keys it owns so it can delete keys it previously set but no longer wants. chezmoi equivalent: `modify_` file with `{{- /* chezmoi:modify-template */ -}}{{ fromJson .chezmoi.stdin | setValueAtPath "a.b" "v" | toPrettyJson }}`, echoing stdin unchanged when nothing differs [verified](https://www.chezmoi.io/user-guide/manage-different-types-of-file/), [reported](https://fungible.codeberg.page/dotfiles/guide/templates/). `create_` = write once and never again. Note JSONC (comments) in VS Code/Windows Terminal: a strict JSON parser will choke — strip or use a JSONC-aware parser.
  3. Array semantics must be explicit (append-unique vs replace) — permissions lists are the usual trap.

### 4.2 Per-OS keybindings/config generation and verifying it
- Keep **one data file** of logical bindings (`action → chord`, with per-OS modifier mapping such as `CMD`→`Super` on Linux, `Ctrl+Shift` on Windows) and generate each target's config (wezterm Lua, VS Code `keybindings.json`, GNOME dconf). Then test: (a) no two actions share a chord within a target; (b) no generated chord collides with OS-reserved chords (GNOME `org.gnome.desktop.wm.keybindings`, `org.gnome.shell.keybindings`, `org.gnome.settings-daemon.plugins.media-keys`, custom-keybindings list; Windows reserved `Win+*`). GNOME itself does **not** detect duplicates reliably — mutter behaviour on conflicts is "apparently random" and Settings only sees registered bindings, not extension ones [verified issue/MR](https://gitlab.gnome.org/GNOME/mutter/-/merge_requests/1344), [issue](https://gitlab.gnome.org/GNOME/gnome-shell/-/issues/5051) — so a repo-side test is the only guard. No off-the-shelf tool found [unsure — none surfaced].

### 4.3 Fonts and pinned third-party plugins
- Fonts: download a **tagged** release asset (e.g. `ryanoasis/nerd-fonts/releases/download/vX.Y.Z/<Font>.zip`), verify SHA-256, unpack to `~/.local/share/fonts/<name>/`, `fc-cache -f`. Windows per-user (no admin, Win10 1809+): copy to `%LOCALAPPDATA%\Microsoft\Windows\Fonts` and register under `HKCU\Software\Microsoft\Windows NT\CurrentVersion\Fonts` [reported](https://www.powershellgallery.com/packages/Fonts/0.0.17/Content/Fonts.psm1); macOS `~/Library/Fonts`. chezmoi externals do this declaratively with `checksum.sha256` and `refreshPeriod` [verified](https://www.chezmoi.io/reference/special-files/chezmoiexternal-format/). Alternatives: `winget`/`scoop` nerd-fonts bucket, `brew --cask font-*`.
- Plugins (yazi, nvim, tmux, zsh): pin by **tag or commit SHA** in a manifest/lockfile (`lazy-lock.json`, `ya pkg` lock, `mise.lock`), and let Renovate/Dependabot open bump PRs (shunk031 has `renovate.yaml`). Never `@latest` in a reproducible install.

### 4.4 GitHub-release binaries
- **mise** is the 2026 default: `aqua:` backend preferred (registry, no plugins, Windows support, cosign/SLSA verification); `github:` backend for anything not in a registry (asset auto-scoring by OS/arch/libc, checksums + GitHub attestations recorded in `mise.lock`); **`ubi:` is deprecated — replace with `github:`** [verified](https://mise.jdx.dev/dev-tools/backends/github.html), [reported](https://mise.jdx.dev/dev-tools/backend_architecture). `mise.lock` revision 2 (Sept 2026) records full dependency graphs for npm/pip tools; `jdx/mise-action` runs `mise --locked` in CI [reported](https://newreleases.io/project/github/jdx/mise/release/v2026.9.7). Set `GITHUB_TOKEN` in CI to avoid rate limits.
- Standalone alternatives: aqua CLI itself, chezmoi `archive-file` externals, `gh release download --pattern` + checksum in your own script.

### 4.5 GNOME settings as code
- Discover keys with `dconf watch /` while clicking in Settings; store **curated partial** dumps (only keys you mean), not `dconf dump /` [reported](https://catern.com/gnometextconf.html). Apply with `dconf load /path/ < file` (relative paths) or per-key `gsettings set` (schema-validated — prefer it, it rejects typos). For exact restoration of a subtree, `dconf reset -f /path/` then load — but that destroys user tweaks; use only for subtrees you fully own (e.g. custom keybindings).
- Custom keybindings are a list of relocatable paths (`custom0`, `custom1`…): generate the list and each entry together, use stable path names.
- Terminal profiles are keyed by UUID — pin a fixed UUID in the repo.
- Extensions: `gext install <uuid>` + `gnome-extensions enable`; settings via their schemas with `--schemadir` [reported].
- System-wide alternative: keyfiles in `/etc/dconf/db/local.d/` + `dconf update` (needs root; locks possible) — good for defaults, not personal tweaks.
- CI: `dbus-run-session -- gsettings …` in a container with the schemas installed; assert with `gsettings get`.

### 4.6 Windows packages and PowerShell profiles
- **winget** for most apps (built in, `winget import/export` JSON, `--id` + `--exact`, `--version` pinning works for many manifests); **scoop** for portable, no-admin CLI tools and buckets (nerd-fonts, extras). Many users run both [reported](https://lemmy.federate.cc/comment/802045).
- **WinGet Configuration** (`winget configure -f configuration.winget`/`.dsc.yaml`, `test`/`validate`/`export` subcommands, DSC v3 `Microsoft.WinGet.DSC/WinGetPackage`) gives declarative packages + Windows settings in one YAML; it continues past failed units and needs admin for many resources; Microsoft recommends reviewing files before applying [verified](https://learn.microsoft.com/en-us/windows/package-manager/configuration/), [verified](https://learn.microsoft.com/windows/package-manager/winget/configure). Good for the Windows-only layer; doesn't help Linux.
- **PowerShell profile**: `$PROFILE` follows the Documents known folder, which **OneDrive Known Folder Move** redirects (also module path; Files-On-Demand placeholders break module loading) [reported](https://learn.microsoft.com/en-us/answers/a/8201066). Robust pattern: tiny stub at `$PROFILE` (managed block) that dot-sources the real profile from a non-synced path (e.g. `~/.config/powershell/`), which is already the profile location on Linux/macOS [reported](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_profiles). Mind Windows PowerShell 5.1 vs pwsh 7 having different profile paths, execution policy (`RemoteSigned` for CurrentUser), and UTF-8 (5.1 writes UTF-16LE by default — also bites Windows Terminal fragments).
- **Cross-shell helpers**: write the logic once as a standalone executable (Python/Go/script with shebang + `.cmd`/`.ps1` shim on PATH) and keep shell-specific code to thin wrappers only for things that must change the *current* shell (`cd`, env). Publish a per-command × per-shell compatibility matrix (renemarc) and test each wrapper in CI (`bash -ic`, `zsh -ic`, `pwsh -c`).

### 4.7 Keeping private data out of a public repo
- Layers that work together:
  1. **Design**: per-machine values live outside the repo (`~/.config/<tool>/config.json`, chezmoi `.chezmoi.toml.tmpl` with `promptStringOnce`); repo only has `*.example`. Already done here.
  2. **Denylist scanning**: a private, untracked list of literal names/emails/employer/customer strings (`.denylist`, or `~/.config/…/denylist`) consumed by a scanner in pre-commit *and* by `doctor`. With gitleaks/betterleaks: custom `[[rules]]` with `regex` + `keywords` + `[extend] useDefault = true`, config passed via `--config` from **outside** the repo so the list itself isn't published [verified config format](https://github.com/gitleaks/gitleaks). Use `gitleaks git --staged`-style staged scan in pre-commit; `protect`/`detect` were deprecated in v8.19 [verified].
  3. **Generic secret scanning** in CI (gitleaks-action / Betterleaks) and GitHub push protection (on by default for public repos [unsure — believed since 2024]).
  4. **Commit metadata** is the most-forgotten leak: author name/email in every commit, branch names, PR text, file paths like `C:\Users\<real-name>`. Use the GitHub noreply email for this repo (`includeIf "gitdir:~/dev/<this-repo>/"`), and add a CI check on `git log --format='%ae %ce'`.
  5. **CI enforcement** of the same checks (hooks are bypassable with `--no-verify`) [reported](https://hoop.dev/blog/stop-pii-leaks-with-pre-commit-security-hooks). In CI the private denylist isn't available — store it as an encrypted GitHub Actions secret and write it to a temp file at job start [unsure — my design suggestion].
  6. Cleanup when it happens: `git filter-repo`, then rotate anything secret; assume forks/caches retained it.
- mise's autosync is explicitly warned against for public repos: every autosave becomes a commit, so a briefly-present secret persists [verified](https://jdx.dev/posts/2026-09-07-dotfiles-that-save-themselves/).

### 4.8 Migrating from an older / hand-grown setup
- **Adopt, then converge**: first an inventory/`doctor` pass (what's installed, which files differ from desired, which old symlinks/blocks exist), then apply with backups (`file.bak-<timestamp>`) and a dry-run diff.
- **Migrations as ordered, idempotent scripts**: Omakub's `migrations/<unix-timestamp>.sh` run if newer than the recorded last-run marker [reported]; chezmoi `run_once_` keyed by content hash (bump a version comment to re-run), `run_before_`/`run_after_` ordering [reported](https://www.chezmoi.io/user-guide/use-scripts-to-perform-actions). Each migration should detect-and-skip so it's safe on fresh machines too.
- **Leftover removal** needs a record of what *you* created: managed blocks with begin/end markers, a state file listing owned paths/keys, `exact_` dirs in chezmoi, `chezmoi managed` / `mise ... unapply`. Without ownership records, cleanup degenerates into blunt `find -lname '*dotfiles*' -delete` [reported](https://terpconnect.umd.edu/~hibiki/en/note/chezmoi/).
- Test it (§3.5).

### 4.9 Secrets
- Fetch at apply time from a password manager CLI, never store: chezmoi `onepasswordRead "op://vault/item/field"`, `bitwarden`, `bitwardenFields`, `rbw`, etc. (results cached per run) [reported](https://www.mintlify.com/twpayne/chezmoi/reference/templates/password-manager-functions); in your own scripts, shell out to `op read` / `bw get` / `rbw get`. Prefer *references* in config (`op://…`, `env:`) over materialised secrets on disk; for SSH use the password manager's SSH agent (1Password, Bitwarden) instead of key files.
- For things that must be in git: age-encrypted files (chezmoi `encrypted_`, sops/agenix in Nix).
- CI: skip secret-dependent steps behind an env flag (`CI=1`) and test them with a fake CLI on PATH; most repos simply skip [reported, survey].

### 4.10 AI coding-agent tooling (Claude Code)
- Precedence: managed > CLI > project local > project shared > user [verified](https://code.claude.com/docs/en/settings).
- Track: rules/CLAUDE.md, skills, agents, commands, hooks — ideally packaged as a **plugin + marketplace** so one setting (`enabledPlugins`/`extraKnownMarketplaces`) installs them reproducibly; this is the cleanest "convention, not file copy" route.
- Merge (not symlink) `~/.claude/settings.json` (app writes it). Never track `~/.claude.json` (auth, MCP, trust) or `~/.claude/projects/` (transcripts) [verified, reported](https://codeongrass.com/blog/managing-claude-code-config-sprawl/).
- Validate against the schemastore schema in CI (warnings on new keys are expected).

---

## 5. Recommendation

### 5.1 Shape of a state-of-the-art setup for this goal (one person, Linux → Windows/macOS)

Keep the current architecture — it already matches the best patterns — and
make it more **data-driven, convergent and tested**:

1. **Thin, dependency-free orchestrator** (the existing stdlib Python
   `bootstrap`): one command (`setup.sh` / `setup.bat`) → `plan` (diff) →
   `apply` → `doctor`. Every step is "observe, compare, act if different" and
   reports `changed/ok/skipped`. This gives dry-run, idempotence assertions and
   migration for free. Python is a good choice: runs on all three OSes without
   compile, has `json`, `tomllib`, `pathlib`, `subprocess`.
2. **Manifests as data, per concern, per OS** (TOML/JSON in the repo):
   `packages.toml` (`apt`, `apt_repos` with keyring URL + fingerprint,
   `flatpak`, `winget`, `scoop`, `brew`), profiles (`base`, `desktop-gnome`,
   `work`, `personal`, `wsl`, `devcontainer`) as sets of tags; machine values
   in the untracked local config. Tests validate manifests against a schema.
3. **Delegate the hard, well-solved sub-problems to specialised tools via files,
   not via code coupling**:
   - dev tools / GitHub binaries → a committed `mise.toml` + `mise.lock`
     (aqua/github backends; drop ubi) — the orchestrator just runs `mise install --locked`.
   - Windows-only system state → optionally a `configuration.winget` file the
     orchestrator passes to `winget configure` (keep it optional; you can do the
     same with `winget install --id … --exact`).
   - Claude Code rules/skills → the existing `ai-personal` plugin/marketplace.
   This preserves "conventions over lock-in": each delegated file is
   swappable (mise → aqua, winget configure → plain winget).
4. **File ownership model**: (a) whole files you own → copy (not symlink) with
   backup; (b) co-owned JSON → owned-keys deep merge with an ownership record;
   (c) shell rc files → marker-delimited managed blocks; (d) apps with
   include/fragment mechanisms → use them (Windows Terminal fragments, git
   `includeIf`, `conf.d`). A state file records everything created so `doctor`
   can detect drift and migrations can remove leftovers.
5. **Generated per-OS configs from one source** (keybindings especially), with
   conflict tests (§4.2).
6. **Privacy guard** as tests: private denylist (outside git) + gitleaks/
   Betterleaks custom rules + commit-email check, run in pre-commit, `doctor`
   and CI (CI gets the denylist from an Actions secret).
7. **Secrets** only by reference from a password-manager CLI; nothing materialised in the repo.
8. **CI pyramid** (cost-conscious): every push — lint + unit + render-all-profiles
   + manifest/schema/keybinding/denylist checks on `ubuntu-latest` and
   `windows-latest`; on PR touching installers — Linux container E2E (fresh
   `ubuntu:24.04` + devcontainers base image, run twice, assert second run
   unchanged, then `doctor` must be clean) and Windows runner E2E with
   `USERPROFILE`/`APPDATA` redirected to a scratch dir; weekly cron — full E2E
   to catch upstream drift (apt repos, winget IDs, release assets); before
   bigger releases — a manual GNOME VM snapshot run and an **upgrade test**
   from the previous tag. Add macOS only when a Mac exists.

### 5.2 When to choose differently
- If you'd rather not own the orchestrator: **chezmoi** (dotfiles, templates,
  secrets, externals) + **mise** (tools) + per-OS package scripts run as
  `run_onchange_` scripts is the mainstream 2026 answer and fully cross-platform.
  Cost: Go-template logic gets hard to test; chezmoi becomes the convention.
- **mise bootstrap** may become the single-tool answer for packages + tools +
  dotfiles across all three OSes; re-evaluate in 2027 once command names are
  stable for a release cycle [reported churn](https://github.com/ray-manaloto/dotfiles/issues/448).
- **Nix/home-manager** only if you drop native Windows and accept Nix as the
  platform.

### 5.3 Trade-offs
- Custom orchestrator: maximum control and portability, but you own
  idempotence, drift detection and docs. Mitigation: keep it small, push
  domain logic into manifests and delegated tools.
- Copy vs symlink: copies are Windows-safe and survive app rewrites, but edits
  in place don't flow back — `doctor` must report drift and offer "adopt"
  (pull live changes back into the repo), which is the main thing symlink users
  miss.
- Pinning everything (fonts, plugins, binaries) gives reproducibility but
  creates bump work — automate with Renovate/Dependabot (Renovate has a mise
  manager [unsure on details]).

### 5.4 Pitfalls people report
- **Symlinked configs rewritten by apps** (atomic save replaces the link; or app writes private state into the repo) — Claude Code `settings.json`, VS Code, Windows Terminal [verified CC behaviour].
- **OneDrive-redirected `$PROFILE`/Documents** on Windows [reported].
- **UTF-16LE output from Windows PowerShell 5.1** breaking JSON consumers [verified for WT fragments].
- **CRLF** in shell scripts checked out on Windows → set `.gitattributes` `*.sh text eol=lf` (already done here).
- **run_once confusion**: a "run once" step that is not idempotent breaks the second machine or the re-run [reported, survey].
- **Nix GUI apps invisible in GNOME menu** on Ubuntu [reported].
- **`dconf dump /` committed wholesale** → machine-specific junk, monitors, recent files; curate keys instead [reported].
- **GNOME silently ignoring conflicting shortcuts** [verified issue].
- **CI that only checks exit code** of `./install` misses wrong state; add assertions and the second-run check [reported, survey].
- **CI sprawl** for a one-person repo (dozens of workflows) becomes the maintenance burden itself.
- **Big opinionated installers rot**: Omakub archived in 2026 [verified]; caarlos0's Nix → shell reversal [reported]. Keep the core small and boring.
- **Private data in commit metadata/paths**, not just file content.
- **Tool churn**: mise renamed bootstrap commands several times in weeks; gitleaks → Betterleaks; ubi deprecated in mise; Determinate installer dropped upstream Nix. Wrap third-party tools behind your own file conventions so swapping is cheap.

---

## Appendix: open questions / not verified
- Exact current flags of `gitleaks git --staged` vs Betterleaks equivalents.
- Whether `mise bootstrap`'s apt-sources/flatpak/winget support is complete enough to replace a custom package layer on Ubuntu GNOME + Windows today.
- A ready-made cross-target keybinding conflict checker — none found.
- Practical recipe for running gnome-shell (not just mutter) headless in GitHub Actions to test extensions — only partial sources.
- GitHub push-protection default state for personal public repos in 2026.
