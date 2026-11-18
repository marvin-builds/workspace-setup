# Slice 5: Packages

Branch `slice-05-packages`. See slice 5 in [the plan](../plan.md),
principles 1, 3 and 6, the apt-repo row of "Handling the hard cases", and
M5 in the [plan review](../research/plan-review-2026-10.md).

## Goal

What a machine gets from its package manager is data:
`home/.chezmoidata/packages.yaml` maps logical names to per-OS ids, with
role and form filters, and declares third-party apt repos with a pinned
key fingerprint. On Linux, `chezmoi apply` installs the filtered apt
packages and adds the repos they need, and does nothing on a second run.
A JSON Schema validates the data, and a CI job checks that every apt id
exists.

First entries: git, gh (GitHub's apt repo), ripgrep, fzf, glow (Charm's
apt repo), file.

## Acceptance criteria

### Data: `home/.chezmoidata/packages.yaml`

1. Two top-level keys:
   - `packages`: a map from logical name (`[a-z0-9-]+`) to an entry with
     - one key per supported OS column: `apt`, `flatpak`, `winget`,
       `scoop`, `brew`. Each is a package id (string) or an explicit
       `null` ("not on this manager"). Every column is present on every
       entry, so a new OS phase shows each gap.
     - optional `apt_repo`: the name of an `apt_repos` entry the apt id
       comes from.
     - optional `roles` and `forms` filters, like in `expect.yaml`
       (missing means all).
   - `apt_repos`: a map from repo name (`[a-z0-9-]+`) to
     - `key_url`: https URL of the signing key (ASCII-armored or binary);
     - `fingerprints`: a non-empty list of full 40-hex-digit primary key
       fingerprints, upper case, no spaces, unique;
     - `uris`, `suites`, `components`: the deb822 fields;
     - optional `architectures`.
   The keyring path and `.sources` file name are derived from the repo
   name (`/etc/apt/keyrings/ws-<name>.gpg`,
   `/etc/apt/sources.list.d/ws-<name>.sources`), so they can't collide
   with files other tools wrote.
2. Entries: `git`, `gh` (`apt_repo: github-cli`), `ripgrep`, `fzf`,
   `glow` (`apt_repo: charm`), `file`. No role or form filter on any of
   them. winget, scoop and brew ids are filled in where known, else
   `null`; `flatpak` is `null` for all.
3. Repo data comes from the vendors' install docs (GitHub CLI's
   `docs/install_linux.md`, Charm's README). The fingerprint is checked
   against the vendor's published value when it is pinned; where a vendor
   publishes none, the brief records how it was obtained.

### Schema

4. `tests/schema/packages.schema.json` (JSON Schema 2020-12) encodes
   criterion 1, including: every OS column required, ids non-empty
   strings or null, `apt_repo` only with a non-null `apt` id,
   fingerprint format, https-only `key_url` and `uris`, no unknown keys.
5. A unit test validates `packages.yaml` against it with a pinned
   validator from `scripts/tools.lock` (single binary with a checksum, no
   Python or Node runtime), plus negative fixtures that must fail (missing
   column, bad fingerprint, http URI, unknown key).
6. A unit test checks what the schema can't: every `apt_repo` names an
   existing `apt_repos` entry, and every `apt_repos` entry is used.

### Linux installer

7. Logic lives in `scripts/install-apt.sh` (POSIX sh, principle 6),
   called by `home/.chezmoiscripts/run_onchange_before_install-packages.sh.tmpl`
   in the pattern of the git-identities script: the template filters
   `packages.yaml` by role and form, passes the apt ids and the needed
   repos as data (not code), and embeds the sha256 of `install-apt.sh`
   and the rendered data so a change to either reruns it. `before_`, so
   later scripts can rely on the packages.
8. For each needed repo, the script
   - downloads the key to a temp file, dearmors it when ASCII-armored,
     and requires the set of its primary key fingerprints to equal
     `fingerprints` exactly (no key missing, no extra key);
     a mismatch or a failed download stops the script with a non-zero
     exit naming the repo, before anything is written (fail closed, unlike
     the rc migration: a wrong key is a security problem, not drift);
   - writes the keyring and a deb822 `.sources` file with `Signed-By`
     only when their content differs from what is there (mode 644, owned
     by root, written through a temp file and a rename).
9. `apt-get update` runs only when a repo file changed or a wanted id has
   no install candidate; `apt-get install -y --no-install-recommends`
   runs only for ids not already installed (`dpkg-query`). With
   everything in place, a run calls neither and makes no changes.
10. Tools the script needs that a minimal Ubuntu lacks (`gpg` for the
    fingerprint check) are installed first, through the same
    already-installed check.
11. Every privileged call goes through `sudo`; the script itself runs as
    the normal user. No `apt-get` (no Debian/Ubuntu family): error naming
    the missing manager, exit non-zero.
12. The package scripts are excluded on every OS but Linux by
    `.chezmoiignore`, like the shell base.

### Removal

13. Removing an entry from `packages.yaml` leaves the package installed
    (decided with me: accept leftovers). The README says so. A
    `remove:` list comes only when a real case needs one.

### `expect.yaml`

14. New `os: [linux]` checks with smoke `--version` (or the tool's
    equivalent) and `source: /usr/bin/<cmd>`, so a copy elsewhere on PATH
    doesn't pass: `gh`, `rg`, `fzf`, `glow`, `file`. `git` gets the
    source too.
15. `file` checks for `/etc/apt/keyrings/ws-github-cli.gpg`,
    `/etc/apt/keyrings/ws-charm.gpg` and the two `.sources` files.

### Tests

16. Unit tests for `install-apt.sh` with stub `sudo`, `apt-get`,
    `dpkg-query`, `gpg` and the download tool on PATH and a temp root for
    `/etc/apt` (an env override used only by tests): repo files written
    once, matching fingerprint accepted, mismatched or failed download
    writes nothing and fails, second run calls neither `apt-get update`
    nor `install`, only missing ids are installed, no data is evaluated as
    code.
17. Render tests for every profile: the template renders, lists exactly
    the filtered ids (a profile filter test with a fixture entry), and
    no render test ever runs real `sudo` or `apt-get`.
18. System test (both roles): after bootstrap, `ws doctor` passes with
    the new checks; idempotency step 2 (cleared script state) reruns the
    installer and leaves `/etc/apt/sources.list.d/` and
    `/etc/apt/keyrings/` byte for byte unchanged.

### Package id check (M5)

19. `scripts/check-package-ids.sh` adds every `apt_repos` entry (same code
    path as the installer) in a fresh `ubuntu:24.04` container and fails
    when any apt id in `packages.yaml`, unfiltered, has no install
    candidate (`apt-cache policy`). It covers entries the container role
    filters out. Other columns are checked in their OS phase.
20. CI job `packages` runs it on every event, including the weekly
    schedule, so upstream renames show up without a commit.

## Files in scope

`home/.chezmoidata/packages.yaml`, `home/.chezmoiscripts/` (installer
template), `home/.chezmoiignore`, `scripts/install-apt.sh`,
`scripts/check-package-ids.sh`, `scripts/tools.lock` (schema validator),
`tests/schema/`, `tests/expect.yaml`, `tests/unit/`, `tests/render/`,
`tests/system/`, `tests/run.sh` if a mode needs it,
`.github/workflows/ci.yml`, `README.md`, `docs/plan.md`.

## Out of scope

- Flatpak (decided with me): the `flatpak` column stays in the schema, but
  the installer path and the runner-VM job (layer 3) come with the first
  desktop app that needs them. The plan moves the VM job there.
- starship, yazi and other binaries not in Ubuntu's archive: mise
  (slice 6).
- winget, scoop and brew installers: Windows and macOS phases.
- Lines that cargo and Homebrew installers appended to a hand-grown
  bashrc: slice 12 inventory (a slice or a `local/` drop-in each).
- Package removal (criterion 13).

## Decisions

- gh from GitHub's apt repo, not Ubuntu's archive (2.45 on 24.04),
  decided with me. With glow's Charm repo, two real repos exercise the
  `apt_repos` path.
- Leftovers on removal are accepted (criterion 13), decided with me.
- Flatpak deferred to its first real app, decided with me.
- A fingerprint mismatch stops the apply (criterion 8). Every other
  installer failure also exits non-zero: a machine without its packages
  should not look applied.

### Decided with the test writer

21. **Destination guard (approved by me):** the installer does nothing
    unless `CHEZMOI_DEST_DIR` equals `CHEZMOI_HOME_DIR`; it prints one
    line containing "skip" and exits 0. Applying into another dir never
    installs system packages.
22. **Guard stubs:** `ws_isolate` puts failing `sudo`, `apt-get` and `apt`
    stubs first on PATH; they name the command, log to `$WS_GUARD_LOG` and
    exit 1, so no test reaches the real ones.
23. **No sudo when nothing changes:** with everything in place,
    `install-apt.sh` calls no `sudo`, so a no-op apply never prompts.
24. **All keys first:** every repo's key is verified before any file is
    written for any repo.
25. **`install-apt.sh` interface:** `install-apt.sh install|check`, data on
    stdin, one tab-separated record per line
    (`repo  name  key_url  fingerprint  uris  suites  components  architectures`
    or `package  id`), list fields joined by spaces, `#` and empty lines
    ignored. Every line is validated before anything runs; a bad line
    fails with its line number. `WS_APT_ROOT` (tests only) prefixes the
    `/etc/apt` paths; `Signed-By` always names the real path. Keys come
    from curl, are dearmored only when armored, and the fingerprint
    compared is the primary key's (`pub` then `fpr`), so a subkey
    fingerprint is rejected. Files go to a temp file in the target dir,
    then `sudo mv` and `sudo chown root:root`, mode 644. `check` adds the
    repos, updates once and fails listing ids without a candidate,
    installing nothing.
26. **`check-package-ids.sh` interface:** `check-package-ids.sh
    [<packages.yaml>]`; reads the file unfiltered with chezmoi, pipes the
    data into one `docker run --rm -i -v <repo>:/src:ro ubuntu:24.04`
    running `install-apt.sh check`; exits with docker's status, and
    non-zero naming docker when it is missing.
27. **Lists in YAML:** `uris`, `suites`, `components` and `architectures`
    are YAML lists.
28. **Id patterns:** apt `^[a-z0-9][a-z0-9+.-]+$`; other managers
    `^[A-Za-z0-9][A-Za-z0-9+._/@-]*$`; suites and components without
    whitespace or quotes (`*` allowed); roles and forms non-empty unique
    lists.
29. **expect.yaml ids:** `pkg-<logical name>` with `os: [linux]`,
    `source: /usr/bin/<cmd>` and `<cmd> --version`; `apt-keyring-<repo>`
    and `apt-sources-<repo>`. The all-OS `git` check keeps no source, since
    `/usr/bin` would break it on other OSes; `pkg-git` carries it on Linux.
30. **Validator:** jv 6.0.3 (santhosh-tekuri/jsonschema `cmd/jv`), YAML
    instances by extension. The release publishes only md5 files: every
    asset's md5 matched, and the pinned sha256s were computed from those
    downloads; the tag commit `b0fc661f` matches the binary's build info.
    `jv --version` prints a pseudo-version with that commit, which the
    fetch's version check matches.
31. **Fingerprints:** GitHub CLI's
    `2C6106201985B60E6C7AC87323F3D4EA75716059` is pinned in a test (GitHub
    publishes it in `install_linux.md`). Charm publishes none; its
    fingerprint is format-checked and the implementer records here how it
    was obtained (criterion 3).

### Implementation round 1

32. **Every primary key is pinned (security):** GitHub's keyring holds two
    primary keys (full fingerprints in `packages.yaml`): `2C61…6059`,
    expired 2026-09-05, and `7F38…2313325`, which signs the current
    `InRelease`; `install_linux.md` lists both. Comparing only the
    first primary key would pass on the expired one and install the
    signing key unchecked. So `fingerprint` became `fingerprints` (a
    list), and a keyring is accepted only when its set of primary key
    fingerprints equals the pinned set. A vendor adding a key fails the
    apply until the pin is updated, and the weekly `packages` job shows
    it. This supersedes the single fingerprint in criteria 1 and 8 and
    decisions 25 and 31; the data line carries the fingerprints joined by
    single spaces.
33. **Charm's fingerprint** `ED927B38BE981E53CA09153D03BBF595D4DFD35C`
    (criterion 3): read from `https://repo.charm.sh/apt/gpg.key` with
    `gpg --show-keys`; the same key is served by keyserver.ubuntu.com and
    as Charm's yum key, and it signs the current `InRelease`. Charm
    publishes no fingerprint. The key expires 2027-07-14.
34. **Missing install script message:** the installer template fails at
    render time naming `scripts/install-apt.sh` when the source is not a
    clone of the repo, like the identity script; the slice 3 render test
    for that message accepts the new name.

### Review round 1 (two reviewers; C = correctness, P = portability/privacy)

35. **Repo already configured elsewhere (C1, P1; decided with me):** a
    machine that set up the GitHub CLI or Charm repo the vendor's way
    (e.g. `github-cli.list` with another `signed-by`) gets a second
    source for the same URI, and apt then refuses every command. Before
    writing anything, in the same pass as the key checks, the installer
    looks for each repo's URIs in `sources.list`, `sources.list.d/*.list`
    and `*.sources` other than its own `ws-*` files (trailing `/` ignored).
    A match stops the run, naming the repo and the file, and nothing is
    written. If `apt-get update` fails after this run wrote repo files,
    the run puts back what was there before (removes new files, restores
    replaced ones), so a failed apply never leaves apt broken. Removing the
    old setup's vendor sources is a dated migration in slice 12.
36. **No download when nothing changed (P2):** a repo whose keyring on
    disk already passes the fingerprint-set check and whose `.sources`
    matches is not downloaded again, so a rerun works offline.
37. **curl (C2, criterion 10):** `curl` and `ca-certificates` are
    installed first when missing, like `gpg`.
38. **Installed status (C3, P3):** a package counts as installed when its
    dpkg status ends in ` ok installed` (held packages, one line per
    architecture), so a held package never brings back `sudo`.
39. **Locale (P3):** apt output that is parsed comes from `LC_ALL=C`.
40. **Docker config (P3):** `check-package-ids.sh` runs docker with an
    empty temporary `DOCKER_CONFIG` (keeping the current context and CLI
    plugins), like `tests/run.sh system`.
41. **Cache key (P3):** the `packages` job gets its own cache key, since it
    fetches only chezmoi.

### Review round 2 (C4–C7, P4–P5; the third round went to me)

42. **Key renewals (C4, P4; decided with me):** a vendor that extends a
    key's expiry keeps its fingerprint, so a keyring on disk passed the
    set check forever and a renewed key never arrived (Charm's expires
    2027-07-14). Each `apt_repos` entry now also pins `key_sha256`, the
    sha256 of the key file as served. A download must match it and the
    fingerprint set, or the run fails closed naming the repo. The pinned
    hash is written as a comment into the repo's `.sources` file, so a
    pin bump changes that file and forces a download, while a rerun with
    unchanged data still reuses the keyring on disk and works offline. A
    renewal fails the weekly `packages` job on the hash; bumping the pin
    reruns the installer on every machine. The data line gains the hash
    as a field after the fingerprints.
43. **Disabled vendor sources (C5):** a deb822 stanza with `Enabled: no`
    is not a conflict; `.sources` files are read stanza by stanza.
44. **`Field:value` without a space (C6):** in `.sources` files the field
    name is stripped before URIs are compared, so `URIs:https://…` is
    found too.
45. **Temp files after a failed write (C7, P5):** a failed write removes
    its own temp file before returning, so a rollback never leaves one in
    `/etc/apt`.
46. **README (P):** gpg, curl and ca-certificates are installed only
    when a third-party repo is needed.
47. **Key fields grouped (privacy scanner):** `key_sha256: <hash>` on one
    line matches the scanner's generic-api-key rule (an identifier with
    "key" followed by a long value), and the repo allows no suppressions.
    So each `apt_repos` entry groups its signing key under `key:` with
    `url`, `sha256` and `fingerprints` (replacing `key_url`, `key_sha256`
    and `fingerprints`). The data line passed to `install-apt.sh` is
    unchanged.

### Review round 3 (final check, C8)

48. **apt booleans and rollback order (C8):** apt reads `Enabled:` as a
    boolean, so `no`, `false`, `off`, `without`, `disable` and `0` (any
    case) mark a stanza disabled. A rollback restores in reverse order,
    the `.sources` file before the keyring, so an interrupted rollback
    never leaves an old keyring next to a sources file with the new pin.
