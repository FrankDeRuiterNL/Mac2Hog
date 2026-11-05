# Changelog

Mac2Hog follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version lives in `VERSION`,
`Sources/Mac2HogCore/Version.swift` and `Resources/Info.plist` (kept in sync by a unit test) and is bumped on every commit.

## 0.10.0
- New **Semi-Manual** mode (top bar, between Timecode and Manual): the timecode rundown runs on a silent clock at
  real speed — no audio — firing every cue exactly as Timecode mode would (including Follow / Wait and delayed
  releases). Press **NEXT** (or Space) to start at the first cue or skip to the next cue point; the rundown continues
  from there with the original timings. PLAY pauses / resumes the rundown.

## 0.9.0
- Millumin: Settings › Network has a Millumin section (IP/hostname, OSC input port, status, Apply, Send test
  message); Settings › OSC has "Millumin Message Format" (address prefix, default /m2h; number arguments; key release).
- New cue command "Millumin Custom OSC" with Prefix (default: Settings prefix), Topic (default /millumin) and Value
  (text or number), sent to Millumin as e.g. `/m2h/millumin start`.
- Settings › OSC: Hog fields renamed to "Hog Message Format", "Hog address prefix", "Hog number arguments",
  "Hog goto cue format"; "Goto cue test" is now "Hog Goto Cue Test".

## 0.8.0
- Cue list: "Duplicate cue" is now "Duplicate to playhead": the selected cue is copied ("Copy of …") to a new
  Timecode cue at the current playhead position. In setlist states (no song) it still duplicates directly below.
  The right-click "Duplicate" still copies directly below the original.

## 0.7.1
- Build: CI and Release run on the self-hosted Mac runner; builds use a scratch folder outside the runner's work
  directory and strip Finder/iCloud extended attributes before code signing (`SCRATCH_PATH` in `build-app.sh`).
- Remove an always-false branch in the waveform drawing (compiler warning).

## 0.7.0
- Start screen: "Recent projects" lists recently opened/saved setlists and shows (and single songs); untitled
  setlists appear via their autosave file. Missing files are greyed out.
- "Showfile" is now called "Hog XML" everywhere (File › Import Hog XML…, start screen, Settings › Hog XML with
  "Loaded Hog XML" / "Recent XML's", Show Objects tab).
- Settings › Hardware: audio output device for the song, a separate output device and channel for live LTC
  timecode (played in sync with the song), and the network adapter used for OSC (with subnet check).
  Replaces the old "Play LTC on the right audio channel" option.
- Cue list: "Duplicate cue" button (copy named "Copy of …" directly below the selected cue) replaces
  "Fire selected" and "Add predefined".

## 0.6.0
- Cue list: cues with a timed Release show it in the Start column, e.g. "TC+ ↩︎ 0,4s" (blue icon and delay;
  "W" for Wait releases); the release is no longer repeated in Console commands.
- Cue list: right-click the column titles to show or hide columns (remembered). Type is hidden by default.
- Cue inspector: delete-cue trash icon is white instead of red.

## 0.5.0
- Release button (blue ↩︎) on a Go of a cuelist or scene: adds the matching Release below it, with its own
  Follow / Wait timing (Follow = seconds after the cue fires, Wait = after the cue's Duration). Commands with a
  timing are sent by the engine after that delay and cancelled by STOP.
- Star button per command: outline = not predefined, yellow = already a predefined trigger (click to add/remove).
- Cue inspector redesigned: aligned label/control grid (labels never truncate), delete-cue trash icon in the
  header; removed Fire now, Preview, Copy to all, Save as predefined and Delete cue buttons.
- Next cue blinks dark green (once per second) in the cue list.
- Two-finger horizontal scrolling (and mouse wheel) over the waveform.
- Fix: the playhead is now a Core Animation layer moving at playback speed on the render server, so it stays
  smooth when a cue fires; it is only re-synced to the player when it drifts or the view scrolls/zooms.

## 0.4.0
- Pinch-to-zoom on the waveform (trackpad); zooms around the playhead when visible, otherwise the centre.
- Fix: Follow / Wait delay, cue Duration and setlist pause fields accept decimals with a dot or a comma
  (0.1, 0,10, 1.15) regardless of the Mac's region, with up to two decimals; "Follow +1.15s" now shows both decimals.

## 0.3.0
- Fix: playhead no longer hitches when a cue fires. Fired/running cue state and the OSC log live in their own
  observable objects (only the cue list, inspector and log redraw), network status is only published when it
  changes, the position timer runs in all run-loop modes, and the playhead is interpolated at display rate.
- Fix: cue list header no longer takes up half the list.
- Inspector follows the last fired / running cue when *Follow* is on (clicking a cue still shows that cue).
- OSC output panel is collapsed by default.
- Main window opens filling the screen on first launch and then remembers its size and position.

## 0.2.0
- Smoother playback: the playhead clock is a separate observable object, so the 30 Hz position updates only
  redraw the transport bar and a light playhead layer instead of the whole window (cue list, inspector, waveform).
- Cue list follows along when *Follow* is on (scrolls to the last fired cue, or the next cue in manual mode).
- Cue list row colours: purple = last fired cue, red = cue still running (within its Duration).
- OSC output panel can be collapsed (Collapse Output / Open OSC output); remembered between launches.

## 0.1.5
- Cue inspector: cuelist and cue numbers sit right next to their pickers (no longer at the far right) and have
  up/down steppers. With a showfile loaded the steppers move to the next/previous existing cuelist or cue;
  without one they count in whole numbers.

## 0.1.4
- Cue inspector: command editor laid out as a label/control grid so cuelist and cue pickers use the available
  width instead of being pushed to the far right; number fields no longer show wrapped labels ("Cu e").

## 0.1.3
- Rename setlist songs (right-click › Rename Song…); the name is used throughout the app, the audio file is untouched.
- Settings › Song lists all setlist songs (or the current song) with Select File… and Re-analyze per song; Recent songs removed.
- About tab in Settings with the app version; copyright footer with links at the bottom of Settings.
- Semantic Versioning: version shown in the app and written into the app bundle by `build-app.sh`.

## 0.1.0 – 0.1.2
- First releases: song analysis (tempo, beats, snares, breaks, song parts), timecode and LTC, Hog OSC output,
  showfile import (Hog XML / CSV), cue list with Timecode / Follow / Wait, manual GO mode, setlists with
  Starting / Waiting / Ending states, predefined triggers, auto-save, app icon and Select File… relinking.
