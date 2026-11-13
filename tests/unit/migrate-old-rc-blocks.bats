#!/usr/bin/env bats
# shellcheck disable=SC2016,SC2012,SC2030,SC2031 # fixture text is literal; ls for inode and mode; bats run sets output per test
# Unit tests for the migration of the old rc marker blocks (slice 4,
# criteria 9, 10, 11, 15), run directly without chezmoi.
#
# Interface (the implementation follows this):
#
#   home/.chezmoiscripts/run_once_after_migrate-20261113-old-rc-blocks.sh
#
#   A plain file (no .tmpl), POSIX sh with the shebang #!/bin/sh, run with
#   no arguments. chezmoi names its target .chezmoiscripts/
#   migrate-20261113-old-rc-blocks.sh; .chezmoiignore excludes that name on
#   Windows (checked in tests/render/shell.bats).
#
#   Directory: $CHEZMOI_DEST_DIR when set and non-empty (chezmoi exports
#   it to scripts, as the git-identities script uses it), else $HOME. The
#   script only ever touches <dir>/.bashrc and <dir>/.zshrc.
#
#   In each of those files it removes every block from its begin line
#   through its end line, where the lines are exactly (whole line):
#     # >>> ai-workspace >>>          ...  # <<< ai-workspace <<<
#     # >>> yazi-setup: <name> >>>    ...  # <<< yazi-setup: <name> <<<
#     # >>> lazygit-setup: <name> >>> ...  # <<< lazygit-setup: <name> <<<
#   (<name> is any text, e.g. "y function" or "lg"; the end line repeats
#   it). Everything outside the blocks stays byte for byte, including a
#   last line without a newline, and the file keeps its mode. Markers match
#   with or without a trailing CR: in a CRLF file the blocks go and every
#   other line keeps its CRLF (decision 25).
#
#   A file is rewritten through a temp file in its own directory and a
#   rename, never truncated in place (a hard link to the old file keeps the
#   old content). A file without blocks is not rewritten at all. A missing
#   file is skipped silently. No temp file is left behind.
#
#   A begin line without its end line: that file is left unchanged, a
#   warning naming the file (its name or path, never its content) goes to
#   stderr, the other file is still migrated, and the script exits 0.
#   The same holds (decisions 23, 24) for an rc file that is
#   - a symlink: never replaced or rewritten; the link and its target stay
#     as they are;
#   - unreadable, or in a directory where the temp file can't be created
#     or renamed.
#
# Fixtures are fake, path-free rc files; tests/system/fixtures/old-rc and
# old-rc.migrated are the seed and expected result the system test uses.

bats_require_minimum_version 1.5.0

load ../helpers/common

SCRIPT="$REPO_ROOT/home/.chezmoiscripts/run_once_after_migrate-20261113-old-rc-blocks.sh"
FIXTURES="$REPO_ROOT/tests/system/fixtures"

setup() {
    ws_isolate
    unset CHEZMOI_DEST_DIR
    [ -f "$SCRIPT" ] || {
        echo "missing home/.chezmoiscripts/run_once_after_migrate-20261113-old-rc-blocks.sh" >&2
        return 1
    }
}

# migrate: runs the script with sh, separating stderr.
migrate() {
    run --separate-stderr sh "$SCRIPT"
}

# rc_with_blocks <file>: an rc file with all three block kinds, text
# around them that must survive (trailing blanks, backslashes, percent
# signs, a marker-like text inside a line) and a second yazi block name.
rc_with_blocks() {
    printf '%s\n' \
        '# fake rc for tests' \
        'export WS_FAKE_BEFORE=1  ' \
        '' \
        '# >>> ai-workspace >>>' \
        'ws() { echo "fake ws $*"; }' \
        'notes() { cd "$HOME/fake-notes" || return; }' \
        '# <<< ai-workspace <<<' \
        "printf '%s\\n' 'between \\t 100%'" \
        '# >>> yazi-setup: y function >>>' \
        'y() { echo fake-yazi; }' \
        '# <<< yazi-setup: y function <<<' \
        '# >>> lazygit-setup: lg >>>' \
        "alias lg='echo fake-lazygit'" \
        '# <<< lazygit-setup: lg <<<' \
        '	indented with a tab' \
        'echo "a line with # >>> ai-workspace >>> inside stays"' \
        '# >>> yazi-setup: other helper >>>' \
        'yy() { echo fake-yazi-2; }' \
        '# <<< yazi-setup: other helper <<<' \
        'echo after' >"$1"
}

# rc_without_blocks <file>: what rc_with_blocks must become.
rc_without_blocks() {
    printf '%s\n' \
        '# fake rc for tests' \
        'export WS_FAKE_BEFORE=1  ' \
        '' \
        "printf '%s\\n' 'between \\t 100%'" \
        '	indented with a tab' \
        'echo "a line with # >>> ai-workspace >>> inside stays"' \
        'echo after' >"$1"
}

# expect_same_file <label> <expected file> <actual file>
expect_same_file() {
    cmp -s "$2" "$3" && return 0
    printf '%s differs from the expected content:\n' "$1" >&2
    diff "$2" "$3" >&2 || true
    return 1
}

# inode <file>
inode() {
    ls -di "$1" | awk '{ print $1 }'
}

# mode_of <file>: the permission string, e.g. -rw-r-----.
mode_of() {
    ls -ln "$1" | awk '{ print $1 }'
}

# home_listing: every path under $HOME with its checksum, sorted.
home_listing() {
    (cd "$HOME" && find . | LC_ALL=C sort | while IFS= read -r f; do
        if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f")"; else printf '%s\n' "$f"; fi
    done)
}

# -------------------------------------------------------------- shape

@test "migration: is a POSIX sh script that parses and passes shellcheck" {
    expect_equal "shebang" '#!/bin/sh' "$(head -n 1 "$SCRIPT")"
    run sh -n "$SCRIPT"
    expect_status 0
    require_tool shellcheck
    run "$(tool_path shellcheck)" "$SCRIPT"
    expect_status 0
}

# ------------------------------------------------- removal (criterion 9)

@test "migration: removes all three block kinds from .bashrc and .zshrc, keeps the rest byte for byte" {
    rc_with_blocks "$HOME/.bashrc"
    rc_with_blocks "$HOME/.zshrc"
    rc_without_blocks "$TEST_TMP/want"
    migrate
    expect_status 0
    expect_same_file .bashrc "$TEST_TMP/want" "$HOME/.bashrc"
    expect_same_file .zshrc "$TEST_TMP/want" "$HOME/.zshrc"
}

@test "migration: the system test fixture migrates to old-rc.migrated" {
    cp "$FIXTURES/old-rc" "$HOME/.zshrc"
    cp "$FIXTURES/old-rc" "$HOME/.bashrc"
    migrate
    expect_status 0
    expect_same_file .zshrc "$FIXTURES/old-rc.migrated" "$HOME/.zshrc"
    expect_same_file .bashrc "$FIXTURES/old-rc.migrated" "$HOME/.bashrc"
}

@test "migration: a last line without a newline is kept as it is" {
    printf '%s\n' 'echo first' '# >>> ai-workspace >>>' 'ws() { :; }' '# <<< ai-workspace <<<' >"$HOME/.zshrc"
    printf 'echo last' >>"$HOME/.zshrc"
    printf '%s\n' 'echo first' >"$TEST_TMP/want"
    printf 'echo last' >>"$TEST_TMP/want"
    migrate
    expect_status 0
    expect_same_file .zshrc "$TEST_TMP/want" "$HOME/.zshrc"
}

@test "migration: a file that is only a block becomes empty" {
    printf '%s\n' '# >>> lazygit-setup: lg >>>' "alias lg='echo fake'" '# <<< lazygit-setup: lg <<<' >"$HOME/.zshrc"
    migrate
    expect_status 0
    [ -f "$HOME/.zshrc" ] && [ ! -s "$HOME/.zshrc" ] || {
        printf '.zshrc should exist and be empty; it holds:\n%s\n' "$(cat "$HOME/.zshrc" 2>/dev/null)" >&2
        return 1
    }
}

@test "migration: keeps each file's mode" {
    rc_with_blocks "$HOME/.bashrc"
    rc_with_blocks "$HOME/.zshrc"
    chmod 640 "$HOME/.bashrc"
    chmod 600 "$HOME/.zshrc"
    migrate
    expect_status 0
    expect_equal ".bashrc mode" "-rw-r-----" "$(mode_of "$HOME/.bashrc")"
    expect_equal ".zshrc mode" "-rw-------" "$(mode_of "$HOME/.zshrc")"
}

# --------------------------------------------- write path (criterion 11)

@test "migration: replaces the file by rename, never truncates it in place" {
    rc_with_blocks "$HOME/.zshrc"
    ln "$HOME/.zshrc" "$TEST_TMP/old-zshrc-link"
    cp "$HOME/.zshrc" "$TEST_TMP/original"
    before=$(inode "$HOME/.zshrc")
    migrate
    expect_status 0
    expect_same_file "hard link to the old .zshrc" "$TEST_TMP/original" "$TEST_TMP/old-zshrc-link"
    [ "$(inode "$HOME/.zshrc")" != "$before" ] || {
        echo ".zshrc kept its inode: rewritten in place instead of renamed" >&2
        return 1
    }
}

@test "migration: leaves no temp file and touches no other file in \$HOME" {
    rc_with_blocks "$HOME/.bashrc"
    rc_with_blocks "$HOME/.zshrc"
    # Other files, some with markers, must stay as they are.
    rc_with_blocks "$HOME/.bash_aliases"
    rc_with_blocks "$HOME/.profile"
    mkdir -p "$HOME/.config/shell/local"
    rc_with_blocks "$HOME/.config/shell/local/50-old.sh"
    printf 'unrelated\n' >"$HOME/notes.txt"
    rc_without_blocks "$TEST_TMP/want"
    cp "$HOME/.bashrc" "$TEST_TMP/want-other"
    before=$(home_listing | grep -vE '^\./\.(bash|zsh)rc ')
    touch "$TEST_TMP/start"
    sleep 1
    migrate
    expect_status 0
    expect_equal "everything but .bashrc and .zshrc" "$before" "$(home_listing | grep -vE '^\./\.(bash|zsh)rc ')"
    changed=$(find "$HOME" -newer "$TEST_TMP/start" ! -name .bashrc ! -name .zshrc ! -path "$HOME")
    expect_equal "other paths changed under \$HOME" "" "$changed"
    expect_same_file .bashrc "$TEST_TMP/want" "$HOME/.bashrc"
    expect_same_file .bash_aliases "$TEST_TMP/want-other" "$HOME/.bash_aliases"
}

@test "migration: a second run changes nothing" {
    rc_with_blocks "$HOME/.bashrc"
    rc_with_blocks "$HOME/.zshrc"
    migrate
    expect_status 0
    first_out=$output
    first_err=$stderr
    before=$(home_listing)
    i_bash=$(inode "$HOME/.bashrc")
    i_zsh=$(inode "$HOME/.zshrc")
    touch "$TEST_TMP/start"
    sleep 1
    migrate
    expect_status 0
    expect_equal "files after the second run" "$before" "$(home_listing)"
    expect_equal ".bashrc inode" "$i_bash" "$(inode "$HOME/.bashrc")"
    expect_equal ".zshrc inode" "$i_zsh" "$(inode "$HOME/.zshrc")"
    changed=$(find "$HOME" -newer "$TEST_TMP/start" ! -path "$HOME")
    expect_equal "paths rewritten by the second run" "" "$changed"
    expect_equal "stdout of the second run" "$first_out" "$output"
    expect_equal "stderr of the second run" "$first_err" "$stderr"
}

@test "migration: a file without blocks is not rewritten" {
    rc_without_blocks "$HOME/.zshrc"
    cp "$HOME/.zshrc" "$TEST_TMP/want"
    i=$(inode "$HOME/.zshrc")
    touch "$TEST_TMP/start"
    sleep 1
    migrate
    expect_status 0
    expect_same_file .zshrc "$TEST_TMP/want" "$HOME/.zshrc"
    expect_equal ".zshrc inode" "$i" "$(inode "$HOME/.zshrc")"
    changed=$(find "$HOME" -newer "$TEST_TMP/start" ! -path "$HOME")
    expect_equal "paths rewritten" "" "$changed"
    expect_equal "stderr" "" "$stderr"
}

# ----------------------------------------- missing files (criterion 9)

@test "migration: no .bashrc and no .zshrc: exits 0, creates nothing, prints nothing" {
    migrate
    expect_status 0
    expect_equal "stderr" "" "$stderr"
    expect_equal "files in \$HOME" "" "$(ls -A "$HOME")"
}

@test "migration: only a .zshrc: it is migrated and no .bashrc appears" {
    rc_with_blocks "$HOME/.zshrc"
    rc_without_blocks "$TEST_TMP/want"
    migrate
    expect_status 0
    expect_same_file .zshrc "$TEST_TMP/want" "$HOME/.zshrc"
    [ ! -e "$HOME/.bashrc" ] || { echo ".bashrc was created" >&2; return 1; }
    expect_equal "stderr" "" "$stderr"
}

# ------------------------------------------ malformed (criterion 10)

# t_malformed <begin line>: a file whose block of that kind has no end.
t_malformed() {
    {
        printf '%s\n' '# fake rc' '# >>> lazygit-setup: lg >>>' "alias lg='echo fake'" '# <<< lazygit-setup: lg <<<'
        printf '%s\n' "$1" 'WS_FAKE_BLOCK_CONTENT=do-not-print' 'echo after'
    } >"$HOME/.zshrc"
    cp "$HOME/.zshrc" "$TEST_TMP/original"
    i=$(inode "$HOME/.zshrc")
    rc_with_blocks "$HOME/.bashrc"
    rc_without_blocks "$TEST_TMP/want"
    migrate
    expect_status 0
    expect_same_file ".zshrc with an unterminated block" "$TEST_TMP/original" "$HOME/.zshrc"
    expect_equal ".zshrc inode" "$i" "$(inode "$HOME/.zshrc")"
    printf '%s\n' "$stderr" | grep -qF '.zshrc' || {
        printf 'no warning naming .zshrc on stderr; stderr:\n%s\n' "$stderr" >&2
        return 1
    }
    for leak in WS_FAKE_BLOCK_CONTENT do-not-print 'echo after' 'fake rc'; do
        printf '%s\n%s\n' "$output" "$stderr" | grep -qF -- "$leak" && {
            printf 'output shows file content (%s):\n%s\n%s\n' "$leak" "$output" "$stderr" >&2
            return 1
        }
    done
    # The other file is still migrated.
    expect_same_file .bashrc "$TEST_TMP/want" "$HOME/.bashrc"
    # No temp file left next to it.
    expect_equal "files in \$HOME" ".bashrc .zshrc " "$(ls -A "$HOME" | LC_ALL=C sort | tr '\n' ' ')"
}

@test "migration: ai-workspace begin without end leaves the file, warns, exits 0" {
    t_malformed '# >>> ai-workspace >>>'
}

@test "migration: yazi-setup begin without end leaves the file, warns, exits 0" {
    t_malformed '# >>> yazi-setup: y function >>>'
}

@test "migration: lazygit-setup begin without end leaves the file, warns, exits 0" {
    t_malformed '# >>> lazygit-setup: other >>>'
}

# ------------------------------------------------------ destination dir

@test "migration: uses CHEZMOI_DEST_DIR when set and leaves \$HOME alone" {
    dest="$TEST_TMP/dest"
    mkdir -p "$dest"
    rc_with_blocks "$dest/.zshrc"
    rc_with_blocks "$HOME/.zshrc"
    cp "$HOME/.zshrc" "$TEST_TMP/home-original"
    rc_without_blocks "$TEST_TMP/want"
    CHEZMOI_DEST_DIR=$dest run --separate-stderr sh "$SCRIPT"
    expect_status 0
    expect_same_file "dest .zshrc" "$TEST_TMP/want" "$dest/.zshrc"
    expect_same_file "\$HOME/.zshrc" "$TEST_TMP/home-original" "$HOME/.zshrc"
}

# ------------------------------------- review round 1 (decisions 23-25)

# expect_warned <name>: stderr names <name> and shows no file content.
expect_warned() {
    printf '%s\n' "$stderr" | grep -qF -- "$1" || {
        printf 'no warning naming %s on stderr; stderr:\n%s\n' "$1" "$stderr" >&2
        return 1
    }
    for leak in fake-yazi fake-lazygit 'fake ws' WS_FAKE_BEFORE 'echo after'; do
        printf '%s\n%s\n' "$output" "$stderr" | grep -qF -- "$leak" && {
            printf 'output shows file content (%s):\n%s\n%s\n' "$leak" "$output" "$stderr" >&2
            return 1
        }
    done
    return 0
}

# t_symlink <rc name> <other rc name>
t_symlink() {
    target_dir="$TEST_TMP/other-repo"
    mkdir -p "$target_dir"
    rc_with_blocks "$target_dir/rc"
    cp "$target_dir/rc" "$TEST_TMP/target-original"
    ln -s "$target_dir/rc" "$HOME/$1"
    rc_with_blocks "$HOME/$2"
    rc_without_blocks "$TEST_TMP/want"
    migrate
    expect_status 0
    [ -L "$HOME/$1" ] || { echo "$1 is no longer a symlink" >&2; return 1; }
    expect_equal "$1 link target" "$target_dir/rc" "$(readlink "$HOME/$1")"
    expect_same_file "symlink target" "$TEST_TMP/target-original" "$target_dir/rc"
    expect_equal "files next to the target" "rc" "$(ls -A "$target_dir")"
    expect_warned "$1"
    expect_same_file "$2" "$TEST_TMP/want" "$HOME/$2"
}

@test "migration: a symlinked .zshrc stays a link, its target unchanged, warns, exits 0" {
    t_symlink .zshrc .bashrc
}

@test "migration: a symlinked .bashrc stays a link, its target unchanged, warns, exits 0" {
    t_symlink .bashrc .zshrc
}

@test "migration: an unreadable .zshrc is left unchanged, warns, exits 0" {
    [ "$(id -u)" -ne 0 ] || skip "root reads files without read permission"
    rc_with_blocks "$HOME/.zshrc"
    cp "$HOME/.zshrc" "$TEST_TMP/original"
    chmod 000 "$HOME/.zshrc"
    rc_with_blocks "$HOME/.bashrc"
    rc_without_blocks "$TEST_TMP/want"
    migrate
    chmod 600 "$HOME/.zshrc"
    expect_status 0
    expect_same_file ".zshrc" "$TEST_TMP/original" "$HOME/.zshrc"
    expect_warned .zshrc
    expect_same_file .bashrc "$TEST_TMP/want" "$HOME/.bashrc"
    expect_equal "files in \$HOME" ".bashrc .zshrc " "$(ls -A "$HOME" | LC_ALL=C sort | tr '\n' ' ')"
}

@test "migration: rc files in a directory that can't take a temp file are left unchanged, warn, exit 0" {
    [ "$(id -u)" -ne 0 ] || skip "root writes to read-only directories"
    # Both rc files share the directory, so neither can be migrated.
    rc_with_blocks "$HOME/.zshrc"
    rc_with_blocks "$HOME/.bashrc"
    cp "$HOME/.zshrc" "$TEST_TMP/original"
    chmod 555 "$HOME"
    migrate
    chmod 755 "$HOME"
    expect_status 0
    expect_same_file ".zshrc" "$TEST_TMP/original" "$HOME/.zshrc"
    expect_same_file ".bashrc" "$TEST_TMP/original" "$HOME/.bashrc"
    expect_warned .zshrc
    expect_warned .bashrc
    expect_equal "files in \$HOME" ".bashrc .zshrc " "$(ls -A "$HOME" | LC_ALL=C sort | tr '\n' ' ')"
}

@test "migration: in a CRLF file the blocks go and every other line keeps its CRLF" {
    rc_with_blocks "$TEST_TMP/lf"
    rc_without_blocks "$TEST_TMP/want-lf"
    sed 's/$/\r/' "$TEST_TMP/lf" >"$HOME/.zshrc"
    sed 's/$/\r/' "$TEST_TMP/want-lf" >"$TEST_TMP/want"
    migrate
    expect_status 0
    expect_same_file ".zshrc (CRLF)" "$TEST_TMP/want" "$HOME/.zshrc"
}

# ------------------------------------------ review round 2 (decision 23)

@test "migration: symlinked rc files without old blocks: silent, unchanged, exit 0" {
    target_dir="$TEST_TMP/other-repo"
    mkdir -p "$target_dir"
    rc_without_blocks "$target_dir/zshrc"
    rc_without_blocks "$target_dir/bashrc"
    cp "$target_dir/zshrc" "$TEST_TMP/original"
    ln -s "$target_dir/zshrc" "$HOME/.zshrc"
    ln -s "$target_dir/bashrc" "$HOME/.bashrc"
    migrate
    expect_status 0
    expect_equal "stderr" "" "$stderr"
    for f in zshrc bashrc; do
        [ -L "$HOME/.$f" ] || { echo ".$f is no longer a symlink" >&2; return 1; }
        expect_equal ".$f link target" "$target_dir/$f" "$(readlink "$HOME/.$f")"
        expect_same_file "$f target" "$TEST_TMP/original" "$target_dir/$f"
    done
    expect_equal "files next to the targets" "bashrc zshrc " "$(ls -A "$target_dir" | LC_ALL=C sort | tr '\n' ' ')"
}
