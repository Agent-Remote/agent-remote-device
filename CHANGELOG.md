# Changelog

All notable changes to this repository are recorded here.

## v0.2.15 - 2026-09-09

- chore: prepare v0.2.15 from v0.2.14 with repository-owned version metadata only.

## v0.2.14 - 2026-09-09

- fix(release): complete changelog history (cce7293)

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

## v0.2.7 - 2026-08-13

- fix: harden computer use interaction recovery (2cfaeb1)

## v0.2.6 - 2026-08-10

- fix: make computer use sessions resilient (1ff56a7)
- test: support release Swift weak references (f153ccf)

## v0.2.5 - 2026-08-09

- docs: document default computer use v2 negotiation (306b257)

## v0.2.4 - 2026-08-09

- chore: release v0.2.4 (29e9715)

## v0.2.3 - 2026-08-09

- feat: harden computer use v2 workflows (6b3c9c2)
- fix: require explicit self in relay closures (3b164fb)
- test: support strict weak reference compilation (1a2e480)

## v0.2.2 - 2026-08-07

- fix: stabilize computer use v2 sessions (ef278e7)
- fix: keep relay failures out of unified logs (b433986)
- test: restore the Rust coverage gate (17e9acd)

## v0.2.1 - 2026-08-05

- feat: add AX-first computer use v2 (d598e21)

## v0.2.0 - 2026-08-04

- feat: add device branding and app icon (d99484f)

## v0.1.9 - 2026-08-04

- feat: stabilize the device control lifecycle and errors (1ace86d)

## v0.1.8 - 2026-08-03

- feat: add local device session binding (08a732d)

## v0.1.7 - 2026-08-01

- chore: release v0.1.7 (3efd420)

## v0.1.6 - 2026-08-01

- chore: release v0.1.6 (07c9f39)

## v0.1.5 - 2026-07-31

- chore: release v0.1.5 (a4e56f1)

## v0.1.4 - 2026-07-31

- chore: release v0.1.4 (3b166ad)

## v0.1.3 - 2026-07-31

- fix: avoid interactive runner trust changes (6b1805b)

## v0.1.2 - 2026-07-31

- fix: trust the community signer in the runner keychain (b29942f)

## v0.1.1 - 2026-07-31

- feat: build the community-signed macOS release (9fd1673)
- fix: update the device release lockfile version (f01e8b6)

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
