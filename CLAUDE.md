# dreadcast contributor guide

This guide is for Claude, Codex and other AI-assisted tools, and for people.

## What this is

`dread` is an open-source Swift command-line tool that shows weather and radar in the
terminal. It is the companion to the DREADCAST Weather & Radar Mac app, but it is a
separate project: it shares no code at build time with the app and never requires it.

## Principles

- **Same honesty rules as the app.** Every reading shows its source and age. Stale data
  is labeled stale. Missing data is never reported as all clear, and scripts get exit
  code 3 when data is unavailable.
- **Direct to providers.** No dreadcast server, account or analytics. Coordinates are
  rounded to two decimals before storage or requests.
- **Voice with limits.** At most one dry line, from `Sources/DreadCLI/Copy.swift`, only
  in pretty output, and never while any alert is active. No comedy in alerts, errors,
  plain or JSON output.
- **Visual first, with fallbacks.** Kitty graphics, iTerm2 images, truecolor
  half-blocks, 256-color, then plain text. Honor `NO_COLOR`, Reduce Motion and `--still`.
- **Free palettes only.** Dreadcast, Classic, Viridis and RainViewer's colors. The app's
  Pro palettes stay in the app.

## Layout

```text
Sources/
├── DreadcastKit/   providers, decoders, domain models, radar decoding, nowcast, basemap
├── DreadTerminal/  terminal capabilities, color, text width, rasters, image protocols
├── DreadCLI/       commands, arguments, config, cache, formatting, brand copy
└── dread/          the executable entry point
Tests/              Swift Testing suites with inline fixtures; no network
scripts/            basemap generator, tests, release build
docs/               privacy, data providers, releasing
```

`DreadcastKit` must not import `DreadTerminal` or `DreadCLI`. Provider payloads are
decoded into provider-neutral models before any command sees them.

## Commands

```sh
scripts/test.sh                   # run the tests
swift run dread --location 33602  # try a command
swift build -c release            # optimized build
scripts/build-basemap.py          # regenerate BasemapData.swift
```

## Conventions

- Swift 6 language mode. No external dependencies.
- macOS and Linux are both supported. Don't use Apple-only frameworks in
  `DreadcastKit` or `DreadTerminal`; guard platform code with `canImport` (`Darwin`,
  `Glibc`, and `Musl` for the static Linux SDK) and `FoundationNetworking` /
  `FoundationXML` on Linux. CI builds and tests both platforms.
- Network work goes through `HTTPClient` with the identifying User-Agent, timeouts and
  size limits.
- New data sources get a cached loader in `Context` with an honest refresh interval,
  independent failure, and entries in `docs/DATA_PROVIDERS.md`, `docs/PRIVACY.md` and
  `dread credits`.
- Every command supports `--json`, `--plain` and pretty output. JSON schemas are
  versioned (`dreadcast.<command>/1`); change the version for breaking changes.
- Generated files (`BasemapData.swift`, `RainViewerColorTable.swift`,
  `ViridisSamples.swift`) are not edited by hand.
- Never print, log or commit credentials. Never put them in fixtures.

## Definition of done

- Tests pass and new behavior has deterministic tests.
- Pretty, plain and JSON output all work.
- Failures stay independent and visible.
- Docs are updated where behavior changed.
