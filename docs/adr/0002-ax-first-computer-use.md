# ADR 0002: Accessibility-first Computer Use observations

Status: accepted for implementation; real signed-app validation and independent
security review remain required for production.

## Context

The v1 device path returns a screenshot after ordinary actions. That is reliable
for visually rich applications, but it repeats image capture, encoding, transport,
and model-visible image input even when the target is a normal browser control.
Adding more coordinate helpers reduces some model round trips but does not remove
the underlying screenshot cost and makes freshness harder to reason about.

## Decision

Use a capability-gated v2 path with v1 as the complete fail-closed fallback.
The managed proxy exposes `observe`, `act`, `input_text`, and `read_clipboard` when
the required capability base is negotiated:

```text
observation_mode_v2
ax_state_v2
adaptive_settle_v2
```

Recognized optional extensions can refine individual responses without changing
that base. `clipboard_payload_v2` carries successful clipboard text in a dedicated
64 KiB UTF-8 field while retaining the existing approval and state bindings.

The normal operation is:

```text
observe(auto) -> bounded AX full/diff -> state-bound act
  -> adaptive settle -> returned AX diff
  -> screenshot only when AX is insufficient or visual judgment is required
```

The GUI Executor is the only AX reader. It returns bounded normalized nodes,
prefers visible browser/list children, merges public AX child collections without
duplicates, elides semantically empty wrappers, suppresses low-value menu/scroll
actions and frames on purely structural nodes, and keeps element indexes when `CFEqual` proves that an AX
element is the same object. Hidden,
ancestor-hidden, and off-window subtrees are not executable and do not expose
value or URL content. The renderer uses only read-only Accessibility queries;
private Chromium/Electron accessibility toggles are best-effort future work and
are not a production dependency.

Chrome-specific normalization removes inactive tab subtrees and the wide labeled
bookmark toolbar near the top of the window. Essential browser controls and the
selected page remain available, reducing fixed Full-state cost without introducing
a page-only mode that would break address-bar and tab workflows.

Every element target binds `state_id`, `state_generation`, application digest,
window ID, display fingerprint, and index. A stale target is rejected; the
Executor never searches by name or substitutes a neighboring element. AX frames
are metadata, not screenshot coordinates; explicit coordinates remain a
screenshot-generation-bound fallback. Adaptive settling is bounded by the request,
lease, and action deadline and reports timeout honestly. Fixed settling remains a
compatibility and diagnostic path with a separate bounded post-action context phase.
Navigation-capable actions
wait for an `AXWebArea` page-identity change before their stable debounce, then
require the complete AX fingerprint to stabilize. Browser chrome and focus noise
cannot satisfy the page-identity gate. Non-browser apps use a complete-tree change,
with one bounded no-change grace for legitimate no-ops.

The compact `input_text` helper accepts the same latest-state binding as `act`, so
an editable element can be focused and filled in one MCP call without a
model-visible image or a separate focus round trip. Partial bindings and
AX/coordinate mixtures fail before any device operation is sent.

Editable text-field presses use the local settle class and retain their bounded
diff. The timeout path is covered deterministically: it returns one finite safe
observation with `status=timeout` and does not retry the action. Acceptance runs do
not manufacture a timeout; an untriggered conditional branch is not a warning.

If an interactive action has already been accepted but its post-action window
cannot be resolved before the adaptive settle deadline, the Executor fails the
local session closed and returns a state-free `window_refresh_failed` rejection.
For an automatic-settle window-management shortcut, the Executor confirms the
new frontmost window first and then debounces that new window's AX tree within the
same deadline; it does not spend the deadline settling the window that was just
left. Transient AX window lookup failures during settle are retried only within
that existing deadline.
Fixed settling receives its bounded context phase after the requested wait, still
within the lease. The proxy poisons that transport generation instead of attempting
to reuse the consumed sequence.

Retained bindings also support direct cross-application workflows. Before acting
on a background application's retained element, the Executor requires that exact
signed process to become the `NSWorkspace` frontmost process; a lagging
`isActive` flag is insufficient. Editable presses then verify AX focus before
committing the action sequence, preventing a following context keyboard action
from reaching the application that was previously frontmost.

When one approved bundle has multiple running processes or windows, initial
resolution selects the frontmost substantial window across every process with the
approved signing identity. Later AX observations, screenshots, v1 fallback
captures, and post-action refreshes reuse the bound process and window ID. Pixel
capture uses ScreenCaptureKit's desktop-independent single-window filter, so a
window on another display cannot be replaced by a different window from the same
application.

Adaptive settle and post-action navigation recovery share one navigation
classifier. Copy/select/cut shortcuts stay on the local path and preserve Diff;
Return and browser Back/Forward remain navigation-capable. Local actions use two
stable samples with a 300 ms minimum, editable focus uses 250 ms, and navigation
retains the 600 ms/six-sample debounce and two-second no-change grace. Recovery
uses internal full-snapshot page-identity presence rather than searching only the
model-visible diff: an unchanged WebArea is normally absent from a diff and must
not turn a local browser infobar dismissal into a redundant Full reset. Recovery
is attempted only when the visible base had page identity and the complete current
snapshot temporarily loses it, which also keeps non-browser buttons off the
WebArea-specific recovery path.

The proxy, transport, session guard, and AX runtime retain one latest binding per
approved application. Switching from application A to B does not discard A's
model-visible state, so multi-application workflows can continue without a
redundant A observation. A new A state replaces only A's prior binding. Global
monotonic sequence and generation counters still order every request and prevent
replay across the device session.

Observation budgets are enforced before serialization: 800 nodes, depth 20, 160
characters per field, 16 KiB total text, and 20 visible rows per row container.
Images use explicit `compact`, `standard`, or `region` profiles. `none` suppresses
model-facing output but does not suppress identity, lease, approval, or sequence
checks; it preserves the last model-visible AX diff base while context is stable.

## Alternatives rejected

- Always returning screenshots: predictable but wastes image input on semantic UI.
- Exposing DOM/CDP, cookies, profiles, or debugging ports: smoother browser access
  but expands the trust boundary beyond approved visible UI.
- Enabling undocumented AX attributes by default: may improve Chromium/Electron
  coverage but lacks a stable public API and signed-app compatibility evidence.
- Automatically retrying stale indexes or coordinates: smoother appearance at the
  cost of wrong-target actions.

## Default negotiation and evidence

New generations negotiate v2 by default when the managed context contains the
complete capability set. A mixed or older deployment naturally falls back to v1,
and the Server emergency switch returns new generations to the empty capability
set. Existing generations are terminated and re-approved rather than downgraded
in place. Runtime quality evidence remains useful for regression tracking but is
not a prerequisite for the formally supported capability.

The fixed non-sensitive task corpus is `benchmark/computer-use-golden-prompts.json`;
the zero-content trace comparison is `docs/optimization-benchmark.md`. These
artifacts and automated protocol tests prove implementation contracts, not real
Safari/Chrome/Firefox behavior, Apple signing/TCC, external network allowlists,
Claude Code compatibility, or independent security review.
