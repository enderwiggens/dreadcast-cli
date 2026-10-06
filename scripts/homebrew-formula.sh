#!/bin/sh
# Prints the Homebrew formula for a published release, with each archive's checksum
# read from the release's .sha256 files:
#   scripts/homebrew-formula.sh 0.2.0 > ../homebrew-dreadcast/Formula/dreadcast.rb
set -eu

VERSION="${1:?Usage: scripts/homebrew-formula.sh <version>}"
BASE="https://github.com/enderwiggens/dreadcast-cli/releases/download/v$VERSION"

checksum() {
  line="$(curl -fsSL "$BASE/$1.sha256")" || {
    echo "Couldn't read $BASE/$1.sha256. Has the release finished uploading?" >&2
    exit 1
  }
  value="${line%% *}"
  case "$value" in
    *[!0-9a-f]* | "") echo "Unexpected checksum for $1: $value" >&2; exit 1 ;;
  esac
  [ "${#value}" -eq 64 ] || { echo "Unexpected checksum for $1: $value" >&2; exit 1; }
  printf '%s' "$value"
}

MACOS="$(checksum dread-macos-universal.zip)"
LINUX_X86="$(checksum dread-linux-x86_64.tar.gz)"
LINUX_ARM="$(checksum dread-linux-arm64.tar.gz)"

cat <<FORMULA
class Dreadcast < Formula
  desc "Weather and radar for the command line"
  homepage "https://github.com/enderwiggens/dreadcast-cli"
  version "$VERSION"
  license "Apache-2.0"

  on_macos do
    depends_on macos: :ventura
    url "$BASE/dread-macos-universal.zip"
    sha256 "$MACOS"
  end

  on_linux do
    on_intel do
      url "$BASE/dread-linux-x86_64.tar.gz"
      sha256 "$LINUX_X86"
    end
    on_arm do
      url "$BASE/dread-linux-arm64.tar.gz"
      sha256 "$LINUX_ARM"
    end
  end

  def install
    bin.install "dread"
  end

  def caveats
    <<~EOS
      Choose a location to get started:
        dread setup
      Then run dread to open the app, or dread now for a quick look.
    EOS
  end

  test do
    assert_match "dread #{version}", shell_output("#{bin}/dread version")
  end
end
FORMULA
