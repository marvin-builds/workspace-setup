#!/bin/sh
# ws doctor: checks this machine against what workspace-setup promises
# (workspace-setup, home/dot_local/libexec/ws/ws-doctor.sh).
#
# Reads ~/.config/ws/expect.tsv, which chezmoi renders from
# tests/expect.yaml already filtered for this machine (format in
# home/dot_config/ws/expect.tsv.tmpl), and adds checks of its own:
#   drift      `chezmoi status` is empty (WARN otherwise)
#   gitconfig  ~/.gitconfig sets no user.name or user.email, which would
#              override the managed identities (FAIL; never prints values)
#   hooks      each clone directly under repos_dir that has .githooks/
#              uses it as core.hooksPath (WARN naming the clone)
#
# Prints `ok`, `FAIL` or `WARN` and the check's id per line, then a
# summary. Exits 0 when nothing failed, 1 otherwise. Only reads: chezmoi
# is asked for status and data, never to change anything.
#
# The output is meant to be pasteable: it never prints git config values
# or the paths of checked files and drifted entries (identity files are
# named after GitHub accounts); the id says which check it is.
#
# Usage: ws doctor

set -u

TSV="$HOME/.config/ws/expect.tsv"
TAB=$(printf '\t')
n_ok=0
n_fail=0
n_warn=0

# report <ok|FAIL|WARN> <id> [detail]
report() {
    case $1 in
        ok) n_ok=$((n_ok + 1)) ;;
        FAIL) n_fail=$((n_fail + 1)) ;;
        WARN) n_warn=$((n_warn + 1)) ;;
    esac
    if [ -n "${3:-}" ]; then
        printf '%-4s %s  %s\n' "$1" "$2" "$3"
    else
        printf '%-4s %s\n' "$1" "$2"
    fi
}

# expand <path>: a leading ~/ (or a lone ~) means $HOME.
expand() {
    case $1 in
        '~') printf '%s\n' "$HOME" ;;
        \~/*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# split <line>: sets nf and f1..f5 from the tab-separated line. Empty
# fields count (a plain `read` with IFS=tab would merge them); the fifth
# field holds the rest of the line.
split() {
    rest=$1
    nf=0
    f1='' f2='' f3='' f4='' f5=''
    while :; do
        nf=$((nf + 1))
        if [ $nf -lt 5 ]; then
            case $rest in
                *"$TAB"*)
                    field=${rest%%"$TAB"*}
                    rest=${rest#*"$TAB"}
                    more=1
                    ;;
                *)
                    field=$rest
                    more=
                    ;;
            esac
        else
            field=$rest
            more=
        fi
        case $nf in
            1) f1=$field ;;
            2) f2=$field ;;
            3) f3=$field ;;
            4) f4=$field ;;
            5) f5=$field ;;
        esac
        [ -n "$more" ] || break
    done
}

# ----------------------------------------------------------- the kinds

# check_command <id> <name> <source> <smoke>
check_command() {
    resolved=$(command -v -- "$2" 2>/dev/null) || {
        report FAIL "$1" "$2 is not on PATH"
        return
    }
    if [ -n "$3" ]; then
        want=$(expand "$3")
        [ "$resolved" = "$want" ] || [ "$resolved" -ef "$want" ] || {
            report FAIL "$1" "$2 resolves to $resolved, expected $want"
            return
        }
    fi
    if [ -n "$4" ]; then
        sh -c "$4" </dev/null >/dev/null 2>&1 || {
            report FAIL "$1" "smoke test failed: $4"
            return
        }
    fi
    report ok "$1"
}

# check_line <id> <file> <count> <text>
check_line() {
    case $3 in
        '' | *[!0-9]*)
            report FAIL "$1" "count '$3' is not a number"
            return
            ;;
    esac
    file=$(expand "$2")
    if [ -e "$file" ]; then
        [ -r "$file" ] || {
            report FAIL "$1" "cannot read the file"
            return
        }
        got=$(grep -cxF -- "$4" "$file" 2>/dev/null)
        [ -n "$got" ] || got=0
    else
        got=0
    fi
    if [ "$got" -eq "$3" ]; then
        report ok "$1"
    else
        report FAIL "$1" "the file has $got lines equal to the text, expected $3"
    fi
}

# check_entry <line>: one line of expect.tsv.
check_entry() {
    split "$1"
    id=${f1:-?}
    case $f2 in
        command | line) want=5 ;;
        file | absent) want=3 ;;
        *)
            report FAIL "$id" "unknown kind '$f2' in expect.tsv"
            return
            ;;
    esac
    [ "$nf" -eq "$want" ] || {
        report FAIL "$id" "$f2 needs $want fields in expect.tsv, has $nf"
        return
    }
    case $f2 in
        command) check_command "$f1" "$f3" "$f4" "$f5" ;;
        file)
            if [ -e "$(expand "$f3")" ]; then
                report ok "$f1"
            else
                report FAIL "$f1" "missing"
            fi
            ;;
        absent)
            p=$(expand "$f3")
            if [ -e "$p" ] || [ -L "$p" ]; then
                report FAIL "$f1" "exists, should not"
            else
                report ok "$f1"
            fi
            ;;
        line) check_line "$f1" "$f3" "$f4" "$f5" ;;
    esac
}

check_tsv() {
    if [ ! -f "$TSV" ] || [ ! -r "$TSV" ]; then
        report FAIL expect-tsv "cannot read ~/.config/ws/expect.tsv; run chezmoi apply"
        return
    fi
    # Read into a variable first, so checks can't consume the input.
    entries=$(cat "$TSV") || {
        report FAIL expect-tsv "cannot read ~/.config/ws/expect.tsv"
        return
    }
    [ -n "$entries" ] || {
        report FAIL expect-tsv "expect.tsv is empty: $TSV"
        return
    }
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        check_entry "$entry"
    done <<EOF
$entries
EOF
}

# ------------------------------------------------------- extra checks

check_drift() {
    command -v chezmoi >/dev/null 2>&1 || {
        report WARN drift "chezmoi not on PATH; drift not checked"
        return
    }
    st=$(chezmoi status </dev/null) || {
        report FAIL drift "chezmoi status failed"
        return
    }
    if [ -z "$st" ]; then
        report ok drift
        return
    fi
    # The count only: paths can name GitHub accounts.
    n=$(printf '%s\n' "$st" | grep -c .)
    report WARN drift "$n entries differ from the source state: see chezmoi diff, then chezmoi re-add (keep the machine's version) or chezmoi merge"
}

check_gitconfig() {
    gc="$HOME/.gitconfig"
    if [ ! -e "$gc" ]; then
        report ok gitconfig
        return
    fi
    command -v git >/dev/null 2>&1 || {
        report WARN gitconfig "git is not on PATH; ~/.gitconfig not checked"
        return
    }
    keys=
    for key in user.name user.email; do
        # Only the exit status is used: the value is never printed.
        if git config -f "$gc" --includes --get-all "$key" >/dev/null 2>&1; then
            keys="${keys:+$keys and }$key"
        fi
    done
    if [ -n "$keys" ]; then
        report FAIL gitconfig "$gc (or a file it includes) sets $keys, which overrides the managed identities in ~/.config/git; remove it there"
    else
        report ok gitconfig
    fi
}

check_hooks() {
    command -v chezmoi >/dev/null 2>&1 || {
        report WARN hooks "chezmoi not on PATH; repos_dir unknown, clones not checked"
        return
    }
    repos=$(chezmoi execute-template '{{ if hasKey . "repos_dir" }}{{ .repos_dir }}{{ end }}' </dev/null 2>/dev/null) || repos=
    if [ -z "$repos" ]; then
        report WARN hooks "repos_dir is not set in chezmoi's data; clones not checked"
        return
    fi
    repos=$(expand "$repos")
    if [ ! -d "$repos" ]; then
        report WARN hooks "repos_dir $repos does not exist; clones not checked"
        return
    fi
    hooks_warned=
    for d in "$repos"/* "$repos"/.[!.]* "$repos"/..?*; do
        [ -d "$d" ] && [ -e "$d/.git" ] && [ -d "$d/.githooks" ] || continue
        # git config -f needs no ownership check (clones of other users).
        if [ -d "$d/.git" ]; then
            hp=$(git config -f "$d/.git/config" --includes --get core.hooksPath 2>/dev/null) || hp=
        else
            hp=$(git -C "$d" config --get core.hooksPath 2>/dev/null) || hp=
        fi
        [ "$hp" != .githooks ] || continue
        report WARN hooks "clone ${d##*/}: set core.hooksPath to .githooks in it"
        hooks_warned=1
    done
    [ -n "$hooks_warned" ] || report ok hooks
}

# --------------------------------------------------------------- main

check_tsv
check_drift
check_gitconfig
check_hooks

printf '%s ok, %s FAIL, %s WARN\n' "$n_ok" "$n_fail" "$n_warn"
[ "$n_fail" -eq 0 ]
