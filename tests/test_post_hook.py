"""Tests for the PostToolUse hook: sim-audio-hook.py, and the sim-audio-hook.sh shim in front of
it. SIM_AUDIO_HOME points at a throwaway folder, so the real ~/.claude/sim-audio is never read
or written.

    python3 -m unittest discover -s tests -v
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK_PY = os.path.join(ROOT, "hooks", "sim-audio-hook.py")
HOOK_SH = os.path.join(ROOT, "hooks", "sim-audio-hook.sh")

DRIVES = [
    "xcrun simctl boot 'iPhone 17 Pro'",
    "xcrun simctl launch booted com.example.app",
    "xcrun simctl install booted build/App.app",
    "xcrun simctl openurl booted https://example.com",
    "xcrun simctl push booted com.example.app payload.apns",
    "xcrun simctl spawn booted log stream",
    "xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build",
    "xcodebuild test -scheme App\n  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'",
]
IGNORES = [
    "xcrun simctl list devices",
    "xcrun simctl shutdown all",
    "xcodebuild -list",
    "xcodebuild -scheme App -destination 'platform=macOS' build",
    "git status",
    "simaudio doctor",
]


class PostHook(unittest.TestCase):
    def setUp(self):
        # The guard's folder sits inside a folder of this test's own. A marker that escapes it
        # (test_session_ids_cannot_escape_the_marker_folder) then lands in there and is deleted with
        # it, not in the shared temporary folder, where it would fail every later run.
        self.tmp = tempfile.mkdtemp(prefix="sim-audio-home-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self.seen = os.path.join(self.home, "hook-seen")
        self.env = dict(os.environ, SIM_AUDIO_HOME=self.home)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def run_hook(self, command, session="session-1", shim=False, payload=None):
        if payload is None:
            payload = json.dumps({"hook_event_name": "PostToolUse", "tool_name": "Bash", "session_id": session,
                                  "tool_input": {"command": command}, "tool_response": {"stdout": ""}})
        argv = ["/bin/sh", HOOK_SH] if shim else [sys.executable, HOOK_PY]
        return subprocess.run(argv, input=payload, capture_output=True, text=True, env=self.env, timeout=20)

    def note(self, proc):
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.strip(), "expected a note")
        out = json.loads(proc.stdout)["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PostToolUse")
        return out["additionalContext"]

    def guard_status(self, pid, updated):
        with open(os.path.join(self.home, "status.json"), "w") as fh:
            json.dump({"pid": pid, "updated": updated, "mode": "all", "sims": []}, fh)

    def test_tells_a_session_that_drives_a_simulator_how_sound_works(self):
        for i, command in enumerate(DRIVES):
            with self.subTest(command=command):
                text = self.note(self.run_hook(command, session="s%d" % i))
                self.assertIn("BlackHole 2ch", text)
                self.assertIn("simaudio record", text)
                self.assertIn("simaudio log", text)
                self.assertIn("simaudio doctor", text)
                self.assertIn("simaudio hear", text)

    def test_says_nothing_for_commands_that_do_not_drive_a_simulator(self):
        for command in IGNORES:
            with self.subTest(command=command):
                proc = self.run_hook(command)
                self.assertEqual(proc.returncode, 0, proc.stderr)
                self.assertEqual(proc.stdout.strip(), "")
        self.assertFalse(os.path.exists(self.seen), "no marker for commands that do not count")

    def test_only_once_per_session(self):
        self.note(self.run_hook(DRIVES[0], session="abc"))
        self.assertTrue(os.path.exists(os.path.join(self.seen, "abc")))
        again = self.run_hook(DRIVES[1], session="abc")
        self.assertEqual(again.stdout.strip(), "")
        self.note(self.run_hook(DRIVES[1], session="other"))
        self.assertEqual(sorted(os.listdir(self.seen)), ["abc", "other"])

    def test_warns_when_the_guard_is_not_running(self):
        self.assertIn("NOT running", self.note(self.run_hook(DRIVES[0], session="none")))
        self.guard_status(os.getpid(), time.time() - 60)  # alive process, stale heartbeat
        self.assertIn("NOT running", self.note(self.run_hook(DRIVES[0], session="stale")))
        self.guard_status(2 ** 22 + 12345, time.time())  # fresh heartbeat, no such process
        self.assertIn("NOT running", self.note(self.run_hook(DRIVES[0], session="dead")))

    def test_no_warning_while_the_guard_is_running(self):
        self.guard_status(os.getpid(), time.time())
        text = self.note(self.run_hook(DRIVES[0], session="alive"))
        self.assertNotIn("NOT running", text)

    def test_session_ids_cannot_escape_the_marker_folder(self):
        self.note(self.run_hook(DRIVES[0], session="../../evil"))
        self.assertEqual(os.listdir(self.seen), ["evil"])
        self.note(self.run_hook(DRIVES[0], session=""))
        self.assertIn("unknown", os.listdir(self.seen))
        self.assertFalse(os.path.exists(os.path.join(self.home, "..", "evil")))

    def test_forgets_sessions_older_than_a_week(self):
        os.makedirs(self.seen)
        old = os.path.join(self.seen, "old-session")
        recent = os.path.join(self.seen, "recent-session")
        for path in (old, recent):
            open(path, "w").close()
        week_ago = time.time() - 8 * 24 * 3600
        os.utime(old, (week_ago, week_ago))
        self.note(self.run_hook(DRIVES[0], session="new"))
        self.assertEqual(sorted(os.listdir(self.seen)), ["new", "recent-session"])

    def test_shim_runs_the_python_next_to_itself(self):
        text = self.note(self.run_hook(DRIVES[0], session="via-shim", shim=True))
        self.assertIn("BlackHole 2ch", text)
        self.assertTrue(os.path.exists(os.path.join(self.seen, "via-shim")))

    def test_shim_passes_xcodebuild_commands_on_too(self):
        command = DRIVES[6]
        self.assertNotIn("simctl", command)  # only the shim's xcodebuild filter lets this one through
        text = self.note(self.run_hook(command, session="via-shim-xcodebuild", shim=True))
        self.assertIn("BlackHole 2ch", text)

    def test_shim_skips_commands_without_simctl_or_xcodebuild(self):
        proc = self.run_hook("echo hello", shim=True)
        self.assertEqual((proc.returncode, proc.stdout), (0, ""))
        self.assertFalse(os.path.exists(self.seen))

    def test_shim_always_exits_zero(self):
        proc = self.run_hook(None, shim=True, payload="not json simctl")
        self.assertEqual((proc.returncode, proc.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
