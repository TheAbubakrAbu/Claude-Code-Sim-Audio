# Claude Code Sim Audio

**Keeps the iOS simulators [Claude Code](https://docs.anthropic.com/en/docs/claude-code) runs off your speakers, while Claude can still record and measure what they play.** A small macOS guard routes every simulator's sound into a silent virtual device, catches anything that slips past, and gives Claude a `simaudio record` command so it can test an alarm or a sound effect without you ever hearing it.

[![tests](https://github.com/TheAbubakrAbu/Claude-Code-Sim-Audio/actions/workflows/tests.yml/badge.svg)](https://github.com/TheAbubakrAbu/Claude-Code-Sim-Audio/actions/workflows/tests.yml)

Created by **Abubakr Elmallah** on **November 17, 2026**.

## At a glance

| | |
|---|---|
| **1** app | `Claude Sim Audio.app`: the guard and the `simaudio` command in one binary (Swift, with a little Objective-C and C) |
| **1** prerequisite | [BlackHole 2ch](https://github.com/ExistentialAudio/BlackHole), a free silent audio device (`brew install blackhole-2ch`) |
| **3** layers of muting | a BlackHole route, a muted Core Audio tap, and quitting what still plays |
| **2** hooks | a `PreToolUse` prompt before anything is unmuted, a `PostToolUse` note that teaches Claude to record |
| **0** permissions to mute | routing needs none; only recording does |
| **44** tests | hooks, installer, LaunchAgent, and a real build, on macOS on every push |

---

## Table of Contents

- [Why this exists](#why-this-exists)
- [Features](#features)
- [What you'll see](#what-youll-see)
- [Getting Started](#getting-started)
- [Commands](#commands)
  - [Installer](#installer)
  - [simaudio](#simaudio)
  - [build.sh](#buildsh)
- [Settings](#settings)
  - [config.json](#configjson)
  - [The signing identity](#the-signing-identity)
  - [Environment variables](#environment-variables)
- [How it works](#how-it-works)
  - [Mode "claude" and Claude Code Idle Reaper](#mode-claude-and-claude-code-idle-reaper)
  - [The two hooks](#the-two-hooks)
- [Teach Claude the other half](#teach-claude-the-other-half)
- [Known Limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)
- [Privacy & Data](#privacy--data)
- [Testing](#testing)
- [Uninstall](#uninstall)
- [License](#license)
- [Feedback & Contact](#feedback--contact)

---

## Why this exists

**Claude Code drives iOS simulators headless, and a headless simulator still plays through your speakers.**

While Claude builds and tests an app it boots simulators, launches the app, and pokes at it, often while you are in a meeting or listening to something else. Every sound the app makes comes out of your Mac: background ambience that loops for as long as the simulator is up, an alarm that fires during a test, a notification chime on every launch. Muting the Mac is no answer (you lose your own sound too), and simply turning simulator audio off is no answer either, because then Claude cannot tell whether the sound it was asked to build actually plays.

This guard takes the sound away from your speakers without taking it away from Claude. Every simulator plays into **BlackHole 2ch**, a virtual audio device nobody listens to. The app inside still plays normally, so `simaudio record` can capture it and report how loud it was and when it started and stopped. **The failure direction is always toward silence:** if the route ever fails, a muted Core Audio tap takes over, and if that fails too, whatever is playing out loud is quit.

## Features

- **Silent by routing, not by tapping:** each simulator's output is pointed at BlackHole through CoreSimulator's own per-simulator audio route. Nothing is captured, so macOS shows no recording dot, and the route sticks across reboots.
- **A safety net under the route:** every simulator process is its own Core Audio client on the Mac, so the guard sees where each one really plays. One caught playing to a real output is held with a muted Core Audio tap.
- **A last resort under the net:** a muted simulator still out loud after 3 seconds, with no working tap over it, has the playing process quit; a second time within two minutes, the simulator is shut down. Either way a banner says so.
- **Claude can test sound:** `simaudio record <sim> [seconds]` saves a WAV and reports seconds audible, peak and average level, and when the sound started and stopped, with `--json` for scripts.
- **One command checks everything:** `simaudio doctor` checks the guard, BlackHole, the Mac's own output, every simulator's route, and plays a silent test sound inside each simulator to prove where it goes.
- **Claude cannot unmute on its own:** a `PreToolUse` hook turns `simaudio hear`, `simaudio mode off|claude`, and anything that stops the guard into a permission prompt.
- **Cheap at rest:** the guard does not poll for sound. Core Audio tells it when a simulator process appears or starts or stops playing, so it wakes every 2 seconds only to check routes and write its heartbeat.
- **Keeps itself alive:** launchd starts it at login and restarts it; the guard exits on purpose, to be restarted, if its main loop stalls for a minute or CoreSimulator stops answering for 90 seconds.

## What you'll see

`simaudio` with no arguments:

```text
Sim audio guard: on, muting every simulator
  iPhone 17 Pro                     muted (into BlackHole)   My App (playing), SpringBoard
Recent:
  2026-11-17 23:21:04  iPhone 17 Pro: its sound now goes to BlackHole (silent)
  2026-11-17 23:21:09  iPhone 17 Pro: My App started playing (silent, into BlackHole)
Test a sound: simaudio record <sim> [seconds]   Check everything: simaudio doctor   Full log: simaudio log
```

`simaudio record "iPhone 17 Pro" 5`, while the app plays a sound:

```text
Recording iPhone 17 Pro for 5 s...
Sound: 2.1 s audible, peak -18.4 dBFS, average -31.2 dBFS
  heard from 0.6 s to 2.7 s after the recording started (5 s long)
Apps with audio open: My App, SpringBoard
Saved: ~/.claude/sim-audio/recordings/20261117-232110-iPhone-17-Pro.wav
```

And a banner titled **Simulator audio** only when something went wrong, at most one of each kind every 15 minutes:

| Banner | When |
| --- | --- |
| **My App in iPhone 17 Pro played out loud for 3 s and was quit. Run: simaudio doctor** | the route and the tap both failed |
| **iPhone 17 Pro kept playing out loud, so it was shut down. Run: simaudio doctor** | it happened again within two minutes |
| **Cannot reach CoreSimulator, so simulator audio routes cannot be checked. Run: simaudio doctor** | CoreSimulator stopped answering (an Xcode update can do this) |
| **Cannot check or set the audio route of iPhone 17 Pro. Run: simaudio doctor** | one simulator's route cannot be read |

## Getting Started

1. **Check the prerequisites:** macOS 26 or later, Xcode 26 or later with an iOS simulator platform installed (Xcode > Settings > Components), and BlackHole 2ch:

   ```bash
   brew install blackhole-2ch
   ```

   Never pick BlackHole as your Mac's output: the guard uses it for the simulators only.

2. **Clone the project:**

   ```bash
   git clone https://github.com/TheAbubakrAbu/Claude-Code-Sim-Audio.git
   cd Claude-Code-Sim-Audio
   ```

3. **Run the installer**, with your Apple Development certificate if you have one (see [The signing identity](#the-signing-identity) for why):

   ```bash
   ./install.sh --identity "Apple Development: Your Name (TEAMID)"   # or just ./install.sh
   ```

   It builds the app into `~/.claude/sim-audio/` (never into this folder), links `simaudio` into `/opt/homebrew/bin` (or `~/.local/bin`), writes and loads the LaunchAgent `~/Library/LaunchAgents/local.sim-audio.plist`, creates `~/.claude/sim-audio/config.json` from [config.example.json](config.example.json) if there is none, copies the two hooks to `~/.claude/hooks/`, and wires them into `~/.claude/settings.json`. A backup of `settings.json` is written first, and running it again changes nothing there.

4. **Check it:**

   ```bash
   simaudio doctor
   ```

   Boot a simulator first for the full live check.

5. **Allow recording when macOS asks.** The first `simaudio record` (or `doctor`'s recording check) asks to let **Claude Sim Audio** record the screen and system audio. Allow it in System Settings > Privacy & Security > Screen & System Audio Recording. Muting through BlackHole does not need it; recording and the fallback tap do.

6. **Restart your Claude Code sessions.** Hooks are read when a session starts. Run `/hooks` inside Claude Code to see them listed.

## Commands

### Installer

| Command | Description |
| --- | --- |
| `./install.sh` | Build the app, link `simaudio`, write and load the LaunchAgent, copy the hooks and wire them into `settings.json` |
| `./install.sh --identity ID` | Sign with this certificate (its name or SHA-1), so the recording permission survives rebuilds |
| `./install.sh --dest DIR` | Put the hook scripts in `DIR` instead of `~/.claude/hooks` |
| `./install.sh --data DIR` | Keep the guard's folder (app, settings, log, recordings) in `DIR` instead of `~/.claude/sim-audio`; the LaunchAgent, the hooks, and `simaudio` are told through `SIM_AUDIO_HOME` |
| `./install.sh --settings FILE` | Wire the hooks into another `settings.json` |
| `./install.sh --launch-agents DIR` | Write the LaunchAgent into `DIR` instead of `~/Library/LaunchAgents` |
| `./install.sh --bin DIR` | Put `simaudio` in `DIR` (default `/opt/homebrew/bin` when it is writable, otherwise `~/.local/bin`) |
| `./install.sh --no-build` | Keep the app already in the data folder |
| `./install.sh --no-launchd` | Write the LaunchAgent, but do not load it (or, with `--uninstall`, unload it) |
| `./install.sh --uninstall` | Stop the guard; remove the LaunchAgent, `simaudio`, and the `settings.json` entries; keep the hook scripts and the data folder |
| `./install.sh --uninstall --purge` | Also delete the hook scripts and the whole data folder, recordings included |

An existing `simaudio` that is not this tool's is left alone. Reinstalling restarts the guard with the new build; simulators already routed to BlackHole stay silent in between.

### simaudio

| Command | Description |
| --- | --- |
| `simaudio` | What is muted, what is playing, the last alarm, and recent events (also `simaudio status`) |
| `simaudio doctor [--quick]` | Check the whole chain: the guard, launchd, the mode, BlackHole, the Mac's output and input, anything recording from BlackHole, CoreSimulator, recent alarms, every booted simulator's route, and (unless `--quick`) a silent test sound played inside each simulator plus a quiet tone the guard must record. Exits 1 on any problem |
| `simaudio record <sim> [secs]` | Capture a simulator's audio (default 10 s, up to 600) to a WAV and report its levels; nothing reaches the speakers. With no `<sim>`, the only muted simulator, when there is just one |
| `simaudio record <sim> --out <file.wav>` | Save it there instead of `~/.claude/sim-audio/recordings` |
| `simaudio record <sim> --json` | A machine-readable result: `heard_sound`, `audible_seconds`, `peak_dbfs`, `average_dbfs`, `first_sound_at`, `last_sound_at`, `captured_seconds`, `apps`, `file`, or `error` |
| `simaudio log [lines]` | The event log, last 40 lines by default: what started and stopped playing, routes set, alarms |
| `simaudio hear <sim> [minutes]` | Let one simulator play out loud for a while (default 10 minutes) |
| `simaudio mute <sim>` | End `hear` early |
| `simaudio mode all\|claude\|off` | Mute every simulator (the default), only Claude's (see [Mode "claude"](#mode-claude-and-claude-code-idle-reaper)), or none |
| `simaudio restart` | Restart the guard, through launchd when the LaunchAgent is loaded (after a rebuild) |
| `simaudio help` | The command list |

`<sim>` is part of a simulator's name (`"iPhone 17 Pro"`, `iPad`) or its UDID. When a name matches several simulators and exactly one is booted, that one wins. Short forms: `rec`, `check`, `unmute`, `start`.

### build.sh

| Command | Description |
| --- | --- |
| `./build.sh` | Build and sign `Claude Sim Audio.app` into `~/.claude/sim-audio` |
| `./build.sh --out DIR` | Build into `DIR` instead; a folder inside this repository is refused |
| `./build.sh --identity ID` | Sign with this certificate |

The build is staged in a temporary folder and swapped in at the end, so a failed build never breaks the installed guard. A running guard keeps the old binary until `simaudio restart`. `./install.sh` runs it for you.

## Settings

### config.json

The guard's settings live in **`~/.claude/sim-audio/config.json`**, written by `simaudio mode`, `hear`, and `mute`. You rarely edit it by hand. The guard notices a change on its next look, within 2 seconds; there is nothing to restart.

| Key | Default | What it does |
| --- | --- | --- |
| `mode` | `"all"` | `"all"` mutes every simulator. `"claude"` mutes only Claude's (see below). `"off"` mutes none and puts back the routes the guard set. |
| `hear` | `{}` | `{ "<UDID>": <unix time> }`: simulators allowed out loud until that time. Written by `simaudio hear`, cleared by `simaudio mute`; expired entries are ignored. |
| `test` | absent | `{ "no_route": ["<UDID>"], "no_tap": true, "until": <unix time> }`: switches that deliberately leave a simulator off BlackHole and keep the fallback tap off, to prove the nets under them. They expire by themselves, every event is logged as `ALARM TEST`, and `simaudio doctor` fails while they are on. |

### The signing identity

**macOS ties the Screen & System Audio Recording permission to the app's code signature.** An app signed with the same Apple Development certificate keeps the permission across rebuilds. An ad hoc signature is new on every build, so macOS treats each rebuild as a new app: it asks again, and until you allow it, `simaudio record` and the fallback tap capture only silence. Muting through BlackHole works either way.

List your certificates and pass one, by name or by its SHA-1, once:

```bash
security find-identity -v -p codesigning
./install.sh --identity "Apple Development: Your Name (TEAMID)"
```

`build.sh` remembers an identity that signed successfully in `~/.claude/sim-audio/signing-identity`, so later rebuilds use it without the flag. Precedence: `--identity`, then `$SIM_AUDIO_SIGN_IDENTITY`, then the remembered one, then ad hoc. If signing with the identity fails, the build falls back to ad hoc and says so.

### Environment variables

| Variable | What it does |
| --- | --- |
| `SIM_AUDIO_HOME` | The guard's folder, instead of `~/.claude/sim-audio`. Read by the guard, `simaudio`, and the `PostToolUse` hook; `install.sh --data` sets it everywhere for you |
| `SIM_AUDIO_SIGN_IDENTITY` | The certificate `build.sh` signs with when `--identity` is not given |

## How it works

One binary plays two roles: `claude-sim-audio daemon` is the guard, run by the LaunchAgent `local.sim-audio`; every other subcommand is the `simaudio` CLI, which talks to the guard through small JSON files in `~/.claude/sim-audio`.

1. **The route.** Each simulator that should be quiet has its audio output pointed at BlackHole 2ch through CoreSimulator's private per-simulator host route, the same one the old Simulator app's I/O > Audio Output menu used (`src/router.m`). Nothing is captured, so there is no recording dot. The route sticks across reboots and moves apps that are already playing. The guard only ever puts a simulator back on the system default output if it is on BlackHole, since only this guard routes simulators there.
2. **The fallback tap.** Every app and system process inside a simulator is its own Core Audio client on the Mac, so the guard can read where each one plays. A muted simulator caught playing to anything but BlackHole (BlackHole missing, a route that failed) gets a Core Audio process tap with `CATapMuted`, inside a private aggregate device the guard keeps running: a muted tap only works while something reads it. That shows the purple recording dot, which is why it is only the fallback. The guard watches that each tap keeps reading audio and rebuilds one that stalls.
3. **The last resort.** The tap has a history of stalling, so it does not get the final word. A muted simulator that still plays to a real output after 3 seconds, with no tap seen reading its audio, has the playing process quit. If it plays out loud again within two minutes, the simulator is shut down. Both are logged as `ALERT` lines and posted as banners.

Problems the guard cannot fix itself (CoreSimulator not answering, a route it cannot read) are logged as `ALERT` lines and get a banner too. One guard runs at a time: a second one waits on a lock and takes over when the first exits.

`simaudio record` asks the guard for a recording through `requests/`. The guard listens in on the simulator's tap if it already has one, or opens a tap just for the recording (the dot shows only then), writes a 16-bit WAV, and measures it: a tenth of a second counts as sound when it is above -60 dBFS. Recordings older than 3 days are deleted.

### Mode "claude" and Claude Code Idle Reaper

Mode `"claude"` is the older, looser rule. It mutes:

- the simulators a Claude session booted, as listed in [Claude Code Idle Reaper](https://github.com/TheAbubakrAbu/Claude-Code-Idle-Reaper)'s `~/.claude/idle-reaper/state.json`;
- any simulator with "Claude" in its name;
- every simulator while no simulator window (Xcode's DeviceHub or the Simulator app) is open, since only Claude sessions drive headless simulators.

Without Idle Reaper installed, the first rule simply finds nothing and the other two still apply. Mode `"all"` needs neither and is the default.

### The two hooks

| Hook | Event | What it does |
| --- | --- | --- |
| `sim-audio-guard.sh` → `sim-audio-guard.py` | `PreToolUse` (Bash) | Asks before `simaudio hear` / `unmute`, `simaudio mode off` / `claude`, `launchctl bootout` / `unload` / `disable` / `remove` / `kill` / `stop` of `local.sim-audio`, `pkill` / `killall` of the guard, or `rm` / `mv` / `trash` of its app or LaunchAgent. It returns `"ask"`, not `"deny"`: when you asked for it, you approve the prompt. Flip `DECISION` in the script to `"deny"` for an absolute block. `restart`, `mute`, `mode all`, `record`, `doctor`, and anything that only reads pass silently. |
| `sim-audio-hook.sh` → `sim-audio-hook.py` | `PostToolUse` (Bash) | The first time in a session that a command boots, launches, installs on, or otherwise drives a simulator (`simctl boot`, `launch`, `install`, `openurl`, `push`, `spawn`, or `xcodebuild` with a simulator destination), adds a note to Claude's context: audio is muted, never reroute it, record to test, and what an app quitting 3 seconds into a sound means. If the guard is not running, the note says so. |

Each `.sh` shim checks the command with one `case` and hands only likely matches to Python, so every other command costs nothing.

## Teach Claude the other half

The hooks cover the moment Claude touches a simulator. For the standing rules (record, never unmute, check `simaudio log` before debugging an app that died mid-sound), paste [docs/CLAUDE.md-snippet.md](docs/CLAUDE.md-snippet.md) into your `~/.claude/CLAUDE.md`.

## Known Limitations

- **macOS 26, Xcode 26, and Apple silicon simulators.** The app is built for macOS 26 or later. The doctor's test sound is built for arm64 simulators, so on an Intel Mac the live part of `simaudio doctor` is skipped.
- **The route uses a private CoreSimulator interface.** An Xcode update can change it. When CoreSimulator stops answering, routes already set stay, the guard relies on the fallback tap, and it posts a banner; `simaudio doctor` reports it.
- **BlackHole hands back whatever is played into it.** An app recording from BlackHole (a screen recorder, a streaming tool) hears every muted simulator. `simaudio doctor` warns when anything is.
- **The last resort quits apps.** An app that dies about 3 seconds into playing a sound was probably quit by the guard: look for an `ALERT` line in `simaudio log` before debugging the app.
- **Routes outlive the guard.** A simulator routed to BlackHole stays silent after you uninstall, until its output is changed. See [Uninstall](#uninstall).
- **The guard's shim matches case-sensitively.** The quick filter in `sim-audio-guard.sh` looks for `simaudio`, `sim-audio`, or `Sim Audio` exactly as written, so a command typed as `SIMAUDIO hear` would skip the prompt (macOS file names are case-insensitive, so it would still run). The hook is a backstop for Claude's habits, not a sandbox.
- **A moved data folder relies on the LaunchAgent.** With `--data` somewhere else, `simaudio restart` passes `SIM_AUDIO_HOME` along through launchd; keep the LaunchAgent loaded.
- **The banners belong to Script Editor.** They are posted through `osascript`, so macOS lists them under Script Editor in System Settings > Notifications.
- **Hooks are read when a session starts.** After installing or uninstalling, restart open sessions.

## Troubleshooting

- **I can hear a simulator.** Run `simaudio doctor`. Check the mode (`simaudio`), and whether a `hear` is still running (`simaudio mute <sim>` ends it).
- **The whole Mac went silent.** The Mac's output is set to BlackHole 2ch. Pick your speakers in the Sound menu; `simaudio doctor` flags this.
- **The purple recording dot stays on.** The fallback tap is holding a simulator because its BlackHole route is missing or failed. `simaudio doctor` says which, and why.
- **`simaudio record` reports silence.** Make sure the app is really playing (`simaudio` shows `(playing)`), then allow **Claude Sim Audio** in System Settings > Privacy & Security > Screen & System Audio Recording. If macOS asks again after every rebuild, set a [signing identity](#the-signing-identity).
- **The guard is not running.** Run `simaudio restart`. Check `~/.claude/sim-audio/daemon.log`, `simaudio log`, and `launchctl print gui/$(id -u)/local.sim-audio`.
- **An app quit about 3 seconds into a sound.** That was the last resort. `simaudio log` has the `ALERT` line naming the app and the simulator; `simaudio doctor` shows what failed underneath.
- **After an Xcode update, routing stopped.** `simaudio log` shows `ALERT: CoreSimulator is not answering`. Run `simaudio doctor`; until it is fixed, the fallback tap keeps simulators muted.

## Privacy & Data

**Claude Code Sim Audio** keeps everything on your Mac:
- **Nothing leaves your computer:** there is no network code. Banners are posted locally through `osascript`.
- **What is recorded:** only what you or Claude ask for with `simaudio record` (and `doctor`'s short, quiet test tone), from one simulator at a time. Recordings stay in `~/.claude/sim-audio/recordings` and are deleted after 3 days.
- **What is kept in `~/.claude/sim-audio`:** `config.json` (mode, hear, test), `status.json` (the guard's heartbeat and what each simulator is doing), `events.log` (what started and stopped playing, kept to about 500 KB plus one older file), `routes.json` (the simulators it routed), `alerts.json` (when each kind of banner last showed), `hook-seen/` (which Claude sessions were told about the guard, forgotten after a week), `requests/` (the hand-off between `simaudio` and the guard), `daemon.log`, and `signing-identity` (the certificate name or hash you chose).
- **Your files stay out of git:** `.gitignore` excludes all of these, and `build.sh` refuses to build inside the repository.

## Testing

```bash
python3 -m unittest discover -s tests -v    # 44 tests; nothing is loaded, unmuted, or rerouted
bash -n install.sh build.sh hooks/*.sh      # the shell scripts parse
```

The hook tests feed payloads to the hooks exactly as Claude Code would, with `SIM_AUDIO_HOME` pointing at a throwaway folder. The installer tests run `install.sh` against a throwaway `HOME`, with `--no-build --no-launchd` and a fake `launchctl` that fails the test if it is ever called, and check the result down to the commands wired into `settings.json`. The build test compiles the whole app into a temporary folder with an ad hoc signature (about a minute; skipped without Xcode 26 and the iOS simulator SDK), checks the bundle and its signature, runs only its `help`, and deletes it. A hygiene test keeps machine-specific paths and signing identities out of the repository. To check a real install, run `simaudio doctor` with a simulator booted.

The [GitHub Actions workflow](.github/workflows/tests.yml) runs all of it on macOS on every push.

## Uninstall

First, with your simulators booted and the guard still running, put their audio back on the Mac's output, since routes outlive the guard:

```bash
simaudio mode off       # the guard moves every simulator it routed back to the system default
```

Then:

```bash
./install.sh --uninstall          # stops the guard; removes the LaunchAgent, simaudio, and the settings entries
./install.sh --uninstall --purge  # also deletes the hook scripts and ~/.claude/sim-audio, recordings included
```

BlackHole stays installed; `brew uninstall blackhole-2ch` removes it.

## License

This project is licensed under the [MIT License](LICENSE). Feel free to use, modify, and distribute the code, but please provide attribution.

## Feedback & Contact

I'd love to hear your thoughts! Open an issue, or reach out with feedback, feature requests, or questions:
- **Email:** contact@abubakrelmallah.com
- **Website:** [abubakrelmallah.com](https://abubakrelmallah.com/)
- **LinkedIn:** [Abubakr Elmallah](https://www.linkedin.com/in/abubakr-elmallah-416a0b273/)
