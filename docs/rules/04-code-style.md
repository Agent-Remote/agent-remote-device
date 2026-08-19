# 04 Code Style

## Swift

- Use Swift 6 strict concurrency and explicit `Sendable` boundaries.
- Keep UI state on the main actor and blocking Security, AX, capture, or filesystem work off actor-critical paths.
- Prefer value types and exhaustive enums for protocol and state-machine data.
- Do not use force unwraps or unchecked concurrency annotations in input-controlled paths.
- Keep permission, cleanup, cancellation, and XPC failure states explicit and testable.

## Rust

- `rustfmt` is authoritative and Clippy runs on all workspace targets with warnings denied.
- Use typed domain models and bounded parsing at MCP, JSON, image, filesystem, and transport boundaries.
- Avoid `unwrap`, `expect`, panics, unbounded allocation, and blocking work on async executors in production paths.
- Add actionable error context without including private user data.

Behavior changes require focused unit or contract tests. Cross-language changes require equivalent coverage on both sides of the boundary.
