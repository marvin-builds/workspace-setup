# Slice 1: Repo hygiene and privacy checks

Branch `slice-01-repo-hygiene`. See slice 1 in [the plan](../plan.md) and
H5 in the [plan review](../research/plan-review-2026-10.md).

## Goal

The repo has its skeleton files, and nothing private can reach GitHub
unnoticed: before the first push, a local hook and a script that CI can call
(slice 2) scan staged changes and the full history for secrets and
denylisted names, and check that every commit email is the GitHub noreply
address.

## Acceptance criteria

1. `.chezmoiroot` contains `home`; `home/.chezmoiversion` contains `2.73.1`.
2. `.gitattributes`: `* text=auto`, `*.sh` and extensionless scripts under
   `scripts/` and `.githooks/` with `eol=lf`, `*.ps1` with `eol=crlf`.
3. `.gitignore` covers the tool cache (`.cache/`) and editor/OS litter.
4. `LICENSE`: MIT, `Copyright (c) 2026 Marvin Mai` (same holder as the old
   repo, already public).
5. **Denylist format**, unchanged from the old repo: one extended regex per
   line, case-insensitive, `#` comments and blank lines ignored. Path from
   `WS_DENYLIST`, else `${XDG_CONFIG_HOME:-$HOME/.config}/ws/denylist`. The
   file never lives in the repo.
6. **`scripts/privacy-check.sh <staged|history|emails|all>`**, POSIX sh:
   - Builds a temporary Betterleaks config outside the repo: `[extend]
     useDefault = true` plus one `[[rules]]` per denylist entry. Rule ids
     are `denylist-<n>`, so the id never reveals the entry.
   - `staged` scans the index, `history` commits; both pass `--redact`
     so a hit never prints the matched text (CI logs are public).
   - `emails` fails if any author or committer email doesn't match
     `^[0-9]+\+[^@]+@users\.noreply\.github\.com$`. Output names the commit,
     not the email.
   - Scope of `history`, `emails` and `all`: optional revisions after the
     mode (`privacy-check.sh history <rev>...`) limit the check to commits
     reachable from them; with none, every ref (`--all`, what CI uses).
     Local branches that are never pushed (e.g. backups made before a
     history rewrite) must not block a push.
   - Fails closed: missing denylist, missing scanner or an empty denylist
     is an error with a hint, not a pass.
   - Removes its temporary files on every exit path.
7. **Scanner provisioning:** `scripts/fetch-tools.sh` downloads Betterleaks
   v1.9.0 from its GitHub release into the gitignored `.cache/bin/`, verifies
   the sha256 before extracting, and skips the download when the right
   version is already there. Version and checksums live in one data file
   (`scripts/tools.lock`, so Renovate can bump them later); the script picks
   the asset by `uname -s`/`uname -m` and fails clearly on an unknown
   platform. It installs nothing system-wide. `privacy-check.sh` uses
   `.cache/bin/betterleaks` and calls the fetch script if it is missing.
   Checksums from the release's `checksums.txt`:

   ```
   1d39116e0a58dc94574715e2aa12a2dbd5062f193eee3fec011fef6ba06bd13b  betterleaks_1.9.0_linux_arm64.tar.gz
   f8b185a39ffcece2a1ca82bf3a4e7435cd81963ffd16b7a9128daf75f35f6de7  betterleaks_1.9.0_linux_x64.tar.gz
   83dd7eaab13d44a1e8e347a17064cdef153a1478db473276d41b38d55613d3f2  betterleaks_1.9.0_darwin_arm64.tar.gz
   68dfd83458d9e7f90663daa7a81c7f944083b170dae82e4f5f8d0581ed519ef1  betterleaks_1.9.0_darwin_x64.tar.gz
   ```

   Windows assets (`.zip`) wait for the Windows phase.
8. **Hooks** in `.githooks/`: `pre-commit` runs `staged`; `pre-push` reads
   git's stdin (`<local ref> <local sha> <remote ref> <remote sha>` per
   line), skips deletions (all-zero local sha) and runs `history` and
   `emails` on the local shas being pushed; nothing to push is a pass.
   Hooks find `privacy-check.sh` relative to their own location, so they
   work from any working directory. Enabled per clone with
   `git config core.hooksPath .githooks`, documented in the README.
9. **Tests** (`tests/privacy.sh`, POSIX sh, until slice 2 brings bats and
   `tests/run.sh`): each case builds a throwaway git repo and a throwaway
   denylist under a temp dir and asserts the exit code and that output
   contains no denylisted text, for: clean commit passes; staged denylisted
   word fails; denylisted word only in an old commit fails `history`;
   private email fails `emails`; noreply email passes; missing/empty
   denylist fails; a generic secret (fake AWS key) fails `staged`.
10. `privacy-check.sh all` passes on this repo's current history.

### Review round 1 (both reviewers, all reproduced)

11. **Denylist scan without Betterleaks' defaults.** The default config's
    global allowlist, prefilter and filter drop denylist hits (`*.svg`,
    lock files, `vendor/`, a match equal to `/home/<x>`). Denylist rules
    run in their own scan with a config that has no `[extend]`; the default
    rules keep their own scan.
12. **No suppression from inside the repo.** Inline `gitleaks:allow` /
    `betterleaks:allow` comments are ignored (`--ignore-gitleaks-allow`).
    A `.gitleaksignore` or `.betterleaksignore` anywhere in the work tree,
    tracked or not, or in the scanned commits, fails the check with a
    message naming the file.
13. **Merge commits are scanned**, including content only a merge adds
    (evil merge, conflict resolution).
14. **Metadata is checked against the denylist**, with the same RE2
    dialect as file contents: commit messages, author and committer names,
    file and directory paths, and for annotated tags in scope their message
    and tagger name. `emails` also covers tagger emails. A pushed
    annotated tag is in scope as the tag object, not only its commit.
15. **Paths are never printed** for any finding: output is rule id, commit
    (or `index`) and line. No grep-based masking.
16. **Scanner version is checked on every run.** `privacy-check.sh` always
    goes through `fetch-tools.sh`, which replaces a cached binary whose
    version differs from `tools.lock`.

### Review round 2 (third round decided with me: scan objects, not diffs)

Scanning `git diff`/`git log -p` output let attributes, config and replace
refs hide content. Content is now read from git's objects instead.

17. **Content scan reads objects.** `history` scans every blob reachable
    from the scope (`git rev-list --objects <revs>` or `--all`); `staged`
    scans the blobs in the index. Blobs are exported under their object
    id, not their path, and scanned with both configs (defaults,
    denylist). A hit is reported as rule id, blob short id, line, and the
    commit that introduced the blob (`git log --find-object`, `index` for
    staged). Binary content and files with NUL bytes are scanned; verify
    against Betterleaks that they really are.
18. **Hermetic git.** Every git call in the checks runs with
    `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
    `GIT_NO_REPLACE_OBJECTS=1` and `GIT_ATTR_NOSYSTEM=1`, plus `-c`
    overrides for repo-local keys that change output (colour, quoting).
    Must fail despite: `.gitattributes` with `-diff` or `binary`, a NUL
    byte in a file, `color.ui=always`, `log.showRoot=false`, a replace ref
    over a commit with a denylisted message, private email or content.
19. **Ignore files** are detected when they are symlinks and regardless of
    letter case (`.GitleaksIgnore`).
20. **Metadata parsing takes no markers from user data.** A control byte
    in a message, name or tag can neither hide a line nor end up in the
    output.
21. **Nested tags:** every tag object in a chain is checked (message,
    tagger name, tagger email), not only the outermost.
22. **`staged` checks staged paths** against the denylist.

### Review round 3 (handling decided with me)

23. **Shallow clones fail.** `history`, `emails` and `all` fail with a hint
    (fetch full history) when `git rev-parse --is-shallow-repository` is
    `true`, since history beyond the boundary can't be checked.
24. **No log parsing for binary files.** Every exported blob gets the
    fixed header line, so Betterleaks never skips one as binary and the
    result doesn't depend on its log format or the temp path (a space in
    `TMPDIR` used to disable the rescan). Line numbers stay correct.
25. Remove the code and comments that assume zip members are unpacked.

## Files in scope

`.chezmoiroot`, `home/.chezmoiversion`, `.gitattributes`, `.gitignore`,
`LICENSE`, `scripts/privacy-check.sh`, scanner provisioning script,
`.githooks/pre-commit`, `.githooks/pre-push`, `tests/privacy.sh`,
`README.md` (setup section), `docs/plan.md` (slice status).

## Out of scope

- CI workflow and the denylist Actions secret: slice 2.
- `includeIf` in the managed git config: slice 2's first managed file is
  git config, so it lands there. This clone already has the noreply email
  in `.git/config`, and `emails` enforces it.
- Denylist in Bitwarden: slice 11.
- Checks on PR titles, bodies and branch names: slice 2 (CI).

## Decisions

- Scanner: repo-local pinned fetch into `.cache/bin/`, not a system install
  and not Docker. The same script serves CI.
- Denylist until slice 11: `~/.config/ws/denylist` (override with
  `WS_DENYLIST`). I copy the old repo's `.denylist` there myself, since it
  is private data, not setup.
- Local checks cover only what is pushed; CI checks every branch on
  GitHub. Chosen so local backup branches with old private emails can stay.
- The generic-secret test plants a GitHub token (`github-pat`), because
  in v1.9.0 `aws-access-token` is a composite rule that ignores a lone key
  ID.
- Content is scanned as git objects, not diffs (criterion 17), because
  diff output depends on attributes, config and replace refs the scanned
  repo or machine controls. Patching each case would leave the next
  variant open.
- Content inside archives (zip-based files included) is not scanned; a
  dotfiles repo has no reason to hold them.
- UTF-16 text isn't matched; handled in the Windows phase (see plan).
- The pre-push hook rescans all history reachable from the pushed commits
  (about 27 s at 4000 commits). Fine for this repo; skipping commits
  already on the remote is a later optimisation.
- No legitimate way to suppress a finding yet (criterion 12). If a false
  positive from the default rules shows up, the allowlist goes into the
  out-of-repo config, never into the repo.
- Unverified Betterleaks details (staged-scan flag, `--redact`, config
  `[extend]` syntax in v1.9.0) are checked against `betterleaks --help` and
  its docs, not assumed from gitleaks.
