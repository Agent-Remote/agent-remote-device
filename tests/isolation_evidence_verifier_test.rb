#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"

root = File.expand_path("..", __dir__)
verifier = File.join(root, "scripts", "verify-isolation-evidence.rb")
digest = "a" * 64
team = "AB12CD34EF"
bundles = %w[
  dev.agentremote.device
  dev.agentremote.device.network-broker
  dev.agentremote.device.gui-executor
]
document = {
  "schema_version" => 1,
  "artifact_sha256" => digest,
  "started_at" => "2026-07-30T00:00:00Z",
  "ended_at" => "2026-07-30T00:02:00Z",
  "processes" => bundles.map do |bundle|
    { "bundle_identifier" => bundle, "team_identifier" => team, "executable_sha256" => "b" * 64 }
  end,
  "file_sensor" => {
    "kind" => "endpoint_security", "dropped_events" => 0,
    "watched_prefixes" => [
      "<HOME>/.claude",
      "<HOME>/Library/Application Support/Claude",
      "<HOME>/Library/Containers/com.anthropic.claudefordesktop",
      "<HOME>/Library/Group Containers/group.com.anthropic.claudefordesktop",
    ],
  },
  "network_sensor" => {
    "kind" => "network_extension", "dns_mode" => "controlled", "dropped_events" => 0,
  },
  "file_events" => [
    { "bundle_identifier" => bundles[2], "operation" => "open", "path" => "/System/Library/test" },
  ],
  "network_events" => [
    { "bundle_identifier" => bundles[1], "hostname" => "control.example.test", "port" => 443, "tls" => true },
  ],
}

def verify(verifier, document, digest, team)
  Tempfile.create(["isolation-evidence", ".json"]) do |file|
    file.write(JSON.generate(document))
    file.flush
    return Open3.capture3(
      "ruby", verifier, "--evidence", file.path, "--artifact-sha256", digest,
      "--team-id", team, "--allow-host", "control.example.test"
    )
  end
end

_, stderr, status = verify(verifier, document, digest, team)
abort(stderr) unless status.success?

for mutation in [
  ->(value) { value["file_sensor"]["dropped_events"] = 1 },
  ->(value) { value["file_events"][0]["path"] = "<HOME>/.claude/history.json" },
  ->(value) { value["network_events"][0]["hostname"] = "api.anthropic.com" },
  ->(value) { value["network_events"][0]["bundle_identifier"] = bundles[2] },
  ->(value) { value["artifact_sha256"] = "c" * 64 },
]
  changed = Marshal.load(Marshal.dump(document))
  mutation.call(changed)
  _, _, rejected = verify(verifier, changed, digest, team)
  abort("unsafe isolation evidence was accepted") if rejected.success?
end
