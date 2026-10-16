# shellcheck shell=sh
# Variables set by the caller:
# shellcheck disable=SC2154
# Sourced by scripts/privacy-check.sh: reads the denylist and writes the two
# Betterleaks configs. Uses $work, die and say from the caller.

denylist_path() {
    if [ -n "${WS_DENYLIST:-}" ]; then
        printf '%s\n' "$WS_DENYLIST"
    else
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/ws/denylist"
    fi
}

# Writes two configs, so neither scan changes the other:
#   $work/defaults.toml  Betterleaks' default rules only
#   $work/denylist.toml  one rule per denylist entry, without [extend], so the
#                        default global allowlist (lock files, *.svg, vendor/,
#                        /home/<x>, ...), prefilter and filters don't apply
# Rule ids are denylist-<line number>. Entries are TOML-escaped, so quotes
# and backslashes in a regex are safe.
build_configs() {
    denylist=$(denylist_path)
    [ -f "$denylist" ] ||
        die "denylist not found at $denylist. Create it (one regex per line) or set WS_DENYLIST; see README.md."
    [ -r "$denylist" ] || die "denylist at $denylist is not readable"

    printf '[extend]\nuseDefault = true\n' >"$work/defaults.toml"

    awk -v cfg="$work/denylist.toml" '
        function toml_escape(s,    out, i, c) {
            out = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == "\\" || c == "\"") out = out "\\" c
                else if (c == "\t") out = out "\\t"
                else out = out c
            }
            return out
        }
        {
            sub(/\r$/, "")
            sub(/^[ \t]+/, "")
            sub(/[ \t]+$/, "")
            if ($0 == "" || substr($0, 1, 1) == "#") next
            if ($0 ~ /[\001-\010\013-\037\177]/) {
                printf "privacy-check: denylist line %d contains control characters\n", NR > "/dev/stderr"
                bad = 1
                next
            }
            n++
            if (n > 1) print "" > cfg
            print "[[rules]]" > cfg
            printf "id = \"denylist-%d\"\n", NR > cfg
            printf "description = \"Denylist entry on line %d\"\n", NR > cfg
            # The outer group makes the whole match the secret, so --redact
            # hides all of it, not just the entry'"'"'s first group.
            printf "regex = \"(?i)(%s)\"\n", toml_escape($0) > cfg
        }
        END {
            if (bad) exit 2
            if (n == 0) exit 3
        }
    ' "$denylist"
    case $? in
        0) ;;
        2) die "fix the denylist at $denylist" ;;
        3) die "denylist at $denylist has no entries (only comments or blanks); refusing to pass without one." ;;
        *) die "cannot read the denylist at $denylist" ;;
    esac
}
