# 09 Protocol Compatibility

`docs/protocol.md` is the human-readable protocol source of truth. Machine-readable schemas live in `protocol/schema/`, and cross-language fixtures live in `protocol/test-vectors/`.

Any wire change must update, in one change:

- the relevant JSON schemas and valid and invalid test vectors;
- Swift models and strict decoding in `macos/Shared/DeviceProtocol/`;
- Rust models and strict decoding in `proxy/src/protocol*.rs`;
- Swift and Rust focused tests;
- `docs/protocol.md`, capability negotiation, and managed skill references when behavior is model-visible.

Protocol v1 remains the mandatory fallback for explicit legacy `per_application_approval` sessions unless both peers
negotiate the complete v2 capability set. A `session_full_trust` session instead requires the complete full-trust
capability set and fails closed when any member is absent; it must never silently downgrade authorization semantics.
Reject unknown or duplicate fields, unknown enum values, non-canonical or oversized frames, stale generations,
expired leases, non-monotonic sequences, and invalid model-visible state bindings.

The proxy may enrich context and expand documented helpers, but it must not invent a bypass action, modify session
authorization, replay a partially completed sequence, or expose raw transport controls to the model.
