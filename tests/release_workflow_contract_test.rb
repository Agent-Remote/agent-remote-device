# frozen_string_literal: true

require "yaml"

repository_root = File.expand_path("..", __dir__)
ci_path = File.join(repository_root, ".github/workflows/ci.yml")
release_path = File.join(repository_root, ".github/workflows/prepare-release.yml")
prepare_version_path = File.join(repository_root, ".github/workflows/prepare-version.yml")
ci = YAML.safe_load(File.read(ci_path), aliases: true)
release = YAML.safe_load(File.read(release_path), aliases: true)
prepare_version = YAML.safe_load(File.read(prepare_version_path), aliases: true)

prepare_commands = prepare_version.dig("jobs", "prepare", "steps").map { |step| step["run"] }.compact.join("\n")
raise "version preparation does not create an immutable tag" unless prepare_commands.include?('git tag "v${VERSION}"')
raise "version preparation does not dispatch the protected release" unless prepare_commands.include?("prepare-release.yml")

rust_steps = ci.dig("jobs", "rust", "steps")
raise "CI Rust job is missing" unless rust_steps

resolved_version = rust_steps.find { |step| step["name"] == "Resolve proxy package version" }
raise "CI does not resolve the proxy version from Cargo metadata" unless resolved_version&.fetch("run", "")&.include?("cargo metadata --format-version=1 --no-deps")
raise "CI does not publish the resolved proxy version" unless resolved_version&.fetch("run", "")&.include?('$GITHUB_OUTPUT')

package_proxy = rust_steps.find { |step| step["name"] == "Package native Linux proxy artifact" }
raise "CI proxy package step is missing" unless package_proxy
unless package_proxy.fetch("env", {})["VERSION"] == "${{ steps.package-version.outputs.value }}"
  raise "CI proxy package version is not bound to Cargo metadata"
end

verify_proxy = rust_steps.find { |step| step["name"] == "Verify proxy artifact metadata" }
raise "CI proxy metadata verification is missing" unless verify_proxy
unless verify_proxy.fetch("env", {})["VERSION"] == "${{ steps.package-version.outputs.value }}"
  raise "CI proxy metadata verification is not bound to Cargo metadata"
end
raise "CI proxy metadata verification does not check the resolved version" unless verify_proxy.fetch("run", "").include?('= "$VERSION"')

validate_commands = release.dig("jobs", "validate", "steps").map { |step| step["run"] }.compact.join("\n")
raise "release does not require its exact tag" unless validate_commands.include?("refs/tags/v${version}")
raise "release does not match the Rust package version" unless validate_commands.include?('test "$resolved" = "$version"')
raise "release Rust vulnerability report is missing" unless validate_commands.include?("cargo audit --json")
raise "release Swift vulnerability report is missing" unless validate_commands.include?("swift-osv.json")
raise "release vulnerability reports are not signed" unless validate_commands.include?("cosign sign-blob")
raise "release does not publish a GitHub Release" unless release.dig("jobs", "publish", "steps").any? { |step| step.fetch("uses", "").start_with?("softprops/action-gh-release@") }

raise "CI supply-chain job is missing" unless ci.dig("jobs", "supply-chain", "steps")

supply_chain = ci.dig("jobs", "supply-chain", "steps")
swift_audit = supply_chain.find { |step| step["name"] == "Reject known vulnerable Swift dependencies" }
raise "Swift dependency audit is missing" unless swift_audit&.fetch("run", "").include?("audit-swift-dependencies.sh")

required_evidence = {
  "proxy" => [
    "sha256sum --check",
    "spdxVersion",
    "cosign verify-blob",
    "gh attestation verify",
    "$sbom.sigstore.json",
  ],
  "macos" => [
    "shasum -a 256 --check",
    "spdxVersion",
    ".profile == \"community-local-trust\"",
    ".apple_notarized == false",
    "cosign verify-blob",
    "gh attestation verify",
    "application_sha256",
    "community-signing.json",
    "cosign sign-blob",
    "$sbom.sigstore.json",
  ],
}.freeze

required_evidence.each do |job_name, fragments|
  steps = release.dig("jobs", job_name, "steps")
  raise "#{job_name} release job is missing" unless steps

  commands = steps.map { |step| step["run"] }.compact.join("\n")
  fragments.each do |fragment|
    raise "#{job_name} release evidence check is missing #{fragment}" unless commands.include?(fragment)
  end
  actions = steps.map { |step| step["uses"] }.compact
  raise "#{job_name} SBOM generation is missing" unless actions.any? { |value| value.start_with?("anchore/sbom-action@") }
  raise "#{job_name} provenance generation is missing" unless actions.any? { |value| value.start_with?("actions/attest-build-provenance@") }
end

raise "release does not publish SBOM signatures" unless File.read(release_path).include?(".spdx.json.sigstore.json")

macos_job = release.dig("jobs", "macos")
raise "community release must use the protected environment" unless macos_job["environment"] == "production-community-release"
raise "community release must use an official macOS runner" unless macos_job["runs-on"] == "macos-15"

macos_build = macos_job["steps"].find { |step| step["name"] == "Build hardened community-signed application" }
raise "community application build step is missing" unless macos_build
raise "community build does not pin the certificate" unless macos_build.fetch("env", {}).key?("SIGNER_CERTIFICATE_SHA1")
raise "community build does not import its persistent P12" unless macos_job["steps"].any? { |step| step["name"] == "Import persistent community signing certificate" }
raise "community build does not establish ephemeral runner trust" unless macos_job["steps"].any? { |step| step["name"] == "Trust community certificate on the ephemeral build runner" }
raise "community build does not verify the packaged XPC chain" unless macos_job["steps"].any? { |step| step["name"] == "Verify packaged community XPC process chain" }
