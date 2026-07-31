# frozen_string_literal: true

repository_root = File.expand_path("..", __dir__)
catalog_paths = {
  "en" => File.join(repository_root, "macos/App/Resources/en.lproj/Localizable.strings"),
  "zh-Hans" => File.join(
    repository_root,
    "macos/App/Resources/zh-Hans.lproj/Localizable.strings"
  ),
}.freeze

def catalog_keys(path)
  keys = []
  File.readlines(path, chomp: true).each do |line|
    next if line.strip.empty?

    match = line.match(/\A"([a-z0-9_.]+)"\s*=\s*".+";\z/)
    raise "invalid localization entry in #{path}: #{line}" unless match

    keys << match[1]
  end
  raise "duplicate localization key in #{path}" unless keys.uniq.length == keys.length

  keys.sort
end

catalogs = catalog_paths.transform_values { |path| catalog_keys(path) }
reference_keys = catalogs.fetch("en")
catalogs.each do |locale, keys|
  raise "#{locale} localization keys differ from English" unless keys == reference_keys
end

source_paths = [
  File.join(repository_root, "macos/App/DeviceStatusView.swift"),
  File.join(repository_root, "macos/AppCore/DeviceAppModel.swift"),
]
source = source_paths.map { |path| File.read(path) }.join("\n")
used_keys = source.scan(/localized(?:App|Core)String\(\s*"([a-z0-9_.]+)"/).flatten.uniq
missing_keys = used_keys - reference_keys
raise "localization keys are missing: #{missing_keys.join(', ')}" unless missing_keys.empty?

view_source = File.read(File.join(repository_root, "macos/App/DeviceStatusView.swift"))
hard_coded = view_source.scan(
  /(?:Text|Label|Button|Picker|ContentUnavailableView)\(\s*"([A-Z][^"]*)"/
).flatten
unless hard_coded.empty?
  raise "hard-coded user-facing strings remain: #{hard_coded.join(', ')}"
end
