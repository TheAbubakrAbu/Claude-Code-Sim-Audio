"""Tests for the PreToolUse guard: sim-audio-guard.py, and the sim-audio-guard.sh shim in front
of it. Each command is fed to the hook as Claude Code would; nothing is run.

    python3 -m unittest discover -s tests -v
"""
import json
import os
import subprocess
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD_PY = os.path.join(ROOT, "hooks", "sim-audio-guard.py")
GUARD_SH = os.path.join(ROOT, "hooks", "sim-audio-guard.sh")
BINARY = '"$HOME/.claude/sim-audio/Claude Sim Audio.app/Contents/MacOS/claude-sim-audio"'

# Commands that would let a simulator play out loud, or take the guard down.
ASKS = [
    "simaudio hear iPhone",
    "simaudio hear 'iPhone 17 Pro' 5",
    "simaudio unmute iPad",
    "simaudio mode off",
    "simaudio mode claude",
    "simaudio mode 'off'",
    'simaudio mode "claude"',
    "SIMAUDIO HEAR iPhone",
    BINARY + " hear iPhone",
    BINARY + " mode off",
    "/opt/homebrew/bin/simaudio hear iPhone",
    "cd ~/code/app && simaudio hear iPhone",
    "xcrun simctl boot X; simaudio mode off",
    "true || simaudio hear X",
    "echo ok\nsimaudio hear X",
    "launchctl bootout gui/501/local.sim-audio",
    "launchctl unload ~/Library/LaunchAgents/local.sim-audio.plist",
    "launchctl disable gui/501/local.sim-audio",
    "launchctl remove local.sim-audio",
    "launchctl kill SIGTERM gui/501/local.sim-audio",
    "launchctl stop local.sim-audio",
    "pkill -f claude-sim-audio",
    'killall "Claude Sim Audio"',
    "rm ~/Library/LaunchAgents/local.sim-audio.plist",
    'rm -rf "$HOME/.claude/sim-audio/Claude Sim Audio.app"',
    'mv ~/Library/LaunchAgents/local.sim-audio.plist /tmp/',
    'trash "Claude Sim Audio.app"',
]

# Commands that keep things quiet or only read: never a prompt.
PASSES = [
    "simaudio",
    "simaudio status",
    "simaudio doctor",
    "simaudio doctor --quick",
    "simaudio record iPhone 5",
    "simaudio record iPhone --json",
    "simaudio log 100",
    "simaudio mute iPhone",
    "simaudio mode all",
    "simaudio restart",
    "simaudio help",
    "launchctl print gui/501/local.sim-audio",
    "launchctl bootstrap gui/501 ~/Library/LaunchAgents/local.sim-audio.plist",
    "launchctl kickstart -k gui/501/local.sim-audio",
    "cat ~/.claude/sim-audio/events.log",
    "ls ~/.claude/sim-audio",
    "echo hear me",
    "git status",
    "grep -r hear src/",
    "xcrun simctl boot 'iPhone 17 Pro'",
]


def run(path, payload, shell=False):
    text = payload if isinstance(payload, str) else json.dumps(payload)
    argv = ["/bin/sh", path] if shell else [sys.executable, path]
    proc = subprocess.run(argv, input=text, capture_output=True, text=True, timeout=20)
    return proc


def bash(command):
    return {"hook_event_name": "PreToolUse", "tool_name": "Bash", "session_id": "test",
            "tool_input": {"command": command, "description": "test"}}


class GuardHook(unittest.TestCase):
    def assertAsks(self, proc, command):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.strip(), "expected a prompt for: %r" % command)
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PreToolUse")
        self.assertEqual(out["permissionDecision"], "ask")
        self.assertIn("muted", out["permissionDecisionReason"])

    def assertPasses(self, proc, command):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), "", "expected no prompt for: %r" % command)

    def test_asks_before_making_a_simulator_audible_or_stopping_the_guard(self):
        for command in ASKS:
            with self.subTest(command=command):
                self.assertAsks(run(GUARD_PY, bash(command)), command)

    def test_stays_out_of_the_way_of_everything_else(self):
        for command in PASSES:
            with self.subTest(command=command):
                self.assertPasses(run(GUARD_PY, bash(command)), command)

    def test_shim_hands_matching_commands_to_the_python_check(self):
        # The shim's quick filter is case-sensitive (the Python check is not), so an all-caps
        # SIMAUDIO never reaches the Python check. See Known Limitations in the README.
        for command in ASKS:
            if command.startswith("SIMAUDIO"):
                continue
            with self.subTest(command=command):
                self.assertAsks(run(GUARD_SH, bash(command), shell=True), command)

    def test_shim_passes_harmless_commands(self):
        for command in PASSES + ["npm test", "swift build"]:
            with self.subTest(command=command):
                self.assertPasses(run(GUARD_SH, bash(command), shell=True), command)

    def test_shim_finds_the_python_next_to_itself(self):
        # The shim is run by its full path from anywhere; it must not assume ~/.claude/hooks.
        proc = subprocess.run(["/bin/sh", GUARD_SH], input=json.dumps(bash("simaudio hear X")),
                              capture_output=True, text=True, timeout=20, cwd="/")
        self.assertAsks(proc, "simaudio hear X")

    def test_malformed_or_empty_payloads_are_ignored(self):
        # '["simaudio hear"]' is JSON but not an object: the Python check fails on it, and the
        # shim still exits 0 with no output.
        for payload in ["", "not json", '["simaudio hear"]', json.dumps({}), json.dumps({"tool_input": {}}),
                        json.dumps({"tool_input": {"command": ""}}),
                        json.dumps({"tool_input": {"command": 42}})]:
            with self.subTest(payload=payload):
                if not payload.startswith("["):  # Claude Code always sends an object
                    proc = run(GUARD_PY, payload)
                    self.assertEqual(proc.returncode, 0)
                    self.assertEqual(proc.stdout.strip(), "")
                shim = run(GUARD_SH, payload, shell=True)
                self.assertEqual(shim.returncode, 0)
                self.assertEqual(shim.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
