# Device protocol v1

All application messages are length-prefixed canonical JSON carried inside the
inner TLS 1.3 stream. The prefix is an unsigned 32-bit network-byte-order length.
Frames larger than 16 MiB are rejected before allocation. Image fields have a
separate decoded limit of 12 MiB and may only use PNG or JPEG. Before an image is
returned to Claude Code, the proxy verifies that its signature matches the
declared media type and completes a bounded decode. Either dimension may be at
most 4096 pixels, the image may contain at most 4,000,000 pixels, and decoder
allocation is limited to 16 MiB. Malformed, mislabeled, and high-compression
images fail closed. The bounded full decode runs on the blocking worker pool, and
all cloned MCP handlers share one operation guard so only one action exchange and
image validation can be in flight for a proxy generation.

Unknown fields, unknown enum values, duplicate JSON keys, non-integer coordinates,
and values outside documented bounds are rejected. Claude supplies only the
`action`; the managed proxy injects `context`, `request_id`, and `lease_until`.

The authoritative machine-readable request schema is
`protocol/schema/action-request-v1.schema.json`. Cross-language fixtures live in
`protocol/test-vectors`.

`read_clipboard` returns at most 64 KiB of plain text and never mutates the Mac
clipboard. It requires a current screenshot bound to an approved application and
that application's explicit per-session clipboard approval. A successful read
consumes the action sequence but does not create an image or advance the
screenshot generation. Missing, non-text, oversized, and unapproved clipboard
content return concrete device errors without dropping the encrypted channel.

The context binding is the tuple `(user_id, device_id, tool_session_id,
device_session_id, node_id, platform, generation)`. Every tuple member must match
the active generation. IDs are UUIDs and are never credentials. Generation uses
the positive signed 64-bit range shared with the Server database; live generations
are capped at `9223372036854775806` and `9223372036854775807` is reserved for
terminal revocation. Action-sequence and screenshot-generation counters never wrap
or saturate. A counter at its unsigned 64-bit maximum fails the generation before
another action is sent or executed.

## Lifecycle frames

The managed proxy also forwards two trusted Claude lifecycle events on the same
confirmed inner TLS stream. A `turn_stop` frame stops in-flight GUI work and
restores hidden applications without releasing the machine lock. A `session_end`
frame ends the device session and releases the lock. Lifecycle frames carry a new
request UUID and the complete context binding but do not consume an action
sequence or screenshot generation.

The Broker acknowledges `turn_stop` only after the Executor has released pressed
input and the Approval UI has restored hidden applications. It retains the
generation, lease, approvals, action sequence, and machine lock in a paused local
turn state. The next authenticated device action is treated as the start of the
next turn: before forwarding that action, the Broker synchronously asks the
Approval UI to hide unapproved applications and restart its safety monitors, then
resumes the Executor. The Executor requires that first action to be a fresh
`screenshot`; stale coordinates cannot cross the turn boundary. These
`turn_started`, `turn_stopped`, and `session_ended` messages are generation-bound
local XPC events and are not accepted from Claude, MCP arguments, or projects.
Every safety-critical Broker request to the Executor or Approval UI has a
15-second local reply deadline. Cancellation, timeout, or a missing callback
fails the current relay and triggers the authenticated control-plane abort.

The proxy MCP process owns a session-private `/tmp/lifecycle.sock`. Fixed Claude
`Stop`, `StopFailure`, and `SessionEnd` command hooks invoke the same verified proxy binary in
notifier mode. The notifier validates the hook event name, sends one bounded
strict local frame, and waits for the authenticated remote acknowledgement.

The Broker rotates an active generation after 14 minutes, before the 15-minute
nested TLS identity limit. Rotation stops the current action, preserves no
unconfirmed action, and returns the session to explicit local approval with a new
generation. Relay failure and Executor loss also end the current local UI
generation so hidden applications are restored. Pending approvals are deduplicated
by the complete session binding, not only by device-session ID, so a rotated
generation is always presented again.

## Exporter confirmation

Application framing starts only after both inner TLS peers exchange and verify one
exporter-confirmation record. The record is exactly 34 bytes:

```text
offset  size  value
0       1     confirmation version, fixed to 1
1       1     sender role: device=1, proxy=2
2       32    HMAC-SHA-256 authentication code
```

The HMAC key is the 32-byte TLS exporter output. Its input is the ASCII label
`agent-remote-device-exporter-confirm-v1`, one zero byte, the confirmation version,
the sender role, the generation as an unsigned 64-bit network-order integer, and
the device-session UUID as 16 network-order bytes. A malformed record, same-role
record, binding mismatch, or authentication failure closes the generation before
any application JSON is accepted.

The proxy bounds each handshake and action exchange by the shorter of the
remaining authorization lease and 30 seconds. Lifecycle acknowledgements have a
15-second deadline. Timeout, malformed response, response-binding failure, or
device rejection closes the inner connection and permanently poisons that proxy
generation; no partially read stream is reused.

The cross-language integration test
`rustlsAndNetworkFrameworkExchangeAuthenticatedActionFrames` starts the real Rust
rustls peer and connects with the Swift Network.framework implementation. It
verifies mutual P-256 identity pinning, exporter confirmation, strict request
decoding, and response binding over the same framed TLS stream used in production.
