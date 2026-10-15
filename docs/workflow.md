# Workflow

How work on this repo is split between an orchestrator and role agents. The
roles are conventions about who reads and writes which files; any agent tool
that can start a fresh session with its own context can fill them.

## Why

- The orchestrator's context stays small: it holds decisions, not file dumps.
- Fresh agents don't inherit assumptions. A test writer that hasn't seen the
  implementation writes tests against the brief, and a reviewer that hasn't
  seen the reasoning reads the diff as it is.
- Handoffs go through files in the repo, so every step can be checked and
  repeated.

## Roles

| Role | Reads | Writes | Must not |
|---|---|---|---|
| Orchestrator | everything | briefs, `docs/plan.md`, git (branches, commits), messages to me | write tests or production code |
| Test writer | brief, existing tests, `docs/plan.md` | `tests/` only | read or write the implementation |
| Implementer | brief, tests, source | source under `home/`, scripts | change tests (a wrong test is reported back) |
| Reviewer | brief, diff, `docs/plan.md` | a findings list | change files |

No role agent runs `bootstrap.sh` or `chezmoi apply` against the live system,
pushes or rewrites history. Only the orchestrator asks me for those.

## Per slice

1. **Brief.** The orchestrator branches off `main` and writes
   `docs/briefs/<NN>-<slug>.md`: goal, acceptance criteria, files in scope,
   out of scope. Open questions go to me before any agent starts.
2. **Tests.** The test writer adds failing expectations. The orchestrator runs
   `tests/run.sh all`, checks that the new tests fail for the stated reason and
   commits them.
3. **Implementation.** The implementer makes the tests pass without touching
   them. If a test looks wrong, it stops and reports. The orchestrator then
   decides with the test writer, or with me, and doesn't let the implementer
   adjust it.
4. **Review.** One or more reviewers, each with one focus: correctness against
   the brief, privacy (nothing private in tracked files), idempotency, OS
   portability. Each finding names a file, line and failure scenario.
5. **Fix loop.** The orchestrator passes confirmed findings to an implementer
   and drops findings it can disprove, giving the reason. Repeat 4–5 until no
   findings remain. A third round goes to me instead.
6. **Finish.** The orchestrator runs `tests/run.sh all` itself (reports from
   agents are not evidence), commits, updates the slice status in
   `docs/plan.md` and asks me before pushing or opening a PR.

## When to use it

Agents cost tokens and time, so they are used only where they pay off. The
default is to work directly, still test first. Use the roles when at least one
of these holds:

- the change adds behavior across several files (most slices);
- it touches privacy-relevant data, secrets or the bootstrap;
- the orchestrator's context is already crowded.

Use only the roles that help. A small change in a sensitive area may need
just one reviewer; a doc change needs none. When unsure, say which roles you
plan to use and why before starting them.

## Parallel work

Slices run one after another by default, because later slices build on earlier
ones. Independent slices may run in parallel only in separate worktrees and
branches.
