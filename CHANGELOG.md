# Changelog

## Unreleased

### Added

- The first time it uses the Dreadcast API, the CLI asks it for an install token and
  sends it with each request to the API, so the API counts this install's requests
  apart from others on the network, with limits of its own. Nothing secret ships in
  the source: the token is random, made by the API, kept in `install-token.json` in the
  config directory, readable only by you, and sent to no other host. A token the API
  turns down is dropped and the request retried without one. `dread config` shows
  whether it's on; `dread config set install-token off` deletes it from the API and
  this machine, and `DREADCAST_INSTALL_TOKEN=off` skips it for a run. Needs
  dreadcast-server #49; an older server, or a network out of tokens for the day, is
  simply asked again a day later, and its other requests go on without one.

- `dread systems` opens the app on its Systems tab: storm cells, alerts, fires, tropical
  storms and more near you, sorted by threat. Piped, or with `--plain`, `--json` or
  `--pretty`, it lists every system once with its details, names the sources it read
  and any it couldn't reach, and exits 3 when none answered. `--json` follows the new
  `dreadcast.systems/1` schema, with each system's `kind` and `source`.
- Where no radar reaches, radar views show NOAA's satellite rain estimates from the
  Dreadcast API, credited with the blend's time. They fill only pixels that no radar
  region covers, and a view no radar reaches at all loops the blends themselves, ten
  minutes apart, at their own times. Right after an outage, when the API lists only
  one blend, it shows that one.
- Where no radar reaches, `dread eta` times rain from the forecast model's 15-minute
  precipitation and says so. Its `--json` has `source: "model"`, the model's `units`
  and each step's `precipitation`, with no frames, reflectivity, motion, trend or
  storm cells. The Systems tab shows "No radar here" with the model's timing, rather
  than an outage.

### Changed

- Satellite rain loads from the radar CDN when the API names it there
  (`satellite.tile_url`, checked against the radar tiles' own origin), so zoomed-out
  views no longer queue behind the API's per-IP limit. If the CDN fails, the tile
  comes from the API as before.
- Asking for one of the app's scenes the terminal doesn't draw (Black Hole, Botanical
  Takeover, Peak Optimism or Volcano Watch) says it's only in the Dreadcast app,
  rather than calling it Pro and the terminal's eight "free scenes": since October 16
  the app makes Peak Optimism free and five of those eight Pro. The README says
  "Eight of Dreadcast's scenes".
- `dread radar` and the Radar tab reach back an hour, as the Mac and iPhone apps now do
  for everyone, instead of half an hour. The CLI asks the API for its hour
  (`/v2/radar/latest?minutes=60`, up to 15 frames, one per four-minute window) and
  draws 8 frames spread across it, every other one, so a loop costs what it did.
  `--frames` takes 2 to 15, always from the oldest to the newest; loops longer than 8
  frames step faster, 0.45 s a frame. Manifests may now have up to 16 frames.
- Weather, air quality, dust and place search come from the Dreadcast API
  (`/v1/weather/current` and `/forecast`, `/v1/air/current`, `/v1/places/search`)
  instead of Open-Meteo's free API, which is for non-commercial use only. The data is
  still Open-Meteo's, with CAMS air quality and GeoNames places, and it's credited the
  same way. Open-Meteo now sees the API's address instead of yours. A reading the API
  serves while its provider is down is marked stale. Dust is read at the place itself
  rather than as the nearest of 25 points.
- The README and the agent guide call the Mac app by its full name, Dreadcast: Weather
  Radar & Forecasts. TRADEMARKS.md lists it with the App Store name, Dreadcast: Radar &
  Weather, and keeps the earlier names as former names.
- Radar comes only from the Dreadcast API. If the API is down, radar is unavailable.
  `api-url off` now turns off radar, weather, air quality and place search; ZIP codes
  and coordinates still resolve.
- `dread now` dates the forecast model's rain from the start of each 15-minute step
  rather than its end, so it can say rain starts up to 15 minutes earlier than before.
  `--plain` shows the model's next two hours when there's no radar timing to show.

### Removed

- RainViewer, with its palette and `config set radar-source`. Places outside the
  Dreadcast API's radar regions (the US, Puerto Rico, Guam and most of Europe) now get
  satellite estimates in radar views and the forecast model's rain timing, not
  RainViewer's radar. A saved RainViewer palette reads as Dreadcast.
- `dread top`. It opened the app on a view, and every view now has its own command:
  `dread` opens the app and `dread systems` opens it on Systems, with the other tabs a
  keypress away. `dread top` now says so and exits 2. `dread help app` replaces
  `dread help top`.

### Fixed

- When the Dreadcast API or another provider answers 429, dread waits as long as its
  `Retry-After` asks (up to an hour, a minute when it doesn't say) before asking that
  host again, across every shell, prompt and status line, and shows the last reading
  meanwhile, marked stale.
- The Systems tab said conditions were loading after they had failed to load; it now
  says they're unavailable.
- On Linux, a request cancelled because another one failed could crash dread inside
  FoundationNetworking. Requests there now run to their own end, bounded by their
  timeouts.
- `dread credits` ran long source names into their descriptions, as in "National
  Weather ServiceActive alerts". Names now have room, and one too long for the column
  takes a line of its own.
- After a network blip, `dread outlook` and `dread systems` kept calling tsunamis,
  volcanoes, smoke and dust unavailable for up to 15 minutes. Hazards where every
  source failed are no longer cached, so the next run tries again or shows the last
  summary, marked stale, and a summary missing some sources is fetched again after a
  minute.

## 0.3.2 — 2026-10-08

### Changed

- The macOS binary is signed with Developer ID and notarized by Apple, so it runs
  however it's downloaded, including a zip from the browser, without clearing the
  quarantine flag. Releases check that Gatekeeper accepts it before publishing, and a
  Signing check workflow tests the signing setup without making a release.

## 0.3.1 — 2026-10-07

### Fixed

- Rain timing named RainViewer as its radar even when the radar came from the
  Dreadcast API: in `dread eta`'s header, in `dread now`'s sources line, and as
  `"source": "rainviewer"` in `dread eta --json` and `dread now --json`. Each now names
  the radar used, such as NOAA MRMS or EUMETNET OPERA with its license, and the JSON
  adds a `credit`. `dread eta` shows the credit on its own Radar row, so Europe's fits
  in 80 columns.
- The app's Radar tab no longer credits RainViewer while its radar is still loading.
- The Systems tab named tropical storms twice, as in "Tropical Storm Tropical Storm
  Isaias": NHC's names already include the classification.

## 0.3.0 — 2026-10-07

### Added

- Radar from the Dreadcast API at `https://api.dreadcast.app`, by default: places it
  covers get radar read as measured values rather than colors, about 1 km across: NOAA
  MRMS for the contiguous US, Alaska, Hawaii, Puerto Rico and the Caribbean, and Guam,
  and EUMETNET OPERA for Europe. Places elsewhere, and places inside a region that its
  radars don't reach (such as Italy), keep RainViewer, which is also the fallback when
  the API can't provide a loop. `radar-source rainviewer` or `api-url off` opts out,
  and `api-url` or `DREADCAST_API_URL` points at another API. Each place's loop is
  timed and labeled "radar delayed" by its own region. The radar footer, `dread eta`
  and `dread credits` name the source, and Europe's radar carries its CC BY 4.0
  license.

### Changed

- Now and Radar are one tab, Radar, which the app opens on: conditions, alerts and the
  next two hours, then live radar filling the window, with the timeline and coming days
  beneath. It has the radar's controls (`space`, `←` `→`, `+` `−`). The tabs are
  renumbered: 1 Radar, 2 Systems, 3 Forecast, 4 Alerts, 5 Outlook, 6 Lightning,
  7 Scene and 8 Places. `dread top now` still opens Radar.
- The scene no longer sits above the radar, so the radar has no competition. Scenes
  keep their own tab and still head `dread now`; `scene-banner` now applies to
  `dread now` only.
- With a second radar source, `dread radar --json` reports `source` as `dreadcast` or
  `rainviewer` and adds a `credit`, and `dread eta` ends with the credit, such as
  "Radar: NOAA MRMS, 4 frames." instead of "Source: RainViewer radar, 4 frames."
- Releases run the tests first and stop if the tag, version and changelog don't agree;
  they sign and notarize the macOS binary once Developer ID secrets are configured, and
  take their notes from the changelog. CI and releases run an offline smoke test
  against the built binaries, and workflow actions are pinned to commits.

### Fixed

- `dread setup` and `dread places` no longer repeat the coordinates for a place given
  as coordinates.

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
