#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version=${VERSION:?VERSION is required}
build_number=${BUILD_NUMBER:?BUILD_NUMBER is required}
signing_identity=${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}
team_identifier=${TEAM_IDENTIFIER:?TEAM_IDENTIFIER is required}
output_root=${OUTPUT_DIR:-"$repo_root/dist/release"}
app_bundle="$output_root/Agent Remote Device.app"
resolved_network_broker_entitlements="$output_root/NetworkBroker.entitlements"

verify_developer_id_signature() {
  local bundle=$1
  local signature_details
  signature_details=$(codesign --display --verbose=4 "$bundle" 2>&1)
  if [[ $(grep -c '^TeamIdentifier=' <<<"$signature_details") -ne 1 ]] || \
    ! grep -Fxq "TeamIdentifier=$team_identifier" <<<"$signature_details"; then
    echo "signed bundle TeamIdentifier does not match TEAM_IDENTIFIER: $bundle" >&2
    exit 1
  fi
  if ! grep -q '^Authority=Developer ID Application:' <<<"$signature_details"; then
    echo "signed bundle does not use a Developer ID Application certificate: $bundle" >&2
    exit 1
  fi
  if ! grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$signature_details"; then
    echo "signed bundle does not enable Hardened Runtime: $bundle" >&2
    exit 1
  fi
}

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must be a semantic version" >&2
  exit 1
fi
if ! [[ "$build_number" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 1
fi
if ! [[ "$team_identifier" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "TEAM_IDENTIFIER must contain exactly 10 uppercase letters or digits" >&2
  exit 1
fi
if [[ "$signing_identity" == "-" ]]; then
  echo "production release signing does not allow an ad-hoc identity" >&2
  exit 1
fi

outbound_policy_attestor_mach_service=${OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE:?OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE is required}
outbound_policy_attestor_public_key=${OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64:?OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64 is required}
outbound_policy_identifier=${OUTBOUND_POLICY_IDENTIFIER:?OUTBOUND_POLICY_IDENTIFIER is required}
if ! [[ "$outbound_policy_attestor_mach_service" =~ ^[A-Za-z0-9.-]{1,255}$ ]]; then
  echo "OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE must be a fixed mach service identifier" >&2
  exit 1
fi
if ! [[ "$outbound_policy_identifier" =~ ^[A-Za-z0-9.-]{1,255}$ ]]; then
  echo "OUTBOUND_POLICY_IDENTIFIER must be a fixed policy identifier" >&2
  exit 1
fi
if ! [[ "$outbound_policy_attestor_public_key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  echo "OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64 must contain canonical base64" >&2
  exit 1
fi
if ! decoded_public_key_bytes=$(printf '%s' "$outbound_policy_attestor_public_key" | /usr/bin/base64 -D 2>/dev/null | wc -c); then
  echo "OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64 must contain a base64 Ed25519 public key" >&2
  exit 1
fi
decoded_public_key_bytes=${decoded_public_key_bytes//[[:space:]]/}
if [[ "$decoded_public_key_bytes" != "32" ]]; then
  echo "OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64 must decode to 32 bytes" >&2
  exit 1
fi

swift build --package-path "$repo_root" -c release
bin_path=$(swift build --package-path "$repo_root" -c release --show-bin-path)

rm -rf "$app_bundle"
mkdir -p \
  "$app_bundle/Contents/MacOS" \
  "$app_bundle/Contents/Resources" \
  "$app_bundle/Contents/XPCServices"

install -m 0755 "$bin_path/agent-remote-device-dev" \
  "$app_bundle/Contents/MacOS/AgentRemoteDevice"
install -m 0644 "$repo_root/macos/Packaging/App-Info.plist" \
  "$app_bundle/Contents/Info.plist"
install -m 0644 "$repo_root/LICENSE" "$app_bundle/Contents/Resources/LICENSE"
install -m 0644 "$repo_root/NOTICE" "$app_bundle/Contents/Resources/NOTICE"

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

install -m 0644 "$repo_root/macos/Entitlements/NetworkBroker.entitlements" \
  "$resolved_network_broker_entitlements"
/usr/libexec/PlistBuddy -c \
  "Set :keychain-access-groups:0 $team_identifier.dev.agentremote.device.credentials" \
  "$resolved_network_broker_entitlements"

install_xpc_service() {
  local service_name=$1
  local executable_name=$2
  local source_executable=$3
  local source_plist=$4
  local entitlements=$5
  local service_bundle="$app_bundle/Contents/XPCServices/$service_name.xpc"

  mkdir -p "$service_bundle/Contents/MacOS"
  install -m 0755 "$source_executable" "$service_bundle/Contents/MacOS/$executable_name"
  install -m 0644 "$source_plist" "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :AgentRemoteTeamIdentifier $team_identifier" \
    "$service_bundle/Contents/Info.plist"
  if [[ "$service_name" == "AgentRemoteNetworkBroker" ]]; then
    /usr/libexec/PlistBuddy -c \
      "Set :AgentRemoteOutboundPolicyAttestorMachService $outbound_policy_attestor_mach_service" \
      "$service_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
      "Set :AgentRemoteOutboundPolicyAttestorPublicKey $outbound_policy_attestor_public_key" \
      "$service_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
      "Set :AgentRemoteOutboundPolicyIdentifier $outbound_policy_identifier" \
      "$service_bundle/Contents/Info.plist"
  fi
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
    "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
    "$service_bundle/Contents/Info.plist"
  codesign --force --sign "$signing_identity" --options runtime --timestamp \
    --entitlements "$entitlements" "$service_bundle"
  verify_developer_id_signature "$service_bundle"
}

install_xpc_service \
  "AgentRemoteNetworkBroker" \
  "AgentRemoteNetworkBroker" \
  "$bin_path/agent-remote-device-network-broker-xpc" \
  "$repo_root/macos/Packaging/NetworkBroker-Info.plist" \
  "$resolved_network_broker_entitlements"
install_xpc_service \
  "AgentRemoteGUIExecutor" \
  "AgentRemoteGUIExecutor" \
  "$bin_path/agent-remote-device-gui-executor-xpc" \
  "$repo_root/macos/Packaging/GUIExecutor-Info.plist" \
  "$repo_root/macos/Entitlements/GUIExecutor.entitlements"

codesign --force --sign "$signing_identity" --options runtime --timestamp \
  --entitlements "$repo_root/macos/Entitlements/App.entitlements" "$app_bundle"
verify_developer_id_signature "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

printf '%s\n' "$app_bundle"
