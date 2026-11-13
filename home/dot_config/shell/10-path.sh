# shellcheck shell=bash
# ~/.local/bin first, so tools installed there win over system ones. Checked
# before adding, because nested shells and re-sourcing run this again.
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) PATH="$HOME/.local/bin${PATH:+:$PATH}" ;;
esac
export PATH
