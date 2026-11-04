# Changelog

Mac2Hog follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The version lives in `VERSION`,
`Sources/Mac2HogCore/Version.swift` and `Resources/Info.plist` (kept in sync by a unit test) and is bumped on every commit.

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
