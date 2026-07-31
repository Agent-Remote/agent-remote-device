#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version=${VERSION:?VERSION is required}
build_number=${BUILD_NUMBER:?BUILD_NUMBER is required}
signing_identity=${SIGNING_IDENTITY:?SIGNING_IDENTITY is required}
signer_certificate_sha1=${SIGNER_CERTIFICATE_SHA1:?SIGNER_CERTIFICATE_SHA1 is required}
output_root=${OUTPUT_DIR:-"$repo_root/dist/community-release"}
app_bundle="$output_root/Agent Remote Device.app"
signing_record="$output_root/community-signing-$version.json"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
  echo "VERSION must be a semantic version" >&2
  exit 2
fi
if ! [[ "$build_number" =~ ^[1-9][0-9]{0,8}$ ]]; then
  echo "BUILD_NUMBER must be a positive integer" >&2
  exit 2
fi
if ! [[ "$signer_certificate_sha1" =~ ^[A-F0-9]{40}$ ]]; then
  echo "SIGNER_CERTIFICATE_SHA1 must be 40 uppercase hexadecimal characters" >&2
  exit 2
fi
if [[ "$signing_identity" == "-" ]]; then
  echo "community releases require a persistent self-signed identity" >&2
  exit 2
fi

certificate_pem=$(mktemp)
trap 'rm -f "$certificate_pem"' EXIT
security find-certificate -c "$signing_identity" -p > "$certificate_pem"
openssl x509 -in "$certificate_pem" -noout -checkend 2592000 >/dev/null
actual_certificate_sha1=$(
  openssl x509 -in "$certificate_pem" -noout -fingerprint -sha1 \
    | cut -d= -f2 | tr -d ':' | tr '[:lower:]' '[:upper:]'
)
if [[ "$actual_certificate_sha1" != "$signer_certificate_sha1" ]]; then
  echo "signing certificate does not match SIGNER_CERTIFICATE_SHA1" >&2
  exit 1
fi
certificate_sha256=$(
  openssl x509 -in "$certificate_pem" -outform DER \
    | shasum -a 256 | awk '{print $1}'
)

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
/usr/libexec/PlistBuddy -c \
  "Add :AgentRemoteSignerCertificateSHA1 string $signer_certificate_sha1" \
  "$app_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c \
  "Add :AgentRemoteReleaseProfile string community-local-trust" \
  "$app_bundle/Contents/Info.plist"

cp -R "$repo_root/macos/App/Resources/." "$app_bundle/Contents/Resources/"
for locale in en zh-Hans; do
  test -f "$app_bundle/Contents/Resources/$locale.lproj/Localizable.strings"
done

verify_community_signature() {
  local bundle=$1
  local signature_details
  signature_details=$(codesign --display --verbose=4 "$bundle" 2>&1)
  grep -Fxq "Authority=$signing_identity" <<<"$signature_details"
  grep -Eq '^CodeDirectory .*flags=.*\(.*runtime.*\)' <<<"$signature_details"
  codesign --verify --strict --verbose=2 "$bundle"
}

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
  /usr/libexec/PlistBuddy -c \
    "Add :AgentRemoteSignerCertificateSHA1 string $signer_certificate_sha1" \
    "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
    "$service_bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" \
    "$service_bundle/Contents/Info.plist"
  if [[ "$service_name" == "AgentRemoteNetworkBroker" ]]; then
    /usr/libexec/PlistBuddy -c \
      "Add :AgentRemoteOutboundPolicyMode string application" \
      "$service_bundle/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c \
      "Add :AgentRemoteCredentialMode string community-file" \
      "$service_bundle/Contents/Info.plist"
  fi
  codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
    --entitlements "$entitlements" "$service_bundle"
  verify_community_signature "$service_bundle"
}

install_xpc_service \
  "AgentRemoteNetworkBroker" \
  "AgentRemoteNetworkBroker" \
  "$bin_path/agent-remote-device-network-broker-xpc" \
  "$repo_root/macos/Packaging/NetworkBroker-Info.plist" \
  "$repo_root/macos/Entitlements/NetworkBrokerCommunity.entitlements"
install_xpc_service \
  "AgentRemoteGUIExecutor" \
  "AgentRemoteGUIExecutor" \
  "$bin_path/agent-remote-device-gui-executor-xpc" \
  "$repo_root/macos/Packaging/GUIExecutor-Info.plist" \
  "$repo_root/macos/Entitlements/GUIExecutor.entitlements"

codesign --force --sign "$signing_identity" --options runtime --timestamp=none \
  --entitlements "$repo_root/macos/Entitlements/App.entitlements" "$app_bundle"
verify_community_signature "$app_bundle"
codesign --verify --deep --strict --verbose=2 "$app_bundle"

jq -n \
  --arg version "$version" \
  --arg certificate_sha1 "$signer_certificate_sha1" \
  --arg certificate_sha256 "$certificate_sha256" \
  '{
    schema_version: 1,
    release_version: $version,
    profile: "community-local-trust",
    production_ready: true,
    apple_notarized: false,
    public_distribution: false,
    signing_type: "project-self-signed",
    signer_certificate_sha1: $certificate_sha1,
    signer_certificate_sha256: $certificate_sha256,
    application_signature_verified: true,
    nested_signatures_verified: true,
    hardened_runtime: true,
    outbound_policy: "application-enforced"
  }' > "$signing_record"

printf '%s\n' "$app_bundle"
