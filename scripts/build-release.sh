#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
VERSION="${1:?Usage: scripts/build-release.sh <version>}"

SELECTED_DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [[ -z "${DEVELOPER_DIR:-}" && "$SELECTED_DEVELOPER_DIR" != *.app/Contents/Developer && -d /Applications/Xcode.app/Contents/Developer ]]; then
  SELECTED_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
export DEVELOPER_DIR="$SELECTED_DEVELOPER_DIR"

grep -q "version = \"$VERSION\"" Sources/DreadcastKit/HTTP.swift || {
  echo "Sources/DreadcastKit/HTTP.swift does not declare version $VERSION." >&2
  exit 1
}

xcrun swift build -c release --arch arm64 --arch x86_64
mkdir -p dist
cp .build/apple/Products/Release/dread dist/dread

if [[ -n "${DREADCAST_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$DREADCAST_SIGNING_IDENTITY" dist/dread
  codesign --verify --strict dist/dread
fi

lipo -info dist/dread
(cd dist && ditto -c -k --keepParent dread "dread-$VERSION-macos.zip" && shasum -a 256 "dread-$VERSION-macos.zip" > "dread-$VERSION-macos.zip.sha256")
echo "Built dist/dread-$VERSION-macos.zip"
