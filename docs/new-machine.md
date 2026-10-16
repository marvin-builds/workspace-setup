# New machine

Manual steps that can't be scripted yet, in order. Each one names the slice
that replaces it; remove the step when that slice lands.

Start with the bootstrap (see the [README](../README.md#new-machine)):

```sh
curl -fsSL https://raw.githubusercontent.com/marvin-builds/workspace-setup/main/bootstrap.sh | sh
```

It clones this repo to `~/dev/workspace-setup`, enables its hooks and
applies the setup. `ws doctor` then shows what is still missing.

## Working on this repo

1. **Denylist** (replaced by slice 11, Bitwarden). Put the private denylist
   at `~/.config/ws/denylist`, readable only by you:

   ```sh
   install -D -m 600 <path to your denylist> ~/.config/ws/denylist
   ```

   Format: one regex per line, case-insensitive, `#` comments. Without it
   the privacy checks fail closed.

2. **Hooks in other clones** (replaced by slice 9: `ws clone` applies the
   hooks convention). The bootstrap already sets it for this repo's clone.
   For a clone you made by hand, of this or another repo with a
   `.githooks/` dir, run in it:

   ```sh
   git config core.hooksPath .githooks
   ```

   `ws doctor` warns about clones directly under the repos dir that miss
   it.

3. **Check:** `scripts/privacy-check.sh all HEAD` passes. The first run
   downloads and verifies the pinned Betterleaks into `.cache/bin/`.

## Once per GitHub repo

4. **Denylist for CI** (manual, run it yourself). The privacy job in CI reads the denylist
   from the Actions secret `WS_DENYLIST` and fails without it. From the
   clone, with the denylist from step 1:

   ```sh
   gh secret set WS_DENYLIST < ~/.config/ws/denylist
   ```

   Run it again whenever the denylist changes.
