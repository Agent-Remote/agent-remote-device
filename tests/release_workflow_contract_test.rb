# frozen_string_literal: true

require "yaml"

repository_root = File.expand_path("..", __dir__)
ci_path = File.join(repository_root, ".github/workflows/ci.yml")
release_path = File.join(repository_root, ".github/workflows/release.yml")
prepare_release_path = File.join(repository_root, ".github/workflows/prepare-release.yml")
ci = YAML.safe_load(File.read(ci_path), aliases: true)
release = YAML.safe_load(File.read(release_path), aliases: true)
prepare_release = YAML.safe_load(File.read(prepare_release_path), aliases: true)

prepare_commands = prepare_release.dig("jobs", "prepare", "steps").map { |step| step["run"] }.compact.join("\n")
raise "version preparation does not create an immutable tag" unless prepare_commands.include?('git tag "v${VERSION}"')
raise "version preparation does not dispatch the protected release" unless prepare_commands.include?("release.yml")
raise "version preparation does not require a clean committed tree" unless prepare_commands.include?("git diff --exit-code")
prepare_script = File.read(File.join(repository_root, "scripts/prepare-release.sh"))
raise "version preparation does not update Cargo.lock" unless prepare_script.include?('lock_path = Path("Cargo.lock")')
raise "version preparation does not update fuzz/Cargo.lock" unless prepare_script.include?('fuzz_lock_path = Path("fuzz/Cargo.lock")')
raise "version preparation does not verify locked fuzz metadata" unless prepare_script.include?("--manifest-path fuzz/Cargo.toml --format-version=1 --locked")
raise "version preparation does not update the Chinese README" unless prepare_script.include?('readme_cn_path = Path("README.zh-CN.md")')
raise "version preparation does not update CHANGELOG.md" unless prepare_script.include?('scripts/update-changelog.sh "$version"')
raise "version preparation does not commit fuzz/Cargo.lock" unless prepare_commands.include?("Cargo.toml Cargo.lock fuzz/Cargo.lock")
raise "version preparation does not commit both READMEs" unless prepare_commands.include?("README.md README.zh-CN.md")
raise "version preparation does not commit CHANGELOG.md" unless prepare_commands.include?("CHANGELOG.md scripts/prepare-release.sh")

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
raise "release identity does not use release.yml" unless File.read(release_path).include?(".github/workflows/release.yml@${GITHUB_REF}")

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
release_commands = macos_job["steps"].map { |step| step["run"] }.compact.join("\n")
raise "community build must not modify runner trust settings" if release_commands.include?("add-trusted-cert")
raise "community build does not verify the packaged XPC chain" unless macos_job["steps"].any? { |step| step["name"] == "Verify packaged community XPC process chain" }
