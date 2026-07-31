# Changelog

All notable changes to this repository are recorded here.

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
