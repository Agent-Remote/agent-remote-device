#!/usr/bin/env ruby
# frozen_string_literal: true

root = File.expand_path("..", __dir__)
activation_sources = [
  "macos/GUIExecutor/WindowCapture.swift",
]

activation_sources.each do |relative|
  source = File.read(File.join(root, relative))
  unless source.match?(/try\?\s+await\s+NSWorkspace\.shared\.openApplication\s*\(/m)
    abort("#{relative} must use the async NSWorkspace application activation API")
  end
  if source.match?(/NSWorkspace\.shared\.openApplication\s*\(.*?configuration:\s*configuration\s*\)\s*\{/m)
    abort("#{relative} must not use an actor-isolated NSWorkspace completion handler")
  end
end

discovery_source = File.read(File.join(root, "macos/App/LocalApplicationDiscovery.swift"))
if discovery_source.match?(/\b(?:activate|openApplication|AXUIElement)\b/)
  abort("LocalApplicationDiscovery.swift must not activate applications")
end

Dir.glob(File.join(root, "macos/**/*.swift")).each do |path|
  source = File.read(path)
  next unless source.match?(/\bweak\s+let\b/)

  abort("#{path.delete_prefix("#{root}/")} must not use weak let because release Swift requires weak var")
end
