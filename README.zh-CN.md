# agent-remote-device

<p align="center"><img src="assets/agent-remote-icon.svg" alt="Agent Remote 图标" width="80" height="80"></p>

<p align="center">
  <a href="https://github.com/Agent-Remote/agent-remote-device/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/Agent-Remote/agent-remote-device/actions/workflows/ci.yml/badge.svg"></a>
  <a href="https://codecov.io/gh/Agent-Remote/agent-remote-device"><img alt="Codecov" src="https://codecov.io/gh/Agent-Remote/agent-remote-device/graph/badge.svg"></a>
  <a href="https://github.com/Agent-Remote/agent-remote-device/stargazers"><img alt="GitHub Stars" src="https://img.shields.io/github/stars/Agent-Remote/agent-remote-device?style=flat&logo=github"></a>
  <img alt="Swift 6.0" src="https://img.shields.io/badge/Swift-6.0-F05138?logo=swift&logoColor=white">
  <img alt="Rust 2021" src="https://img.shields.io/badge/Rust-2021-000000?logo=rust&logoColor=white">
  <a href="LICENSE"><img alt="许可证：GPL-3.0" src="https://img.shields.io/github/license/Agent-Remote/agent-remote-device"></a>
</p>

[English](README.md) | 中文

agent-remote 的安全敏感型 macOS 设备桥接程序和受管 MCP proxy。

本仓库负责版本化设备协议、原生 macOS 组件、远端 `agent-remote-device` MCP proxy
和发布打包。生产功能默认保持关闭，只有向发布验证器提供某个明确发布 profile 的证据后才会启用。
默认的 `community-local-trust` profile 使用持久化项目自签名、GitHub 官方 runner、应用层出口
限制，以及不宣称经过 Apple 公证的显式降级风险接受。对于能够取得相应资质的部署，仍保留要求更严格的
Apple Developer ID profile 文档。

## 开发

```sh
scripts/run-quality-checks.sh
```

除了 Rust 和 Swift 工具链，本地质量门禁还需要 `cargo-deny` 和 `cargo-llvm-cov`。

使用 ad-hoc 签名的开发应用只能处理合成数据。测试需要 TCC 权限的功能前，请先阅读
`docs/release-signing.md` 和 `docs/macos-security.md`。

相邻的 `agent-remote` 仓库提供 `scripts/run-local-device-control-e2e.sh`。该脚本会运行真实的
FastAPI/WebSocket relay、Node `BridgeManager`、Rust nested-TLS transport 和 Swift
Network.framework peer。它的临时控制平面仅监听 loopback，且不会放宽生产客户端对
`https/wss` 的要求。

为 Node 打包构建 Linux proxy artifact：

```sh
VERSION=0.2.7 scripts/package-proxy-release.sh
```

`VERSION` 必须与 Rust workspace package 版本完全一致。使用 `scripts/prepare-release.sh`
准备新的源代码版本；`prepare-release` workflow 会更新仓库版本文件和 `CHANGELOG.md`、提交并标记
该版本，然后触发受保护的签名 `release` workflow。

交叉构建时，将 `TARGET` 设置为 `x86_64-unknown-linux-gnu`、
`aarch64-unknown-linux-gnu`、`x86_64-unknown-linux-musl` 或
`aarch64-unknown-linux-musl`，并使用 `BUILD_TOOL=cross`。输出位于
`dist/device-proxies/<target>/`，其中包含可执行文件、`VERSION` 和 `SHA256SUMS`，可通过
`DEVICE_PROXY_DIR` 直接传给 Node release build。

CI 会分别生成 Rust 和 Swift 覆盖率，并使用不同 Codecov flag 上传。发布 artifact 使用
GPL-3.0-only 许可证；分发要求详见 `LICENSE`、`NOTICE` 和 `docs/release-signing.md`。
