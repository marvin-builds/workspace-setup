# shellcheck shell=bash
# Programmable completion, when bash-completion is installed. Ubuntu's
# /etc/bash.bashrc leaves this commented out, so skel enables it here.
if ! shopt -oq posix; then
    if [ -r /usr/share/bash-completion/bash_completion ]; then
        # shellcheck source=/dev/null
        . /usr/share/bash-completion/bash_completion
    elif [ -r /etc/bash_completion ]; then
        # shellcheck source=/dev/null
        . /etc/bash_completion
    fi
fi
