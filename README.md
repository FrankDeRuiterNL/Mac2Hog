<img width="1942" height="809" alt="image" src="https://github.com/user-attachments/assets/4a10e0dc-0acb-4295-bbb2-114ee52d5c7e" />

# Mac2Hog

A native macOS app that turns a song into a light show on an **ETC / High End Systems Hog 4** console
(Hog 4, Full Boar 4, Road Hog 4, Nano Hog 4, Hedgehog 4/4X, Hog 4 PC), controlled over **OSC**.

1. **Import a song** (`.wav` or `.mp3`, also `.aiff`, `.m4a`).
2. Mac2Hog **analyses** it: main tempo (with alternatives), beat grid and bars, **snare hits**, kick hits,
   **breaks**, and **song parts** (intro, verse, build-up, chorus/drop, break, bridge, outro).
3. It generates **SMPTE timecode** for the whole song (24/25/29.97df/30 fps, starting at e.g. `01:00:00:00`).
4. **Import your Hog 4 show** (XML export or CSV) and attach its **cuelists, scenes and macros** to cues
   on the song timeline. Mac2Hog converts them into the correct Hog 4 OSC messages.
5. Run the show with the big **STOP** (red) and **PLAY** (green) buttons:
   - **Timecode mode** – press Play (Space) and every cue fires automatically at its timecode.
   - **Manual mode** – the cues form a cue stack; press **GO** / **Space** to fire the next cue.
6. Or build a **setlist** of several songs that follow each other, with **Starting**, **Waiting** (between songs)
   and **Ending** light states.

### Cue start: Timecode, Follow, Wait

Every cue has a start mode (inspector › Start, shown in the cue list's *Start* column):

| Start | Fires |
|---|---|
| **Timecode** | at its own position in the song |
| **Follow +5s** | 5 s after the previous cue *started* |
| **Wait +10s** | 10 s after the previous cue *finished*, i.e. its start + its **Duration** (set the duration to the cue's fade/run time on the Hog) |

Follow / Wait cues stay chained behind the cue before them in the list. In timecode mode their times are
computed automatically. In manual mode a GO fires the cue plus its whole Follow / Wait chain with the right delays.

### Predefined triggers

*Settings › Predefined* holds reusable triggers: a name plus the OSC command(s) to send (e.g. “Blackout”,
“Strobe hit”). Add them to the selected cue with **+ Add › Predefined** in the inspector, create a new cue from
one with **Add predefined** under the cue list, or save a cue's commands with *Save commands as predefined trigger*.

### Setlists

Choose **Setlist** on the start screen (or *File › New Setlist*, ⇧⌘N) and add one or more songs. Every song works
exactly like a single-song show (its own analysis, timecode and cues). In the setlist sidebar you can:

- drag songs to reorder them, remove them, and set the **pause** after each song (default pause for all songs below);
- edit the **Starting state** (fires when the setlist starts; the first song starts after *First song starts after* seconds),
  the **Waiting state** (fires in every pause between songs) and the **Ending state** (fires after the last song).
  State cues use seconds from the start of the state plus Follow / Wait;
- choose whether the next song starts automatically after the pause, or waits for Play.

Setlists **auto-save** after every change: to their `.mac2hogset` file once you have saved it, and before that
to the Autosave folder (*File › Show Autosave Folder*). Single-song shows auto-save once they have been saved.

**START** runs the setlist from the top (or from the selected song). STOP / Esc stops everything. Setlists are saved as
`.mac2hogset` files with all songs embedded.

## Requirements

- macOS 13 Ventura or later
- Xcode 15+ (or the Swift 5.9+ toolchain) to build
- A Hog 4 console / Hog 4 PC on the same network with OSC input enabled

## Build & run

```bash
# Run directly
swift run -c release Mac2Hog

# Or build a double-clickable app bundle (build/Mac2Hog.app)
./scripts/build-app.sh
```

You can also open `Package.swift` in Xcode and run the **Mac2Hog** scheme.

Run the engine tests with `swift test` (the core engine also builds and tests on Linux).
Every push builds the app and runs the tests on GitHub Actions; the built `Mac2Hog.app` is attached to the run as an artifact.

## Setting up the Hog 4

1. On the console: **Setup → Control Panel → Network** → enable **OSC In** and note the port (Mac2Hog uses 7001 by default).
2. Optional: enable **OSC Out** to your Mac's IP / port 7002 to see console feedback in Mac2Hog's OSC log.
3. In Mac2Hog: **Settings (⌘,) → Network** → enter the console IP and port and click *Send test message*.

## Workflow

| Step | Where |
|---|---|
| Import song / pick a recent one | *File › Import Song* (⌘I) or *Settings › Song* |
| Correct the tempo (×2, ÷2, type a BPM, shift bar start) | Tempo field in the transport bar, *Song Analysis* tab |
| Import the Hog showfile / pick a recent one | *File › Import Hog 4 Showfile* (⇧⌘I) or *Settings › Showfile* |
| Generate cues from parts / breaks / snares / every N bars | **Generate Cues** button |
| Add a cue | Double-click the waveform, ⌘T at the playhead, or **Start/End/Add trigger** in the *Song Analysis* tab |
| Move a cue | Drag its flag on the waveform (snaps to the beat grid), or type a timecode in the inspector |
| Attach console commands | Select a cue → inspector → **Add** (Go cuelist, goto cue, scene, macro, release, master go, fader, custom OSC) |
| Same command on all snares | Inspector → *Copy to all Snare cues*, or attach it in Generate Cues |
| Reusable commands | *Settings › Predefined*, then **+ Add › Predefined** on a cue |
| Chain cues | Inspector › Start: Follow +n s / Wait +n s |
| Run | Space = play/pause (timecode) or GO (manual), Esc = stop |
| Save | *File › Save Show* (⌘S) – `.mac2hog` project (single song) or `.mac2hogset` (setlist) |
| Export | Cue sheet CSV, LTC WAV, or song + LTC stereo WAV |

### Timecode / LTC

Mac2Hog fires cues itself from its internal timecode clock (a 4 ms high-priority timer locked to audio
playback) and has a latency compensation setting. If you also want the Hog to chase timecode, enable
*Settings › Timecode › Play LTC on the right channel* (song on the left) and feed the right channel into the
Hog's LTC input, or export an LTC WAV.

## Hog 4 OSC mapping

From the Hog 4 OS manual, *OSC Mappings*:

| Command | OSC |
|---|---|
| Go cuelist | `/hog/playback/go/0 <list>` |
| Goto cue | `/hog/playback/go/0 <list>.<cue>` |
| Halt / resume / release cuelist | `/hog/playback/halt|resume|release/0 <list>` |
| Go / halt / release scene | `/hog/playback/go|halt|release/1 <scene>` |
| Go / halt / release macro | `/hog/playback/go|halt|release/2 <macro>` |
| Master go / pause / back | `/hog/hardware/go|pause|goback/<master> 1` then `0` |
| Master fader | `/hog/hardware/fader/<master> 0–255` |
| Main go / halt / back | `/hog/hardware/maingo|mainhalt|mainback 1` then `0` |

Numbers are sent as OSC floats by default (*Settings › OSC* can switch to int or string).

**Goto cue:** the manual only documents the payload as `cuelist #.cue #`. A single float such as `1.2` is ambiguous,
because Hog cuelists can have decimal numbers themselves (list 1.2), and it also can't tell cue `1.10` from `1.1`. The default is
therefore a **string** argument (`"1.2"`). *Settings › OSC › Goto cue test* sends each variant (string argument,
list.cue in the address, float, two arguments) so you can pick the one your Hog OS version accepts. Any other address can be sent with a
*Custom OSC* command.

## Showfile import

A native Hog 4 `.shw` show is a proprietary binary database that only Hog OS can read. Mac2Hog imports:

- **Hog XML exports**: in Hog OS open the Cuelist, Scene or Macro directory, select the items and choose
  *Export* (or export the show to XML). Hog OS v5 exports (`xml_show` schema) keep each object's number and name in a
  child `<DirectoryItem number=… name=…>`. The parser also accepts number/name attributes or child elements.
- **CSV**: `type,number,name[,cue number,cue name]`, e.g. `cuelist,3,Chorus wash` or `scene,1,Blackout`.
- Objects can also be **added by hand** in the *Show Objects* tab when you know the numbers.

If you pick a `.shw` file, Mac2Hog explains how to export it.

## How the analysis works

All analysis runs on a 22.05 kHz mono copy of the song (`Sources/Mac2HogCore/Audio/AudioAnalyzer.swift`):

- **Spectrum**: 1024-point STFT, hop 256 (≈11.6 ms resolution).
- **Tempo**: autocorrelation of the spectral-flux onset envelope, weighted towards 120 BPM, then refined
  to 0.05 BPM. Alternative tempi are offered.
- **Beats**: dynamic-programming beat tracker; bar starts from where the kicks and backbeat snares fall.
- **Snares**: linear-magnitude flux of the 1.2–5 kHz "rattle" band, boosted by the 150–400 Hz body and
  suppressed when the onset is dominated by the kick band, then adaptive peak picking. Hits on beats 2 and 4
  need less evidence. Sensitivity is adjustable.
- **Song parts**: bar-level timbre + harmony + drum features → self-similarity matrix → novelty peaks,
  snapped to phrases, grouped by similarity (A/B/C) and labelled by energy, repetition and position.
- **Breaks**: bars where the drums disappear or the level drops well below the song's median.

Analysis is a starting point. Every marker can be moved, and cues are only created where you want them.

## Project layout

```
Sources/Mac2HogCore   platform-independent engine (unit tested)
  Audio/              decoding (AVFoundation / WAV), FFT, analyzer
  Hog/                show objects, showfile importer, command → OSC mapping
  OSC/                OSC 1.0 encoder/decoder, UDP sender & listener
  Show/               project model, cue generator, timecode runner, manual cue stack
  Timecode/           SMPTE timecode (incl. drop-frame), LTC encoder/decoder
  Settings/           persisted app settings
Sources/Mac2Hog       SwiftUI macOS app
Tests/Mac2HogCoreTests
```
