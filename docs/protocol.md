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
it into at most five existing actions in this fixed order: optional state-bound
`press` or coordinate `left_click`, optional `key`, optional non-empty `type`,
optional `key`, optional `wait`. Omitting `type` permits a bounded select-and-clear
shortcut sequence without manufacturing an invalid empty type action. One operation guard covers the complete sequence,
every action crosses the normal authenticated device path, and every step advances
the existing sequence and screenshot-generation counters. Only the final successful
screenshot is returned to the model; intermediate images are discarded by the
proxy. A failed step stops the sequence and reports how many prefix steps completed
so callers do not blindly replay partially applied input. Absence of typed text in
a truncated full state or a diff is inconclusive and does not turn a successful
device action into a false failure; a complete, non-truncated full state that omits
the text still stops the sequence before its final key.

On v2, each action already receives adaptive settle, so `input_text` does not emit
the legacy trailing fixed `wait`; this keeps the typed action's confirming AX state
as the tool result instead of replacing it with an empty wait diff. When AX exposes
the target field, callers pass its latest `state_id`, `state_generation`, and
`element_index` directly to `input_text` and omit `coordinate`. The three AX fields
are atomic, mutually exclusive with `coordinate`, and unavailable on the v1
fallback. AX frames are not screenshot coordinates. A
state-bound `set_value` accepts an empty string at the protocol boundary. The compact
MCP `act` surface exposes `clear_value`, which maps to that operation without making
the client serialize an empty string.

The authoritative machine-readable request schema is
`protocol/schema/action-request-v1.schema.json`. Cross-language fixtures live in
`protocol/test-vectors`.

`read_clipboard` returns at most 64 KiB of plain text and never mutates the Mac
clipboard. V1 requires a current screenshot; v2 requires the current verified
application/window state. Both paths require that application's explicit
per-session clipboard approval. A successful read consumes the action sequence
but does not create an image or advance the screenshot generation. Missing,
non-text, oversized, and unapproved clipboard content return concrete device
errors without dropping the encrypted channel.
On the compact v2 surface it requests observation mode `none` and returns only the
JSON-escaped clipboard text plus the unchanged `state_id` and `state_generation`.
Because a read cannot mutate GUI state, existing element indexes remain valid without
another `observe`. AX nodes, screenshot metadata, and settle fields are intentionally
omitted.

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
observation or GUI-mutating action advances `state_generation`; a successful v2
`read_clipboard` preserves it. `screenshot_generation`
advances only when a new image is returned to the model and becomes a valid
coordinate source. `state_id` is generated inside the device boundary and binds
the full session generation, approved application, selected window, display
fingerprint, and state generation. It is not a credential and is never accepted
across a turn resume or device generation.

`state_generation` remains a session-wide monotonic response counter, while
element freshness is scoped to the approved application identified by the
opaque `state_id`. The proxy and Executor retain at most one latest AX binding
per approved application. Observing or acting in application B therefore does
not invalidate the latest model-visible element indexes for application A.
A newer state for A, an A window/display change, a turn boundary, or a device
generation change still invalidates A's prior binding. The Executor never
remaps an old index to a newer state.

Before executing an action against a retained binding for a background
application, the Executor activates that exact signed process and waits until
`NSWorkspace` identifies it as frontmost. `NSRunningApplication.isActive` alone
is not accepted because it may lag during an application transition. A `press`
on a settable editable text node also establishes and verifies AX focus before
the action sequence is committed. A successful returned state can therefore be
followed directly by context-bound text input without an extra observation.

### Bounded accessibility state and diffs

AX output is generated only by the GUI Executor. Normalized nodes may contain the
minimum decision-relevant role, title, label, value, placeholder, URL, settable
marker, and exposed AX actions. Frames are retained only for settable or actionable
nodes; purely structural nodes omit them so browser layout motion does not inflate
state size or turn a semantic diff into a full reset. AX frames remain metadata and
are never valid screenshot coordinates. Token-oriented defaults are 600 nodes, a
depth of 20, 160 characters per node, 12 KiB total text, and 12 visible rows per
container. The hard limits remain 800 nodes, 16 KiB total text, and 20 visible rows;
all hard limits are lower than the encrypted frame limit and are enforced before
serialization.

Text-budget exhaustion truncates text fields but does not terminate structural
tree traversal. One quarter of the total text budget is reserved from static
content for settable, editable, or actionable controls so navigation sidebars and
long document text cannot hide a later search field or composer from model-visible
AX state.

Secure text values, password contents, invisible sensitive values, unbounded web
subtrees, and redundant wrapper nodes are omitted or redacted. AX URLs describe
only the approved browser window; they do not create a general navigation API.

The first observation for an application/window/display context is full. Later
observations may return added, changed, and removed nodes relative to
`base_state_id`. The Executor or proxy returns a bounded full state with
`reset: true` when the base was not delivered to the model, the context changed,
the diff is too large, or either side cannot prove the base is current. A diff
without a valid model-visible base must never be returned.

If navigation recovery replaces an initially computed diff with a full state,
the response still uses `reset: true` whenever the request carried a model-visible
base. Clearing an internal snapshot or requesting a fresh capture must not turn
that replacement into a misleading first-state `reset: false` response.

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
    "type": "press | set_value | clear_value | select_text | scroll | secondary_action"
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
`clear_value` is a compact MCP alias for a state-bound SetValue carrying an empty
string; it avoids empty-string JSON serialization failures in model clients.

### Adaptive settle and image profiles

Automatic settling verifies that the approved application, window, and display
remain stable, then samples bounded AX loading/busy state and normalized tree
hashes. In browser windows the settle hash follows page identity, editable controls,
loading indicators, and the leading decision-relevant page text; late lazy-loaded
footer text and browser-chrome counters do not extend the wait. Lightweight actions
can return after the short stable debounce. Actions
that can navigate, including element presses, click-family actions, Return, and
browser Back/Forward shortcuts, require a page-identity change before using their
navigation debounce when an `AXWebArea` is present. Page identity uses only the
WebArea role, title, and URL, so focus, tab-memory labels, and browser-chrome popup
changes cannot falsely satisfy navigation settle. The complete normalized AX
fingerprint must then stabilize before return. Non-browser applications fall back
to a meaningful complete-tree change. If no change occurs, one bounded two-second
grace lets a legitimate no-op finish without waiting for the hard timeout. Settling
stops at the minimum of five seconds, the requested
hard-bounded timeout, the remaining lease, and the action deadline. Timeout returns
the newest safe state with `status: timeout`; it is not reported as settled.

A press bound to a settable `AXTextField`, `AXTextArea`, or `AXSearchField` is
classified as local focus rather than navigation. It uses the shorter local settle
policy and preserves its bounded diff instead of triggering a follow-up full
navigation observation.

Local non-navigation actions use a 300 ms minimum stable interval and two stable
samples; editable focus uses a 250 ms minimum and two samples. Navigation-capable
actions retain the longer 600 ms/six-sample debounce and two-second no-change
grace. Immediate selection and clipboard shortcuts retain their short class.

Navigation recovery uses the same action classifier as adaptive settle. Copy,
select, and cut shortcuts such as `cmd+c` are local actions: selection or focus
churn must not force a full navigation observation. Return and browser
Back/Forward shortcuts remain navigation-capable. Recovery also distinguishes the
complete current AX snapshot from the bounded diff sent to the model. It retries
only when the model base contained a titled or addressed `AXWebArea` and the
complete current snapshot temporarily has none. An unchanged WebArea omitted from
a valid diff is not evidence of navigation, so dismissing a browser infobar does
not manufacture a follow-up Full reset. Applications that do not expose WebAreas
are not placed on the browser-navigation recovery path.

Normalized AX output suppresses ubiquitous `AXShowMenu` and `AXScrollToVisible`
actions when they are the only actions on structural groups, static text, images,
or unknown nodes. Those nodes omit frames and empty wrappers may be elided; genuine
press, edit, selection, and other control actions remain exposed.

For Chrome, the bounded renderer also prunes inactive tab subtrees and the wide,
labeled top bookmark-toolbar subtree. It retains the selected tab, address field,
new-tab control, navigation/reload controls, transient browser prompts, and the
page `AXWebArea`; pruning uses application identity, role, selection, and
window-relative geometry rather than localized bookmark names.

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

When a valid base and the application, window, and display context remain bound,
adding or removing local UI such as a Chrome find bar, infobar, popover, or menu
returns a diff even when the bounded traversal temporarily omits `AXWebArea` or
more than half of the visible nodes change. A large change becomes a full reset
only when both snapshots expose conflicting page identities. Application, native
window, or display replacement clears the base before diffing, and an unavailable
base produces a full state. Missing AX page or window anchors by themselves are
not reset signals. This keeps overlay open and close symmetric and prevents a
small local change from expanding into a redundant full tree.

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
bounded local reply deadline. Cancellation, timeout, or a missing callback
fails the current relay and triggers fail-closed recovery.

The proxy MCP process owns a session-private `/tmp/lifecycle.sock`. Fixed Claude
`Stop`, `StopFailure`, and `SessionEnd` command hooks invoke the same verified proxy binary in
notifier mode. The notifier validates the hook event name, sends one bounded
strict local frame, and waits for the authenticated remote acknowledgement.
Claude also emits `SessionEnd` with `reason=clear` for `/clear` while the same
process and MCP servers remain alive. The notifier maps only that reason to
`turn_stop`, preserving the existing lease and approvals for the cleared
conversation. Other `SessionEnd` reasons remain `session_end`. Repeated
`turn_stop` notifications are idempotent at the Broker.

The Broker rotates an active generation after 14 minutes, before the 15-minute
nested TLS identity limit. When the rotation deadline collides with an action, the
Broker requires a continuous two-second action-free quiet window, resetting that
window whenever an action starts or finishes. It then atomically cancels the relay
only while the in-flight action count is still zero. This prevents a burst that
begins at the rotation deadline from being cut mid-frame. A transport disconnect
is different: the nested relay races connection health against the action
handler, cancels the handler immediately when either WebSocket peer disappears,
fails the old Executor guard, and advances the control-plane generation. The
unknown-status request is never replayed across that generation boundary. An
invalid frame, binding failure, explicit stop, or Executor loss still ends the
current local UI generation and follows the fail-closed abort path so hidden
applications are restored. A scheduled or disconnect-recovery identity rotation
does not end the existing user authorization: the device advances the control
plane generation, rebinds the exact approved application identities, control
levels, and clipboard flags to that generation, resets Executor state, and opens a
fresh mutually authenticated relay. It never widens the approval set or extends
the device session's absolute expiry. Rotation failure performs a best-effort
Executor stop, authenticated control-plane abort, and Approval UI cleanup so the
next recovery requires an explicit current binding instead of silently reusing a
partially rotated generation.

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

The proxy waits at most 60 seconds for the first managed action context and at
most 45 seconds when recovering after an active transport. A managed-context
file that is temporarily absent while the control plane replaces it is retried
inside that bounded window and is never surfaced as a raw filesystem error.
The initial context, lease-readiness, and action-response budgets total less than
the 180-second foreground tool limit. Each action exchange remains bounded by the
shorter of the remaining authorization lease and 60 seconds. Lifecycle
acknowledgements have a 15-second deadline. A transient bridge, TLS, channel, or
timeout failure closes the partial inner connection and performs at most three
same-generation reconnects using the exact serialized request and binding. A
malformed response or response-binding failure poisons that proxy generation;
no partially read stream is reused.

If exact same-generation recovery is exhausted, the MCP surface returns the
stable `transport_unavailable` classification with a concrete diagnostic. The
next read-only observation waits for a strictly newer managed generation. An
action whose execution status is unknown is never replayed across that generation
boundary; the caller observes first and retries only after proving that the
action did not take effect.

The cross-language integration test
`rustlsAndNetworkFrameworkExchangeAuthenticatedActionFrames` starts the real Rust
rustls peer and connects with the Swift Network.framework implementation. It
verifies mutual P-256 identity pinning, exporter confirmation, strict request
decoding, and response binding over the same framed TLS stream used in production.
