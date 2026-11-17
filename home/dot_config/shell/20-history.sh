# shellcheck shell=bash
# From Ubuntu's skel: skip duplicates and lines starting with a space, and
# append instead of overwriting, so parallel shells don't lose history.
HISTCONTROL=ignoreboth
shopt -s histappend
# Larger than skel's 1000/2000: a long history is cheap and searchable.
HISTSIZE=10000
HISTFILESIZE=20000
