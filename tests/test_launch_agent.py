"""Tests for tools/launch_agent.py, which writes the guard's LaunchAgent. Plists go to a
throwaway folder and are never loaded.

    python3 -m unittest discover -s tests -v
"""
import importlib.util
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(ROOT, "tools", "launch_agent.py")


def load_module():
    spec = importlib.util.spec_from_file_location("launch_agent", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LaunchAgent(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="sim-audio-agent-")
        self.la = load_module()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_default_folder_matches_the_original_agent(self):
        data = os.path.join(os.path.expanduser("~"), ".claude", "sim-audio")
        plist = self.la.agent(data)
        self.assertEqual(plist["Label"], "local.sim-audio")
        self.assertEqual(plist["ProgramArguments"],
                         [data + "/Claude Sim Audio.app/Contents/MacOS/claude-sim-audio", "daemon"])
        self.assertIs(plist["RunAtLoad"], True)
        self.assertIs(plist["KeepAlive"], True)
        self.assertEqual(plist["ThrottleInterval"], 5)
        self.assertEqual(plist["ProcessType"], "Interactive")
        self.assertEqual(plist["StandardOutPath"], data + "/daemon.log")
        self.assertEqual(plist["StandardErrorPath"], data + "/daemon.log")
        self.assertNotIn("EnvironmentVariables", plist, "the default folder needs no SIM_AUDIO_HOME")

    def test_another_folder_sets_sim_audio_home(self):
        data = os.path.join(self.tmp, "guard data")
        plist = self.la.agent(data)
        self.assertEqual(plist["EnvironmentVariables"], {"SIM_AUDIO_HOME": data})
        self.assertTrue(plist["ProgramArguments"][0].startswith(data + "/Claude Sim Audio.app/"))

    def test_relative_and_tilde_paths_become_absolute(self):
        plist = self.la.agent("~/.claude/sim-audio")
        self.assertTrue(os.path.isabs(plist["ProgramArguments"][0]))
        self.assertNotIn("~", plist["StandardOutPath"])
        cwd = os.getcwd()
        try:
            os.chdir(self.tmp)
            plist = self.la.agent("relative")
        finally:
            os.chdir(cwd)
        self.assertEqual(plist["EnvironmentVariables"]["SIM_AUDIO_HOME"],
                         os.path.join(os.path.realpath(self.tmp), "relative"))

    def test_cli_writes_a_valid_plist_that_plutil_accepts(self):
        out = os.path.join(self.tmp, "agents", "local.sim-audio.plist")
        data = os.path.join(self.tmp, "data & more <odd>")
        proc = subprocess.run([sys.executable, SCRIPT, "--data", data, "--out", out],
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout.strip(), out)
        with open(out, "rb") as fh:
            plist = plistlib.load(fh)
        self.assertEqual(plist["EnvironmentVariables"]["SIM_AUDIO_HOME"], data)
        self.assertFalse(os.path.exists(out + ".tmp"))
        if shutil.which("plutil"):
            lint = subprocess.run(["plutil", "-lint", out], capture_output=True, text=True)
            self.assertEqual(lint.returncode, 0, lint.stdout + lint.stderr)

    def test_rewriting_replaces_the_old_plist(self):
        out = os.path.join(self.tmp, "local.sim-audio.plist")
        self.la.write(os.path.join(self.tmp, "one"), out)
        self.la.write(os.path.join(self.tmp, "two"), out)
        with open(out, "rb") as fh:
            plist = plistlib.load(fh)
        self.assertEqual(plist["EnvironmentVariables"]["SIM_AUDIO_HOME"], os.path.join(self.tmp, "two"))


if __name__ == "__main__":
    unittest.main()
