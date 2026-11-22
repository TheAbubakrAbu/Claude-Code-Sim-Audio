#!/usr/bin/env python3
"""
PreToolUse(Bash) guard: never let Claude make a simulator audible, or take the sim-audio
guard down, on its own.

Run by sim-audio-guard.sh. Reads the hook payload on stdin. If the Bash command would let a
simulator play out loud (`simaudio hear`, `simaudio mode off`, `simaudio mode claude`) or
stop or unload the guard that keeps simulators muted, emit a permissionDecision of "ask" so
the harness forces a permission prompt.

"ask" (not "deny") is deliberate, the same as git-guard.py: the standing rule is "simulators
stay silent unless I say so", and when the user HAS asked to hear one they just approve the
prompt. Flip DECISION to "deny" to make it an absolute block.

Not covered, on purpose: `simaudio restart`, `simaudio mute`, `simaudio mode all`,
`simaudio record`, `simaudio doctor` and anything that only reads. Those keep things quiet.
"""
import json
import re
import sys

DECISION = "ask"

# The CLI under either of its names: the `simaudio` link or the binary inside the app.
CLI = r"(?:\bsimaudio|claude-sim-audio[\"']?)"

PATTERNS = [
    # simaudio hear <sim> / unmute <sim>: one simulator out loud
    re.compile(CLI + r"\s+(?:hear|unmute)\b", re.I),
    # simaudio mode off / mode claude: muting off, or back to the looser rule
    re.compile(CLI + r"\s+mode\s+[\"']?(?:off|claude)\b", re.I),
    # launchctl bootout / unload / disable / remove / kill / stop of the guard's LaunchAgent
    re.compile(r"\blaunchctl\b\s+(?:bootout|unload|disable|remove|kill|stop)\b.*\bsim-audio\b", re.I),
    # pkill / killall of the guard
    re.compile(r"\b(?:pkill|killall)\b.*(?:claude-sim-audio|Claude Sim Audio)", re.I),
    # removing the guard's LaunchAgent file or the app itself
    re.compile(r"\b(?:rm|mv|trash)\b.*(?:local\.sim-audio\.plist|Claude Sim Audio\.app)", re.I),
]

SEGMENT_SPLIT = re.compile(r"(?:;|&&|\|\||\||\n)")

REASON = (
    "Blocked by your standing rule: every simulator stays muted. This command would let a "
    "simulator play through your speakers, or stop the guard that mutes them. Approve only "
    "if you just asked for this."
)


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0  # malformed payload: stay out of the way

    command = (payload.get("tool_input") or {}).get("command") or ""
    if not isinstance(command, str) or not command.strip():
        return 0

    for segment in SEGMENT_SPLIT.split(command):
        if any(p.search(segment) for p in PATTERNS):
            json.dump(
                {
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": DECISION,
                        "permissionDecisionReason": REASON,
                    }
                },
                sys.stdout,
            )
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
