#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "time"

FIXED_BUNDLES = %w[
  dev.agentremote.device
  dev.agentremote.device.network-broker
  dev.agentremote.device.gui-executor
].freeze
CLAUDE_PREFIXES = [
  "<HOME>/.claude",
  "<HOME>/Library/Application Support/Claude",
  "<HOME>/Library/Containers/com.anthropic.claudefordesktop",
  "<HOME>/Library/Group Containers/group.com.anthropic.claudefordesktop",
].freeze
HEX_256 = /\A[0-9a-f]{64}\z/
TEAM_ID = /\A[A-Z0-9]{10}\z/

options = { allowed_hosts: [] }
OptionParser.new do |parser|
  parser.on("--evidence PATH") { |value| options[:evidence] = value }
  parser.on("--artifact-sha256 HEX") { |value| options[:artifact_sha256] = value }
  parser.on("--team-id ID") { |value| options[:team_id] = value }
  parser.on("--allow-host HOST") { |value| options[:allowed_hosts] << value }
end.parse!

def fail_evidence(message)
  warn(message)
  exit(1)
end

required_options = %i[evidence artifact_sha256 team_id]
fail_evidence("required isolation evidence options are missing") if required_options.any? { |key| options[key].nil? }
fail_evidence("at least one exact allowed host is required") if options[:allowed_hosts].empty?
fail_evidence("artifact digest is invalid") unless options[:artifact_sha256].match?(HEX_256)
fail_evidence("Team ID is invalid") unless options[:team_id].match?(TEAM_ID)
unless options[:allowed_hosts].all? { |host| host.match?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/) }
  fail_evidence("allowed hosts must be normalized DNS names")
end

begin
  document = JSON.parse(File.read(options[:evidence], 2 * 1024 * 1024))
rescue StandardError => e
  fail_evidence("isolation evidence is unreadable: #{e.class}")
end

top_keys = %w[
  schema_version artifact_sha256 started_at ended_at processes file_sensor network_sensor
  file_events network_events
]
fail_evidence("isolation evidence fields are invalid") unless document.is_a?(Hash) && document.keys.sort == top_keys.sort
fail_evidence("isolation evidence schema is unsupported") unless document["schema_version"] == 1
unless document["artifact_sha256"] == options[:artifact_sha256]
  fail_evidence("isolation evidence is not bound to the release artifact")
end

begin
  started_at = Time.iso8601(document.fetch("started_at"))
  ended_at = Time.iso8601(document.fetch("ended_at"))
rescue StandardError
  fail_evidence("isolation evidence timestamps are invalid")
end
duration = ended_at - started_at
fail_evidence("isolation observation must last between 60 seconds and 24 hours") unless (60..86_400).cover?(duration)

processes = document["processes"]
unless processes.is_a?(Array) && processes.length == FIXED_BUNDLES.length
  fail_evidence("all fixed device processes must be observed exactly once")
end
observed_bundles = processes.map do |process|
  expected = %w[bundle_identifier executable_sha256 team_identifier]
  fail_evidence("process evidence fields are invalid") unless process.is_a?(Hash) && process.keys.sort == expected.sort
  fail_evidence("process Team ID does not match") unless process["team_identifier"] == options[:team_id]
  fail_evidence("process executable digest is invalid") unless process["executable_sha256"].match?(HEX_256)
  process["bundle_identifier"]
end
fail_evidence("process bundle identities are incomplete") unless observed_bundles.sort == FIXED_BUNDLES.sort

file_sensor = document["file_sensor"]
expected_file_sensor = %w[dropped_events kind watched_prefixes]
unless file_sensor.is_a?(Hash) && file_sensor.keys.sort == expected_file_sensor.sort &&
       file_sensor["kind"] == "endpoint_security" && file_sensor["dropped_events"] == 0 &&
       file_sensor["watched_prefixes"].sort == CLAUDE_PREFIXES.sort
  fail_evidence("Endpoint Security evidence is incomplete or dropped events")
end

network_sensor = document["network_sensor"]
expected_network_sensor = %w[dns_mode dropped_events kind]
unless network_sensor.is_a?(Hash) && network_sensor.keys.sort == expected_network_sensor.sort &&
       network_sensor["kind"] == "network_extension" && network_sensor["dns_mode"] == "controlled" &&
       network_sensor["dropped_events"] == 0
  fail_evidence("Network Extension evidence is incomplete or dropped events")
end

file_events = document["file_events"]
fail_evidence("file events must be an array") unless file_events.is_a?(Array)
file_events.each do |event|
  expected = %w[bundle_identifier operation path]
  fail_evidence("file event fields are invalid") unless event.is_a?(Hash) && event.keys.sort == expected.sort
  fail_evidence("file event process is not a device component") unless FIXED_BUNDLES.include?(event["bundle_identifier"])
  fail_evidence("file event operation is invalid") unless %w[open create write rename unlink].include?(event["operation"])
  path = event["path"]
  normalized_path = path.is_a?(String) && (path.start_with?("/") || path.start_with?("<HOME>/"))
  fail_evidence("file event path is not normalized") unless normalized_path
  if CLAUDE_PREFIXES.any? { |prefix| path == prefix || path.start_with?("#{prefix}/") }
    fail_evidence("device component accessed a local Claude data path")
  end
end

network_events = document["network_events"]
fail_evidence("network events must be a non-empty array") unless network_events.is_a?(Array) && !network_events.empty?
network_events.each do |event|
  expected = %w[bundle_identifier hostname port tls]
  fail_evidence("network event fields are invalid") unless event.is_a?(Hash) && event.keys.sort == expected.sort
  unless event["bundle_identifier"] == "dev.agentremote.device.network-broker"
    fail_evidence("a non-broker device process opened a network connection")
  end
  fail_evidence("network destination is outside the exact allowlist") unless options[:allowed_hosts].include?(event["hostname"])
  fail_evidence("device network connection is not TLS on port 443") unless event["tls"] == true && event["port"] == 443
end

puts "Isolation evidence verified for #{duration.to_i} seconds"
