# Sourced by scripts/privacy-check.sh: runs Betterleaks and reports findings.
# Uses $work, $top, $SCANNER, $LEAKS_EXIT, die and say from the caller.
#
# Findings are printed as "rule  commit  line N" (commit is "index" for
# staged changes). Matched text is redacted and paths are never printed:
# a path can itself contain a denylisted name, and CI logs are public.

# One finding per line: rule id, short commit (or "index"), start line.
write_report_template() {
    printf '%s\n' \
        '{{range .}}{{.RuleID}}	{{if .Commit}}{{printf "%.7s" .Commit}}{{else}}index{{end}}	{{.StartLine}}' \
        '{{end}}' >"$work/report.tmpl"
    mkdir -p "$work/no-ignore"
}

# run_scanner <config> <betterleaks command and args...>
# Returns 0 when clean, 1 on findings (in $work/report), 2 on a scanner
# error. Inline allow comments are ignored; ignore files are checked
# separately (check_ignore_files), since an empty -i dir does not stop
# Betterleaks from reading the repo's own .gitleaksignore.
run_scanner() {
    config=$1
    shift
    rm -f "$work/report"
    "$SCANNER" "$@" --config "$config" --redact --no-banner --no-color \
        --ignore-gitleaks-allow --gitleaks-ignore-path "$work/no-ignore" \
        --exit-code "$LEAKS_EXIT" --report-format template \
        --report-template "$work/report.tmpl" --report-path "$work/report" \
        >"$work/scan.log" 2>&1
    case $? in
        0) return 0 ;;
        "$LEAKS_EXIT") return 1 ;;
        *) return 2 ;;
    esac
}

# The scanner log can quote denylist entries (for example on an invalid
# regex), so only the rule id is shown.
scanner_failed() {
    bad_rule=$(grep -Eo 'denylist-[0-9]+: invalid regex' "$work/scan.log" | head -n 1)
    if [ -n "$bad_rule" ]; then
        say "$1: scanner rejected the denylist: $bad_rule (denylist-<n> is line n)"
    else
        say "$1: scanner failed; its log is hidden because it can quote denylist entries"
    fi
}

# print_findings <label>: prints $work/findings under a heading, or "clean".
# Returns 1 if there were findings.
print_findings() {
    if [ -s "$work/findings" ]; then
        say "$1: leaks found (matched text redacted):"
        cat "$work/findings"
        return 1
    fi
    say "$1: no leaks found"
}

# scan_git <label> <betterleaks git flags...>: default rules and denylist
# rules in two separate scans of the same git range.
scan_git() {
    label=$1
    shift
    : >"$work/findings"
    errors=0
    for config in "$work/defaults.toml" "$work/denylist.toml"; do
        run_scanner "$config" git "$@" "$top"
        case $? in
            1)
                awk -F '\t' 'NF { printf "privacy-check:   %s  %s  line %s\n", $1, $2, $3 }' \
                    "$work/report" >>"$work/findings"
                ;;
            2)
                scanner_failed "$label"
                errors=1
                ;;
        esac
    done
    print_findings "$label" || return 1
    return $errors
}

# scan_metadata <label>: scans $work/meta.txt with the denylist rules (same
# RE2 dialect as file contents). $work/meta.idx names the object of each
# line ("commit abc1234" or "tag abc1234"); findings print that, not text.
scan_metadata() {
    label=$1
    : >"$work/findings"
    [ -s "$work/meta.txt" ] || {
        say "$label: no metadata in scope"
        return 0
    }
    run_scanner "$work/denylist.toml" stdin <"$work/meta.txt"
    case $? in
        0) ;;
        1)
            awk -F '\t' '
                NR == FNR { what[NR] = $0; next }
                NF { printf "privacy-check:   %s  %s (message, name or path)\n", $1, what[$3] }
            ' "$work/meta.idx" "$work/report" >"$work/findings"
            ;;
        *)
            scanner_failed "$label"
            return 1
            ;;
    esac
    print_findings "$label"
}
