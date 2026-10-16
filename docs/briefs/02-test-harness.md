# Slice 2: Test harness and CI skeleton

Branch `slice-02-test-harness`. See slice 2 in [the plan](../plan.md) and
H3, H5, M1, M2, L4 in the [plan review](../research/plan-review-2026-10.md).

## Goal

`tests/run.sh` runs unit and render tests locally and in CI, with every
tool pinned and checksum-verified in `.cache/bin/`. The first managed file,
the git config, goes red to green through it. CI runs the tests on Linux
and Windows, lints the workflow and scripts, and runs the privacy checks on
every branch and PR, with the denylist from an Actions secret.

## Acceptance criteria

### Tools

1. `scripts/tools.lock` pins, next to Betterleaks, each with sha256:

   | Tool | Version | Platforms | Checksum source |
   |---|---|---|---|
   | chezmoi | 2.73.1 | linux, darwin (amd64, arm64), windows amd64 | release `checksums.txt` |
   | actionlint | 1.7.12 | linux, darwin (amd64, arm64), windows amd64 | release `checksums.txt` |
   | shellcheck | 0.11.0 | linux, darwin (x86_64, aarch64), `.tar.xz` | computed when writing this brief (no upstream checksum file) |
   | bats-core | 1.14.0 | source tarball, any OS | computed when writing this brief (tag archive) |

   ```
   a3f958acb7d0e5d53fa43c2eec9bc8ae3b4fba8bcbfdce29a8881ca3ffc20a53  chezmoi_2.73.1_linux_amd64.tar.gz
   e60275b27f505ae2086bfb87b144eacf7377a89803120f6bd933d1852a93b0c6  chezmoi_2.73.1_linux_arm64.tar.gz
   0ec1869c60752644863bc4690878a290455f0d35c6e9b200ca4a822b35d2be54  chezmoi_2.73.1_darwin_amd64.tar.gz
   19a8d9778d90476cc2f0463be69e9d82e2b91ba7b2361dbfc5348f243b1ba731  chezmoi_2.73.1_darwin_arm64.tar.gz
   29c48a8d403f590cfacf16fbf9db3c2dc0a8ebe8b744db64bac6057c0266c65d  chezmoi_2.73.1_windows_amd64.zip
   8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8  actionlint_1.7.12_linux_amd64.tar.gz
   325e971b6ba9bfa504672e29be93c24981eeb1c07576d730e9f7c8805afff0c6  actionlint_1.7.12_linux_arm64.tar.gz
   5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644  actionlint_1.7.12_darwin_amd64.tar.gz
   aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f  actionlint_1.7.12_darwin_arm64.tar.gz
   6e7241b51e6817ea6a047693d8e6fed13b31819c9a0dd6c5a726e1592d22f6e9  actionlint_1.7.12_windows_amd64.zip
   8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198  shellcheck-v0.11.0.linux.x86_64.tar.xz
   12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588  shellcheck-v0.11.0.linux.aarch64.tar.xz
   3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6  shellcheck-v0.11.0.darwin.x86_64.tar.xz
   56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79  shellcheck-v0.11.0.darwin.aarch64.tar.xz
   bb537b70b15b732f6d8827dd6578e3d8ce166636ce1f18ea9a074184fcce9177  bats-core-1.14.0.tar.gz (github.com/bats-core/bats-core/archive/refs/tags/v1.14.0.tar.gz)
   ```

2. `scripts/fetch-tools.sh [tool...]` fetches the named tools (all without
   arguments) with the slice 1 guarantees: checksum before extracting,
   version check on every run, a clear failure on an unknown platform,
   nothing installed system-wide. The lock keeps one normalised platform
   key per line; the per-tool asset naming lives in the script. On Git Bash
   (`uname -s` = `MINGW*`/`MSYS*`) the platform is `windows_amd64` and the
   `.zip` assets are used. Betterleaks keeps working unchanged.

### Test runner

3. `tests/run.sh <unit|render|lint|all>` (POSIX sh, also runs in Git Bash
   on Windows) fetches what each mode needs and exits non-zero if any test
   fails. `all` runs every mode. `system` is reserved for slice 3 and fails
   with a clear "not yet" message.
   - `unit`: bats files under `tests/unit/`, plus the existing
     `tests/privacy.sh`.
   - `render`: bats files under `tests/render/`.
   - `lint`: shellcheck on every tracked shell script (`*.sh`, `.githooks/*`,
     shebang-detected scripts under `scripts/` and `tests/`) and actionlint
     on `.github/workflows/`.
4. Tests never touch the real home: every test sets `HOME`,
   `XDG_CONFIG_HOME` and `TMPDIR` to a temp dir, runs git with
   `GIT_CONFIG_NOSYSTEM=1`, and runs chezmoi with `--source home
   --destination <tmp> --config <profile> --cache <tmp> --persistent-state
   <tmp>`. A test asserts that a render leaves the real `$HOME` untouched
   (no file in it is newer than the test's start).

### Machine data and profiles

5. `home/.chezmoi.toml.tmpl` prompts once (`promptStringOnce`/
   `promptChoiceOnce`) for `role` (personal | work), `form` (desktop |
   headless | wsl | container), `name`, `github_identities` and `ci`
   (bool, default false). `github_identities` is a string of
   space-separated `owner=email` pairs. A render test runs it with
   `chezmoi execute-template --init --promptString/--promptChoice/
   --promptBool` and checks the resulting TOML parses and holds the given
   values.
6. `tests/profiles/<role>-<form>.toml`, eight files (role × form), each a
   complete chezmoi config with fake data: `ci = true`, a fake name, and two
   fake identities (`octo-one=11111111+octo-one@users.noreply.github.com`,
   `octo-two=…`). No real names, owners or emails anywhere in `tests/`.
7. Every profile renders without error (render test loops over all files
   in `tests/profiles/`, so a new profile is picked up automatically).

### First managed file: git config

8. `home/dot_config/git/config.tmpl` renders to `~/.config/git/config`
   (XDG, so a machine's `~/.gitconfig` is left alone until migration):
   - `user.name` from data, `user.useConfigOnly = true`, no `user.email`.
   - Per identity, two `includeIf "hasconfig:remote.*.url:…"` sections
     (`https://github.com/<owner>/**` and `git@github.com:<owner>/**`)
     with `path` to `~/.config/git/identities/<owner>`.
   - The template only turns data into lines; no branching beyond `range`.
9. The identity files hold `[user] email = <email>`. Since chezmoi can't
   render a variable number of files from one template, a
   `run_onchange_after_` script hands the pairs to a plain script in the
   repo (`scripts/git-identities.sh`, called via
   `{{ .chezmoi.workingTree }}`), which writes them under the destination
   dir chezmoi passes, never under a hardcoded `$HOME`. The script:
   - rejects a malformed pair, an owner that isn't a valid GitHub login, or
     an email that doesn't match
     `^[0-9]+\+[^@]+@users\.noreply\.github\.com$` (exit non-zero, message
     names the pair's position, not its value);
   - removes identity files for owners no longer in the data;
   - is idempotent (second run: no change, same output).
   Unit-tested with bats (`tests/unit/`) directly, without chezmoi.
10. Render tests on the rendered tree, per profile:
    - `git config -f <dest>/.config/git/config --list` parses;
    - end to end, with `HOME=<dest>`: a temp repo whose `origin` is
      `https://github.com/octo-one/x.git` gets `octo-one`'s email from
      `git config user.email`, the SSH form gets it too, and a repo with
      an unknown owner (or no remote) has no email and `git commit` fails;
    - a second `chezmoi apply` changes nothing (`chezmoi diff` empty).

### CI

11. `.github/workflows/ci.yml`, triggered on push to any branch, on
    `pull_request`, weekly (`schedule`) and `workflow_dispatch`, with
    `permissions: contents: read`, actions pinned by commit sha, and
    `fail-fast: false`:
    - **test:** matrix `ubuntu-latest`, `windows-latest`. Linux runs `unit`
      and `render`; Windows runs `render` under Git Bash (`shell: bash`).
      Tool cache keyed on `scripts/tools.lock`.
    - **lint:** `tests/run.sh lint` on Linux.
    - **privacy:** Linux, `fetch-depth: 0`. Writes secret `WS_DENYLIST` to a
      `mktemp` file (mode 600, removed at job end), exports its path as
      `WS_DENYLIST`, runs `scripts/privacy-check.sh all`. A missing secret
      fails the job (fail closed). Verify that `GIT_CONFIG_GLOBAL=/dev/null`
      doesn't trip git's `safe.directory` check on the runner.
12. **Text check for PR metadata.** `scripts/privacy-check.sh text` reads
    stdin and runs the denylist and default rules on it, with the same
    output rules as the other modes (rule id and line, never the match). In
    the privacy job it checks the branch name, and on `pull_request` the PR
    title and body. Event values reach the script only through `env:`,
    never through `${{ }}` inside `run:` (script injection). Unit-tested in
    `tests/privacy.sh` (clean text passes, denylisted text fails, no match
    printed).

### Docs

13. `docs/new-machine.md`: a step for creating the Actions secret, which I
    run myself: `gh secret set WS_DENYLIST < ~/.config/ws/denylist`.
    README: how to run the tests.
14. `docs/plan.md`: slice 1 marked merged; machine data lists
    `github_identities` instead of `email`, with the `useConfigOnly`
    rationale; slice 2 status.

## Files in scope

`scripts/tools.lock`, `scripts/fetch-tools.sh`, `scripts/privacy-check.sh`
(+ `scripts/lib/`), `scripts/git-identities.sh`, `tests/` (`run.sh`,
`unit/`, `render/`, `profiles/`, `privacy.sh`), `home/.chezmoi.toml.tmpl`,
`home/dot_config/git/config.tmpl`, `home/.chezmoiscripts/` (the identity
script), `.github/workflows/ci.yml`, `README.md`, `docs/new-machine.md`,
`docs/plan.md`.

## Out of scope

- `bootstrap.sh`, `expect.yaml`, `ws doctor`, system tests: slice 3.
- Other git settings (aliases, pager, signing): slice 8.
- Migrating an existing `~/.gitconfig`: slice 12.
- shfmt (would reformat slice 1's scripts; revisit later).
- Renovate: slice 6.
- Windows privacy checks and unit tests (Pester): Windows phase.

## Finish (orchestrator, after asking me)

- Create the `WS_DENYLIST` secret: I do this myself.
- After the first green CI run on `main`: branch protection on `main` with
  the CI jobs as required checks and "require branches to be up to date".

## Decisions

- Commit email: per GitHub owner from prompt data via `includeIf
  hasconfig:remote.*.url`, no global email, `useConfigOnly = true`. Owners
  and emails never appear in tracked files, so the public repo can't link
  my accounts; a repo without a matching owner refuses to commit instead of
  falling back to a wrong email.
- Identity files come from a plain script (criterion 9), because chezmoi
  can't render a variable number of files; this also gives the unit layer
  its first real target.
- Tools are fetched into `.cache/bin/` like Betterleaks, not installed
  system-wide and not via Docker.
- Unit tests run on Linux only for now; Windows gets render tests (M2).
- Unverified chezmoi details (whether scripts get the destination dir as
  `CHEZMOI_DEST_DIR` or only via `.chezmoi.destDir`; `execute-template
  --init` prompt flags in 2.73.1) are checked against chezmoi's docs and
  `--help`, not assumed.

### Decided with the test writer

15. Lock keys are normalised for every tool, Betterleaks included:
    `linux_amd64`, `linux_arm64`, `darwin_amd64`, `darwin_arm64`,
    `windows_amd64`. bats-core has one line with key `any`.
16. Interfaces: `scripts/git-identities.sh <dest_dir> <pairs>` (all pairs
    validated before anything is written; a duplicate owner, compared
    case-insensitively, fails as `pair <n>`; extra whitespace between pairs
    is tolerated; an empty or whitespace-only string removes every identity
    file). `privacy-check.sh text` reads stdin and reports
    `denylist-<n> … line <n>`. Prompt texts: `Role`, `Form`, `Name`,
    `GitHub identities`, `CI`.

### Implementation decisions (accepted)

17. The identity script reads `CHEZMOI_WORKING_TREE` and `CHEZMOI_DEST_DIR`
    from its environment instead of templating paths; the template carries
    only the pairs.
18. Windows uses a `.ps1` twin of the identity script that calls Git's
    `sh`; `home/.chezmoiignore` picks one per OS.
19. `.gitattributes` forces LF for `*.bash`, `*.bats` and `*.sh.tmpl`, so
    Windows checkouts keep render working.

### Review round 1 (two reviewers; P = privacy, C = correctness)

20. **GitHub's merge committer (P1).** `emails` accepts exactly
    `GitHub <noreply@github.com>` as *committer* (GitHub's own committer for
    merges made on the website). Authors and taggers still need the
    personal noreply form. Without this, every branch on `main` fails.
21. **No code from prompt data (P2, P3).** Both identity script templates
    `fail` when `github_identities` contains anything outside
    `[A-Za-z0-9=+@._ \t-]` (newlines included), so data can't end the
    here-doc or here-string.
22. **PR edits are checked (P4).** `pull_request` types include `edited`.
23. **No "no leaks found" after a scanner error (P5)** in `text` and blob
    scans.
24. **Two known owners in one repo (C1)** must refuse to commit, not pick
    one. `git-identities.sh` writes, into each owner's identity file, an
    `includeIf` per *other* owner (https and ssh forms) pointing to
    `~/.config/git/identities/.conflict`, which sets an empty `user.name`
    and `user.email`. Git then fails with "empty ident name". Verified on
    git 2.43.
25. **`~/.gitconfig` overrides the XDG config (C2).** Not fixed in code:
    documented in the plan (slice 3 `ws doctor` flags a `user.email` or
    `user.name` in `~/.gitconfig`; slice 12 migration removes it).
26. **`tests/run.sh lint` (C3, C4):** a non-shell file sorting last must
    not fail the listing; a failing `git ls-files` must fail lint.
27. **Source without a git working tree (C5):** the identity script fails
    with a clear message naming the missing script, not exit 127 from
    `sh`.
28. **Rerun when the logic changes (C6):** the run_onchange template also
    embeds a hash of `scripts/git-identities.sh`, so a fix there reaches
    existing machines. A hand-deleted identity file is not repaired by
    `chezmoi apply`; slice 3's `ws doctor` checks the files exist.
29. **Windows (C7, unverified):** the `.ps1` resolves `sh.exe` from Git's
    install dir (via `git --exec-path` or the location of `git.exe`), not
    from PATH, and never passes an empty argument (a whitespace-only pairs
    string already means "remove all").
30. **Test gaps (C8):** run.sh exit propagation for a failing unit file,
    failing `privacy.sh` and one failing mode under `all`; a render test
    that changes `github_identities` and re-applies; the cases from 20–27.

### Review round 3 (decided with me: fix all five)

31. **Owner matching ignores case and covers every GitHub URL form (C1).**
    Patterns fold letters with bracket classes (`[Oo][Cc]…`, verified with
    `hasconfig` on git 2.43) and cover `https://github.com/<owner>/**`,
    `git@github.com:<owner>/**` and `ssh://git@github.com/<owner>/**`. To
    keep that logic out of templates, `git-identities.sh` also writes
    `~/.config/git/identities/.includes` (every owner-matching `includeIf`
    line; the conflict includes stay nested in each owner's file, since
    only nesting expresses "a remote of A and a remote of B"); `config.tmpl` only renders
    `user.name`, `useConfigOnly` and one `[include]` of that file.
    Remotes of two owners in any case or URL form refuse to commit.
32. **Control bytes in identities (P1).** `emails` fails a commit or tag
    whose author, committer or tagger name or email contains a control
    byte, or whose record has an unexpected field count.
33. **Windows guard test (P2)** asserts on the line that calls `sh`.
34. **Non-ASCII file names are linted (C2):** `ls-files` with
    `core.quotePath=false` (or `-z`).
35. **Windows `sh` (C3, unverified):** prefer Git's `bin\sh.exe` (sets up
    PATH for the MSYS tools), fall back to `usr\bin\sh.exe`.

### Known limitation (decided with me)

36. `emails` and the metadata scan read an ident only up to its first
    `>`, so a hand-crafted object with a second `<email>` after it passes.
    `git commit` can't create one and `git fsck` rejects it. Tracked in
    issue #2 instead of a fourth review round.
