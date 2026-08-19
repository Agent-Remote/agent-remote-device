# 02 Architecture

## Module Layout

```text
macos/App/                    SwiftUI entry point and broker client
macos/AppCore/                Approval and safety state machines
macos/DeviceServices/         Broker and executor service implementations
macos/GUIExecutor/            AX, capture, input, and visibility operations
macos/Shared/DeviceIPC/       Versioned authenticated XPC contracts
macos/Shared/DeviceProtocol/  Canonical device wire models
proxy/src/                    Rust MCP proxy, transport, protocol, and state
protocol/                     JSON schemas and cross-language test vectors
skills/agent-remote-device/   Managed model-facing skill
scripts/                      Build, release, audit, and verification tooling
```

Keep process capabilities deliberately split. The Approval UI must not hold the long-term Broker credential. The Network Broker must not gain TCC-backed GUI access. The GUI Executor must not gain an arbitrary network client or long-term device credential.

Entry points coordinate existing modules. Put reusable policy in the owning library target, not in `main.swift`, app views, or shell scripts. XPC payloads must use the shared IPC types and retain code-signature validation, reply deadlines, cancellation, and fail-closed invalidation.
