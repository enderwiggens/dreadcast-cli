# dreadcast

**Weather and radar for the command line.** *There’s a lot in the forecast.*

`dread` is the open-source command-line companion to DREADCAST Weather & Radar. It
draws animated radar in your terminal, tells you when rain will arrive, lists active
warnings in full, and fits a forecast into your shell prompt. Every reading comes
straight from a public provider, with its source and age attached.

```
$ dread

  DREADCAST  ·  Tampa, FL                                        2:32 PM EDT
  ⛈️  71°F  Thunderstorm        Feels 74° · Humidity 82% · Wind SW 14 G 31 mph

   ▲ SEVERE THUNDERSTORM WARNING   until 3:15 PM EDT          NWS Tampa Bay FL
    Move to an interior room on the lowest floor of a building.

  Next 2 h    ▁▁▁▁▁▂▅██▅▂▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁   rain from ~2:51 PM, heavy ~10 min
  Lightning   42 in 20 min · nearest 7 mi SW  2 min ago
  Tonight     Low 69° · Thunderstorm · 60% chance of rain

  OPEN-METEO · NWS · XWEATHER · RAINVIEWER                 updated 2 min ago
```

*Example output. Readings are illustrative.*

## Install

dreadcast is macOS-first and builds with Swift 6 (Xcode 16 or later). It has no
dependencies beyond the Swift toolchain.

```sh
git clone https://github.com/enderwiggens/dreadcast-cli.git
cd dreadcast-cli
swift build -c release
cp .build/release/dread /usr/local/bin/   # or anywhere on your PATH
dread setup
```

A Homebrew tap with signed, notarized binaries is planned. See
[docs/RELEASING.md](docs/RELEASING.md).

## Commands

| Command | What it does |
| --- | --- |
| `dread` | Current conditions, active alerts, the next two hours and recent lightning |
| `dread radar` | Animated radar loop with ranges, palettes and lightning ages |
| `dread alerts` | Active NWS watches, warnings and advisories in full |
| `dread prompt` | A cached segment for shell prompts and status lines |
| `dread forecast` | Hourly and 7-day charts |
| `dread eta` | When rain reaches you, from recent radar motion |
| `dread top` | Full-screen dashboard: weather systems listed like processes |
| `dread outlook` | Solar activity, aurora, earthquakes, meteor showers and hazards |
| `dread lightning` | Strike map in Braille dots (needs your own Xweather account) |
| `dread setup` | Choose a location: ZIP code, place name or `lat,lon` |
| `dread auth xweather` | Save optional lightning credentials to the Keychain |
| `dread config` | Show or change preferences |
| `dread credits` | Data sources and licenses |

Run `dread help <command>` for options. Every command accepts `--location`,
`--units imperial|metric`, `--json`, `--plain` and `--no-color`.

### Radar

```sh
dread radar                    # animate the last eight frames
dread radar --range 150        # 15, 35, 75, 150 or 300 miles
dread radar --palette viridis  # dreadcast, classic, viridis or rainviewer
dread radar --still            # just the latest frame
```

While it animates: space pauses, ←/→ step frames, +/− zoom, q quits.

dreadcast reads RainViewer's free radar tiles and converts each pixel back to
reflectivity using RainViewer's published color table, so the radar can be redrawn in
the Dreadcast palettes and used for timing. The basemap is Natural Earth data built
into the binary, so the terminal never needs a map service.

### Rain timing

`dread eta` measures how echoes moved across the last four radar frames, then traces
backward from your location to estimate when rain arrives, how heavy it gets and when
it eases. It reports its confidence and the frames it used. It can't foresee storms
that form or fade along the way.

### Scripts and automation

`--json` gives a versioned schema on every command. `dread alerts` sets exit codes:

| Exit | Meaning |
| --- | --- |
| 0 | Nothing at or above the `--fail-on` level |
| 1 | An alert at or above the level is active |
| 2 | Usage error |
| 3 | Data unavailable or stale. Never reported as all clear |
| 4 | No location yet; run `dread setup` |

```sh
dread alerts --fail-on severe && ./start-field-crew.sh
dread alerts --follow --json | jq -r '"\(.type): \(.alert.event)"'
```

### Prompts and status lines

`dread prompt` reads only the cache and returns in about 15 ms. When the cache is more
than ten minutes old it starts one background refresh, shared by every shell.

```sh
# zsh
setopt prompt_subst
RPROMPT='$(dread prompt)'

# tmux
set -g status-right '#(dread prompt --format tmux)'
set -g status-interval 60
```

```toml
# Starship
[custom.dreadcast]
command = "dread prompt"
when = true
```

```json
// Claude Code: ~/.claude/settings.json
{ "statusLine": { "type": "command", "command": "dread prompt" } }
```

## How it draws

dreadcast detects what your terminal supports and uses the best renderer available:

| Renderer | Terminals | Result |
| --- | --- | --- |
| Kitty graphics | Kitty, Ghostty | Full-resolution radar, animated in place |
| Inline images | iTerm2, WezTerm | Full-resolution radar, redrawn each frame |
| Truecolor half-blocks | Most modern terminals | Two pixels per character cell |
| 256-color | Older terminals, many SSH sessions | Same layout, quantized colors |
| Plain text and JSON | Pipes, CI, screen readers | Readings as sentences, or structured data |

Force a renderer with `--renderer`, or with `dread config set renderer halfblock`.
Inside tmux, graphics protocols are off by default. dreadcast honors `NO_COLOR` and the
macOS Reduce Motion setting; `--still` stops animation.

## Data and privacy

dreadcast has no account, no server and no analytics. Requests go directly from your
machine to each provider, and coordinates are rounded to two decimal places (about
1 km) before they are stored or sent. See [docs/PRIVACY.md](docs/PRIVACY.md) and
[docs/DATA_PROVIDERS.md](docs/DATA_PROVIDERS.md).

| Data | Provider |
| --- | --- |
| Conditions, forecasts, air quality, place search | [Open-Meteo](https://open-meteo.com/) (CC BY 4.0) |
| Radar | [RainViewer](https://www.rainviewer.com/) |
| Alerts | [National Weather Service](https://www.weather.gov/) |
| Severe outlook, tropical storms | NOAA SPC and NHC |
| Wildfires | NIFC |
| Solar activity, aurora, HF radio | NOAA SWPC |
| Earthquakes, volcanoes | USGS |
| Tsunamis | NTWC / PTWC |
| Smoke | NOAA HMS |
| Lightning (optional) | [Xweather](https://www.xweather.com/), with your own credentials |
| ZIP lookup | [Zippopotam.us](https://zippopotam.us/) |
| Basemap | [Natural Earth](https://www.naturalearthdata.com/) (public domain) |

NWS, SPC, NHC and NIFC data cover the United States. Conditions, forecasts, radar and
the outlook work worldwide.

## Development

```sh
scripts/test.sh                  # deterministic tests; no network
swift run dread --location 33602 # try it
scripts/build-basemap.py         # regenerate the embedded Natural Earth basemap
```

The package has three libraries: `DreadcastKit` (providers, decoders, models),
`DreadTerminal` (capabilities, color, rasters, image protocols) and `DreadCLI`
(commands, configuration, cache, output). See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CLAUDE.md](CLAUDE.md).

## License and trademark

The code is licensed under the [Apache License 2.0](LICENSE). The Dreadcast name and
wordmark are trademarks and are not licensed for use by forks; see
[TRADEMARKS.md](TRADEMARKS.md). Third-party notices are in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

*A chance of rain. Among other things.*
