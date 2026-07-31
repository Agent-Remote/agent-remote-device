#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/agent-remote-swift-audit-test.XXXXXX")
cleanup() {
  rm -rf "$temporary"
}
trap cleanup EXIT

mkdir -p "$temporary/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s" "${FAKE_OSV_RESPONSE:?}"' \
  > "$temporary/bin/curl"
chmod 0700 "$temporary/bin/curl"

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

PATH="$temporary/bin:$PATH" \
FAKE_OSV_RESPONSE='{"results":[{},{},{}]}' \
OSV_API_URL='https://osv.invalid/querybatch' \
  "$repo_root/scripts/audit-swift-dependencies.sh" \
    "$repo_root/Package.resolved" "$temporary/swift-osv.json" >/dev/null
jq -e '
  .schema_version == 1
  and .source == "OSV"
  and (.dependencies | length == 3)
  and (.vulnerability_ids == [])
' "$temporary/swift-osv.json" >/dev/null

expect_failure \
  'OSV-TEST-0001' \
  env PATH="$temporary/bin:$PATH" \
  FAKE_OSV_RESPONSE='{"results":[{"vulns":[{"id":"OSV-TEST-0001"}]},{},{}]}' \
  OSV_API_URL='https://osv.invalid/querybatch' \
  "$repo_root/scripts/audit-swift-dependencies.sh" \
    "$repo_root/Package.resolved" "$temporary/swift-osv-vulnerable.json"
jq -e '.vulnerability_ids == ["OSV-TEST-0001"]' \
  "$temporary/swift-osv-vulnerable.json" >/dev/null

expect_failure \
  'OSV returned an invalid Swift dependency response' \
  env PATH="$temporary/bin:$PATH" \
  FAKE_OSV_RESPONSE='{"results":[]}' \
  OSV_API_URL='https://osv.invalid/querybatch' \
  "$repo_root/scripts/audit-swift-dependencies.sh" "$repo_root/Package.resolved"

printf '%s\n' '{"version":3,"pins":[]}' > "$temporary/Package.resolved"
expect_failure \
  'unsupported or unpinned Swift dependency' \
  env PATH="$temporary/bin:$PATH" \
  FAKE_OSV_RESPONSE='{"results":[]}' \
  OSV_API_URL='https://osv.invalid/querybatch' \
  "$repo_root/scripts/audit-swift-dependencies.sh" "$temporary/Package.resolved"
