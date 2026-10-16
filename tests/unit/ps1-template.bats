#!/usr/bin/env bats
# Static checks on the Windows identity script template (slice 2, review
# round 1, criterion 29). It can't run on Linux, so these only read it:
#   - sh.exe comes from Git's install dir (git --exec-path or the location
#     of git.exe), never a bare `sh` looked up on PATH;
#   - the pairs argument is never passed empty (a leading space, or an
#     explicit guard for empty data).

load ../helpers/common

PS1="$REPO_ROOT/home/.chezmoiscripts/run_onchange_after_git-identities.ps1.tmpl"

setup() {
    ws_isolate
    [ -f "$PS1" ] || { echo "missing $PS1" >&2; return 1; }
}

@test "ps1 template: finds sh.exe via Git's install dir" {
    grep -qE -- '--exec-path|git\.exe|Get-Command[ ]+git' "$PS1" || {
        echo "no git --exec-path or git.exe lookup in the ps1 template" >&2
        return 1
    }
    grep -qiE 'sh\.exe' "$PS1" || {
        echo "the ps1 template doesn't name sh.exe" >&2
        return 1
    }
}

@test "ps1 template: never calls bare sh from PATH" {
    run grep -nE '(^|[&;|(][ ]*)(sh|sh\.exe|bash|bash\.exe)([ ]|$)|Start-Process[ ]+(-FilePath[ ]+)?["'\'']?(sh|bash)(\.exe)?["'\'']?([ ]|$)' "$PS1"
    expect_status 1
}

# call_lines <file>: the lines that run sh via PowerShell's call operator.
call_lines() {
    grep -E '^[[:space:]]*&[[:space:]]*[$"'\'']' "$1" || true
}

# pairs_guarded <file>: every call line passes an argument that starts
# with a space before a variable (" $pairs", (' ' + $pairs), " $($x)").
pairs_guarded() {
    calls=$(call_lines "$1")
    [ -n "$calls" ] || { echo "no '& \$sh ...' call line in $1" >&2; return 1; }
    printf '%s\n' "$calls" | while IFS= read -r line; do
        printf '%s\n' "$line" | grep -qE "\" \\\$[A-Za-z_(]|\\([[:space:]]*[\"'] [\"'][[:space:]]*\\+[[:space:]]*\\\$" || {
            printf 'call line passes the pairs without a leading space: %s\n' "$line" >&2
            return 1
        }
    done
}

@test "ps1 template: the sh call passes the pairs with a leading space" {
    pairs_guarded "$PS1"
}

@test "ps1 template: the guard check fails on a copy with the pairs unquoted" {
    copy="$TEST_TMP/copy.ps1.tmpl"
    # shellcheck disable=SC2016 # a sed script, not shell expansion
    sed -E '/^[[:space:]]*&/ s/" \$([A-Za-z_]+)"/$\1/g' "$PS1" >"$copy"
    if cmp -s "$PS1" "$copy"; then
        echo "mutation changed nothing: no '\" \$var\"' argument on a call line" >&2
        return 1
    fi
    run pairs_guarded "$copy"
    expect_failure
}

@test "ps1 template: tries bin\\sh.exe before usr\\bin\\sh.exe" {
    # Offsets in the whole file of the first bin\sh.exe not under usr\ and
    # of the first usr\bin\sh.exe ('/' or '\', quotes or Join-Path parts).
    offsets=$(tr '\n' ' ' <"$PS1" | awk '{
        s = $0; usr = 0; bin = 0
        if (match(s, /usr[\\\/'\'' ,"]+bin[\\\/'\'' ,"]+sh\.exe/)) usr = RSTART
        rest = s; off = 0
        while (match(rest, /bin[\\\/'\'' ,"]+sh\.exe/)) {
            pos = off + RSTART
            pre = substr(s, 1, pos - 1)
            if (pre !~ /usr[\\\/'\'' ,"]+$/) { bin = pos; break }
            off = pos + RLENGTH - 1
            rest = substr(s, off + 1)
        }
        print bin, usr
    }')
    bin=${offsets% *}
    usr=${offsets#* }
    [ "$bin" -gt 0 ] || { printf '%s\n' 'no bin\sh.exe in the ps1 template' >&2; return 1; }
    [ "$usr" -gt 0 ] || { printf '%s\n' 'no usr\bin\sh.exe fallback in the ps1 template' >&2; return 1; }
    [ "$bin" -lt "$usr" ] || { printf '%s\n' 'usr\bin\sh.exe comes before bin\sh.exe' >&2; return 1; }
}
