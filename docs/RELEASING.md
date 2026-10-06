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

   `.github/workflows/release.yml` builds:

   - `dread-macos-universal.zip` (Apple silicon and Intel)
   - `dread-linux-x86_64.tar.gz` and `dread-linux-arm64.tar.gz` (fully static, built with
     the Swift Static Linux SDK)

   File names carry no version, so `releases/latest/download/<file>` links stay valid;
   the tag in each URL identifies the release.

   and attaches each file with a `.sha256` checksum to the GitHub release.
4. Update `Formula/dreadcast.rb` in
   [homebrew-dreadcast](https://github.com/enderwiggens/homebrew-dreadcast) with the new
   version, URLs and checksums, and check that `brew install` and `brew test` pass.

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

- [ ] Version and changelog updated
- [ ] CI green on macOS, Linux and static Linux
- [ ] Manual check in Terminal, iTerm2, Ghostty and Kitty: `dread`, `dread radar`, `dread top`
- [ ] Manual check on a Linux machine: `dread`, `dread radar --still`
- [ ] Formula updated and `brew install enderwiggens/dreadcast/dreadcast` works
- [ ] Provider terms re-checked for any new source
