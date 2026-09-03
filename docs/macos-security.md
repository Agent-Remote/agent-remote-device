# macOS security boundary

The product is split into Approval UI, Network Broker, and GUI Executor processes.
The broker owns device authentication and the fixed outbound endpoint but has no
Screen Recording or Accessibility entitlement. The executor owns TCC-backed GUI
operations but has no arbitrary network client or long-term device credential.
They communicate through a versioned, code-signature-validated XPC interface.
The Approval UI, Network Broker, and GUI Executor set both core-dump resource limits to zero before
loading credentials or session state and exit when that process hardening cannot be applied.

The application bundle identifier is `dev.agentremote.device`. No component reads,
discovers, launches, configures, or communicates with local Claude installations.
Anthropic credential environment variables are excluded from child environments.

Remote Claude lifecycle notifications arrive only through the generation-bound
mutual TLS channel. The Broker treats turn completion as an Executor-only stop so
the existing machine lock remains held. Session termination stops the Executor,
calls the authenticated control-plane stop operation, and only then closes the
relay.

After local approval, the app leaves the user's foreground application and all
other applications visible. It starts the global stop, screen-lock, user-switch,
sleep, and network-loss monitors before it asks the Broker to activate the server
session or start the relay. Passive observation, screenshots, waits, zooms, and
approved clipboard reads do not activate the approved application. Interactive
input activates only the exact signed target process. After the action and its
follow-up observation complete, the Executor restores the user's prior foreground
application when the remote target is still frontmost. Pressed mouse or key state
delays restoration until release. A local stop observed while
activation is in flight leaves the UI paused and is forwarded as soon as Broker
approval returns; activation completion cannot overwrite that paused state.
Coordinate actions still require the model-visible window frame to remain exact.
Keyboard, unpositioned scrolling, and AX element actions instead retain the exact
signed process, window ID, and display binding while allowing macOS to adjust a
full-screen window's frame during Space activation. While that transition is in
flight, their exact window ID is resolved from the all-Space window list only after
the signed target process is confirmed frontmost; coordinate actions remain limited
to the current on-screen list. After an interactive action completes, the follow-up
observation resolves the target process's frontmost window without forcing the prior
window ID. If the action created or selected another window, the Executor discards
the prior window's AX state before returning the newly bound observation.
Window-management keyboard shortcuts are injected through normal HID routing only
after that exact process is frontmost; this is required for macOS and the application
to handle window creation or selection rather than a PID-local event queue.

Approval UI or Executor XPC invalidation immediately cancels the active relay.
Executor input release is best effort after the Executor becomes unavailable,
but its failure never suppresses the authenticated control-plane abort. The same
ordering applies to user Stop and End Session requests: local cleanup is
attempted first and control-plane revocation is still mandatory.

A trusted remote turn stop pauses only the current turn, not the approved device
session. Completed actions normally restore the user's prior foreground application;
the acknowledgement also waits for Executor input release and performs the same
restoration as fail-closed cleanup. A user-initiated foreground change is never overwritten. Before
the next authenticated action, the Broker uses the same code-signature-checked
XPC connection to restart the global safety monitors and resume the Executor. The
first resumed action must be a new screenshot. Remote session end also waits for
Approval UI cleanup, while the machine lock remains held across the paused turn interval.
All safety-critical Broker calls to the Executor and Approval UI have a local
15-second reply deadline and cancellation handling. A connected XPC peer that
stops replying therefore fails closed in the same way as an invalidated peer.
An invalid relay frame or Executor loss asks the still-connected Approval UI to
end the current generation and restore any legacy visibility journal before the control-plane
abort. A plain relay transport disconnect instead cancels any in-flight handler,
fails the old Executor guard, and rotates to a fresh generation with the exact
same approved applications. Unknown-status actions are never replayed across
that boundary.
Cleanup errors leave the UI in an explicit failed state; they never suppress
control-plane revocation. Scheduled identity rotation is narrower: it waits for
in-flight work, advances the authenticated control-plane generation, and rebinds
only the exact prior application identities, control levels, and clipboard flags
within the unchanged device-session expiry. It does not prompt again or widen
authorization. Any mismatch or incomplete rotation falls back to the normal
fail-closed cleanup path.

An allowed approval and relay activation each require a fresh, short-lived Ed25519 proof from the
fixed privileged outbound-policy attestor. The proof binds the signed Broker identity and exact
control-plane hostname to an enabled Network Extension and successful allow/block probes. Missing,
stale, mismatched, disabled, or silent attestors fail closed. The release evidence manifest is not
accepted as a substitute for this current-machine check.

Unsigned Swift Package builds exercise protocol and state-machine code only. A
signed installation on a dedicated test Mac is required to verify Sandbox, XPC,
ScreenCaptureKit, Accessibility, global Esc handling, window exclusion, and TCC
restart behavior.

## Accessibility observation boundary

The capability-gated v2 path is implemented. Accessibility snapshots belong
exclusively to the GUI Executor, which owns the TCC Accessibility permission and
has no arbitrary network client. The Broker may relay only the bounded encrypted
response; it does not inspect, cache, log, diff, or index AX content. Production
enablement still requires the signed-installation and release evidence gates in
this document.

The snapshot renderer applies hard node, depth, per-node text, total text, and
visible-row budgets before XPC serialization. Exhausting the text budget removes
later text values without stopping structural traversal, and a fixed quarter of
that budget remains reserved for editable or actionable controls. It emits only
normalized fields needed for UI decisions. Secure text values, password contents, invisible
sensitive values, and unbounded browser WebArea descendants are redacted or
elided. Browser WebArea/list traversal prefers visible children and merges
`AXChildren`, `AXRows`, `AXContents`, and best-effort `AXVisibleChildren` without
duplicates; semantically empty single-child wrappers are elided. Snapshot text,
URLs, window titles, element values, frames, and reversible
content hashes are prohibited from logs, audit records, crash metadata, and
performance telemetry.

Full/diff state is scoped to one complete device binding, active generation,
approved application digest, selected window ID, display fingerprint, and state
generation. The Executor retains at most one current mapping per approved
application. Switching between approved applications preserves each application's
latest model-visible mapping; a new state or window/display change replaces only
that application's mapping. A turn pause, generation rotation, or Executor restart
clears every mapping. A lost diff base returns a bounded full state with an
explicit reset marker.

For observations that combine AX and pixels, the Executor binds AX traversal to
the exact ScreenCaptureKit-selected window. It prefers an exact match between the
AX window number and ScreenCaptureKit window ID, together with a sufficiently
matching frame. When AX does not expose a window number, it requires the frame
and, when ScreenCaptureKit supplies one, a unique normalized window-title match.
The title comparison permits only the application suffix that macOS AX appends
after a ` - ` boundary. More than one matching candidate is ambiguous and fails
closed. This disambiguates same-process windows with identical frames. If the AX
window identity cannot be proven, observation fails closed instead of returning
AX state from a neighboring window. The title remains inside the Executor for
identity checking and is never added to logs or telemetry.

## State-bound element execution

An element index is not a stable identifier. The Executor accepts it only with the
device-generated latest `state_id` and `state_generation` for that application,
then resolves it in the matching in-memory snapshot. Before an AX action, it repeats the same live
application, process, window, display, lease, sequence, approval, and control-level
checks used for coordinate actions and verifies that the element exposes the exact
requested action.

Stale or foreign handles, missing elements, role/action changes, and ambiguous
targets fail closed. The Executor never searches for a same-named replacement,
reuses an index from another window, or silently falls back to coordinates.
`set_value` and selection require full-control approval. Secure/password fields and
credentials that require user hand-off cannot be populated through AX.

Coordinate fallback remains bound to the last image actually returned to the
model, not merely the most recent internal context observation. State generation
and screenshot generation are therefore separate counters in v2.

## Settle and image boundary

The Executor separates lightweight live-context observation from pixel capture and
encoding. AX-only and `none` observation modes still verify application, window,
display, lease, sequence, and approval state, but do not create an image. Pixel
capture occurs only for explicit screenshot, both-mode, visual fallback, or region
inspection responses.

Adaptive settling is bounded by the remaining lease and action deadline. It may
sample AX busy/loading state, bounded normalized tree hashes, and `AXWebArea`
title/URL page identity already authorized for model-visible AX state, but it cannot read
browser profiles, cookies, DOM debugging endpoints, local files, or another
application. Two stable samples after a debounce interval are required for
`settled`; timeout returns the newest safe state with an explicit timeout status.

Compact, standard, and region image profiles use bounded JPEG quality and preserve
the exact returned pixel dimensions and coordinate frame in the screenshot context. Compression never
weakens image signature, dimension, pixel-count, decode-allocation, or application
identity checks.

## Privacy-preserving performance telemetry

Permitted metrics are action type, observation mode, node count, diff/image/frame
byte counts, stage durations, settle status, error code, retry count, and fallback
kind. AX text, URLs, titles, images, values, inputs, coordinates, clipboard data,
and reversible content hashes are forbidden. Metrics must be bounded and attached
only to the existing session/device audit identifiers already allowed by the data
retention policy.

The proxy implementation emits this fixed schema to an owner-only JSONL file,
stops writing at 16 MiB, rejects symlink or unsafe existing targets, and disables
the sink after any write failure. It never makes action success depend on metrics
availability. Benchmark collection and comparison are documented in
`docs/optimization-benchmark.md`.
