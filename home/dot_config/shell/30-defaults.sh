# shellcheck shell=bash
# Defaults from Ubuntu's skel. External tools are optional, so a minimal
# container gets no errors.

# Keep LINES and COLUMNS right after a terminal resize.
shopt -s checkwinsize

# Lets less show archives and other non-text files.
if command -v lesspipe >/dev/null 2>&1; then
    eval "$(SHELL=/bin/sh lesspipe)"
fi

# LS_COLORS for ls --color, from ~/.dircolors when present.
if command -v dircolors >/dev/null 2>&1; then
    if [ -r "$HOME/.dircolors" ]; then
        eval "$(dircolors -b "$HOME/.dircolors")"
    else
        eval "$(dircolors -b)"
    fi
fi
