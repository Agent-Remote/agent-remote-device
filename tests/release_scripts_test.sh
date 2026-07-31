#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
release_script="$repo_root/scripts/build-release-app.sh"
development_script="$repo_root/scripts/build-development-app.sh"
proxy_script="$repo_root/scripts/package-proxy-release.sh"
prepare_version_script="$repo_root/scripts/prepare-version.sh"

expect_failure() {
  local expected=$1
  shift
  local output
  if output=$("$@" 2>&1); then
    echo "expected command to fail" >&2
    exit 1
  fi
  if [[ "$output" != *"$expected"* ]]; then
    echo "missing expected error: $expected" >&2
    echo "$output" >&2
    exit 1
  fi
}

expect_failure \
  "VERSION must be a semantic version" \
  env VERSION=invalid BUILD_NUMBER=1 SIGNING_IDENTITY=Developer TEAM_IDENTIFIER=AB12CD34EF \
  "$release_script"
expect_failure \
  "proxy release version does not match the Rust package version" \
  env VERSION=999.0.0 "$proxy_script"
expect_failure \
  "invalid semantic version" \
  "$prepare_version_script" invalid
expect_failure \
  "TEAM_IDENTIFIER must contain exactly 10 uppercase letters or digits" \
  env VERSION=1.0.0 BUILD_NUMBER=1 SIGNING_IDENTITY=Developer TEAM_IDENTIFIER=invalid \
  "$release_script"
expect_failure \
  "production release signing does not allow an ad-hoc identity" \
  env VERSION=1.0.0 BUILD_NUMBER=1 SIGNING_IDENTITY=- TEAM_IDENTIFIER=AB12CD34EF \
  "$release_script"
expect_failure \
  "OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE is required" \
  env VERSION=1.0.0 BUILD_NUMBER=1 SIGNING_IDENTITY=Developer TEAM_IDENTIFIER=AB12CD34EF \
  "$release_script"
expect_failure \
  "OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64 must contain canonical base64" \
  env VERSION=1.0.0 BUILD_NUMBER=1 SIGNING_IDENTITY=Developer TEAM_IDENTIFIER=AB12CD34EF \
  OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE=dev.example.policy \
  OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64=invalid \
  OUTBOUND_POLICY_IDENTIFIER=dev.example.production \
  "$release_script"

mock_root=$(mktemp -d)
trap 'rm -rf "$mock_root"' EXIT
mkdir -p "$mock_root/bin" "$mock_root/work"
cat > "$mock_root/bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  metadata)
    printf '%s\n' '{"packages":[{"name":"agent-remote-device-proxy","version":"0.1.0"}]}'
    ;;
  build)
    target=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--target" ]; then
        target=$2
        break
      fi
      shift
    done
    test -n "$target"
    mkdir -p "target/$target/release"
    printf '#!/usr/bin/env bash\nexit 0\n' > \
      "target/$target/release/agent-remote-device-proxy"
    chmod 0755 "target/$target/release/agent-remote-device-proxy"
    ;;
  *)
    echo "unexpected cargo command: ${1:-}" >&2
    exit 1
    ;;
esac
SH
chmod 0755 "$mock_root/bin/cargo"
(
  cd "$mock_root/work"
  PATH="$mock_root/bin:$PATH" \
    VERSION=0.1.0 \
    TARGET=x86_64-unknown-linux-gnu \
    OUT_DIR="$mock_root/output" \
    BUILD_TOOL=cargo \
    "$proxy_script"
)
(
  cd "$mock_root/output/linux-amd64-glibc"
  shasum -a 256 --check SHA256SUMS
)
if grep -Fq "$mock_root" "$mock_root/output/linux-amd64-glibc/SHA256SUMS"; then
  echo "proxy checksum manifest contains a build-time path" >&2
  exit 1
fi

for field in \
  AgentRemoteOutboundPolicyAttestorMachService \
  AgentRemoteOutboundPolicyAttestorPublicKey \
  AgentRemoteOutboundPolicyIdentifier; do
  if ! grep -Fq "$field" "$release_script"; then
    echo "release build does not pin $field" >&2
    exit 1
  fi
done

for signature_check in \
  'TeamIdentifier=$team_identifier' \
  'Authority=Developer ID Application:' \
  'flags=.*\(.*runtime.*\)' \
  'verify_developer_id_signature "$service_bundle"' \
  'verify_developer_id_signature "$app_bundle"'; do
  if ! grep -Fq "$signature_check" "$release_script"; then
    echo "release build does not enforce signature metadata: $signature_check" >&2
    exit 1
  fi
done

for script in "$release_script" "$development_script"; do
  if ! grep -Fq 'Contents/Resources/$locale.lproj/Localizable.strings' "$script"; then
    echo "localization catalog check is missing from $script" >&2
    exit 1
  fi
  if ! grep -Fq 'macos/App/Resources/.' "$script"; then
    echo "localization catalog installation is missing from $script" >&2
    exit 1
  fi
done

for version_check in \
  'development app version does not match the Device package version' \
  'Set :CFBundleShortVersionString $version' \
  'Set :CFBundleVersion $build_number'; do
  if ! grep -Fq "$version_check" "$development_script"; then
    echo "development build version binding is missing: $version_check" >&2
    exit 1
  fi
done
