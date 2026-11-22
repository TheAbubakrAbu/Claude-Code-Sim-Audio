# CLAUDE.md snippet

The guard keeps simulators quiet by itself. This section teaches Claude the rest: how to test sound without unmuting anything, what never to touch, and what to suspect when an app dies a few seconds into playing. Paste it into `~/.claude/CLAUDE.md` (or a project's `CLAUDE.md`) and adjust the first paragraph to your own story.

---

## Simulator audio: muted on my speakers, still testable

Claude's simulators kept playing app sounds (background ambience, alarms, notification chimes) through my speakers. A guard mutes them now: Claude Code Sim Audio (LaunchAgent `local.sim-audio`, files in `~/.claude/sim-audio`) routes the audio output of **every simulator, the ones I boot myself included** (mode `all`), to **BlackHole 2ch**, a silent virtual audio device. Nothing they play reaches my speakers, headphones or any other output, but the audio still plays inside the simulator and can be recorded. If a muted simulator is ever caught playing to a real output, the guard holds it with a Core Audio tap instead (that shows the purple recording dot in my menu bar). If it is still out loud 3 seconds later with no working tap, the guard quits whatever is playing, and shuts the simulator down if it happens again within two minutes; either way it posts a "Simulator audio" banner. So an app that dies about 3 seconds into playing sound was probably quit by the guard: look for an `ALERT` line in `simaudio log` before debugging the app.

- **Never select BlackHole 2ch as the Mac's output, and never reroute a simulator's audio yourself.** The guard owns the routes.
- **To test sound, record it; never unmute it.** `simaudio record <sim> [seconds]` captures that simulator's audio to a WAV in `~/.claude/sim-audio/recordings` and reports how many seconds were audible, the peak and average level, and when the sound started and stopped. Start the recording in the background, then trigger the sound. `--json` gives a machine-readable result. The purple dot shows only while it records.
- `simaudio` shows what is muted and what is playing right now. `simaudio log` shows what started and stopped playing and when, which is enough to confirm that an alarm or a notification sound fired.
- `simaudio doctor` checks the whole chain: the guard, BlackHole, every booted simulator's route, and a silent test sound played inside each simulator to prove where it really goes. Run it when muting is in doubt or after an Xcode update. `--quick` skips the live sounds.
- Do not run `simaudio hear`, `simaudio mode off` or `simaudio mode claude` unless I ask: those play out loud. A `PreToolUse` hook (`~/.claude/hooks/sim-audio-guard.sh`) turns them, and anything that stops or unloads the guard, into a permission prompt. Treat the prompt as a backstop, not as permission. When I want to hear a simulator I run `simaudio hear <sim>` myself (10 minutes by default, `simaudio mute <sim>` ends it).
- If `simaudio` says the guard is not running, run `simaudio restart`.
