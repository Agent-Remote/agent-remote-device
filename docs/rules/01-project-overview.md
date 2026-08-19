# 01 Project Overview

`agent-remote-device` is the security-sensitive local device-control component of agent-remote. It owns the native macOS application, its isolated XPC services, the managed Rust MCP proxy, the versioned device protocol, and device release packaging.

## Repository Boundary

- The macOS app owns local approval, permissions, visible safety state, and session cleanup.
- The Network Broker owns device credentials, control-plane communication, and nested-TLS relay transport.
- The GUI Executor owns Screen Recording, Accessibility, input execution, AX observation, and clipboard reads.
- The Rust proxy exposes the bounded MCP surface and translates it to the device protocol; it does not bypass local approval.
- The server owns identity, authorization, session binding, generation advancement, and capability policy.
- The node transports the managed proxy and relay streams; it does not become a device trust authority.

Protocol schemas, release artifact formats, bundle identifiers, XPC interfaces, and MCP tool behavior are compatibility surfaces. Changes require focused tests and documentation.
