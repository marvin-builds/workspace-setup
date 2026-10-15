# Agent instructions

This repo is the source of truth for how my machines are set up. The chezmoi
source state lives in `home/` (`.chezmoiroot`); the root holds the
bootstrap, tests and docs. The plan and implementation slices are in
`docs/plan.md`; read it before starting work.

## Change the machine only through this repo

- Every setup change, fixes included, goes into this repo first. The machine
  is then changed only by `bootstrap.sh` or `chezmoi apply`.
- Never fix the live system by hand: no direct edits under `~/.config`, no
  manual package or font installs.
- Ask before running `bootstrap.sh` or `chezmoi apply` against the live
  system. Tests render into a temporary destination or run in a container.

## Test first

Start every change with a failing expectation in `tests/expect.yaml` or a
render test, then implement. `tests/run.sh all` must pass before a PR.

## Public repo

Nothing private goes into tracked files: no secrets, employer or customer
names, personal email, machine-specific paths. Those come from chezmoi
prompt data or the password manager.
