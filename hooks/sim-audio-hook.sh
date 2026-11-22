#!/bin/sh
# PostToolUse (Bash): the first time a Claude session starts or drives an iOS simulator, tells
# it that simulator audio is muted by the sim-audio guard and how to test sound. Every other
# command pays for one `case` and nothing more; sim-audio-hook.py, next to this file, makes the
# real check.
input=$(cat)
case "$input" in
  *simctl*|*xcodebuild*)
    printf '%s' "$input" | /usr/bin/python3 "$(dirname "$0")/sim-audio-hook.py" 2>/dev/null ;;
esac
exit 0
