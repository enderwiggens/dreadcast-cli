# Contributing

Thanks for helping. A few things keep dreadcast trustworthy:

- **Tests never touch the network.** Decoders are tested with inline fixtures.
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

You need Swift 6 (Xcode 16 or later on macOS).

## Pull requests

- Keep each pull request focused on one change.
- Add or update tests for behavior changes.
- Update the README and the files in `docs/` when commands, output or data sources change.
  The README screenshots come from live runs: `scripts/docs-images/capture.sh` rebuilds
  them (it needs Google Chrome and a Python with `pyte`).
- Run `scripts/test.sh` before opening the pull request.

See [CLAUDE.md](CLAUDE.md) for the architecture and conventions, and
[TRADEMARKS.md](TRADEMARKS.md) before publishing a fork.
