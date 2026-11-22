#!/bin/sh
# PreToolUse (Bash): asks before a Claude session makes a simulator audible (simaudio hear,
# simaudio mode off|claude) or stops the sim-audio guard. Every other command pays for one
# `case` and nothing more; sim-audio-guard.py, next to this file, makes the real check.
input=$(cat)
case "$input" in
  *simaudio*|*sim-audio*|*"Sim Audio"*)
    printf '%s' "$input" | /usr/bin/python3 "$(dirname "$0")/sim-audio-guard.py" 2>/dev/null ;;
esac
exit 0
