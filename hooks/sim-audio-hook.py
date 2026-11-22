"""Tells a Claude session, once, that simulator audio is muted and how to test sound.

Run by sim-audio-hook.sh on PostToolUse for Bash. Fires when the command boots, launches,
installs on or otherwise drives a simulator (simctl boot/launch/install/openurl/push/spawn,
or xcodebuild with a simulator destination), and only the first time in each session.
"""

import json
import os
import re
import sys
import time

DRIVES_SIM = re.compile(
    r"simctl\s+(boot|launch|install|openurl|push|spawn)\b|xcodebuild\b.*\b[Ss]imulator\b",
    re.S,
)
BASE = os.environ.get("SIM_AUDIO_HOME") or os.path.expanduser("~/.claude/sim-audio")
SEEN = os.path.join(BASE, "hook-seen")


def guard_running():
    try:
        with open(os.path.join(BASE, "status.json")) as f:
            status = json.load(f)
        os.kill(int(status["pid"]), 0)
        return time.time() - float(status["updated"]) < 20
    except Exception:
        return False


def main():
    event = json.load(sys.stdin)
    command = (event.get("tool_input") or {}).get("command", "")
    if not DRIVES_SIM.search(command):
        return
    session = re.sub(r"[^A-Za-z0-9_-]", "", event.get("session_id") or "") or "unknown"
    os.makedirs(SEEN, exist_ok=True)
    marker = os.path.join(SEEN, session)
    if os.path.exists(marker):
        return
    open(marker, "w").close()

    # Forget sessions older than a week.
    cutoff = time.time() - 7 * 24 * 3600
    for name in os.listdir(SEEN):
        path = os.path.join(SEEN, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass

    note = (
        "Simulator audio on this Mac is muted by the sim-audio guard: every simulator "
        "plays into BlackHole 2ch, a silent virtual device, so its sound never reaches the "
        "user's speakers. Never reroute a simulator's audio or pick BlackHole as the Mac's "
        "output yourself. If an app dies about 3 seconds into playing sound, the guard may "
        "have quit it for playing out loud: look for an ALERT line in `simaudio log`, and "
        "`simaudio doctor` checks the whole chain. To test sound "
        "(an alarm, a notification, sound effects), record it: start "
        "`simaudio record <sim name or UDID> [seconds]` in the background, trigger the sound, "
        "then read the result (seconds audible, peak and average dBFS, when it started and "
        "stopped; add --json for a machine-readable result). `simaudio log` shows what started "
        "and stopped playing and when. Never run `simaudio hear`, `simaudio mode off` or "
        "`simaudio mode claude` unless the user asks: those play out loud."
    )
    if not guard_running():
        note += (
            " The guard is NOT running right now, so a simulator it has not routed yet is "
            "audible: run `simaudio restart` before playing anything."
        )
    print(json.dumps({"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note}}))


if __name__ == "__main__":
    main()
