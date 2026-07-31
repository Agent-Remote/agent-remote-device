#!/usr/bin/env bash
set -euo pipefail

package_version=$(cargo metadata --format-version=1 --no-deps | python3 -c \
  'import json,sys; data=json.load(sys.stdin); print(next(p["version"] for p in data["packages"] if p["name"] == "agent-remote-device-proxy"))')
VERSION="${VERSION:-$package_version}"
TARGET="${TARGET:-x86_64-unknown-linux-gnu}"
OUT_DIR="${OUT_DIR:-dist/device-proxies}"
BUILD_TOOL="${BUILD_TOOL:-cargo}"

if ! [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]]; then
  echo "invalid proxy version" >&2
  exit 2
fi
if [ "$VERSION" != "$package_version" ]; then
  echo "proxy release version does not match the Rust package version" >&2
  exit 2
fi

case "$TARGET" in
  x86_64-unknown-linux-gnu) label="linux-amd64-glibc" ;;
  aarch64-unknown-linux-gnu) label="linux-arm64-glibc" ;;
  x86_64-unknown-linux-musl) label="linux-amd64-musl" ;;
  aarch64-unknown-linux-musl) label="linux-arm64-musl" ;;
  *) echo "unsupported proxy target: $TARGET" >&2; exit 2 ;;
esac

case "$BUILD_TOOL" in
  cargo|cross|cargo-zigbuild) ;;
  *) echo "BUILD_TOOL must be cargo, cross, or cargo-zigbuild" >&2; exit 2 ;;
esac

if [ "$BUILD_TOOL" = "cargo-zigbuild" ]; then
  cargo zigbuild --locked --release --target "$TARGET" --package agent-remote-device-proxy
else
  "$BUILD_TOOL" build --locked --release --target "$TARGET" --package agent-remote-device-proxy
fi

source_binary="target/$TARGET/release/agent-remote-device-proxy"
if [ ! -f "$source_binary" ] || [ -L "$source_binary" ] || [ ! -x "$source_binary" ]; then
  echo "proxy build did not produce a regular executable" >&2
  exit 1
fi

destination="$OUT_DIR/$label"
mkdir -p "$destination"
install -m 0755 "$source_binary" "$destination/agent-remote-device-proxy"
printf '%s\n' "$VERSION" > "$destination/VERSION"
(
  cd "$destination"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum agent-remote-device-proxy > SHA256SUMS
  else
    shasum -a 256 agent-remote-device-proxy > SHA256SUMS
  fi
)

echo "proxy release artifact written to $destination"
