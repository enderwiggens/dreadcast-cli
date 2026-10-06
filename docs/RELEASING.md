# Releasing

dreadcast is distributed outside the Mac App Store as a Developer ID–signed, notarized
universal binary, then published through a Homebrew tap. Nothing here has been run
against real signing credentials yet.

## Build

```sh
scripts/build-release.sh 0.1.0
```

This builds a universal (arm64 + x86_64) release binary into `dist/` and writes a
SHA-256 checksum. Set `DREADCAST_SIGNING_IDENTITY` to a "Developer ID Application"
identity to sign with the hardened runtime.

## Notarize

```sh
ditto -c -k --keepParent dist/dread dist/dread-0.1.0-macos.zip
xcrun notarytool submit dist/dread-0.1.0-macos.zip --keychain-profile dreadcast --wait
```

A command-line tool can't be stapled, so Gatekeeper checks notarization online on
first run.

## Homebrew

Publish a tap repository, for example `enderwiggens/homebrew-dreadcast`, with a formula
like this:

```ruby
class Dreadcast < Formula
  desc "Weather and radar for the command line"
  homepage "https://github.com/enderwiggens/dreadcast-cli"
  url "https://github.com/enderwiggens/dreadcast-cli/releases/download/v0.1.0/dread-0.1.0-macos.zip"
  sha256 "<checksum from scripts/build-release.sh>"
  license "Apache-2.0"

  def install
    bin.install "dread"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/dread version")
  end
end
```

Users then install with `brew install enderwiggens/dreadcast/dreadcast`.

## Checklist

- [ ] Version updated in `Sources/DreadcastKit/HTTP.swift` and `CHANGELOG.md`
- [ ] `scripts/test.sh` passes
- [ ] Manual check in Terminal, iTerm2, Ghostty and Kitty: `dread` (every tab), `dread now`, `dread radar`
- [ ] The repository URL in the User-Agent resolves
- [ ] Provider terms re-checked for any new source
