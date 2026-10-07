# Security

## Reporting a vulnerability

Please report security problems privately, not in a public issue: open this
repository’s **Security** tab and choose **Report a vulnerability**. Include what you
found, how to reproduce it, and the version (`dread version`). We’ll acknowledge the
report, keep you posted while it’s fixed, and credit you in the release notes if you’d
like.

## Supported versions

Fixes go into the latest release only. Upgrade with `brew upgrade dreadcast`, or
download the newest binary from
[Releases](https://github.com/enderwiggens/dreadcast-cli/releases/latest).

## What’s in scope

- The `dread` binary and this repository’s build and release pipeline
- Credential handling: `dread auth xweather` stores lightning credentials in the macOS
  Keychain, or in a file only you can read on Linux, and never prints or logs them
- Network handling: every request has a timeout and a size limit, radar from the
  Dreadcast API is validated before use, and its tiles load only from Dreadcast’s hosts

Weather providers’ own services are out of scope; report problems with them to the
provider. For what dreadcast sends and stores, see [docs/PRIVACY.md](docs/PRIVACY.md).
