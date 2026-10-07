# Contributing

Thanks for helping. A few things keep Dreadcast trustworthy:

- **Tests never touch the network.** Decoders are tested with inline fixtures, and
  commands run end to end against stubbed providers.
- **Readings stay honest.** Show the source and age, label stale data, and never turn
  missing data into reassurance.
- **Failures stay independent.** One provider failing must not hide the others.
- **No new dependencies** without a discussion first.

## Setup

```sh
git clone https://github.com/enderwiggens/dreadcast-cli.git
cd dreadcast-cli
scripts/test.sh
swift run dread setup
```

You need Swift 6: Xcode 16 or later on macOS, or a
[swift.org toolchain](https://www.swift.org/install/linux/) on Linux (run `swift test`
there instead of `scripts/test.sh`).

## Tests

`scripts/test.sh` runs everything; `scripts/test.sh --filter CommandTests` runs one
suite. Provider decoding lives in `Tests/DreadcastKitTests`, terminal rendering in
`Tests/DreadTerminalTests`, and the app, scenes, saved places and commands in
`Tests/DreadCLITests`. A behavior change should come with a test that fails without it;
for a command, add a case to `CommandTests`, which runs the real command with provider
responses stubbed and checks its output and exit code.

## Pull requests

- Keep each pull request focused on one change.
- Add or update tests for behavior changes.
- Update the README and the files in `docs/` when commands, output or data sources change.
  The README screenshots come from live runs: `scripts/docs-images/capture.sh` rebuilds
  them (it needs Google Chrome and a Python with `pyte`).
- Run `scripts/test.sh` before opening the pull request.

See [CLAUDE.md](CLAUDE.md) for the architecture and conventions, and
[TRADEMARKS.md](TRADEMARKS.md) before publishing a fork.
