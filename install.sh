#!/usr/bin/env bash
# Claude Code Sim Audio installer.
#   ./install.sh                            build the guard, start it, add simaudio, wire the hooks
#   ./install.sh --identity ID              sign with this certificate (keeps the audio permission)
#   ./install.sh --dest ~/.claude/hooks     where the two hook scripts go
#   ./install.sh --data ~/.claude/sim-audio the guard's folder: app, settings, log, recordings
#   ./install.sh --settings ~/.claude/settings.json
#   ./install.sh --launch-agents ~/Library/LaunchAgents
#   ./install.sh --bin DIR                  where `simaudio` goes (/opt/homebrew/bin or ~/.local/bin)
#   ./install.sh --no-build                 keep the app already in the data folder
#   ./install.sh --no-launchd               write the LaunchAgent, but do not load or unload it
#   ./install.sh --uninstall                stop the guard; remove the hooks, LaunchAgent and simaudio
#   ./install.sh --uninstall --purge        also delete the hook scripts and the data folder
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LABEL="local.sim-audio"
APP="Claude Sim Audio.app"
DEST="$HOME/.claude/hooks"
DATA="$HOME/.claude/sim-audio"
SETTINGS="$HOME/.claude/settings.json"
AGENTS="$HOME/Library/LaunchAgents"
BIN=""
IDENTITY=""
BUILD=1
LAUNCHD=1
UNINSTALL=0
PURGE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dest) DEST="$2"; shift 2 ;;
    --data) DATA="$2"; shift 2 ;;
    --settings) SETTINGS="$2"; shift 2 ;;
    --launch-agents) AGENTS="$2"; shift 2 ;;
    --bin) BIN="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    --no-launchd) LAUNCHD=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --purge) PURGE=1; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = Darwin ] || { echo "Claude Code Sim Audio runs on macOS only." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required (xcode-select --install)" >&2; exit 1; }

absolute() { python3 -c 'import os,sys; print(os.path.abspath(os.path.expanduser(sys.argv[1])))' "$1"; }
DEST="$(absolute "$DEST")"
DATA="$(absolute "$DATA")"
SETTINGS="$(absolute "$SETTINGS")"
AGENTS="$(absolute "$AGENTS")"
if [ -z "$BIN" ]; then
  if [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then BIN=/opt/homebrew/bin; else BIN="$HOME/.local/bin"; fi
fi
BIN="$(absolute "$BIN")"
PLIST="$AGENTS/$LABEL.plist"
LINK="$BIN/simaudio"
BINARY="$DATA/$APP/Contents/MacOS/claude-sim-audio"
DEFAULT_DATA=0
[ "$DATA" = "$HOME/.claude/sim-audio" ] && DEFAULT_DATA=1

# A `simaudio` in BIN is ours when it points at (or wraps) the guard's binary.
link_is_ours() {
  if [ -L "$LINK" ]; then
    case "$(readlink "$LINK")" in *claude-sim-audio) return 0 ;; esac
    return 1
  fi
  [ -f "$LINK" ] && grep -q 'claude-sim-audio' "$LINK" 2>/dev/null
}

# The commands stored in settings.json. $HOME keeps them portable between Macs.
if [ "$DEST" = "$HOME/.claude/hooks" ]; then
  GUARD_CMD='"$HOME/.claude/hooks/sim-audio-guard.sh"'
  HOOK_CMD='"$HOME/.claude/hooks/sim-audio-hook.sh"'
else
  GUARD_CMD="\"$DEST/sim-audio-guard.sh\""
  HOOK_CMD="\"$DEST/sim-audio-hook.sh\""
fi
if [ "$DEFAULT_DATA" = 0 ]; then
  HOOK_CMD="SIM_AUDIO_HOME=\"$DATA\" $HOOK_CMD"
fi

wire_settings() {
python3 - "$SETTINGS" "$GUARD_CMD" "$HOOK_CMD" "$UNINSTALL" <<'PY'
import json, os, shutil, sys, time

path, guard_cmd, hook_cmd, uninstall = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
WANTED = [("PreToolUse", "sim-audio-guard", guard_cmd), ("PostToolUse", "sim-audio-hook", hook_cmd)]

try:
    with open(path) as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    sys.exit("%s is not a JSON object; fix it by hand first" % path)
before = json.dumps(data, sort_keys=True)
hooks = data.setdefault("hooks", {})


def ours(hook, keys):
    return isinstance(hook, dict) and any(k in str(hook.get("command", "")) for k in keys)


if uninstall:
    keys = [key for _, key, _ in WANTED]
    for event in list(hooks):
        groups = hooks[event]
        if not isinstance(groups, list):
            continue
        kept = []
        for group in groups:
            inner = [h for h in group.get("hooks", []) if not ours(h, keys)]
            if inner or not group.get("hooks"):
                kept.append(dict(group, hooks=inner) if group.get("hooks") else group)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    if not hooks:
        data.pop("hooks", None)
else:
    for event, key, cmd in WANTED:
        groups = hooks.setdefault(event, [])
        found = False
        for group in groups:
            for hook in group.get("hooks", []):
                if ours(hook, [key]):
                    found = True
                    hook["type"] = "command"
                    hook["command"] = cmd
                    hook.setdefault("timeout", 10)
        if not found:
            groups.append({"matcher": "Bash", "hooks": [{"type": "command", "command": cmd, "timeout": 10}]})

if json.dumps(data, sort_keys=True) == before:
    print("settings already up to date: " + path)
else:
    if os.path.exists(path):
        backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S")
        n = 1
        while os.path.exists(backup):  # two runs in one second must not share a backup
            backup = path + ".bak-" + time.strftime("%Y%m%d-%H%M%S") + "-%d" % n
            n += 1
        shutil.copy(path, backup)
        print("backed up " + backup)
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")
    print(("removed from " if uninstall else "wired into ") + path)
PY
}

# ---------------------------------------------------------------- uninstall
if [ "$UNINSTALL" = 1 ]; then
  if [ "$LAUNCHD" = 1 ]; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null && echo "stopped the guard ($LABEL)" || true
  fi
  if [ -f "$PLIST" ]; then rm -f "$PLIST"; echo "deleted $PLIST"; fi
  if link_is_ours; then rm -f "$LINK"; echo "deleted $LINK"; fi
  wire_settings
  if [ "$PURGE" = 1 ]; then
    rm -f "$DEST/sim-audio-guard.sh" "$DEST/sim-audio-guard.py" "$DEST/sim-audio-hook.sh" "$DEST/sim-audio-hook.py"
    echo "deleted the hook scripts in $DEST"
    case "$DATA" in
      ""|/|"$HOME"|"$HOME/.claude") echo "refusing to delete $DATA" >&2; exit 1 ;;
    esac
    rm -rf "$DATA"
    echo "deleted $DATA (the app, settings, log and recordings)"
  else
    echo "kept the hook scripts in $DEST and $DATA (add --purge to delete them)"
  fi
  cat <<EOF

Simulators the guard routed to BlackHole stay silent until their output is changed. To put
them back before uninstalling, boot them with the guard running and run: simaudio mode off
Restart your Claude Code sessions: hooks are read when a session starts.
EOF
  exit 0
fi

# ---------------------------------------------------------------- install
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$BUILD" = 1 ] || [ "$LAUNCHD" = 1 ]; then
  [ "$macos_major" -ge 26 ] || { echo "The guard needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))." >&2; exit 1; }
fi
if [ "$BUILD" = 1 ]; then
  command -v xcrun >/dev/null 2>&1 || { echo "Xcode is required to build the guard (xcrun is missing)." >&2; exit 1; }
  sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo 0)"
  [ "${sdk%%.*}" -ge 26 ] || { echo "Building needs Xcode 26 or later (the macOS SDK here is $sdk)." >&2; exit 1; }
  xcrun --sdk iphonesimulator --show-sdk-path >/dev/null 2>&1 || {
    echo "Building needs the iOS simulator SDK: add an iOS platform in Xcode > Settings > Components." >&2; exit 1; }
fi
if [ ! -d /Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver ]; then
  echo "note: BlackHole 2ch is not installed. Install it: brew install blackhole-2ch"
  echo "      Until then the guard mutes simulators with its fallback tap (the purple recording dot)."
fi

mkdir -p "$DEST" "$DATA"
for f in sim-audio-guard.sh sim-audio-guard.py sim-audio-hook.sh sim-audio-hook.py; do
  cp "$HERE/hooks/$f" "$DEST/$f"
done
chmod +x "$DEST/sim-audio-guard.sh" "$DEST/sim-audio-hook.sh" "$DEST/sim-audio-guard.py"
if [ ! -f "$DATA/config.json" ]; then
  cp "$HERE/config.example.json" "$DATA/config.json"
fi

if [ "$BUILD" = 1 ]; then
  if [ -n "$IDENTITY" ]; then
    "$HERE/build.sh" --out "$DATA" --identity "$IDENTITY"
  else
    "$HERE/build.sh" --out "$DATA"
  fi
elif [ ! -x "$BINARY" ]; then
  echo "note: --no-build, and there is no app in $DATA yet"
fi

# The `simaudio` command: a link to the binary, or a small wrapper when the data folder moved.
mkdir -p "$BIN"
if { [ -e "$LINK" ] || [ -L "$LINK" ]; } && ! link_is_ours; then
  echo "left $LINK alone: it is not this tool's. Run the guard's CLI as: \"$BINARY\""
elif [ "$DEFAULT_DATA" = 1 ]; then
  ln -sfn "$BINARY" "$LINK"
else
  rm -f "$LINK"  # never write through an old link into the binary
  python3 - "$LINK" "$DATA" "$BINARY" <<'PY'
import os, shlex, sys
link, data, binary = sys.argv[1:]
with open(link, "w") as fh:
    fh.write("#!/bin/sh\n# simaudio for a sim-audio guard kept in another folder (written by install.sh).\n")
    fh.write("SIM_AUDIO_HOME=%s exec %s \"$@\"\n" % (shlex.quote(data), shlex.quote(binary)))
os.chmod(link, 0o755)
PY
fi

python3 "$HERE/tools/launch_agent.py" --data "$DATA" --out "$PLIST" >/dev/null
if [ "$LAUNCHD" = 1 ]; then
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
fi

wire_settings

case ":$PATH:" in
  *":$BIN:"*) path_note="" ;;
  *) path_note="  $BIN is not on your PATH: add it, or run the CLI by its full path." ;;
esac

cat <<EOF

Installed
  guard     $DATA/$APP   (LaunchAgent $PLIST$([ "$LAUNCHD" = 1 ] || echo ", not loaded"))
  command   $LINK
  hooks     $DEST/sim-audio-guard.sh (PreToolUse), $DEST/sim-audio-hook.sh (PostToolUse)
  settings  $DATA/config.json
$path_note
Next
  simaudio doctor      check the whole chain (boot a simulator first for the live test)
  Allow "Claude Sim Audio" in System Settings > Privacy & Security > Screen & System Audio
  Recording the first time it asks: simaudio record and the fallback tap need it.
  Restart your Claude Code sessions: hooks are read when a session starts.
EOF
