# Changelog

All notable changes to this repository are recorded here.

## v0.2.13 - 2026-09-05

- fix(macos): handle scalar bounds and scroll fallback (287d0da)
- fix(ci): use gnu target for fuzzing (329f08d)
- ci: optimize workflow execution (5e3e453)
- fix(macos): stabilize browser window and input handling (ec190e6)
- fix(macos): harden window-bound GUI actions (6d9c5e3)
- fix(logging): redact executor error type (85728d6)
- fix: device control relay and GUI execution (bb436a9)

## v0.2.12 - 2026-09-03

- feat: add session full-trust device control (c7e333d)
- tune(device-control): improve compact image fidelity (63cc155)
- fix(device-control): harden screenshot relay and freshness tests (f4c4733)
- fix(device-control): harden window targeting and recovery (177e3fb)

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
