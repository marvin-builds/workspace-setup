# shellcheck shell=bash
# starship when installed; otherwise skel's user@host:dir prompt, so a
# fresh machine still shows where it is.
if command -v starship >/dev/null 2>&1; then
    eval "$(starship init bash)"
elif [ "${TERM:-dumb}" = dumb ]; then
    PS1='\u@\h:\w\$ '
else
    PS1='\[\e[01;32m\]\u@\h\[\e[00m\]:\[\e[01;34m\]\w\[\e[00m\]\$ '
fi
