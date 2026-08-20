# Voxel

A macOS panic button for games. One hotkey collapses the machine from "playing"
to "working" in about 50 milliseconds; a second hotkey puts everything back
exactly as it was.

The product is **Voxel**. The background agent that actually runs is
**CoreAudioHelper** — an LSUIElement process with no Dock icon, no menu bar, and
no windows, which reads as unremarkable in Activity Monitor.

> The bundle identifier stays honest (`com.emberguild.voxel.helper`). Only the
> display and process name are boring. Impersonating an Apple daemon at the
> identifier level is what makes XProtect and EDR tooling score a binary as
> suspicious, and there's no upside to it.

**Scope note:** this is built for hiding a game from someone walking into the
room. It is not built to defeat managed-device monitoring, and pointing it at an
MDM-managed work or school Mac is a bad idea — the leak report will tell you
about the screen, not about a policy agent watching the process list.

---

## Status

P0 spike, working. The core loop is real and instrumented:

```
panic     50.5 ms
          mute        31.4 ms
          hide         0.0 ms
          reveal      19.1 ms
resume     4.7 ms
```

The headline finding: **the direct hide/activate path is fast enough**, and
`mute` dominates it — 31ms of the 50ms is a CoreAudio property write round-
tripping to Bluetooth headphones. On built-in output it should be far cheaper.

Cover screenshots are built on top of that and cost **1.4ms**, verified against
the window server's own on-screen list rather than trusting AppKit's occlusion
reporting.

---

## Setup

Requires macOS 14+ and a Swift toolchain. Xcode is not needed — Command Line
Tools is enough, and the app bundle is assembled by script.

```bash
git clone <repo> && cd Voxel
./scripts/build-app.sh
```

That produces:

- `build/CoreAudioHelper.app` — the agent
- `build/voxel` — the operator CLI

Put `voxel` somewhere on your `PATH` if you want it handy:

```bash
ln -sf "$PWD/build/voxel" /usr/local/bin/voxel
```

### Permissions

**None.** Not one prompt. This is a deliberate design constraint, not a
coincidence:

| What we need | How we get it | Permission |
|---|---|---|
| Global hotkey | Carbon `RegisterEventHotKey` | none |
| Hide / show apps | `NSRunningApplication.hide()` / `.unhide()` | none |
| Switch front app | `NSRunningApplication.activate()` | none |
| Mute and restore | CoreAudio device properties | none |
| Leak checks | running-app list, window geometry, prefs | none |

The tempting alternative for hotkeys, `NSEvent.addGlobalMonitorForEvents`,
requires Accessibility — and a panic button whose first act is to open a "Voxel
wants to control your computer" dialog defeats its own purpose. Anything that
needs Screen Recording, Accessibility, or Full Disk Access has to earn its way
in as an explicit opt-in.

---

## Quickstart

```bash
./scripts/build-app.sh                 # build the agent and the CLI
./build/voxel capture Gaming --in 5    # switch to your game during the countdown
./build/voxel covers --open            # drop screenshots in, then: voxel covers
./build/voxel leaks                    # see what would still give you away
open ./build/CoreAudioHelper.app       # start the agent
```

Then press **⌃⌥⌘H** to panic and **⌃⌥⌘J** to come back.

---

## Command reference

Voxel is two programs. `CoreAudioHelper` is the agent that holds the hotkeys and
does the work; `voxel` is the CLI you use to set it up and inspect it. The CLI
never talks to the agent — they share state through the config file on disk.

### `voxel capture [name] [--in <seconds>]`

Snapshots every running app and sorts it into a cover story, then writes the
result to `~/Library/Application Support/Voxel/config.json`.

| Argument | Default | Meaning |
|---|---|---|
| `name` | `Default` | Profile name. Cosmetic — it's what shows up in `leaks` and `dry-run`. |
| `--in <seconds>` | `0` | Count down before capturing, clamped to 0–60. |

Use `--in` whenever you run this from a terminal. Without it the terminal is the
frontmost app by definition, which is the one piece of information the classifier
most wants and the one it would be getting wrong.

Each app lands in one of three buckets:

- **conceal** — hidden on panic. Assigned when the bundle ID or app path matches
  a known game marker (`steam`, `blizzard`, `riotgames`, `crossover`, `unity.`,
  `/applications/games/`, and others), or when the app was frontmost at capture
  time and isn't a terminal.
- **reveal** — brought forward on panic. Assigned from a list of known
  cover-story apps: browsers, Notes, Preview, the iWork and Office suites, Mail,
  Obsidian, VS Code, Terminal.
- **ignore** — untouched. System agents, and anything the heuristics didn't
  recognise.

It will get things wrong. The output prints its reasoning per app so you can see
*why*, and the config file is plain JSON — fix it there. The agent re-reads the
file on every panic, so edits take effect immediately with no restart.

```
  conceal  Steam
           matched "steam"  com.valvesoftware.steam
  reveal   Google Chrome            ←front
           known cover-story app  com.google.Chrome
  ignore   Spotify
           unrecognised -- sort this one yourself  com.spotify.client
```

### `voxel leaks`

Audits the machine's *current* state for things a panic press will not fix, and
prints them worst-first. See [The leak report](#the-leak-report) for the full
list of checks and why each one matters.

Run it with the game actually open — several checks (fullscreen detection, Space
detection) have nothing to look at otherwise, and the report will say so rather
than quietly passing.

Severities: **CRITICAL** means panic will visibly fail or be far too slow.
**WARNING** means panic works but something else still points at the game.
**INFO** is context, not a problem.

### `voxel dry-run [--hold <seconds>]`

Runs the real panic sequence in-process, waits, then resumes — with per-phase
timings. Lets you watch the thing and measure it without needing a free hand or
a running agent.

| Argument | Default | Meaning |
|---|---|---|
| `--hold <seconds>` | `2` | How long to stay concealed, clamped to 0.2–30. |

```
  panic     50.5 ms
            mute        31.4 ms
            hide         0.0 ms
            reveal      19.1 ms
  resume     4.7 ms
```

Timings are colour-coded against the 150ms target. They're indicative, not
authoritative: the CLI has no run loop, and activation from a non-accessory
process behaves a little differently than it does in the agent. The number that
actually counts comes from screen-recording the agent at 60fps and counting
frames.

This performs real actions — it will genuinely mute your audio and rearrange
your windows — but it restores everything when the hold expires.

### `voxel covers [name|number] [options]`

Manages the cover screenshots and, crucially, **which one shows**.

```bash
voxel covers                      # list what you have, and the current rule
voxel covers homework.png         # always show this one
voxel covers 2                    # same, by position in the listing
voxel covers --mode cycle         # advance to the next image on every panic
voxel covers --mode random        # pick at random, never twice running
voxel covers --dismiss 1500       # tear the image down after 1.5s
voxel covers --hold               # keep it up until you press resume (default)
voxel covers --off                # back to app-switching only
voxel covers --open               # open the folder in Finder
```

Three ways to choose, and they're the whole answer to "I have a set, which one?":

| Mode | Behaviour | Good for |
|---|---|---|
| `fixed` | Always the image you named. | One cover story you always use. |
| `cycle` | Next image each panic, wrapping. | Rotating so the same person doesn't see the same screen twice. |
| `random` | Random, never repeating back-to-back. | Same, without a predictable order. |

The active image is resolved and decoded **before** the panic, not during it, so
choosing between fifty screenshots costs the same as choosing between two.
`cycle` position lives in memory and resets when the agent restarts.

### `voxel apps`

Lists every running app with its bundle identifier, so you can fill in `conceal`
and `reveal` by hand without guessing. The quick single-app version is
`osascript -e 'id of app "Steam"'`.

### `voxel config`

Prints the config file path and its contents. Nothing clever; it saves you
remembering where Application Support put it.

### `voxel help`

Command summary. Also what you get from no arguments at all.

### The agent

```bash
open build/CoreAudioHelper.app        # start it (background, no Dock icon)
pkill -x CoreAudioHelper              # stop it
tail -f ~/Library/Logs/Voxel/agent.log
```

To watch it in the foreground instead, run the binary directly:

```bash
./build/CoreAudioHelper.app/Contents/MacOS/CoreAudioHelper
```

It logs every panic and resume with timings, to both stdout and the log file.
Ctrl-C is safe: SIGINT and SIGTERM handlers restore your audio and unhide your
apps before exiting, so being killed mid-conceal can't strand the machine muted.

There is no login item yet — start it by hand, or add it to System Settings >
General > Login Items.

### The config file

`~/Library/Application Support/Voxel/config.json`

```json
{
  "panicKey":  { "keyCode": 4,  "control": true, "option": true, "command": true },
  "resumeKey": { "keyCode": 38, "control": true, "option": true, "command": true },
  "profile": {
    "name": "Gaming",
    "conceal": ["com.valvesoftware.steam"],
    "reveal": ["com.google.Chrome", "com.apple.Notes"],
    "mute": true
  },
  "cover": {
    "enabled": true,
    "selection": "cycle",
    "active": "homework.png",
    "dismissAfterMilliseconds": 1500
  }
}
```

| Field | Meaning |
|---|---|
| `keyCode` | Carbon `kVK_ANSI_*` virtual keycode. Physical key position, so it doesn't move with your keyboard layout. `H` = 4, `J` = 38, `Z` = 6, `X` = 7, `Space` = 49, `F13` = 105. |
| `control` / `option` / `command` / `shift` | Modifiers. At least one is strongly recommended, or you'll fire the panic mid-sentence. |
| `conceal` | Bundle identifiers to hide. Find one with `osascript -e 'id of app "Steam"'`. |
| `reveal` | Bundle identifiers to bring forward. **`reveal[0]` ends up frontmost.** |
| `mute` | Whether to silence and restore system output. |
| `cover.selection` | `fixed`, `cycle`, or `random`. See [`voxel covers`](#voxel-covers-namenumber-options). |
| `cover.active` | Filename in the covers folder. Only used by `fixed`. |
| `cover.dismissAfterMilliseconds` | Omit to hold the image until resume. |

Hotkey changes need an agent restart. Profile changes don't.

---

## Cover screenshots

Instead of juggling real apps, Voxel can slam a **screenshot** over every display
the instant you press panic.

You supply the images. Screenshot your own cover story with ⌘⇧3, drop the files
into `~/Library/Application Support/Voxel/covers/`, and run `voxel covers`.

```bash
voxel covers --open        # opens the folder
voxel covers --mode cycle  # rotate through everything in it
```

This is faster and more reliable than moving windows around — the window is built
and the image decoded ahead of time, so the panic itself is a single
`orderFrontRegardless()` measured at **1.4ms**. It also sits above the Dock and
the menu bar, which incidentally covers the Dock-icon leak.

**Voxel never captures your screen.** It only draws pictures you already took.
That is why a feature that would otherwise need Screen Recording permission needs
none at all — the original design for this assumed Voxel would take the
screenshot itself, and having you supply it removes the prompt entirely.

Two teardown behaviours:

- **Hold** (default) — the image stays until you press resume. Simple and
  bulletproof, but static: it will not survive someone standing there for ten
  seconds, moving the mouse, or asking you to scroll.
- **Dismiss after N ms** (`--dismiss 1500`) — the image covers the switch and
  then disappears, leaving your real cover-story apps on screen. Best of both,
  but only convincing if the screenshot actually matches what's underneath.

Clicks do **not** pass through to whatever is behind the cover. A stray click
landing in the game would be worse than no cover at all.

---

## How the panic sequence works

Ordered by what gives you away soonest, not by what's easiest:

0. **Cover** — if a screenshot is armed, put it up. Already decoded and already
   laid out, so this is one `orderFront`: the screen changes in a single frame,
   before anything slower gets a chance to be visible. ~1.4ms.
1. **Mute** — synchronously. Sound reaches the hallway before sight reaches the
   doorway. It's the only tell with a head start on the person.
2. **Hide** the concealed apps. `hide()` is animation-free and instant.
3. **Reveal** the cover story, back-to-front so the intended app lands on top.

Resume is the exact inverse: unhide, refocus whatever was frontmost when you
panicked, restore the audio device to precisely the state it was in.

Audio restore tries three strategies in order — the device's real mute switch
(one write, preserves volume for free), then the HAL virtual main volume, then
per-channel volume scalars — and records which one it used so resume can undo
exactly that.

---

## The leak report

The feature that makes this more than a 1987 boss key. Every check is
permission-free:

| Check | Why it matters |
|---|---|
| **Game running but not in `conceal`** | The one misconfiguration that makes panic useless: Voxel doesn't know it should hide the thing you're hiding. |
| Fullscreen / off-Space game | Half-second Space-switch animation macOS won't let us suppress. The worst failure mode. |
| Decoy app not running | Panic would have to cold-launch it — seconds, not milliseconds, and a launching app looks nothing like one you were using. |
| Built-in speakers at volume | Mute is instant, but speakers cost you the head start. |
| Dock always visible | Hiding an app does **not** remove its Dock icon or running indicator. |
| Multiple displays | Panic hides everywhere, but your cover story only fills one screen. |
| Discord / Steam running | Rich Presence and "In-Game" broadcast the title to other people's devices entirely. |
| Zoom / Teams / OBS running | If a share goes live, the hotkey isn't what saves you. |
| Focus not enabled | A notification sliding in over your "homework" undoes the illusion — and can arrive after you've walked away. |

**Voxel does not fix these for you, on purpose.** The Dock one is the clearest
case: toggling auto-hide live restarts the Dock, which takes about a second and
is far more conspicuous than the icon you were trying to hide. Telling you to
turn it on once is strictly better than doing it during a panic.

---

## Architecture

```
Sources/
  VoxelCore/              shared by both executables
    Config.swift          hotkey bindings, profiles, JSON store
    AudioController.swift CoreAudio mute/restore with a 3-strategy fallback
    Concealer.swift       the panic sequence, its inverse, and phase timing
    Cover.swift           screenshot overlay windows and the selection rule
    HotkeyService.swift   Carbon global hotkeys
    ProfileCapture.swift  snapshot running apps → cover story
    LeakReport.swift      permission-free audit
  CoreAudioHelper/        the agent (LSUIElement)
  voxel/                  operator CLI
scripts/build-app.sh      assembles the .app by hand (no Xcode required)
```

The agent installs SIGINT/SIGTERM handlers that resume before exiting — being
killed while concealed would otherwise leave the machine muted and the game
hidden.

---

## Decisions made, and why

**macOS only.** No cross-platform abstraction layer to pay for.

**Threat model is someone walking in**, not screen-sharing and not monitoring
software. That's what puts audio first in the sequence and what makes latency
the metric that matters.

**Capture, don't configure.** No manual profile builder and no shipped presets:
you arrange your machine, hit capture, and correct the guesses. Heuristics only
need to be good enough that correcting beats building from scratch.

**Zero permissions in v1.** See the table above. Everything that prompts is
deferred to an opt-in.

**Terminals are excluded from the "frontmost" heuristic.** Running `voxel
capture` from a shell makes the terminal frontmost by definition, so without
this the tool would confidently classify your terminal as the game.

**No Dock manipulation.** The cure is more visible than the disease.

**Two-handed default chords (⌃⌥⌘H / ⌃⌥⌘J).** Placeholder, and known to be
wrong — see below.

---

## Known open questions

- **Hotkey ergonomics.** ⌃⌥⌘H needs two hands, which is exactly wrong for a
  panic button. Candidates: double-tap Right Shift (needs an event tap, so
  Accessibility), a mouse side button, a spare F-key, or a USB foot pedal.
  Unresolved and the most user-visible remaining question.
- **Fullscreen games.** Currently detected and reported, not solved. It may not
  be solvable — the Space-switch animation is macOS's, not ours.
- **Is 50ms actually the number?** Measured in-process with nothing to hide.
  Needs a real game running and a 60fps screen recording to confirm.

---

## Ideas not built

Deliberately deferred, in rough priority order:

- **Auto-arm** — launching any app in the conceal set arms Voxel silently, so
  the config UI is opened once and never again.
- **Conceal on screen share** — detect Zoom/Teams/OBS starting a capture and
  panic automatically.
- **Remote trigger** — a `127.0.0.1` listener so an iPhone Shortcut, an Apple
  Watch, a Stream Deck, or a foot pedal can fire the panic.
- **Deeper capture** — window titles and open documents, for a decoy that
  restores exactly. Needs Screen Recording (titles) and Automation (browser
  tabs).
- **Live-looking covers** — nudge the decoy on reveal (scroll a line, move the
  caret) so a held screenshot doesn't read as frozen if someone lingers.
- **Per-display covers** — right now every display gets the same image.
- **Session budget** — a play timer, which is the honest framing for the
  landing page as well as a genuinely useful feature.
- **Presence killing** — toggle Discord Rich Presence and Steam status
  automatically instead of just warning about them.
- **Login item** via `SMAppService.agent`.
- **The site** — marketing, docs, signed and notarized DMG, Sparkle updates.

---

## Development

```bash
swift build                  # both executables into .build/debug
swift build -c release
./scripts/build-app.sh       # assemble and ad-hoc sign the .app
./.build/debug/voxel help
```

Ad-hoc signing is fine locally. Distribution needs a Developer ID and
notarization, which needs full Xcode.
