#!/bin/sh
# Removes the marker blocks the old setup repo wrote into ~/.bashrc and
# ~/.zshrc (ai-workspace, yazi-setup: <name>, lazygit-setup: <name>), each
# from its begin line through its end line. Runs once per machine; running
# it again finds no blocks and changes nothing.
#
# chezmoi exports the destination as CHEZMOI_DEST_DIR, so an apply into
# another dir never touches $HOME. A file this script can't safely change
# (a block without its end line, a symlink, unreadable, no temp file
# possible) is left alone with a warning and the script still exits 0, so
# one bad file never blocks later applies; ws doctor reports the leftover
# markers.
set -u

dir=${CHEZMOI_DEST_DIR:-$HOME}

# warn <file> <reason>: names the file, never its content.
warn() {
    printf 'migrate-old-rc-blocks: %s: %s; left unchanged, remove the old block by hand\n' "$1" "$2" >&2
}

# scan <file> [<keep last newline-less line: 0|1>]: prints <file> without
# its blocks. Exits 0 if it has none, 10 if it has blocks, all closed, 11 if
# one is unterminated. Markers match only as whole lines, with or without a
# trailing CR; a block ends only at the end line with the same name. Kept
# lines are printed as they were, CR included.
scan() {
    awk -v nonl="${2:-0}" '
        function flush(nl) {
            if (held_nr) printf "%s%s", held, nl
            held_nr = 0
        }
        { l = $0; sub(/\r$/, "", l) }
        !open && (l == "# >>> ai-workspace >>>" ||
                  l ~ /^# >>> (yazi|lazygit)-setup: .+ >>>$/) {
            end = "# <<< " substr(l, 7, length(l) - 10) " <<<"
            open = 1; found = 1; next
        }
        open { if (l == end) open = 0; next }
        { flush("\n"); held = $0; held_nr = NR }
        END {
            if (open) exit 11
            # A last line without a newline keeps lacking it.
            flush((nonl && held_nr == NR) ? "" : "\n")
            exit found ? 10 : 0
        }
    ' "$1"
}

# migrate <file>: returns non-zero only after warning.
migrate() {
    f=$1
    # A dangling symlink holds no blocks either.
    [ -e "$f" ] || return 0
    if [ ! -f "$f" ] || [ ! -r "$f" ]; then
        warn "$f" "cannot be read"
        return 1
    fi
    rc=0
    scan "$f" >/dev/null 2>&1 || rc=$?
    case $rc in
        0) return 0 ;;
        10) ;;
        11) warn "$f" "has an old marker block without its end line"; return 1 ;;
        *) warn "$f" "cannot be read"; return 1 ;;
    esac
    # Read through a symlink, never write: its target belongs to another
    # repo or tool.
    if [ -L "$f" ]; then
        warn "$f" "is a symlink"
        return 1
    fi
    nonl=0
    [ -z "$(tail -c 1 "$f")" ] || nonl=1
    # Temp file next to the original, so the rename is atomic; cp -p gives
    # it the original's mode before any content is written.
    tmp=$(mktemp "$f.XXXXXX" 2>/dev/null) || {
        tmp=
        warn "$f" "no temp file can be created next to it"
        return 1
    }
    rc=0
    cp -p "$f" "$tmp" 2>/dev/null || rc=1
    if [ "$rc" -eq 0 ]; then
        scan "$f" "$nonl" >"$tmp" 2>/dev/null || rc=$?
        [ "$rc" -ne 10 ] || rc=0
    fi
    if [ "$rc" -eq 0 ] && mv -f "$tmp" "$f" 2>/dev/null; then
        tmp=
        return 0
    fi
    rm -f "$tmp"
    tmp=
    warn "$f" "cannot be rewritten"
    return 1
}

tmp=
trap 'if [ -n "$tmp" ]; then rm -f "$tmp"; fi' EXIT

for name in .bashrc .zshrc; do
    migrate "$dir/$name" || :
done
exit 0
