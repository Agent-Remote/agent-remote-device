# Release signing and activation

## Community local-trust profile

The default release workflow supports an account-free `community-local-trust` profile on the
official `macos-15` GitHub runner. Create one persistent self-signed identity and configure the
protected environment with:

```sh
scripts/create-community-signing-identity.sh
scripts/configure-community-release-environment.sh
```

Back up `dist/community-signing-identity` outside the repository before deleting the local copy.
The directory contains the private key and P12 password and must never be committed or attached to
a release. The workflow temporarily trusts the public certificate only on the ephemeral runner so
`codesign` can use it. Installed Macs do not trust it as an Apple Developer ID; the verified CLI
removes quarantine after it pins the embedded leaf certificate on the app and both XPC services.

Community packages set `production_ready=true`, `apple_notarized=false`,
`public_distribution=false`, and `profile=community-local-trust`. They use application-enforced
destination checks and an owner-only Broker credential file rather than Apple access groups and a
managed Network Extension.

The Apple Developer ID profile below remains available as a stricter future option, but it is not
used by the default workflow.

## Apple Developer ID profile

Production packages require all of the following evidence:

- The application and nested XPC services have valid Developer ID Application signatures.
- Any future installer package has a valid Developer ID Installer signature.
- Notarization succeeds and the ticket is stapled.
- Hardened Runtime and the reviewed entitlements are present.
- The system-level signature-bound outbound allowlist is installed and its active
  probe succeeds.
- SBOM, provenance attestation, update signature, and SHA-256 digests are published.
- Dependency audit reports no known Critical or High vulnerability.
- Protocol, fuzz, isolation, fail-closed, TCC, and compatibility suites pass.
- Independent security review has no unresolved Critical or High finding.

Create a hardened, nested-signed application with:

```sh
VERSION=1.0.0 \
BUILD_NUMBER=1 \
TEAM_IDENTIFIER=AB12CD34EF \
SIGNING_IDENTITY="Developer ID Application: Example (AB12CD34EF)" \
OUTBOUND_POLICY_ATTESTOR_MACH_SERVICE="dev.example.agentremote.policy-attestor" \
OUTBOUND_POLICY_ATTESTOR_PUBLIC_KEY_BASE64="<base64 raw Ed25519 public key>" \
OUTBOUND_POLICY_IDENTIFIER="dev.example.agentremote.production" \
scripts/build-release-app.sh
```

The command rejects ad-hoc identities, validates version and Team ID inputs,
requires a 32-byte Ed25519 policy-attestor public key, pins all policy-attestor
identifiers into the signed Network Broker, signs each XPC service before the outer application, and runs deep strict
signature verification. Every nested XPC service and the outer application must report the configured
`TeamIdentifier`, a `Developer ID Application` authority, and Hardened Runtime in its actual code-signature
metadata. Release evidence reads the Team ID back from the final application signature and requires it to
match both the protected environment and the Broker's signed plist. It does not claim notarization: the resulting app must
still be submitted with `notarytool`, stapled, assessed with Gatekeeper, scanned
into an SBOM, and attached to provenance before release.

Development archives are never production artifacts and never enable the
production capability. The control plane keeps `device_control_enabled=false`
until every gate above has independently verifiable evidence.

The attestor private key must remain in the independently managed policy service. It must not be
stored in GitHub, the application bundle, an application preference, or a release asset. Configure
the mach service and policy ID as protected environment variables and the public key as a protected
secret named by `.github/workflows/release.yml`. See `isolation-verification.md` for the
challenge and proof contract.

The signed signing/notarization record is generated from the packaged Network Broker plist. It
includes the embedded Team ID, Broker bundle identifier, policy ID, attestor mach service, and
SHA-256 of the embedded raw public key. Certified composition assembly requires the external runtime
policy evidence to match all five values before it can issue a manifest.

The release workflow signs each proxy and notarized application archive and its
SPDX SBOM with Sigstore keyless signing. It uploads every `.sigstore.json` bundle
beside the signed file. Consumers verify each blob against the repository workflow
identity and GitHub Actions OIDC issuer before installing an update;
the Apple signature and notarization ticket remain independently required for
the macOS application itself.

Before upload, the workflow parses each SPDX document, checks the archive digest,
verifies both archive and SBOM Sigstore bundles against the exact release-workflow
identity, and
verifies the GitHub build-provenance attestation. CI also scans SwiftPM and Rust
lockfiles for known vulnerabilities; a scanner failure or finding fails the
supply-chain job.
