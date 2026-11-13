# Slice 4: Shell base

Branch `slice-04-shell-base`. See slice 4 in [the plan](../plan.md),
principles 5 and 9 (emacs mode), the rc-file row of "Handling the hard
cases", and M4 in the [plan review](../research/plan-review-2026-10.md).

## Goal

The repo owns `~/.bashrc`. It stays thin: it loads one drop-in per topic
from `~/.config/shell/`, then untracked machine drop-ins from
`~/.config/shell/local/`. A new interactive bash has `~/.local/bin` on PATH
once, emacs line editing and the starship prompt when starship is
installed. A dated migration script removes the marker blocks the old setup
repo wrote into rc files.

## Acceptance criteria

### `~/.bashrc`

1. `home/dot_bashrc` (a plain file unless a template is needed) is managed
   on Linux and excluded on Windows by `.chezmoiignore` (Git Bash comes
   with the Windows phase).
2. For a non-interactive shell it returns before doing anything else.
3. It sources, in this order and in glob order within each dir, every
   readable `~/.config/shell/*.sh`, then every readable
   `~/.config/shell/local/*.sh`. A missing `local/` dir or an empty glob
   produces no error and no output.
4. It contains no logic beyond that loop: topics live in drop-ins.

### Drop-ins (`home/dot_config/shell/`)

Names carry a two-digit prefix so the load order is visible. Each is bash,
passes `bash -n` and shellcheck (`# shellcheck shell=bash`).

5. **`10-path.sh`:** puts `~/.local/bin` at the front of PATH unless it is
   already in PATH. Sourcing the bashrc again (a nested `bash -i`, or
   `. ~/.bashrc`) never adds a second entry.
6. **`20-history.sh`, `30-defaults.sh`, `40-aliases.sh`,
   `50-completion.sh`:** the parts of Ubuntu's `/etc/skel/.bashrc` worth
   keeping, so owning the file is no regression: history settings
   (`ignoreboth`, `histappend`, larger sizes), `checkwinsize`, `lesspipe`
   and `dircolors` when present, the colour aliases and `ll`/`la`/`l`,
   `~/.bash_aliases` when present, bash-completion when present. Every
   external tool is guarded, so a minimal container gets no errors.
7. **`60-editing.sh`:** `set -o emacs`.
8. **`90-prompt.sh`:** when `starship` is on PATH, `eval "$(starship init
   bash)"`; otherwise a plain coloured `user@host:dir$` prompt. No error or
   output when starship is missing. No `starship.toml` in this slice
   (starship's defaults; app configs are slice 8, the install is slice 5
   or 6).

### Migration of the old rc blocks

9. `home/.chezmoiscripts/run_once_after_migrate-20261113-old-rc-blocks.sh`
   (POSIX sh, excluded on Windows) removes these blocks from `~/.bashrc`
   and `~/.zshrc`, each from its begin line through its end line:
   - `# >>> ai-workspace >>>` … `# <<< ai-workspace <<<`
   - `# >>> yazi-setup: <name> >>>` … `# <<< yazi-setup: <name> <<<`
   - `# >>> lazygit-setup: <name> >>>` … `# <<< lazygit-setup: <name> <<<`
   Everything outside the blocks stays byte for byte, including the file's
   mode. A missing file is skipped.
10. A begin line without its end line: the file is left unchanged, the
    script prints a warning naming the file (not its content) to stderr
    and exits 0, so the rest of the apply goes on; `ws doctor` reports it
    (criterion 12).
11. Running the script again changes nothing. Files are rewritten through
    a temp file in the same dir and a rename, never truncated in place.
    `~/.bashrc` normally has no blocks by then (chezmoi replaced it
    before the `after` script); the script must still handle it.

### `expect.yaml`

12. New checks, `os: [linux]`:
    - `bashrc`: `file: ~/.bashrc`.
    - `shell-path`: a new interactive bash, also a nested one, has
      `~/.local/bin` in PATH exactly once (smoke command via `bash -ic`).
    - `shell-emacs`: emacs mode is on in a new interactive bash.
    - `old-block-*`: `line` checks with `count: 0` for each known old
      begin line (`# >>> ai-workspace >>>`, `# >>> yazi-setup: y function
      >>>`, `# >>> lazygit-setup: lg >>>`) in `~/.bashrc` and `~/.zshrc`.
      A missing file counts as 0.

### Tests

13. Render tests for every profile: the bashrc and all drop-ins render,
    pass `bash -n` and shellcheck.
14. Behaviour tests against a rendered home (`HOME` pointing at the render
    destination, `bash -i` with no tty):
    - PATH has `~/.local/bin` once, also after re-sourcing and in a
      nested shell;
    - emacs mode on;
    - a `local/*.sh` drop-in is sourced after the managed ones (it can
      override an alias);
    - no `local/` dir and no starship: no stderr output;
    - a stub `starship` on PATH: its init output is evaluated;
    - a non-interactive `bash -c '. ~/.bashrc'` sources no drop-in.
15. Unit tests for the migration script with fixture rc files: all three
    block kinds removed, surrounding text and mode kept, CRLF-free LF
    files assumed, second run is a no-op, malformed block leaves the file
    unchanged and warns, missing files skipped, no other file in `$HOME`
    touched.
16. System test: one role's container run starts with a `~/.bashrc` and
    `~/.zshrc` seeded with all three old blocks (a fake, path-free
    version), then bootstrap; `ws doctor` passes, including the
    `old-block-*` checks. The existing idempotency steps cover the new
    files (re-running the migration via cleared script state changes
    nothing).

## Files in scope

`home/dot_bashrc`, `home/dot_config/shell/`, `home/.chezmoiscripts/`
(migration script), `home/.chezmoiignore`, `tests/expect.yaml`, `tests/`
(render, unit, system fixtures), `docs/plan.md` (slice 3 and 4 status),
`README.md` if it lists managed files.

## Out of scope

- Installing starship (slice 5 or 6) and a `starship.toml` (slice 8).
- `~/.profile`, `~/.bash_profile` and `~/.zshrc` ownership: not managed
  (bash only; Ubuntu's `~/.profile` already sources `~/.bashrc`).
- A separate "foreign lines in the bashrc" doctor check: a line someone
  appended to the owned `~/.bashrc` already shows up as drift in
  `ws doctor` (`chezmoi status`), with the hint to move it to `local/`.
- The old setup's PowerShell profile blocks and Git Bash: Windows phase.
- Replacements for the helpers the old blocks defined: `ws <cmd>`,
  `clone` and `slice` come in slice 9; the rest, and lines third-party
  installers appended to a hand-grown bashrc, are part of the slice 12
  inventory (a slice or a `local/` drop-in each).

## Decisions

- Ubuntu's skel defaults are carried over as drop-ins (criterion 6),
  decided with me.
- A malformed old block warns and lets the apply go on; `ws doctor` fails
  on the leftover marker (criterion 10), decided with me.
- `~/.bashrc` is owned whole (M4), not edited between markers; drift from
  appended lines is reported by the existing drift check.

### Decided with the test writer

17. **Emacs check:** bash turns emacs mode on by default, even without a
    tty, so the test and the `shell-emacs` smoke start bash with `-o vi`
    and expect the bashrc to switch to emacs.
18. **Destination:** the migration script works in
    `${CHEZMOI_DEST_DIR:-$HOME}`, like the git-identities script, so
    render tests that apply into a temp dir never touch `$HOME`.
19. **Malformed files are all or nothing:** if any block in a file is
    unterminated, no block in that file is removed. Markers match only as
    whole lines.
20. **Edge cases left alone:** an end line without a begin line is not a
    block and stays; a begin line is closed only by the end line with the
    same name (otherwise the file counts as malformed). The old repo
    always wrote matched pairs, so these get no dedicated tests.
21. **Test shells:** behaviour tests run bash under `env -i` with `HOME`
    at the render destination, a stub dir plus `/usr/bin:/bin` as PATH,
    `TERM=dumb` and `setsid -w` when available; bash's job-control notices
    are filtered from stderr.
22. **System test:** the `personal` run seeds `~/.bashrc` and `~/.zshrc`
    (mode 600) from `tests/system/fixtures/old-rc`; afterwards `.zshrc`
    must equal `old-rc.migrated` with its mode kept. The `work` run starts
    without a `.zshrc` and must not get one.

### Review round 1 (two reviewers; C = correctness, P = privacy/portability)

23. **Symlinked rc files (C1, P1):** a `~/.bashrc` or `~/.zshrc` that is a
    symlink is never replaced or rewritten. The script only reads through
    it: with old blocks (or unreadable), it warns naming the path and goes
    on, like a malformed block; without blocks it stays silent. Rewriting the target would
    edit a file another repo owns; `ws doctor` reports the leftover
    markers through the link.
24. **Unreadable or unwritable rc file (C4):** warn naming the file and go
    on with exit 0, like a malformed block, so one bad file never blocks
    every later apply. Doctor reports it.
25. **CRLF rc files (C3):** markers match with or without a trailing
    `\r`; a block in a CRLF file is removed and the other lines keep
    their CRLF endings.
26. **Login shells (C2):** Ubuntu's `~/.profile` prepends `~/.local/bin`
    after sourcing the bashrc, so a login shell has it twice. `~/.profile`
    stays out of scope (slice 12 inventory); the `shell-path` smoke runs
    bash in a clean environment (`env -i` with `HOME`, a minimal PATH and
    `TERM=dumb`), so it checks the bashrc, not the caller's PATH.
27. **failglob (C5):** the bashrc loads the drop-ins with `nullglob` on
    and `failglob` off, restoring both afterwards, so an empty `local/`
    never stops the managed drop-ins.
28. **Fixed location (C6):** the bashrc always reads `~/.config/shell`
    (chezmoi installs there whatever `XDG_CONFIG_HOME` says); criterion
    3's `XDG_CONFIG_HOME` clause is dropped.
29. **Existing bashrc (C7):** the README's bootstrap section says that
    bootstrap replaces an existing `~/.bashrc` and to back it up or move
    machine lines to `~/.config/shell/local/` first (backup is slice 12).
30. **Line endings (P3):** `.gitattributes` forces LF for
    `home/dot_bashrc` and `tests/system/fixtures/*`.
31. **Linux only (P4):** `.chezmoiignore` excludes the shell base and the
    migration on every OS but Linux, matching the `os: [linux]` checks;
    the macOS phase flips one condition.
32. **Doctor's marker checks (P5):** they cover the block names the old
    repo actually wrote (`y function`, `lg`); other names are not
    expected. Accepted as is.
