# Dreadcast CLI contributor guide

This guide is for Claude, Codex and other AI-assisted tools, and for people.

## What this is

`dread` is an open-source Swift command-line tool that shows weather and radar in the
terminal. It is a standalone companion to DREADCAST Weather & Radar, the Mac app: a
separate project that shares no code with the app at build time and never requires it.

## Principles

- **Same honesty rules as the app.** Every reading shows its source and age. Stale data
  is labeled stale. Missing data is never reported as all clear, and scripts get exit
  code 3 when data is unavailable.
- **Honest about where data goes.** Today every request goes directly to a provider,
  with no account or analytics. Any dreadcast-run service must be described in
  `docs/PRIVACY.md` and `docs/DATA_PROVIDERS.md` before it ships, and user-facing copy
  never promises there's no server. Coordinates are rounded to two decimals before
  storage or requests.
- **Voice with limits.** At most one dry line, from `Sources/DreadCLI/Copy.swift`, only
  in pretty output, and never while any alert is active. No comedy in alerts, errors,
  plain or JSON output.
- **Visual first, with fallbacks.** Kitty graphics, iTerm2 images, truecolor
  half-blocks, 256-color, then plain text. Honor `NO_COLOR`, Reduce Motion and `--still`.
- **Free palettes and scenes only.** Dreadcast, Classic, Viridis and RainViewer's colors,
  and the app's eight free scenes. The Pro palettes and Pro scenes stay in the app.
- **Scenes are decorative.** They never describe the weather; real readings sit beside
  them. The `dread now` banner steps aside while any alert is active or alert data is
  unknown, and scene lines follow the voice rules above.

## Layout

```text
Sources/
├── DreadcastKit/   providers, decoders, domain models, radar decoding, nowcast, basemap
├── DreadTerminal/  terminal capabilities, color, text width, rasters, pixel-art helpers,
│                   frame diffing, image protocols
├── DreadCLI/       commands, arguments, config, cache, formatting, brand copy
│   ├── App/        the full-screen app: tabs, frame, screen diffing, one view per tab
│   └── Scenes/     the scenes: model, painter, readings beneath them
│       └── Kit/    the scene kit (stage, sprites, shared scenery) and one file per scene
└── dread/          the executable entry point
Tests/              Swift Testing suites with inline fixtures and stubbed providers; no network
scripts/            basemap generator, tests, release build, README screenshots
docs/               privacy, data providers, releasing, README images
```

`DreadcastKit` must not import `DreadTerminal` or `DreadCLI`. Provider payloads are
decoded into provider-neutral models before any command sees them.

## Commands

```sh
scripts/test.sh                   # run the tests (swift test on Linux)
scripts/test.sh --filter CommandTests   # one suite
scripts/smoke-test.sh .build/release/dread   # a built binary, end to end, offline
swift run dread --location 33602  # open the app (dread now prints the quick look)
swift build -c release            # optimized build
scripts/build-basemap.py          # regenerate BasemapData.swift
scripts/docs-images/capture.sh    # regenerate docs/images from live runs (needs pyte, Chrome)
```

## Conventions

- Swift 6 language mode. No external dependencies.
- macOS and Linux are both supported. Don't use Apple-only frameworks in
  `DreadcastKit` or `DreadTerminal`; guard platform code with `canImport` (`Darwin`,
  `Glibc`, and `Musl` for the static Linux SDK) and `FoundationNetworking` /
  `FoundationXML` on Linux. CI builds and tests both platforms.
- Network work goes through `HTTPClient` with the identifying User-Agent, timeouts and
  size limits.
- Radar has two sources behind `Context.radarLoop`: NOAA MRMS from the Dreadcast API
  (`DreadcastRadar.swift`, following dreadcast-server's `docs/API.md`) for the
  contiguous US when an API is set, and RainViewer elsewhere and as the fallback.
  `Dreadcast.apiBaseURL` is nil until the public API is live. Validate manifests the
  way the Mac app does, and only request tiles from the allowed hosts.
- New data sources get a cached loader in `Context` with an honest refresh interval,
  independent failure, and entries in `docs/DATA_PROVIDERS.md`, `docs/PRIVACY.md` and
  `dread credits`.
- `dread` is one app with a tab per view, sharing `TopCommand.State`'s live data. A tab
  reuses its command's pretty renderer, sized by the app (`width`/`height` parameters)
  rather than the terminal, and `ctx.inApp` drops titles the app header already shows.
  New views go in `App/AppViews.swift`, keep the one-shot command, and get a tab only
  when they're worth living in.
- Themes follow the Mac app (`Appearance.swift`): a scene's highlight and map palette,
  the app's eight fixed highlights, and Graphite. Copy values from the app's
  `DreadcastTheme.swift`, `MapPalette.swift` and `Resources/MapPreview/style.js`, and
  keep its free and Pro scenes, order and accents in `Scene.swift`. Themes never touch
  hazard, alert, radar or lightning colors.
- Radar comes first, as in the Mac app. The app opens on the Radar tab: the readings,
  live radar, then the timeline and days, with no scene (scenes have their own tab and
  head `dread now`). It draws through `RadarPanel`.
- Saved places (`Config.places`, first is the default) each get their own `State` in
  the app. Only the place being viewed loads every source; the rest are watched
  lightly (`DreadApp.sources`). Views reset per-place state in `placeChanged()`, and
  nothing from one place may be drawn under another's header.
- Every command supports `--json`, `--plain` and pretty output. JSON schemas are
  versioned (`dreadcast.<command>/1`); change the version for breaking changes.
- Generated files (`BasemapData.swift`, `RainViewerColorTable.swift`,
  `ViridisSamples.swift`, `docs/images`) are not edited by hand.
- Scenes are designed for the terminal with the scene kit: hand-drawn sprites at one
  pixel scale, flat banded skies, stepped light, no anti-aliasing, and a deliberate
  window, panorama and strip composition for each. Larger terminals show more sky;
  very large ones double every pixel. Animate in slow steps (a few per second at most)
  so frames stay small. The scene tests paint every scene in every layout and size.
- Never print, log or commit credentials. Never put them in fixtures.

## Tests

| Suite | Covers |
| --- | --- |
| `DreadcastKitTests/ProviderTests` | Decoding every provider, PNG and radar math, nowcasts, places |
| `DreadTerminalTests` | Terminal detection, key parsing, text width, frame diffing |
| `DreadCLITests/SceneTests` | Every scene in every layout, size and period; banner and copy rules |
| `DreadCLITests/AppTests`, `PlacesTests` | App views, tabs, header, saved places and light monitoring |
| `DreadCLITests/CommandTests` | Commands end to end through `Dread.dispatch`, with `StubProvider` serving fixtures: output, JSON shapes, exit codes, offline behavior, caching and request privacy |

New commands and flags get a `CommandTests` case: `CommandTests.run([...], environment:
routes:)` returns the exit code, output and errors, with any provider host left out of
`routes` failing as if offline. Use `DREADCAST_CREDENTIAL_STORE=none` (set by the
helper) so tests never read real credentials.

## Definition of done

- Tests pass and new behavior has deterministic tests.
- Pretty, plain and JSON output all work.
- Failures stay independent and visible.
- Docs are updated where behavior changed.
