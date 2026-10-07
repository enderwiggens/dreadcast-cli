# Changelog

## Unreleased

### Changed

- Now and Radar are one tab, Radar, which the app opens on: conditions, alerts and the
  next two hours, then live radar filling the window, with the timeline and coming days
  beneath. It has the radar's controls (`space`, `←` `→`, `+` `−`). The tabs are
  renumbered: 1 Radar, 2 Systems, 3 Forecast, 4 Alerts, 5 Outlook, 6 Lightning,
  7 Scene and 8 Places. `dread top now` still opens Radar.
- The scene no longer sits above the radar, so the radar has no competition. Scenes
  keep their own tab and still head `dread now`; `scene-banner` now applies to
  `dread now` only.

## 0.2.0 — 2026-10-07

### Added

- `dread` opens a full-screen app with tabs for Now, Radar, Systems, Forecast, Alerts,
  Outlook, Lightning and Scene. Every tab shares one set of live data, refreshed per
  source, and a new alert shows in the header whichever tab is open. `dread top <view>`
  opens on a view by name or number. Ctrl-Z suspends the app and `fg` brings it back
  redrawn.
- The app's home, Now, is laid out like the Mac app's window: the scene as a short
  header, then conditions, alerts and the next two hours, then live radar filling the
  rest, with its timeline and the coming days beneath. It falls back to text in small
  windows and without 256 colors.
- Saved places: `dread places add|remove|default|rename`, up to eight, each usable as
  `--location <name>`. The app watches all of them, alerts every 2 minutes and
  conditions every 10, and gives the place you're viewing every source. A Places tab
  lists them, `[` and `]` switch places, and an alert at any place shows in the header
  with its name (`a` jumps to it). `dread now --all`, `dread alerts --all` and
  `dread alerts --follow --all` cover every place; `--fail-on` exits 1 when any does.
- Themes, as in the Mac app: each scene brings its own highlight color (for the selected
  tab, keys and the map marker) and its own map colors under the radar.
  `dread config set highlight` fixes one of the app's eight highlights, `map graphite`
  picks the neutral map, and `forecast days|hourly|off` sets what sits beside the
  radar's timeline. Hazard, alert, radar and lightning colors never change with a
  theme.
- `dread scene`: the app's eight free scenes as animated pixel art, filling the
  terminal, with live conditions beneath them. Scenes show their sunset version through
  the day and their night version after 8 PM, the two drawn for a dark terminal. Keys
  change the scene and switch between sunset and night; `--still` draws one frame and
  `--png` saves the artwork.
- `dread config set scene <name|daily>` picks your scene (Asteroid Watch by default), and
  `dread config set scene-banner on|off` shows or hides it on the Now tab and in
  `dread now`.
- `dread now` prints the quick look that `dread` used to, now with your scene as a
  banner when no alert is active and a five-day list. `dread weather` is another name
  for it, and `dread` still prints it when piped or given `--plain` or `--json`.
- Linux support (x86_64 and arm64), with fully static release binaries.
- A release workflow that builds the macOS universal binary and the Linux binaries for
  each tag.
- Install instructions for macOS and Linux: Homebrew, release downloads and building
  from source. `scripts/homebrew-formula.sh` writes the formula for a release.
- A README with a recorded demo and examples of every main command, captured from live
  runs, and the script that regenerates them.
- End-to-end command tests that run each main command with provider responses
  stubbed, covering output, JSON shapes, exit codes, offline behavior and rounding of
  coordinates in requests.
- `DREADCAST_CREDENTIAL_STORE=none` ignores saved lightning credentials, for CI.

### Changed

- `dread` in an interactive terminal opens the app instead of printing and exiting. Shell
  profiles that ran `dread` at startup should use `dread now`.
- `dread top`'s dashboard is now the app's Systems tab.
- The README and docs describe Dreadcast CLI as a standalone companion to DREADCAST
  Weather & Radar, and use the app's naming.
- PNG compression and decompression are now portable Swift, replacing Apple's
  Compression framework.
- On Linux, `dread auth xweather` saves credentials to a file only you can read.
- Release archives are named without a version (`dread-macos-universal.zip`,
  `dread-linux-x86_64.tar.gz`, `dread-linux-arm64.tar.gz`) and contain only the binary.

### Fixed

- The `dread eta` footer wraps to the terminal width.
- Full-screen views no longer quit when an arrow key's escape sequence arrives split, as
  it can over SSH, or when Alt is held with a key.
- Keys that arrive together, from key repeat or a paste, are no longer dropped.
- A window smaller than the app needs shows a note instead of wrapped output, and the
  pixel-art views explain themselves when colors are off.

## 0.1.0 — 2026-10-06

First release: phases 1 and 2.

### Added

- `dread`: current conditions, active alerts, the next two hours and recent lightning.
- `dread radar`: animated RainViewer radar with Natural Earth basemap, five ranges, the
  Dreadcast, Classic, Viridis and RainViewer palettes, lightning ages, and Kitty,
  iTerm2, truecolor half-block and 256-color renderers.
- `dread alerts`: full NWS alert text, `--follow` change stream and `--fail-on` exit codes.
- `dread prompt`: cache-only segment for shell prompts, tmux and status lines, with a
  shared background refresh.
- `dread forecast`: hourly and 7-day charts.
- `dread eta`: rain arrival, intensity and duration from radar motion, with stated confidence.
- `dread top`: full-screen dashboard of weather systems near you.
- `dread outlook`: Kp index, aurora, earthquakes, meteor showers, tsunamis, volcanoes,
  smoke, HF radio absorption and dust.
- `dread lightning`: Braille strike map using your own Xweather credentials.
- `dread setup`, `dread auth`, `dread config` and `dread credits`.
- `--json` with versioned schemas, `--plain`, `--no-color`, `--pretty` and `NO_COLOR`.
