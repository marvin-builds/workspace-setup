# shellcheck shell=bash
# Runtimes and tools from mise (~/.config/mise/config.toml) on PATH. The
# activation applies the environment at once, not only at the first
# prompt, so `bash -ic` finds the tools too; it updates PATH per directory
# for a project's own mise.toml, and keeps each entry once in nested
# shells and on re-sourcing. Runs before 90-prompt.sh, so a starship from
# mise gives the prompt.
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
