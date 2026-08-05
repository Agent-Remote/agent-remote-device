# Device protocol

Protocol v2 is implemented as a capability-gated extension. Protocol v1 remains
the mandatory compatibility fallback and the default whenever either peer lacks
one of the required v2 capabilities. Production enablement is separate from wire
implementation and remains subject to the release evidence and macOS security
gates.

## Protocol v1 compatibility

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

The MCP-only `input_text` helper does not add a protocol action. The proxy expands
it into at most five existing actions in this fixed order: optional `left_click`,
optional `key`, `type`, optional `key`, optional `wait`. One operation guard covers
the complete sequence, every action crosses the normal authenticated device path,
and every step advances the existing sequence and screenshot-generation counters.
Only the final successful screenshot is returned to the model; intermediate images
are discarded by the proxy. A failed step stops the sequence and reports how many
prefix steps completed so callers do not blindly replay partially applied input.

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

## Protocol v2: structured, token-efficient observations

V2 is implemented by the strict Swift and Rust decoders, the macOS GUI Executor,
the managed proxy, and Node capability/context propagation. The authoritative
request contract is `protocol/schema/action-request-v2.schema.json`; the shared
Rust/Swift vector is `protocol/test-vectors/action-request-v2-valid.json`. V1 and
v2 frames are dispatched by their exact version. A peer never partially
interprets v2 fields as v1.

### Capability negotiation and fallback

V2 is enabled only when the managed context contains all exact generation-bound
capabilities needed by a request. The implemented capability names are:

```text
observation_mode_v2
ax_state_v2
adaptive_settle_v2
```

Unknown capabilities, a missing capability, or a version mismatch selects the
complete v1 behavior. The fallback is not allowed to accept a v2 frame and ignore
unknown observation fields. Existing managed contexts with no capability list are
read as v1 and upgraded on renewal. Deployment may use shadow mode before enabling
the compact MCP surface for a production cohort.

### Request observation policy

A v2 action request adds an `observation` object selected by the managed proxy and
bounded by compile-time limits on the device:

```json
{
  "observation": {
    "mode": "none | ax_diff | ax_full | screenshot | both | auto",
    "max_nodes": 800,
    "max_depth": 20,
    "max_text_per_node": 160,
    "max_total_text_bytes": 16384,
    "max_visible_rows_per_container": 20,
    "settle": "none | auto | fixed",
    "settle_timeout_ms": 5000,
    "image_profile": "none | compact | standard | region",
    "region": null
  }
}
```

`none` suppresses model-facing observation data. It does not suppress approval,
application/window/display identity checks, monotonic sequence validation, lease
validation, or post-action context verification. The Executor must separate
window/context observation from pixel capture and image encoding so a `none` or
AX-only response does not first build and transfer an image that the proxy later
discards.

The device may lower any AX budget or settle timeout but must reject values above
its hard bounds. `fixed` settling remains a compatibility and diagnostic mode;
managed browser flows default to bounded `auto` settling.

### Response state

A successful v2 response binds observation freshness independently from image
freshness. The authoritative response contract is
`protocol/schema/action-response-v2.schema.json`; the shared Rust/Swift response
vector is `protocol/test-vectors/action-response-v2-valid.json`:

```json
{
  "state_generation": 42,
  "screenshot_generation": 17,
  "state_id": "device-generated-opaque-id",
  "base_state_id": "prior-model-visible-state-or-null",
  "observation": {
    "mode": "ax_diff",
    "reset": false,
    "text": "bounded normalized accessibility state"
  },
  "settle": {
    "status": "settled | timeout | not_requested",
    "elapsed_ms": 420
  },
  "image": null
}
```

Every request still consumes the exact next `monotonic_sequence`. A successful
observation or action advances `state_generation`. `screenshot_generation`
advances only when a new image is returned to the model and becomes a valid
coordinate source. `state_id` is generated inside the device boundary and binds
the full session generation, approved application, selected window, display
fingerprint, and state generation. It is not a credential and is never accepted
across a turn resume or device generation.

### Bounded accessibility state and diffs

AX output is generated only by the GUI Executor. Normalized nodes may contain the
minimum decision-relevant role, title, label, value, placeholder, URL, visible
frame, settable marker, and exposed AX actions. Default budgets are 800 nodes, a
depth of 20, 160 characters per node, 16 KiB total text, and 20 visible rows per
container. Hard limits are lower than the encrypted frame limit and are enforced
before serialization.

Secure text values, password contents, invisible sensitive values, unbounded web
subtrees, and redundant wrapper nodes are omitted or redacted. AX URLs describe
only the approved browser window; they do not create a general navigation API.

The first observation for an application/window/display context is full. Later
observations may return added, changed, and removed nodes relative to
`base_state_id`. The Executor or proxy returns a bounded full state with
`reset: true` when the base was not delivered to the model, the context changed,
the diff is too large, or either side cannot prove the base is current. A diff
without a valid model-visible base must never be returned.

### State-bound element targets

An element action carries more than a bare index:

```json
{
  "target": {
    "state_id": "device-generated-opaque-id",
    "state_generation": 42,
    "element_index": 18
  },
  "action": {
    "type": "press | set_value | select_text | scroll | secondary_action"
  }
}
```

The Executor resolves the index only inside the exact current AX snapshot. Before
execution it revalidates the session generation, application digest, window ID,
display fingerprint, element existence, exposed AX action, and local control
level. A stale, foreign, missing, or non-actionable element fails with a concrete
error. The device never substitutes a same-named element, neighboring index, or
coordinate click.

`set_value` and text selection require full-control approval. Secure fields and
credentials subject to hand-off policy cannot be set through AX. Coordinate
actions remain available as a fallback and continue to require the latest
model-visible `screenshot_generation` and exact returned image dimensions.

### Adaptive settle and image profiles

Automatic settling verifies that the approved application, window, and display
remain stable, then samples bounded AX loading/busy state and normalized tree
hashes. It returns `settled` only after the debounce interval produces two stable
observations. It stops at the minimum of five seconds, the requested hard-bounded
timeout, the remaining lease, and the action deadline. Timeout returns the newest
safe state with `status: timeout`; it is not reported as settled.

Image responses use an explicit profile:

```text
compact   ordinary visual confirmation
standard  coordinate location and OCR
region    bounded detail inspection
```

Returned dimensions, selected window, coordinate frame, and display fingerprint
are recorded in the screenshot context. JPEG may reduce bridge bytes, but image
count and dimensions are the primary model-token controls.

### MCP mapping and sequence helpers

The compact v2 MCP surface is `observe`, `act`, `input_text`, and
`read_clipboard`, enabled for the managed proxy with `--compact-tools`. Existing
v1 tools remain compatibility wrappers. `observe`
defaults to `auto` and diff output; `act` prefers a state-bound element target and
requests a screenshot only when accessibility state is insufficient.

Sequence helpers remain proxy-side conveniences rather than new device actions.
They may batch only deterministic prefixes that require no intermediate visual
decision, execute under one operation guard, and stop at the first failure. A
result identifies the completed prefix. Transport failures with unknown execution
status are never replayed automatically, and consequential final actions remain
separate observation and confirmation points.

`none` responses preserve the last model-visible AX diff base while the approved
application, window, and display remain unchanged. This lets a deterministic
`input_text` prefix omit intermediate observations and still return one final AX
diff. A context change clears the base. Explicit `ax_full` requests always send a
null base and establish a new one.

The managed proxy writes bounded zero-content optimization events to the fixed
owner-only JSONL path supplied by Node. See `docs/optimization-benchmark.md` for
the event contract, fixed browser corpus, comparison command, and release targets.
The architectural decision and rejected alternatives are recorded in
`docs/adr/0002-ax-first-computer-use.md`.

### Canonical invocation state machine

The proxy instructions, skill, and browser reference must implement this same
state machine. The protocol, rather than prompt wording, enforces freshness and
fallback safety:

```text
START / APP_OR_WINDOW_CHANGED / TURN_RESUMED
  -> observe(auto)
  -> AX_FULL, AX_DIFF, or IMAGE

AX_FULL or AX_DIFF with represented target
  -> act(state-bound target, settle=auto)
  -> consume returned next state

AX insufficient and visual decision required
  -> observe(screenshot, compact)
  -> upgrade to standard or region only if required
  -> coordinate action bound to that image generation

DIFF_BASE_LOST or RESET hides target
  -> observe(ax_full with null base)

STALE_ELEMENT
  -> observe(auto), re-locate, never substitute

STALE_SCREENSHOT
  -> observe(screenshot), re-locate, never reuse coordinates

CONSEQUENTIAL_FINAL_ACTION
  -> separate current observation and confirmation
  -> one action, no automatic replay
```

A successful `act` response is already an observation and is the only state from
which the next element index may be selected. Re-observing after every successful
action wastes a tool round trip and can invalidate indexes without adding useful
information. Conversely, batching is limited to deterministic prefixes whose
intermediate result cannot change the next decision.

Fallback follows a one-way evidence ladder for each decision:
`ax_diff -> ax_full -> compact image -> standard image -> region image`. A caller
may start at a higher rung when the task is inherently visual, but it must not
request all representations by default or repeatedly retry an AX action that the
application does not expose. Browser navigation, tabs, ordinary forms, and
represented scrolling stay on the AX path; canvas, remote desktop, video, complex
editors, and inaccessible Electron views use image fallback.

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
