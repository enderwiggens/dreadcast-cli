# Releasing

Pushing a version tag builds and publishes everything. Binaries are ad-hoc signed and
not yet notarized; Homebrew installs them without a Gatekeeper prompt.

## Steps

1. Update `Dreadcast.version` in `Sources/DreadcastKit/HTTP.swift` and date the entry in
   `CHANGELOG.md`.
2. Merge to `main` and confirm CI passed on macOS, Linux and the static Linux build.
3. Tag and push:

   ```sh
   git tag -a v0.2.0 -m "dreadcast 0.2.0"
   git push origin v0.2.0
   ```

   `.github/workflows/release.yml` builds these and attaches each, with a `.sha256`
   checksum, to the GitHub release:

   - `dread-macos-universal.zip` (Apple silicon and Intel)
   - `dread-linux-x86_64.tar.gz` and `dread-linux-arm64.tar.gz` (fully static, built with
     the Swift Static Linux SDK)

   File names carry no version, so `releases/latest/download/<file>` links stay valid;
   the tag in each URL identifies the release.
4. Once all six files are on the release, generate the formula from their checksums
   and commit it to [homebrew-dreadcast](https://github.com/enderwiggens/homebrew-dreadcast):

   ```sh
   scripts/homebrew-formula.sh 0.2.0 > ../homebrew-dreadcast/Formula/dreadcast.rb
   brew install --build-from-source ../homebrew-dreadcast/Formula/dreadcast.rb && brew test dreadcast
   ```

   The formula installs the universal binary on macOS and the matching static binary on
   Linux (x86_64 or arm64).

## Building locally

```sh
scripts/build-release.sh 0.2.0   # macOS universal binary in dist/
scripts/build-linux.sh 0.2.0     # Linux; needs a swift.org toolchain and the matching static SDK
```

To sign the macOS binary with a Developer ID, set `DREADCAST_SIGNING_IDENTITY` before
running `scripts/build-release.sh`, then notarize the zip:

```sh
xcrun notarytool submit dist/dread-macos-universal.zip --keychain-profile dreadcast --wait
```

## Checklist

- [ ] Version updated in `Sources/DreadcastKit/HTTP.swift` and `CHANGELOG.md`
- [ ] `scripts/test.sh` passes, and CI is green on macOS, Linux and static Linux
- [ ] Manual check in Terminal, iTerm2, Ghostty and Kitty: `dread` (every tab, and the
      Places tab with two or more saved places), `dread now`, `dread radar`
- [ ] Manual check on a Linux machine: `dread`, `dread now`, `dread radar --still`
- [ ] The repository URL in the User-Agent resolves
- [ ] Formula updated and `brew install enderwiggens/dreadcast/dreadcast` works
- [ ] Provider terms re-checked for any new source
