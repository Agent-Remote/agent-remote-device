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
the exact capability set is negotiated:

```text
observation_mode_v2
ax_state_v2
adaptive_settle_v2
```

The normal operation is:

```text
observe(auto) -> bounded AX full/diff -> state-bound act
  -> adaptive settle -> returned AX diff
  -> screenshot only when AX is insufficient or visual judgment is required
```

The GUI Executor is the only AX reader. It returns bounded normalized nodes,
prefers visible browser/list children, merges public AX child collections without
duplicates, elides semantically empty single-child wrappers, and keeps element
indexes when `CFEqual` proves that an AX element is the same object. Hidden,
ancestor-hidden, and off-window subtrees are not executable and do not expose
value or URL content. The renderer uses only read-only Accessibility queries;
private Chromium/Electron accessibility toggles are best-effort future work and
are not a production dependency.

Every element target binds `state_id`, `state_generation`, application digest,
window ID, display fingerprint, and index. A stale target is rejected; the
Executor never searches by name or substitutes a neighboring element. Explicit
coordinates remain a screenshot-generation-bound fallback. Adaptive settling is
bounded by the request, lease, and action deadline and reports timeout honestly.

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

## Rollout and evidence

Roll out as v1 baseline, v2 shadow, internal signed devices, small cohort, then
per-application expansion. Any partial capability, wrong-target result, sensitive
telemetry, stale/fallback spike, success regression, or latency target failure
returns new generations to the empty capability set. Existing generations are
terminated and re-approved rather than downgraded in place.

The fixed non-sensitive task corpus is `benchmark/computer-use-golden-prompts.json`;
the zero-content trace comparison is `docs/optimization-benchmark.md`. These
artifacts and automated protocol tests prove implementation contracts, not real
Safari/Chrome/Firefox behavior, Apple signing/TCC, external network allowlists,
Claude Code compatibility, or independent security review.
