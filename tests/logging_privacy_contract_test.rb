#!/usr/bin/env ruby
# frozen_string_literal: true

root = File.expand_path("..", __dir__)
swift_files = Dir.glob(File.join(root, "macos", "**", "*.swift"))
rust_files = Dir.glob(File.join(root, "proxy", "src", "**", "*.rs"))
log_call = /\.(?:debug|info|notice|warning|error|fault)\s*\((.*?)\)/m
sensitive_terms = /(?:access_token|authorization|base64_data|clipboard|payload|window_title)/i

for path in swift_files
  source = File.read(path)
  next unless source.include?("Logger(") || source.include?("OSLog")

  source.to_enum(:scan, log_call).each do
    body = Regexp.last_match(1)
    line = source[0...Regexp.last_match.begin(0)].count("\n") + 1
    if body.include?("\\(") || body.match?(/String\s*\(\s*describing:/)
      abort("dynamic unified-log content is forbidden: #{path}:#{line}")
    end
    if body.match?(sensitive_terms)
      abort("sensitive unified-log field is forbidden: #{path}:#{line}")
    end
  end
end

for path in rust_files
  File.read(path).each_line.with_index(1) do |line, number|
    next unless line.match?(/\b(?:println|eprintln|dbg|trace|debug|info|warn|error)!/)
    abort("runtime logging macro is forbidden in the device proxy: #{path}:#{number}")
  end
end

hardening = {
  "macos/App/AgentRemoteDeviceApp.swift" => "DeviceProcessHardening.disableCoreDumps()",
  "macos/NetworkBrokerService/main.swift" => "DeviceProcessHardening.disableCoreDumps()",
  "macos/GUIExecutorService/main.swift" => "DeviceProcessHardening.disableCoreDumps()",
  "proxy/src/main.rs" => "disable_core_dumps()?",
}
hardening.each do |relative, required|
  path = File.join(root, relative)
  abort("#{relative} does not disable core dumps before serving") unless File.read(path).include?(required)
end
