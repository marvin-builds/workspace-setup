# New machine

Manual steps that can't be scripted yet, in order. Each one names the slice
that replaces it; remove the step when that slice lands.

## Working on this repo

1. **Denylist** (replaced by slice 11, Bitwarden). Put the private denylist
   at `~/.config/ws/denylist`, readable only by you:

   ```sh
   install -D -m 600 <path to your denylist> ~/.config/ws/denylist
   ```

   Format: one regex per line, case-insensitive, `#` comments. Without it
   the privacy checks fail closed.

2. **Hooks** (replaced by slices 3 and 9: bootstrap and `ws clone` apply
   the hooks convention). In the clone:

   ```sh
   git config core.hooksPath .githooks
   ```

3. **Check:** `scripts/privacy-check.sh all HEAD` passes. The first run
   downloads and verifies the pinned Betterleaks into `.cache/bin/`.
