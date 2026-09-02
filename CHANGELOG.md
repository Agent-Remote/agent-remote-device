# Changelog

All notable changes to this repository are recorded here.

## v0.2.11 - 2026-09-02

- fix(device-control): preserve exact window targeting (39fafb3)

## v0.2.10 - 2026-09-01

- feat(device-control): improve macos control resilience (55aa5e3)

## v0.2.9 - 2026-08-19

- fix: preserve user focus during macOS control (49f5a26)

## v0.2.8 - 2026-08-19

- docs: define independent release policy (1c39d14)
- feat: align device documentation and release automation (0ab0686)

## v0.1.0 - 2026-07-31

- feat: add the macOS device control app, approval UI, and executor XPC services
- feat: enforce generation-bound approvals, leases, revocation, and input release
- feat: add the managed MCP proxy with strict protocol and image validation
- feat: attest the outbound network policy before activating encrypted relays
- build: package version-matched app, XPC services, and standalone proxy releases
- test: cover Rust and Swift security contracts and the cross-component control path
- ci: run Swift 6 builds on macOS 15 and install the protocol fuzz runner explicitly
- fix: compile ScreenCaptureKit calls under Swift 6 strict concurrency checks
- ci: run bounded protocol fuzzing with the required nightly toolchain and a host-built runner
- fix: support the Xcode 16 Security overlay when creating ephemeral TLS identities
