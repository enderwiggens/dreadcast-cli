#!/bin/sh
# Builds fully static Linux binaries with the Swift Static Linux SDK.
# Needs a Swift toolchain and static SDK of the same version (see .github/workflows).
set -eu

cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/build-linux.sh <version>}"

grep -q "version = \"$VERSION\"" Sources/DreadcastKit/HTTP.swift || {
  echo "Sources/DreadcastKit/HTTP.swift does not declare version $VERSION." >&2
  exit 1
}

mkdir -p dist
for pair in "x86_64:x86_64" "aarch64:arm64"; do
  triple="${pair%%:*}"
  name="${pair##*:}"
  swift build -c release --swift-sdk "$triple-swift-linux-musl"
  bin="$(swift build -c release --swift-sdk "$triple-swift-linux-musl" --show-bin-path)"
  stage="$(mktemp -d)"
  cp "$bin/dread" "$stage/dread"
  tar -C "$stage" -czf "dist/dread-linux-$name.tar.gz" dread
  rm -rf "$stage"
  (cd dist && sha256sum "dread-linux-$name.tar.gz" > "dread-linux-$name.tar.gz.sha256")
done
ls -l dist
