# shellcheck shell=bash
# Aliases from Ubuntu's skel.

# Colour only where dircolors exists: that is where GNU ls and grep are.
if command -v dircolors >/dev/null 2>&1; then
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'

# Personal aliases kept from before this repo owned ~/.bashrc.
if [ -f "$HOME/.bash_aliases" ] && [ -r "$HOME/.bash_aliases" ]; then
    # shellcheck source=/dev/null
    . "$HOME/.bash_aliases"
fi
