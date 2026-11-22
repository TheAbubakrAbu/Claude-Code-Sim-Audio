"""Tests for build.sh. The real build compiles the app once into a throwaway folder, signed ad
hoc, and is deleted afterwards; it needs macOS with Xcode 26 or later and the iOS simulator SDK,
and is skipped elsewhere. The only thing ever run from the built app is its `help` text.

    python3 -m unittest discover -s tests -v
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build.sh")
APP = "Claude Sim Audio.app"


def sdk_major(sdk):
    try:
        out = subprocess.run(["xcrun", "--sdk", sdk, "--show-sdk-version"], capture_output=True,
                             text=True, timeout=60).stdout.strip()
        return int(out.split(".")[0])
    except Exception:
        return 0


def can_build():
    return sys.platform == "darwin" and shutil.which("xcrun") and sdk_major("macosx") >= 26 \
        and sdk_major("iphonesimulator") > 0


def repo_listing():
    found = set()
    for folder, dirs, files in os.walk(ROOT):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for name in files:
            found.add(os.path.relpath(os.path.join(folder, name), ROOT))
    return found


class BuildScript(unittest.TestCase):
    def test_refuses_to_build_inside_the_source_folder(self):
        for out in (ROOT, os.path.join(ROOT, "build"), os.path.join(ROOT, "src", "..", "out")):
            with self.subTest(out=out):
                proc = subprocess.run(["bash", BUILD, "--out", out], capture_output=True, text=True, timeout=60)
                self.assertEqual(proc.returncode, 2, proc.stdout + proc.stderr)
                self.assertIn("refusing to build inside the source folder", proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(ROOT, "build")))
        self.assertFalse(os.path.exists(os.path.join(ROOT, "out")))

    def test_help_and_unknown_options(self):
        proc = subprocess.run(["bash", BUILD, "--help"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertIn("--identity", proc.stdout)
        self.assertIn("SIM_AUDIO_SIGN_IDENTITY", proc.stdout)
        proc = subprocess.run(["bash", BUILD, "--bogus"], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)


@unittest.skipUnless(can_build(), "needs macOS with Xcode 26+ and the iOS simulator SDK")
class RealBuild(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = os.path.realpath(tempfile.mkdtemp(prefix="sim-audio-build-"))
        cls.out = os.path.join(cls.tmp, "out dir")
        cls.app = os.path.join(cls.out, APP)
        # An old app with a stray file in it: the build must swap the whole bundle.
        os.makedirs(os.path.join(cls.app, "Contents"))
        open(os.path.join(cls.app, "Contents", "stale-file"), "w").close()
        cls.before = repo_listing()
        env = dict(os.environ, SIM_AUDIO_SIGN_IDENTITY="No Such Signing Identity For Tests")
        cls.proc = subprocess.run(["bash", BUILD, "--out", cls.out], capture_output=True, text=True,
                                  env=env, timeout=900)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_build_succeeds(self):
        self.assertEqual(self.proc.returncode, 0, self.proc.stdout + self.proc.stderr)
        self.assertIn("Built " + self.app, self.proc.stdout)

    def test_the_bundle_holds_the_guard_and_the_test_sound(self):
        binary = os.path.join(self.app, "Contents", "MacOS", "claude-sim-audio")
        self.assertTrue(os.access(binary, os.X_OK))
        self.assertTrue(os.path.isfile(os.path.join(self.app, "Contents", "Info.plist")))
        tone = os.path.join(self.app, "Contents", "Resources", "simtone")
        self.assertTrue(os.access(tone, os.X_OK))
        kind = subprocess.run(["file", binary, tone], capture_output=True, text=True).stdout
        self.assertEqual(kind.count("Mach-O"), 2, kind)
        self.assertFalse(os.path.exists(os.path.join(self.app, "Contents", "stale-file")),
                         "the old bundle should have been replaced as a whole")

    def test_a_failed_identity_falls_back_to_ad_hoc_and_is_not_remembered(self):
        self.assertIn("Signing with that identity failed", self.proc.stderr)
        info = subprocess.run(["codesign", "-dv", self.app], capture_output=True, text=True).stderr
        self.assertIn("Identifier=local.claude.sim-audio", info)
        self.assertIn("Signature=adhoc", info)
        verify = subprocess.run(["codesign", "--verify", "--deep", self.app], capture_output=True, text=True)
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, "signing-identity")))

    def test_help_runs_and_matches_the_readme(self):
        # `help` only prints text: it reads no settings and talks to no guard.
        binary = os.path.join(self.app, "Contents", "MacOS", "claude-sim-audio")
        home = os.path.join(self.tmp, "binary-home")
        proc = subprocess.run([binary, "help"], capture_output=True, text=True, timeout=30,
                              env=dict(os.environ, SIM_AUDIO_HOME=home))
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(home), "help must not create the guard's folder")
        with open(os.path.join(ROOT, "README.md")) as fh:
            readme = fh.read()
        for command in ("simaudio doctor", "simaudio record", "simaudio log", "simaudio hear",
                        "simaudio mute", "simaudio mode", "simaudio restart"):
            self.assertIn(command, proc.stdout)
            self.assertIn("`" + command, readme, "README is missing " + command)

    def test_nothing_was_written_into_the_repository(self):
        self.assertEqual(repo_listing(), self.before)


if __name__ == "__main__":
    unittest.main()
