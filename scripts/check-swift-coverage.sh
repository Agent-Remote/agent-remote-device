#!/usr/bin/env bash
set -euo pipefail

minimum_lines=${SWIFT_COVERAGE_MINIMUM:-55}
profile=${SWIFT_COVERAGE_PROFILE:-.build/debug/codecov/default.profdata}
test_binary=${SWIFT_COVERAGE_BINARY:-.build/debug/AgentRemoteDevicePackageTests.xctest/Contents/MacOS/AgentRemoteDevicePackageTests}

test -f "$profile"
test -x "$test_binary"

report=$(xcrun llvm-cov report \
  -instr-profile "$profile" \
  "$test_binary" \
  -ignore-filename-regex='(/\.build/checkouts/|/Tests/|/\.build/)')
coverage=$(awk '$1 == "TOTAL" {value=$4; gsub(/%/, "", value); print value}' <<<"$report")

if [[ -z "$coverage" ]] || ! awk -v actual="$coverage" -v minimum="$minimum_lines" \
  'BEGIN { exit !(actual + 0 >= minimum + 0) }'; then
  echo "Swift line coverage ${coverage:-unknown}% is below ${minimum_lines}%" >&2
  exit 1
fi

echo "Swift line coverage: $coverage% (minimum $minimum_lines%)"
