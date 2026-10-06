# Changelog

## 0.2.0 — unreleased

### Added

- Linux support (x86_64 and arm64), with fully static release binaries.
- Release workflow that builds the macOS universal binary and Linux binaries for each tag.

### Changed

- PNG compression and decompression are now portable Swift, replacing Apple's
  Compression framework.
- On Linux, `dread auth xweather` saves credentials to a file only you can read.
- Release archives are now named without a version (`dread-macos-universal.zip`,
  `dread-linux-x86_64.tar.gz`, `dread-linux-arm64.tar.gz`) and contain only the binary.

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
