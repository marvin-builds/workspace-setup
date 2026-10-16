# shellcheck shell=sh
# Variables set by the caller:
# shellcheck disable=SC2154
# Sourced by scripts/privacy-check.sh: runs Betterleaks on exported objects
# and metadata and reports findings. Uses $work, $SCANNER, $LEAKS_EXIT, die,
# say and the git helpers from the caller.
#
# Betterleaks never reads the repo: it scans blobs exported by object id and
# metadata text, so attributes, diff config and replace refs can't hide
# anything. Findings name rule, blob, commit (or index) and line. Matched
# text is redacted, and neither paths nor metadata text are printed: a path
# can contain a denylisted name, and CI logs are public.

# The first line of every exported blob and of the metadata files.
# Betterleaks skips files whose first bytes look binary (executables, gzip,
# PDF, images); with this line in front it scans every byte as text, so
# binary content and NUL bytes are covered. Hit lines are one less.
TEXT_HEADER='privacy-check text view'

prepare_scanner() {
    printf '%s\n' \
        '{{range .}}{{.RuleID}}	{{.StartLine}}	{{.File}}' \
        '{{end}}' >"$work/report.tmpl"
    mkdir -p "$work/no-ignore"
}

# run_scanner <config> <betterleaks command and args...>
# Returns 0 when clean, 1 on findings (in $work/report), 2 on a scanner
# error; the log is in $work/scan.log. Inline allow comments are
# ignored, and -i points to an empty dir so no ignore file is read.
run_scanner() {
    config=$1
    shift
    rm -f "$work/report"
    "$SCANNER" "$@" --config "$config" --redact --no-banner --no-color \
        --ignore-gitleaks-allow \
        --gitleaks-ignore-path "$work/no-ignore" \
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

# scan_blobs <label> <history|staged>: scans $work/blobs (written by
# export_blobs with the text header) with both configs. The scanner runs
# inside that dir, so each reported file name is just the blob id.
scan_blobs() {
    label=$1
    : >"$work/hits"
    errors=0
    for config in defaults denylist; do
        (cd "$work/blobs" && run_scanner "$work/$config.toml" dir .)
        case $? in
            1)
                awk -F '\t' 'NF { print $3, $1, $2 - 1 }' "$work/report" \
                    >>"$work/hits"
                ;;
            2)
                scanner_failed "$label"
                errors=1
                ;;
        esac
    done
    sort -u "$work/hits" | while read -r oid rule line; do
        if [ "$2" = staged ]; then
            where=index
        else
            commit=$(introduced_by "$oid")
            where="commit ${commit:-unknown}"
        fi
        printf 'privacy-check:   %s  blob %s  %s  line %s\n' \
            "$rule" "$(g_short "$oid")" "$where" "$line"
    done >"$work/findings"
    report_scan "$label" "$errors"
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

# report_scan <label> <errors>: prints the findings; after a scanner error
# the result is incomplete, so it fails and never says "no leaks found".
report_scan() {
    if [ "$2" -eq 0 ]; then
        print_findings "$1"
        return
    fi
    if [ -s "$work/findings" ]; then
        say "$1: leaks found (matched text redacted):"
        cat "$work/findings"
    fi
    say "$1: scan incomplete because of the scanner error above"
    return 1
}

# scan_metadata <label>: scans $work/meta.txt with the denylist rules (same
# RE2 dialect as file contents). $work/meta.idx names the object of each
# line ("commit abc1234", "tag abc1234" or "index"); findings print that.
scan_metadata() {
    label=$1
    : >"$work/findings"
    run_scanner "$work/denylist.toml" stdin <"$work/meta.txt"
    case $? in
        0) ;;
        1)
            awk -F '\t' '
                NR == FNR { what[NR] = $0; next }
                NF { printf "privacy-check:   %s  %s (message, name or path)\n", $1, what[$2] }
            ' "$work/meta.idx" "$work/report" | sort -u >"$work/findings"
            ;;
        *)
            scanner_failed "$label"
            return 1
            ;;
    esac
    print_findings "$label"
}

# scan_text <label>: scans stdin (PR title and body, branch names) with both
# configs. The text goes to a file behind the text header first, so binary
# looking input is scanned as text and both scans read the same bytes.
# Findings name rule and line of the input, never the text.
scan_text() {
    label=$1
    {
        printf '%s\n' "$TEXT_HEADER"
        cat
    } >"$work/text.txt" || die "cannot read the text from stdin"
    : >"$work/hits"
    errors=0
    for config in defaults denylist; do
        run_scanner "$work/$config.toml" stdin <"$work/text.txt"
        case $? in
            1) awk -F '\t' 'NF { print $1, $2 - 1 }' "$work/report" >>"$work/hits" ;;
            2)
                scanner_failed "$label"
                errors=1
                ;;
        esac
    done
    sort -u "$work/hits" | while read -r rule line; do
        printf 'privacy-check:   %s  line %s\n' "$rule" "$line"
    done >"$work/findings"
    report_scan "$label" "$errors"
}
