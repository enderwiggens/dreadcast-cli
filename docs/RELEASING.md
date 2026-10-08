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
   - builds `dread-macos-universal.zip` (Apple silicon and Intel), signs it with
     Developer ID, notarizes it, and checks that Gatekeeper accepts it (ad-hoc signed
     instead if the secrets below are missing)
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

Releases are signed with the Developer ID Application certificate for Kevin Fleming
(team `MY488U92K9`), issued from Apple’s G2 intermediate and valid until
**2031-09-16**, and notarized with the App Store Connect API key “Dreadcast CLI
notarization” (Developer role). The certificate and key live in these repository
secrets; without them the macOS binary is only ad-hoc signed, and a zip downloaded in a
browser needs its quarantine flag cleared.

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

**Checking without a release.** The Signing check workflow signs and notarizes a build
with these secrets and publishes nothing. It runs on pull requests that change signing,
and from the Actions tab; run it after replacing a secret.

**Replacing the certificate**, before it expires or if it’s compromised: on
developer.apple.com, create a Developer ID Application certificate with the G2 Sub-CA
from a new certificate signing request, export it with its key as `.p12`, update
`MACOS_CERTIFICATE` and `MACOS_CERTIFICATE_PASSWORD`, and run the Signing check.
Releases already signed keep working after a certificate expires, because their
signatures are timestamped; only revoking a certificate invalidates them.

## Building locally

```sh
scripts/build-release.sh 0.3.0   # macOS universal binary in dist/
scripts/build-linux.sh 0.3.0     # Linux; needs a swift.org toolchain and the matching static SDK
scripts/smoke-test.sh .build/release/dread
```

To sign locally, set `DREADCAST_SIGNING_IDENTITY` before `scripts/build-release.sh`: the
identity’s name, or its SHA-1 hash from `security find-identity -v -p codesigning` if
more than one certificate has that name. Then, with the notarization key’s values in
`NOTARY_KEY` (the `.p8`, base64-encoded), `NOTARY_KEY_ID` and `NOTARY_ISSUER`, run
`scripts/notarize.sh dist/dread-macos-universal.zip dist/dread`.

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
- [ ] The macOS binary is notarized: `spctl -a -t exec -vv $(which dread)` reports
      “Notarized Developer ID”
- [ ] Provider terms re-checked for any new source; privacy docs match what’s sent
