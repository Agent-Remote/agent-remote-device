#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
app_bundle="$repo_root/dist/development/Agent Remote Device.app"
app_executable="$app_bundle/Contents/MacOS/AgentRemoteDevice"
broker_executable="$app_bundle/Contents/XPCServices/AgentRemoteNetworkBroker.xpc/Contents/MacOS/AgentRemoteNetworkBroker"
executor_executable="$app_bundle/Contents/XPCServices/AgentRemoteGUIExecutor.xpc/Contents/MacOS/AgentRemoteGUIExecutor"

"$repo_root/scripts/build-development-app.sh" >/dev/null
open -n "$app_bundle"

app_pid=""
cleanup() {
  if [[ -n "$app_pid" ]]; then
    kill "$app_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for _ in {1..50}; do
  app_pid=$(pgrep -f -x "$app_executable" || true)
  broker_pid=$(pgrep -f -x "$broker_executable" || true)
  executor_pid=$(pgrep -f -x "$executor_executable" || true)
  if [[ -n "$app_pid" && -n "$broker_pid" && -n "$executor_pid" ]]; then
    break
  fi
  sleep 0.2
done

if [[ -z "$app_pid" || -z "${broker_pid:-}" || -z "${executor_pid:-}" ]]; then
  echo "development XPC process chain did not start" >&2
  exit 1
fi

for _ in {1..25}; do
  if /usr/bin/log show --last 2m --style compact \
    --predicate "processIdentifier == $app_pid AND subsystem == \"dev.agentremote.device\" AND category == \"xpc-health\"" \
    | grep -Fq 'Secure XPC chain ready'; then
    exit 0
  fi
  sleep 0.2
done

echo "development XPC health marker was not emitted" >&2
exit 1
