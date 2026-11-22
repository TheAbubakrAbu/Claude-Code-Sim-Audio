#!/usr/bin/env python3
"""Writes the LaunchAgent that keeps the sim-audio guard running: local.sim-audio.plist.

    python3 tools/launch_agent.py --data ~/.claude/sim-audio --out ~/Library/LaunchAgents/local.sim-audio.plist

launchd starts the guard at login, restarts it whenever it exits (the guard exits on purpose
when it stops making progress), and sends its output to DATA/daemon.log. When DATA is not the
default folder, the plist also sets SIM_AUDIO_HOME so the guard finds it.
"""
import argparse
import os
import plistlib
import sys

LABEL = "local.sim-audio"
APP = "Claude Sim Audio.app"
BINARY = "Contents/MacOS/claude-sim-audio"


def default_data():
    return os.path.join(os.path.expanduser("~"), ".claude", "sim-audio")


def binary_path(data):
    return os.path.join(data, APP, BINARY)


def agent(data):
    """The LaunchAgent for a guard that lives in `data`, as a dict."""
    data = os.path.abspath(os.path.expanduser(data))
    log = os.path.join(data, "daemon.log")
    plist = {
        "Label": LABEL,
        "ProgramArguments": [binary_path(data), "daemon"],
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 5,
        "ProcessType": "Interactive",
        "StandardOutPath": log,
        "StandardErrorPath": log,
    }
    if os.path.realpath(data) != os.path.realpath(default_data()):
        plist["EnvironmentVariables"] = {"SIM_AUDIO_HOME": data}
    return plist


def write(data, out):
    out = os.path.abspath(os.path.expanduser(out))
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "wb") as fh:
        plistlib.dump(agent(data), fh)
    os.replace(tmp, out)
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--data", default=default_data(), help="the guard's folder (default ~/.claude/sim-audio)")
    parser.add_argument("--out", required=True, help="where to write the plist")
    args = parser.parse_args(argv)
    print(write(args.data, args.out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
