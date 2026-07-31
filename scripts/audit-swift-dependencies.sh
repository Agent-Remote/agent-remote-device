#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
resolved_file=${1:-"$repo_root/Package.resolved"}
report_file=${2:-}
osv_api_url=${OSV_API_URL:-https://api.osv.dev/v1/querybatch}

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required for the Swift dependency audit" >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required for the Swift dependency audit" >&2
  exit 1
fi
if [[ ! -f "$resolved_file" || -L "$resolved_file" ]]; then
  echo "Package.resolved must be a regular non-symlink file" >&2
  exit 1
fi

if ! jq -e '
  .version == 3
  and (.pins | type == "array" and length > 0)
  and all(.pins[];
    .kind == "remoteSourceControl"
    and (.identity | type == "string" and length > 0)
    and (.location | type == "string" and test("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\\.git)?$"))
    and (.state.version | type == "string" and test("^[0-9]+\\.[0-9]+\\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$"))
    and (.state.revision | type == "string" and test("^[0-9a-f]{40}$"))
  )
' "$resolved_file" >/dev/null; then
  echo "Package.resolved contains an unsupported or unpinned Swift dependency" >&2
  exit 1
fi

query_file=$(mktemp "${TMPDIR:-/tmp}/agent-remote-swift-osv-query.XXXXXX")
response_file=$(mktemp "${TMPDIR:-/tmp}/agent-remote-swift-osv-response.XXXXXX")
cleanup() {
  rm -f "$query_file" "$response_file"
}
trap cleanup EXIT

jq '{
  queries: [.pins[] | {
    package: {ecosystem: "SwiftURL", name: .location},
    version: .state.version
  }]
}' "$resolved_file" > "$query_file"

curl --fail --silent --show-error \
  --connect-timeout 10 \
  --max-time 30 \
  --retry 2 \
  --max-filesize 1048576 \
  --header 'Content-Type: application/json' \
  --data-binary "@$query_file" \
  "$osv_api_url" > "$response_file"

dependency_count=$(jq '.pins | length' "$resolved_file")
if ! jq -e --argjson count "$dependency_count" '
  (.results | type == "array" and length == $count)
  and all(.results[]; type == "object")
' "$response_file" >/dev/null; then
  echo "OSV returned an invalid Swift dependency response" >&2
  exit 1
fi

if [[ -n "$report_file" ]]; then
  report_directory=$(dirname "$report_file")
  if [[ ! -d "$report_directory" || -L "$report_directory" ]]; then
    echo "Swift dependency audit report directory is invalid" >&2
    exit 1
  fi
  report_temporary=$(mktemp "$report_file.XXXXXX")
  jq --slurpfile osv "$response_file" '
    . as $resolved
    | {
        schema_version: 1,
        source: "OSV",
        dependencies: [
          range(0; $resolved.pins | length) as $index
          | $resolved.pins[$index]
          | {
              identity,
              location,
              version: .state.version,
              revision: .state.revision,
              vulnerabilities: ($osv[0].results[$index].vulns // [])
            }
        ],
        vulnerability_ids: [$osv[0].results[]?.vulns[]?.id] | unique
      }
  ' "$resolved_file" > "$report_temporary"
  mv "$report_temporary" "$report_file"
fi

vulnerability_ids=$(jq -r '[.results[]?.vulns[]?.id] | unique | .[]' "$response_file")
if [[ -n "$vulnerability_ids" ]]; then
  echo "Swift dependency audit found known vulnerabilities:" >&2
  printf '%s\n' "$vulnerability_ids" >&2
  exit 1
fi

printf 'Swift dependency audit passed for %s pinned packages\n' "$dependency_count"
