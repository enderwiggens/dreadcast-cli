# Releasing

Pushing a version tag tests, builds, signs (when configured) and publishes everything.
Versions follow semantic versioning; the tag is the version with a `v`.

## Steps

1. On a branch, set `Dreadcast.version` in `Sources/DreadcastKit/HTTP.swift`, and turn
   the changelog’s `## Unreleased` heading into `## X.Y.Z — YYYY-MM-DD`. Open a pull
   request, wait for CI on macOS, Linux and the static Linux build, and merge it.
2. Tag the merge commit and push the tag:

   ```sh
   git tag -a v0.3.0 -m "dreadcast 0.3.0"
   git push origin v0.3.0
   ```

   `.github/workflows/release.yml` then:

   - checks that the tag matches `Dreadcast.version` and that the changelog has a
     section for it, and runs the tests, before building anything
   - builds `dread-macos-universal.zip` (Apple silicon and Intel), signed with Developer
     ID and notarized when the secrets below are set, and ad-hoc signed otherwise
   - builds the fully static `dread-linux-x86_64.tar.gz` and `dread-linux-arm64.tar.gz`
     with the Swift Static Linux SDK, and runs `scripts/smoke-test.sh` against the
     x86_64 binary
   - attaches each archive with a `.sha256` checksum, then sets the release’s title and
     notes from its changelog section

   File names carry no version, so `releases/latest/download/<file>` links stay valid.
3. Once the release has all six files, generate the formula from their checksums and
   open a pull request in
   [homebrew-dreadcast](https://github.com/enderwiggens/homebrew-dreadcast):

   ```sh
   scripts/homebrew-formula.sh 0.3.0 > ../homebrew-dreadcast/Formula/dreadcast.rb
   ```

   After it merges, check `brew upgrade dreadcast && dread version && brew test dreadcast`.

## Signing and notarization

Without these repository secrets, the macOS binary is ad-hoc signed: Homebrew and
`curl` installs run as is, but a zip downloaded in a browser needs its quarantine flag
cleared. With them, the release is signed with Developer ID and notarized.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE` | A Developer ID Application certificate and key, exported as `.p12` and base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The `.p12` export password |
| `MACOS_SIGNING_IDENTITY` | The identity name, such as `Developer ID Application: Dreadcast Weather (TEAMID)` |
| `NOTARY_KEY` | An App Store Connect API key (`.p8`), base64-encoded |
| `NOTARY_KEY_ID` | That key’s ID |
| `NOTARY_ISSUER` | The key’s issuer ID |

A bare binary can’t be stapled, so Gatekeeper checks the notarization online the first
time the binary runs.

## Building locally

```sh
scripts/build-release.sh 0.3.0   # macOS universal binary in dist/
scripts/build-linux.sh 0.3.0     # Linux; needs a swift.org toolchain and the matching static SDK
scripts/smoke-test.sh .build/release/dread
```

To sign locally, set `DREADCAST_SIGNING_IDENTITY` before `scripts/build-release.sh`,
then notarize with `xcrun notarytool submit dist/dread-macos-universal.zip
--keychain-profile dreadcast --wait`.

## Checklist

- [ ] Version and changelog updated in a merged pull request, and CI green on macOS,
      Linux and static Linux
- [ ] Manual check in Terminal, iTerm2, Ghostty and Kitty: `dread` (every tab, and the
      Places tab with two or more saved places), `dread now`, `dread radar`
- [ ] Manual check on a Linux machine: `dread`, `dread now`, `dread radar --still`
- [ ] Radar from the Dreadcast API: `curl -fsS https://api.dreadcast.app/v2/radar/latest`
      answers, `dread radar` at a US location credits NOAA MRMS, and in London credits
      EUMETNET OPERA with its license
- [ ] The repository URL in the User-Agent resolves
- [ ] Release has six files and notes; the formula is updated and `brew test` passes
- [ ] Provider terms re-checked for any new source; privacy docs match what’s sent
