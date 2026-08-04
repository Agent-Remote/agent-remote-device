#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_root="$repo_root/dist/development"
app_bundle="$output_root/Agent Remote Device.app"
package_version=$(cargo metadata --format-version=1 --no-deps | python3 -c \
  'import json,sys; data=json.load(sys.stdin); print(next(p["version"] for p in data["packages"] if p["name"] == "agent-remote-device-proxy"))')
version=${VERSION:-$package_version}
build_number=${BUILD_NUMBER:-1}

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "development VERSION must use the numeric Apple bundle version format" >&2
  exit 2
fi
if [ "$version" != "$package_version" ]; then
  echo "development app version does not match the Device package version" >&2
  exit 2
fi
if ! [[ "$build_number" =~ ^[1-9][0-9]*$ ]]; then
  echo "development BUILD_NUMBER must be a positive integer" >&2
  exit 2
fi

swift build --package-path "$repo_root" -c debug
bin_path=$(swift build --package-path "$repo_root" -c debug --show-bin-path)

rm -rf "$app_bundle"
mkdir -p \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Resources" \
  "$app_bundle/Contents/XPCServices"

install -m 0755 "$bin_path/agent-remote-device-dev" \
  "$app_bundle/Contents/MacOS/AgentRemoteDevice"
install -m 0644 "$repo_root/macos/Packaging/App-Info.plist" \
  "$app_bundle/Contents/Info.plist"
install -m 0644 "$repo_root/macos/Packaging/AppIcon.icns" \
  "$app_bundle/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
  "$app_bundle/Contents/Info.plist"

cp -R "$repo_root/macos/App/Resources/." "$app_bundle/Contents/Resources/"
for locale in en zh-Hans; do
  if [[ ! -f "$app_bundle/Contents/Resources/$locale.lproj/Localizable.strings" ]]; then
    echo "required localization is missing: $locale" >&2
    exit 1
  fi
done

install_xpc_service() {
  local service_name=$1
  local executable_name=$2
  local source_executable=$3
  local source_plist=$4
  local service_bundle="$app_bundle/Contents/XPCServices/$service_name.xpc"

  mkdir -p "$service_bundle/Contents/MacOS"
  install -m 0755 "$source_executable" "$service_bundle/Contents/MacOS/$executable_name"
  install -m 0644 "$source_plist" "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
    "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
    "$service_bundle/Contents/Info.plist"
  codesign --force --sign - --timestamp=none "$service_bundle"
}

install_xpc_service \
  "AgentRemoteNetworkBroker" \
  "AgentRemoteNetworkBroker" \
  "$bin_path/agent-remote-device-network-broker-xpc" \
  "$repo_root/macos/Packaging/NetworkBroker-Info.plist"
install_xpc_service \
  "AgentRemoteGUIExecutor" \
  "AgentRemoteGUIExecutor" \
  "$bin_path/agent-remote-device-gui-executor-xpc" \
  "$repo_root/macos/Packaging/GUIExecutor-Info.plist"

codesign --force --sign - --timestamp=none "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf '%s\n' "$app_bundle"
