# Sourced by scripts/privacy-check.sh: runs Betterleaks on exported objects
# and metadata and reports findings. Uses $work, $SCANNER, $LEAKS_EXIT, die,
# say and the git helpers from the caller.
#
# Betterleaks never reads the repo: it scans blobs exported by object id and
# metadata text, so attributes, diff config and replace refs can't hide
# anything. Findings name rule, blob, commit (or index) and line. Matched
# text is redacted, and neither paths nor metadata text are printed: a path
# can contain a denylisted name, and CI logs are public.

# The first line of a re-exported binary blob and of the metadata files.
# Betterleaks skips files whose first bytes look binary (executables, gzip,
# images); with this line in front it scans their bytes as text.
TEXT_HEADER='privacy-check text view'

prepare_scanner() {
    printf '%s\n' \
        '{{range .}}{{.RuleID}}	{{.StartLine}}	{{.File}}' \
        '{{end}}' >"$work/report.tmpl"
    mkdir -p "$work/no-ignore"
}

# run_scanner <config> <betterleaks command and args...>
# Returns 0 when clean, 1 on findings (in $work/report), 2 on a scanner
# error; the debug log is in $work/scan.log. Inline allow comments are
# ignored, and -i points to an empty dir so no ignore file is read.
run_scanner() {
    config=$1
    shift
    rm -f "$work/report"
    "$SCANNER" "$@" --config "$config" --redact --no-banner --no-color \
        --log-level debug --ignore-gitleaks-allow \
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

# Appends "<blob id> <rule> <line>" per finding in $work/report to
# $work/hits. Reported files are <dir>/<blob id>, or <dir>/<blob id>.zip!...
# for a hit inside an archive. <offset> is subtracted from the line.
collect_blob_hits() {
    awk -F '\t' -v dir="$1/" -v offset="$2" '
        NF {
            f = substr($3, length(dir) + 1)
            if (substr($3, 1, length(dir)) != dir || !match(f, /^[0-9a-f]+/)) next
            print substr(f, 1, RLENGTH), $1, $2 - offset
        }
    ' "$work/report" >>"$work/hits"
}

# scan_blob_dir <label> <dir> <offset>: scans <dir> with both configs.
scan_blob_dir() {
    for config in defaults denylist; do
        run_scanner "$work/$config.toml" dir "$2"
        case $? in
            1) collect_blob_hits "$2" "$3" ;;
            2) scanner_failed "$1"; errors=1 ;;
        esac
    done
}

# scan_blobs <label> <history|staged>: scans $work/blobs. Blobs Betterleaks
# skipped as binary are re-exported with the text header and scanned again,
# so binary content and files with NUL bytes are covered. Compressed
# archives other than zip are not unpacked.
scan_blobs() {
    label=$1
    : >"$work/hits"
    errors=0
    scan_blob_dir "$label" "$work/blobs" 0
    sed -n 's|.*skipping binary file .*/\([0-9a-f]\{40,64\}\)$|\1|p' \
        "$work/scan.log" | sort -u >"$work/binary-ids"
    if [ -s "$work/binary-ids" ]; then
        mkdir -p "$work/text"
        while read -r oid; do
            { printf '%s\n' "$TEXT_HEADER"; cat "$work/blobs/$oid"; } \
                >"$work/text/$oid"
        done <"$work/binary-ids"
        scan_blob_dir "$label" "$work/text" 1
    fi
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
    print_findings "$label" || return 1
    return $errors
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
