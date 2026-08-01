# agent-remote-device

Security-sensitive macOS device bridge and managed MCP proxy for agent-remote.

This repository owns the versioned device protocol, the native macOS components,
the remote `agent-remote-device` MCP proxy, and release packaging. Production
activation is fail-closed until evidence for one explicit release profile is
supplied to the release verifier. The default `community-local-trust` profile
uses persistent project self-signing, official GitHub runners, application-level
egress enforcement, and explicit reduced-risk acceptance without claiming Apple
notarization. The stricter Apple Developer ID profile remains documented for
deployments that can obtain it.

## Development

```sh
scripts/run-quality-checks.sh
```

The local quality gate requires `cargo-deny` and `cargo-llvm-cov` in addition to
the Rust and Swift toolchains.

The ad-hoc development application can only be used with synthetic data. See
`docs/release-signing.md` and `docs/macos-security.md` before testing TCC-backed
features.

The sibling `agent-remote` repository provides
`scripts/run-local-device-control-e2e.sh`. It runs a real FastAPI/WebSocket relay,
the Node `BridgeManager`, the Rust nested-TLS transport, and a Swift
Network.framework peer. Its temporary control plane is loopback-only and does
not relax the production client's `https/wss` requirement.

Build a Linux proxy artifact for Node packaging:

```sh
VERSION=0.1.7 scripts/package-proxy-release.sh
```

`VERSION` must exactly match the Rust workspace package version. Prepare a new
source version with `scripts/prepare-version.sh`; the `prepare version` workflow
commits and tags that version before dispatching the protected signed release.

Cross builds set `TARGET` to one of `x86_64-unknown-linux-gnu`,
`aarch64-unknown-linux-gnu`, `x86_64-unknown-linux-musl`, or
`aarch64-unknown-linux-musl` and use `BUILD_TOOL=cross`. Output under
`dist/device-proxies/<target>/` contains the executable, `VERSION`, and `SHA256SUMS` and can be
passed directly to the Node release build as `DEVICE_PROXY_DIR`.

Rust and Swift coverage are generated independently in CI and uploaded with
separate Codecov flags. Release artifacts are licensed under GPL-3.0-only; see
`LICENSE`, `NOTICE`, and `docs/release-signing.md` for distribution requirements.
