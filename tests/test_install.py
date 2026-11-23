"""Tests for install.sh. Every run uses a throwaway HOME, --bin in a throwaway folder,
--no-build and --no-launchd, and a fake `launchctl` and `xcrun` first on the PATH that record
any call: nothing is built, nothing is loaded, and the real ~/.claude is never touched.

    python3 -m unittest discover -s tests -v
"""
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALL = os.path.join(ROOT, "install.sh")
BINARY_TAIL = "/Claude Sim Audio.app/Contents/MacOS/claude-sim-audio"
GUARD_DEFAULT = '"$HOME/.claude/hooks/sim-audio-guard.sh"'
HOOK_DEFAULT = '"$HOME/.claude/hooks/sim-audio-hook.sh"'
HOOK_FILES = ["sim-audio-guard.sh", "sim-audio-guard.py", "sim-audio-hook.sh", "sim-audio-hook.py"]


def repo_listing():
    found = set()
    for folder, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for name in files:
            found.add(os.path.relpath(os.path.join(folder, name), ROOT))
    return found


@unittest.skipUnless(sys.platform == "darwin", "the installer is macOS only")
class Installer(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="sim-audio-install-"))
        self.home = os.path.join(self.tmp, "home")
        self.bin = os.path.join(self.tmp, "bin")
        self.fakes = os.path.join(self.tmp, "fakes")
        self.calls = os.path.join(self.tmp, "calls.log")
        os.makedirs(self.home)
        os.makedirs(self.fakes)
        for tool in ("launchctl", "xcrun", "codesign"):
            path = os.path.join(self.fakes, tool)
            with open(path, "w") as fh:
                fh.write('#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' % (tool, self.calls))
            os.chmod(path, 0o755)
        self.env = dict(os.environ, HOME=self.home, PATH=self.fakes + os.pathsep + os.environ["PATH"])
        self.env.pop("SIM_AUDIO_HOME", None)
        self.env.pop("SIM_AUDIO_SIGN_IDENTITY", None)
        self.settings = os.path.join(self.home, ".claude", "settings.json")
        self.hooks = os.path.join(self.home, ".claude", "hooks")
        self.data = os.path.join(self.home, ".claude", "sim-audio")
        self.plist = os.path.join(self.home, "Library", "LaunchAgents", "local.sim-audio.plist")
        self.link = os.path.join(self.bin, "simaudio")

    def tearDown(self):
        self.assertFalse(os.path.exists(self.calls), "launchctl, xcrun or codesign was called:\n"
                         + (open(self.calls).read() if os.path.exists(self.calls) else ""))
        shutil.rmtree(self.tmp, ignore_errors=True)

    # helpers -------------------------------------------------------------

    def install(self, *args, ok=True):
        argv = ["bash", INSTALL, "--bin", self.bin, "--no-build", "--no-launchd"] + list(args)
        proc = subprocess.run(argv, capture_output=True, text=True, env=self.env, timeout=60)
        if ok:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def read_settings(self):
        with open(self.settings) as fh:
            return json.load(fh)

    def write_settings(self, data):
        os.makedirs(os.path.dirname(self.settings), exist_ok=True)
        with open(self.settings, "w") as fh:
            json.dump(data, fh, indent=2)

    def commands(self, event):
        return [h["command"] for g in self.read_settings().get("hooks", {}).get(event, []) for h in g.get("hooks", [])]

    def backups(self):
        folder = os.path.dirname(self.settings)
        return sorted(n for n in os.listdir(folder) if n.startswith("settings.json.bak-"))

    def run_command(self, command, payload):
        """Runs a hook command the way Claude Code does: through the shell, payload on stdin."""
        return subprocess.run(["/bin/sh", "-c", command], input=json.dumps(payload), capture_output=True,
                              text=True, env=self.env, timeout=20)

    # tests ---------------------------------------------------------------

    def test_fresh_install_reproduces_the_original_layout(self):
        proc = self.install()
        self.assertIn("wired into " + self.settings, proc.stdout)
        for name in HOOK_FILES:
            self.assertTrue(os.path.isfile(os.path.join(self.hooks, name)), name)
        for name in ("sim-audio-guard.sh", "sim-audio-hook.sh"):
            self.assertTrue(os.access(os.path.join(self.hooks, name), os.X_OK), name)
        with open(os.path.join(self.data, "config.json")) as fh:
            self.assertEqual(json.load(fh), {"mode": "all"})
        self.assertEqual(self.read_settings()["hooks"], {
            "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": GUARD_DEFAULT, "timeout": 10}]}],
            "PostToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": HOOK_DEFAULT, "timeout": 10}]}],
        })
        with open(self.plist, "rb") as fh:
            plist = plistlib.load(fh)
        self.assertEqual(plist["ProgramArguments"], [self.data + BINARY_TAIL, "daemon"])
        self.assertNotIn("EnvironmentVariables", plist)
        self.assertTrue(os.path.islink(self.link))
        self.assertEqual(os.readlink(self.link), self.data + BINARY_TAIL)
        self.assertIn("not on your PATH", proc.stdout)

    def test_the_wired_hook_commands_work(self):
        self.install()
        guard = self.run_command(self.commands("PreToolUse")[0],
                                 {"tool_input": {"command": "simaudio hear iPhone"}})
        self.assertEqual(json.loads(guard.stdout)["hookSpecificOutput"]["permissionDecision"], "ask")
        quiet = self.run_command(self.commands("PreToolUse")[0], {"tool_input": {"command": "simaudio doctor"}})
        self.assertEqual(quiet.stdout, "")
        post = self.run_command(self.commands("PostToolUse")[0],
                                {"session_id": "s1", "tool_input": {"command": "xcrun simctl boot X"}})
        self.assertIn("BlackHole 2ch", json.loads(post.stdout)["hookSpecificOutput"]["additionalContext"])
        self.assertTrue(os.path.exists(os.path.join(self.data, "hook-seen", "s1")))

    def test_running_it_again_changes_nothing(self):
        self.install()
        with open(self.settings) as fh:
            first = fh.read()
        proc = self.install()
        self.assertIn("settings already up to date", proc.stdout)
        with open(self.settings) as fh:
            self.assertEqual(fh.read(), first)
        self.assertEqual(self.backups(), [])

    def test_keeps_your_config(self):
        os.makedirs(self.data)
        with open(os.path.join(self.data, "config.json"), "w") as fh:
            json.dump({"mode": "claude", "hear": {"ABC": 1}}, fh)
        self.install()
        with open(os.path.join(self.data, "config.json")) as fh:
            self.assertEqual(json.load(fh), {"mode": "claude", "hear": {"ABC": 1}})

    def test_keeps_other_hooks_and_uninstall_restores_the_file(self):
        original = {
            "model": "opus",
            "hooks": {
                "PreToolUse": [{"matcher": "Bash", "hooks": [
                    {"type": "command", "command": 'python3 "$HOME/.claude/hooks/git-guard.py"', "timeout": 10}]}],
                "Stop": [{"hooks": [{"type": "command", "command": 'python3 "$HOME/.claude/hooks/notify.py"'}]}],
            },
        }
        self.write_settings(original)
        self.install()
        self.assertEqual(len(self.backups()), 1)
        self.assertEqual(self.commands("PreToolUse"), ['python3 "$HOME/.claude/hooks/git-guard.py"', GUARD_DEFAULT])
        self.assertEqual(self.commands("Stop"), ['python3 "$HOME/.claude/hooks/notify.py"'])
        self.assertEqual(self.read_settings()["model"], "opus")
        self.install("--uninstall")
        self.assertEqual(self.read_settings(), original)

    def test_hooks_already_in_a_shared_group_are_left_where_they_are(self):
        shared = {"hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": 'python3 "$HOME/.claude/hooks/git-guard.py"', "timeout": 10},
                {"type": "command", "command": GUARD_DEFAULT, "timeout": 10}]}],
            "PostToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": '"$HOME/.claude/hooks/idle-reaper-hook.sh"', "timeout": 10},
                {"type": "command", "command": HOOK_DEFAULT, "timeout": 10}]}],
        }}
        self.write_settings(shared)
        proc = self.install()
        self.assertIn("settings already up to date", proc.stdout)
        self.assertEqual(self.read_settings(), shared)
        self.install("--uninstall")
        self.assertEqual(self.commands("PreToolUse"), ['python3 "$HOME/.claude/hooks/git-guard.py"'])
        self.assertEqual(self.commands("PostToolUse"), ['"$HOME/.claude/hooks/idle-reaper-hook.sh"'])

    def test_uninstall_keeps_files_and_purge_deletes_them(self):
        self.install()
        os.makedirs(os.path.join(self.data, "recordings"))
        with open(os.path.join(self.data, "events.log"), "w") as fh:
            fh.write("guard started\n")
        proc = self.install("--uninstall")
        self.assertIn("simaudio mode off", proc.stdout)
        self.assertFalse(os.path.exists(self.plist))
        self.assertFalse(os.path.lexists(self.link))
        self.assertNotIn("hooks", self.read_settings())
        for name in HOOK_FILES:
            self.assertTrue(os.path.exists(os.path.join(self.hooks, name)), name)
        self.assertTrue(os.path.exists(os.path.join(self.data, "events.log")))
        self.install("--uninstall", "--purge")
        for name in HOOK_FILES:
            self.assertFalse(os.path.exists(os.path.join(self.hooks, name)), name)
        self.assertFalse(os.path.exists(self.data))
        self.assertTrue(os.path.isdir(self.hooks), "the hooks folder itself stays")

    def test_another_data_folder_is_passed_to_everything(self):
        data = os.path.join(self.tmp, "guard data")
        hooks = os.path.join(self.tmp, "my hooks")
        self.install("--data", data, "--dest", hooks)
        guard_cmd, = self.commands("PreToolUse")
        hook_cmd, = self.commands("PostToolUse")
        self.assertEqual(guard_cmd, '"%s/sim-audio-guard.sh"' % hooks)
        self.assertEqual(hook_cmd, 'SIM_AUDIO_HOME="%s" "%s/sim-audio-hook.sh"' % (data, hooks))
        with open(self.plist, "rb") as fh:
            plist = plistlib.load(fh)
        self.assertEqual(plist["EnvironmentVariables"], {"SIM_AUDIO_HOME": data})
        self.assertEqual(plist["ProgramArguments"][0], data + BINARY_TAIL)
        # simaudio becomes a wrapper that sets SIM_AUDIO_HOME, not a bare link.
        self.assertFalse(os.path.islink(self.link))
        with open(self.link) as fh:
            wrapper = fh.read()
        self.assertIn("SIM_AUDIO_HOME='%s'" % data, wrapper)
        self.assertIn("exec '%s'" % (data + BINARY_TAIL), wrapper)
        self.assertEqual(subprocess.run(["/bin/sh", "-n", self.link]).returncode, 0)
        # The wired post hook writes its marker in the other folder, not in ~/.claude/sim-audio.
        self.run_command(hook_cmd, {"session_id": "moved", "tool_input": {"command": "xcrun simctl boot X"}})
        self.assertTrue(os.path.exists(os.path.join(data, "hook-seen", "moved")))
        self.assertFalse(os.path.exists(os.path.join(self.data, "hook-seen")))
        self.install("--data", data, "--dest", hooks, "--uninstall", "--purge")
        self.assertFalse(os.path.exists(data))
        self.assertFalse(os.path.lexists(self.link))

    def test_purge_refuses_to_delete_the_home_folder_or_the_claude_folder(self):
        # --purge ends in `rm -rf` of the data folder, so a --data that names the home folder or
        # ~/.claude must be turned away. Both live in this test's throwaway folder here: an
        # installer that lost the check could delete nothing else.
        claude = os.path.join(self.home, ".claude")
        os.makedirs(claude)
        kept = [os.path.join(self.home, "keep.txt"), os.path.join(claude, "keep.txt")]
        for path in kept:
            with open(path, "w") as fh:
                fh.write("mine")
        for data in (self.home, claude, "~", "~/.claude"):
            with self.subTest(data=data):
                proc = self.install("--data", data, "--uninstall", "--purge", ok=False)
                self.assertEqual(proc.returncode, 1, proc.stdout + proc.stderr)
                self.assertIn("refusing to delete", proc.stderr)
                self.assertEqual([os.path.exists(path) for path in kept], [True, True])

    def test_leaves_a_simaudio_that_is_not_ours_alone(self):
        os.makedirs(self.bin)
        with open(self.link, "w") as fh:
            fh.write("#!/bin/sh\necho someone else's tool\n")
        proc = self.install()
        self.assertIn("left " + self.link + " alone", proc.stdout)
        self.install("--uninstall")
        with open(self.link) as fh:
            self.assertIn("someone else's tool", fh.read())

    def test_replaces_its_own_old_link(self):
        os.makedirs(self.bin)
        os.symlink("/old/place/Claude Sim Audio.app/Contents/MacOS/claude-sim-audio", self.link)
        self.install()
        self.assertEqual(os.readlink(self.link), self.data + BINARY_TAIL)

    def test_refuses_a_settings_file_that_is_not_an_object(self):
        os.makedirs(os.path.dirname(self.settings))
        with open(self.settings, "w") as fh:
            fh.write("[]")
        proc = self.install(ok=False)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("not a JSON object", proc.stderr)
        with open(self.settings) as fh:
            self.assertEqual(fh.read(), "[]")

    def test_help_and_unknown_options(self):
        proc = subprocess.run(["bash", INSTALL, "-h"], capture_output=True, text=True, env=self.env)
        self.assertEqual(proc.returncode, 0)
        for flag in ("--identity", "--data", "--dest", "--settings", "--launch-agents", "--bin",
                     "--no-build", "--no-launchd", "--uninstall", "--purge"):
            self.assertIn(flag, proc.stdout)
        proc = subprocess.run(["bash", INSTALL, "--bogus"], capture_output=True, text=True, env=self.env)
        self.assertEqual(proc.returncode, 2)

    def test_never_writes_into_the_repository(self):
        before = repo_listing()
        self.install()
        self.install("--uninstall", "--purge")
        self.assertEqual(repo_listing(), before)


if __name__ == "__main__":
    unittest.main()
